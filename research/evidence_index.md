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

## M3 (in progress) — GPIO, timer, bus, ROM/RAM split

| Claim | Evidence | How to reproduce |
|---|---|---|
| KEY/SW/LED MMIO controller correct: level reads, sticky rising-edge detect with correct clear-on-read semantics, LED write/read-back, unmapped-offset behavior | `research/results/m3_gpio_timer_bus_final.log` (`key_sw_gpio_tb.sv` section): 10/10 PASS | Animas MCP: `set_sim_top(sim/tb/key_sw_gpio_tb.sv)` → `run_simulation` |
| cpu_core + soc_bus + GPIO + timer + real ROM/RAM split with explicit `.data` load-copy, all exercised by real compiled C | `research/results/m3_gpio_timer_bus_final.log` (`soc_bus_tb.sv` section): 6/6 PASS on the first simulation attempt | `bash scripts/build_firmware.sh m3_bus_gpio firmware/linker/de2_115_bus.ld firmware/startup/crt0_bus.S firmware/tests/m3_bus_gpio_main.c` then Animas `set_sim_top(sim/tb/soc_bus_tb.sv)` → `run_simulation` |

## M3 — SDRAM controller

| Claim | Evidence | How to reproduce |
|---|---|---|
| Close-page SDR SDRAM controller: correct init sequence, word read/write, byte-masked writes, address non-aliasing, periodic refresh during operation | `research/results/m3_sdram_ctrl_tb_final.log`: 14/14 PASS | Animas MCP: `set_sim_top(sim/tb/sdram_ctrl_tb.sv)` → `run_simulation` |

## M3 — SD/SPI controller (mandatory, Section 3A)

| Claim | Evidence | How to reproduce |
|---|---|---|
| Full SDHC SPI init handshake (CMD0/CMD8/CMD55+ACMD41 retried exactly twice/CMD58 CCS check) and a CMD17 single-block read verified byte-for-byte against a real prepared boot image | `research/results/m3_sd_spi_tb_final.log`: 9/9 PASS | `python3 scripts/prepare_sd_image.py ...` then Animas `set_sim_top(sim/tb/sd_spi_tb.sv)` → `run_simulation` |
| Raw boot image format is independently verifiable, not just self-consistent | `python3 scripts/verify_sd_image.py sim/models/sd_fixture.img --manifest sim/models/sd_fixture.manifest.json` → `PASS: image structurally consistent and all hashes verified independently` | same command |
| Four real RTL bugs (command encoding, SPI mode-0 timing violation, a same-edge race, a read-after-write hazard) found and fixed via Animas waveform inspection, not guesswork | `research/bugs.csv`, `docs/verification_report.md` SD/SPI section | `git log -p` around this milestone's commit |

## M4 — SoC integration

| Claim | Evidence | How to reproduce |
|---|---|---|
| Real SD boot image → bootloader (real compiled C) → cpu_core → SDRAM → jump to loaded program → framebuffer writes → VGA scan-out, end to end | `research/results/m4_e2e_tb_final.log`: 7/7 PASS, `pc=0x10000030` at halt (confirms the jump into SDRAM-loaded code) | Animas MCP: `set_sim_top(sim/tb/m4_e2e_tb.sv)` → `run_simulation` (note: this test runs at realistic SD/SPI clock dividers and takes longer than earlier tests — check `get_last_sim_result`'s `finished` field rather than assuming an early tool-call return means it's done) |
| The SD/SPI byte-order fix (M3→M4) is correct, not just reasoned through | `research/results/m4_sd_spi_tb_recheck.log`: 9/9 PASS with corrected values `0x18110a03`/`0x342d261f` | Animas MCP: `set_sim_top(sim/tb/sd_spi_tb.sv)` → `run_simulation` |
| Animas/Zenith does not write simulation artifacts to `/tmp` for this project | Before/after snapshot of `/tmp`'s top-level contents+mtimes across a full simulation run showed zero diff; `lsof` on the running daemon/backend processes showed no open `/tmp` files | `find /tmp -maxdepth 1 -printf '%T@ %p\n' \| sort -n` before and after a `run_simulation` call, diff the two |

## M5 — DoomGeneric real compile (S0-S2 software gates)

| Claim | Evidence | How to reproduce |
|---|---|---|
| The real, complete DoomGeneric engine (86 compilation units) compiles and links cleanly for RV32IM/ILP32, using only instructions `cpu_core.sv` implements | `research/results/m5_doom_compile_link_isa_gate.log`: 86/86 compiled, link OK, `readelf -A` shows `rv32i2p1_m2p0_zmmul1p0` only, 0 hits for any F/D/A/V/CSR/AMO/compressed mnemonic across the full 792,874-byte binary | `bash scripts/build_doom.sh` |
| The pixel-format and palette-update design decisions required zero patches to upstream DoomGeneric | `software/doom_port/doomgeneric_de2115.c` and `w_file_de2115.c` only add new files; `git diff` against `software/upstream/doomgeneric/` is empty | `diff -r software/upstream/doomgeneric/ <(git show HEAD:software/upstream/doomgeneric/)` (or just inspect: no files under `software/upstream/` were modified after the initial vendoring commit) |

## M6 — Quartus handoff

| Claim | Evidence | How to reproduce |
|---|---|---|
| `rtl/board/de2_115_top.sv` elaborates and runs after reset, with every port matching `docs/pin_assignments.csv` | `research/results/m6_board_top_smoke.log`: `sim/tb/board_top_smoke_tb.sv`, 3/3 PASS (CPU runs after reset, no illegal_instr, structural connectivity) | Load `rtl/board/de2_115_top.sv` + `sim/tb/board_top_smoke_tb.sv` into Animas, `run_simulation` |
| `docs/pin_assignments.csv` and `rtl/board/de2_115_top.sv` agree on every signal and width, bidirectionally | `python3 scripts/pin_audit.py docs/pin_assignments.csv rtl/board/de2_115_top.sv` → `Errors: 0` across 26 signals/132 pins | Same command, any time either file changes |
| The Quartus `.qsf`/`.sdc` files were hand-written, not produced by running Quartus | Stated explicitly in each file's own header comment; `docs/known_limitations.md`/`docs/fpga_handoff.md` repeat it — this project never invoked Quartus at any point, consistent with the mission's scope boundary | `grep -l "not generated by Quartus" fpga/de2_115/*` |

## What is explicitly NOT claimed, as of the end of M6

- The compiled DOOM binary has NOT been executed on `cpu_core` via Animas — compiling and linking cleanly is S0-S2, not S3/S4. The measured reason (SD-transfer time for an 800KB+ payload) and the concrete next step (a direct-SDRAM-preload fast-path testbench) are in `docs/verification_report.md`'s M5 section and `PROJECT_STATE.md`. **This is the one open gap in the whole project.**
- The bootloader does not yet copy the WAD into SDRAM (only the program) — found and documented while writing `docs/how_to_run_doom.md`; a small, scoped, not-yet-done fix.
- No physical SD card write has been performed by this project — `docs/sd_card_preparation.md` is instructions for the human team, not a completed action.
- Nothing in this project has been synthesized, fit, timed, or programmed onto physical hardware, and `fpga/de2_115/doom_riscv_de2_115.{qpf,qsf,sdc}` were never opened in real Quartus — nothing here claims otherwise.
- Three physical facts remain unconfirmed and are needed before a human team can safely compile in Quartus: the device's exact speed grade, the JP6/JP7 jumper position (needed for KEY/SW's `IO_STANDARD`), and the specific ADATA SD card's real SPI electrical compatibility — all three listed with the same honesty in `docs/known_limitations.md` and `docs/fpga_handoff.md` §2.
