#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reference model of the Ethernet RS(544,514) "KP4" FEC (IEEE 802.3 clause
91 / 119 / 172): GF(2^10) with x^10 + x^3 + 1, generator
g(x) = prod_{j=0..29} (x - alpha^j), t = 15 symbol errors.

Codewords are lists of 544 10-bit symbols, first transmitted first: c[0] is
the coefficient of x^543 (message symbol m_513), c[513] of x^30, and
c[514..543] the parity, c[543] the coefficient of x^0.

  encode(msg514) -> codeword
  decode(word544) -> (corrected codeword or None, number of symbols corrected)
  ribm(syndromes)  -> (Lambda, Omega, L) of the riBM the RTL uses
  python3 scripts/ethfec/rs_ref.py   # self-test (and against reedsolo when installed)
"""
import random

M, PRIM, N, K = 10, 0x409, 544, 514
NSYM = N - K
T = NSYM // 2
EXP, LOG = [0] * 2048, [0] * 1024
x = 1
for i in range(1023):
    EXP[i] = x
    LOG[x] = i
    x <<= 1
    if x & 0x400:
        x ^= PRIM
for i in range(1023, 2048):
    EXP[i] = EXP[i - 1023]


def mul(a, b):
    return 0 if a == 0 or b == 0 else EXP[LOG[a] + LOG[b]]


def inv(a):
    return EXP[1023 - LOG[a]]


def pw(a, e):
    return 0 if a == 0 else EXP[(LOG[a] * e) % 1023]


def gen_poly():
    g = [1]                                   # highest degree first
    for j in range(NSYM):
        r = EXP[j]
        out = g + [0]
        for i in range(len(g)):
            out[i + 1] ^= mul(g[i], r)
        g = out
    return g


G = gen_poly()


def encode(msg):
    assert len(msg) == K
    rem = [0] * NSYM
    for s in msg:
        fb = s ^ rem[0]
        rem = rem[1:] + [0]
        if fb:
            for i in range(NSYM):
                rem[i] ^= mul(G[i + 1], fb)
    return list(msg) + rem


def syndromes(c):
    out = []
    for j in range(NSYM):
        a, s = EXP[j], 0
        for v in c:
            s = mul(s, a) ^ v
        out.append(s)
    return out


def decode(c):
    S = syndromes(c)
    if not any(S):
        return list(c), 0
    # Berlekamp-Massey: Lambda(x) lowest degree first
    lam, b = [1] + [0] * NSYM, [1] + [0] * NSYM
    L, m, bb = 0, 1, 1
    for r in range(NSYM):
        d = S[r]
        for i in range(1, L + 1):
            d ^= mul(lam[i], S[r - i])
        if d == 0:
            m += 1
        elif 2 * L <= r:
            tmp = lam[:]
            coef = mul(d, inv(bb))
            for i in range(NSYM + 1 - m):
                lam[i + m] ^= mul(coef, b[i])
            L, b, bb, m = r + 1 - L, tmp, d, 1
        else:
            coef = mul(d, inv(bb))
            for i in range(NSYM + 1 - m):
                lam[i + m] ^= mul(coef, b[i])
            m += 1
    if L > T:
        return None, 0
    # Omega = S(x) Lambda(x) mod x^30
    om = [0] * NSYM
    for i in range(NSYM):
        for j in range(i + 1):
            om[i] ^= mul(S[j], lam[i - j])
    out, n = list(c), 0
    for pos in range(N):                      # pos = degree; index N - 1 - pos
        xi = inv(EXP[pos % 1023]) if pos else 1
        ev = 0
        for i in range(L, -1, -1):
            ev = mul(ev, xi) ^ lam[i]
        if ev:
            continue
        num = 0
        for i in range(NSYM - 1, -1, -1):
            num = mul(num, xi) ^ om[i]
        den = 0                               # Lambda'(x): odd terms
        for i in range(1, L + 1, 2):
            den ^= mul(lam[i], pw(xi, i - 1))
        if den == 0:
            return None, 0
        e = mul(EXP[pos % 1023], mul(num, inv(den)))
        out[N - 1 - pos] ^= e
        n += 1
    if n != L or any(syndromes(out)):
        return None, 0
    return out, n


def ribm(S):
    """Reformulated inversionless Berlekamp-Massey as the RTL runs it:
    (Lambda, Omega, L) with Lambda and Omega lowest degree first (scaled by a
    nonzero factor) and L = (30 - k) / 2 the length of the LFSR."""
    d = [0] * (3 * T + 2)
    th = [0] * (3 * T + 1)
    for i in range(2 * T):
        d[i] = th[i] = S[i]
    d[3 * T] = th[3 * T] = 1
    k, g = 0, 1
    for _ in range(2 * T):
        d0 = d[0]
        nd = [mul(g, d[i + 1]) ^ mul(d0, th[i]) for i in range(3 * T + 1)] + [0]
        if d0 != 0 and k >= 0:
            th, g, k = d[1:3 * T + 2], d0, -k - 1
        else:
            k += 1
        d = nd
    return [d[T + i] for i in range(T + 1)], [d[i] for i in range(T)], (2 * T - k) // 2


def selftest(trials=200, seed=1):
    rng = random.Random(seed)
    try:
        import reedsolo
        rs = reedsolo.RSCodec(nsym=NSYM, nsize=N, c_exp=M, prim=PRIM, generator=2, fcr=0)
    except Exception:
        rs = None
    bad = 0
    for t in range(trials):
        msg = [rng.getrandbits(10) for _ in range(K)]
        cw = encode(msg)
        if any(syndromes(cw)):
            bad += 1
        if rs is not None and list(rs.encode(bytearray(0) if False else msg)) != cw:
            bad += 1
        ne = rng.randrange(0, 20)
        rx = list(cw)
        for p in rng.sample(range(N), ne):
            rx[p] ^= rng.randrange(1, 1024)
        dec, n = decode(rx)
        if ne <= T and (dec != cw or n != ne):
            bad += 1
        if ne > T and dec == cw:
            bad += 1
    print(f"rs_ref selftest: {trials} codewords, {bad} failures" + (" (encoder also checked against reedsolo)" if rs else ""))
    return bad == 0


if __name__ == '__main__':
    import sys
    sys.exit(0 if selftest() else 1)
