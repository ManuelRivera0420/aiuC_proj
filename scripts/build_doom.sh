#!/usr/bin/env bash
# Builds DoomGeneric (software/upstream/doomgeneric/) for this project's
# bare-metal RV32IM target, linking against the toolchain's bundled
# Newlib (confirmed present and built for rv32im/ilp32 -- see
# docs/known_limitations.md) plus our own syscall stubs and platform
# hooks. Excludes every other platform's doomgeneric_*.c/i_*sound*.c/
# i_*music*.c/net_*.c (SDL/X11/Windows/network -- out of scope) and the
# host w_file_stdc.c (replaced by software/doom_port/w_file_de2115.c,
# which exports the same `stdc_wad_file` symbol w_file.c expects).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/riscv_env.sh"

DG_SRC="$REPO_ROOT/software/upstream/doomgeneric"
PORT_SRC="$REPO_ROOT/software/doom_port"
BUILD_DIR="$REPO_ROOT/firmware/build/doom"
mkdir -p "$BUILD_DIR"

CFLAGS="-march=rv32im -mabi=ilp32 -ffreestanding -fno-pic -fno-pie -mno-relax -O1 -g -Wall \
-DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -DNORMALUNIX=0 \
-I$DG_SRC -I$PORT_SRC"

# Every doomgeneric/*.c EXCEPT: other platforms' doomgeneric_*.c backends,
# sound/music backends (allegro/sdl/soso), networking (we're single-player,
# no net_sdl.c etc. needed -- but d_net.c itself, the generic dispatcher,
# IS kept), the host WAD backend, icon.c (SDL-specific), and statdump.c
# (debug stats dump tool, not part of the engine).
EXCLUDE_PATTERN='doomgeneric_allegro|doomgeneric_emscripten|doomgeneric_linuxvt|doomgeneric_sdl|doomgeneric_soso|doomgeneric_sosox|doomgeneric_win|doomgeneric_xlib|i_allegromusic|i_allegrosound|i_sdlmusic|i_sdlsound|w_file_stdc|icon\.c'

mapfile -t SOURCES < <(find "$DG_SRC" -maxdepth 1 -name '*.c' | grep -vE "$EXCLUDE_PATTERN" | sort)
SOURCES+=("$PORT_SRC/doomgeneric_de2115.c" "$PORT_SRC/w_file_de2115.c" "$PORT_SRC/main_de2115.c")
SOURCES+=("$REPO_ROOT/firmware/platform/syscalls.c")
SOURCES+=("$REPO_ROOT/firmware/startup/crt0.S")

echo "=== ${#SOURCES[@]} source files ==="

FAILED=0
OBJS=()
for src in "${SOURCES[@]}"; do
    base="$(basename "$src")"
    obj="$BUILD_DIR/${base%.*}.o"
    if riscv64-unknown-elf-gcc $CFLAGS -c "$src" -o "$obj" 2>"$BUILD_DIR/${base%.*}.err.txt"; then
        OBJS+=("$obj")
    else
        echo "FAIL: $base"
        FAILED=$((FAILED+1))
    fi
done

echo "=== compiled $((${#SOURCES[@]} - FAILED)) / ${#SOURCES[@]}, $FAILED failures ==="
if [ "$FAILED" -gt 0 ]; then
    echo "--- first failing file's errors ---"
    for f in "$BUILD_DIR"/*.err.txt; do
        if [ -s "$f" ]; then
            echo "=== $f ==="
            head -20 "$f"
            break
        fi
    done
fi

if [ "$FAILED" -eq 0 ]; then
    echo "=== attempting link ==="
    riscv64-unknown-elf-gcc $CFLAGS -nostdlib \
        -T "$REPO_ROOT/firmware/linker/de2_115_soc.ld" \
        -Wl,--defsym=__heap_start_doom=0 \
        -o "$BUILD_DIR/doom.elf" "${OBJS[@]}" -lm -lc -lgcc 2>"$BUILD_DIR/link.err.txt"
    LINK_STATUS=$?
    if [ "$LINK_STATUS" -eq 0 ]; then
        echo "LINK OK"
        riscv64-unknown-elf-size "$BUILD_DIR/doom.elf"
    else
        echo "LINK FAILED:"
        cat "$BUILD_DIR/link.err.txt"
    fi
fi
