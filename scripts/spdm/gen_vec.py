#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Test vectors for SPDM_top from the reference model (spdm_ref.py).

  python3 scripts/spdm/gen_vec.py tb/SPDM_vec.hex [--check]

The file is a list of 32-bit words (hex, one per line) holding records
{op[31:24], arg[23:0]} followed by their data:
  0x01 CFG     ct_exp, asym_id, pset, cc_len, m_en, m_tcb, m_type
  0x02 STORE   arg = {sel[16], n[15:0]}: word address, n data words
  0x03 KEYGEN  arg = {pset[13:12], err[8], clr[4], sel[0]}: 8 seed words (seed, or the
               sideload port when sel); err: refused with cmd_err; clr: clr
               is pulsed while KeyGen runs (no key afterwards)
  0x04 PK      arg = n: the n public-key words expected (arg bit 23: pk_open
               is refused with cmd_err, no words)
  0x05 REQ     arg = {clr_at[23:20], req_len[15:0]}, then {nrn[31:24],
               rsp_len[23:0]}, the nrn random words to supply, the request
               bytes and the expected response bytes (little-endian packed);
               clr_at 1: clr after half the request, 2: while the ML-DSA
               signature is computed, 3: after the first response byte (the
               response is then not checked, the model is cleared)
  0x06 CLR
  0x07 SLV     arg = sl_valid level for the next KEYGEN records
  0x00 END
--check verifies every signed response with ML-DSA Verify against the public
key and the transcript (slow).
"""
import os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spdm_ref as sr  # noqa: E402

ASYM_ID = 0x0A01_0004          # the ExtAsym entry programmed into asym_id


class Gen:
    def __init__(self, rnd, check):
        self.r = rnd
        self.check = check
        self.m = sr.Responder()
        self.w = []
        self.ncase = 0
        self.sl_valid = 0

    def words(self, b):
        b = bytes(b) + bytes(-len(b) % 4)
        return [int.from_bytes(b[i:i + 4], "little") for i in range(0, len(b), 4)]

    def cfg(self, ct_exp=12, pset=0, cc_len=None, m_en=None, m_tcb=None, m_type=None):
        m = self.m
        m.ct_exp = ct_exp
        m.asym_id = ASYM_ID
        if m_en is not None:
            m.m_en = m_en
        if m_tcb is not None:
            m.m_tcb = m_tcb
        if m_type is not None:
            m.m_type = list(m_type)
        cc = len(m.cc) if cc_len is None else cc_len
        self.cc_len = cc
        self.pset = pset
        self.w += [0x01 << 24, ct_exp, ASYM_ID, pset, cc, m.m_en, m.m_tcb,
                   sum(t << (8 * i) for i, t in enumerate(m.m_type))]

    def store_cc(self, cc, addr=0):
        ws = self.words(cc)
        self.w += [0x02 << 24 | len(ws), addr] + ws

    def set_cc(self, cc):
        self.cc_full = bytes(cc)
        self.store_cc(cc)

    def set_cc_len(self, n):
        self.m.cc = self.cc_full[:n]
        self.cfg(ct_exp=self.m.ct_exp, pset=self.pset, cc_len=n)

    def store_meas(self, i, val):
        self.m.m_val[i] = bytes(val)
        self.w += [0x02 << 24 | 1 << 16 | 12, 16 * i] + self.words(val)

    def keygen(self, pset, sel=0, clr=False, err=False):
        seed = bytes(self.r.getrandbits(8) for _ in range(32))
        self.w += [0x03 << 24 | (pset << 12) | (err << 8) | (clr << 4) | sel] + self.words(seed)
        if err or clr:
            if clr:
                self.m.clear()
            return
        pk = self.m.keygen(pset, seed)
        self.pk = pk
        ws = self.words(pk)
        self.w += [0x04 << 24 | len(ws)] + ws

    def slv(self, v):
        self.w += [0x07 << 24 | v]

    def clr(self):
        self.m.clear()
        self.w += [0x06 << 24]

    def req(self, q, clr_at=0):
        q = bytes(q)
        rn = []

        def nxt():
            v = self.r.getrandbits(32)
            rn.append(v)
            return v
        before = (self.m.vca, self.m.tm, self.m.tl)
        if clr_at:
            # the model never answers: the random words it would use are given anyway
            m2 = sr.Responder()
            m2.__dict__.update({k: v for k, v in self.m.__dict__.items()})
            try:
                r = m2.handle(q, nxt)
            except Exception:
                r = b""
            self.m.clear()
            r = b""
            if clr_at == 1:
                rn = []
        else:
            r = self.m.handle(q, nxt)
            if self.check and len(r) > 1000 and r[1] in (0x03, 0x60):
                vca, tm, tl = before
                t = vca + (tm if r[1] == 0x03 else tl)
                ctx = sr.CTX_CHAL if r[1] == 0x03 else sr.CTX_MEAS
                assert sr.verify_challenge_auth(self.m.key[1], self.m.key[0], t, q, r, ctx), "signature check"
        self.w += [0x05 << 24 | clr_at << 20 | len(q), len(rn) << 24 | len(r)] + rn + self.words(q) + self.words(r)
        self.ncase += 1
        return r

    def vca(self, dts=0x2000, ext=(ASYM_ID,), base_hash=sr.BASE_HASH_SHA3_384, meas_spec=1):
        self.req(sr.get_version())
        self.req(sr.get_capabilities(dts=dts))
        self.req(sr.negotiate_algorithms(ext_asym=ext, base_hash=base_hash, meas_spec=meas_spec))


def main():
    out = sys.argv[1]
    check = "--check" in sys.argv
    g = Gen(random.Random(20261031), check)
    r = g.r
    nonce = lambda: bytes(r.getrandbits(8) for _ in range(32))
    # chain: Length, Reserved, RootHash (48), then DER-looking bytes
    body = bytes([0x30, 0x82]) + bytes(r.getrandbits(8) for _ in range(1100))
    root = sr.sha3(body[:400])
    cc = sr.u16(4 + 48 + len(body)) + bytes(2) + root + body
    g.cfg(ct_exp=12, pset=0, cc_len=0, m_en=0b1011, m_tcb=0b0011, m_type=[0x00, 0x01, 0x02, 0x83])
    g.set_cc(cc)
    for i in range(4):
        g.store_meas(i, bytes(r.getrandbits(8) for _ in range(48)))
    g.m.cc = b""

    # ---- before GET_VERSION ----
    g.req(sr.get_capabilities())                       # UnexpectedRequest (version 1.0 ERROR)
    g.req(bytes([0x12, 0xE1]))                         # too short
    g.req(bytes([0x12]))
    g.req(bytes([0x12, 0x99, 0, 0]))                   # unsupported code
    g.req(bytes([0x12, 0x04, 0, 0]))                   # a response code
    g.req(bytes([0x12, 0xE4]) + bytes(40))             # KEY_EXCHANGE: unsupported
    g.req(bytes([0x12, 0x84]) + bytes(200))            # over 128 bytes
    g.req(get_v := sr.get_version(0x11))               # version mismatch
    g.req(sr.get_version(0x12))
    g.req(sr.get_version() + b"\x00")                  # bad length
    g.req(sr.get_version())
    g.req(sr.get_version())                            # again: restarts VCA
    # ---- GET_CAPABILITIES ----
    g.req(sr.get_capabilities(ver=0x11))
    g.req(sr.negotiate_algorithms(ext_asym=[ASYM_ID]))  # out of order
    g.req(sr.get_digests())
    g.req(sr.get_capabilities()[:12])                  # 1.1 length
    g.req(sr.get_capabilities(dts=41))
    g.req(sr.get_capabilities(dts=0x1000, msz=0x0FFF))
    g.req(sr.get_capabilities(dts=0x20000))            # clamped to our size
    g.req(sr.get_capabilities())                       # again: unexpected
    # ---- NEGOTIATE_ALGORITHMS ----
    g.req(sr.get_digests())
    g.req(sr.negotiate_algorithms(ext_asym=[ASYM_ID], length=50))
    g.req(sr.negotiate_algorithms(ext_asym=[1] * 12, ext_hash=[2] * 9))
    g.req(sr.negotiate_algorithms()[:30])
    na = bytearray(sr.negotiate_algorithms(ext_asym=[ASYM_ID, 7]))
    na[28] = 3                                          # claims 3 entries, has 2
    g.req(bytes(na))
    structs = bytes([2, 0x20, 0x10, 0x00, 3, 0x20, 0x02, 0x00, 4, 0x20, 0x80, 0x00, 5, 0x20, 0x01, 0x00])
    g.req(sr.negotiate_algorithms(ext_asym=[0x0004_0007, 0x1234_5678, ASYM_ID] + [r.getrandbits(32) for _ in range(5)],
                                  ext_hash=[0x0004_0099], structs=structs))
    g.req(sr.negotiate_algorithms(ext_asym=[ASYM_ID]))  # unexpected now
    # ---- no key, empty slot ----
    g.req(sr.get_digests())
    g.req(sr.get_certificate(0, 64))
    g.req(sr.challenge(nonce()))
    g.req(sr.get_measurements(0))
    g.req(sr.get_measurements(0xFF))
    g.req(sr.get_measurements(2))
    g.req(sr.get_measurements(3))                      # index 3 not present
    g.req(sr.get_measurements(5))
    g.req(sr.get_measurements(0xFE))
    g.req(sr.get_measurements(0xFF, sig=True, nonce=nonce()))   # no key
    g.req(sr.get_measurements(1) + b"\x00")            # bad length
    g.req(sr.get_measurements(0xFF, ver=0x11))
    g.req(bytes([0x12, 0x81, 0, 0, 0]))                # GET_DIGESTS bad length
    # ---- refused key commands ----
    g.keygen(3, err=True)                              # reserved parameter set
    g.keygen(0, sel=1, err=True)                       # sideload not valid
    g.w += [0x04 << 24 | 0x800000]                     # PK without a key: cmd_err
    # ---- ML-DSA-44 key, slot 0 ----
    g.keygen(0)
    g.set_cc_len(len(cc))
    g.req(sr.get_digests())
    g.req(sr.get_certificate(0, 256))
    g.req(sr.get_measurements(0xFF))                   # L1 interleaved with M1
    g.req(sr.get_certificate(256, 4000))
    g.req(sr.get_certificate(len(cc) - 5, 64))
    g.req(sr.get_certificate(17, 0))
    g.req(sr.get_certificate(len(cc), 4))              # offset past the end
    g.req(sr.get_certificate(0, 4, slot=1))
    g.req(sr.get_certificate(0, 4) + b"\x00")
    g.req(sr.challenge(nonce(), mtype=2))
    g.req(sr.challenge(nonce(), slot=1))
    g.req(sr.challenge(nonce()) + b"\x00")
    g.req(sr.challenge(nonce(), mtype=0))
    g.req(sr.challenge(nonce(), mtype=1))              # M1 restarted from VCA
    g.req(sr.get_digests())
    g.req(sr.challenge(nonce(), mtype=0xFF))
    g.req(sr.get_measurements(1, sig=True, nonce=nonce()))
    g.req(sr.get_measurements(0))
    g.req(sr.get_measurements(4))
    g.req(sr.get_measurements(0xFF, sig=True, nonce=nonce()))
    g.req(sr.get_measurements(0xFF, sig=True, nonce=nonce(), slot=1))
    g.req(sr.get_measurements(0, sig=True, nonce=nonce()))
    # ---- small DataTransferSize ----
    g.vca(dts=42)
    g.req(sr.get_digests())                            # ResponseTooLarge
    g.req(sr.get_certificate(100, 200))                # portion clamped to 34
    g.req(sr.challenge(nonce()))
    g.req(sr.get_measurements(0))                      # 42 bytes: fits
    g.req(sr.get_measurements(2))
    g.req(sr.get_measurements(0xFF, sig=True, nonce=nonce()))
    g.vca(dts=2500)
    g.req(sr.challenge(nonce(), mtype=0xFF))           # 134 + 2420 bytes: fits
    g.req(sr.get_measurements(0xFF, sig=True, nonce=nonce()))   # 207 + 2420: too large
    g.req(sr.get_measurements(1, sig=True, nonce=nonce()))      # 97 + 2420: fits
    # ---- negotiation without a common algorithm ----
    g.vca(ext=(0x1111_2222,))
    g.req(sr.get_digests())
    g.req(sr.get_measurements(0))
    g.vca(base_hash=1 << 1)                            # SHA-384 only
    g.req(sr.challenge(nonce()))
    g.vca(meas_spec=0)
    g.req(sr.get_measurements(0))                      # no measurement spec
    g.req(sr.challenge(nonce(), mtype=0xFF))
    g.vca()
    # empty TCB summary
    g.cfg(ct_exp=3, pset=1, m_tcb=0b0100)
    g.req(sr.challenge(nonce(), mtype=1))
    g.cfg(ct_exp=3, pset=1, m_en=0b0000, m_tcb=0)
    g.req(sr.get_measurements(0xFF))
    g.req(sr.get_measurements(0))
    g.req(sr.challenge(nonce(), mtype=0xFF))
    g.cfg(ct_exp=255, pset=1, m_en=0b1111, m_tcb=0b1010, m_type=[0x04, 0x05, 0x06, 0x07])
    # ---- clr in the middle of things ----
    g.req(sr.get_digests(), clr_at=1)
    g.keygen(1)
    g.vca()
    g.req(sr.challenge(nonce()), clr_at=2)
    g.slv(1)
    g.keygen(1, sel=1)
    g.vca()
    g.req(sr.get_certificate(0, 1000), clr_at=3)
    g.req(sr.get_version())                            # conn none again ... fine
    g.req(sr.get_digests())
    g.keygen(1, clr=True)
    g.keygen(1)
    g.vca(dts=0xFFFF)
    g.req(sr.challenge(nonce(), mtype=1))              # ML-DSA-65
    g.req(sr.get_measurements(3, sig=True, nonce=nonce()))
    # ---- ML-DSA-87 ----
    g.slv(0)
    g.cfg(ct_exp=20, pset=2)
    g.keygen(2)
    g.vca()
    g.req(sr.get_digests())
    g.req(sr.get_certificate(0, 0xFFFF))
    g.req(sr.challenge(nonce(), mtype=0xFF))
    g.req(sr.get_measurements(0xFF, sig=True, nonce=nonce()))
    g.clr()
    g.req(sr.get_digests())
    g.w += [0]
    with open(out, "w") as f:
        f.write("\n".join(f"{x & 0xFFFFFFFF:08x}" for x in g.w) + "\n")
    print(f"{g.ncase} requests, {len(g.w)} words -> {out}")


if __name__ == "__main__":
    main()
