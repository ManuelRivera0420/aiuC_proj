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
 *   - lump directory entry 0: plausible filepos/size (nonzero size,
 *     filepos before the directory itself -- a loose sanity check, not
 *     a specific expected lump, since this doesn't hardcode which lump
 *     freedoom1.wad's entry 0 happens to be)
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

int main(void) {
    u32 ident, numlumps, infotableofs;
    u32 dir_filepos, dir_size;
    u32 ok;

    ident        = PEEK(WAD_BASE + 0);
    numlumps     = PEEK(WAD_BASE + 4);
    infotableofs = PEEK(WAD_BASE + 8);

    dir_filepos = PEEK(WAD_BASE + infotableofs + 0);
    dir_size    = PEEK(WAD_BASE + infotableofs + 4);

    ok = (ident == EXPECTED_IDENT)
      && (numlumps == EXPECTED_NUMLUMPS)
      && (infotableofs == EXPECTED_INFOTABLEOFS)
      && (dir_size > 0)
      && (dir_filepos < infotableofs);

    POKE(GPIO_LED_STATUS, ok ? 0x1u : 0x2u);

    __asm__ volatile ("ecall");
    for (;;) { /* unreachable: cpu_core.sv halts on ecall */ }
    return 0;
}
