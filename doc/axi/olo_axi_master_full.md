<img src="../Logo.png" alt="Logo" width="400">

# olo_axi_master_full

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_axi_master_full.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_axi_master_full.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_axi_master_full.json?cacheSeconds=0)

VHDL Source: [olo_axi_master_full](../../src/axi/vhdl/olo_axi_master_full.vhd)

## Description

This entity is a wrapper around [olo_axi_master_simple](olo_axi_master_simple.md) to allow the following things:

- Access to non word-aligned addresses
- Arbitrarily sized (not a multiple of AXI data words) transfers
- AXI data width can be bigger than the data-width of the user interface

Besides the capability for unaligned transfers, the user interface is the same as for
[olo_axi_master_simple](olo_axi_master_simple.md) - **please read through the documentation of
[olo_axi_master_simple](olo_axi_master_simple.md)**. Important topics covered there are:

- Automatic splitting of transfers at 4kB boundaries
- Automatic splitting of transfers at the maximum bust-size supported by AXI4
- High Latency vs. Low Latency transactions

Important differences between _olo_axi_master_full_ and [olo_axi_master_simple](olo_axi_master_simple.md) are:

- Transaction size (_CmdWr_Size_/_CmdRd_Size_) is given in **bytes** not **words**
- Write data cannot be provided before the command (due to the required alignment)
- No byte enables are provided on the user interface because data is aligned automatically.

Note that due to the alignment logic, every command takes at least four clock cycles to process. In most cases there
significant bursts are executed this does not matter but for cases where many very small (e.g. single-beat) transactions
are required this entity is suboptimal.

### Throughput

Commands follow each other without gaps (see [Overview](#overview)): from 16 words per command, writes reach one beat
per clock cycle. Shorter commands are bound by the limits of
[olo_axi_master_simple](olo_axi_master_simple.md#throughput) (one command every 6 clock cycles) and lose one more
clock cycle per command in this entity. For reads the entity keeps one command in flight beyond the one whose data it
delivers, so the read latency is hidden only for long commands: at a read latency of 8 clock cycles about two clock
cycles per command are lost from 16 words per command, shorter read commands wait for part of the latency. With
_UserDataWidth_g_ < _AxiDataWidth_g_ the user side is the limit: one user word per clock cycle.

Measured with 32-bit user and AXI data, _AxiMaxBeats_g_ = 16, back-to-back commands in high-latency mode, a slave that
is always ready and a read latency of 8 clock cycles (beats per clock cycle, writes on the AXI data channel):

| Command size              | Writes | Reads |
| :------------------------ | -----: | ----: |
| 8 bytes (2 words)         |   0.29 |  0.19 |
| 16 bytes (4 words)        |   0.58 |  0.34 |
| 32 bytes (8 words)        |   0.89 |  0.58 |
| 64 bytes (16 words)       |   1.00 |  0.89 |
| 64 bytes at offset 1      |   0.94 |  0.89 |
| 1 KB                      |   1.00 |  0.99 |

An unaligned command of 16 words spans 17 AXI words, hence 0.94 at offset 1.

Most of the logic in this entity is related to unaligned and odd-sized transfers. So if you only require an AXI data
width that is larger than the user interface data width, you may consider using
[olo_axi_master_simple](olo_axi_master_simple.md) along with [olo_base_wconv_n2xn](../base/olo_base_wconv_n2xn.md)/
[olo_base_wconv_xn2n](../base/olo_base_wconv_xn2n.md) (width conversion) to achieve better performance with less
resource utilization.

Read and write logic are fully independent. So reads and writes can happen at the same time.

### FIXED Bursts

A command with _CmdWr_Fixed_ or _CmdRd_Fixed_ = '1' is executed with FIXED bursts as described for
[olo_axi_master_simple](olo_axi_master_simple.md#fixed-bursts): all bursts at the same address, at most 16 beats each,
not split at 4kB boundaries. For such a command:

- The address bits below the AXI data width are ignored: the transfer starts at the AXI word that contains the address.
- The user data is packed into the AXI beats from byte lane 0 without realignment: beat n carries the bytes n x B to
  n x B + B - 1 of the transfer, B = _AxiDataWidth_g_/8.
- Write: the strobes of the last beat are set for the remaining bytes only.
- Read: of the last beat only the remaining bytes are delivered.
- _CmdWr_Size_ and _CmdRd_Size_ remain in bytes.

## Generics

| Name                      | Type     | Default | Description                                                  |
| :------------------------ | :------- | ------- | :----------------------------------------------------------- |
| AxiAddrWidth_g            | positive | 32      | AXI4 address width (width of _AwAddr_ and _ArAddr_ signals)<br />Range: 12 ... 64 |
| AxiDataWidth_g            | positive | 32      | AXI data width (must be a power of 2 of bytes and equal to or an integer multiple of _UserDataWidth_g_)<br />Range: 8 ... 1024 |
| AxiMaxBeats_g             | positive | 256     | Maximum number of beats in one AXI transaction. <br />Values given by the AXI specification are 16 for AXI-3 and 256 for AXI-4. However, the user may choose any other number for scheduling reasons.<br />Range: 1 ... 256 |
| AxiMaxOpenTransactions_g  | positive | 8       | Maximum number of AXI commands (AW/AR-channel) to send before the first command is completed (outstanding transactions).<br />Range: 1 ... 8 |
| UserTransactionSizeBits_g | positive | 24      | Number of bits used to specify the number of bytes to transfer on the user command interface. This is the only limiting factor for the transfer size requested.<br />Must be smaller than _AxiAddrWidth_g_-1 (smaller than _AxiAddrWidth_g_ for _AxiDataWidth_g_ = 8), so that a single transfer cannot exceed the AXI address range. |
| DataFifoDepth_g           | positive | 1024    | Number of entries in the read/write data FIFOs (in AXI data words - _AxiDataWidth_g_, not bytes) |
| UserDataWidth_g           | positive | 32      | Width of the user interface for data (_Wr_Data_/_Rd_Data_)   |
| ImplRead_g                | boolean  | true    | Implement read functionality (can be disabled to save resources) |
| ImplWrite_g               | boolean  | true    | Implement write functionality (can be disabled to save resources) |
| RamBehavior_g             | string   | "RBW"   | Block-RAM style (must match FPGA architecture) **"RBW"** Read before write, **"WBR"** Write before read |

## Interfaces

### Control

| Name | In/Out | Length | Default | Description                                     |
| :--- | :----- | :----- | ------- | :---------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                           |
| Rst  | in     | 1      | -       | Reset input (high-active, synchronous to _Clk_) |

### AXI Interfaces

| Name      | In/Out | Length | Default | Description                                                  |
| :-------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| M_Axi_... | *      | *      | *       | AXI4 master interface. For the exact meaning of the signals, refer to the AXI protocol specification. |

Transaction requests are forwarded from the slave interface to the master interfaces. Responses are forwarded from the
master interface to the slave interface.

#### Note about AXI Id Signals

The following signals are not included in the olo_axi_master_full interface but they could be mandatory for some
applications or tools:

- M_Axi_AwId
- M_Axi_BId
- M_Axi_ArId
- M_Axi_RId
  
These signals are not included in olo_axi_master_full on purpose as they are not strictly needed to handle an AXI
transaction. If some application or tool require these signals, the user should add them in the wrapping entity.

### User Write Command Interface

| Name         | In/Out | Length                      | Default | Description                                                  |
| :----------- | :----- | :-------------------------- | ------- | :----------------------------------------------------------- |
| CmdWr_Addr   | in     | _AxiAddrWidth_g_            | 0       | Address to start writing at. Unaligned addresses are allowed and data is aligned automatically. |
| CmdWr_Size   | in     | _UserTransactionSizeBits_g_ | 0       | Number of bytes in the transfer.<br />Transfers may exceed _AxiMaxBeats_g_ and 4k boundaries. Transfers are splitted by the _olo_axi_master_simple_ automatically. |
| CmdWr_LowLat | in     | 1                           | '0'     | **'1'** \--\> Low latency mode, **'0'** \--\> High latency mode<br />It is recommended to **not** use low-latency transfers if _AxiDataWidth_g > UserDataWidth_g_ because the width conversion limits the bandwidth which would lead to stall-cycles on the AXI bus. |
| CmdWr_Fixed  | in     | 1                           | '0'     | **'1'** \--\> FIXED bursts at the AXI word of _CmdWr_Addr_, **'0'** \--\> incrementing bursts<br />See [FIXED Bursts](#fixed-bursts) |
| CmdWr_Valid  | in     | 1                           | '0'     | AXI-S handshaking signal for _CmdWr_                         |
| CmdWr_Ready  | out    | 1                           | -       | AXI-S handshaking signal for _CmdWr_                         |

### User Write Data Interface

| Name     | In/Out | Length            | Default | Description                       |
| :------- | :----- | :---------------- | ------- | :-------------------------------- |
| Wr_Data  | in     | _UserDataWidth_g_ | 0       | Write data                        |
| Wr_Valid | in     | 1                 | '0'     | AXI-S handshaking signal for _Wr_ |
| Wr_Ready | out    | 1                 | -       | AXI-S handshaking signal for _Wr_ |

### User Read Command Interface

| Name         | In/Out | Length                      | Default | Description                                                  |
| :----------- | :----- | :-------------------------- | ------- | :----------------------------------------------------------- |
| CmdRd_Addr   | in     | _AxiAddrWidth_g_            | 0       | Address to start reading at. Unaligned addresses are allowed and data is aligned automatically. |
| CmdRd_Size   | in     | _UserTransactionSizeBits_g_ | 0       | Number of bytes in the transfer<br />Transfers may exceed _AxiMaxBeats_g_ and 4k boundaries. Transfers are splitted by the _olo_axi_master_simple_ automatically. |
| CmdRd_LowLat | in     | 1                           | '0'     | **'1'** \--\> Low latency mode, **'0'** \--\> High latency mode<br />It is recommended to **not** use low-latency transfers if _AxiDataWidth_g > UserDataWidth_g_ because the width conversion limits the bandwidth which would lead to stall-cycles on the AXI bus. |
| CmdRd_Fixed  | in     | 1                           | '0'     | **'1'** \--\> FIXED bursts at the AXI word of _CmdRd_Addr_, **'0'** \--\> incrementing bursts<br />See [FIXED Bursts](#fixed-bursts) |
| CmdRd_Valid  | in     | 1                           | '0'     | AXI-S handshaking signal for _CmdRd_                         |
| CmdRd_Ready  | out    | 1                           | -       | AXI-S handshaking signal for _CmdRd_                         |

### User Read Data Interface

| Name     | In/Out | Length            | Default | Description                                                  |
| :------- | :----- | :---------------- | ------- | :----------------------------------------------------------- |
| Rd_Data  | out    | _UserDataWidth_g_ | -       | Read data                                                    |
| Rd_Last  | out    | 1                 | -       | Indicates last word of data related to a _CmdRd_ command. <br />The bit is related to the user command (_CmdRd_) and only set for the last AXI burst related to one user-command. |
| Rd_Valid | out    | 1                 | -       | AXI-S handshaking signal for _Rd_                            |
| Rd_Ready | in     | 1                 | '1'     | AXI-S handshaking signal for _Rd_                            |

### User Response Interface

| Name     | In/Out | Length | Default | Description                                                  |
| :------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Wr_Done  | out    | 1      | -       | Pulsed high when a write command was completed successfully. |
| Wr_Error | out    | 1      | -       | Pulsed high when a write command was completed but  failed (AXI response from slave indicated an error) |
| Rd_Done  | out    | 1      | -       | Pulsed high when a read command was completed successfully.  |
| Rd_Error | out    | 1      | -       | Pulsed high when a read command was completed but at least one transaction failed (AXI response from slave indicated an error) |
| Wr_ErrorResp | out | 2      | -       | AXI response code of the failed write command, valid in the clock cycle in which _Wr_Error_ is high (see below). "00" in all other clock cycles. |
| Rd_ErrorResp | out | 2      | -       | AXI response code of the failed read command, valid in the clock cycle in which _Rd_Error_ is high (see below). "00" in all other clock cycles. |

A command fails if any response of its bursts is not OKAY; for reads this includes every beat. The master never
requests exclusive access, so EXOKAY also counts as a failure. _Wr_ErrorResp_ and _Rd_ErrorResp_ report the first
response other than OKAY of the failed command, in the order the responses are accepted: "10" (SLVERR), "11" (DECERR)
or "01" (EXOKAY). Each command starts without an error code, so a successful command after a failed one reports no
code.

## Architecture

### Overview

The entity is a wrapper around [olo_axi_master_simple](olo_axi_master_simple.md). It controls data alignment and the
width conversion between user interface and AXI but uses [olo_axi_master_simple](olo_axi_master_simple.md) to actually
execute the transfers.

The only FIFOs present are the ones inside [olo_axi_master_simple](olo_axi_master_simple.md) (see the corresponding
documentation). As a result, significant amounts of data cannot be provided before the command because the command
determines the alignment required (which is done before the data goes into the FIFO). However, user designs shall not
rely on no data being accepted before the command - due to timing optimization a few words of data may be accepted
before the command.

Commands follow each other without gaps: the data path takes the next command when the data of the current one are
through, and the command is handed to [olo_axi_master_simple](olo_axi_master_simple.md) independently. In high-latency
mode [olo_axi_master_simple](olo_axi_master_simple.md) takes the next command only after the data of the current one,
so the data of a command can reach its data FIFO before the command. This relies on
[olo_axi_master_simple](olo_axi_master_simple.md) accepting write data before, with or after the command.

In cases where the amount of data to write - and hence the write command _WrCmd_xxx_ - is unknown until no more data
arrives, above situation is a problem because data is only accepted after the command. In this situation, it is
recommended that the user inserts a FIFO (to buffer the data before a command can be generated) external to
_olo_axi_master_full_.

The entity implements read and write side completely independent. It is possible to implement only one or the other
direction of transfers.

![Architecture](./master/olo_axi_master_full.svg)

### Transaction Types

For simplicity, only burst transactions are shown. However, of course also single-word transactions are supported.

Note that latencies and delays may be drawn shorter than they actually are to keep the waveforms small. However, all
relationship between signals are correct.

For all figures, an AXI-width of 32 bits and a user data width of 16 bits is assumed to keep the figures simple.

For simplicity reasons, only transfers that consist of one AXI transaction are shown. For the user interface, larger
transactions (consisting of multiple AXI bursts) do behave exactly the same.

For all transactions, user data is right-aligned. The byte at the start address specified in the command is the LSB of
the user input/output data.

Note that the transaction examples focus on data-alignment. For anything else, refer to the documentation of
[olo_axi_master_simple](olo_axi_master_simple.md).

#### Read Transaction

The example below shows a read transaction.

![Read Transaction](./master/full_read.png)

<p align=center> <i>Read transaction </i></\p>

The read command together with the address of the first used byte and the size of the data required in bytes is
asserted. The _olo_axi_master_full_ then calculates the word-aligned AXI start address (0x0200) and the number of
AXI-beats required (3 \--\> _M\_Axi\_ArLen_=2) and asserts the AXI AR-command.

The received data is aligned correctly in order to have the first byte the user requested as LSB of the first _Rd_Data_
word. Unused trailing bytes may have any value, they shall never be interpreted.

Note that the _Rd\_Done_ signal is asserted as soon as all data is read from AXI, even if the data was not yet consumed
on the _Rd_Data_ interface.

#### Write Transaction

The example below shows a write transaction.

Note that a high-latency write (AXI commands only sent after data is in buffer) is shown in this figure.

![Write Transaction](./master/full_write.png)

<p align=center> <i> Write transaction </i></\p>

In this example, the user provides some data before the command. The first word is accepted before the command, all
other data is not accepted before the command is known. Then the write command together with the address of the first
byte to write and the size of the data is provided. The _olo_axi_master_full_ then calculates the word-aligned AXI start
address (0x0200) and the number of AXI-beats required (3 \--\> _M\_Axi\_ArLen_=2) and asserts the AXI AW-command.

The user data is automatically aligned to the alignment of the AXI bus.

Unused bytes may have any value, which is fine because the corresponding strobe signal is set to low. The same applies
to the user interface: unused trailing bytes can have any value and do not influence the transaction.

As soon as the write response from AXI is received, the _Wr_Done_ signal is asserted.
