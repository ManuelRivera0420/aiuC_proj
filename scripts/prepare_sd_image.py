#!/usr/bin/env python3
"""Build a deterministic, versioned raw-sector boot image for the SD/SPI
bootloader (mission Section 3A). NOT a filesystem -- a fixed, versioned
binary layout the bootloader parses directly, matching the contract
sim/models/sdhc_spi_model.sv and rtl/peripherals/sd_spi.sv expect.

Layout (512-byte logical blocks, SDHC LBA addressing):
  LBA 0            : header sector (see HEADER_STRUCT below)
  LBA 1..N         : program image, padded to a 512-byte boundary
  LBA (1+N)..M     : WAD image (if provided), padded to a 512-byte boundary

Header (little-endian; all offsets in bytes within the 512-byte sector):
  0   magic              4s   b"RVDM"
  4   version             I   1
  8   program_load_addr   I   where the bootloader copies the program (e.g. SDRAM base)
  12  program_entry_addr  I   where execution jumps after loading
  16  program_length      I   bytes
  20  program_lba_start   I   always 1 in this layout
  24  wad_lba_start       I   0 if no WAD
  28  wad_length          I   bytes, 0 if no WAD
  32  program_sha256      32s full SHA-256 of the program image
  64  wad_sha256          32s full SHA-256 of the WAD image (zero if none)
  96..511            reserved, zero-filled

This intentionally has NO filesystem parser dependency in RTL/bootloader --
see the mission's instruction to prefer a fixed, versioned manifest over
FAT32 for the initial design.
"""
import argparse
import hashlib
import json
import struct
import sys

SECTOR = 512
MAGIC = b"RVDM"
VERSION = 1

HEADER_FIELDS = [
    "magic", "version", "program_load_addr", "program_entry_addr",
    "program_length", "program_lba_start", "wad_lba_start", "wad_length",
]


def pad_to_sector(data: bytes) -> bytes:
    pad = (-len(data)) % SECTOR
    return data + b"\x00" * pad


def build_image(program_path, wad_path, load_addr, entry_addr, out_path, manifest_path):
    with open(program_path, "rb") as f:
        program = f.read()
    program_padded = pad_to_sector(program)
    program_sectors = len(program_padded) // SECTOR
    program_sha = hashlib.sha256(program).digest()

    wad = b""
    wad_sha = b"\x00" * 32
    wad_lba_start = 0
    if wad_path:
        with open(wad_path, "rb") as f:
            wad = f.read()
        wad_sha = hashlib.sha256(wad).digest()
        wad_lba_start = 1 + program_sectors
    wad_padded = pad_to_sector(wad) if wad_path else b""

    header = bytearray(SECTOR)
    struct.pack_into("<4sIIIIIII", header, 0,
                      MAGIC, VERSION, load_addr, entry_addr, len(program),
                      1, wad_lba_start, len(wad))
    header[32:64] = program_sha
    header[64:96] = wad_sha

    image = bytes(header) + program_padded + wad_padded
    with open(out_path, "wb") as f:
        f.write(image)

    manifest = {
        "magic": MAGIC.decode(),
        "version": VERSION,
        "program_load_addr": hex(load_addr),
        "program_entry_addr": hex(entry_addr),
        "program_length_bytes": len(program),
        "program_lba_start": 1,
        "program_lba_count": program_sectors,
        "program_sha256": program_sha.hex(),
        "wad_lba_start": wad_lba_start,
        "wad_length_bytes": len(wad),
        "wad_sha256": wad_sha.hex(),
        "total_sectors": len(image) // SECTOR,
        "total_bytes": len(image),
        "image_sha256": hashlib.sha256(image).hexdigest(),
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"wrote {out_path}: {len(image)} bytes ({manifest['total_sectors']} sectors)")
    print(f"wrote {manifest_path}")
    return manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--program", required=True, help="raw program binary (e.g. from objcopy -O binary)")
    ap.add_argument("--wad", default=None, help="optional WAD file to embed")
    ap.add_argument("--load-addr", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--entry-addr", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--out", required=True, help="output raw image path")
    ap.add_argument("--manifest", required=True, help="output JSON manifest path")
    args = ap.parse_args()

    build_image(args.program, args.wad, args.load_addr, args.entry_addr, args.out, args.manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
