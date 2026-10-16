# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
import random
import sys
import os
import unittest

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from olo_base_rs import OloBaseRsGf, OloBaseRsCode, OloBaseRsEncode, OloBaseRsDecode

try:
    import reedsolo
except ImportError:  # development dependency only
    reedsolo = None

# Primitive field polynomials (m low coefficients, x^m implicit)
PRIMITIVE = {3: 0x3, 4: 0x3, 5: 0x5, 6: 0x3, 7: 0x3, 8: 0x1D, 9: 0x11, 10: 0x9, 11: 0x5, 12: 0x53}

# CCSDS 131.0-B-5: field x^8 + x^7 + x^2 + x + 1 (4.3.3), roots alpha^(11 j) (4.3.4), dual basis (4.3.9)
CCSDS = dict(symbol_width=8, field_polynomial=0x87, codeword_symbols=255, root_step=11, dual_basis=117)
CCSDS_E16 = dict(CCSDS, data_symbols=223, first_root=212)  # j = 112 ... 143
CCSDS_E8 = dict(CCSDS, data_symbols=239, first_root=45)    # j = 120 ... 135


def ccsds(e16=True, **kwargs):
    return dict(CCSDS_E16 if e16 else CCSDS_E8, **kwargs)


class TestOloBaseRsGf(unittest.TestCase):

    def test_field_axioms(self):
        rnd = random.Random(1)
        for m, poly in PRIMITIVE.items():
            gf = OloBaseRsGf(m, poly)
            self.assertEqual(gf.alpha_pow(gf.order), 1)
            for _ in range(50):
                a, b, c = (rnd.randrange(gf.size) for _ in range(3))
                self.assertEqual(gf.mul(a, b), gf.mul(b, a))
                self.assertEqual(gf.mul(gf.mul(a, b), c), gf.mul(a, gf.mul(b, c)))
                self.assertEqual(gf.mul(a, b ^ c), gf.mul(a, b) ^ gf.mul(a, c))
                if a:
                    self.assertEqual(gf.mul(a, gf.inv(a)), 1)
                    self.assertEqual(gf.alpha_pow(gf.log(a)), a)
                    self.assertEqual(gf.pow(a, -1), gf.inv(a))
                self.assertIn(gf.trace(a), (0, 1))
            self.assertEqual(gf.pow(0, 0), 1)
            self.assertEqual(gf.pow(0, 3), 0)

    def test_invalid(self):
        with self.assertRaises(ValueError):
            OloBaseRsGf(1, 1)
        with self.assertRaises(ValueError):
            OloBaseRsGf(4, 0x10)
        with self.assertRaises(ValueError):
            OloBaseRsGf(4, 0xF)  # x^4 + x^3 + x^2 + x + 1 is irreducible but not primitive
        gf = OloBaseRsGf(4, 0x3)
        with self.assertRaises(ValueError):
            gf.log(0)
        with self.assertRaises(ZeroDivisionError):
            gf.inv(0)
        with self.assertRaises(ZeroDivisionError):
            gf.pow(0, -1)
        with self.assertRaises(ValueError):
            gf.dual_basis(5)  # alpha^5 has order 3 in GF(16), its powers are no basis

    def test_ccsds_dual_basis(self):
        gf = OloBaseRsGf(8, 0x87)
        to_dual, from_dual = gf.dual_basis(117)
        # 4.3.9.3: rows of T are the dual basis representations of alpha^7 ... alpha^0
        rows = [0b10001101, 0b11101111, 0b11101100, 0b10000110, 0b11111010, 0b10011001, 0b10101111, 0b01111011]
        for i, row in enumerate(rows):
            self.assertEqual(to_dual[1 << (7 - i)], row)
        # 4.3.9.3: rows of T^-1 are the polynomial basis representations of l0 ... l7
        rows_inv = [0b11000101, 0b01000010, 0b00101110, 0b11111101, 0b11110000, 0b01111001, 0b10101100, 0b11001100]
        for j, row in enumerate(rows_inv):
            self.assertEqual(from_dual[1 << (7 - j)], row)
        # Annex F, table F-1 (power of alpha: dual basis value) and the examples of F2
        for power, z in [(8, 0b11000000), (31, 0b01111010), (67, 0b00000010), (152, 0b11101000), (213, 0b10111001)]:
            self.assertEqual(to_dual[gf.alpha_pow(power)], z)
        self.assertEqual(to_dual[0], 0)
        self.assertEqual(from_dual[0b10111001], 0b00101010)

    def test_ccsds_generator(self):
        # Annex G: coefficients of g(x) as powers of alpha, symmetric
        for e, first, expected in [(16, 212, [249, 59, 66, 4, 43, 126, 251, 97, 30, 3, 213, 50, 66, 170, 5, 24]),
                                   (8, 45, [30, 230, 49, 235, 129, 81, 76, 173])]:
            gf = OloBaseRsGf(8, 0x87)
            g = gf.rs_generator(2 * e, first, 11)
            self.assertEqual(g[0], 1)
            self.assertEqual(g[2 * e], 1)
            for i, power in enumerate(expected, start=1):
                self.assertEqual(gf.log(g[i]), power)
                self.assertEqual(gf.log(g[2 * e - i]), power)


class TestOloBaseRsCode(unittest.TestCase):

    def test_invalid(self):
        for args in [dict(codeword_symbols=16, data_symbols=11), dict(codeword_symbols=15, data_symbols=15),
                     dict(codeword_symbols=15, data_symbols=0), dict(codeword_symbols=15, data_symbols=11,
                                                                     root_step=3),
                     dict(codeword_symbols=15, data_symbols=11, interleave_depth=0)]:
            with self.assertRaises(ValueError):
                OloBaseRsCode(4, 0x3, **args)
        with self.assertRaises(ValueError):
            OloBaseRsDecode(4, 0x3, 15, 10)  # odd number of check symbols

    def test_roots(self):
        code = OloBaseRsCode(**ccsds())
        self.assertEqual(code.j0, 112)
        for i in range(code.nroots):
            self.assertEqual(code.gf.pow(code.beta, code.j0 + i), code.gf.alpha_pow(11 * (112 + i)))
            self.assertEqual(code.gf.poly_eval(code.generator, code.gf.pow(code.beta, code.j0 + i)), 0)


class TestOloBaseRsEncode(unittest.TestCase):

    def test_interleaving_order(self):
        # 4.4.1: data unchanged, then check symbol 1 of codewords 1 ... I, check symbol 2 of codewords 1 ... I, ...
        rnd = random.Random(2)
        enc = OloBaseRsEncode(**ccsds(interleave_depth=5))
        data = [rnd.randrange(256) for _ in range(5 * 223)]
        out = enc.encode_block(data)
        self.assertEqual(len(out), 5 * 255)
        self.assertEqual([s for s, _, _ in out[:5 * 223]], data)
        self.assertTrue(all(not p for _, p, _ in out[:5 * 223]))
        self.assertTrue(all(p for _, p, _ in out[5 * 223:]))
        self.assertEqual([last for _, _, last in out].index(True), len(out) - 1)
        for c in range(5):
            word = [enc.from_port(d) for d in data[c::5]]
            checks = enc.check_symbols(word)
            self.assertEqual([enc.from_port(s) for s, _, _ in out[5 * 223 + c::5]], checks)

    def test_codewords(self):
        # Every codeword of an encoded block evaluates to zero at all roots
        rnd = random.Random(3)
        for args in [ccsds(interleave_depth=2), ccsds(False), dict(symbol_width=4, field_polynomial=0x3,
                                                                   codeword_symbols=15, data_symbols=9,
                                                                   first_root=3, root_step=2)]:
            enc = OloBaseRsEncode(**args)
            for length in [enc.depth * enc.k, enc.depth * 3]:
                data = [rnd.randrange(enc.gf.size) for _ in range(length)]
                out = [enc.from_port(s) for s, _, _ in enc.encode_block(data)]
                for word in enc.deal(out):
                    for i in range(enc.nroots):
                        self.assertEqual(enc.gf.poly_eval(list(reversed(word)), enc.gf.pow(enc.beta, enc.j0 + i)), 0)

    def test_blocks(self):
        enc = OloBaseRsEncode(4, 0x3, 15, 11, interleave_depth=2)
        self.assertTrue(enc.block_is_valid(22))
        self.assertTrue(enc.block_is_valid(2))
        self.assertFalse(enc.block_is_valid(3))
        self.assertFalse(enc.block_is_valid(24))
        with self.assertRaises(ValueError):
            enc.encode_block([])
        with self.assertRaises(ValueError):
            enc.encode_block([0] * 23)
        # A block that violates the rule still gets the check symbols of every codeword
        data = [1, 2, 3]
        out = enc.encode_block(data)
        self.assertEqual(len(out), 3 + 2 * 4)
        self.assertEqual([s for s, _, _ in out[3::2]], enc.check_symbols([1, 3]))
        self.assertEqual([s for s, _, _ in out[4::2]], enc.check_symbols([2]))


class TestOloBaseRsDecode(unittest.TestCase):

    CONFIGS = [ccsds(interleave_depth=1), ccsds(interleave_depth=2), ccsds(interleave_depth=5),
               ccsds(interleave_depth=8), ccsds(False, interleave_depth=5),
               dict(symbol_width=4, field_polynomial=0x3, codeword_symbols=15, data_symbols=11),
               dict(symbol_width=4, field_polynomial=0x3, codeword_symbols=15, data_symbols=9, first_root=3,
                    root_step=2, interleave_depth=2),
               dict(symbol_width=8, field_polynomial=0x1D, codeword_symbols=204, data_symbols=188),
               dict(symbol_width=5, field_polynomial=0x5, codeword_symbols=31, data_symbols=23, first_root=1,
                    root_step=3, dual_basis=1)]

    def corrupt(self, rnd, code, block, per_codeword):
        rx = list(block)
        for c, nerr in enumerate(per_codeword):
            positions = range(c, len(block), code.depth)
            for s in rnd.sample(list(positions), nerr):
                rx[s] ^= rnd.randrange(1, code.gf.size)
        return rx

    def test_up_to_t_errors(self):
        rnd = random.Random(4)
        for args in self.CONFIGS:
            enc, dec = OloBaseRsEncode(**args), OloBaseRsDecode(**args, output_parity=True)
            for trial in range(6):
                length = enc.depth * rnd.choice([enc.k, 1, rnd.randrange(1, enc.k)])
                data = [rnd.randrange(enc.gf.size) for _ in range(length)]
                block = [s for s, _, _ in enc.encode_block(data)]
                nerr = [rnd.randrange(0, enc.t + 1) for _ in range(enc.depth)]
                out, status = dec.decode_block(self.corrupt(rnd, enc, block, nerr))
                self.assertEqual([s for s, _, _ in out], block)
                self.assertEqual(status, [(e, False) for e in nerr])

    def test_beyond_t(self):
        # Beyond t errors a codeword is flagged, or it is decoded to another codeword (miscorrection)
        rnd = random.Random(5)
        counts = {"flagged": 0, "miscorrected": 0}
        for args in self.CONFIGS[5:7] + self.CONFIGS[0:1]:
            enc, dec = OloBaseRsEncode(**args), OloBaseRsDecode(**args, output_parity=True)
            for trial in range(30):
                data = [rnd.randrange(enc.gf.size) for _ in range(enc.depth * enc.k)]
                block = [s for s, _, _ in enc.encode_block(data)]
                nerr = [rnd.randrange(enc.t + 1, enc.nroots + 3) for _ in range(enc.depth)]
                out, status = dec.decode_block(self.corrupt(rnd, enc, block, nerr))
                words = enc.deal([enc.from_port(s) for s, _, _ in out])
                for word, (changed, failed) in zip(words, status):
                    if failed:
                        counts["flagged"] += 1
                    else:
                        counts["miscorrected"] += 1
                        self.assertLessEqual(changed, enc.t)
                        for i in range(enc.nroots):
                            self.assertEqual(enc.gf.poly_eval(list(reversed(word)),
                                                              enc.gf.pow(enc.beta, enc.j0 + i)), 0)
        self.assertGreater(counts["flagged"], 0)
        self.assertGreater(counts["miscorrected"], 0)

    def test_output_and_invalid_blocks(self):
        dec = OloBaseRsDecode(4, 0x3, 15, 11, interleave_depth=2)
        enc = OloBaseRsEncode(4, 0x3, 15, 11, interleave_depth=2)
        block = [s for s, _, _ in enc.encode_block(list(range(1, 7)))]
        out, status = dec.decode_block(block)
        self.assertEqual(out, [(s, False, i == 5) for i, s in enumerate(block[:6])])
        self.assertEqual(status, [(0, False)] * 2)
        for length in [len(block) - 1, 2 * 4, 2 * 4 + 1]:  # not a multiple of I, no data symbol
            out, status = dec.decode_block(block[:length])
            self.assertEqual(status, [(0, True)] * 2)
            self.assertEqual([s for s, _, _ in out], block[:max(0, length - 8)])
        with self.assertRaises(ValueError):
            dec.decode_block([0] * 31)
        dec_p = OloBaseRsDecode(4, 0x3, 15, 11, interleave_depth=2, output_parity=True)
        out, status = dec_p.decode_block(block[:7])
        self.assertEqual(out, [(s, i >= 0, i == 6) for i, s in enumerate(block[:7])])

    def test_multiple_root(self):
        # A locator with a multiple root gives the error value zero: uncorrectable
        dec = OloBaseRsDecode(4, 0x3, 15, 11)
        gf = dec.gf
        # Received word whose syndromes are those of the locator (1 + x)^2 = 1 + x^2 (L = 2, deg 2)
        found = False
        rnd = random.Random(6)
        for _ in range(4000):
            word = [rnd.randrange(16) for _ in range(15)]
            synd = [gf.poly_eval(list(reversed(word)), gf.pow(dec.beta, dec.j0 + i)) for i in range(4)]
            lam, length = dec.berlekamp_massey(synd)
            if length == 2 and lam == [1, 0, gf.mul(lam[2], 1)] and lam[1] == 0:
                _, changed, failed = dec.decode_codeword(word)
                self.assertTrue(failed)
                found = True
                break
        self.assertTrue(found)


@unittest.skipIf(reedsolo is None, "reedsolo not installed (development dependency)")
class TestOloBaseRsReedsolo(unittest.TestCase):

    def test_against_reedsolo(self):
        rnd = random.Random(7)
        for m, poly, n, k, first, step in [(8, 0x1D, 255, 223, 0, 1), (8, 0x1D, 255, 239, 1, 1),
                                           (8, 0x87, 255, 223, 212, 11), (4, 0x3, 15, 11, 0, 1),
                                           (4, 0x3, 15, 9, 3, 2), (6, 0x3, 63, 53, 5, 5)]:
            enc = OloBaseRsEncode(m, poly, n, k, first_root=first, root_step=step)
            dec = OloBaseRsDecode(m, poly, n, k, first_root=first, root_step=step)
            codec = reedsolo.RSCodec(n - k, nsize=n, fcr=enc.j0, prim=poly | (1 << m),
                                     generator=enc.beta, c_exp=m)
            for length in [k, k // 2]:
                data = [rnd.randrange(1 << m) for _ in range(length)]
                ours = [s for s, _, _ in enc.encode_block(data)]
                theirs = list(codec.encode(data))
                self.assertEqual(ours, theirs)
                rx = list(ours)
                for s in rnd.sample(range(len(rx)), enc.t):
                    rx[s] ^= rnd.randrange(1, 1 << m)
                msg, _, _ = codec.decode(rx)
                out, status = dec.decode_block(rx)
                self.assertEqual([s for s, _, _ in out], list(msg))
                self.assertEqual(status, [(enc.t, False)])


if __name__ == "__main__":
    unittest.main()
