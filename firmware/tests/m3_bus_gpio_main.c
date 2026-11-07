/*
 * M3 bus-integration bring-up: real compiled C running on cpu_core.sv +
 * soc_bus.sv, reading the GPIO and timer peripherals through their real
 * memory-mapped addresses (docs/memory_map.md), and exercising the real
 * ROM(code+.data-image)/RAM(.data-runtime+.bss+stack) split via
 * firmware/linker/de2_115_bus.ld + firmware/startup/crt0_bus.S.
 */
typedef unsigned int u32;

#define POKE(addr, val) (*(volatile u32 *)(addr) = (val))
#define PEEK(addr)      (*(volatile u32 *)(addr))

#define GPIO_KEY_STATUS 0x20000000u
#define GPIO_SW_LEVEL   0x20000004u
#define TIMER_CYCLES    0x20000100u

/* .data, nonzero: proves the ROM->RAM .data copy in crt0_bus.S ran. */
static volatile u32 g_data_marker = 0xA5A5A5A5u;

int main(void) {
    u32 key = PEEK(GPIO_KEY_STATUS);
    u32 sw  = PEEK(GPIO_SW_LEVEL);
    u32 t0  = PEEK(TIMER_CYCLES);
    u32 t1  = PEEK(TIMER_CYCLES);

    POKE(0x11000, key);
    POKE(0x11004, sw);
    POKE(0x11008, (t1 > t0) ? 1u : 0u);  /* timer is actually free-running */
    POKE(0x1100C, g_data_marker);          /* .data copy worked */
    POKE(0x11010, 0xC0FFEEu);               /* ordinary RAM writes still work */

    return 0;
}
