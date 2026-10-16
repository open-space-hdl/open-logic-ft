# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Description
# ---------------------------------------------------------------------------------------------------
# Reference model of the Galois field GF(2^m) used by olo_base_rs_encode and olo_base_rs_decode.
#
# Elements are integers in the polynomial basis: bit i is the coefficient of alpha^i, where alpha is a root of the
# field polynomial. The field polynomial is given as in the VHDL generic FieldPolynomial_g: its m low coefficients,
# the coefficient of x^m is implicit.
#
# The model is written from the definitions (polynomial multiplication modulo the field polynomial, the trace, the
# dual basis), not from the VHDL implementation.

# ---------------------------------------------------------------------------------------------------
# Classes
# ---------------------------------------------------------------------------------------------------
class OloBaseRsGf:
    """
    GF(2^m) in the polynomial basis
    """

    def __init__(self, symbol_width: int, field_polynomial: int):
        """
        :param symbol_width: m, number of bits of a field element (3 ... 12 for the VHDL entities)
        :param field_polynomial: the m low coefficients of the field polynomial (x^m implicit), e.g. 0x87 for
                                 x^8 + x^7 + x^2 + x + 1
        """
        if symbol_width < 2 or symbol_width > 16:
            raise ValueError("symbol_width must be 2 ... 16")
        if field_polynomial < 0 or field_polynomial >= (1 << symbol_width):
            raise ValueError("field_polynomial must have symbol_width bits (x^m is implicit)")
        self.m = symbol_width
        self.size = 1 << symbol_width
        self.order = self.size - 1
        self._poly = field_polynomial | (1 << symbol_width)
        # Powers of alpha by repeated multiplication with x
        self._exp = []
        x = 1
        for _ in range(self.order):
            self._exp.append(x)
            x = self.mul(x, 2)
        if x != 1 or len(set(self._exp)) != self.order:
            raise ValueError("field polynomial is not primitive")
        self._log = {v: i for i, v in enumerate(self._exp)}

    def mul(self, a: int, b: int) -> int:
        """Product of two field elements (polynomial multiplication modulo the field polynomial)"""
        r = 0
        while b:
            if b & 1:
                r ^= a
            b >>= 1
            a <<= 1
            if a & self.size:
                a ^= self._poly
        return r

    def alpha_pow(self, e: int) -> int:
        """alpha^e for any integer e"""
        return self._exp[e % self.order]

    def log(self, a: int) -> int:
        """Discrete logarithm to the base alpha (a must not be zero)"""
        if a == 0:
            raise ValueError("log of zero")
        return self._log[a]

    def pow(self, a: int, e: int) -> int:
        """a^e for any integer e (0^0 = 1, 0^e = 0 for e > 0)"""
        if a == 0:
            if e < 0:
                raise ZeroDivisionError("negative power of zero")
            return 1 if e == 0 else 0
        return self._exp[(self._log[a] * e) % self.order]

    def inv(self, a: int) -> int:
        """Multiplicative inverse"""
        if a == 0:
            raise ZeroDivisionError("inverse of zero")
        return self.pow(a, self.order - 1)

    def trace(self, a: int) -> int:
        """Tr(a) = a + a^2 + a^4 + ... + a^(2^(m-1)), 0 or 1"""
        t, y = 0, a
        for _ in range(self.m):
            t ^= y
            y = self.mul(y, y)
        return t

    def poly_eval(self, p: list, x: int) -> int:
        """Value of the polynomial p (p[i] = coefficient of x^i) at x"""
        r = 0
        for c in reversed(p):
            r = self.mul(r, x) ^ c
        return r

    def poly_mul(self, a: list, b: list) -> list:
        """Product of two polynomials (coefficient lists, index = power)"""
        r = [0] * (len(a) + len(b) - 1)
        for i, ca in enumerate(a):
            for j, cb in enumerate(b):
                r[i + j] ^= self.mul(ca, cb)
        return r

    def rs_generator(self, roots: int, first_root: int, root_step: int) -> list:
        """
        Generator polynomial g(x) = prod_{i=0}^{roots-1} (x - alpha^(first_root + i * root_step))
        :return: coefficients g[0] ... g[roots] (g[roots] = 1)
        """
        g = [1]
        for i in range(roots):
            g = self.poly_mul(g, [self.alpha_pow(first_root + i * root_step), 1])
        return g

    def dual_basis(self, exponent: int) -> tuple:
        """
        Conversion between the polynomial basis and the dual basis of (1, b, b^2, ..., b^(m-1)) with b = alpha^exponent
        (CCSDS 131.0-B-5 4.3.9: exponent 117).

        The dual basis coefficients of an element u are z_j = Tr(u * b^j) (trace duality). A dual basis value is an
        integer with z_0 as its most significant bit (z_0 is transmitted first in CCSDS).

        :return: (to_dual, from_dual) as lists indexed by the element value
        """
        b = self.alpha_pow(exponent)
        powers = [self.pow(b, j) for j in range(self.m)]
        to_dual = []
        for u in range(self.size):
            z = 0
            for j in range(self.m):
                z = (z << 1) | self.trace(self.mul(u, powers[j]))
            to_dual.append(z)
        if len(set(to_dual)) != self.size:
            raise ValueError("(1, b, ..., b^(m-1)) is not a basis for this exponent")
        from_dual = [0] * self.size
        for u, z in enumerate(to_dual):
            from_dual[z] = u
        return to_dual, from_dual
