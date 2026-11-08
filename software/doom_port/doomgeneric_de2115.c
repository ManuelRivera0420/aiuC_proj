/*
 * Bare-metal platform hooks for DoomGeneric on this project's RV32IM SoC.
 * Implements the contract in software/upstream/doomgeneric/doomgeneric.h
 * against this project's real memory map (docs/memory_map.md) -- no SDL,
 * no X11, no OS. Pixel format is 8-bit palette-indexed at the engine's
 * true native 320x200 resolution (see software/source-lock.json's
 * pixel_format_finding); this file must be compiled with
 * -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 for every
 * translation unit that includes doomgeneric.h (scripts/build_doom.sh
 * sets this consistently).
 */
#include <stdint.h>
#include "doomgeneric.h"
#include "doomkeys.h"
#include "i_video.h" /* for struct color / colors[] / palette_changed --
                        see the DG_DrawFrame palette-push comment below */

#define POKE(addr, val)  (*(volatile uint32_t *)(addr) = (val))
#define PEEK(addr)       (*(volatile uint32_t *)(addr))
#define POKE8(addr, val) (*(volatile uint8_t *)(addr) = (val))

#define VGA_FB_BASE      0x30000000u
#define VGA_PALETTE_BASE 0x30010000u

#define GPIO_KEY_STATUS  0x20000000u /* bits[3:1] = KEY[3:1], active-high synchronized */
#define GPIO_SW_LEVEL    0x20000004u /* bits[17:0] = SW[17:0], level */
#define GPIO_SW_EDGE     0x20000008u /* bits[17:0], sticky rising-edge, clear-on-read */

#define TIMER_CYCLES     0x20000100u

/* Locked onboard control mapping -- Section 2A of the mission brief.
   KEY[1]=turn left, KEY[2]=turn right, KEY[3]=fire/confirm (held);
   SW[0..3]=move fwd/back/strafe L/R (level); SW[4..7]=use/weapon/menu/
   select (edge). Translated here into DoomGeneric's DG_GetKey queue. */
#define KEY_BIT_TURN_LEFT  1u
#define KEY_BIT_TURN_RIGHT 2u
#define KEY_BIT_FIRE       3u

#define SW_BIT_FORWARD   0u
#define SW_BIT_BACKWARD  1u
#define SW_BIT_STRAFE_L  2u
#define SW_BIT_STRAFE_R  3u
#define SW_BIT_USE       4u
#define SW_BIT_WEAPON    5u
#define SW_BIT_MENU      6u
#define SW_BIT_SELECT    7u

/* Small fixed-size key-event queue: DG_GetKey drains one event per call,
   i_input.c calls it in a `while` loop until it returns 0, matching the
   contract every other platform backend (doomgeneric_sdl.c etc.) uses. */
#define KEYQUEUE_SIZE 32
static uint8_t  s_KeyQueuePressed[KEYQUEUE_SIZE];
static uint8_t  s_KeyQueueKey[KEYQUEUE_SIZE];
static uint32_t s_KeyQueueHead = 0;
static uint32_t s_KeyQueueTail = 0;

static void push_key(int pressed, unsigned char key) {
    uint32_t next = (s_KeyQueueTail + 1u) % KEYQUEUE_SIZE;
    if (next == s_KeyQueueHead) {
        return; /* queue full: drop the event rather than corrupt it */
    }
    s_KeyQueuePressed[s_KeyQueueTail] = (uint8_t)pressed;
    s_KeyQueueKey[s_KeyQueueTail]     = key;
    s_KeyQueueTail = next;
}

/* Level-sensitive inputs (KEY turn/fire, SW movement) are polled every
   tick and converted to press/release edges here, since DoomGeneric's
   input model is edge-based (key-down/key-up events), not level-based. */
static uint32_t s_PrevKeyLevel = 0;
static uint32_t s_PrevSwLevel  = 0;

static void poll_level_inputs(void) {
    uint32_t key = PEEK(GPIO_KEY_STATUS);
    uint32_t sw  = PEEK(GPIO_SW_LEVEL);
    uint32_t changed;

    changed = key ^ s_PrevKeyLevel;
    if (changed & (1u << KEY_BIT_TURN_LEFT))
        push_key((key >> KEY_BIT_TURN_LEFT) & 1u, KEY_LEFTARROW);
    if (changed & (1u << KEY_BIT_TURN_RIGHT))
        push_key((key >> KEY_BIT_TURN_RIGHT) & 1u, KEY_RIGHTARROW);
    if (changed & (1u << KEY_BIT_FIRE))
        push_key((key >> KEY_BIT_FIRE) & 1u, KEY_FIRE);
    s_PrevKeyLevel = key;

    changed = sw ^ s_PrevSwLevel;
    if (changed & (1u << SW_BIT_FORWARD))
        push_key((sw >> SW_BIT_FORWARD) & 1u, KEY_UPARROW);
    if (changed & (1u << SW_BIT_BACKWARD))
        push_key((sw >> SW_BIT_BACKWARD) & 1u, KEY_DOWNARROW);
    if (changed & (1u << SW_BIT_STRAFE_L))
        push_key((sw >> SW_BIT_STRAFE_L) & 1u, KEY_STRAFE_L);
    if (changed & (1u << SW_BIT_STRAFE_R))
        push_key((sw >> SW_BIT_STRAFE_R) & 1u, KEY_STRAFE_R);
    s_PrevSwLevel = sw;
}

/* Edge-triggered inputs (SW use/weapon/menu/select) come straight from
   the GPIO controller's own sticky rising-edge latch (rtl/peripherals/
   key_sw_gpio.sv's SW_EDGE register) -- always a clean single press
   event per physical toggle, no debounce/edge logic needed here. */
static void poll_edge_inputs(void) {
    uint32_t edges = PEEK(GPIO_SW_EDGE); /* clear-on-read */
    if (edges & (1u << SW_BIT_USE))    { push_key(1, KEY_USE); push_key(0, KEY_USE); }
    /* Vanilla DOOM has no dedicated "next weapon" key -- weapon choice is
       normally the number keys 1-7. Mapped to '2' (pistol/chainsaw slot)
       as a simple, documented substitute; a real menu-driven weapon
       cycle would need more switches than the mission's locked mapping
       allocates. */
    if (edges & (1u << SW_BIT_WEAPON)) { push_key(1, '2'); push_key(0, '2'); }
    if (edges & (1u << SW_BIT_MENU))   { push_key(1, KEY_ESCAPE); push_key(0, KEY_ESCAPE); }
    if (edges & (1u << SW_BIT_SELECT)) { push_key(1, KEY_ENTER); push_key(0, KEY_ENTER); }
}

void DG_Init(void) {
    /* Nothing to do: cpu_core/soc_bus/framebuffer/vga are already running
       from reset by the time main() is reached -- there is no separate
       "open a window" step on bare metal. */
}

void DG_DrawFrame(void) {
    /* DG_ScreenBuffer is exactly 320*200 bytes of palette index (see the
       CMAP256 + matching-resolution build flags), laid out row-major,
       matching framebuffer.sv's pixel layout exactly -- a straight
       byte-for-byte copy via the MMIO window. */
    const uint8_t *src = (const uint8_t *)DG_ScreenBuffer;
    for (int i = 0; i < DOOMGENERIC_RESX * DOOMGENERIC_RESY; i++) {
        POKE8(VGA_FB_BASE + (uint32_t)i, src[i]);
    }

    /* Push the game's palette to hardware whenever it changes (damage
       flash, berserk tint, etc). i_video.c's CMAP256 build declares both
       `colors` and `palette_changed` as plain (non-static) globals --
       see i_video.c's #ifdef CMAP256 block -- specifically so a platform
       backend can read them directly, exactly as doomgeneric_allegro.c
       already does. No patch to upstream i_video.c needed. */
    if (palette_changed) {
        for (int i = 0; i < 256; i++) {
            uint32_t rgb = ((uint32_t)colors[i].r << 16) |
                           ((uint32_t)colors[i].g << 8) |
                           ((uint32_t)colors[i].b);
            POKE(VGA_PALETTE_BASE + (uint32_t)i * 4u, rgb);
        }
        palette_changed = false;
    }

    poll_level_inputs();
    poll_edge_inputs();
}

void DG_SleepMs(uint32_t ms) {
    /* No RTOS, no interrupts: busy-wait against the free-running cycle
       counter. Cycle-to-ms conversion assumes the eventual 50MHz board
       clock (mission's locked clock source) -- NOT yet confirmed against
       the real FPGA-synthesized frequency, flagged here rather than
       silently assumed correct post-synthesis. */
    uint32_t start = PEEK(TIMER_CYCLES);
    uint32_t target_cycles = ms * 50000u; /* 50 MHz => 50000 cycles/ms */
    while (PEEK(TIMER_CYCLES) - start < target_cycles) {
        /* spin */
    }
}

uint32_t DG_GetTicksMs(void) {
    /* See the DG_SleepMs note above re: the 50MHz assumption. */
    return PEEK(TIMER_CYCLES) / 50000u;
}

int DG_GetKey(int *pressed, unsigned char *doomKey) {
    if (s_KeyQueueHead == s_KeyQueueTail) {
        return 0; /* queue empty */
    }
    *pressed = s_KeyQueuePressed[s_KeyQueueHead];
    *doomKey = s_KeyQueueKey[s_KeyQueueHead];
    s_KeyQueueHead = (s_KeyQueueHead + 1u) % KEYQUEUE_SIZE;
    return 1;
}

void DG_SetWindowTitle(const char *title) {
    (void)title; /* no window, nothing to do */
}
