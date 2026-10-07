<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_axi_master_full

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_axi_master_full.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_axi_master_full.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_axi_master_full.json?cacheSeconds=0)

VHDL Source: [olo_ft_axi_master_full](../../src/ft/vhdl/olo_ft_axi_master_full.vhd)

## Description

This component implements an **ECC-protected AXI4 master with unaligned-access support and width
conversion**. The interface and behavior match [olo_axi_master_full](../axi/olo_axi_master_full.md);
commands (sizes in bytes), responses and the AXI interface pass through unchanged.

The bulk write/read data buffering happens in SECDED-protected
[olo_ft_fifo_sync](./olo_ft_fifo_sync.md) instances where the last flag (read side) is part of the ECC
codeword. The wrapped master runs with small internal FIFOs that only cover the burst-issuance window and
are implemented in flip-flops by default, coverable by vendor TMR.

## Generics

All generics of [olo_axi_master_full](../axi/olo_axi_master_full.md) are provided with identical semantics.
Differences and additions:

| Name              | Type    | Default     | Description                                                  |
| :---------------- | :------ | ----------- | :----------------------------------------------------------- |
| DataFifoDepth_g   | positive | 1024       | Number of entries of the **ECC-protected** write/read data buffers (in user-width words). The internal FIFOs of the wrapped master are sized separately (fixed at 2 x _AxiMaxBeats_g_ AXI-width words). |
| RamStyle_g        | string  | "auto"      | RAM style of the ECC-protected data buffers. Any medium is acceptable here because the content is a full ECC codeword. |
| IntFifoRamStyle_g | string  | "registers" | RAM style of the wrapped master's internal FIFOs. The default "registers" keeps them in flip-flops so vendor TMR covers them. Overriding this to a RAM primitive re-introduces non-ECC-protected RAM state and is discouraged for fault-tolerant designs (see [olo_ft_axi_master_simple - Fault-Tolerant Storage](./olo_ft_axi_master_simple.md#fault-tolerant-storage)). |

## Interfaces

The command, response, write-data, read-data and AXI interfaces are identical to
[olo_axi_master_full](../axi/olo_axi_master_full.md). Additional ft ports:

### Error Status

| Name      | In/Out | Length | Default | Description                                                  |
| :-------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Wr_EccSec | out    | 1      | N/A     | Single error corrected on a write beat leaving the write buffer towards the wrapped master. One-cycle pulse per affected beat, directly countable. |
| Wr_EccDed | out    | 1      | N/A     | Double error detected on a write beat leaving the write buffer. The (unreliable) decoder output is written to the bus. One-cycle pulse per affected beat, directly countable. |
| Rd_EccSec | out    | 1      | N/A     | Single error corrected flag of the read data buffer. Time-aligned with _Rd_Data_, qualify with the _Rd_Valid_/_Rd_Ready_ handshake. |
| Rd_EccDed | out    | 1      | N/A     | Double error detected flag of the read data buffer. Read data is unreliable. Time-aligned with _Rd_Data_. |

### Error Injection (optional)

These ports drive the injection latches of the two internal [olo_ft_fifo_sync](./olo_ft_fifo_sync.md)
instances. Leave them unconnected for normal operation; see
[Open Logic Fault-Tolerance Principles - Error Injection](./olo_ft_principles.md#error-injection).

| Name              | In/Out | Length                                     | Default | Description                                                  |
| :---------------- | :----- | :----------------------------------------- | ------- | :----------------------------------------------------------- |
| Wr_ErrInj_BitFlip | in     | _eccCodewordWidth(UserDataWidth_g)_        | all 0   | Flip pattern for the data codeword of the write buffer.      |
| Wr_ErrInj_Valid   | in     | 1                                          | '0'     | Strobe, latched and applied to the next accepted write beat. |
| Rd_ErrInj_BitFlip | in     | _eccCodewordWidth(UserDataWidth_g + 1)_    | all 0   | Flip pattern for the {Last, Data} codeword of the read buffer. |
| Rd_ErrInj_Valid   | in     | 1                                          | '0'     | Strobe, latched and applied to the next beat entering the read buffer. |

## Detailed Description

### Architecture

The composition is identical to
[olo_ft_axi_master_simple](./olo_ft_axi_master_simple.md#architecture), with
[olo_axi_master_full](../axi/olo_axi_master_full.md) as the wrapped master: the external ECC buffers sit on
the user-width streams, the width conversion and alignment logic of the wrapped master (which is free of
RAM state) operates between them and the AXI bus.

One behavioral improvement over the base entity: the base entity requires write data to be provided only
after the command (due to the alignment logic). With the wrapper, the user may push write data ahead of the
command; it waits ECC-protected in the write buffer, and the wrapped master consumes it via its ready
handshake once the command arrives.

See [olo_ft_axi_master_simple - Fault-Tolerant Storage](./olo_ft_axi_master_simple.md#fault-tolerant-storage)
for the storage-protection discussion; it applies here unchanged (the internal data FIFO flip-flop cost is
`2 x AxiMaxBeats_g x AxiDataWidth_g x 9/8` per implemented direction).

### ECC Overhead, Error Injection and Status Flags

See the corresponding sections in
[Open Logic Fault-Tolerance Principles](./olo_ft_principles.md):

- [ECC Overhead](./olo_ft_principles.md#ecc-overhead) - internal storage width vs. data width
- [Error Injection](./olo_ft_principles.md#error-injection) - latched-strobe injection semantics
- [Error Status Flags](./olo_ft_principles.md#error-status-flags) - meaning of the SEC/DED flags

### Constraints

- Low-latency commands behave as in the base entity; the external buffer adds its fall-through latency to
  the data arrival.
- See
  [Open Logic Fault-Tolerance Principles - Constraints That Apply Across the Area](./olo_ft_principles.md#constraints-that-apply-across-the-area)
  for the constraints that apply across the _ft_ area.
