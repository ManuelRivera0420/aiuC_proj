# Milestone Status

## M0 — Feasibility and evidence plan: **DONE** (2026-11-07)

- Capability probe complete: shell, internet, git, RISC-V toolchain (needs `module load riscv-gnu-toolchain/elf-multilib/2026.07.15-elf`), Python/pip (needs `module load python3/3.11.16`), Animas MCP, Zenith simulator feature set. See `docs/known_limitations.md`.
- Initial prompt frozen (harness-truncated, provenance documented) at `research/prompts/initial_prompt.md`.
- Repository skeleton scaffolded per the mission's required structure.
- DE2-115 manual pin/resource claims in the mission brief **independently verified by direct PDF text extraction** against the actual manual (not assumed): clocks, KEY/SW, LEDs, VGA/ADV7123, SDRAM, SD Card socket, FPGA device resource counts. All matched exactly. See `docs/board_resource_selection.md`.
- Mandated Animas sanity check executed and passed on real (non-counter) RTL: a 32-bit RV32I ALU + 32×32 register file with a self-checking testbench, run through the actual Animas MCP `run_simulation` tool (UI remote-control mode) against the real Zenith v1.0.2 simulator. 17/17 directed checks passed, 0 errors, 0 warnings after two trivial RTL cleanups. See `research/evidence_index.md`.
- Correction recorded: the prior "counter pass" referenced in the initial prompt could not be verified in this project's starting state (0 registered sources, no ZWDB). Treated as unverified rather than fact.
- Correction recorded: manual page count is 122 (pypdf-confirmed), matching the prompt, not the 141 claimed by harness file metadata.

## M1 — CPU PASS: **DONE** (2026-11-07)

Multicycle RV32IM core (`rtl/cpu/{decoder,mul_div,cpu_core}.sv` + M0's `alu.sv`/`regfile.sv`), picorv32-style memory interface. Verified with a 66-instruction directed test (real `riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32` compiled, not hand-encoded), 32/32 self-checking assertions PASS, 0 errors. Two real bugs found and fixed via Animas (one RTL timing bug in the register-file write-enable path, one off-by-one in the test program itself). Full writeup: `docs/verification_report.md`. Evidence: `research/evidence_index.md`, `research/results/m1_cpu_core_tb_final.log`.

Known, documented gaps (not blockers for M2): MULH family/DIVU/REMU implemented but only lightly spot-tested by reasoning rather than a directed test each; no LH/LHU directed test; no illegal-instruction/CSR-rejection directed test; misaligned access behavior undefined. Candidates for a later hardening pass.

## M2 — Bare-metal PASS: **DONE** (2026-11-07)

Real compiled C (`firmware/tests/m2_bringup_main.c`), not hand-written assembly, executes correctly on `cpu_core.sv` via Animas: 6/6 checks PASS (stack, `.data`, `.bss`, function call/return via stack). S0/S1 software gates both satisfied. Two bugs found via static `readelf`/`objdump` analysis *before* any simulation (linker script missing `.sdata`/`.sbss`, a constant-folded test). Full writeup: `docs/verification_report.md`. Scope note: M2's linker script uses one flat memory region with no ROM/RAM split — M3/M4 will need a real `.data` load-copy once that split exists.

## M3 — Board peripheral PASS: **DONE** (2026-11-07)

All peripherals verified standalone against Animas (not yet wired together into one SoC — that's M4):
- GPIO (KEY/SW/LED): 10/10 PASS, direct unit test.
- Address-decoded bus + real ROM/RAM split + .data load-copy: 6/6 PASS, running real compiled C through cpu_core+soc_bus.
- VGA 640x480@60Hz timing + DOOM scan-out addressing: 29/29 PASS.
- SDRAM controller (close-page, init+refresh+read/write): 14/14 PASS.
- SD/SPI SDHC controller (full init handshake + CMD17 block read): 9/9 PASS — the hardest debugging session so far, 4 real RTL bugs + 1 model bug found via Animas waveform inspection.
- Pin audit: 132 pins, 0 errors, 1 expected warning; 22 pins flagged as needing human-confirmed JP7 reading before `.qsf` generation.

Full writeups: `docs/verification_report.md`, `docs/sdhc_32gb_boot_protocol.md`, `docs/sd_card_preparation.md`, `docs/pin_audit_report.md`, `docs/memory_map.md`. Evidence: `research/evidence_index.md`, `research/results/m3_*.log`.

## M4 — SoC integration PASS: **DONE** (2026-11-08)

Full real SD boot image → bootloader → cpu_core → SDRAM → jump → framebuffer writes → VGA scan-out, 7/7 checks PASS (`sim/tb/m4_e2e_tb.sv`). Hit and recovered from a genuine Animas daemon lock between sessions (documented, not glossed over — see `PROJECT_STATE.md`'s prior checkpoint and `docs/verification_report.md`'s M4 section); after the user restarted Animas, re-verified `sd_spi_tb.sv` (9/9, confirming a byte-order fix made while blocked) before running the new end-to-end test. Also addressed a host disk-space concern: moved build scratch off the shared `/tmp` volume to a project-local `.build_tmp/` directory and confirmed (by direct before/after inspection, not assumption) that Zenith/Animas itself doesn't write simulation artifacts to `/tmp` for this project. Full writeup: `docs/verification_report.md`, `docs/known_limitations.md`, `docs/boot_process.md`.

## M5-M6: not started
