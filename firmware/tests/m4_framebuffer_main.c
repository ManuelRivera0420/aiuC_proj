/*
 * M4/M5 framebuffer animation test: real compiled C, loaded into SDRAM by
 * the bootloader (firmware/bootloader/bootloader_main.c) and executed
 * there, writes two successive "frames" to the on-chip VGA framebuffer
 * through its real memory-mapped address range -- updated for the real
 * DoomGeneric pixel format discovered in M5 (8-bit palette-indexed, see
 * software/source-lock.json's pixel_format_finding), superseding M4's
 * initial 32-bit-RGB-per-pixel placeholder.
 *
 * Only a handful of pixels are written (not the full 64,000-pixel frame)
 * to keep simulation time reasonable; this demonstrates the mechanism,
 * not a claim about real achievable fill rate.
 */
typedef unsigned int u32;
typedef unsigned char u8;

#define POKE(addr, val) (*(volatile u32 *)(addr) = (val))
#define PEEK(addr)      (*(volatile u32 *)(addr))
#define POKE8(addr, val) (*(volatile u8 *)(addr) = (val))

#define VGA_FB_BASE      0x30000000u
#define VGA_PALETTE_BASE 0x30010000u /* framebuffer.sv's PALETTE_BASE offset within the same window */
#define TIMER_CYCLES     0x20000100u

#define DOOM_W 320

static void set_palette(u8 index, u32 rgb888) {
    POKE(VGA_PALETTE_BASE + (u32)index * 4u, rgb888);
}

static void set_pixel(u32 x, u32 y, u8 index) {
    u32 idx = y * DOOM_W + x;
    POKE8(VGA_FB_BASE + idx, index);
}

int main(void) {
    u32 t0;

    set_palette(1, 0xFF0000u); /* index 1 = red */
    set_palette(2, 0x00FF00u); /* index 2 = green */

    /* frame 1: palette index 1 (red) at a handful of points spread across
       the buffer */
    set_pixel(0, 0, 1);
    set_pixel(159, 100, 1);
    set_pixel(319, 199, 1);
    set_pixel(50, 50, 1);

    /* a short busy-wait between frames, using the real timer peripheral */
    t0 = PEEK(TIMER_CYCLES);
    while (PEEK(TIMER_CYCLES) - t0 < 200u) {
        /* spin */
    }

    /* frame 2: the same points switch to palette index 2 (green) --
       proves the buffer is genuinely re-writable, not a write-once latch */
    set_pixel(0, 0, 2);
    set_pixel(159, 100, 2);
    set_pixel(319, 199, 2);
    set_pixel(50, 50, 2);

    return 0;
}
