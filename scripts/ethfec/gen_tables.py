#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Writes the constant tables of rtl/Ethernet_RS_FEC_top.sv (the block
between the GENERATED TABLES markers) from the reference model rs_ref.py.

Every multiplication by a constant in the datapath is a linear map over
GF(2), so each one is a table of row masks: output bit o is the XOR of the
input bits selected by row o ([NIN o +: NIN]). Symbol s of a vector is at
[10 s +: 10].

  M_SQ1 / M_SQ2 / M_SQ4   x^2, x^4, x^16 (for the inversion a^1022)
  M_ENC   {beat (32 symbols), r (30)} -> r x^32 + sum_k m_k x^(61-k) mod g
  M_ENCL  {m0, m1, r}                 -> r x^2 + m0 x^31 + m1 x^30 mod g
  M_SYN   {beat, S (30)}              -> S_j a^32j + sum_k c_k a^j(31-k)
  M_LE / M_LO / M_LAM
          {r_0..r_15}                 -> for k = 0..31 the even / odd / all
                                         terms of sum_i r_i a^ik
  M_W     {w_0..w_14}                 -> for k = 0..31 sum_i w_i a^(i+30)k
  M_UPL / M_UPW   r_i a^32i, w_i a^32(i+30)          (next beat)
  M_SCL / M_SCW   r_i a^-543i, w_i a^-543(i+30)      (symbol 0 of beat 0)

  python3 scripts/ethfec/gen_tables.py          # rewrite the RTL block
  python3 scripts/ethfec/gen_tables.py --check  # exit 1 if it is stale
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rs_ref import EXP, G, NSYM, mul, pw   # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RTL = os.path.join(ROOT, "rtl", "Ethernet_RS_FEC_top.sv")
BEGIN, END = "  // ---- BEGIN GENERATED TABLES", "  // ---- END GENERATED TABLES"


def xmod(e):
    """x^e mod g(x) as 30 coefficients, lowest degree first."""
    r = [0] * NSYM
    r[0] = 1
    for _ in range(e):
        top = r[NSYM - 1]                    # multiply by x, reduce x^30
        r = [0] + r[:NSYM - 1]
        if top:
            for j in range(NSYM):            # x^30 = sum_j G[30 - j] x^j (char 2)
                r[j] ^= mul(top, G[NSYM - j])
    return r


def packed(name, nbits, v):
    """A localparam as a concatenation of 384-bit hex chunks."""
    first = nbits % 384 or 384
    chunks = [first] + [384] * ((nbits - first) // 384)
    out, sh = [], nbits
    for w in chunks:
        sh -= w
        out.append(f"{w}'h{(v >> sh) & ((1 << w) - 1):0{(w + 3) // 4}x}")
    body = ",\n    ".join(out)
    return f"  localparam logic [{nbits - 1}:0] {name} = {{\n    {body}}};\n"


def syms(v, n):
    return [(v >> (10 * i)) & 1023 for i in range(n)]


def vec(ss):
    v = 0
    for i, x in enumerate(ss):
        v |= x << (10 * i)
    return v


def matrix(name, nin, nout, f):
    """Row masks of the GF(2)-linear map f (bit vector -> bit vector)."""
    cols = [f(1 << j) for j in range(nin)]
    v = 0
    for o in range(nout):
        row = 0
        for j in range(nin):
            if (cols[j] >> o) & 1:
                row |= 1 << j
        v |= row << (nin * o)
    return f"  // {name}: {nout} rows of {nin} bits\n" + packed(name, nin * nout, v)


def a(e):
    return EXP[e % 1023]


def block():
    pm = [xmod(e) for e in range(62)]

    def enc(n):
        def f(v):
            s = syms(v, 30 + n)
            r, m = s[:30], s[30:]
            out = [0] * 30
            for i in range(30):
                for j in range(30):
                    out[j] ^= mul(r[i], pm[i + n][j])
            for k in range(n):
                for j in range(30):
                    out[j] ^= mul(m[k], pm[n - 1 - k + 30][j])
            return vec(out)
        return f

    def syn(v):
        s = syms(v, 62)
        S, c = s[:30], s[30:]
        return vec([mul(S[j], a(32 * j)) ^ _xs(mul(c[k], a(j * (31 - k))) for k in range(32)) for j in range(30)])

    def ev(sel, off, n):
        def f(v):
            r = syms(v, n)
            return vec([_xs(mul(r[i], a((i + off) * k)) for i in range(n) if sel(i)) for k in range(32)])
        return f

    def scale(n, off, e):
        def f(v):
            r = syms(v, n)
            return vec([mul(r[i], a(e * (i + off))) for i in range(n)])
        return f

    out = [BEGIN + " (scripts/ethfec/gen_tables.py; do not edit by hand)\n"]
    for n, e in (("M_SQ1", 2), ("M_SQ2", 4), ("M_SQ4", 16)):
        out.append(matrix(n, 10, 10, lambda v, e=e: pw(v, e)))
    out.append(matrix("M_ENC", 620, 300, enc(32)))
    out.append(matrix("M_ENCL", 320, 300, enc(2)))
    out.append(matrix("M_SYN", 620, 300, syn))
    out.append(matrix("M_LAM", 160, 320, ev(lambda i: True, 0, 16)))
    out.append(matrix("M_LE", 160, 320, ev(lambda i: i % 2 == 0, 0, 16)))
    out.append(matrix("M_LO", 160, 320, ev(lambda i: i % 2 == 1, 0, 16)))
    out.append(matrix("M_W", 150, 320, ev(lambda i: True, 30, 15)))
    out.append(matrix("M_UPL", 160, 160, scale(16, 0, 32)))
    out.append(matrix("M_UPW", 150, 150, scale(15, 30, 32)))
    out.append(matrix("M_SCL", 160, 160, scale(16, 0, 1023 - 543)))
    out.append(matrix("M_SCW", 150, 150, scale(15, 30, 1023 - 543)))
    out.append(END + "\n")
    return "".join(out)


def _xs(it):
    x = 0
    for y in it:
        x ^= y
    return x


def main():
    s = open(RTL).read()
    a_, b_ = s.index(BEGIN), s.index(END)
    b_ = s.index("\n", b_) + 1
    new = s[:a_] + block() + s[b_:]
    if "--check" in sys.argv:
        if new != s:
            print("gen_tables: rtl/Ethernet_RS_FEC_top.sv tables are stale")
            sys.exit(1)
        print("gen_tables: up to date")
        return
    open(RTL, "w").write(new)


if __name__ == "__main__":
    main()
