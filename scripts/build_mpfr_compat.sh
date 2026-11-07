#!/usr/bin/env bash
# Rebuilds the libmpfr.so.4 compatibility library that scripts/riscv_env.sh
# needs (see that file and docs/known_limitations.md for why). User-space
# only, no root required. Idempotent: safe to re-run.
set -euo pipefail

SCRATCH_DEFAULT="/tmp/claude-5012/-home-marivera-Documents-aiuC-proj/49fcab7d-b4c6-48cd-af52-bda387f5d78d/scratchpad"
SCRATCH="${1:-$SCRATCH_DEFAULT}"
BUILD_DIR="$SCRATCH/mpfr_build"
PREFIX="$SCRATCH/mpfr_local"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -f mpfr-3.1.6.tar.gz ]; then
    curl -sL --max-time 60 -o mpfr-3.1.6.tar.gz https://ftp.gnu.org/gnu/mpfr/mpfr-3.1.6.tar.gz
fi
tar xzf mpfr-3.1.6.tar.gz
cd mpfr-3.1.6
./configure --prefix="$PREFIX" --with-gmp=/usr
make -j"$(nproc)"
make install

echo "libmpfr.so.4 compat build installed to $PREFIX/lib"
ls -la "$PREFIX/lib/libmpfr.so.4"*
