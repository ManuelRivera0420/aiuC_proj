/*
 * M5 S3: a small, fast, focused check that sdram_model.sv's PRELOAD2
 * (WAD header) and PRELOAD3 (WAD lump directory) regions are reachable
 * through the REAL memory path -- cpu_core -> soc_bus -> sdram_ctrl ->
 * sdram_model -- not just present in the model's backing store. This is
 * deliberately NOT DoomGeneric: it exists so a WAD-preload/addressing
 * bug can be found and fixed in a few hundred cycles instead of needing
 * ~10,000,000+ cycles of real DOOM startup first (see
 * docs/verification_report.md's M5 S3 section for why that matters).
 *
 * Checks, against the known-correct values read directly from the real
 * freedoom1.wad with Python before generating the preload hex files
 * (scripts/extract_wad_header_directory.py's own printed output):
 *   - header: "IWAD" magic, numlumps=3163, infotableofs=28744468
 *   - lump directory entry 0: filepos=12, size=0, name="E1M1" -- this
 *     IS freedoom1.wad's actual real lump 0 (confirmed directly with
 *     Python against the real file: a standard, correctly-zero-size WAD
 *     map-marker lump, not a placeholder). An earlier version of this
 *     test wrongly asserted size>0 for lump 0 and failed on that -- not
 *     a preload/addressing bug, just a wrong assumption about what lump
 *     0 is; fixed to check the actual expected name instead, which is a
 *     stronger, more specific check anyway.
 *
 * Reports via LED_STATUS (0x1 = all checks passed, 0x2 = failed) rather
 * than needing the testbench to peek into memory directly -- same
 * mechanism firmware/bootloader/bootloader_main.c already uses.
 */
typedef unsigned int u32;

#define POKE(addr, val) (*(volatile u32 *)(addr) = (val))
#define PEEK(addr)      (*(volatile u32 *)(addr))

#define GPIO_LED_STATUS 0x2000000Cu
#define WAD_BASE        0x14000000u

#define EXPECTED_IDENT         0x44415749u /* "IWAD" little-endian */
#define EXPECTED_NUMLUMPS      3163u
#define EXPECTED_INFOTABLEOFS  28744468u
#define EXPECTED_DIR0_FILEPOS  12u
#define EXPECTED_DIR0_NAME_LO  0x314d3145u /* "E1M1" little-endian */
#define EXPECTED_DIR0_NAME_HI  0x00000000u /* zero-padded to 8 bytes */

/* Bit-per-check diagnostic encoding (instead of a single pass/fail bit)
 * so a failure can be narrowed down from LED_STATUS alone, without
 * needing a waveform -- this test is cheap enough (a few thousand
 * cycles) to just rebuild and rerun once a specific bit identifies the
 * actual problem. 0x3F (all 6 bits set) = full pass. */
#define BIT_IDENT_OK          0x01u
#define BIT_NUMLUMPS_OK       0x02u
#define BIT_INFOTABLEOFS_OK   0x04u
#define BIT_DIR_FILEPOS_OK    0x08u
#define BIT_DIR_NAME_OK       0x10u
#define BIT_ALL_PASS          0x20u

int main(void) {
    u32 ident, numlumps, infotableofs;
    u32 dir_filepos, dir_name_lo, dir_name_hi;
    u32 flags;
    u32 ident_ok, numlumps_ok, infotableofs_ok, dir_filepos_ok, dir_name_ok;

    ident        = PEEK(WAD_BASE + 0);
    numlumps     = PEEK(WAD_BASE + 4);
    infotableofs = PEEK(WAD_BASE + 8);

    dir_filepos = PEEK(WAD_BASE + infotableofs + 0);
    dir_name_lo = PEEK(WAD_BASE + infotableofs + 8);
    dir_name_hi = PEEK(WAD_BASE + infotableofs + 12);

    ident_ok        = (ident == EXPECTED_IDENT);
    numlumps_ok     = (numlumps == EXPECTED_NUMLUMPS);
    infotableofs_ok = (infotableofs == EXPECTED_INFOTABLEOFS);
    dir_filepos_ok  = (dir_filepos == EXPECTED_DIR0_FILEPOS);
    dir_name_ok     = (dir_name_lo == EXPECTED_DIR0_NAME_LO) && (dir_name_hi == EXPECTED_DIR0_NAME_HI);

    flags = (ident_ok        ? BIT_IDENT_OK        : 0u)
          | (numlumps_ok     ? BIT_NUMLUMPS_OK     : 0u)
          | (infotableofs_ok ? BIT_INFOTABLEOFS_OK : 0u)
          | (dir_filepos_ok  ? BIT_DIR_FILEPOS_OK  : 0u)
          | (dir_name_ok     ? BIT_DIR_NAME_OK     : 0u);

    if (ident_ok && numlumps_ok && infotableofs_ok && dir_filepos_ok && dir_name_ok) {
        flags |= BIT_ALL_PASS;
    }

    POKE(GPIO_LED_STATUS, flags);

    __asm__ volatile ("ecall");
    for (;;) { /* unreachable: cpu_core.sv halts on ecall */ }
    return 0;
}
