/*
 * M5 S3 finding: D_FindIWAD() (software/upstream/doomgeneric/d_iwad.c)
 * only ever succeeds by finding a REAL file on a REAL filesystem --
 * either via the "-iwad <path>" command-line argument (which still goes
 * through D_FindWADByName()'s M_FileExists() check) or by searching a
 * list of directories built from environment variables. Both paths
 * depend on a working fopen()/stat()-backed filesystem, which this
 * target genuinely does not have (firmware/platform/syscalls.c's _open
 * always fails) -- so D_FindIWAD() can never return non-NULL here,
 * meaning D_DoomMain() always hits its own "No IWAD file was found"
 * I_Error() before ever reaching software/doom_port/w_file_de2115.c's
 * custom WAD backend at all. Confirmed by direct execution: see
 * docs/verification_report.md's M5 S3 section for the trace that led
 * here (the engine halted via I_Error after ~11.6M cycles, still inside
 * early D_DoomMain()-path code, with the WAD region never even touched).
 *
 * This is a genuine integration gap distinct from (and found after) the
 * "bootloader doesn't copy the WAD" gap fixed earlier in M5/M6 -- fixing
 * that alone was not going to be enough, because this gate sits BEFORE
 * any WAD content is ever read.
 *
 * Fixed WITHOUT patching upstream d_iwad.c/d_main.c: scripts/build_doom.sh
 * links with `-Wl,--wrap=D_FindIWAD`, which redirects every call to
 * D_FindIWAD() to __wrap_D_FindIWAD() below instead. This target has
 * exactly one WAD, always preloaded at a fixed SDRAM address by
 * w_file_de2115.c -- there is nothing to search for, so this skips the
 * entire filesystem-search mechanism and returns a fixed, non-NULL,
 * dummy name immediately. software/doom_port/w_file_de2115.c's own
 * De2115_OpenFile() ignores the string it's given (same reason: a
 * single, fixed, preloaded WAD, no path lookup), so the exact contents
 * of this string don't matter -- it only needs to be non-NULL so
 * d_main.c's `if (iwadfile == NULL)` check passes and proceeds to
 * D_AddFile(iwadfile) -> W_AddFile() -> W_OpenFile() -> our backend.
 */
#include "d_mode.h"

char *__wrap_D_FindIWAD(int mask, GameMission_t *mission) {
    (void)mask;
    *mission = doom; /* freedoom1.wad is a Doom-1-style IWAD */
    return "wad";
}
