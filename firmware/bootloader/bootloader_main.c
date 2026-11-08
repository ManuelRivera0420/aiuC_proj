/*
 * M4 bootloader: reads the raw SD boot image (scripts/prepare_sd_image.py
 * format) via sd_spi.sv's MMIO registers, validates the header, copies the
 * program from SD into SDRAM sector-by-sector, then jumps to its entry
 * point. Runs from boot ROM (firmware/linker/de2_115_boot.ld); the program
 * it loads runs from SDRAM (firmware/linker/de2_115_soc.ld).
 *
 * No libc, no filesystem -- a fixed, versioned binary layout only (see
 * docs/sdhc_32gb_boot_protocol.md). LED status codes below double as the
 * only diagnostic available before VGA is up.
 */
typedef unsigned int u32;

#define POKE(addr, val) (*(volatile u32 *)(addr) = (val))
#define PEEK(addr)      (*(volatile u32 *)(addr))

#define GPIO_LED_STATUS   0x2000000Cu

#define SDSPI_CTRL      0x20000200u
#define SDSPI_STATUS    0x20000204u
#define SDSPI_LBA       0x20000208u
#define SDSPI_BUF_DATA  0x2000020Cu

#define SDSPI_CTRL_START_READ  0x2u
#define SDSPI_STATUS_BUSY_BIT  0x1u
#define SDSPI_STATUS_READY_BIT 0x2u
#define SDSPI_STATUS_ERROR_BIT 0x4u

#define IMG_MAGIC_LE 0x4D445652u /* "RVDM" read little-endian: R,V,D,M at offsets 0,1,2,3 */

/* LED status codes -- see docs/boot_process.md (to be written in a later
   pass) for the full table; kept minimal here since this is the first
   real consumer of LED_STATUS. */
#define LED_BOOT_SDSPI_INIT   0x1u
#define LED_BOOT_SDSPI_ERROR  0x2u
#define LED_BOOT_BAD_MAGIC    0x3u
#define LED_BOOT_LOADING      0x4u
#define LED_BOOT_JUMPING      0x5u
#define LED_BOOT_LOADING_WAD  0x6u

static void halt_blink(u32 code) {
    for (;;) {
        POKE(GPIO_LED_STATUS, code);
    }
}

static u32 sdspi_read_block(u32 lba, u32 *dest, u32 word_count) {
    u32 i;
    POKE(SDSPI_LBA, lba);
    POKE(SDSPI_CTRL, SDSPI_CTRL_START_READ);
    while (PEEK(SDSPI_STATUS) & SDSPI_STATUS_BUSY_BIT) {
        /* spin */
    }
    if (PEEK(SDSPI_STATUS) & SDSPI_STATUS_ERROR_BIT) {
        return 1;
    }
    for (i = 0; i < word_count; i++) {
        dest[i] = PEEK(SDSPI_BUF_DATA);
    }
    return 0;
}

int main(void) {
    u32 header[128]; /* one full 512-byte sector */
    u32 magic, load_addr, entry_addr, length, prog_lba_start;
    u32 wad_lba_start, wad_length;
    u32 num_sectors, i;
    volatile u32 *sdram_dst;

    POKE(GPIO_LED_STATUS, LED_BOOT_SDSPI_INIT);

    while (!(PEEK(SDSPI_STATUS) & (SDSPI_STATUS_READY_BIT | SDSPI_STATUS_ERROR_BIT))) {
        /* sd_spi.sv runs its init handshake automatically after reset;
           just wait for ready or error. */
    }
    if (PEEK(SDSPI_STATUS) & SDSPI_STATUS_ERROR_BIT) {
        halt_blink(LED_BOOT_SDSPI_ERROR);
    }

    if (sdspi_read_block(0, header, 128)) {
        halt_blink(LED_BOOT_SDSPI_ERROR);
    }

    magic          = header[0];
    load_addr      = header[2];
    entry_addr     = header[3];
    length         = header[4];
    prog_lba_start = header[5];
    wad_lba_start  = header[6];
    wad_length     = header[7];

    if (magic != IMG_MAGIC_LE) {
        halt_blink(LED_BOOT_BAD_MAGIC);
    }

    POKE(GPIO_LED_STATUS, LED_BOOT_LOADING);

    num_sectors = (length + 511u) / 512u;
    sdram_dst = (volatile u32 *)load_addr;

    for (i = 0; i < num_sectors; i++) {
        u32 sector_words[128];
        u32 w;
        if (sdspi_read_block(prog_lba_start + i, sector_words, 128)) {
            halt_blink(LED_BOOT_SDSPI_ERROR);
        }
        for (w = 0; w < 128; w++) {
            sdram_dst[i * 128u + w] = sector_words[w];
        }
    }

    /* WAD copy: optional -- wad_lba_start is 0 when prepare_sd_image.py
       was run without --wad (every image this project has built so far),
       so this is a no-op for every boot image that predates it, same
       behavior as before this was added. software/doom_port/
       w_file_de2115.c assumes the WAD lands at a fixed 0x14000000
       regardless of what this specific image's load_addr/length were --
       that address is intentionally hardcoded here too rather than
       derived from the header, since it's a property of the FIRMWARE
       being booted (where it expects its WAD), not of the image. */
    if (wad_lba_start != 0u) {
        u32 *const wad_dst = (u32 *)0x14000000u;
        u32 wad_num_sectors = (wad_length + 511u) / 512u;

        POKE(GPIO_LED_STATUS, LED_BOOT_LOADING_WAD);

        for (i = 0; i < wad_num_sectors; i++) {
            u32 sector_words[128];
            u32 w;
            if (sdspi_read_block(wad_lba_start + i, sector_words, 128)) {
                halt_blink(LED_BOOT_SDSPI_ERROR);
            }
            for (w = 0; w < 128; w++) {
                wad_dst[i * 128u + w] = sector_words[w];
            }
        }
    }

    POKE(GPIO_LED_STATUS, LED_BOOT_JUMPING);

    {
        void (*entry)(void) = (void (*)(void))entry_addr;
        entry();
    }

    /* should never return */
    halt_blink(0xFu);
    return 0;
}
