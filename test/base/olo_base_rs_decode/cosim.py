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
from olo_base_rs import OloBaseRsEncode, OloBaseRsDecode

# Number of equal full blocks at the start of the sequence (continuous operation)
CONTINUOUS_BLOCKS = 4


# ---------------------------------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------------------------------
def code_args(generics: dict) -> dict:
    """Model parameters from the generics of the RS testbenches"""
    return dict(symbol_width=generics["SymbolWidth_g"], field_polynomial=generics["FieldPolynomial_g"],
                codeword_symbols=generics["CodewordSymbols_g"], data_symbols=generics["DataSymbols_g"],
                first_root=generics.get("FirstRoot_g", 0), root_step=generics.get("RootStep_g", 1),
                interleave_depth=generics.get("InterleaveDepth_g", 1), dual_basis=generics.get("DualBasis_g", 0))


class Block:
    """A received block for the decoder"""

    def __init__(self, enc, rnd, data_len, errors="none", last=True, raw_len=None, raw=None):
        self.last = last
        data = [rnd.randrange(enc.gf.size) for _ in range(data_len)]
        tx = [s for s, _, _ in enc.encode_block(data)] if data_len else []
        if raw_len is not None:  # invalid block: arbitrary symbols of the given length
            tx = [rnd.randrange(enc.gf.size) for _ in range(raw_len)]
        if raw is not None:  # given symbols
            tx = list(raw)
        self.rx = list(tx)
        depth, t = enc.depth, enc.t
        if errors != "none" and self.rx:
            for c in range(depth):
                positions = list(range(c, len(self.rx), depth))
                if errors == "random":
                    count = rnd.randrange(0, t + 1)
                elif errors == "t":
                    count = t
                elif errors == "beyond":
                    count = rnd.choice([t + 1, t + 2, 2 * t, 2 * t + 1])
                else:
                    count = 0
                for s in rnd.sample(positions, min(count, len(positions))):
                    self.rx[s] ^= rnd.randrange(1, enc.gf.size)
            if errors == "burst":
                # A burst of I*t consecutive symbols: t errors in every codeword
                start = rnd.randrange(0, len(self.rx) - depth * t + 1)
                for s in range(start, start + depth * t):
                    self.rx[s] ^= rnd.randrange(1, enc.gf.size)


def failing_block(enc, dec, rnd, kind):
    """
    A block of arbitrary symbols whose codeword 1 fails in a way random errors rarely produce:
    kind "length": L > t (BM register length); kind "degree": deg(Lambda) != L <= t with deg(Lambda) roots in the
    transmitted positions (caught only by the degree check, the decoder must not correct these roots).
    Searched for small fields only (frequent there); None if not found.
    """
    if enc.gf.size > 32:
        return None
    gf, depth = dec.gf, dec.depth
    for _ in range(2000):
        ntx = rnd.randrange(dec.nroots + 1, dec.n + 1)
        raw = [rnd.randrange(gf.size) for _ in range(depth * ntx)]
        word = dec.deal([dec.from_port(z) for z in raw])[0]
        synd = [gf.poly_eval(list(reversed(word)), gf.pow(dec.beta, dec.j0 + i)) for i in range(dec.nroots)]
        lam, length = dec.berlekamp_massey(synd)
        deg = len(lam) - 1
        if kind == "length" and length > dec.t:
            return Block(enc, rnd, 0, raw=raw)
        if kind == "degree" and length <= dec.t and 0 < deg != length:
            roots = sum(1 for u in range(ntx) if gf.poly_eval(lam, gf.inv(gf.pow(dec.beta, ntx - 1 - u))) == 0)
            if roots == deg:
                return Block(enc, rnd, 0, raw=raw)
    return None


def block_plan(enc, dec, rnd) -> list:
    depth, k, n = enc.depth, enc.k, enc.n
    plan = [Block(enc, rnd, depth * k, "random") for _ in range(CONTINUOUS_BLOCKS)]
    plan += [Block(enc, rnd, depth * k, "none"),
             Block(enc, rnd, depth * k, "t"),
             Block(enc, rnd, depth * k, "burst"),
             Block(enc, rnd, depth * k, "random", last=False),
             Block(enc, rnd, depth * rnd.randrange(1, k), "random"),
             Block(enc, rnd, depth, "t"),
             Block(enc, rnd, depth * k, "beyond"),
             Block(enc, rnd, depth * rnd.randrange(1, k), "beyond")]
    for kind in ("length", "degree", "degree"):
        block = failing_block(enc, dec, rnd, kind)
        if block is not None:
            plan += [block]
    # Blocks that are not decoded, each followed by a regular block: too short, and every remainder of a
    # length that is not a multiple of I
    plan += [Block(enc, rnd, 0, raw_len=depth * enc.nroots), Block(enc, rnd, depth * k, "random")]
    for rest in range(1, depth):
        plan += [Block(enc, rnd, 0, raw_len=depth * rnd.randrange(enc.nroots + 1, n) + rest),
                 Block(enc, rnd, depth * rnd.randrange(1, k), "random")]
    plan += [Block(enc, rnd, depth * k, "random")]
    return plan


def cosim(output_path: str = None, generics: dict = None, cosim_mode: bool = True):
    args = code_args(generics)
    enc = OloBaseRsEncode(**args)
    dec = OloBaseRsDecode(**args, output_parity=bool(generics.get("OutputParity_g", False)))
    rnd = random.Random(repr(sorted(generics.items())))
    # dec_in.csv: symbol, In_Last; dec_out.csv: symbol, Out_Parity, Out_Last;
    # dec_status.csv: corrected symbols, uncorrectable, Status_Last, number of blocks with output up to this block
    # dec_hold.csv: output symbols before which the OutputStall test holds Out_Ready low (first symbol of a block and
    # 0 ... 5 symbols before its last one)
    with open(os.path.join(output_path, "dec_in.csv"), "w") as fin, \
         open(os.path.join(output_path, "dec_out.csv"), "w") as fout, \
         open(os.path.join(output_path, "dec_status.csv"), "w") as fstat:
        outputs, beats, holds = 0, 0, []
        for block in block_plan(enc, dec, rnd):
            for i, z in enumerate(block.rx):
                fin.write(f"{z},{int(block.last and i == len(block.rx) - 1)}\n")
            output, status = dec.decode_block(block.rx)
            for symbol, parity, last in output:
                fout.write(f"{symbol},{int(parity)},{int(last)}\n")
            if output:
                holds += [beats, max(beats, beats + len(output) - 1 - outputs % 6)]
                outputs += 1
                beats += len(output)
            for c, (changed, failed) in enumerate(status):
                fstat.write(f"{changed},{int(failed)},{int(c == len(status) - 1)},{outputs}\n")
    with open(os.path.join(output_path, "dec_hold.csv"), "w") as fhold:
        for beat in sorted(set(holds)):
            fhold.write(f"{beat}\n")
    return True


if __name__ == "__main__":
    cosim(os.path.abspath("."), {"SymbolWidth_g": 8, "FieldPolynomial_g": 0x87, "CodewordSymbols_g": 255,
                                 "DataSymbols_g": 223, "FirstRoot_g": 212, "RootStep_g": 11,
                                 "InterleaveDepth_g": 5, "DualBasis_g": 117})
