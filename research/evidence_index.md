# Evidence Index

Every PASS claim below links to a reproducible artifact. "Reproducible" means: re-running the cited command against the cited source files, in this same project, should regenerate the cited log/zwdb.

| Claim | Evidence | How to reproduce |
|---|---|---|
| RV32I ALU (10 ops incl. ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND) is functionally correct for the tested vectors | `output/zsim.log` (via Animas `get_last_sim_result`: error_count=0, warning_count=0, finish_time=91ns); raw PASS lines for all 10 directed ALU vectors + zero-flag check | Animas MCP: `set_sim_top(sim/tb/alu_regfile_tb.sv)` → `run_simulation(project_id)` → `get_last_sim_result` / `read_simulation_log` |
| RV32I register file: reset clears all regs, x0 is hardwired to zero (write attempts do not stick), independent writes do not disturb other registers, dual read ports return correct values | Same log as above, 6 additional PASS lines (`x1 after reset`, `x31 after reset`, `x0 stays zero after write attempt`, `x5 write/read port1`, `x5 write/read port2`, `x5 unaffected by x17 write`, `x17 holds new value`) | Same as above |
| Total: 17/17 self-checking assertions passed, 0 simulator errors, 0 elaboration warnings | `get_sim_diagnostics` returned `{"error":0,"warning":0,"fatal":0}` after the second run (first run had 2 cosmetic warnings, fixed via `patch_source_file` and re-verified) | Same as above; ZWDB at `output/alu_regfile_tb.zwdb` |
| DE2-115 pin assignments cited in the mission brief (CLOCK_50, KEY[0:3], SW[0:7], VGA/ADV7123, SDRAM, SD Card socket) match the actual manual | Direct text extracted from `DE2_115_User_manual.pdf` via `pypdf`, PDF pages 36, 39, 54-55, 69-70, 71-72 — full extracted text quoted in the conversation transcript and summarized in `docs/board_resource_selection.md` | `python3 -c "from pypdf import PdfReader; r=PdfReader('DE2_115_User_manual.pdf'); print(r.pages[N-1].extract_text())"` for PDF page N |
| RV32IM/ILP32 bare-metal cross-compilation is available in this environment | `riscv64-unknown-elf-gcc --version` → 16.1.0; `-print-multi-lib` lists `rv32im/ilp32` | `module load riscv-gnu-toolchain/elf-multilib/2026.07.15-elf && riscv64-unknown-elf-gcc -print-multi-lib` |

## M1 — RV32IM multicycle CPU core

| Claim | Evidence | How to reproduce |
|---|---|---|
| RV32IM multicycle core (`rtl/cpu/cpu_core.sv` + `decoder.sv` + `mul_div.sv` + M0's `alu.sv`/`regfile.sv`) correctly executes a 66-instruction directed test covering every supported instruction class (ALU reg-reg/reg-imm, LUI, AUIPC, branches incl. signed/unsigned, JAL/JALR round trip, loads/stores incl. byte-lane and sign/zero extension, MUL/DIV/REM) | `research/results/m1_cpu_core_tb_final.log`: 32/32 self-checking assertions PASS, 0 errors, clean ECALL halt at pc=0x104, finish_time=4155 | Animas MCP: `set_sim_top(sim/tb/cpu_core_tb.sv)` → `run_simulation` → `get_last_sim_result` |
| Test program is real compiled RV32IM, not hand-encoded machine code | `sim/tb/asm/cpu_directed_test.S` assembled with `riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32`, confirmed via `riscv64-unknown-elf-objdump -d` disassembly matching source intent exactly (see `docs/verification_report.md`) | `source scripts/riscv_env.sh && riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -Wl,-Ttext=0x0 -o test.elf sim/tb/asm/cpu_directed_test.S && riscv64-unknown-elf-objdump -d test.elf` |
| Two real bugs (one RTL timing bug, one test-program bug) were found and fixed via the Animas run→diagnose→patch→rerun loop, not glossed over | `research/bugs.csv`, `docs/verification_report.md` "Bugs found and fixed" section | Diff `git log -p` on commits around this milestone |

## M2 — Bare-metal firmware boot (S0/S1 software gates)

| Claim | Evidence | How to reproduce |
|---|---|---|
| Real compiled C executes correctly on `cpu_core.sv`, with correct stack/`.data`/`.bss`/function-call handling | `research/results/m2_firmware_tb_final.log`: 6/6 checks PASS, 0 errors, clean ECALL halt | `bash scripts/build_firmware.sh m2_bringup firmware/linker/de2_115.ld firmware/startup/crt0.S firmware/tests/m2_bringup_main.c` then Animas MCP `set_sim_top(sim/tb/firmware_m2_tb.sv)` → `run_simulation` |
| ELF is genuinely RV32IM/ILP32 with no unsupported extensions | `firmware/build/m2_bringup.attrs.txt` (`Tag_RISCV_arch: "rv32i2p1_m2p0_zmmul1p0"`), `firmware/build/m2_bringup.disasm.txt` | `source scripts/riscv_env.sh && riscv64-unknown-elf-readelf -A firmware/build/m2_bringup.elf` |
| Two real bugs caught by static analysis before any simulation | `research/bugs.csv`, `docs/verification_report.md` M2 section | — |

## What is explicitly NOT claimed yet

- No peripheral RTL exists yet (SDRAM, SD/SPI, VGA, GPIO) — M3 not started.
- No SDRAM, SD/SPI, VGA, or GPIO peripheral RTL exists yet.
- No DoomGeneric source has been fetched or inspected yet.
- Nothing in this project has been synthesized, fit, timed, or programmed onto physical hardware — and nothing here claims otherwise.
