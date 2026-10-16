<img src="../Logo.png" alt="Logo" width="400">

# olo_base_rs_decode

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_base_rs_decode.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_base_rs_decode.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_base_rs_decode.json?cacheSeconds=0)

VHDL Source: [olo_base_rs_decode](../../src/base/vhdl/olo_base_rs_decode.vhd)

## Description

This entity is a Reed-Solomon decoder over GF(2^m) for a stream of symbols, the counterpart of
[olo_base_rs_encode](./olo_base_rs_encode.md). It takes the same generics for the code (field polynomial, code length
_n_, data symbols _k_, generator roots _alpha^(b0 + i*gamma)_, interleaving depth _I_, dual basis) and corrects up to
_t = (n-k)/2_ symbol errors in every codeword. Shortened blocks are supported. Erasures are not supported.

The entity outputs the corrected data symbols of each block (optionally also the check symbols) and, after the last
output symbol of a block, one status pulse per codeword with the number of corrected symbols and an uncorrectable
flag. The field arithmetic is in [olo_base_pkg_gf](./olo_base_pkg_gf.md).

The reference configuration is the Reed-Solomon code of CCSDS 131.0-B-5 (TM Synchronization and Channel Coding,
section 4). The generics are the same as for the encoder:

| Generic | E = 16, RS(255,223) | E = 8, RS(255,239) | Clause |
| :------ | :------------------ | :----------------- | :----- |
| FieldPolynomial_g | x"87" | x"87" | 4.3.3 |
| CodewordSymbols_g | 255 | 255 | 4.3.2 |
| DataSymbols_g | 223 | 239 | 4.3.2 |
| FirstRoot_g | 212 | 45 | 4.3.4 |
| RootStep_g | 11 | 11 | 4.3.4 |
| InterleaveDepth_g | 1, 2, 3, 4, 5 or 8 | 1, 2, 3, 4, 5 or 8 | 4.3.5 |
| DualBasis_g | 117 | 117 | 4.3.9 |

The attached sync marker and the pseudo-randomizer are not part of this entity: the input of the decoder is the
derandomized codeblock without the marker.

A Python model of the decoder is in [src/base/python/olo_base_rs](../../src/base/python/olo_base_rs/); the testbench
compares the entity with it, including blocks with more than _t_ errors per codeword and invalid blocks.

## Generics

| Name              | Type             | Default | Description                                                  |
| :---------------- | :--------------- | ------- | :----------------------------------------------------------- |
| FieldPolynomial_g | std_logic_vector | -       | Field polynomial without its _x^m_ term (as in [olo_base_pkg_gf](./olo_base_pkg_gf.md)), e.g. _x"87"_ for _x^8 + x^7 + x^2 + x + 1_. Its length is the symbol width _m_ (3 ... 12). Must be primitive. |
| CodewordSymbols_g | positive         | -       | Codeword length _n_ in symbols, at most _2^m-1_                |
| DataSymbols_g     | positive         | -       | Data symbols per codeword _k_ (_k < n_). _n-k_ must be even. |
| FirstRoot_g       | natural          | 0       | _b0_, exponent of the first root of the generator polynomial (see [olo_base_rs_encode](./olo_base_rs_encode.md)) |
| RootStep_g        | positive         | 1       | _gamma_, the step between the exponents of consecutive roots. Must be coprime to _2^m-1_. |
| InterleaveDepth_g | positive         | 1       | Interleaving depth _I_: number of codewords interleaved symbol by symbol in one block |
| DualBasis_g       | natural          | 0       | Representation of the symbols at the ports:<br />0: polynomial basis<br />_s_ > 0: dual basis of _(1, alpha^s, ..., alpha^(s(m-1)))_ (CCSDS 131.0-B-5: 117) |
| OutputParity_g    | boolean          | false   | **false**: only the data symbols are output<br />**true**: the check symbols are output too (marked by _Out_Parity_) |
| RamStyle_g        | string           | "auto"  | RAM style of the block buffer, see [olo_base_ram_sdp](./olo_base_ram_sdp.md) |
| RamBehavior_g     | string           | "RBW"   | RAM behavior of the block buffer, see [olo_base_ram_sdp](./olo_base_ram_sdp.md) |

## Interfaces

### Control

| Name | In/Out | Length | Default | Description                                     |
| :--- | :----- | :----- | ------- | :---------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                           |
| Rst  | in     | 1      | -       | Reset input (high-active, synchronous to _Clk_) |

### Input Data

| Name     | In/Out | Length | Default | Description                                                  |
| :------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| In_Valid | in     | 1      | '1'     | AXI4-Stream handshaking signal for _In_Data_                  |
| In_Ready | out    | 1      | N/A     | AXI4-Stream handshaking signal for _In_Data_                  |
| In_Data  | in     | _m_    | -       | Received symbol (data or check symbol)                       |
| In_Last  | in     | 1      | '0'     | Last symbol of a shortened block. Not required for a block of _I*n_ symbols. |

### Output Data

| Name       | In/Out | Length | Default | Description                                                  |
| :--------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Out_Valid  | out    | 1      | N/A     | AXI4-Stream handshaking signal for _Out_Data_                 |
| Out_Ready  | in     | 1      | '1'     | AXI4-Stream handshaking signal for _Out_Data_                 |
| Out_Data   | out    | _m_    | N/A     | Corrected symbol                                             |
| Out_Parity | out    | 1      | N/A     | '1' for check symbols (only output with _OutputParity_g_ = true) |
| Out_Last   | out    | 1      | N/A     | Last output symbol of the block                              |

### Status

| Name                 | In/Out | Length                 | Default | Description                                     |
| :------------------- | :----- | :--------------------- | ------- | :---------------------------------------------- |
| Status_Valid         | out    | 1                      | N/A     | One pulse per codeword, codewords 1 ... _I_ of the block on consecutive clock cycles |
| Status_Last          | out    | 1                      | N/A     | Status of the last codeword of the block        |
| Status_Corrected     | out    | _ceil(log2(t+1))_      | N/A     | Number of symbols of the codeword the decoder changed |
| Status_Uncorrectable | out    | 1                      | N/A     | '1' if the codeword is uncorrectable            |

The status has no ready signal: the user must accept a pulse in every clock cycle in which _Status_Valid_ is high.

## Architecture

### Blocks

A block consists of the _I*n_ symbols of a codeblock as [olo_base_rs_encode](./olo_base_rs_encode.md) outputs it:
symbol _i_ of the block belongs to codeword _i mod I_, the last _I*(n-k)_ symbols are the check symbols. A full
block ends automatically after _I*n_ symbols; _In_Last_ ends a shortened block (CCSDS 131.0-B-5 4.3.7) earlier.

A block is decoded if its length is a multiple of _I_ and at least _I*(n-k+1)_ symbols (one data symbol per
codeword). Any other block is not a valid codeblock. The entity does not decode it: its symbols pass unchanged, and
all _I_ codewords are reported uncorrectable with a corrected count of zero. A block whose length is not a multiple
of _I_ also produces an assertion warning in simulation. The next block is decoded normally.

A reset discards the block that is being received and all blocks that are not yet completely output, including
their status. After a reset, _In_Ready_ is low for _I_ clock cycles while the syndrome registers are cleared.

### Decoding

The decoder works in three stages, each one block apart:

1. **Syndromes.** While a block is received, the symbols are written into a buffer RAM and the _2t_ syndromes of all
   _I_ codewords are computed in parallel (Horner's rule, constant multipliers). Two sets of syndrome registers
   alternate between consecutive blocks.
2. **Key equation.** For each codeword the syndromes are scaled to the length of the (shortened) block and the key
   equation is solved by the reformulated inversionless Berlekamp-Massey algorithm (RiBM, Sarwate and Shanbhag), one
   iteration per clock cycle, _2t_ iterations per codeword. The resulting error locator _Lambda(x)_ and error
   evaluator _Omega(x)_ of all _I_ codewords are stored.
3. **Correction.** The symbols of the block are read from the buffer in their original order. For every position
   the Chien search evaluates _Lambda(x)_ and the Forney formula computes the error value, which is added to the
   symbol on its way to the output. Search and correction run at the speed of the output, one position per clock
   cycle, so no second buffer is needed.

### Uncorrectable Codewords

A codeword is reported uncorrectable if one of the following holds:

- The Berlekamp-Massey register length _L_ is larger than _t_, or the degree of _Lambda(x)_ differs from _L_. In this
  case no symbol of the codeword is changed.
- The number of positions of the (shortened) codeword at which _Lambda(x)_ has a root differs from its degree. Roots
  in the virtual fill of a shortened codeword are not found and count as missing; a multiple root is found only once.
- The block is not a valid codeblock (see [Blocks](#blocks)).

Because the correction runs together with the output, the decoder knows whether a codeword is uncorrectable only
after its last position passed. **The output symbols of an uncorrectable codeword may therefore contain changes
that are not corrections**, and _Status_Corrected_ reports the number of symbols that were changed. A user that must
not forward wrongly corrected data has to buffer the output of a block until its status arrives.

Like every Reed-Solomon decoder, the entity cannot detect all codewords with more than _t_ errors: such a codeword can
be close enough to another valid codeword to be decoded to it and reported as corrected.

### Status Timing

The status of a block consists of _I_ pulses on _Status_Valid_ on consecutive clock cycles, one per codeword in the
order codeword 1 ... _I_. _Status_Last_ marks the pulse of the last codeword.

The first pulse comes at the earliest two clock cycles after the handshake of the block's _Out_Last_ symbol, and
only after all positions of the block (including the check symbols, which pass the correction stage even when they
are not output) were processed. The status of a block is therefore never output before its last output symbol was
accepted. The output of the next block can start before the status pulses of the previous block.

For a block without output symbols (a block of at most _I*(n-k)_ symbols with _OutputParity_g_ = false) the status
pulses follow the processing of its positions.

### Timing and Throughput

- The input accepts one symbol per clock cycle.
- The correction stage processes one position per clock cycle. With _OutputParity_g_ = false the check symbols are
  not output, so the output of each block has a gap of _I*(n-k)_ clock cycles; the data rate at the output is _k/n_
  of the clock. With 8-bit symbols at 200 MHz the input carries 1.6 Gbit/s.
- The entity handles one symbol per beat. Wider streams are converted with
  [olo_base_wconv_n2xn](./olo_base_wconv_n2xn.md) and [olo_base_wconv_xn2n](./olo_base_wconv_xn2n.md) around it.
- Latency: the first output symbol of a block appears _I*(2t+2) + 2t + 8_ clock cycles after the last symbol of the
  block was accepted (decoder idle, _Out_Ready_ high), e.g. 74 clock cycles for CCSDS E = 16 with _I_ = 1, 210 with
  _I_ = 5, and 42 for E = 8 with _I_ = 1.
- Status: with _OutputParity_g_ = false the first status pulse of a block comes _I*(n-k) + 1_ clock cycles after
  its _Out_Last_ symbol (the check symbols are processed but not output); with _OutputParity_g_ = true it comes two
  clock cycles after _Out_Last_ (_Out_Ready_ high).
- Continuous operation: blocks of _N_ symbols that follow each other without a gap are accepted without stalling the
  input (_In_Ready_ stays high) as long as _Out_Ready_ is high and _N >= I*(2t+3) + 2t + 3_. The bound comes from the
  key equation solver, which needs _2t+2_ clock cycles per codeword. For full blocks (_N = I*n_) it holds for all
  codes with _n >= 2t+3 + (2t+3)/I_, which includes every CCSDS configuration. For CCSDS E = 16, shortened blocks
  need at least 70 (_I_ = 1), 53 (_I_ = 2), 42 (_I_ = 5) or 40 (_I_ = 8) symbols per codeword for continuous
  operation. Shorter blocks are decoded at a rate of one block per _I*(2t+3) + 2t + 3_ clock cycles; _In_Ready_ goes
  low as needed.
- While _Out_Ready_ is low, the decoder keeps receiving until its buffer of _2^ceil(log2(2*I*n))_ symbols or its
  queue of four blocks is full.

### Resources

Synthesis results for the CCSDS configurations (Libero SoC 2025.2, PolarFire SoC MPFS250T, speed grade STD; the
maximum frequency with registered ports after place and route):

| Configuration       | LUTs  | Registers | Block RAM (LSRAM) | Small RAM (uSRAM) | Fmax    |
| :------------------ | ----: | --------: | ----------------: | ----------------: | ------: |
| E = 16, _I_ = 5     | 14131 | 6335      | 2                 | 31                | 192 MHz |
| E = 8, _I_ = 1      | 4466  | 1717      | 1                 | 4                 | 207 MHz |

The buffer of the received symbols uses block RAM, the stored locator and evaluator coefficients of the codewords
use small RAMs. Most of the logic is the key equation solver: the RiBM structure has _3t+1_ processing elements
with two general GF(2^m) multipliers each, so its size grows with _t_ but not with _I_. In the configuration with
_E_ = 16 the critical path is the selection of the syndrome in the scaling stage of the key equation solver.

The solver is busy for _2t+2_ of the _n_ clock cycles of each codeword. A folded solver with fewer processing
elements, which spends several clock cycles per iteration, would reduce the area while keeping the throughput for
full blocks; it is a possible extension and not implemented.
