.option norvc
.section .text
.globl _start
_start:
    li   t0, 0x10000000
    jalr x0, t0, 0
