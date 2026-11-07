#!/usr/bin/env bash
# Reproducible build: C/asm sources -> ELF -> raw binary -> $readmemh hex.
# Usage: build_firmware.sh <output_name> <linker_script> <source files...>
# Example:
#   scripts/build_firmware.sh m2_bringup firmware/linker/de2_115.ld \
#       firmware/startup/crt0.S firmware/tests/m2_bringup_main.c
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/riscv_env.sh"

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <output_name> <linker_script> <source files...>" >&2
    exit 1
fi

OUT_NAME="$1"; shift
LD_SCRIPT="$1"; shift
SOURCES=("$@")

BUILD_DIR="$REPO_ROOT/firmware/build"
mkdir -p "$BUILD_DIR"

CFLAGS="-march=rv32im -mabi=ilp32 -ffreestanding -fno-pic -fno-pie -mno-relax -O1 -g -Wall"
LDFLAGS="-nostdlib -nostartfiles -T $LD_SCRIPT -Wl,-Map=$BUILD_DIR/$OUT_NAME.map"

OBJS=()
for src in "${SOURCES[@]}"; do
    base="$(basename "$src")"
    obj="$BUILD_DIR/${base%.*}.o"
    riscv64-unknown-elf-gcc $CFLAGS -c "$src" -o "$obj"
    OBJS+=("$obj")
done

riscv64-unknown-elf-gcc $CFLAGS $LDFLAGS -o "$BUILD_DIR/$OUT_NAME.elf" "${OBJS[@]}"

riscv64-unknown-elf-objdump -d "$BUILD_DIR/$OUT_NAME.elf" > "$BUILD_DIR/$OUT_NAME.disasm.txt"
riscv64-unknown-elf-readelf -A "$BUILD_DIR/$OUT_NAME.elf" > "$BUILD_DIR/$OUT_NAME.attrs.txt"
riscv64-unknown-elf-nm "$BUILD_DIR/$OUT_NAME.elf" | sort > "$BUILD_DIR/$OUT_NAME.symbols.txt"
riscv64-unknown-elf-objcopy -O binary "$BUILD_DIR/$OUT_NAME.elf" "$BUILD_DIR/$OUT_NAME.bin"

python3 "$SCRIPT_DIR/bin_to_readmemh.py" "$BUILD_DIR/$OUT_NAME.bin" "$BUILD_DIR/$OUT_NAME.hex"

echo "=== $OUT_NAME: build complete ==="
riscv64-unknown-elf-size "$BUILD_DIR/$OUT_NAME.elf"
echo "ELF:  $BUILD_DIR/$OUT_NAME.elf"
echo "HEX:  $BUILD_DIR/$OUT_NAME.hex"
echo "DISASM: $BUILD_DIR/$OUT_NAME.disasm.txt"
