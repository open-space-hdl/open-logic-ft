# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Description
# ---------------------------------------------------------------------------------------------------
# Parameters of a Reed-Solomon code as used by olo_base_rs_encode and olo_base_rs_decode, and the rules for
# blocks (interleaving, shortening) that both share.

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
from math import gcd

from .olo_base_rs_gf import OloBaseRsGf


# ---------------------------------------------------------------------------------------------------
# Classes
# ---------------------------------------------------------------------------------------------------
class OloBaseRsCode:
    """
    Reed-Solomon code with symbol interleaving and an optional dual basis representation of the symbols
    """

    def __init__(self, symbol_width: int, field_polynomial: int, codeword_symbols: int, data_symbols: int,
                 first_root: int = 0, root_step: int = 1, interleave_depth: int = 1, dual_basis: int = 0):
        """
        :param symbol_width: m (bits per symbol)
        :param field_polynomial: m low coefficients of the field polynomial (x^m implicit)
        :param codeword_symbols: n, at most 2^m - 1
        :param data_symbols: k, 1 <= k < n
        :param first_root: b0, the generator has the roots alpha^(b0 + i * root_step), i = 0 ... n - k - 1
        :param root_step: gamma, coprime to 2^m - 1
        :param interleave_depth: I, the number of interleaved codewords of a block
        :param dual_basis: 0 for the polynomial basis at the interfaces, s > 0 for the dual basis of
                           (1, alpha^s, ..., alpha^(s(m-1)))
        """
        self.gf = OloBaseRsGf(symbol_width, field_polynomial)
        if not 1 <= data_symbols < codeword_symbols <= self.gf.order:
            raise ValueError("require 1 <= data_symbols < codeword_symbols <= 2^m - 1")
        if gcd(root_step, self.gf.order) != 1:
            raise ValueError("root_step must be coprime to 2^m - 1")
        if interleave_depth < 1:
            raise ValueError("interleave_depth must be at least 1")
        self.m = symbol_width
        self.n = codeword_symbols
        self.k = data_symbols
        self.nroots = codeword_symbols - data_symbols
        self.t = self.nroots // 2
        self.first_root = first_root
        self.root_step = root_step
        self.depth = interleave_depth
        self.generator = self.gf.rs_generator(self.nroots, first_root, root_step)
        # Root sequence as consecutive powers of beta = alpha^gamma: alpha^(b0 + i gamma) = beta^(j0 + i)
        self.beta = self.gf.alpha_pow(root_step)
        self.j0 = (first_root * pow(root_step, -1, self.gf.order)) % self.gf.order
        if dual_basis:
            self._to_dual, self._from_dual = self.gf.dual_basis(dual_basis)
        else:
            self._to_dual = self._from_dual = None

    # *** Symbol representation at the interfaces ***
    def to_port(self, u: int) -> int:
        """Polynomial basis value to the representation at the interfaces"""
        return self._to_dual[u] if self._to_dual else u

    def from_port(self, z: int) -> int:
        """Representation at the interfaces to the polynomial basis value"""
        return self._from_dual[z] if self._from_dual else z

    # *** Interleaving ***
    def deal(self, symbols: list) -> list:
        """Symbols of a block dealt to the codewords in rotation (symbol i goes to codeword i mod I)"""
        return [symbols[c::self.depth] for c in range(self.depth)]
