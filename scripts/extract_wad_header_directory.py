#!/usr/bin/env python3
"""Extract just a WAD file's 12-byte header and its lump directory (not
the whole file) into two separate $readmemh hex files, for
sim/tb/m5_doom_exec_tb.sv's PRELOAD2/PRELOAD3 parameters.

Why: a WAD's lump directory is a flat array of 16-byte entries
(filepos, size, name) pointed to by the header's infotableofs field --
for a standard-layout IWAD like freedoom1.wad, that's near the END of
the file, far from the header at offset 0. Preloading the ~28MB file in
between them to get both is exactly the scale problem that stalled this
project's first full-WAD preload attempt (see
docs/verification_report.md's M5 S3 section) -- extracting just these
two small regions gets W_AddFile() real IWAD-identification data and a
correctly-populated lump table at a tiny fraction of the cost. Individual
lump CONTENT is still not covered by this script -- that is a separate,
further increment.

Usage: extract_wad_header_directory.py <wad_file> <out_header.bin> <out_directory.bin>
"""
import struct
import sys


def main():
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <wad_file> <out_header.bin> <out_directory.bin>", file=sys.stderr)
        return 1
    wad_path, out_header, out_directory = sys.argv[1:4]

    with open(wad_path, "rb") as f:
        header = f.read(12)
        if len(header) != 12:
            print("error: file too short to contain a WAD header", file=sys.stderr)
            return 1
        ident, numlumps, infotableofs = struct.unpack("<4sII", header)
        if ident not in (b"IWAD", b"PWAD"):
            print(f"error: not IWAD/PWAD magic, got {ident!r}", file=sys.stderr)
            return 1
        f.seek(infotableofs)
        directory = f.read(numlumps * 16)
        if len(directory) != numlumps * 16:
            print("error: short read on lump directory -- infotableofs/numlumps inconsistent with file size", file=sys.stderr)
            return 1

    with open(out_header, "wb") as f:
        f.write(header)
    with open(out_directory, "wb") as f:
        f.write(directory)

    print(f"{ident.decode()} numlumps={numlumps} infotableofs={infotableofs}")
    print(f"wrote {len(header)} bytes to {out_header}")
    print(f"wrote {len(directory)} bytes ({numlumps} lumps) to {out_directory}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
