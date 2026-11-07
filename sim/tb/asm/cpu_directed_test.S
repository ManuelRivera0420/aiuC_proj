/*
 * M1 directed ISA test for cpu_core.sv. Hand-assembled with the real
 * RV32IM toolchain (not written as raw machine code) and self-checking:
 * the testbench asserts final register-file / memory contents computed
 * independently (by hand, in sim/tb/cpu_core_tb.sv) from this source,
 * not from anything the CPU itself produced.
 *
 * Register convention notes (see docs/verification_report.md for the
 * full expected-value table):
 *   x1  is reused as a JAL link register near the end -- its earlier
 *       value (5) is NOT asserted at halt, only values that depend on
 *       it (x3,x4,x5,x7,x8,x9 etc.) are, which is still a valid
 *       indirect check of x1's correctness at the time it was 5.
 *   x14, x20 are reused as general scratch throughout and are not
 *       asserted at halt.
 */
.section .text
.global _start
_start:
    li   x1, 5
    li   x2, 7
    add  x3, x1, x2            /* 12 */
    sub  x4, x2, x1             /* 2  */
    slli x5, x1, 2               /* 20 */
    andi x6, x2, 0x6              /* 6  */
    ori  x7, x1, 0x8               /* 13 */
    xori x8, x1, 0xFF                /* 250 */
    slt  x9, x1, x2                   /* 1 */
    sltu x10, x2, x1                   /* 0 */

    /* auipc + jalr self-relative jump: proves target computation, not
       just control-transfer-happens like the branches below do. */
    auipc x11, 0
    addi  x11, x11, 20          /* skip addi(this,4B)+jalr(4B)+li-badbad(8B) = 16B, land 20B past auipc */
    jalr  x0, x11, 0
    li    x30, 0xBADBAD        /* must be skipped -- stays 0 if correct */
    li    x31, 0x900DF00D      /* must be the landing point */

    lui  x12, 0x12345           /* 0x12345000 */

    li   x13, -1                 /* 0xFFFFFFFF, used for signed/unsigned tests */
    slt  x23, x13, x1              /* -1 <s 5  -> 1 */
    sltu x26, x13, x1                /* 0xFFFFFFFF <u 5 -> 0 */

    li   x20, 0x1000
    li   x14, 100
    sw   x14, 0(x20)              /* mem word @0x1000 = 100 */
    lw   x15, 0(x20)                /* 100 */
    sb   x1, 4(x20)                   /* mem byte @0x1004 = 5 (lane0) */
    lbu  x16, 4(x20)                    /* 5 */
    lb   x17, 4(x20)                      /* 5 */
    sb   x2, 5(x20)                        /* mem byte @0x1005 = 7 (lane1) */

    mul  x18, x1, x2                         /* 35 */
    div  x19, x2, x1                           /* 1 */
    rem  x21, x2, x1                             /* 2 */

    li   x22, 0xBAD0
    beq  x1, x1, Lskip22        /* always taken */
    li   x22, 0xDEAD0
Lskip22:

    li   x24, 0xBAD1
    bne  x1, x2, Lskip24        /* 5 != 7, taken */
    li   x24, 0xDEAD1
Lskip24:

    li   x25, 0xBAD2
    beq  x1, x2, Lskip25        /* 5 == 7 false, NOT taken: fallthrough must execute */
    li   x25, 0x600D2
Lskip25:

    li   x14, 0xB1
    blt  x13, x1, Lblt_ok        /* -1 <s 5 -> taken */
    li   x14, 0xDE
Lblt_ok:
    sw   x14, 8(x20)               /* mem word @0x1008 = 0xB1 */

    li   x14, 0xB2
    bgeu x13, x1, Lbgeu_ok        /* 0xFFFFFFFF >=u 5 -> taken (would fail if signed compare used) */
    li   x14, 0xDE2
Lbgeu_ok:
    sw   x14, 12(x20)               /* mem word @0x100C = 0xB2 */

    li   x27, 0x1111
    jal  x1, myfunc                 /* call: x1 <- return address */
    li   x28, 0x3333                  /* only reached if jalr-return worked */
    j    after_func
myfunc:
    li   x29, 0x2222
    jalr x0, x1, 0                     /* return */
after_func:

    ecall
