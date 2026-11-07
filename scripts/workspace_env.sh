#!/usr/bin/env bash
# Sets TMPDIR/TMP/TEMP to a persistent, project-local directory instead of
# the shared /tmp filesystem. /tmp on this host is its own small volume
# (/dev/mapper/vg_os-lv_tmp, 20G) that was observed at 84% full and
# shared across every user/session on this multi-tenant machine -- see
# docs/known_limitations.md for the measured numbers and what was found
# living there. /home has far more headroom (300G volume, <70% used), so
# anything this project creates -- compiler temp files, build scratch,
# downloaded archives -- should go under the repo instead.
#
# Source this BEFORE any compilation/build command. scripts/riscv_env.sh
# already does this for you.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export WORKSPACE_TMP="$REPO_ROOT/.build_tmp"
mkdir -p "$WORKSPACE_TMP"
export TMPDIR="$WORKSPACE_TMP"
export TMP="$WORKSPACE_TMP"
export TEMP="$WORKSPACE_TMP"
