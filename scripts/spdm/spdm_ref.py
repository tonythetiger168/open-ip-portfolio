#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""SPDM 1.2 responder reference model for SPDM_top (DMTF DSP0274 1.2).

Written from the message layouts of DSP0274 1.2 and the behaviour documented
in rtl/SPDM_top.sv: VCA, GET_DIGESTS, GET_CERTIFICATE, CHALLENGE and
GET_MEASUREMENTS with SHA3-384 transcripts (M1, L1) and ML-DSA signatures
(scripts/mldsa/mldsa_ref.py, pure ML-DSA with an empty context).

The model keeps the transcripts as byte strings and hashes them with
hashlib when a response is signed, so it shares no structure with the RTL
(which hashes on the fly in three SHA3 engines).
"""
import hashlib, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mldsa"))
import mldsa_ref as ml  # noqa: E402

PSETS = ["ML-DSA-44", "ML-DSA-65", "ML-DSA-87"]
RQ_MAX = 128
GET_VERSION, GET_CAPABILITIES, NEGOTIATE_ALGORITHMS = 0x84, 0xE1, 0xE3
GET_DIGESTS, GET_CERTIFICATE, CHALLENGE, GET_MEASUREMENTS = 0x81, 0x82, 0x83, 0xE0
KNOWN = {GET_CAPABILITIES, NEGOTIATE_ALGORITHMS, GET_DIGESTS, GET_CERTIFICATE, CHALLENGE, GET_MEASUREMENTS}
INVALID_REQUEST, UNEXPECTED_REQUEST, UNSUPPORTED_REQUEST = 0x01, 0x04, 0x07
RESPONSE_TOO_LARGE, VERSION_MISMATCH = 0x0D, 0x41
# CAPABILITIES flags: CERT_CAP (bit 1), CHAL_CAP (bit 2), MEAS_CAP = 2 (bits 4:3)
RSP_FLAGS = (1 << 1) | (1 << 2) | (2 << 3)
BASE_HASH_SHA3_384 = 1 << 4
MEAS_HASH_SHA3_384 = 1 << 5
CTX_CHAL = b"responder-challenge_auth signing"
CTX_MEAS = b"responder-measurements signing"


def sha3(b):
    return hashlib.sha3_384(bytes(b)).digest()


def u16(v):
    return v.to_bytes(2, "little")


def u24(v):
    return v.to_bytes(3, "little")


def u32(v):
    return v.to_bytes(4, "little")


def signing_input(ctx, digest):
    """combined_spdm_prefix || message_hash (DSP0274 1.2, signature generation)."""
    prefix = b"dmtf-spdm-v1.2.*" * 4
    return prefix + bytes(36 - len(ctx)) + ctx + digest


class Responder:
    def __init__(self, nm=4):
        self.nm = nm
        self.dts_max = max(8 + 55 * nm + 34 + 4627, 4761)
        self.ct_exp = 0
        self.asym_id = 0
        self.cc = b""
        self.m_en = 0
        self.m_tcb = 0
        self.m_type = [0] * nm
        self.m_val = [bytes(48)] * nm
        self.key = None              # (pset, pk, sk)
        self.reset_conn()

    def reset_conn(self):
        self.conn = 0
        self.vca = b""
        self.tm = b""                # message B + C so far (M1 = VCA || tm)
        self.tl = b""                # measurement messages so far (L1 = VCA || tl)
        self.hash_ok = self.asym_ok = self.meas_ok = False
        self.dts = 0

    # ---------------- host side ----------------
    def keygen(self, pset, seed):
        p = ml.PARAMS[PSETS[pset]]
        pk, sk = ml.keygen(bytes(seed), p)
        self.key = (pset, pk, sk)
        return pk

    def clear(self):
        self.key = None
        self.reset_conn()

    def slot_ok(self):
        return len(self.cc) != 0 and self.key is not None

    def sig_len(self):
        pset = self.key[0] if self.key else 0
        return ml.sig_len(ml.PARAMS[PSETS[pset]])

    def block(self, i):
        return bytes([i + 1, 0x01]) + u16(51) + bytes([self.m_type[i]]) + u16(48) + self.m_val[i]

    def sign(self, ctx, transcript, rnd):
        pset, _, sk = self.key
        p = ml.PARAMS[PSETS[pset]]
        msg = ml.format_msg(signing_input(ctx, sha3(transcript)), b"", None)
        return ml.sign(sk, msg, bytes(rnd), p)

    # ---------------- requests ----------------
    def error(self, req, code, data=0):
        ver = 0x10 if self.conn == 0 or len(req) < 2 or req[1] == GET_VERSION else 0x12
        return bytes([ver, 0x7F, code, data])

    def check(self, q):
        """The ERROR code for request q, or 0."""
        n = len(q)
        if n > RQ_MAX or n < 4:
            return INVALID_REQUEST
        ver, code, p1, p2 = q[0], q[1], q[2], q[3]
        if code == GET_VERSION:
            return VERSION_MISMATCH if ver != 0x10 else INVALID_REQUEST if n != 4 else 0
        if code not in KNOWN:
            return UNSUPPORTED_REQUEST
        if self.conn == 0:
            return UNEXPECTED_REQUEST
        if ver != 0x12:
            return VERSION_MISMATCH
        cr = self.conn == 3 and self.hash_ok and self.asym_ok
        if code == GET_CAPABILITIES:
            if self.conn != 1:
                return UNEXPECTED_REQUEST
            if n != 20:
                return INVALID_REQUEST
            dts = int.from_bytes(q[12:16], "little")
            msz = int.from_bytes(q[16:20], "little")
            return INVALID_REQUEST if dts < 42 or msz < dts else 0
        if code == NEGOTIATE_ALGORITHMS:
            if self.conn != 2:
                return UNEXPECTED_REQUEST
            if n < 32:
                return INVALID_REQUEST
            length = int.from_bytes(q[4:6], "little")
            a, e = q[28], q[29]
            return INVALID_REQUEST if length != n or a + e > 20 or length < 32 + 4 * (a + e) else 0
        if not cr:
            return UNEXPECTED_REQUEST
        if code == GET_DIGESTS:
            if n != 4:
                return INVALID_REQUEST
            return RESPONSE_TOO_LARGE if self.slot_ok() and self.dts < 52 else 0
        if code == GET_CERTIFICATE:
            off = int.from_bytes(q[4:6], "little")
            return INVALID_REQUEST if n != 8 or p1 & 0xF or not self.slot_ok() or off >= len(self.cc) else 0
        if code == CHALLENGE:
            if n != 36 or p1 != 0 or not self.slot_ok() or p2 not in (0, 1, 0xFF):
                return INVALID_REQUEST
            ln = 86 + (48 if p2 else 0) + self.sig_len()
            return RESPONSE_TOO_LARGE if ln > self.dts else 0
        # GET_MEASUREMENTS
        if not self.meas_ok:
            return UNSUPPORTED_REQUEST
        sig = p1 & 1
        if n != (37 if sig else 4):
            return INVALID_REQUEST
        if p2 not in (0, 0xFF) and not (p2 <= self.nm and self.m_en >> (p2 - 1) & 1):
            return INVALID_REQUEST
        if sig and (q[36] != 0 or not self.slot_ok()):
            return INVALID_REQUEST
        nb = 0 if p2 == 0 else bin(self.m_en).count("1") if p2 == 0xFF else 1
        ln = 42 + 55 * nb + (self.sig_len() if sig else 0)
        return RESPONSE_TOO_LARGE if ln > self.dts else 0

    def handle(self, q, rn):
        """Answer request q; rn() gives the next 32-bit random word."""
        q = bytes(q)
        e = self.check(q)
        if e:
            return self.error(q, e, q[1] if e == UNSUPPORTED_REQUEST else 0)
        code, p1, p2 = q[1], q[2], q[3]
        if code == GET_VERSION:
            self.reset_conn()
            r = bytes([0x10, 0x04, 0, 0, 0, 1]) + u16(0x1200)
            self.conn = 1
            self.vca = q + r
            return r
        if code == GET_CAPABILITIES:
            dts = int.from_bytes(q[12:16], "little")
            self.dts = min(dts, self.dts_max)
            r = bytes([0x12, 0x61, 0, 0, 0, self.ct_exp, 0, 0]) + u32(RSP_FLAGS) + u32(self.dts_max) * 2
            self.conn = 2
            self.vca += q + r
            return r
        if code == NEGOTIATE_ALGORITHMS:
            a = q[28]
            ext = [int.from_bytes(q[32 + 4 * i:36 + 4 * i], "little") for i in range(a)]
            self.hash_ok = bool(int.from_bytes(q[12:16], "little") & BASE_HASH_SHA3_384)
            self.asym_ok = self.asym_id in ext
            self.meas_ok = bool(q[6] & 1)
            r = bytes([0x12, 0x63, 0, 0]) + u16(40 if self.asym_ok else 36)
            r += bytes([1 if self.meas_ok else 0, 0]) + u32(MEAS_HASH_SHA3_384 if self.meas_ok else 0)
            r += u32(0) + u32(BASE_HASH_SHA3_384 if self.hash_ok else 0) + bytes(12)
            r += bytes([1 if self.asym_ok else 0, 0, 0, 0])
            if self.asym_ok:
                r += u32(self.asym_id)
            self.conn = 3
            self.vca += q + r
            return r
        if code == GET_DIGESTS:
            r = bytes([0x12, 0x01, 0, 1 if self.slot_ok() else 0])
            if self.slot_ok():
                r += sha3(self.cc)
            self.tm += q + r
            return r
        if code == GET_CERTIFICATE:
            off = int.from_bytes(q[4:6], "little")
            ln = int.from_bytes(q[6:8], "little")
            por = min(ln, len(self.cc) - off, self.dts - 8)
            rem = len(self.cc) - off - por
            r = bytes([0x12, 0x02, 0, 0]) + u16(por) + u16(rem) + self.cc[off:off + por]
            self.tm += q + r
            return r
        nonce = b"".join(u32(rn()) for _ in range(8))
        if code == CHALLENGE:
            rnd = b"".join(u32(rn()) for _ in range(8))
            r = bytes([0x12, 0x03, 0, 1]) + sha3(self.cc) + nonce
            if p2:
                sel = [i for i in range(self.nm) if self.m_en >> i & 1 and (p2 == 0xFF or self.m_tcb >> i & 1)]
                r += sha3(b"".join(self.block(i) for i in sel))
            r += u16(0)
            t = self.vca + self.tm + q + r
            r += self.sign(CTX_CHAL, t, rnd)
            self.tm = b""
            return r
        # GET_MEASUREMENTS
        sig = p1 & 1
        rnd = b"".join(u32(rn()) for _ in range(8)) if sig else None
        en = [i for i in range(self.nm) if self.m_en >> i & 1]
        sel = [] if p2 == 0 else en if p2 == 0xFF else [p2 - 1]
        rec = b"".join(self.block(i) for i in sel)
        r = bytes([0x12, 0x60, len(en) if p2 == 0 else 0, 0, len(sel)]) + u24(len(rec)) + rec + nonce + u16(0)
        if sig:
            t = self.vca + self.tl + q + r
            r += self.sign(CTX_MEAS, t, rnd)
            self.tl = b""
        else:
            self.tl += q + r
        return r


# ---------------- request builders (for the vector generator) ----------------
def get_version(ver=0x10):
    return bytes([ver, GET_VERSION, 0, 0])


def get_capabilities(dts=4096, msz=None, ct=0, flags=0x0000F6C6, ver=0x12):
    msz = dts if msz is None else msz
    return bytes([ver, GET_CAPABILITIES, 0, 0, 0, ct, 0, 0]) + u32(flags) + u32(dts) + u32(msz)


def negotiate_algorithms(ext_asym=(), ext_hash=(), base_hash=BASE_HASH_SHA3_384, meas_spec=1,
                         base_asym=0x0000_0080, structs=b"", length=None, ver=0x12):
    body = bytes([meas_spec, 0x02]) + u32(base_asym) + u32(base_hash) + bytes(12)
    body += bytes([len(ext_asym), len(ext_hash), 0, 0])
    body += b"".join(u32(x) for x in ext_asym) + b"".join(u32(x) for x in ext_hash) + structs
    n = 6 + len(body)
    return bytes([ver, NEGOTIATE_ALGORITHMS, len(structs) // 4 if structs else 0, 0]) + u16(n if length is None else length) + body


def get_digests(ver=0x12):
    return bytes([ver, GET_DIGESTS, 0, 0])


def get_certificate(off, ln, slot=0, ver=0x12):
    return bytes([ver, GET_CERTIFICATE, slot, 0]) + u16(off) + u16(ln)


def challenge(nonce, mtype=0, slot=0, ver=0x12):
    return bytes([ver, CHALLENGE, slot, mtype]) + bytes(nonce)


def get_measurements(op, sig=False, nonce=bytes(32), slot=0, ver=0x12):
    q = bytes([ver, GET_MEASUREMENTS, 1 if sig else 0, op])
    return q + bytes(nonce) + bytes([slot]) if sig else q


def verify_challenge_auth(pk, pset, transcript_before, req, rsp, ctx=CTX_CHAL):
    """Check a signed response with ML-DSA Verify (used by the self-test)."""
    p = ml.PARAMS[PSETS[pset]]
    sl = ml.sig_len(p)
    body, sig = rsp[:-sl], rsp[-sl:]
    msg = ml.format_msg(signing_input(ctx, sha3(transcript_before + req + body)), b"", None)
    return ml.verify(pk, msg, sig, p)
