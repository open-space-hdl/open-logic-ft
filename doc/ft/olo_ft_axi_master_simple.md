<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_axi_master_simple

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_axi_master_simple.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_axi_master_simple.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_axi_master_simple.json?cacheSeconds=0)

VHDL Source: [olo_ft_axi_master_simple](../../src/ft/vhdl/olo_ft_axi_master_simple.vhd)

## Description

This component implements an **ECC-protected AXI4 master with a simple interface**. The interface and
behavior match [olo_axi_master_simple](../axi/olo_axi_master_simple.md); commands, responses and the AXI
interface pass through unchanged.

The bulk write/read data buffering happens in SECDED-protected
[olo_ft_fifo_sync](./olo_ft_fifo_sync.md) instances where the byte enables (write side) and the last flag
(read side) are part of the ECC codeword, so no data or framing sideband is stored unprotected. The wrapped
master runs with small internal FIFOs that only cover the burst-issuance window and are implemented in
flip-flops by default, coverable by vendor TMR.

## Generics

All generics of [olo_axi_master_simple](../axi/olo_axi_master_simple.md) are provided with identical
semantics. Differences and additions:

| Name              | Type    | Default     | Description                                                  |
| :---------------- | :------ | ----------- | :----------------------------------------------------------- |
| DataFifoDepth_g   | positive | 1024       | Number of entries of the **ECC-protected** write/read data buffers (in words). The internal FIFOs of the wrapped master are sized separately (fixed at 2 x _AxiMaxBeats_g_). |
| RamStyle_g        | string  | "auto"      | RAM style of the ECC-protected data buffers. Any medium is acceptable here because the content is a full ECC codeword. |
| IntFifoRamStyle_g | string  | "registers" | RAM style of the wrapped master's five internal FIFOs. The default "registers" keeps them in flip-flops so vendor TMR covers them. Overriding this to a RAM primitive re-introduces non-ECC-protected RAM state and is discouraged for fault-tolerant designs (see [Fault-Tolerant Storage](#fault-tolerant-storage)). |

## Interfaces

The command, response, write-data, read-data and AXI interfaces are identical to
[olo_axi_master_simple](../axi/olo_axi_master_simple.md). Additional ft ports:

### Error Status

| Name      | In/Out | Length | Default | Description                                                  |
| :-------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Wr_EccSec | out    | 1      | N/A     | Single error corrected on a write beat leaving the write buffer towards the AXI bus. One-cycle pulse per affected beat, directly countable. |
| Wr_EccDed | out    | 1      | N/A     | Double error detected on a write beat leaving the write buffer. The (unreliable) decoder output is written to the bus. One-cycle pulse per affected beat, directly countable. |
| Rd_EccSec | out    | 1      | N/A     | Single error corrected flag of the read data buffer. Time-aligned with _Rd_Data_, qualify with the _Rd_Valid_/_Rd_Ready_ handshake. |
| Rd_EccDed | out    | 1      | N/A     | Double error detected flag of the read data buffer. Read data is unreliable. Time-aligned with _Rd_Data_. |

### Error Injection (optional)

These ports drive the injection latches of the two internal [olo_ft_fifo_sync](./olo_ft_fifo_sync.md)
instances. Leave them unconnected for normal operation; see
[Open Logic Fault-Tolerance Principles - Error Injection](./olo_ft_principles.md#error-injection).

| Name              | In/Out | Length                                                                | Default | Description                                                  |
| :---------------- | :----- | :-------------------------------------------------------------------- | ------- | :----------------------------------------------------------- |
| Wr_ErrInj_BitFlip | in     | _eccCodewordWidth(AxiDataWidth_g + AxiDataWidth_g/8)_                 | all 0   | Flip pattern for the {Be, Data} codeword of the write buffer. |
| Wr_ErrInj_Valid   | in     | 1                                                                     | '0'     | Strobe, latched and applied to the next accepted write beat.  |
| Rd_ErrInj_BitFlip | in     | _eccCodewordWidth(AxiDataWidth_g + 1)_                                | all 0   | Flip pattern for the {Last, Data} codeword of the read buffer. |
| Rd_ErrInj_Valid   | in     | 1                                                                     | '0'     | Strobe, latched and applied to the next beat entering the read buffer from the AXI side. |

## Detailed Description

### Architecture

```text
User Wr --{Be & Data codeword}--> olo_ft_fifo_sync --> olo_axi_master_simple --> AXI AW/W/B
          (ECC bulk buffer,        (write buffer)      (internal FIFOs:
           DataFifoDepth_g)                             2 x AxiMaxBeats_g, registers)

AXI AR/R --> olo_axi_master_simple --> olo_ft_fifo_sync --{Last & Data codeword}--> User Rd
                                       (read buffer, ECC bulk, DataFifoDepth_g)
```

The wrapped master's user-side data interfaces are plain valid/ready streams, so the bulk buffering moves
into the external ECC FIFOs without behavioral change: the write buffer streams beats into the small
internal FIFO whenever it has room, and the high/low-latency command gating of the wrapped master (based on
its internal FIFO level) works unchanged. On the read side, the external buffer continuously drains the
internal FIFO, so read bursts flow at line rate; the data then waits ECC-protected until the user consumes
it. Compared to the base entity, the only observable differences are a few clock cycles of buffer
fall-through latency and that _Wr_Ready_/_Rd_Valid_ reflect the external buffer state.

### Fault-Tolerant Storage

- **Long-residency data** (payload waiting for commands or bus grants, read data waiting for the user)
  lives in the ECC-protected buffers; a single upset per codeword is corrected and reported.
- **The wrapped master's five internal FIFOs** (two data FIFOs covering the in-flight burst window, three
  small transaction/response FIFOs) are implemented in flip-flops with the default
  `IntFifoRamStyle_g = "registers"` and must be covered by vendor TMR (`syn_radhardlevel = "tmr"`) like all
  other control logic. Verify in the synthesis report that no RAM primitive is inferred for them (on tools
  where "registers" is not a recognized RAM-style value, e.g. Intel Quartus which uses "logic", override
  the generic accordingly).
- The flip-flop cost of the internal data FIFOs is `2 x AxiMaxBeats_g x (AxiDataWidth_g + AxiDataWidth_g/8)`
  per implemented direction. Reduce `AxiMaxBeats_g` when the flip-flop budget matters; long user transfers
  are split into multiple AXI bursts automatically.

### ECC Overhead, Error Injection and Status Flags

See the corresponding sections in
[Open Logic Fault-Tolerance Principles](./olo_ft_principles.md):

- [ECC Overhead](./olo_ft_principles.md#ecc-overhead) - internal storage width vs. data width
- [Error Injection](./olo_ft_principles.md#error-injection) - latched-strobe injection semantics
- [Error Status Flags](./olo_ft_principles.md#error-status-flags) - meaning of the SEC/DED flags

### Constraints

- Low-latency commands (_CmdWr_LowLat_/_CmdRd_LowLat_ = '1') behave as in the base entity; the external
  buffer adds its fall-through latency to the data arrival, so the AXI bus may stall slightly longer if
  data is provided late.
- See
  [Open Logic Fault-Tolerance Principles - Constraints That Apply Across the Area](./olo_ft_principles.md#constraints-that-apply-across-the-area)
  for the constraints that apply across the _ft_ area.
