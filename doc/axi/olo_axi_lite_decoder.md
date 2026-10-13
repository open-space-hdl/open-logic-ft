<img src="../Logo.png" alt="Logo" width="400">

# olo_axi_lite_decoder

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_axi_lite_decoder.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_axi_lite_decoder.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_axi_lite_decoder.json?cacheSeconds=0)

VHDL Source: [olo_axi_lite_decoder](../../src/axi/vhdl/olo_axi_lite_decoder.vhd)

## Description

This component connects one AXI4-Lite master to _Ports_g_ AXI4-Lite slaves. Its typical use is the register access of
several entities with an AXI4-Lite slave interface (e.g. several [olo_axi_lite_slave](./olo_axi_lite_slave.md) based
register banks) from one master. It is a minimal address decoder for register access, not a general interconnect:
it supports one master and one transaction per direction at a time.

### Address Map

Every slave port owns an address window of 2<sup>_PortAddrWidth_g_</sup> bytes. The window of a transaction is selected
by the log2ceil(_Ports_g_) address bits directly above the window, slave port _p_ owns the byte addresses
_p_ x 2<sup>_PortAddrWidth_g_</sup> to (_p_ + 1) x 2<sup>_PortAddrWidth_g_</sup> - 1. The slave ports receive the
offset inside their window (the _PortAddrWidth_g_ least significant address bits).

Example for _Ports_g_ = 3 and _PortAddrWidth_g_ = 12:

| Address range     | Slave port | Response                       |
| :---------------- | :--------- | :----------------------------- |
| 0x0000 to 0x0FFF  | 0          | Response of slave port 0       |
| 0x1000 to 0x1FFF  | 1          | Response of slave port 1       |
| 0x2000 to 0x2FFF  | 2          | Response of slave port 2       |
| 0x3000 to 0x3FFF  | none       | DECERR, read data all zero     |

If _Ports_g_ is not a power of two, the windows above the last slave port are not populated. Accesses to them are
answered with DECERR (read data all zero) by the decoder, no slave port sees them.

Address bits above the window selection are ignored: the address map repeats every
2<sup>_PortAddrWidth_g_ + log2ceil(_Ports_g_)</sup> bytes. Restrict the address range on the master side if aliases
must not be accessible.

### Transactions

Read and write transactions are handled independently, one read and one write transaction can be in progress at the
same time (also on the same slave port). The decoder accepts the write address and the write data in any order and
forwards both to the slave port together. The responses of the slave ports (OKAY, SLVERR, DECERR) are forwarded
unchanged.

All outputs are registered, there is no combinational path between the master and the slave ports. A transaction takes
at least four clock cycles plus the handshake delays and the latency of the slave port. A new transaction of the same
direction is accepted after the response of the previous one was handed over to the master. This is regarded as
acceptable because the decoder targets register access.

### Usage with AXI4 Masters

An AXI4 master can be connected if it only issues single-beat transactions (_AxLEN_ = 0) of the full data width, for
example [olo_axi_master_simple](./olo_axi_master_simple.md) or [olo_axi_master_full](./olo_axi_master_full.md) with
_AxiMaxBeats_g_ = 1. Connect the AXI4-Lite subset of its signals and drive its _RLast_ input with '1'. ID signals are
not supported, so the master must not rely on transaction IDs.

## Generics

| Name            | Type     | Default | Description                                                                      |
| :-------------- | :------- | ------- | :------------------------------------------------------------------------------- |
| AxiAddrWidth_g  | positive | 32      | Address width of the slave interface, at least _PortAddrWidth_g_ + log2ceil(_Ports_g_) |
| AxiDataWidth_g  | positive | 32      | AXI data width (must be a multiple of 8)                                         |
| Ports_g         | positive | 4       | Number of slave ports (master interfaces of the decoder)                          |
| PortAddrWidth_g | positive | 16      | Address width of every slave port, the window of a port is 2<sup>_PortAddrWidth_g_</sup> bytes |

## Interfaces

### Control

| Name | In/Out | Length | Default | Description                                     |
| :--- | :----- | :----- | ------- | :---------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                           |
| Rst  | in     | 1      | -       | Reset input (high-active, synchronous to _Clk_) |

### AXI Slave Interface

| Name          | In/Out | Length | Default | Description                                                  |
| :------------ | :----- | :----- | ------- | :----------------------------------------------------------- |
| S_AxiLite_... | *      | *      | *       | AXI4-Lite slave interface (connect the master here). For the exact meaning of the signals, refer to the AXI4-Lite protocol specification. |

### AXI Master Interfaces

The signals of all slave ports are concatenated: the signals of slave port _p_ are in the slice with index _p_ (e.g.
bits (_p_ + 1) x _PortAddrWidth_g_ - 1 downto _p_ x _PortAddrWidth_g_ of _M_AxiLite_ArAddr_).

| Name              | In/Out | Length                         | Default | Description                       |
| :---------------- | :----- | :----------------------------- | ------- | :-------------------------------- |
| M_AxiLite_ArAddr  | out    | _Ports_g_ x _PortAddrWidth_g_  | N/A     | Read address (offset in the window) |
| M_AxiLite_ArValid | out    | _Ports_g_                      | N/A     | Read address valid                |
| M_AxiLite_ArReady | in     | _Ports_g_                      | -       | Read address ready                |
| M_AxiLite_AwAddr  | out    | _Ports_g_ x _PortAddrWidth_g_  | N/A     | Write address (offset in the window) |
| M_AxiLite_AwValid | out    | _Ports_g_                      | N/A     | Write address valid               |
| M_AxiLite_AwReady | in     | _Ports_g_                      | -       | Write address ready               |
| M_AxiLite_WData   | out    | _Ports_g_ x _AxiDataWidth_g_   | N/A     | Write data                        |
| M_AxiLite_WStrb   | out    | _Ports_g_ x _AxiDataWidth_g_/8 | N/A     | Write strobes                     |
| M_AxiLite_WValid  | out    | _Ports_g_                      | N/A     | Write data valid                  |
| M_AxiLite_WReady  | in     | _Ports_g_                      | -       | Write data ready                  |
| M_AxiLite_BResp   | in     | _Ports_g_ x 2                  | -       | Write response                    |
| M_AxiLite_BValid  | in     | _Ports_g_                      | -       | Write response valid              |
| M_AxiLite_BReady  | out    | _Ports_g_                      | N/A     | Write response ready              |
| M_AxiLite_RData   | in     | _Ports_g_ x _AxiDataWidth_g_   | -       | Read data                         |
| M_AxiLite_RResp   | in     | _Ports_g_ x 2                  | -       | Read response                     |
| M_AxiLite_RValid  | in     | _Ports_g_                      | -       | Read data valid                   |
| M_AxiLite_RReady  | out    | _Ports_g_                      | N/A     | Read data ready                   |

## Architecture

The decoder consists of two independent state machines, one for write and one for read transactions.

The write state machine collects the write address and the write data from the master (in any order), decodes the slave
port from the address and presents address and data to the slave port. After both handshakes it waits for the write
response of the slave port and hands it over to the master. For a window without slave port, it answers with DECERR
directly.

The read state machine accepts the read address, presents it to the decoded slave port, waits for the read data and
hands it over to the master. For a window without slave port, it answers with DECERR and zero read data directly.

The handshaking signals towards the master (_S_AxiLite_AwReady_, _S_AxiLite_WReady_, _S_AxiLite_ArReady_) are
asserted while the decoder is ready for a new transaction of the respective direction, also during reset.
