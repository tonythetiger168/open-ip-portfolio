#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""ML-DSA (FIPS 204) reference model, written from the standard.

KeyGen_internal, Sign_internal and Verify_internal (Algorithms 6, 7, 8) for
ML-DSA-44, -65 and -87, plus the external ML-DSA.Sign / Verify and
HashML-DSA message formatting (Algorithms 2-5) so the NIST ACVP files can
be checked end to end:

  python3 scripts/mldsa/mldsa_ref.py ACVP.json ...

Each file is a keyGen, sigGen or sigVer internalProjection.json from
usnistgov/ACVP-Server (gen-val/json-files/ML-DSA-*-FIPS204).
"""
import hashlib, json, sys

Q = 8380417
N = 256
D = 13
ZETA = 1753

PARAMS = {
    'ML-DSA-44': dict(k=4, l=4, eta=2, tau=39, lam=128, g1=1 << 17, g2=(Q - 1) // 88, omega=80),
    'ML-DSA-65': dict(k=6, l=5, eta=4, tau=49, lam=192, g1=1 << 19, g2=(Q - 1) // 32, omega=55),
    'ML-DSA-87': dict(k=8, l=7, eta=2, tau=60, lam=256, g1=1 << 19, g2=(Q - 1) // 32, omega=75),
}
for _p in PARAMS.values():
    _p['beta'] = _p['tau'] * _p['eta']


def H(b, n):
    return hashlib.shake_256(b).digest(n)


class Xof:
    """SHAKE stream, squeezed a byte at a time (enough output is precomputed)."""
    def __init__(self, f, b, n=8192):
        self.buf = f(b).digest(n)
        self.pos = 0

    def get(self, n=1):
        r = self.buf[self.pos:self.pos + n]
        self.pos += n
        assert len(r) == n
        return r


def brv8(x):
    return int(f'{x:08b}'[::-1], 2)


ZETAS = [pow(ZETA, brv8(i), Q) for i in range(256)]


def mod_pm(r, a):
    """r mod+- a: the representative in (-a/2, a/2] (a even)."""
    r %= a
    return r - a if r > a // 2 else r


def ntt(w):
    w = list(w)
    m, ln = 0, 128
    while ln >= 1:
        st = 0
        while st < 256:
            m += 1
            z = ZETAS[m]
            for j in range(st, st + ln):
                t = z * w[j + ln] % Q
                w[j + ln] = (w[j] - t) % Q
                w[j] = (w[j] + t) % Q
            st += 2 * ln
        ln //= 2
    return w


def intt(w):
    w = list(w)
    m, ln = 256, 1
    while ln < 256:
        st = 0
        while st < 256:
            m -= 1
            z = Q - ZETAS[m]
            for j in range(st, st + ln):
                t = w[j]
                w[j] = (t + w[j + ln]) % Q
                w[j + ln] = z * (t - w[j + ln]) % Q
            st += 2 * ln
        ln *= 2
    f = 8347681
    return [f * x % Q for x in w]


def pmul(a, b):
    return [x * y % Q for x, y in zip(a, b)]


def padd(a, b):
    return [(x + y) % Q for x, y in zip(a, b)]


def psub(a, b):
    return [(x - y) % Q for x, y in zip(a, b)]


# ---------------- bit packing (Algorithms 9-21) ----------------
def bits_to_bytes(bits):
    out = bytearray((len(bits) + 7) // 8)
    for i, b in enumerate(bits):
        out[i // 8] |= b << (i % 8)
    return bytes(out)


def bytes_to_bits(b):
    return [(x >> i) & 1 for x in b for i in range(8)]


def simple_bit_pack(w, b):
    n = b.bit_length()
    return bits_to_bytes([(x >> i) & 1 for x in w for i in range(n)])


def simple_bit_unpack(v, b):
    n = b.bit_length()
    bits = bytes_to_bits(v)
    return [sum(bits[n * j + i] << i for i in range(n)) for j in range(256)]


def bit_pack(w, a, b):
    n = (a + b).bit_length()
    return bits_to_bytes([((b - mod_pm(x, Q)) >> i) & 1 for x in w for i in range(n)])


def bit_unpack(v, a, b):
    n = (a + b).bit_length()
    bits = bytes_to_bits(v)
    return [b - sum(bits[n * j + i] << i for i in range(n)) for j in range(256)]


def hint_bit_pack(h, p):
    k, om = p['k'], p['omega']
    y = bytearray(om + k)
    idx = 0
    for i in range(k):
        for j in range(256):
            if h[i][j]:
                y[idx] = j
                idx += 1
        y[om + i] = idx
    return bytes(y)


def hint_bit_unpack(y, p):
    k, om = p['k'], p['omega']
    h = [[0] * 256 for _ in range(k)]
    idx = 0
    for i in range(k):
        if y[om + i] < idx or y[om + i] > om:
            return None
        first = idx
        while idx < y[om + i]:
            if idx > first and y[idx - 1] >= y[idx]:
                return None
            h[i][y[idx]] = 1
            idx += 1
    for i in range(idx, om):
        if y[i] != 0:
            return None
    return h


def pk_encode(rho, t1, p):
    return rho + b''.join(simple_bit_pack(t, (1 << 10) - 1) for t in t1)


def pk_decode(pk, p):
    rho = pk[:32]
    t1 = [simple_bit_unpack(pk[32 + 320 * i:32 + 320 * (i + 1)], (1 << 10) - 1) for i in range(p['k'])]
    return rho, t1


def eta_bytes(p):
    return 32 * (2 * p['eta']).bit_length()


def sk_encode(rho, K, tr, s1, s2, t0, p):
    e = p['eta']
    return (rho + K + tr + b''.join(bit_pack(s, e, e) for s in s1) + b''.join(bit_pack(s, e, e) for s in s2)
            + b''.join(bit_pack(t, (1 << (D - 1)) - 1, 1 << (D - 1)) for t in t0))


def sk_decode(sk, p):
    e, eb = p['eta'], eta_bytes(p)
    rho, K, tr = sk[:32], sk[32:64], sk[64:128]
    o = 128
    s1 = [bit_unpack(sk[o + eb * i:o + eb * (i + 1)], e, e) for i in range(p['l'])]
    o += eb * p['l']
    s2 = [bit_unpack(sk[o + eb * i:o + eb * (i + 1)], e, e) for i in range(p['k'])]
    o += eb * p['k']
    t0 = [bit_unpack(sk[o + 416 * i:o + 416 * (i + 1)], (1 << (D - 1)) - 1, 1 << (D - 1)) for i in range(p['k'])]
    return rho, K, tr, s1, s2, t0


def zbits(p):
    return 1 + (p['g1'] - 1).bit_length()


def sig_encode(ct, z, h, p):
    return ct + b''.join(bit_pack(x, p['g1'] - 1, p['g1']) for x in z) + hint_bit_pack(h, p)


def sig_decode(sig, p):
    cl, zb = p['lam'] // 4, 32 * zbits(p)
    ct = sig[:cl]
    z = [bit_unpack(sig[cl + zb * i:cl + zb * (i + 1)], p['g1'] - 1, p['g1']) for i in range(p['l'])]
    h = hint_bit_unpack(sig[cl + zb * p['l']:], p)
    return ct, z, h


def w1_bits(p):
    return ((Q - 1) // (2 * p['g2']) - 1).bit_length()


def w1_encode(w1, p):
    return b''.join(simple_bit_pack(w, (Q - 1) // (2 * p['g2']) - 1) for w in w1)


# ---------------- sampling (Algorithms 29-34) ----------------
def sample_in_ball(rho, p):
    c = [0] * 256
    x = Xof(hashlib.shake_256, rho)
    h = bytes_to_bits(x.get(8))
    tau = p['tau']
    for i in range(256 - tau, 256):
        j = x.get()[0]
        while j > i:
            j = x.get()[0]
        c[i] = c[j]
        c[j] = 1 if h[i + tau - 256] == 0 else Q - 1
    return c


def rej_ntt_poly(rho):
    x = Xof(hashlib.shake_128, rho)
    a = []
    while len(a) < 256:
        b = x.get(3)
        z = b[0] | b[1] << 8 | (b[2] & 0x7F) << 16
        if z < Q:
            a.append(z)
    return a


def coeff_from_half_byte(b, eta):
    if eta == 2 and b < 15:
        return 2 - b % 5
    if eta == 4 and b < 9:
        return 4 - b
    return None


def rej_bounded_poly(rho, eta):
    x = Xof(hashlib.shake_256, rho)
    a = []
    while len(a) < 256:
        z = x.get()[0]
        for v in (z & 15, z >> 4):
            c = coeff_from_half_byte(v, eta)
            if c is not None and len(a) < 256:
                a.append(c % Q)
    return a


def expand_a(rho, p):
    return [[rej_ntt_poly(rho + bytes([s, r])) for s in range(p['l'])] for r in range(p['k'])]


def expand_s(rho, p):
    s1 = [rej_bounded_poly(rho + r.to_bytes(2, 'little'), p['eta']) for r in range(p['l'])]
    s2 = [rej_bounded_poly(rho + (r + p['l']).to_bytes(2, 'little'), p['eta']) for r in range(p['k'])]
    return s1, s2


def expand_mask(rho, mu, p):
    c = zbits(p)
    return [bit_unpack(H(rho + (mu + r).to_bytes(2, 'little'), 32 * c), p['g1'] - 1, p['g1']) for r in range(p['l'])]


# ---------------- rounding (Algorithms 35-40) ----------------
def power2round(r):
    r %= Q
    r0 = mod_pm(r, 1 << D)
    return (r - r0) >> D, r0


def decompose(r, p):
    g2 = p['g2']
    r %= Q
    r0 = mod_pm(r, 2 * g2)
    if r - r0 == Q - 1:
        return 0, r0 - 1
    return (r - r0) // (2 * g2), r0


def high_bits(r, p):
    return decompose(r, p)[0]


def low_bits(r, p):
    return decompose(r, p)[1]


def make_hint(z, r, p):
    return int(high_bits(r, p) != high_bits(r + z, p))


def use_hint(h, r, p):
    m = (Q - 1) // (2 * p['g2'])
    r1, r0 = decompose(r, p)
    if h and r0 > 0:
        return (r1 + 1) % m
    if h and r0 <= 0:
        return (r1 - 1) % m
    return r1


def inf_norm(v):
    """||v||_inf of a vector of polynomials stored mod q."""
    return max(abs(mod_pm(x, Q)) for poly in v for x in poly)


# ---------------- internal algorithms (6, 7, 8) ----------------
def keygen(xi, p):
    k, l = p['k'], p['l']
    hb = H(xi + bytes([k, l]), 128)
    rho, rhop, K = hb[:32], hb[32:96], hb[96:]
    A = expand_a(rho, p)
    s1, s2 = expand_s(rhop, p)
    s1h = [ntt(s) for s in s1]
    t = []
    for r in range(k):
        acc = [0] * 256
        for s in range(l):
            acc = padd(acc, pmul(A[r][s], s1h[s]))
        t.append(padd(intt(acc), s2[r]))
    t1, t0 = [], []
    for poly in t:
        a, b = zip(*(power2round(x) for x in poly))
        t1.append(list(a))
        t0.append(list(b))
    pk = pk_encode(rho, t1, p)
    tr = H(pk, 64)
    sk = sk_encode(rho, K, tr, s1, s2, t0, p)
    return pk, sk


def sign(sk, msg, rnd, p, mu=None, stats=None):
    """Sign_internal(sk, M', rnd); with mu given, M' is not used (external mu)."""
    k, l = p['k'], p['l']
    rho, K, tr, s1, s2, t0 = sk_decode(sk, p)
    s1h = [ntt(s) for s in s1]
    s2h = [ntt(s) for s in s2]
    t0h = [ntt(t) for t in t0]
    A = expand_a(rho, p)
    if mu is None:
        mu = H(tr + msg, 64)
    rhopp = H(K + rnd + mu, 64)
    kappa = 0
    tries = 0
    while True:
        tries += 1
        y = expand_mask(rhopp, kappa, p)
        yh = [ntt(v) for v in y]
        w = []
        for r in range(k):
            acc = [0] * 256
            for s in range(l):
                acc = padd(acc, pmul(A[r][s], yh[s]))
            w.append(intt(acc))
        w1 = [[high_bits(x, p) for x in poly] for poly in w]
        ct = H(mu + w1_encode(w1, p), p['lam'] // 4)
        ch = ntt(sample_in_ball(ct, p))
        cs1 = [intt(pmul(ch, s)) for s in s1h]
        cs2 = [intt(pmul(ch, s)) for s in s2h]
        z = [padd(a, b) for a, b in zip(y, cs1)]
        wm = [psub(a, b) for a, b in zip(w, cs2)]
        r0 = [[low_bits(x, p) for x in poly] for poly in wm]
        kappa += l
        if inf_norm(z) >= p['g1'] - p['beta'] or max(abs(x) for poly in r0 for x in poly) >= p['g2'] - p['beta']:
            continue
        ct0 = [intt(pmul(ch, t)) for t in t0h]
        h = [[make_hint((Q - a) % Q, (b + a) % Q, p) for a, b in zip(pa, pb)] for pa, pb in zip(ct0, wm)]
        if inf_norm(ct0) >= p['g2'] or sum(map(sum, h)) > p['omega']:
            continue
        if stats is not None:
            stats['tries'] = tries
        return sig_encode(ct, z, h, p)


def verify(pk, msg, sig, p, mu=None):
    k, l = p['k'], p['l']
    if len(sig) != sig_len(p) or len(pk) != pk_len(p):
        return False
    rho, t1 = pk_decode(pk, p)
    ct, z, h = sig_decode(sig, p)
    if h is None:
        return False
    A = expand_a(rho, p)
    if mu is None:
        mu = H(H(pk, 64) + msg, 64)
    ch = ntt(sample_in_ball(ct, p))
    zh = [ntt([x % Q for x in v]) for v in z]
    w = []
    for r in range(k):
        acc = [0] * 256
        for s in range(l):
            acc = padd(acc, pmul(A[r][s], zh[s]))
        t = ntt([(x << D) % Q for x in t1[r]])
        w.append(intt(psub(acc, pmul(ch, t))))
    w1 = [[use_hint(hb, x, p) for hb, x in zip(hp, wp)] for hp, wp in zip(h, w)]
    ct2 = H(mu + w1_encode(w1, p), p['lam'] // 4)
    zn = max(abs(x) for v in z for x in v)
    return zn < p['g1'] - p['beta'] and ct == ct2


def pk_len(p):
    return 32 + 320 * p['k']


def sk_len(p):
    return 128 + eta_bytes(p) * (p['k'] + p['l']) + 416 * p['k']


def sig_len(p):
    return p['lam'] // 4 + 32 * zbits(p) * p['l'] + p['omega'] + p['k']


# ---------------- external message formatting (Algorithms 2-5) ----------------
PH = {
    'SHA2-224': ('060960864801650304020' + '4', lambda m: hashlib.sha224(m).digest()),
    'SHA2-256': ('0609608648016503040201', lambda m: hashlib.sha256(m).digest()),
    'SHA2-384': ('0609608648016503040202', lambda m: hashlib.sha384(m).digest()),
    'SHA2-512': ('0609608648016503040203', lambda m: hashlib.sha512(m).digest()),
    'SHA2-512/224': ('0609608648016503040205', lambda m: hashlib.new('sha512_224', m).digest()),
    'SHA2-512/256': ('0609608648016503040206', lambda m: hashlib.new('sha512_256', m).digest()),
    'SHA3-224': ('0609608648016503040207', lambda m: hashlib.sha3_224(m).digest()),
    'SHA3-256': ('0609608648016503040208', lambda m: hashlib.sha3_256(m).digest()),
    'SHA3-384': ('0609608648016503040209', lambda m: hashlib.sha3_384(m).digest()),
    'SHA3-512': ('060960864801650304020A', lambda m: hashlib.sha3_512(m).digest()),
    'SHAKE-128': ('060960864801650304020B', lambda m: hashlib.shake_128(m).digest(32)),
    'SHAKE-256': ('060960864801650304020C', lambda m: hashlib.shake_256(m).digest(64)),
}


def format_msg(msg, ctx, hash_alg):
    """M' for ML-DSA.Sign / Verify (pure) or HashML-DSA (hash_alg given)."""
    if hash_alg in (None, 'none'):
        return bytes([0, len(ctx)]) + ctx + msg
    oid, f = PH[hash_alg]
    return bytes([1, len(ctx)]) + ctx + bytes.fromhex(oid) + f(msg)


# ---------------- ACVP check ----------------
def check_acvp(path):
    j = json.load(open(path))
    ok = bad = 0
    for g in j['testGroups']:
        p = PARAMS[g['parameterSet']]
        for t in g['tests']:
            x = lambda key: bytes.fromhex(t[key])
            if 'seed' in t:
                pk, sk = keygen(x('seed'), p)
                good = pk == x('pk') and sk == x('sk')
            else:
                ext = g.get('signatureInterface') == 'external'
                mu = x('mu') if g.get('externalMu') else None
                msg = None if mu is not None else (format_msg(x('message'), x('context'), t.get('hashAlg'))
                                                   if ext else x('message'))
                if 'testPassed' in t:
                    good = verify(x('pk'), msg, x('signature'), p, mu) == t['testPassed']
                else:
                    rnd = x('rnd') if 'rnd' in t else bytes(32)
                    good = sign(x('sk'), msg, rnd, p, mu) == x('signature')
            ok += good
            bad += not good
            if not good:
                print(f'  FAIL tcId {t["tcId"]}')
    print(f'{path}: {ok} pass, {bad} fail')
    return bad == 0


if __name__ == '__main__':
    sys.exit(0 if all([check_acvp(f) for f in sys.argv[1:]]) else 1)
