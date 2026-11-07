/*
 * Minimal RV32IM freestanding startup. No OS, no semihosting, no assumption
 * of a preinitialized environment beyond what cpu_core.sv + the boot image
 * actually provide: a stack pointer must be set up here, .bss must be
 * explicitly cleared here (the memory is NOT guaranteed zero -- see
 * firmware/linker/de2_115.ld), and there is nothing to return to after
 * main(), so we halt via ECALL (cpu_core.sv asserts `halted`+`ecall_seen`
 * on ECALL; this is the only defined program-exit mechanism in M1/M2).
 */
.section .text.start
.global _start
_start:
    la   sp, _stack_top

    /* clear .bss: __bss_start/__bss_end come from firmware/linker/de2_115.ld */
    la   t0, __bss_start
    la   t1, __bss_end
clear_bss_loop:
    bge  t0, t1, clear_bss_done
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    clear_bss_loop
clear_bss_done:

    call main

    /* main() returned (or should never be reached if it doesn't): halt. */
    ecall
halt_spin:
    j    halt_spin
