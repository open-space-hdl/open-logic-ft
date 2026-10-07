<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_delay

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_delay.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_delay.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_delay.json?cacheSeconds=0)

VHDL Source: [olo_ft_delay](../../src/ft/vhdl/olo_ft_delay.vhd)

## Description

This component implements an **ECC-protected fixed-duration delay** using SECDED (Single Error Correction,
Double Error Detection) Hamming code. The interface and behavior match
[olo_base_delay](../base/olo_base_delay.md): the input data is delayed by a fixed number of data-beats
(_In_Valid_ = '1' cycles).

The ECC is transparent to the user: data is automatically encoded at the input and decoded/corrected at the
output. Error status flags indicate whether a single-bit error was corrected or a double-bit error was
detected.

## Generics

| Name            | Type      | Default | Description                                                  |
| :-------------- | :-------- | ------- | :----------------------------------------------------------- |
| Width_g         | positive  | -       | Number of data bits. The internal delay line is wider to accommodate ECC parity bits. |
| Delay_g         | natural   | -       | Delay in data-beats (_In_Valid_ = '1' cycles). Delay of 0 implements a combinational feed-through. |
| Resource_g      | string    | "AUTO"  | "AUTO", "SRL" or "BRAM". See [olo_base_delay](../base/olo_base_delay.md) and the note on storage protection below. |
| BramThreshold_g | positive  | 128     | In "AUTO" mode, BRAM is used for delays >= _BramThreshold_g_. Applies to the internal (wrapped) delay, which is one beat shorter when _EccPipeline_g_ = 1. |
| RstState_g      | boolean   | true    | true: the first _Delay_g_ output beats after reset read as zero (with clean error flags). false: the content of the delay-line storage after reset is undefined, including the error flags. |
| RamBehavior_g   | string    | "RBW"   | Controls the RAM behavior. "RBW" or "WBR"                    |
| RamStyle_g      | string    | "auto"  | Controls the RAM implementation resource                     |
| EccPipeline_g   | natural   | 0       | 0: combinational ECC decode at the output. 1: one _In_Valid_-gated register on the decoded outputs; the wrapped delay is shortened by one beat internally, so the total delay stays exactly _Delay_g_. Requires _Delay_g_ >= 1. |

## Interfaces

### Clock and Reset

| Name | In/Out | Length | Default | Description                                                  |
| :--- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                                        |
| Rst  | in     | 1      | -       | Reset (high-active, synchronous to _Clk_). Restarts the _RstState_g_ warm-up and clears the internal error-injection latch. The delay-line storage content is unaffected but masked by the warm-up. |

### Data

| Name       | In/Out | Length    | Default | Description                                                  |
| :--------- | :----- | :-------- | ------- | :----------------------------------------------------------- |
| In_Data    | in     | _Width_g_ | -       | Input data                                                   |
| In_Valid   | in     | 1         | '1'     | Data-beat strobe. The delay line only advances on _In_Valid_ = '1' cycles; outputs hold their value in between. |
| Out_Data   | out    | _Width_g_ | N/A     | Delayed output data (corrected if a single-bit error was detected) |
| Out_EccSec | out    | 1         | N/A     | Single error corrected flag. Time-aligned with _Out_Data_.   |
| Out_EccDed | out    | 1         | N/A     | Double error detected flag. Output data is unreliable. Time-aligned with _Out_Data_. |

### Error Injection (optional)

These ports drive the internal [olo_ft_ecc_encode](./olo_ft_ecc_encode.md) instance. Leave them unconnected
for normal operation; see
[Open Logic Fault-Tolerance Principles - Error Injection](./olo_ft_principles.md#error-injection) for the
latched-strobe semantics shared across the _ft_ area.

| Name              | In/Out | Length                                                               | Default | Description                                                  |
| :---------------- | :----- | :------------------------------------------------------------------- | ------- | :----------------------------------------------------------- |
| In_ErrInj_BitFlip | in     | _[eccCodewordWidth](./olo_ft_pkg_ecc.md#ecccodewordwidth)(Width_g)_  | all 0   | Codeword-wide flip pattern. Each '1' bit XORs (flips) the corresponding bit of the stored codeword. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable. |
| In_ErrInj_Valid   | in     | 1                                                                    | '0'     | Strobe that latches _In_ErrInj\_BitFlip_ into the encoder's pending-injection register. The latched pattern is applied to the next _In_Valid_ beat. |

## Detailed Description

### Architecture

The entity is a sandwich of three Open Logic entities:

1. [olo_ft_ecc_encode](./olo_ft_ecc_encode.md) encodes each _In_Valid_ beat into a SECDED codeword
   (combinational).
2. [olo_base_delay](../base/olo_base_delay.md) delays the codeword (entity configured with a
   codeword-wide word).
3. [olo_ft_ecc_decode](./olo_ft_ecc_decode.md) decodes and corrects the delayed codeword and drives
   _Out_EccSec_ / _Out_EccDed_ time-aligned with _Out_Data_.

With `EccPipeline_g = 1`, one additional _In_Valid_-gated register is placed on the decoded outputs and the
wrapped delay runs one beat shorter, so the total delay stays exactly `Delay_g` and the outputs are driven
from a fabric register (restoring the registered-output property of the base entity).

### Storage-Medium Independent Protection

Because encoding happens before, and decoding after, **all** storage elements, every storage tap holds a
full ECC codeword: the SRL cells (LUT-based shift registers or MLABs), the BRAM content and the base
entity's output register alike. A single upset in any of these media is corrected at decode and reported on
_Out_EccSec_. `Resource_g` is therefore a pure resource/timing trade-off with no impact on the protection,
which notably makes this entity also the fault-tolerant answer for **short** delays: LUT-SRL and MLAB cells
are dynamic storage that vendor TMR does not cover, so even `Resource_g = "SRL"` configurations benefit from
the ECC.

The address counters and the warm-up counter are regular flip-flops and should be covered by vendor TMR
(`syn_radhardlevel = "tmr"`) as part of the surrounding radiation-hardened design, like all other control
logic.

### ECC Overhead, Error Injection and Status Flags

See the corresponding sections in
[Open Logic Fault-Tolerance Principles](./olo_ft_principles.md):

- [ECC Overhead](./olo_ft_principles.md#ecc-overhead) - internal storage width vs. data width
- [Error Injection](./olo_ft_principles.md#error-injection) - semantics of _In_ErrInj\_BitFlip_ / _In_ErrInj\_Valid_
- [Error Status Flags](./olo_ft_principles.md#error-status-flags) - meaning of _Out_EccSec_ / _Out_EccDed_

### Constraints

- With `RstState_g = false` the storage content after reset is undefined, so the error flags may report
  spurious errors during the first `Delay_g` output beats. Use the default `RstState_g = true` where clean
  flags matter (e.g. when counting SEC/DED events).
- See
  [Open Logic Fault-Tolerance Principles - Constraints That Apply Across the Area](./olo_ft_principles.md#constraints-that-apply-across-the-area)
  for the constraints that apply across the _ft_ area.
