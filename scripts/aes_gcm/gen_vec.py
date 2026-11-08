#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Test vectors for tb/AES_GCM_tb.sv.

  python3 scripts/aes_gcm/gen_vec.py > tb/AES_GCM_vec.svh
  python3 scripts/aes_gcm/gen_vec.py --extract DIR    # rebuild scripts/aes_gcm/kat.json

kat.json holds the known-answer tests the TB runs, cut (with --extract) from
the pycryptodome-test-vectors package (DIR is its pycryptodome_test_vectors
directory):
  * NIST CAVP gcmEncryptExtIV128.rsp and gcmDecrypt128.rsp (AES-128): the
    first case of every section with a 96-bit IV (AAD 0-90 bytes, text 0-51
    bytes, tags of 4-16 bytes; the decrypt cases include wrong tags);
  * Project Wycheproof aes_gcm_test.json (Apache-2.0): every case with a
    96-bit IV and a 128- or 256-bit key, valid and invalid.
Every case is checked here against scripts/aes_gcm/gcm_ref.py, and against
Python's cryptography package when it is installed, before it is written.
Seeded random cases (AES-128 and AES-256, both directions, lengths up to 300
bytes, tags of 1-16 bytes, a wrong tag in some decrypt cases) are added from the same model, and
long encrypt cases at the length limits of the TB's core (LEN_W = 14): their
data is the TB's pattern pat() and the TB checks the tag and the XOR of all
output blocks.
"""
import json, os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gcm_ref

HERE = os.path.dirname(os.path.abspath(__file__))
KAT = os.path.join(HERE, "kat.json")


def parse_rsp(path):
    out, hdr, cur = [], {}, None
    for ln in open(path):
        ln = ln.strip()
        if ln.startswith("[") and "=" in ln:
            k, v = ln[1:-1].split("=")
            hdr[k.strip()] = int(v)
        elif ln.startswith("Count"):
            cur = dict(hdr, Count=int(ln.split("=")[1]))
            out.append(cur)
        elif cur is not None and "=" in ln:
            k, v = (x.strip() for x in ln.split("=", 1))
            cur[k] = v
        elif cur is not None and ln == "FAIL":
            cur["FAIL"] = True
    return out


def extract(d):
    kats = []
    for name, dec in (("gcmEncryptExtIV128.rsp", False), ("gcmDecrypt128.rsp", True)):
        for c in parse_rsp(os.path.join(d, "Cipher", "AES", name)):
            if c["IVlen"] != 96 or c["Count"] != 0:
                continue
            k = {"src": f"NIST {name[:-4]} PT{c['PTlen']} AAD{c['AADlen']} Tag{c['Taglen']}",
                 "key": c["Key"], "iv": c["IV"], "aad": c["AAD"], "ct": c["CT"], "tag": c["Tag"]}
            if dec:
                k["dec"] = True
                k["pt"] = None if c.get("FAIL") else c["PT"]
            else:
                k["pt"] = c["PT"]
            kats.append(k)
    w = json.load(open(os.path.join(d, "Cipher", "wycheproof", "aes_gcm_test.json")))
    for g in w["testGroups"]:
        if g["ivSize"] != 96 or g["keySize"] not in (128, 256):
            continue
        for t in g["tests"]:
            kats.append({"src": f"Wycheproof tcId {t['tcId']}", "dec": True, "key": t["key"], "iv": t["iv"],
                         "aad": t["aad"], "ct": t["ct"], "tag": t["tag"],
                         "pt": t["msg"] if t["result"] == "valid" else None})
    json.dump({"source": "pycryptodome-test-vectors 1.0.26: NIST CAVP GCM (AES-128, 96-bit IV, Count 0 of "
                         "every section) and Project Wycheproof aes_gcm_test.json (96-bit IV, 128/256-bit keys)",
               "kats": kats}, open(KAT, "w"), indent=0)
    print(f"{len(kats)} known-answer tests -> {KAT}")


def check(key, iv, aad, x, dec, tag, ok):
    out, full = gcm_ref.gcm(key, iv, aad, x, decrypt=dec)
    assert (full[:len(tag)] == tag) == ok
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.exceptions import InvalidTag
        if not dec:
            assert AESGCM(key).encrypt(iv, x, aad) == out + full
        elif len(tag) == 16:
            try:
                AESGCM(key).decrypt(iv, x + tag, aad)
                assert ok
            except InvalidTag:
                assert not ok
    except ImportError:
        pass
    return out, full


LW = 14                                 # LEN_W of the core in tb/AES_GCM_tb.sv


def pat(seed, n):
    """n bytes of the TB's pattern: block j is words ((seed + 4j + k) * 0x9E3779B1), k = 0..3."""
    b = b"".join((((seed + k) * 0x9E3779B1) & 0xFFFFFFFF).to_bytes(4, "big") for k in range(0, 4 * (n // 16 + 1)))
    return b[:n]


def blocks(b):
    return [b[i:i + 16] + bytes(16 - len(b[i:i + 16])) for i in range(0, len(b), 16)]


def main():
    if sys.argv[1:2] == ["--extract"]:
        extract(sys.argv[2])
        return
    kj = json.load(open(KAT))
    vb, vecs = [], []

    def put(b):
        o = len(vb)
        vb.extend(blocks(b))
        return o

    def add(src, key, iv, aad, x, dec, tag, ok, out, full, pair=False):
        ab, xb, ob = put(aad), put(x), put(out)
        e = dict(src=src, key=key, iv=iv, alen=len(aad), plen=len(x), dec=dec, ok=ok,
                 tlen=len(tag) % 16, tag=(tag + bytes(16 - len(tag))) if dec else full, ab=ab, xb=xb, ob=ob)
        vecs.append(e)
        if pair:   # the same case decrypted, with the (truncated) tag: shares the blocks
            vecs.append(dict(e, src=src + " (decrypt)", dec=True, ok=True, xb=ob, ob=xb,
                             tag=tag + bytes(16 - len(tag))))

    x = bytes.fromhex
    nk = 0
    for k in kj["kats"]:
        key, iv, aad, ct, tag = x(k["key"]), x(k["iv"]), x(k["aad"]), x(k["ct"]), x(k["tag"])
        if k.get("dec"):
            ok = k["pt"] is not None
            out, full = check(key, iv, aad, ct, True, tag, ok)
            if ok:
                assert out == x(k["pt"])
            add(k["src"], key, iv, aad, ct, True, tag, ok, out, full)
        else:
            out, full = check(key, iv, aad, x(k["pt"]), False, tag, True)
            assert out == ct
            add(k["src"], key, iv, aad, x(k["pt"]), False, tag, True, out, full, pair=True)
        nk += 1
    rnd = random.Random(0x6C3)
    lens = [0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 64, 100, 255, 256, 300]
    for i in range(96):
        k256 = i % 3 != 0
        key = bytes(rnd.getrandbits(8) for _ in range(32 if k256 else 16))
        iv = bytes(rnd.getrandbits(8) for _ in range(12))
        aad = bytes(rnd.getrandbits(8) for _ in range(rnd.choice(lens)))
        p = bytes(rnd.getrandbits(8) for _ in range(rnd.choice(lens)))
        tl = rnd.choice([16, 16] + list(range(1, 16)))       # every tag length on decrypt
        c, full = gcm_ref.gcm(key, iv, aad, p)
        check(key, iv, aad, p, False, full, True)
        if i % 2 == 0:
            add(f"random {i}", key, iv, aad, p, False, full[:tl], True, c, full)
        else:
            bad = i % 4 == 3
            tag = bytearray(full[:tl])
            if bad:
                tag[rnd.randrange(tl)] ^= 1 << rnd.randrange(8)
            out, f2 = check(key, iv, aad, c, True, bytes(tag), not bad)
            add(f"random {i}{' wrong tag' if bad else ''}", key, iv, aad, c, True, bytes(tag), not bad, out, f2)
    longs = []
    for k256, alen, plen, seed in ((0, (1 << LW) - 1, 33, 0x10), (1, 5, (1 << LW) - 32, 0x20)):
        key = bytes(rnd.getrandbits(8) for _ in range(32 if k256 else 16))
        iv = bytes(rnd.getrandbits(8) for _ in range(12))
        c, full = gcm_ref.gcm(key, iv, pat(seed, alen), pat(seed + 0x1000000, plen))
        check(key, iv, pat(seed, alen), pat(seed + 0x1000000, plen), False, full, True)
        fold = 0
        for b in blocks(c):
            fold ^= int.from_bytes(b, "big")
        longs.append((k256, alen, plen, seed, key + bytes(32 - len(key)), iv, full, fold))
    print("// SPDX-License-Identifier: Apache-2.0")
    print("// generated by scripts/aes_gcm/gen_vec.py: do not edit")
    print(f"// {nk} known-answer tests (NIST CAVP, Wycheproof; see scripts/aes_gcm/kat.json) and "
          f"{len(vecs) - nk} derived / random cases")
    print(f"localparam int NV = {len(vecs)};")
    print(f"localparam int NB = {len(vb)};")
    print("logic [127:0] vb [0:NB-1];                // blocks: AAD, input text, expected output (zero padded)")
    print("logic [255:0] v_key [0:NV-1];")
    print("logic [95:0]  v_iv [0:NV-1];")
    print("logic [127:0] v_tag [0:NV-1];             // encrypt: the expected tag; decrypt: tag_in")
    print("logic [3:0]   v_tlen [0:NV-1];            // tag bytes compared, 0 = 16")
    print("logic         v_k256 [0:NV-1], v_dec [0:NV-1], v_ok [0:NV-1];")
    print("int           v_alen [0:NV-1], v_plen [0:NV-1], v_ab [0:NV-1], v_xb [0:NV-1], v_ob [0:NV-1];")
    print("task automatic vec(input int i, input logic k256, dec, ok, input logic [3:0] tlen, input int alen, plen, ab, xb, ob,")
    print("                   input logic [255:0] key, input logic [95:0] iv, input logic [127:0] tag);")
    print("  v_k256[i] = k256; v_dec[i] = dec; v_ok[i] = ok; v_tlen[i] = tlen; v_alen[i] = alen; v_plen[i] = plen;")
    print("  v_ab[i] = ab; v_xb[i] = xb; v_ob[i] = ob; v_key[i] = key; v_iv[i] = iv; v_tag[i] = tag;")
    print("endtask")
    print(f"localparam int NL = {len(longs)};             // long cases: AAD pat(seed), text pat(seed + 2^24)")
    print("logic [255:0] l_key [0:NL-1];")
    print("logic [95:0]  l_iv [0:NL-1];")
    print("logic [127:0] l_tag [0:NL-1], l_fold [0:NL-1];  // tag, XOR of the output blocks")
    print("logic         l_k256 [0:NL-1];")
    print("int           l_alen [0:NL-1], l_plen [0:NL-1], l_seed [0:NL-1];")
    print("task automatic load_vecs();")
    for i, (k256, alen, plen, seed, key, iv, full, fold) in enumerate(longs):
        print(f"  l_k256[{i}] = {k256}; l_alen[{i}] = {alen}; l_plen[{i}] = {plen}; l_seed[{i}] = {seed}; "
              f"l_key[{i}] = 256'h{key.hex()};")
        print(f"  l_iv[{i}] = 96'h{iv.hex()}; l_tag[{i}] = 128'h{full.hex()}; l_fold[{i}] = 128'h{fold:032x};")
    for i, b in enumerate(vb):
        print(f"  vb[{i}] = 128'h{b.hex()};")
    for i, e in enumerate(vecs):
        kk = e["key"] + bytes(32 - len(e["key"]))
        print(f"  vec({i}, {int(len(e['key']) == 32)}, {int(e['dec'])}, {int(e['ok'])}, {e['tlen']}, {e['alen']}, "
              f"{e['plen']}, {e['ab']}, {e['xb']}, {e['ob']}, 256'h{kk.hex()}, 96'h{e['iv'].hex()}, "
              f"128'h{e['tag'].hex()});  // {e['src']}")
    print("endtask")


if __name__ == "__main__":
    main()
