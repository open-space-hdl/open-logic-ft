# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Description
# ---------------------------------------------------------------------------------------------------
# Reference model of olo_base_rs_encode: systematic Reed-Solomon encoding of blocks of I interleaved codewords,
# shortened blocks (virtual fill) and the dual basis option (CCSDS 131.0-B-5 4.3.7, 4.3.9, 4.4.1).
#
# The check symbols are the remainder of d(x) * x^(n-k) divided by g(x), computed by polynomial division.

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
from .olo_base_rs_code import OloBaseRsCode


# ---------------------------------------------------------------------------------------------------
# Classes
# ---------------------------------------------------------------------------------------------------
class OloBaseRsEncode(OloBaseRsCode):
    """
    Model of olo_base_rs_encode (same parameters as OloBaseRsCode)
    """

    def check_symbols(self, data: list) -> list:
        """
        Check symbols of one codeword
        :param data: data symbols in the polynomial basis, in transmission order (first = highest power)
        :return: n - k check symbols in transmission order
        """
        gf = self.gf
        # Dividend d(x) * x^(n-k), coefficients from the highest power down
        rem = list(data) + [0] * self.nroots
        g_desc = list(reversed(self.generator))  # g_desc[0] = 1 (highest power)
        for i in range(len(data)):
            q = rem[i]
            if q:
                for j in range(1, len(g_desc)):
                    rem[i + j] ^= gf.mul(q, g_desc[j])
        return rem[len(data):]

    def block_is_valid(self, length: int) -> bool:
        """A block of data symbols is valid when its length is a multiple of I and at most I * k (4.3.7.3)"""
        return 1 <= length <= self.depth * self.k and length % self.depth == 0

    def encode_block(self, data: list) -> list:
        """
        Encode one block
        :param data: data symbols of the block in the representation at the interfaces, 1 ... I * k symbols
        :return: list of (symbol, is_check_symbol, is_last) as olo_base_rs_encode outputs them: the data unchanged,
                 then the I * (n - k) check symbols (first check symbol of codewords 1 ... I, then the second, ...)

        A block whose length is not a multiple of I is not a valid codeblock. It is still ended in a defined way: every
        codeword gets the check symbols of the data it received (the codewords after the last symbol received one
        symbol fewer), output in the same order.
        """
        if not 1 <= len(data) <= self.depth * self.k:
            raise ValueError("a block has 1 ... I * k data symbols")
        words = self.deal([self.from_port(d) for d in data])
        checks = [self.check_symbols(w) for w in words]
        out = [(d, False, False) for d in data]
        for i in range(self.nroots):
            for c in range(self.depth):
                out.append((self.to_port(checks[c][i]), True, False))
        out[-1] = (out[-1][0], True, True)
        return out
