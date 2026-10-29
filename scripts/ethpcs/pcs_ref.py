#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reference model of the 400GBASE-R PCS data path around the RS(544,514)
FEC (IEEE 802.3 clause 119): 256B/257B transcoding (119.2.4.2, the rules of
91.5.2.5), the 58-bit self-synchronizing scrambler 1 + x^39 + x^58
(119.2.4.3), alignment marker insertion (119.2.4.4.2: 16 markers of 120
bits, 10-bit interleaved, a 133-bit PRBS9 pad and 3 status bits), pre-FEC
distribution into two messages (119.2.4.5), RS(544,514) encoding (119.2.4.6,
scripts/ethfec/rs_ref.py) and the 10-bit symbol distribution of the two
codewords (119.2.4.7); and the receive direction.

Every bit vector is a Python int whose bit 0 is the first bit transmitted.
A 66-bit block has its sync header in bits 1:0 (data: bit 0 = 0, bit 1 = 1;
control: bit 0 = 1, bit 1 = 0) and its payload in bits 65:2; the block type
field of a control block is bits 9:2.

  python3 scripts/ethpcs/pcs_ref.py     # self-test
"""
import os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ethfec"))
from rs_ref import decode, encode  # noqa: E402

M64 = (1 << 64) - 1
SH_DATA, SH_CTRL, SH_ERR = 0b10, 0b01, 0b11      # bits 1:0 of a 66-bit block
# block types of the 64B/66B code used at 40G and above (clause 82), keyed by
# the first nibble sent (bits 3:0), which is all 256B/257B keeps of the first
# control block
BTF = {0xE: 0x1E, 0x8: 0x78, 0xB: 0x4B, 0x7: 0x87, 0x9: 0x99, 0xA: 0xAA,
       0x4: 0xB4, 0xC: 0xCC, 0x2: 0xD2, 0x1: 0xE1, 0xF: 0xFF}

# Table 119-2: {CM0, CM1, CM2, UP0, CM3, CM4, CM5, UP1, UM0, UM1, UM2, UP2, UM3, UM4, UM5}
AM_TABLE = [
    [0x9A, 0x4A, 0x26, 0xB6, 0x65, 0xB5, 0xD9, 0xD9, 0x01, 0x71, 0xF3, 0x26, 0xFE, 0x8E, 0x0C],
    [0x9A, 0x4A, 0x26, 0x04, 0x65, 0xB5, 0xD9, 0x67, 0x5A, 0xDE, 0x7E, 0x98, 0xA5, 0x21, 0x81],
    [0x9A, 0x4A, 0x26, 0x46, 0x65, 0xB5, 0xD9, 0xFE, 0x3E, 0xF3, 0x56, 0x01, 0xC1, 0x0C, 0xA9],
    [0x9A, 0x4A, 0x26, 0x5A, 0x65, 0xB5, 0xD9, 0x84, 0x86, 0x80, 0xD0, 0x7B, 0x79, 0x7F, 0x2F],
    [0x9A, 0x4A, 0x26, 0xE1, 0x65, 0xB5, 0xD9, 0x19, 0x2A, 0x51, 0xF2, 0xE6, 0xD5, 0xAE, 0x0D],
    [0x9A, 0x4A, 0x26, 0xF2, 0x65, 0xB5, 0xD9, 0x4E, 0x12, 0x4F, 0xD1, 0xB1, 0xED, 0xB0, 0x2E],
    [0x9A, 0x4A, 0x26, 0x3D, 0x65, 0xB5, 0xD9, 0xEE, 0x42, 0x9C, 0xA1, 0x11, 0xBD, 0x63, 0x5E],
    [0x9A, 0x4A, 0x26, 0x22, 0x65, 0xB5, 0xD9, 0x32, 0xD6, 0x76, 0x5B, 0xCD, 0x29, 0x89, 0xA4],
    [0x9A, 0x4A, 0x26, 0x60, 0x65, 0xB5, 0xD9, 0x9F, 0xE1, 0x73, 0x75, 0x60, 0x1E, 0x8C, 0x8A],
    [0x9A, 0x4A, 0x26, 0x6B, 0x65, 0xB5, 0xD9, 0xA2, 0x71, 0xC4, 0x3C, 0x5D, 0x8E, 0x3B, 0xC3],
    [0x9A, 0x4A, 0x26, 0xFA, 0x65, 0xB5, 0xD9, 0x04, 0x95, 0xEB, 0xD8, 0xFB, 0x6A, 0x14, 0x27],
    [0x9A, 0x4A, 0x26, 0x6C, 0x65, 0xB5, 0xD9, 0x71, 0x22, 0x66, 0x38, 0x8E, 0xDD, 0x99, 0xC7],
    [0x9A, 0x4A, 0x26, 0x18, 0x65, 0xB5, 0xD9, 0x5B, 0xA2, 0xF6, 0x95, 0xA4, 0x5D, 0x09, 0x6A],
    [0x9A, 0x4A, 0x26, 0x14, 0x65, 0xB5, 0xD9, 0xCC, 0x31, 0x97, 0xC3, 0x33, 0xCE, 0x68, 0x3C],
    [0x9A, 0x4A, 0x26, 0xD0, 0x65, 0xB5, 0xD9, 0xB1, 0xCA, 0xFB, 0xA6, 0x4E, 0x35, 0x04, 0x59],
    [0x9A, 0x4A, 0x26, 0xB4, 0x65, 0xB5, 0xD9, 0x56, 0xA6, 0xBA, 0x79, 0xA9, 0x59, 0x45, 0x86],
]
NBLK = 40                 # 257-bit blocks per pair of FEC messages
AMBLK = 8                 # of which the alignment marker group takes 8
PAIR_BITS = NBLK * 257    # 10280 = 2 x 514 x 10


def bits(v, lo, n):
    return (v >> lo) & ((1 << n) - 1)


def am_x(x):
    """am_x<119:0>: octet i of the table at bits 8i+7:8i (sent LSB first)."""
    return sum(b << (8 * i) for i, b in enumerate(AM_TABLE[x]))


def am_mapped_fixed():
    """am_mapped<1919:0>: the 16 markers, 10-bit interleaved (119.2.4.4.2)."""
    am = [am_x(x) for x in range(16)]
    v = 0
    for k in range(12):
        for j in range(8):
            a, b = (am[2 * j], am[2 * j + 1]) if k % 2 == 0 else (am[2 * j + 1], am[2 * j])
            v |= bits(a, 10 * k, 10) << (160 * k + 20 * j)
            v |= bits(b, 10 * k, 10) << (160 * k + 20 * j + 10)
    return v


AM_FIXED = am_mapped_fixed()


class Prbs9:
    """Free-running PRBS9 x^9 + x^5 + 1 for the pad: b[n] = b[n-9] ^ b[n-5];
    the state holds the last 9 bits, the newest in bit 0. Reset: all ones."""
    def __init__(self):
        self.s = 0x1FF

    def take(self, n):
        v = 0
        for i in range(n):
            b = ((self.s >> 8) ^ (self.s >> 4)) & 1
            self.s = ((self.s << 1) | b) & 0x1FF
            v |= b << i
        return v


def am_group(prbs, sf):
    return AM_FIXED | (prbs.take(133) << 1920) | ((sf & 7) << 2053)


def transcode(blocks):
    """tx_xcoded<256:0> from four 66-bit blocks (j = 0 first)."""
    sh = [b & 3 for b in blocks]
    pay = sum((b >> 2) << (64 * j) for j, b in enumerate(blocks))
    if all(s == SH_DATA for s in sh):
        return 1 | (pay << 1)
    if all(s in (SH_DATA, SH_CTRL) for s in sh):
        c = next(j for j in range(4) if sh[j] == SH_CTRL)
        mask = sum(((sh[j] >> 1) & 1) << j for j in range(4))
    else:                                    # an invalid sync header: all flags 1
        c, mask = 0, 0xF
    lo = bits(pay, 0, 64 * c + 4)
    hi = pay >> (64 * c + 8)
    return (mask << 1) | (lo << 5) | (hi << (64 * c + 9))


def rev_transcode(x):
    """Four 66-bit blocks from rx_xcoded; an invalid block (flags all 1 with
    header 0, or an unknown first block type nibble) gives four blocks with
    sync header 11 and the payload bits as received."""
    if x & 1:
        return [SH_DATA | (bits(x, 1 + 64 * j, 64) << 2) for j in range(4)], False
    mask = bits(x, 1, 4)
    if mask == 0xF:
        pay = x >> 5
        return [SH_ERR | (bits(pay, 64 * j, 64) << 2) for j in range(4)], True
    c = next(j for j in range(4) if not (mask >> j) & 1)
    nib = bits(x, 5 + 64 * c, 4)
    lo = bits(x, 5, 64 * c + 4)
    hi = x >> (64 * c + 9)
    bad = nib not in BTF
    pay = lo | ((BTF.get(nib, 0) >> 4) << (64 * c + 4)) | (hi << (64 * c + 8))
    out = []
    for j in range(4):
        sh = SH_ERR if bad else (SH_DATA if (mask >> j) & 1 else SH_CTRL)
        out.append(sh | (bits(pay, 64 * j, 64) << 2))
    return out, bad


class Scrambler:
    """1 + x^39 + x^58, self-synchronizing: out[n] = in[n] ^ out[n-39] ^ out[n-58].
    hist holds the last 58 line bits (scrambled), the newest in bit 57.
    Reset: all ones."""
    def __init__(self):
        self.h = (1 << 58) - 1

    def scramble(self, v, n=257):
        o = 0
        for i in range(n):
            b = ((v >> i) ^ (self.h >> 19) ^ self.h) & 1     # h bit 19 = out[n-39], bit 0 = out[n-58]
            o |= b << i
            self.h = (self.h >> 1) | (b << 57)
        return o

    def descramble(self, v, n=257):
        o = 0
        for i in range(n):
            b = (v >> i) & 1
            o |= ((b ^ (self.h >> 19) ^ self.h) & 1) << i
            self.h = (self.h >> 1) | (b << 57)
        return o


def split(pair):
    """Pre-FEC distribution: pmA<513-i> = bits 20i+9:20i, pmB the next 10.
    Returned in transmit order (message symbol m_513 first)."""
    a = [bits(pair, 20 * i, 10) for i in range(514)]
    b = [bits(pair, 20 * i + 10, 10) for i in range(514)]
    return a, b


def interleave(ca, cb):
    """Symbol distribution (119.2.4.7): tx_out, 1088 symbols in transmit order
    (tx_out<n> goes to PCS lane n mod 16). ca / cb in transmit order (c<543> first)."""
    out = [0] * 1088
    for k in range(68):
        for j in range(8):
            p, q = (ca, cb) if k % 2 == 0 else (cb, ca)
            out[16 * k + 2 * j] = p[8 * k + j]
            out[16 * k + 2 * j + 1] = q[8 * k + j]
    return out


def deinterleave(out):
    ca, cb = [0] * 544, [0] * 544
    for k in range(68):
        for j in range(8):
            p, q = (ca, cb) if k % 2 == 0 else (cb, ca)
            p[8 * k + j] = out[16 * k + 2 * j]
            q[8 * k + j] = out[16 * k + 2 * j + 1]
    return ca, cb


class Tx:
    def __init__(self, amp):
        self.amp, self.pc = amp, 0
        self.scr, self.prbs = Scrambler(), Prbs9()

    def pair(self, groups, sf=0, am=None):
        """One pair of codewords: groups (32 or 40 lists of four 66-bit
        blocks; 32 when this pair carries the marker group) -> tx_out symbols."""
        blks = []
        if self.pc == 0 if am is None else am:     # am: force the marker group in or out ("bad0": in, damaged)
            g = am_group(self.prbs, sf)
            if am == "bad0":                       # lane 0 marker damaged: block 0 only
                g ^= 1 << 5
            blks = [bits(g, 257 * i, 257) for i in range(AMBLK)]
        assert len(groups) == NBLK - len(blks)
        # a group may also be ("raw", x): a 257-bit block given as is (before scrambling)
        blks += [self.scr.scramble(g[1] if g[0] == "raw" else transcode(g)) for g in groups]
        self.pc = (self.pc + 1) % self.amp
        pair = sum(b << (257 * i) for i, b in enumerate(blks))
        a, b = split(pair)
        return interleave(encode(a), encode(b))


class Rx:
    """Receive: deinterleave, decode, merge, marker check and removal,
    descramble, reverse transcode. lock: a marker group was found at the
    start of a pair; until then nothing comes out. Locked, the group is
    expected every amp pairs and removed; three missing in a row drop lock."""
    def __init__(self, amp):
        self.amp, self.lock, self.pc, self.miss, self.sf = amp, False, 0, 0, 0
        self.dsc = Scrambler()

    def pair(self, syms):
        ca, cb = deinterleave(syms)
        da, _ = decode(ca)
        db, _ = decode(cb)
        bad = da is None or db is None
        da, db = da or ca, db or cb
        pair = 0
        for i in range(514):
            pair |= (da[i] << (20 * i)) | (db[i] << (20 * i + 10))
        blks = [bits(pair, 257 * i, 257) for i in range(NBLK)]
        grp = sum(b << (257 * i) for i, b in enumerate(blks[:AMBLK]))
        found = bits(grp, 0, 1920) == AM_FIXED
        out, ev = [], {"bad": bad, "am_err": False, "found": found, "itb": 0}
        if not self.lock:
            if found:
                self.lock, self.pc, self.miss, self.sf = True, 0, 0, grp >> 2053
                start = AMBLK
            else:
                for b in blks[AMBLK:]:
                    self.dsc.descramble(b)   # keep the history of the line
                return out, ev
        elif self.pc == 0:
            start = AMBLK
            if found:
                self.miss, self.sf = 0, grp >> 2053
            elif not bad:
                ev["am_err"] = True
                self.miss += 1
                if self.miss == 3:
                    self.lock = False
        else:
            start = 0
            if found and not bad:
                ev["am_err"] = True              # a marker group off its period
        self.pc = (self.pc + 1) % self.amp
        if not self.lock:                        # lost at this group: nothing more comes out
            for b in blks[start:]:
                self.dsc.descramble(b)
            return out, ev
        for b in blks[start:]:
            d = self.dsc.descramble(b)
            g, inv = rev_transcode(d)
            ev["itb"] += inv and not bad
            if bad:
                g = [SH_ERR | (x & ~3) for x in g]
            out.append(g)
        return out, ev


# ---------------- self-test ----------------
def rnd_group(rng, p_ctrl=0.3, p_bad=0.0):
    g = []
    for _ in range(4):
        r = rng.random()
        if r < p_bad:
            g.append(rng.choice([0, 3]) | (rng.getrandbits(64) << 2))
        elif r < p_bad + p_ctrl:
            g.append(SH_CTRL | (rng.choice(list(BTF.values())) << 2) | (rng.getrandbits(56) << 10))
        else:
            g.append(SH_DATA | (rng.getrandbits(64) << 2))
    return g


def selftest():
    rng = random.Random(5)
    # transcoding round trip
    for _ in range(3000):
        g = rnd_group(rng, rng.random(), 0.05 if rng.random() < 0.2 else 0)
        x = transcode(g)
        assert x >> 257 == 0
        back, bad = rev_transcode(x)
        valid = all(b & 3 in (SH_DATA, SH_CTRL) for b in g)
        if valid:
            assert back == g and not bad, (g, back)
        else:
            assert bad and all(b & 3 == SH_ERR for b in back)
    # scrambler round trip
    s, d = Scrambler(), Scrambler()
    for _ in range(50):
        v = rng.getrandbits(257)
        assert d.descramble(s.scramble(v)) == v
    # marker fields: the inverted pairs CM3..5 = ~CM0..2, UM3..5 = ~UM0..2, UP2 = ~UP1
    for r in AM_TABLE:
        assert [r[4], r[5], r[6]] == [x ^ 0xFF for x in r[:3]]
        assert [r[12], r[13], r[14]] == [x ^ 0xFF for x in r[8:11]]
        assert r[11] == r[7] ^ 0xFF
    # every lane's PCS-lane symbols carry its own marker: lane x gets tx_out<n>, n mod 16 = x
    tx, rx = Tx(3), Rx(3)
    sent, got = [], []
    for p in range(7):
        n = NBLK - (AMBLK if tx.pc == 0 else 0)
        gs = [rnd_group(rng) for _ in range(n)]
        syms = tx.pair(gs, sf=p & 7)
        if p == 0:
            for x in range(16):
                lane = [syms[16 * m + x] for m in range(12)]
                v = sum(s << (10 * m) for m, s in enumerate(lane))
                assert v == am_x(x), x
        sent += gs
        out, ev = rx.pair(syms)
        assert not ev["bad"] and not ev["am_err"]
        got += out
    assert got == sent
    print("pcs_ref self-test: PASS")


if __name__ == "__main__":
    selftest()
