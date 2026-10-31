#!/usr/bin/env python3
"""Test vectors for tb/ML_KEM_tb.sv, from the FIPS 203 model in mlkem_ref.py
(which passes the NIST ACVP vectors).

  python3 scripts/mlkem/gen_vec.py OUT.hex [N] [ACVP.json ...]

N random cases per parameter set (default 2): a KeyGen, an Encaps with its
key, a Decaps of that ciphertext and a Decaps of a modified one (implicit
rejection). ACVP files given after N are added as well (first 2 tests of
each group). One 32-bit word per line:
  header   A5 | f<<23 | op<<16 | pset<<8 | nseg    f: same clock count as the
                                                    previous Decaps
  segment  dir<<31 | word address<<16 | words, then the data (little-endian
           bytes); dir 0 = load before, 1 = expect after
  end      FFFFFFFF
"""
import json, os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mlkem_ref import PARAMS, keygen, encaps, decaps

A_EK, A_DK, A_C, A_D, A_Z, A_M, A_K = 0x0000, 0x0620, 0x1280, 0x1EC0, 0x1EE0, 0x1F00, 0x1F20
NAMES = ['ML-KEM-512', 'ML-KEM-768', 'ML-KEM-1024']


def words(b):
    assert len(b) % 4 == 0
    return [int.from_bytes(b[i:i + 4], 'little') for i in range(0, len(b), 4)]


def case(out, op, ps, ins, exp, same=False):
    segs = [(0, a, b) for a, b in ins] + [(1, a, b) for a, b in exp]
    out.append(0xA5000000 | same << 23 | op << 16 | ps << 8 | len(segs))
    for d, a, b in segs:
        w = words(b)
        out.append(d << 31 | (a >> 2) << 16 | len(w))
        out += w


def main():
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    rng = random.Random(203)
    rb = lambda k: bytes(rng.getrandbits(8) for _ in range(k))
    out = []
    for _ in range(n):
        for ps, name in enumerate(NAMES):
            p = PARAMS[name]
            d, z, m = rb(32), rb(32), rb(32)
            ek, dk = keygen(d, z, p)
            case(out, 0, ps, [(A_D, d), (A_Z, z)], [(A_EK, ek), (A_DK, dk)])
            k, c = encaps(ek, m, p)
            case(out, 1, ps, [(A_EK, ek), (A_M, m)], [(A_C, c), (A_K, k)])
            case(out, 2, ps, [(A_DK, dk), (A_C, c)], [(A_K, k)])
            bad = bytearray(c)
            bad[rng.randrange(len(c))] ^= 1 << rng.randrange(8)
            kb = decaps(dk, bytes(bad), p)
            assert kb != k
            case(out, 2, ps, [(A_DK, dk), (A_C, bytes(bad))], [(A_K, kb)], same=True)
    for f in sys.argv[3:]:
        for g in json.load(open(f))['testGroups']:
            ps, fn = NAMES.index(g['parameterSet']), g.get('function', 'keyGen')
            for t in g['tests'][:2]:
                x = {k: bytes.fromhex(v) for k, v in t.items() if isinstance(v, str) and k != 'reason'}
                if fn == 'keyGen':
                    case(out, 0, ps, [(A_D, x['d']), (A_Z, x['z'])], [(A_EK, x['ek']), (A_DK, x['dk'])])
                elif fn == 'encapsulation':
                    case(out, 1, ps, [(A_EK, x['ek']), (A_M, x['m'])], [(A_C, x['c']), (A_K, x['k'])])
                elif fn == 'decapsulation':
                    case(out, 2, ps, [(A_DK, x['dk']), (A_C, x['c'])], [(A_K, x['k'])])
    out.append(0xFFFFFFFF)
    with open(path, 'w') as fh:
        fh.write(''.join(f'{w:08x}\n' for w in out))
    print(f'{path}: {len(out)} words')


if __name__ == '__main__':
    main()
