#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Test vectors for tb/ML_DSA_tb.sv, from the FIPS 204 model in mldsa_ref.py
(which passes the NIST ACVP vectors).

  python3 scripts/mldsa/gen_vec.py OUT.hex [N] [ACVP.json ...]

N random cases per parameter set (default 1): a KeyGen; a deterministic and a
hedged Sign of random messages M' (one of them with external mu); a Verify of
each signature; Verify of signatures with a modified c~, z, or hint encoding,
of a modified message, and with external mu. ACVP files given after N (the
keyGen / sigGen / sigVer internalProjection.json) add their first test of
each internal-interface group (Sign: the one with the fewest attempts). One 32-bit word per line:
  header   A5 | ext_mu<<23 | op<<16 | pset<<8 | nseg
  header2  fail<<31 | tries<<16 | mlen       expected fail (Verify) and attempt
                                              count (Sign); mlen of M'
  segment  dir<<31 | pad<<29 | word address<<16 | words, then the data
           (little-endian bytes, zero padded); dir 0 = load before, 1 =
           expect after; pad: bytes of the last word past the field
  end      FFFFFFFF
"""
import json, os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mldsa_ref as m

A_PK, A_SK, A_SIG, A_XI, A_RND, A_MU, A_MSG = 0x0000, 0x0A20, 0x1D40, 0x2F60, 0x2FA0, 0x2FC0, 0x4000
NAMES = ['ML-DSA-44', 'ML-DSA-65', 'ML-DSA-87']


def words(b):
    b = b + bytes(-len(b) % 4)
    return [int.from_bytes(b[i:i + 4], 'little') for i in range(0, len(b), 4)]


def case(out, op, ps, ins, exp, ext=False, fail=False, tries=0, mlen=0):
    segs = [(0, a, b) for a, b in ins] + [(1, a, b) for a, b in exp]
    out.append(0xA5000000 | ext << 23 | op << 16 | ps << 8 | len(segs))
    out.append(fail << 31 | tries << 16 | mlen)
    for d, a, b in segs:
        w = words(b)
        out.append(d << 31 | (-len(b) % 4) << 29 | (a >> 2) << 16 | len(w))
        out += w


def sign_case(out, ps, sk, msg, rnd, mu=None):
    p = m.PARAMS[NAMES[ps]]
    st = {}
    sig = m.sign(sk, msg, rnd, p, mu, st)
    ins = [(A_SK, sk), (A_RND, rnd)] + ([(A_MU, mu)] if mu is not None else [(A_MSG, msg)] if msg else [])
    case(out, 1, ps, ins, [(A_SIG, sig)], ext=mu is not None, tries=st['tries'], mlen=0 if mu is not None else len(msg))
    return sig


def verify_case(out, ps, pk, msg, sig, mu=None):
    p = m.PARAMS[NAMES[ps]]
    ok = m.verify(pk, msg, sig, p, mu)
    ins = [(A_PK, pk), (A_SIG, sig)] + ([(A_MU, mu)] if mu is not None else [(A_MSG, msg)] if msg else [])
    case(out, 2, ps, ins, [], ext=mu is not None, fail=not ok, mlen=0 if mu is not None else len(msg))
    return ok


def attempts(sk, msg, p, rnd=bytes(32)):
    st = {}
    m.sign(sk, msg, rnd, p, None, st)
    return st


def targeted(out, rng, rb, p, pk, sk):
    """ML-DSA-44 Sign cases for the rarer rejections: too many hints, exactly
    omega hints after a row, ||<<c t0>>|| >= gamma2 (a private key whose t0
    row 0 is aligned with the first attempt's c), an empty and the longest
    message, and Verify of hint encodings that set every hint index."""
    om = p['omega']
    for want in ('hints', 'omega'):
        while True:
            msg = rb(rng.randrange(1, 64))
            st = attempts(sk, msg, p)
            hit = any('hints' in w for w in st['why']) if want == 'hints' else \
                any(om in r for r in st['rows'])
            if hit and st['tries'] <= 4:
                break
        sign_case(out, 0, sk, msg, bytes(32))
    # t0: row 0 of sk set so that coefficient 0 of c t0 is 4000 tau; the other rows 0
    e8 = 128 + m.eta_bytes(p) * (p['k'] + p['l'])
    while True:
        msg = rb(rng.randrange(1, 64))
        c = attempts(sk, msg, p)['c'][0]
        t = [0] * 256
        for j in range(256):
            if c[j]:
                v = 4000 * (1 if c[j] == 1 else -1) * (1 if j == 0 else -1)
                t[(256 - j) % 256] = v
        rows = [t] + [[0] * 256 for _ in range(p['k'] - 1)]
        sk2 = sk[:e8] + b''.join(m.bit_pack(r, 4095, 4096) for r in rows)
        st = attempts(sk2, msg, p)
        if 'ct0' in st['why'][0] and st['tries'] <= 4:
            break
    sign_case(out, 0, sk2, msg, bytes(32))
    sign_case(out, 0, sk, b'', bytes(32))
    # the longest M' (16384 bytes), and a Verify of a 12345-byte one
    while True:
        msg = rb(16384)
        if attempts(sk, msg, p)['tries'] <= 2:
            break
    sig = sign_case(out, 0, sk, msg, bytes(32))
    msg = rb(12345)
    assert verify_case(out, 0, pk, msg, m.sign(sk, msg, bytes(32), p))
    # hint encodings that name every index 0..255 (64 per signature, 16 per row)
    hb = p['lam'] // 4 + 32 * m.zbits(p) * p['l']
    for v in range(4):
        y = bytearray(om + p['k'])
        for r in range(p['k']):
            y[16 * r:16 * r + 16] = bytes(range(64 * v + 16 * r, 64 * v + 16 * r + 16))
            y[om + r] = 16 * (r + 1)
        verify_case(out, 0, pk, msg, sig[:hb] + bytes(y))


def main():
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rng = random.Random(204)
    rb = lambda k: bytes(rng.getrandbits(8) for _ in range(k))
    out = []
    for _ in range(n):
        for ps, name in enumerate(NAMES):
            p = m.PARAMS[name]
            xi = rb(32)
            pk, sk = m.keygen(xi, p)
            case(out, 0, ps, [(A_XI, xi)], [(A_PK, pk), (A_SK, sk)])
            # messages whose deterministic signature takes at most two attempts (simulation time)
            while True:
                msg = rb(rng.randrange(0, 300))
                st = {}
                m.sign(sk, msg, bytes(32), p, None, st)
                if st['tries'] <= 2:
                    break
            sig = sign_case(out, ps, sk, msg, bytes(32))
            assert verify_case(out, ps, pk, msg, sig)
            mu = m.H(m.H(pk, 64) + msg, 64)
            while True:
                rnd = rb(32)
                st = {}
                m.sign(sk, None, rnd, p, mu, st)
                if st['tries'] <= 3:
                    break
            sig2 = sign_case(out, ps, sk, None, rnd, mu)
            assert verify_case(out, ps, pk, None, sig2, mu)
            # rejections: c~, z (a coefficient out of range), hints, the message
            cl, zb = p['lam'] // 4, 32 * m.zbits(p)
            bad = bytearray(sig); bad[rng.randrange(cl)] ^= 1 << rng.randrange(8)
            assert not verify_case(out, ps, pk, msg, bytes(bad))
            bad = bytearray(sig); bad[cl + rng.randrange(zb * p['l'])] ^= 0xFF
            assert not verify_case(out, ps, pk, msg, bytes(bad))
            hb = cl + zb * p['l']
            bad = bytearray(sig); bad[hb + p['omega'] + p['k'] - 1] = p['omega'] + 1   # row end beyond omega
            assert not verify_case(out, ps, pk, msg, bytes(bad))
            bad = bytearray(sig); bad[hb + p['omega'] - 1] = 1                        # unused index not zero
            if m.verify(pk, msg, bytes(bad), p):
                bad[hb + p['omega'] - 1] = 0
            verify_case(out, ps, pk, msg, bytes(bad))
            assert not verify_case(out, ps, pk, msg + b'\x00', sig)
            bad = bytearray(sig)                                                       # z[0][0] = gamma1
            bad[cl] = bad[cl + 1] = 0
            bad[cl + 2] &= 0xFC if zb == 576 else 0xF0
            assert not verify_case(out, ps, pk, msg, bytes(bad))
            if ps == 0:
                targeted(out, rng, rb, p, pk, sk)
    for f in sys.argv[3:]:
        for g in json.load(open(f))['testGroups']:
            if g.get('signatureInterface', 'internal') != 'internal':
                continue
            ps = NAMES.index(g['parameterSet'])
            p = m.PARAMS[g['parameterSet']]
            t = g['tests'][0]
            if 'signature' in t and 'testPassed' not in t:     # Sign: the test with the fewest attempts
                def tries(t):
                    st = {}
                    v = lambda key: bytes.fromhex(t[key]) if key in t else None
                    m.sign(v('sk'), v('message'), v('rnd') or bytes(32), p, v('mu'), st)
                    return st['tries']
                t = min(g['tests'], key=tries)
            x = {k: bytes.fromhex(v) for k, v in t.items() if isinstance(v, str) and k not in ('reason', 'hashAlg')}
            mu = x.get('mu')
            if 'seed' in x:
                case(out, 0, ps, [(A_XI, x['seed'])], [(A_PK, x['pk']), (A_SK, x['sk'])])
            elif 'testPassed' in t:
                assert verify_case(out, ps, x['pk'], x.get('message'), x['signature'], mu) == t['testPassed']
            else:
                assert sign_case(out, ps, x['sk'], x.get('message'), x.get('rnd', bytes(32)), mu) == x['signature']
    out.append(0xFFFFFFFF)
    with open(path, 'w') as fh:
        fh.write(''.join(f'{w:08x}\n' for w in out))
    print(f'{path}: {len(out)} words')


if __name__ == '__main__':
    main()
