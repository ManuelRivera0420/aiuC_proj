/*
 * M4 framebuffer animation test: real compiled C, loaded into SDRAM by the
 * bootloader (firmware/bootloader/bootloader_main.c) and executed there,
 * writes two successive "frames" (a small set of pixels, chosen across the
 * full 320x200 range, not just the start) to the on-chip VGA framebuffer
 * through its real memory-mapped address range. Proves the CPU can drive
 * actual pixel output through the full write path -- the testbench
 * separately confirms vga.sv's scan-out reads the final values back
 * correctly (sim/tb/m4_e2e_tb.sv).
 *
 * Only a handful of pixels are written (not the full 64,000-pixel frame)
 * to keep simulation time reasonable; this demonstrates the mechanism,
 * not a claim about real achievable fill rate -- see
 * docs/verification_report.md's M4 section for that distinction.
 */
typedef unsigned int u32;

#define POKE(addr, val) (*(volatile u32 *)(addr) = (val))
#define PEEK(addr)      (*(volatile u32 *)(addr))

#define VGA_FB_BASE   0x30000000u
#define TIMER_CYCLES  0x20000100u

#define DOOM_W 320

static void set_pixel(u32 x, u32 y, u32 rgb) {
    u32 idx = y * DOOM_W + x;
    POKE(VGA_FB_BASE + idx * 4u, rgb);
}

int main(void) {
    u32 t0;

    /* frame 1: red at a handful of points spread across the buffer */
    set_pixel(0, 0, 0xFF0000u);
    set_pixel(159, 100, 0xFF0000u);
    set_pixel(319, 199, 0xFF0000u);
    set_pixel(50, 50, 0xFF0000u);

    /* a short busy-wait between frames, using the real timer peripheral */
    t0 = PEEK(TIMER_CYCLES);
    while (PEEK(TIMER_CYCLES) - t0 < 200u) {
        /* spin */
    }

    /* frame 2: the same points turn green -- proves the buffer is
       genuinely re-writable (an "animation"), not a write-once latch */
    set_pixel(0, 0, 0x00FF00u);
    set_pixel(159, 100, 0x00FF00u);
    set_pixel(319, 199, 0x00FF00u);
    set_pixel(50, 50, 0x00FF00u);

    return 0;
}
