/*
 * M4 full-SoC linker script, matching docs/memory_map.md exactly:
 *   ROM   0x0000_0000 - 0x0000_FFFF  (boot code + .data load image)
 *   BRAM  0x0001_0000 - 0x0001_FFFF  (bootloader scratch RAM/stack, if ever needed standalone)
 *   SDRAM 0x1000_0000 - 0x17FF_FFFF  (real program's .text/.data/.bss/heap/stack once loaded)
 *
 * This script is for the REAL PROGRAM that the bootloader loads into
 * SDRAM and jumps to -- it links entirely against the SDRAM region,
 * since by the time it runs, the bootloader has already copied it there
 * and SDRAM is fully initialized. The BOOTLOADER itself uses a different,
 * ROM-resident script (de2_115_boot.ld, alongside this file).
 */

MEMORY
{
    SDRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 1M   /* 1 MiB window for this test program; full 128MB available */
}

ENTRY(_start)

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text .text.*)
    } > SDRAM

    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > SDRAM

    .data : {
        __data_start = .;
        *(.data .data.* .sdata .sdata.*)
        __data_end = .;
    } > SDRAM

    .bss : {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > SDRAM

    . = ALIGN(16);
    __heap_start = .;

    _stack_top = ORIGIN(SDRAM) + LENGTH(SDRAM);
}
