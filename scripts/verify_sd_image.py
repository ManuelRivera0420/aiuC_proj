#!/usr/bin/env python3
"""Independently re-parse and verify a raw SD boot image built by
prepare_sd_image.py: re-reads the header, re-slices the program/WAD
regions by LBA, recomputes SHA-256 over them, and checks against the
embedded hashes AND (if given) the separately-written JSON manifest.
Exit code 0 = verified OK, 1 = mismatch/corruption found.

This is deliberately a SEPARATE script re-deriving everything from the
raw image bytes, not just re-reading the manifest JSON and trusting it --
the point is to catch a corrupted image that still has an intact-looking
manifest sitting next to it.
"""
import argparse
import hashlib
import json
import struct
import sys

SECTOR = 512
MAGIC = b"RVDM"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image", help="raw image file to verify")
    ap.add_argument("--manifest", default=None, help="optional manifest JSON to cross-check")
    args = ap.parse_args()

    with open(args.image, "rb") as f:
        data = f.read()

    errors = []

    if len(data) < SECTOR:
        print(f"FAIL: image too short ({len(data)} bytes, need at least {SECTOR})")
        return 1

    header = data[0:SECTOR]
    magic, version, load_addr, entry_addr, prog_len, prog_lba, wad_lba, wad_len = \
        struct.unpack_from("<4sIIIIIII", header, 0)
    prog_sha_expected = header[32:64]
    wad_sha_expected = header[64:96]

    if magic != MAGIC:
        errors.append(f"bad magic: {magic!r} (expected {MAGIC!r})")

    prog_start = prog_lba * SECTOR
    prog_end = prog_start + prog_len
    if prog_end > len(data):
        errors.append(f"program region [{prog_start}:{prog_end}) exceeds image length {len(data)}")
    else:
        prog_actual_sha = hashlib.sha256(data[prog_start:prog_end]).digest()
        if prog_actual_sha != prog_sha_expected:
            errors.append(f"program SHA-256 mismatch: header says {prog_sha_expected.hex()}, "
                           f"recomputed {prog_actual_sha.hex()}")

    if wad_len > 0:
        wad_start = wad_lba * SECTOR
        wad_end = wad_start + wad_len
        if wad_end > len(data):
            errors.append(f"WAD region [{wad_start}:{wad_end}) exceeds image length {len(data)}")
        else:
            wad_actual_sha = hashlib.sha256(data[wad_start:wad_end]).digest()
            if wad_actual_sha != wad_sha_expected:
                errors.append(f"WAD SHA-256 mismatch: header says {wad_sha_expected.hex()}, "
                               f"recomputed {wad_actual_sha.hex()}")

    if args.manifest:
        with open(args.manifest) as f:
            manifest = json.load(f)
        if manifest.get("program_length_bytes") != prog_len:
            errors.append(f"manifest program_length_bytes {manifest.get('program_length_bytes')} "
                           f"!= header value {prog_len}")
        if manifest.get("program_sha256") != prog_sha_expected.hex():
            errors.append("manifest program_sha256 does not match header")

    print(f"magic={magic!r} version={version} load_addr=0x{load_addr:08x} "
          f"entry_addr=0x{entry_addr:08x} program_length={prog_len} "
          f"program_lba={prog_lba} wad_lba={wad_lba} wad_length={wad_len}")

    if errors:
        print("FAIL:")
        for e in errors:
            print(f"  - {e}")
        return 1

    print("PASS: image structurally consistent and all hashes verified independently")
    return 0


if __name__ == "__main__":
    sys.exit(main())
