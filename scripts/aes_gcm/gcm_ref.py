# SPDX-License-Identifier: Apache-2.0
"""Reference model of AES-GCM (NIST SP 800-38D) with AES-128 / AES-256
(FIPS 197), written from the standards and independent of the RTL. Used by
scripts/aes_gcm/gen_vec.py to check the known-answer tests and to make the
random cases of tb/AES_GCM_tb.sv.

  python3 scripts/aes_gcm/gcm_ref.py      # self-test: FIPS 197 and SP 800-38D examples,
                                          # and (if installed) Python's cryptography package
"""


def _xt(a):
    return ((a << 1) ^ 0x11B) & 0xFF if a & 0x80 else a << 1


def _gmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a, b = _xt(a), b >> 1
    return r


def _sbox():
    s = []
    for x in range(256):
        b = 0 if x == 0 else next(y for y in range(1, 256) if _gmul(x, y) == 1)
        v = b
        for i in range(1, 5):
            v ^= ((b << i) | (b >> (8 - i))) & 0xFF
        s.append(v ^ 0x63)
    return s


SBOX = _sbox()


def expand_key(key):
    """FIPS 197 KeyExpansion: list of Nr + 1 round keys of 16 bytes."""
    nk = len(key) // 4
    assert nk in (4, 8)
    nr = nk + 6
    w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = [SBOX[b] for b in t[1:] + t[:1]]
            t[0] ^= rcon
            rcon = _xt(rcon)
        elif nk > 6 and i % nk == 4:
            t = [SBOX[b] for b in t]
        w.append([a ^ b for a, b in zip(w[i - nk], t)])
    return [bytes(sum(w[4 * r:4 * r + 4], [])) for r in range(nr + 1)]


def aes_encrypt(key, block):
    rk = expand_key(key)
    s = [a ^ b for a, b in zip(block, rk[0])]
    for r in range(1, len(rk)):
        s = [SBOX[b] for b in s]
        s = [s[4 * ((c + row) % 4) + row] for c in range(4) for row in range(4)]   # ShiftRows
        if r != len(rk) - 1:
            m = []
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                m += [_xt(a[0]) ^ _xt(a[1]) ^ a[1] ^ a[2] ^ a[3],
                      a[0] ^ _xt(a[1]) ^ _xt(a[2]) ^ a[2] ^ a[3],
                      a[0] ^ a[1] ^ _xt(a[2]) ^ _xt(a[3]) ^ a[3],
                      _xt(a[0]) ^ a[0] ^ a[1] ^ a[2] ^ _xt(a[3])]
            s = m
        s = [a ^ b for a, b in zip(s, rk[r])]
    return bytes(s)


R = 0xE1 << 120


def gf_mul(x, y):
    """Multiplication in GF(2^128), SP 800-38D algorithm 1 (bit 0 = MSB)."""
    z, v = 0, y
    for i in range(127, -1, -1):
        if (x >> i) & 1:
            z ^= v
        v = (v >> 1) ^ R if v & 1 else v >> 1
    return z


def ghash(h, data):
    y = 0
    for i in range(0, len(data), 16):
        y = gf_mul(y ^ int.from_bytes(data[i:i + 16], "big"), h)
    return y


def _pad(b):
    return b + bytes(-len(b) % 16)


def gcm(key, iv, aad, text, decrypt=False):
    """Returns (output text, full 128-bit tag); 96-bit IV only."""
    assert len(iv) == 12
    h = int.from_bytes(aes_encrypt(key, bytes(16)), "big")
    j0 = iv + b"\x00\x00\x00\x01"
    out = bytearray()
    for i in range(0, len(text), 16):
        ks = aes_encrypt(key, iv + ((i // 16 + 2) & 0xFFFFFFFF).to_bytes(4, "big"))
        out += bytes(a ^ b for a, b in zip(text[i:i + 16], ks))
    c = text if decrypt else bytes(out)
    s = ghash(h, _pad(aad) + _pad(c) + (8 * len(aad)).to_bytes(8, "big") + (8 * len(c)).to_bytes(8, "big"))
    tag = (s ^ int.from_bytes(aes_encrypt(key, j0), "big")).to_bytes(16, "big")
    return bytes(out), tag


def _selftest():
    x = bytes.fromhex
    # FIPS 197 appendix C.1 and C.3
    assert aes_encrypt(x("000102030405060708090a0b0c0d0e0f"), x("00112233445566778899aabbccddeeff")) == \
        x("69c4e0d86a7b0430d8cdb78070b4c55a")
    assert aes_encrypt(x("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
                       x("00112233445566778899aabbccddeeff")) == x("8ea2b7ca516745bfeafc49904b496089")
    # GCM specification (McGrew / Viega) test cases 2 and 14
    assert gcm(bytes(16), bytes(12), b"", bytes(16)) == \
        (x("0388dace60b6a392f328c2b971b2fe78"), x("ab6e47d42cec13bdf53a67b21257bddf"))
    assert gcm(bytes(32), bytes(12), b"", bytes(16)) == \
        (x("cea7403d4d606b6e074ec5d3baf39d18"), x("d0d1c8a799996bf0265b98b5d48ab919"))
    n = 0
    try:
        import os
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        for i in range(300):
            k, iv = os.urandom(32 if i & 1 else 16), os.urandom(12)
            a, p = os.urandom(i % 50), os.urandom((7 * i) % 70)
            c, t = gcm(k, iv, a, p)
            assert AESGCM(k).encrypt(iv, p, a) == c + t
            assert gcm(k, iv, a, c, decrypt=True) == (p, t)
            n += 1
    except ImportError:
        pass
    print(f"gcm_ref self-test passed (FIPS 197, GCM spec cases, {n} random cases against cryptography)")


if __name__ == "__main__":
    _selftest()
