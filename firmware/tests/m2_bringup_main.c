/*
 * M2 bare-metal bring-up test: proves cpu_core.sv can run real compiled C
 * (not hand-written assembly) with a correctly initialized stack, .data,
 * and .bss. No libc, no syscalls -- results are written to fixed memory
 * addresses via volatile pointers (the same MMIO-register idiom the real
 * peripheral drivers will use later) for the testbench to check directly.
 */
typedef unsigned int u32;

#define POKE(addr, val) (*(volatile u32 *)(addr) = (val))

/* .data: nonzero initializer -- proves .data's load image is correct.
   volatile so -O1 can't constant-fold the read away (it did, silently,
   before this was added -- see docs/verification_report.md M2 bugs). */
static volatile u32 g_initialized = 0x1234ABCDu;

/* .bss: no initializer -- proves crt0's explicit zero-clear actually ran. */
static volatile u32 g_zero;

static u32 add_u32(u32 a, u32 b) {
    return a + b;
}

int main(void) {
    /* stack-resident array + loop: proves sp is valid and stack memory is
       writable/readable at the addresses the linker script assigned. */
    u32 local_arr[4];
    for (u32 i = 0; i < 4; i++) {
        local_arr[i] = i * i;
    }
    u32 sum = 0;
    for (u32 i = 0; i < 4; i++) {
        sum += local_arr[i];
    }

    POKE(0x2000, g_initialized);        /* expect 0x1234ABCD */
    POKE(0x2004, g_zero);                /* expect 0x00000000 */
    POKE(0x2008, sum);                    /* expect 14 (0+1+4+9) */
    POKE(0x200C, add_u32(111, 222));       /* expect 333: function call/return via stack */

    g_zero = 0xCAFEBABEu;                   /* .bss must be ordinary writable RAM */
    POKE(0x2010, g_zero);                    /* expect 0xCAFEBABE */

    return 0;
}
