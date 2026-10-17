<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_private_fifo_stream

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_private_fifo_stream](../../src/ft/vhdl/olo_ft_private_fifo_stream.vhd)

**Internal building block.** This entity is the ECC-protected data buffer of the ft AXI masters
[olo_ft_axi_master_simple](./olo_ft_axi_master_simple.md) and [olo_ft_axi_master_full](./olo_ft_axi_master_full.md).
It is **not intended for direct end-user instantiation**; use [olo_ft_fifo_sync](./olo_ft_fifo_sync.md) instead.

## Description

This component implements an **ECC-protected synchronous FIFO with stream interfaces only**: it has the data path of
[olo_ft_fifo_sync](./olo_ft_fifo_sync.md) but no fill levels and no status flags, and its ECC decoder can be
pipelined.

A pipelined decoder holds beats that the levels of the internal FIFO do not count. That is why
[olo_ft_fifo_sync](./olo_ft_fifo_sync.md), which exposes the levels and flags of
[olo_base_fifo_sync](../base/olo_base_fifo_sync.md), keeps a combinational decoder. A consumer that uses only the
handshakes, such as the ft AXI masters, sees the pipeline only as additional latency.

## Generics

| Name          | Type     | Default | Description                                                  |
| :------------ | :------- | ------- | :----------------------------------------------------------- |
| Width_g       | positive | -       | Number of data bits per FIFO entry. The internal FIFO is wider to accommodate ECC parity bits. |
| Depth_g       | positive | -       | Number of entries of the internal FIFO                       |
| EccPipeline_g | natural  | 0       | Number of register stages in the ECC decoder (range _0..2_), as in [olo_ft_ram_sdp](./olo_ft_ram_sdp.md): <br>0 = combinational decode. <br>1 = one register at the decoder output. <br>2 = one register between the syndrome and the correction, plus the output register. |
| RamStyle_g    | string   | "auto"  | Controls the RAM implementation resource                     |
| RamBehavior_g | string   | "RBW"   | Controls the RAM behavior. "RBW" or "WBR"                    |

## Interfaces

### Clock and Reset

| Name | In/Out | Length | Default | Description                                                  |
| :--- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                                        |
| Rst  | in     | 1      | -       | Reset (high-active, synchronous to _Clk_). Empties the FIFO and the decoder pipeline and clears the error-injection latch. |

### Input Data

| Name     | In/Out | Length    | Default | Description                     |
| :------- | :----- | :-------- | ------- | :------------------------------ |
| In_Data  | in     | _Width_g_ | -       | Input data                      |
| In_Valid | in     | 1         | '1'     | Input valid (AXI-S handshaking) |
| In_Ready | out    | 1         | N/A     | Input ready (AXI-S handshaking) |

### Output Data

| Name       | In/Out | Length    | Default | Description                                                  |
| :--------- | :----- | :-------- | ------- | :----------------------------------------------------------- |
| Out_Data   | out    | _Width_g_ | N/A     | Output data (corrected if a single-bit error was detected)   |
| Out_Valid  | out    | 1         | N/A     | Output valid (AXI-S handshaking)                             |
| Out_Ready  | in     | 1         | '1'     | Output ready (AXI-S handshaking)                             |
| Out_EccSec | out    | 1         | N/A     | Single error corrected flag. Time-aligned with _Out_Data_.   |
| Out_EccDed | out    | 1         | N/A     | Double error detected flag. Read data is unreliable. Time-aligned with _Out_Data_. |

### Error Injection (optional)

Identical to [olo_ft_fifo_sync](./olo_ft_fifo_sync.md#error-injection-optional): the pattern is latched by
_In_ErrInj_Valid_ and applied to the next accepted input beat.

| Name              | In/Out | Length                                                               | Default | Description                                                  |
| :---------------- | :----- | :------------------------------------------------------------------- | ------- | :----------------------------------------------------------- |
| In_ErrInj_BitFlip | in     | _[eccCodewordWidth](./olo_ft_pkg_ecc.md#ecccodewordwidth)(Width_g)_  | all 0   | Codeword-wide flip pattern. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable. |
| In_ErrInj_Valid   | in     | 1                                                                    | '0'     | Strobe that latches _In_ErrInj\_BitFlip_. The latched pattern is applied to the next accepted input beat. |

## Detailed Description

### Architecture

The entity is composed of the three entities of [olo_ft_fifo_sync](./olo_ft_fifo_sync.md#architecture):

1. [olo_ft_ecc_encode](./olo_ft_ecc_encode.md), combinational, encodes each accepted input beat.
2. [olo_base_fifo_sync](../base/olo_base_fifo_sync.md) stores the codeword.
3. [olo_ft_ecc_decode](./olo_ft_ecc_decode.md) with _Pipeline_g_ = _EccPipeline_g_ decodes and corrects each beat.
   Its pipeline stages have valid/ready handshakes, so the FIFO passes one beat per clock cycle for every value of
   _EccPipeline_g_, and the ECC flags travel with their beat.

One beat per clock cycle needs _Depth_g_ >= 3: [olo_base_fifo_sync](../base/olo_base_fifo_sync.md) sees a read on its
write side one clock cycle late, so with 2 entries it takes at most 2 beats in 3 clock cycles.

The output side follows the output of [olo_base_fifo_sync](../base/olo_base_fifo_sync.md) by _EccPipeline_g_ clock
cycles. The pipeline stages hold beats in addition to the _Depth_g_ entries of the internal FIFO.

The ECC decode after the RAM output is the critical path of the entity. _EccPipeline_g_ = 2 splits it into the
syndrome and the correction; the encoder, combinational before the RAM, is about as deep as the syndrome stage.

### ECC Overhead, Error Injection and Status Flags

See the corresponding sections in
[Open Logic Fault-Tolerance Principles](./olo_ft_principles.md):

- [ECC Overhead](./olo_ft_principles.md#ecc-overhead) - internal storage width vs. data width
- [Error Injection](./olo_ft_principles.md#error-injection) - semantics of _In_ErrInj\_BitFlip_ / _In_ErrInj\_Valid_
- [Error Status Flags](./olo_ft_principles.md#error-status-flags) - meaning of _Out_EccSec_ / _Out_EccDed_
