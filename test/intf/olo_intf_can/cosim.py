# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
import os
import random

# ---------------------------------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------------------------------
# Reference bit streams of CAN 2.0 data and remote frames (Bosch CAN Specification 2.0 part B, sections 3.2.1,
# 3.2.2 and 6), written independently of the RTL: destuffed fields, CRC-15, bit stuffing, fixed-form tail.
# Bits are bus levels: 0 = dominant, 1 = recessive.

MAX_BITS = 180  # longest frame: 118 destuffed bits + 29 stuff bits + 10 fixed-form bits, padded
CRC_POLY = 0x4599


def bits_of(value: int, width: int) -> list:
    return [(value >> (width - 1 - i)) & 1 for i in range(width)]


def crc15(bits: list) -> int:
    crc = 0
    for b in bits:
        nxt = b ^ ((crc >> 14) & 1)
        crc = (crc << 1) & 0x7FFF
        if nxt:
            crc ^= CRC_POLY
    return crc


def stuff(bits: list) -> tuple:
    """Stuffed stream and the index of its first stuff bit (-1 if none)"""
    out, run, last, first = [], 0, None, -1
    for b in bits:
        out.append(b)
        run = run + 1 if b == last else 1
        last = b
        if run == 5:
            if first < 0:
                first = len(out)
            out.append(1 - b)
            run, last = 1, 1 - b
    return out, first


def destuffed(can_id: int, ide: int, rtr: int, dlc: int, data: list, reserved: int = 0) -> list:
    """
    SOF to the end of the data field (can_id: 29 bits, a standard identifier in bits 28 to 18); reserved: level of the
    reserved bits r1 and r0 (sent dominant, accepted at both levels by receivers, section 3.2.1)
    """
    bits = [0] + bits_of(can_id >> 18, 11)
    if ide:
        bits += [1, 1] + bits_of(can_id & 0x3FFFF, 18) + [rtr, reserved, reserved]
    else:
        bits += [rtr, 0, reserved]
    bits += bits_of(dlc, 4)
    if not rtr:
        for byte in data[:min(dlc, 8)]:
            bits += bits_of(byte, 8)
    return bits


def frame_stream(can_id: int, ide: int, rtr: int, dlc: int, data: list, crc_flip: int = -1,
                 reserved: int = 0) -> tuple:
    """
    Bus bits from SOF to the end of EOF with a dominant (acknowledged) ACK slot, the ACK slot index and the index of
    the first stuff bit. crc_flip >= 0 inverts that CRC bit (a frame with a CRC error, stuffed as sent).
    """
    bits = destuffed(can_id, ide, rtr, dlc, data, reserved)
    crc = crc15(bits)
    if crc_flip >= 0:
        crc ^= 1 << (14 - crc_flip)
    stream, first = stuff(bits + bits_of(crc, 15))
    ack = len(stream) + 1
    stream += [1, 0, 1] + [1] * 7  # CRC delimiter, ACK slot, ACK delimiter, EOF
    return stream, ack, first


def frame_list(rnd: random.Random) -> list:
    """(can_id, ide, rtr, dlc, data); the bench refers to the first entries by index"""
    frames = []
    pattern = [0x5A, 0xC3, 0x0F, 0xF0, 0x81, 0x7E, 0x00, 0xFF]
    # 0..8: standard data frames DLC 0..8
    for dlc in range(9):
        frames.append((0x123 << 18, 0, 0, dlc, pattern))
    # 9..17: extended data frames DLC 0..8
    for dlc in range(9):
        frames.append((0x0ABCDEF5, 1, 0, dlc, pattern))
    # 18..20: standard remote frames, 21..22: extended remote frames
    frames += [(0x456 << 18, 0, 1, 0, []), (0x456 << 18, 0, 1, 4, []), (0x456 << 18, 0, 1, 8, [])]
    frames += [(0x1555AAAA, 1, 1, 0, []), (0x1555AAAA, 1, 1, 8, [])]
    # 23..29: DLC 9..15 (8 data bytes)
    for dlc in range(9, 16):
        frames.append((0x2A5 << 18, 0, 0, dlc, pattern[::-1]))
    # 30..35: many stuff bits (long runs in identifier, data and CRC)
    frames += [(0x000, 0, 0, 8, [0x00] * 8), (0x7EF << 18, 0, 0, 8, [0xFF] * 8), (0x0000000, 1, 0, 8, [0x00] * 8),
               (0x1FBFFFFF, 1, 0, 8, [0xFF] * 8), (0x001 << 18, 0, 0, 1, [0x1F]), (0x0F0 << 18, 0, 0, 2, [0xE0, 0x7C])]
    # 36..63: random frames
    for _ in range(28):
        ide = rnd.randrange(2)
        can_id = rnd.randrange(1 << 29) if ide else rnd.randrange(0x7F0) << 18
        rtr = int(rnd.random() < 0.15)
        dlc = rnd.randrange(16) if rnd.random() < 0.1 else rnd.randrange(9)
        frames.append((can_id, ide, rtr, dlc, [rnd.randrange(256) for _ in range(8)]))
    return frames


def write_csv(path: str, rows: list):
    with open(path, "w") as f:
        for (can_id, ide, rtr, dlc, data), (stream, ack, first) in rows:
            data8 = (list(data) + [0] * 8)[:8] if not rtr else [0] * 8
            if not rtr:
                data8 = [b if i < min(dlc, 8) else 0 for i, b in enumerate(data8)]
            assert len(stream) <= MAX_BITS
            cols = [can_id, ide, rtr, dlc] + data8 + [len(stream), ack, first] + stream + [1] * (MAX_BITS - len(stream))
            f.write(",".join(str(c) for c in cols) + "\n")


def cosim(output_path: str = None, generics: dict = None, cosim_mode: bool = True):
    """
    frames.csv: id, ide, rtr, dlc, data bytes 0 to 7, number of bits, ACK slot index, first stuff bit index, bits
    crcerr.csv: the same frames with the CRC bit (index of the frame mod 15) inverted
    reserved.csv: the same frames with recessive reserved bits
    """
    # Self check of the model: CRC-15/CAN check value of the CRC catalogue ("123456789" -> 0x059E)
    assert crc15([b for ch in b"123456789" for b in bits_of(ch, 8)]) == 0x059E
    rnd = random.Random(2026)
    frames = frame_list(rnd)
    write_csv(os.path.join(output_path, "frames.csv"), [(f, frame_stream(*f)) for f in frames])
    write_csv(os.path.join(output_path, "crcerr.csv"),
              [(f, frame_stream(*f, crc_flip=i % 15)) for i, f in enumerate(frames)])
    write_csv(os.path.join(output_path, "reserved.csv"), [(f, frame_stream(*f, reserved=1)) for f in frames])
    return True


if __name__ == "__main__":
    cosim(os.path.abspath("."))
