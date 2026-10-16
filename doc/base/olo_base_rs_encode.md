<img src="../Logo.png" alt="Logo" width="400">

# olo_base_rs_encode

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_base_rs_encode.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_base_rs_encode.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_base_rs_encode.json?cacheSeconds=0)

VHDL Source: [olo_base_rs_encode](../../src/base/vhdl/olo_base_rs_encode.vhd)

## Description

This entity is a systematic Reed-Solomon encoder over GF(2^m) for a stream of symbols. It supports any primitive
field polynomial, any code length _n_ up to _2^m-1_ and any number of check symbols, the generator roots
_alpha^(b0 + i*gamma)_, symbol interleaving of _I_ codewords, shortened blocks (virtual fill) and the dual basis
representation of the symbols at its ports.

The data symbols pass the entity unchanged; after the last data symbol of a block the entity outputs the check
symbols of all codewords of the block. The matching decoder is [olo_base_rs_decode](./olo_base_rs_decode.md), the
field arithmetic is in [olo_base_pkg_gf](./olo_base_pkg_gf.md).

The reference configuration is the Reed-Solomon code of CCSDS 131.0-B-5 (TM Synchronization and Channel Coding,
section 4):

| Generic | E = 16, RS(255,223) | E = 8, RS(255,239) | Clause |
| :------ | :------------------ | :----------------- | :----- |
| FieldPolynomial_g | x"87" | x"87" | 4.3.3: _x^8 + x^7 + x^2 + x + 1_ |
| CodewordSymbols_g | 255 | 255 | 4.3.2 |
| DataSymbols_g | 223 | 239 | 4.3.2 |
| FirstRoot_g | 212 | 45 | 4.3.4: roots _alpha^(11 j)_, _j_ = 128-E ... 127+E, _11 (128-E) mod 255_ |
| RootStep_g | 11 | 11 | 4.3.4 |
| InterleaveDepth_g | 1, 2, 3, 4, 5 or 8 | 1, 2, 3, 4, 5 or 8 | 4.3.5 |
| DualBasis_g | 117 | 117 | 4.3.9 |

A shortened codeblock (4.3.7) is a block with fewer data symbols ending with _In_Last_. The attached sync marker
(4.3.8.1) and the pseudo-randomizer are not part of this entity.

A Python model of the encoder is in [src/base/python/olo_base_rs](../../src/base/python/olo_base_rs/); the testbench
compares the entity with it.

## Generics

| Name              | Type             | Default | Description                                                  |
| :---------------- | :--------------- | ------- | :----------------------------------------------------------- |
| FieldPolynomial_g | std_logic_vector | -       | Field polynomial without its _x^m_ term (as in [olo_base_pkg_gf](./olo_base_pkg_gf.md)), e.g. _x"87"_ for _x^8 + x^7 + x^2 + x + 1_. Its length is the symbol width _m_ (3 ... 12). Must be primitive. |
| CodewordSymbols_g | positive         | -       | Codeword length _n_ in symbols, at most _2^m-1_                |
| DataSymbols_g     | positive         | -       | Data symbols per codeword _k_ (_k < n_). The codeword has _n-k_ check symbols. |
| FirstRoot_g       | natural          | 0       | _b0_: the generator polynomial is _g(x) = (x + alpha^b0) (x + alpha^(b0+gamma)) ... (x + alpha^(b0+(n-k-1) gamma))_ |
| RootStep_g        | positive         | 1       | _gamma_, the step between the exponents of consecutive roots. Must be coprime to _2^m-1_ for the decoder. |
| InterleaveDepth_g | positive         | 1       | Interleaving depth _I_: number of codewords interleaved symbol by symbol in one block |
| DualBasis_g       | natural          | 0       | Representation of the symbols at the ports:<br />0: polynomial basis<br />_s_ > 0: dual basis of _(1, alpha^s, ..., alpha^(s(m-1)))_ (CCSDS 131.0-B-5: 117) |

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
| In_Data  | in     | _m_    | -       | Data symbol                                                  |
| In_Last  | in     | 1      | '0'     | Last data symbol of a shortened block. Not required for a block of _I*k_ symbols. |

### Output Data

| Name       | In/Out | Length | Default | Description                                                  |
| :--------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Out_Valid  | out    | 1      | N/A     | AXI4-Stream handshaking signal for _Out_Data_                 |
| Out_Ready  | in     | 1      | '1'     | AXI4-Stream handshaking signal for _Out_Data_                 |
| Out_Data   | out    | _m_    | N/A     | Data symbol or check symbol                                  |
| Out_Parity | out    | 1      | N/A     | '1' for check symbols                                        |
| Out_Last   | out    | 1      | N/A     | Last check symbol of the codeblock                           |

## Architecture

### Blocks

A block consists of _I*k_ data symbols, or fewer when _In_Last_ ends it earlier (shortened block). The symbols are
dealt to the _I_ codewords in rotation: symbol _i_ of the block belongs to codeword _i mod I_. After the last data
symbol the entity outputs the _I*(n-k)_ check symbols: the first check symbol of codewords 1 ... _I_, then the second
check symbol of codewords 1 ... _I_ and so on (CCSDS 131.0-B-5 4.4.1). _Out_Last_ marks the last check symbol.

Each codeword of a shortened block is shortened by the same number of symbols, so the length of a shortened block
must be a multiple of _I_ (CCSDS 131.0-B-5 4.3.7.3). A block that ends with _In_Last_ at another length is still ended
in a defined way: every codeword gets the check symbols of the data symbols it received, in the order above. Such a
block is not a valid codeblock and [olo_base_rs_decode](./olo_base_rs_decode.md) reports it as uncorrectable. The
next block starts normally.

### Data path

Every codeword has a remainder register of _n-k_ symbols, the remainder of the division of its data polynomial by
_g(x)_. The _I_ registers form a rotating chain: the register of the codeword of the current symbol is updated (one
constant multiplier per check symbol, which synthesis reduces to XOR networks) and moved to the end of the chain.
During the check symbol phase the registers are shifted out in the same rotation and are empty at the end of the
block, so consecutive blocks need no clearing. After a reset the chain is cleared in _I_ clock cycles, during which
_In_Ready_ is low.

With _DualBasis_g_ > 0 the input symbols are converted to the polynomial basis for the division and the check
symbols back to the dual basis (two constant GF(2) matrices). The data symbols pass unchanged.

### Timing and Throughput

- The output is registered: a symbol appears on _Out_Data_ one clock cycle after it was accepted.
- The entity processes one symbol per clock cycle. The output has no gaps: the check symbols follow the last data
  symbol directly, and the next block can follow the last check symbol directly.
- _In_Ready_ is low while the _I*(n-k)_ check symbols are output, so the data rate at the input is _k/n_ of the clock
  for full blocks. With 8-bit symbols at 200 MHz the output carries 1.6 Gbit/s.
- The entity handles one symbol per beat. Wider streams are converted with
  [olo_base_wconv_n2xn](./olo_base_wconv_n2xn.md) and [olo_base_wconv_xn2n](./olo_base_wconv_xn2n.md) around it.

### Resources

Synthesis result for CCSDS E = 16 with _I_ = 5 (Libero SoC 2025.2, PolarFire SoC MPFS250T, speed grade STD; the
maximum frequency with registered ports after place and route): 799 LUTs, 1318 registers, no RAM, 331 MHz. The
registers are mainly the _I*(n-k)_ symbols of the remainder registers.
