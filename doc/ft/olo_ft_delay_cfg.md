<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_delay_cfg

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_delay_cfg.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_delay_cfg.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_delay_cfg.json?cacheSeconds=0)

VHDL Source: [olo_ft_delay_cfg](../../src/ft/vhdl/olo_ft_delay_cfg.vhd)

## Description

This component implements an **ECC-protected, runtime-configurable delay** using SECDED (Single Error
Correction, Double Error Detection) Hamming code. The interface and behavior match
[olo_base_delay_cfg](../base/olo_base_delay_cfg.md): the input data is delayed by a number of data-beats
(_In_Valid_ = '1' cycles) selected through the _Delay_ input. Delay changes settle at the output within less
than 5 samples.

The ECC is transparent to the user: data is automatically encoded at the input and decoded/corrected at the
output. Error status flags indicate whether a single-bit error was corrected or a double-bit error was
detected. In addition to the base entity, `RstState_g` suppresses reading storage that was never written
since reset, so no spurious error flags pollute SEC/DED counters during warm-up.

## Generics

| Name          | Type      | Default | Description                                                  |
| :------------ | :-------- | ------- | :----------------------------------------------------------- |
| Width_g       | positive  | -       | Number of data bits. The internal delay line is wider to accommodate ECC parity bits. |
| MaxDelay_g    | positive  | 256     | Maximum delay in data-beats                                  |
| SupportZero_g | boolean   | false   | true: _Delay_ = 0 (combinational feed-through) is supported. false: _Delay_ must be >= 1. |
| RstState_g    | boolean   | true    | true: while the configured delay reaches back to storage never written since reset, the output data and error flags read as zero (covers reset and delay increases beyond the written history). false: such output beats are undefined, including the error flags (base-entity behavior). |
| RamBehavior_g | string    | "RBW"   | Controls the RAM behavior. "RBW" or "WBR"                    |
| RamStyle_g    | string    | "auto"  | Controls the RAM implementation resource                     |
| EccPipeline_g | natural   | 0       | 0: combinational ECC decode at the output. 1: one _In_Valid_-gated register on the decoded outputs; the wrapped delay runs one beat shorter (dynamically compensated), so the total delay stays exactly _Delay_. |

## Interfaces

### Clock and Reset

| Name | In/Out | Length | Default | Description                                                  |
| :--- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                                        |
| Rst  | in     | 1      | -       | Reset (high-active, synchronous to _Clk_). Restarts the _RstState_g_ warm-up gate and clears the internal error-injection latch. The delay-line storage content is unaffected but masked by the warm-up gate. |

### Control

| Name  | In/Out | Length                       | Default | Description                                                  |
| :---- | :----- | :--------------------------- | ------- | :----------------------------------------------------------- |
| Delay | in     | _ceil(log2(MaxDelay_g+1))_   | -       | Delay in data-beats. Range 1 ... _MaxDelay_g_ (0 allowed with _SupportZero_g_ = true). May be changed at any time; the new delay settles at the output within less than 5 samples. |

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
2. [olo_base_delay_cfg](../base/olo_base_delay_cfg.md) delays the codeword (entity configured with a
   codeword-wide word).
3. [olo_ft_ecc_decode](./olo_ft_ecc_decode.md) decodes and corrects the delayed codeword and drives
   _Out_EccSec_ / _Out_EccDed_ time-aligned with _Out_Data_.

With `EccPipeline_g = 1`, one additional _In_Valid_-gated register is placed on the decoded outputs and the
wrapped entity receives `Delay - 1`, so the total delay stays exactly `Delay` and the outputs are driven
from a fabric register. With `SupportZero_g = true` the `Delay = 0` feed-through bypasses this register
combinationally.

Every storage tap of the wrapped entity (the internal shift register stages, the RAM content and the output
register) holds a full ECC codeword, so a single upset in any storage medium is corrected at decode. See
[olo_ft_delay - Storage-Medium Independent Protection](./olo_ft_delay.md#storage-medium-independent-protection)
for the discussion; it applies here unchanged.

### Warm-Up Gating (RstState_g)

The base entity has no reset state: after reset it outputs whatever the delay-line storage holds. For the
ECC-protected variant this content decodes as garbage codewords, which would assert spurious _Out_EccSec_ /
_Out_EccDed_ flags and pollute error counters.

With `RstState_g = true` (default), the entity counts the _In_Valid_ beats since reset and forces the output
data and both error flags to zero while the configured delay reaches back further than that. This covers
both the warm-up after reset and delay increases beyond the written history. Output beats within the written
history are never gated; increasing the delay within the written history simply replays older (valid)
samples, without spurious flags.

### ECC Overhead, Error Injection and Status Flags

See the corresponding sections in
[Open Logic Fault-Tolerance Principles](./olo_ft_principles.md):

- [ECC Overhead](./olo_ft_principles.md#ecc-overhead) - internal storage width vs. data width
- [Error Injection](./olo_ft_principles.md#error-injection) - semantics of _In_ErrInj\_BitFlip_ / _In_ErrInj\_Valid_
- [Error Status Flags](./olo_ft_principles.md#error-status-flags) - meaning of _Out_EccSec_ / _Out_EccDed_

### Constraints

- During the settle window after a delay change (less than 5 samples), the output data follows the
  base-entity behavior (a mix of old-delay and new-delay samples). The samples are decoded stored codewords,
  so no spurious error flags occur within the written history.
- With `RstState_g = false` the output (including the error flags) is undefined whenever the configured
  delay reaches back to storage never written since reset. Use the default `RstState_g = true` where clean
  flags matter (e.g. when counting SEC/DED events).
- See
  [Open Logic Fault-Tolerance Principles - Constraints That Apply Across the Area](./olo_ft_principles.md#constraints-that-apply-across-the-area)
  for the constraints that apply across the _ft_ area.
