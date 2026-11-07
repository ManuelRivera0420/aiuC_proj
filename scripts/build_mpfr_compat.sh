#!/usr/bin/env bash
# Rebuilds the libmpfr.so.4 compatibility library that scripts/riscv_env.sh
# needs (see that file and docs/known_limitations.md for why). User-space
# only, no root required. Idempotent: safe to re-run.
#
# Builds under .build_tmp/ (project-local persistent dir, NOT /tmp) -- see
# scripts/workspace_env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/workspace_env.sh"

SCRATCH="${1:-$WORKSPACE_TMP}"
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
