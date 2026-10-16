# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Description
# ---------------------------------------------------------------------------------------------------
# Reference model of olo_base_rs_decode: decoding of blocks of I interleaved codewords, shortened blocks and the
# dual basis option.
#
# Algorithm (textbook form, independent of the VHDL implementation): syndromes, Berlekamp-Massey (Massey 1969),
# error locations by evaluating the locator at every transmitted position, error values by the Forney formula.
#
# Decoding result of a codeword, exactly as olo_base_rs_decode produces it:
# - L > t (BM register length) or deg(Lambda) != L: no symbol is changed, the codeword is uncorrectable.
# - Otherwise every transmitted position where Lambda has a root gets its Forney error value added. The codeword is
#   uncorrectable if the number of these roots differs from deg(Lambda) (roots in the virtual fill or outside the code
#   length are never found, a multiple root is found once).
# - The reported count is the number of changed symbols (also for an uncorrectable codeword, whose changes are then
#   not corrections).
# A block whose length is not a multiple of I, or shorter than I * (n - k + 1) symbols, is not decoded: its symbols
# are passed unchanged and every codeword is reported uncorrectable.

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
from .olo_base_rs_code import OloBaseRsCode


# ---------------------------------------------------------------------------------------------------
# Classes
# ---------------------------------------------------------------------------------------------------
class OloBaseRsDecode(OloBaseRsCode):
    """
    Model of olo_base_rs_decode
    """

    def __init__(self, *args, output_parity: bool = False, **kwargs):
        """
        :param output_parity: also output the check symbols (OutputParity_g)
        Other parameters as OloBaseRsCode; n - k must be even.
        """
        super().__init__(*args, **kwargs)
        if self.nroots % 2:
            raise ValueError("the decoder requires an even number of check symbols")
        self.output_parity = output_parity

    def block_is_valid(self, length: int) -> bool:
        """A received block is decoded when its length is a multiple of I, at least I * (n - k + 1) and at most I * n"""
        return length % self.depth == 0 and self.depth * (self.nroots + 1) <= length <= self.depth * self.n

    def berlekamp_massey(self, s: list) -> tuple:
        """
        Berlekamp-Massey algorithm
        :param s: syndromes S_0 ... S_{2t-1}
        :return: (Lambda as coefficient list with Lambda[0] = 1, register length L)
        """
        gf = self.gf
        lam, prev = [1], [1]
        length, shift, prev_disc = 0, 1, 1
        for r in range(len(s)):
            disc = s[r]
            for i in range(1, min(length, len(lam) - 1) + 1):
                disc ^= gf.mul(lam[i], s[r - i])
            if disc == 0:
                shift += 1
                continue
            scale = gf.mul(disc, gf.inv(prev_disc))
            new = lam + [0] * max(0, len(prev) + shift - len(lam))
            for i, c in enumerate(prev):
                new[i + shift] ^= gf.mul(scale, c)
            if 2 * length <= r:
                length, prev, prev_disc, shift = r + 1 - length, lam, disc, 1
            else:
                shift += 1
            lam = new
        while len(lam) > 1 and lam[-1] == 0:
            lam.pop()
        return lam, length

    def decode_codeword(self, received: list) -> tuple:
        """
        Decode one (possibly shortened) codeword
        :param received: symbols in the polynomial basis, transmission order
        :return: (output symbols in the polynomial basis, changed symbols, uncorrectable)
        """
        gf = self.gf
        ntx = len(received)
        # Syndromes S_i = r(beta^(j0 + i)), the first transmitted symbol is the coefficient of x^(ntx-1)
        synd = []
        for i in range(self.nroots):
            synd.append(gf.poly_eval(list(reversed(received)), gf.pow(self.beta, self.j0 + i)))
        lam, length = self.berlekamp_massey(synd)
        deg = len(lam) - 1
        if length > self.t or deg != length:
            return list(received), 0, True
        # Evaluator Omega(x) = S(x) Lambda(x) mod x^2t, derivative Lambda'(x)
        omega = gf.poly_mul(synd, lam)[:self.nroots]
        dlam = [lam[i] if i % 2 else 0 for i in range(1, len(lam))]
        out = list(received)
        roots, changed = 0, 0
        for u in range(ntx):
            x = gf.pow(self.beta, ntx - 1 - u)  # error locator of position u
            xinv = gf.inv(x)
            if gf.poly_eval(lam, xinv) != 0:
                continue
            roots += 1
            # Forney: e = X^(1-j0) Omega(X^-1) / Lambda'(X^-1). A multiple root (Lambda'(X^-1) = 0) gives e = 0 and
            # is found only once, so the codeword fails through the root count. With roots = deg = L <= t an error
            # value is never zero (the syndromes would then have a shorter recurrence than L).
            dval = gf.poly_eval(dlam, xinv)
            e = gf.mul(gf.mul(gf.pow(x, 1 - self.j0), gf.poly_eval(omega, xinv)), gf.inv(dval)) if dval else 0
            if e:
                changed += 1
                out[u] ^= e
        return out, changed, roots != deg

    def decode_block(self, received: list) -> tuple:
        """
        Decode one block
        :param received: transmitted codeblock (data and check symbols) in the representation at the interfaces
        :return: (output, status)
                 output: list of (symbol, is_check_symbol, is_last) as olo_base_rs_decode outputs them (check symbols
                 only with output_parity)
                 status: list of (changed symbols, uncorrectable), one entry per codeword 1 ... I
        """
        length = len(received)
        if not 1 <= length <= self.depth * self.n:
            raise ValueError("a block has 1 ... I * n symbols")
        nchecks = min(length, self.depth * self.nroots)
        if self.block_is_valid(length):
            words = self.deal([self.from_port(z) for z in received])
            results = [self.decode_codeword(w) for w in words]
            symbols = [0] * length
            for c, (word, _, _) in enumerate(results):
                for u, v in enumerate(word):
                    symbols[c + u * self.depth] = self.to_port(v)
            status = [(changed, failed) for _, changed, failed in results]
        else:
            symbols = list(received)
            status = [(0, True)] * self.depth
        output = []
        for s, v in enumerate(symbols):
            is_check = s >= length - nchecks
            if is_check and not self.output_parity:
                continue
            output.append((v, is_check, False))
        if output:
            output[-1] = (output[-1][0], output[-1][1], True)
        return output, status
