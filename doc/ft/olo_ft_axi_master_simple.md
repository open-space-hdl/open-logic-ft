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
[olo_ft_private_fifo_stream](./olo_ft_private_fifo_stream.md) instances (the data path of
[olo_ft_fifo_sync](./olo_ft_fifo_sync.md) with an optional decoder pipeline) where the byte enables (write
side) and the last flag
(read side) are part of the ECC codeword, so no data or framing sideband is stored unprotected. The wrapped
master runs with small internal FIFOs that only cover the burst-issuance window and are implemented in
flip-flops by default, coverable by vendor TMR.

## Generics

All generics of [olo_axi_master_simple](../axi/olo_axi_master_simple.md) are provided with identical
semantics. Differences and additions:

| Name              | Type    | Default     | Description                                                  |
| :---------------- | :------ | ----------- | :----------------------------------------------------------- |
| DataFifoDepth_g   | positive | 1024       | Number of entries of the **ECC-protected** write/read data buffers (in words). The internal FIFOs of the wrapped master are sized separately (_IntFifoDepth_g_). |
| RamStyle_g        | string  | "auto"      | RAM style of the ECC-protected data buffers. Any medium is acceptable here because the content is a full ECC codeword. |
| IntFifoRamStyle_g | string  | "registers" | RAM style of the wrapped master's five internal FIFOs. The default "registers" keeps them in flip-flops so vendor TMR covers them. Overriding this to a RAM primitive re-introduces non-ECC-protected RAM state and is discouraged for fault-tolerant designs (see [Fault-Tolerant Storage](#fault-tolerant-storage)). |
| IntFifoDepth_g    | natural | 0           | Entries of the wrapped master's internal data FIFOs, in words. 0 selects 2 x _AxiMaxBeats_g_. Other values must be at least _AxiMaxBeats_g_ (assertion): in high-latency mode the wrapped master requests a burst only when it fits. More entries keep more read bursts in flight (see [Throughput](#throughput)) and cost flip-flops (see [Fault-Tolerant Storage](#fault-tolerant-storage)). |
| EccPipeline_g     | natural | 0           | Register stages in the ECC decoders of both data buffers (range _0..2_), with the meaning of [olo_ft_ram_sdp](./olo_ft_ram_sdp.md): 0 = combinational decode, 1 = one register at the decoder output, 2 = one register between the syndrome and the correction plus the output register. The stages add _EccPipeline_g_ clock cycles of latency to the read data and to the write data on their way to the wrapped master; the throughput stays one beat per clock cycle. See [Clock Frequency](./olo_ft_axi_master_simple.md#clock-frequency). |

## Interfaces

The command (including _CmdWr_Fixed_ and _CmdRd_Fixed_ for
[FIXED bursts](../axi/olo_axi_master_simple.md#fixed-bursts)), response (including the response codes _Wr_ErrorResp_
and _Rd_ErrorResp_), write-data, read-data and AXI interfaces are identical to
[olo_axi_master_simple](../axi/olo_axi_master_simple.md). Additional ft ports:

### Error Status

| Name      | In/Out | Length | Default | Description                                                  |
| :-------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Wr_EccSec | out    | 1      | N/A     | Single error corrected on a write beat leaving the write buffer towards the AXI bus. One-cycle pulse per affected beat, directly countable. |
| Wr_EccDed | out    | 1      | N/A     | Double error detected on a write beat leaving the write buffer. The (unreliable) decoder output is written to the bus. One-cycle pulse per affected beat, directly countable. |
| Rd_EccSec | out    | 1      | N/A     | Single error corrected flag of the read data buffer. Time-aligned with _Rd_Data_, qualify with the _Rd_Valid_/_Rd_Ready_ handshake. |
| Rd_EccDed | out    | 1      | N/A     | Double error detected flag of the read data buffer. Read data is unreliable. Time-aligned with _Rd_Data_. |

### Error Injection (optional)

These ports drive the injection latches of the two internal
[olo_ft_private_fifo_stream](./olo_ft_private_fifo_stream.md) instances. Leave them unconnected for normal
operation; see
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
User Wr --{Be & Data codeword}--> ECC FIFO --> olo_axi_master_simple --> AXI AW/W/B
                                  write        internal FIFOs:
                                  buffer       2 x AxiMaxBeats_g, registers

AXI AR/R --> olo_axi_master_simple --> ECC FIFO --{Last & Data codeword}--> User Rd
                                       read buffer

ECC FIFO: olo_ft_private_fifo_stream, DataFifoDepth_g entries
          (encoder, olo_base_fifo_sync, decoder with EccPipeline_g stages)
```

The wrapped master's user-side data interfaces are plain valid/ready streams, so the bulk buffering moves
into the external ECC FIFOs without behavioral change: the write buffer streams beats into the small
internal FIFO whenever it has room, and the high/low-latency command gating of the wrapped master (based on
its internal FIFO level) works unchanged. On the read side, the external buffer continuously drains the
internal FIFO, so read bursts flow at line rate; the data then waits ECC-protected until the user consumes
it. Compared to the base entity, the only observable differences are a few clock cycles of buffer
fall-through latency (plus _EccPipeline_g_ per buffer) and that _Wr_Ready_/_Rd_Valid_ reflect the external
buffer state.

### Throughput

In high-latency mode (_CmdRd_LowLat_ = '0') the wrapped master requests a read burst only when its internal
read FIFO can take the whole burst, so at most _IntFifoDepth_g_ beats are requested and not yet passed to the
read buffer. One beat per clock cycle needs these beats to cover the round trip of a burst: choose
_IntFifoDepth_g_ at least the read latency of the memory (AR handshake to the first R beat, in clock cycles) plus
two bursts, and _AxiMaxOpenTransactions_g_ x _AxiMaxBeats_g_ at least as large, because the open transactions bound
the beats in flight as well. With the default of two bursts, short bursts or a long read latency reduce the read
rate. Independently of the depth, the wrapped master issues at most one burst every 4 clock cycles, so bursts
below 4 beats cannot reach one beat per clock cycle (see
[olo_axi_master_simple - Throughput](../axi/olo_axi_master_simple.md#throughput)).

Measured read rates, in beats per clock cycle: 32-bit bus, commands of 1 KB, _AxiMaxOpenTransactions_g_ = 8,
_DataFifoDepth_g_ = 64, a slave that is always ready. The depth in brackets is the automatic value.

| _AxiMaxBeats_g_ | Read latency | _IntFifoDepth_g_ | Read rate |
| --------------: | -----------: | ---------------: | --------: |
|               2 |            8 |          0 (4)   |      0.27 |
|               2 |            8 |         16       |      0.50 |
|               4 |            8 |          0 (8)   |      0.47 |
|               4 |            8 |         16       |      0.94 |
|               4 |            8 |         32       |      0.99 |
|               8 |            8 |          0 (16)  |      0.76 |
|               8 |            8 |         32       |      1.00 |
|               4 |           30 |          0 (8)   |      0.20 |
|               4 |           30 |         32       |      0.82 |
|               4 |           30 |         64       |      0.89 |
|              16 |           30 |          0 (32)  |      0.63 |
|              16 |           30 |         64       |      1.00 |

With 2 beats per burst the rate stays at 0.50 (one burst every 4 clock cycles); with a read latency of 30 and 4 beats
per burst the 8 open transactions (32 beats) limit it. Writes with _AxiMaxBeats_g_ = 4 reach 0.73 with the automatic
depth and 0.99 with _IntFifoDepth_g_ = 16. _EccPipeline_g_ does not change the rate: writes at _AxiMaxBeats_g_ = 4
reach 0.73 with _EccPipeline_g_ = 0 and 2 alike; each stage adds one clock cycle of latency.

### Clock Frequency

The ECC decode after the RAM output of each data buffer is the critical path of the entity, and it grows with
the data width: the syndrome is a parity tree over the whole codeword and its result fans out to every data
bit. _EccPipeline_g_ = 1 registers the decoder output, _EccPipeline_g_ = 2 also splits the syndrome from the
correction.

FMAX_TABLE

### Fault-Tolerant Storage

- **Long-residency data** (payload waiting for commands or bus grants, read data waiting for the user)
  lives in the ECC-protected buffers; a single upset per codeword is corrected and reported.
- **The wrapped master's five internal FIFOs** (two data FIFOs covering the in-flight burst window, three
  small transaction/response FIFOs) are implemented in flip-flops with the default
  `IntFifoRamStyle_g = "registers"` and must be covered by vendor TMR (`syn_radhardlevel = "tmr"`) like all
  other control logic. Verify in the synthesis report that no RAM primitive is inferred for them (on tools
  where "registers" is not a recognized RAM-style value, e.g. Intel Quartus which uses "logic", override
  the generic accordingly).
- The flip-flop cost of the internal data FIFOs is `D x (AxiDataWidth_g + AxiDataWidth_g/8)` for the write
  FIFO and `D x (AxiDataWidth_g + 1)` for the read FIFO, with `D` = _IntFifoDepth_g_ (2 x _AxiMaxBeats_g_ by
  default), before TMR. Reduce `D` when the flip-flop budget matters; long user transfers are split into
  multiple AXI bursts automatically.

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
