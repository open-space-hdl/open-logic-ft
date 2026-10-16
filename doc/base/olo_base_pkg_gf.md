<img src="../Logo.png" alt="Logo" width="400">

# olo_base_pkg_gf

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_base_pkg_gf.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_base_pkg_gf.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_base_pkg_gf.json?cacheSeconds=0)

VHDL Source: [olo_base_pkg_gf](../../src/base/vhdl/olo_base_pkg_gf.vhd)

## Description

This package contains the arithmetic of the Galois field GF(2^m) used by
[olo_base_rs_encode](./olo_base_rs_encode.md) and [olo_base_rs_decode](./olo_base_rs_decode.md). It is usable for other
codes over GF(2^m) as well.

- **Elements** are _std_logic_vector(m-1 downto 0)_ in the polynomial basis: bit _i_ is the coefficient of
  _alpha^i_, where _alpha_ is a root of the field polynomial.
- **The field polynomial** is passed as _fieldPolynomial_: its _m_ low coefficients, the coefficient of _x^m_ is
  implicit. _x^8 + x^7 + x^2 + x + 1_ (the field of CCSDS 131.0-B-5) is _x"87"_, _x^8 + x^4 + x^3 + x^2 + 1_ is
  _x"1D"_. The width _m_ is the length of the vector. The polynomial must be primitive for _alpha_ to generate the
  field (see _gfIsPrimitive()_).
- **Functions working on vectors** are synthesizable. A multiplication with one constant operand reduces to an XOR
  network.
- **Functions ending in _Int_** work on element values given as _natural_ and are meant for constants computed at
  elaboration. Tables and code polynomials are returned as _IntegerArray_t_ from
  [olo_base_pkg_array](./olo_base_pkg_array.md).

The functions loop over the elements of the field at elaboration; they are written for _m_ up to 12 (4096 elements).

## Definitions

None

## Functions on Vectors

### gfMult()

Product of two field elements (polynomial multiplication modulo the field polynomial).

```vhdl
function gfMult(a, b, fieldPolynomial : std_logic_vector) return std_logic_vector;
```

### gfAlphaPow()

_alpha^e_ for any integer _e_ (negative exponents give the inverse powers).

```vhdl
function gfAlphaPow(e : integer; fieldPolynomial : std_logic_vector) return std_logic_vector;
```

### gfPow()

_a^e_ for _e_ >= 0 (square and multiply).

```vhdl
function gfPow(a : std_logic_vector; e : natural; fieldPolynomial : std_logic_vector) return std_logic_vector;
```

### gfInv()

Multiplicative inverse _a^(2^m-2)_. The inverse of zero is returned as zero. For a non-constant operand a table
lookup (_gfInvTable()_ as a ROM) is usually smaller than this function in hardware.

```vhdl
function gfInv(a, fieldPolynomial : std_logic_vector) return std_logic_vector;
```

### gfMatMult()

Product of a constant GF(2) matrix with a vector: the XOR of _matrix(i)_ over all bits _i_ of _x_ that are set.
Used with _gfDualBasisMatrix()_ and _gfDualBasisMatrixInv()_ for the conversion between bases.

```vhdl
function gfMatMult(matrix : IntegerArray_t; x : std_logic_vector) return std_logic_vector;
```

## Functions on Element Values (Elaboration)

| Function | Result |
| :------- | :----- |
| `gfAddInt(a, b)` | _a + b_ (bitwise XOR) |
| `gfMultInt(a, b, fieldPolynomial)` | _a * b_ |
| `gfAlphaPowInt(e, fieldPolynomial)` | _alpha^e_ for any integer _e_ |
| `gfPowInt(a, e, fieldPolynomial)` | _a^e_ for any integer _e_ (_0^0_ = 1, a negative power of zero is returned as zero) |
| `gfInvInt(a, fieldPolynomial)` | Inverse of _a_ (zero for zero) |
| `gfLogInt(a, fieldPolynomial)` | Logarithm to the base _alpha_ (zero for zero) |
| `gfTraceInt(a, fieldPolynomial)` | Trace _a + a^2 + a^4 + ... + a^(2^(m-1))_, 0 or 1 |
| `gfIsPrimitive(fieldPolynomial)` | True if _alpha_ generates all _2^m-1_ non-zero elements |

## Tables and Code Polynomials (Elaboration)

### gfAntilogTable(), gfLogTable(), gfInvTable()

_gfAntilogTable()_ returns _alpha^i_ for _i_ = 0 ... _2^m-2_. _gfLogTable()_ and _gfInvTable()_ return the logarithm
and the inverse for _a_ = 0 ... _2^m-1_ (entry 0 is zero). Assigned to a constant they are inferred as ROMs.

```vhdl
function gfAntilogTable(fieldPolynomial : std_logic_vector) return IntegerArray_t;
function gfLogTable(fieldPolynomial : std_logic_vector) return IntegerArray_t;
function gfInvTable(fieldPolynomial : std_logic_vector) return IntegerArray_t;
```

### gfRsGenerator()

Generator polynomial of a Reed-Solomon code with _roots_ check symbols:

`g(x) = (x + alpha^b0) (x + alpha^(b0 + gamma)) ... (x + alpha^(b0 + (roots-1) gamma))`

with the first root exponent _b0_ = _firstRoot_ and the root step _gamma_ = _rootStep_. The result holds the
coefficients _g_0_ ... _g_roots_ (_g_roots_ = 1).

```vhdl
function gfRsGenerator(fieldPolynomial : std_logic_vector;
                       roots : positive; firstRoot : natural; rootStep : positive) return IntegerArray_t;
```

Example: the code of CCSDS 131.0-B-5 4.3.4 with _E_ = 16 has the roots _alpha^(11 j)_, _j_ = 112 ... 143, so
_gfRsGenerator(x"87", 32, 212, 11)_ (_11 * 112 mod 255 = 212_); with _E_ = 8, _gfRsGenerator(x"87", 16, 45, 11)_.

### gfDualBasisMatrix(), gfDualBasisMatrixInv()

Conversion matrices between the polynomial basis and the dual basis of _(1, b, b^2, ..., b^(m-1))_ with
_b = alpha^exponent_. The dual basis coefficients of an element _u_ are _z_j = Tr(u * b^j)_, and the dual basis value
holds _z_0_ in its most significant bit. Entry _i_ of _gfDualBasisMatrix()_ is the dual basis value of _alpha^i_;
entry _j_ of _gfDualBasisMatrixInv()_ is the polynomial basis value whose dual basis value is _2^j_. Both are applied
with _gfMatMult()_. If the powers of _b_ are no basis, the inverse function stops the elaboration with a failure.

```vhdl
function gfDualBasisMatrix(fieldPolynomial : std_logic_vector; exponent : positive) return IntegerArray_t;
function gfDualBasisMatrixInv(fieldPolynomial : std_logic_vector; exponent : positive) return IntegerArray_t;
```

CCSDS 131.0-B-5 4.3.9 uses the field _x"87"_ and _exponent_ = 117: _gfDualBasisMatrix(x"87", 117)_ holds the rows
of the matrix _T_ given there (entry _i_ is the row of _alpha^i_), _gfDualBasisMatrixInv(x"87", 117)_ the rows of its
inverse.
