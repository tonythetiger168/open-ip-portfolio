#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""ML-KEM (FIPS 203) reference model, written from the standard, used as the
golden model of the ML-KEM IP. Run directly to check it against the NIST
ACVP vectors (key generation, encapsulation, decapsulation, key checks):
  python3 scripts/mlkem/mlkem_ref.py keyGen.json encapDecap.json
"""
import hashlib, json, sys

N, Q, ZETA = 256, 3329, 17
PARAMS = {  # k, eta1, eta2, du, dv
    'ML-KEM-512': (2, 3, 2, 10, 4),
    'ML-KEM-768': (3, 2, 2, 10, 4),
    'ML-KEM-1024': (4, 2, 2, 11, 5),
}


def bitrev7(i):
    return int(f'{i:07b}'[::-1], 2)


ZETAS = [pow(ZETA, bitrev7(i), Q) for i in range(128)]
GAMMAS = [pow(ZETA, 2 * bitrev7(i) + 1, Q) for i in range(128)]


# ---- hash functions (FIPS 203 4.1)
def G(b):
    h = hashlib.sha3_512(b).digest()
    return h[:32], h[32:]


def H(b):
    return hashlib.sha3_256(b).digest()


def J(b):
    return hashlib.shake_256(b).digest(32)


def PRF(eta, s, b):
    return hashlib.shake_256(s + bytes([b])).digest(64 * eta)


# ---- encoding (4.2.1)
def byte_encode(f, d):
    bits = 0
    for i, a in enumerate(f):
        bits |= (a % (Q if d == 12 else 1 << d)) << (d * i)
    return bits.to_bytes(32 * d, 'little')


def byte_decode(b, d):
    v = int.from_bytes(b, 'little')
    m = Q if d == 12 else 1 << d
    return [((v >> (d * i)) & ((1 << d) - 1)) % m for i in range(N)]


def compress(x, d):
    return ((x << d) + Q // 2) // Q % (1 << d)


def decompress(y, d):
    return (y * Q + (1 << (d - 1))) >> d


# ---- sampling (4.2.2)
def sample_ntt(seed):
    xof = hashlib.shake_128(seed).digest(840 * 3)  # far more than ever needed
    a, i = [], 0
    while len(a) < N:
        c0, c1, c2 = xof[i], xof[i + 1], xof[i + 2]
        i += 3
        d1 = c0 + 256 * (c1 % 16)
        d2 = c1 // 16 + 16 * c2
        if d1 < Q:
            a.append(d1)
        if d2 < Q and len(a) < N:
            a.append(d2)
    return a


def sample_cbd(b, eta):
    bits = int.from_bytes(b, 'little')
    f = []
    for i in range(N):
        x = sum((bits >> (2 * i * eta + j)) & 1 for j in range(eta))
        y = sum((bits >> (2 * i * eta + eta + j)) & 1 for j in range(eta))
        f.append((x - y) % Q)
    return f


# ---- NTT (4.3)
def ntt(f):
    f = list(f)
    k, ln = 1, 128
    while ln >= 2:
        for start in range(0, N, 2 * ln):
            z = ZETAS[k]
            k += 1
            for j in range(start, start + ln):
                t = z * f[j + ln] % Q
                f[j + ln] = (f[j] - t) % Q
                f[j] = (f[j] + t) % Q
        ln //= 2
    return f


def intt(f):
    f = list(f)
    k, ln = 127, 2
    while ln <= 128:
        for start in range(0, N, 2 * ln):
            z = ZETAS[k]
            k -= 1
            for j in range(start, start + ln):
                t = f[j]
                f[j] = (t + f[j + ln]) % Q
                f[j + ln] = z * (f[j + ln] - t) % Q
        ln *= 2
    return [x * 3303 % Q for x in f]


def mul_ntt(f, g):
    h = [0] * N
    for i in range(128):
        a0, a1, b0, b1 = f[2 * i], f[2 * i + 1], g[2 * i], g[2 * i + 1]
        h[2 * i] = (a0 * b0 + a1 * b1 * GAMMAS[i]) % Q
        h[2 * i + 1] = (a0 * b1 + a1 * b0) % Q
    return h


def add(f, g):
    return [(a + b) % Q for a, b in zip(f, g)]


def sub(f, g):
    return [(a - b) % Q for a, b in zip(f, g)]


def matrix(rho, k):
    """A_hat[i][j] = SampleNTT(rho || j || i)"""
    return [[sample_ntt(rho + bytes([j, i])) for j in range(k)] for i in range(k)]


# ---- K-PKE (5)
def pke_keygen(d, p):
    k, eta1 = p[0], p[1]
    rho, sigma = G(d + bytes([k]))
    a = matrix(rho, k)
    s = [ntt(sample_cbd(PRF(eta1, sigma, i), eta1)) for i in range(k)]
    e = [ntt(sample_cbd(PRF(eta1, sigma, k + i), eta1)) for i in range(k)]
    t = []
    for i in range(k):
        acc = e[i]
        for j in range(k):
            acc = add(acc, mul_ntt(a[i][j], s[j]))
        t.append(acc)
    ek = b''.join(byte_encode(x, 12) for x in t) + rho
    dk = b''.join(byte_encode(x, 12) for x in s)
    return ek, dk


def pke_encrypt(ek, m, r, p):
    k, eta1, eta2, du, dv = p
    t = [byte_decode(ek[384 * i:384 * (i + 1)], 12) for i in range(k)]
    rho = ek[384 * k:]
    a = matrix(rho, k)
    y = [ntt(sample_cbd(PRF(eta1, r, i), eta1)) for i in range(k)]
    e1 = [sample_cbd(PRF(eta2, r, k + i), eta2) for i in range(k)]
    e2 = sample_cbd(PRF(eta2, r, 2 * k), eta2)
    u = []
    for i in range(k):
        acc = [0] * N
        for j in range(k):
            acc = add(acc, mul_ntt(a[j][i], y[j]))  # A transposed
        u.append(add(intt(acc), e1[i]))
    mu = [decompress(b, 1) for b in byte_decode(m, 1)]
    acc = [0] * N
    for i in range(k):
        acc = add(acc, mul_ntt(t[i], y[i]))
    v = add(add(intt(acc), e2), mu)
    c1 = b''.join(byte_encode([compress(x, du) for x in ui], du) for ui in u)
    c2 = byte_encode([compress(x, dv) for x in v], dv)
    return c1 + c2


def pke_decrypt(dk, c, p):
    k, _, _, du, dv = p
    u = [[decompress(x, du) for x in byte_decode(c[32 * du * i:32 * du * (i + 1)], du)] for i in range(k)]
    v = [decompress(x, dv) for x in byte_decode(c[32 * du * k:], dv)]
    s = [byte_decode(dk[384 * i:384 * (i + 1)], 12) for i in range(k)]
    acc = [0] * N
    for i in range(k):
        acc = add(acc, mul_ntt(s[i], ntt(u[i])))
    w = sub(v, intt(acc))
    return byte_encode([compress(x, 1) for x in w], 1)


# ---- ML-KEM (6)
def keygen(d, z, p):
    ek, dkp = pke_keygen(d, p)
    return ek, dkp + ek + H(ek) + z


def encaps(ek, m, p):
    key, r = G(m + H(ek))
    return key, pke_encrypt(ek, m, r, p)


def decaps(dk, c, p):
    k = p[0]
    dkp, ek, h, z = dk[:384 * k], dk[384 * k:768 * k + 32], dk[768 * k + 32:768 * k + 64], dk[768 * k + 64:]
    m = pke_decrypt(dkp, c, p)
    key, r = G(m + h)
    kbar = J(z + c)
    return key if pke_encrypt(ek, m, r, p) == c else kbar


def ek_check(ek, p):
    k = p[0]
    if len(ek) != 384 * k + 32:
        return False
    return all(byte_encode(byte_decode(ek[384 * i:384 * (i + 1)], 12), 12) == ek[384 * i:384 * (i + 1)] for i in range(k))


def dk_check(dk, p):
    k = p[0]
    if len(dk) != 768 * k + 96:
        return False
    return H(dk[384 * k:768 * k + 32]) == dk[768 * k + 32:768 * k + 64]


def acvp(paths):
    ok = bad = 0
    for path in paths:
        for g in json.load(open(path))['testGroups']:
            p = PARAMS[g['parameterSet']]
            fn = g.get('function', 'keyGen')
            for t in g['tests']:
                x = {k: bytes.fromhex(v) for k, v in t.items() if isinstance(v, str) and k != 'reason'}
                if fn == 'keyGen':
                    good = keygen(x['d'], x['z'], p) == (x['ek'], x['dk'])
                elif fn == 'encapsulation':
                    good = encaps(x['ek'], x['m'], p) == (x['k'], x['c'])
                elif fn == 'decapsulation':
                    good = decaps(x['dk'], x['c'], p) == x['k']
                elif fn == 'encapsulationKeyCheck':
                    good = ek_check(x['ek'], p) == t['testPassed']
                else:
                    good = dk_check(x['dk'], p) == t['testPassed']
                if good:
                    ok += 1
                else:
                    bad += 1
                    print(f"FAIL {path} {g['parameterSet']} {fn} tc {t['tcId']}")
    print(f"ACVP: {ok} passed, {bad} failed")
    return bad == 0


if __name__ == '__main__':
    sys.exit(0 if acvp(sys.argv[1:]) else 1)
