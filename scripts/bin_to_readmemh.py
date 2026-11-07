#!/usr/bin/env python3
"""Convert a flat little-endian RV32 binary image into a $readmemh hex file
(one 32-bit word per line, most-significant-byte-first text representation,
matching Verilog's $readmemh word-value convention). Pads the final partial
word with zero bytes if the image length isn't a multiple of 4.

Usage: bin_to_readmemh.py input.bin output.hex
"""
import sys


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} input.bin output.hex", file=sys.stderr)
        return 1
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    pad = (-len(data)) % 4
    data += b"\x00" * pad
    with open(sys.argv[2], "w") as f:
        for i in range(0, len(data), 4):
            word = int.from_bytes(data[i:i + 4], byteorder="little")
            f.write(f"{word:08x}\n")
    print(f"wrote {len(data)//4} words ({len(data)} bytes, {pad} pad bytes) to {sys.argv[2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
