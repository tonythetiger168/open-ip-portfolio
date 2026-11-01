# SPDX-License-Identifier: Apache-2.0
"""Reference model of the PCIe_CXL_IDE framing (rtl/PCIe_CXL_IDE_top.sv),
written from the IP's documented field layouts and independent of the RTL.
The cipher is scripts/aes_gcm/gcm_ref.py (AES-256-GCM, SP 800-38D).

  TLP:      AAD = prefix (4 bytes) || header, text = payload,
            IV = fixed field (4 bytes) || invocation counter (8 bytes),
            MAC = the first 12 bytes of the tag.
  cachemem: one GCM message per MAC epoch, no AAD, text = the flits.
"""
import os, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "aes_gcm"))
import gcm_ref

PFX_TYPE = 0x92


def prefix(sid, k, sub):
    """The IDE prefix word: [31:24] 0x92, [23] M, [22] K, [19:18] sub-stream, [15:8] Stream ID."""
    return (PFX_TYPE << 24) | (1 << 23) | (k << 22) | (sub << 18) | (sid << 8)


def iv(fix, ctr):
    return fix.to_bytes(4, "big") + ctr.to_bytes(8, "big")


def protect_tlp(key, fix, ctr, sid, k, sub, hdr, payload):
    """Returns (prefix word, ciphertext, 12-byte MAC)."""
    p = prefix(sid, k, sub)
    ct, tag = gcm_ref.gcm(key, iv(fix, ctr), p.to_bytes(4, "big") + hdr, payload)
    return p, ct, tag[:12]


def protect_epoch(key, fix, ctr, flits):
    ct, tag = gcm_ref.gcm(key, iv(fix, ctr), b"", flits)
    return ct, tag[:12]


def _selftest():
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    key = bytes(range(32))
    hdr, pl = bytes(range(16)), bytes(range(100, 140))
    p, ct, mac = protect_tlp(key, 0x01020304, 5, 0x2A, 1, 2, hdr, pl)
    assert p == 0x92C82A00, hex(p)
    ref = AESGCM(key).encrypt(iv(0x01020304, 5), pl, p.to_bytes(4, "big") + hdr)
    assert ref[:-16] == ct and ref[-16:-4] == mac
    print("ide_ref self-test passed")


if __name__ == "__main__":
    _selftest()
