# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
import os
import random
import sys

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../src/base/python")))
from olo_base_rs import OloBaseRsEncode


# ---------------------------------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------------------------------
def code_args(generics: dict) -> dict:
    """Model parameters from the generics of the RS testbenches"""
    return dict(symbol_width=generics["SymbolWidth_g"], field_polynomial=generics["FieldPolynomial_g"],
                codeword_symbols=generics["CodewordSymbols_g"], data_symbols=generics["DataSymbols_g"],
                first_root=generics.get("FirstRoot_g", 0), root_step=generics.get("RootStep_g", 1),
                interleave_depth=generics.get("InterleaveDepth_g", 1), dual_basis=generics.get("DualBasis_g", 0))


def block_plan(depth: int, k: int, rnd: random.Random) -> list:
    """
    Data block lengths and whether In_Last is set on the last symbol:
    a full block with In_Last, a full block that ends by its length, shortened blocks (multiples of I), the shortest
    block, and for I > 1 a block whose length is not a multiple of I followed by a regular block
    """
    plan = [(depth * k, True), (depth * k, False), (depth * rnd.randrange(1, k + 1), True), (depth, True)]
    # Every remainder of a length that is not a multiple of I, each followed by a regular block
    for rest in range(1, depth):
        plan += [(depth * rnd.randrange(0, min(k, 4)) + rest, True), (depth * rnd.randrange(1, min(k, 4) + 1), True)]
    plan += [(depth * rnd.randrange(1, k + 1), True)]
    return plan


def cosim(output_path: str = None, generics: dict = None, cosim_mode: bool = True):
    enc = OloBaseRsEncode(**code_args(generics))
    rnd = random.Random(repr(sorted(generics.items())))
    # enc_in.csv: symbol, In_Last; enc_out.csv: symbol, Out_Parity, Out_Last;
    # enc_in_as_out.csv: the input symbols as data output (for the reset test)
    with open(os.path.join(output_path, "enc_in.csv"), "w") as fin, \
         open(os.path.join(output_path, "enc_out.csv"), "w") as fout, \
         open(os.path.join(output_path, "enc_in_as_out.csv"), "w") as fpass:
        for length, last in block_plan(enc.depth, enc.k, rnd):
            data = [rnd.randrange(enc.gf.size) for _ in range(length)]
            for i, d in enumerate(data):
                fin.write(f"{d},{int(last and i == length - 1)}\n")
                fpass.write(f"{d},0,0\n")
            for symbol, parity, is_last in enc.encode_block(data):
                fout.write(f"{symbol},{int(parity)},{int(is_last)}\n")
    return True


if __name__ == "__main__":
    out = os.path.abspath(".")
    cosim(out, {"SymbolWidth_g": 8, "FieldPolynomial_g": 0x87, "CodewordSymbols_g": 255, "DataSymbols_g": 223,
                "FirstRoot_g": 212, "RootStep_g": 11, "InterleaveDepth_g": 5, "DualBasis_g": 117})
