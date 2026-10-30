#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Test vectors for Ethernet_RS_FEC from the reference model rs_ref.py.

  python3 scripts/ethfec/gen_vec.py tb/Ethernet_RS_FEC_vec.hex

One 10-bit symbol per line (3 hex digits). Each case:
  header 0x200 | bad << 4 | nsym
  message (514), codeword (544), received word (544), expected decoder output (544)
and the file ends with 0x3FF. The expected output is rs_ref.decode's
(Berlekamp-Massey, Chien, Forney, then a re-syndrome check), and the RTL's
decision rule (riBM length L <= 15 and L roots found) must agree with it
on every case. The cases: clean codewords, single errors at both ends,
bursts, 1..15 random errors, 15 in the parity, beat boundaries, 16..200
errors, and an uncorrectable word whose riBM length L is above 15.
"""
import os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rs_ref import EXP, K, N, T, decode, encode, inv, mul, pw, ribm, syndromes  # noqa: E402


def rtl_rule(rx):
    """Uncorrectable as the RTL decides it: L > 15, or the roots of Lambda
    among the 544 positions are not L."""
    lam, _, L = ribm(syndromes(rx))
    if L > T:
        return True
    roots = 0
    for pos in range(N):
        xi = inv(EXP[pos % 1023]) if pos else 1
        v = 0
        for i in range(T, -1, -1):
            v = mul(v, xi) ^ lam[i]
        roots += v == 0
    return roots != L


def case(rng, msg, errs):
    """errs: {index: error value}"""
    cw = encode(msg)
    rx = list(cw)
    for p, e in errs.items():
        rx[p] ^= e
    dec, n = decode(rx)
    bad = dec is None
    unc = rtl_rule(rx)
    assert unc == bad, f"RTL rule and reference disagree ({len(errs)} errors)"
    if not bad:
        assert dec == cw and n == len(errs)
    return msg, cw, rx, (rx if bad else dec), bad, (0 if bad else n)


def main():
    out = sys.argv[1]
    rng = random.Random(544)
    rmsg = lambda: [rng.getrandbits(10) for _ in range(K)]
    rerr = lambda idx: {p: rng.randrange(1, 1024) for p in idx}
    cases = [
        case(rng, [0] * K, {}),
        case(rng, [1023] * K, {}),
        case(rng, rmsg(), {0: rng.randrange(1, 1024)}),
        case(rng, rmsg(), {N - 1: 1023}),
        case(rng, rmsg(), rerr(rng.sample(range(512, N), 15))),
        case(rng, rmsg(), {p: 1023 for p in range(100, 115)}),
        case(rng, rmsg(), rerr(rng.sample(range(K, N), 15))),
        case(rng, rmsg(), rerr([31, 32, 63, 64, 511, 512, 513, 514])),
    ]
    for ne in (2, 5, 8, 12, 14, 15, 15, 15, 16, 17, 20, 30, 60, 200):
        cases.append(case(rng, rmsg(), rerr(rng.sample(range(N), ne))))
    # an uncorrectable word with L > 15 (about 1 in 3000 of 16-error words;
    # searched on the syndromes of the error pattern, which are the word's)
    for _ in range(200000):
        errs = rerr(rng.sample(range(N), 16))
        S = [0] * 30
        for p, e in errs.items():
            for j in range(30):
                S[j] ^= mul(e, pw(EXP[j], N - 1 - p))
        if ribm(S)[2] > T:
            cases.append(case(rng, rmsg(), errs))
            break
    else:
        sys.exit("gen_vec: no word with L > 15 found")
    with open(out, "w") as f:
        for msg, cw, rx, exp, bad, n in cases:
            f.write(f"{0x200 | bad << 4 | n:03x}\n")
            for v in msg + cw + rx + exp:
                f.write(f"{v:03x}\n")
        f.write("3ff\n")
    print(f"gen_vec: {len(cases)} cases -> {out}")


if __name__ == "__main__":
    main()
