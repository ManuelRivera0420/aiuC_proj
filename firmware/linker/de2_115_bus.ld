/*
 * M3 bus-integration linker script: a real ROM (code + .data's initial
 * image) vs RAM (.data's runtime location, .bss, stack) split, matching
 * docs/memory_map.md's ROM_BASE=0x0/BRAM_BASE=0x10000 regions. Unlike
 * M2's single-flat-region script, .data now has a DIFFERENT load address
 * (in ROM) than its virtual/run address (in RAM), so crt0_bus.S must
 * explicitly copy it at startup -- not just clear .bss.
 */

MEMORY
{
    ROM  (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    RAM  (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
}

ENTRY(_start)

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text .text.*)
    } > ROM

    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > ROM

    .data : {
        __data_start = .;
        *(.data .data.* .sdata .sdata.*)
        __data_end = .;
    } > RAM AT> ROM
    __data_load_start = LOADADDR(.data);

    .bss : {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    __heap_start = .;

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
