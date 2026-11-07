#!/usr/bin/env bash
# Source this to get a working riscv64-unknown-elf-gcc (RV32IM/ILP32 capable)
# in the current shell.
#
# Why this exists: the module-provided toolchain's cc1 is linked against
# libmpfr.so.4, but this host only has libmpfr.so.6 (mpfr 4.1.0) installed
# system-wide, and there is no root access to add the old ABI package.
# Fix: build MPFR 3.1.6 from source (provides libmpfr.so.4) into a
# user-space prefix and point LD_LIBRARY_PATH at it. See
# docs/known_limitations.md for the full story and PROJECT_STATE.md for
# where this is used.
#
# The MPFR 3.1.6 build itself lives under the session scratchpad, which is
# NOT part of this repo and will not survive into a fresh environment --
# if that directory is gone, rebuild it with scripts/build_mpfr_compat.sh
# before sourcing this file.

set -u
source /etc/profile.d/modules.sh
module load riscv-gnu-toolchain/elf-multilib/2026.07.15-elf

MPFR_COMPAT_LIB="${MPFR_COMPAT_LIB:-/tmp/claude-5012/-home-marivera-Documents-aiuC-proj/49fcab7d-b4c6-48cd-af52-bda387f5d78d/scratchpad/mpfr_local/lib}"
if [ -d "$MPFR_COMPAT_LIB" ]; then
    export LD_LIBRARY_PATH="$MPFR_COMPAT_LIB:${LD_LIBRARY_PATH:-}"
else
    echo "WARNING: $MPFR_COMPAT_LIB not found -- riscv64-unknown-elf-gcc's cc1 will fail" \
         "with 'libmpfr.so.4: cannot open shared object file'. Rebuild it with" \
         "scripts/build_mpfr_compat.sh first." >&2
fi
