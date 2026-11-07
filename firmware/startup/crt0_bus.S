/*
 * Startup for the real ROM/RAM split (firmware/linker/de2_115_bus.ld).
 * Unlike firmware/startup/crt0.S (M2's single-flat-memory version), .data
 * now has a load address in ROM different from its run address in RAM, so
 * it must be explicitly copied -- a zero-clear of .bss alone is not
 * enough once a real ROM/RAM split exists (see docs/verification_report.md
 * M2 section, which flagged this as deferred work).
 */
.section .text.start
.global _start
_start:
    la   sp, _stack_top

    /* copy .data from its ROM load image to its RAM run address */
    la   t0, __data_load_start
    la   t1, __data_start
    la   t2, __data_end
copy_data_loop:
    bge  t1, t2, copy_data_done
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    copy_data_loop
copy_data_done:

    /* clear .bss */
    la   t0, __bss_start
    la   t1, __bss_end
clear_bss_loop:
    bge  t0, t1, clear_bss_done
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    clear_bss_loop
clear_bss_done:

    call main
    ecall
halt_spin:
    j    halt_spin
