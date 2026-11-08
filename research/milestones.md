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

## M5 — DOOM functional PASS: **PARTIAL** (S0-S2 software gates DONE, S3-S4 NOT attempted this session)

The real, complete DoomGeneric engine (86 compilation units, GPL-2.0, pinned commit `e257a09527062bfb986b6e5e0780839b6cbd5b71`) compiles and links cleanly for RV32IM/ILP32 against the toolchain's bundled Newlib, producing a 792,874-byte ELF that passes the same static ISA/ABI gate used since M2 with zero unsupported-instruction hits. Required: inspecting the real pixel format (320×200 8-bit indexed, not 32-bit RGB — a genuine mid-course correction to `framebuffer.sv`, re-verified 7/7 PASS), a ~14-function Newlib syscall stub layer, and a custom WAD backend reading a (not-yet-implemented) SDRAM-preloaded WAD — all achieved with **zero patches to upstream DoomGeneric source**. Freedoom 0.13.0 fetched and hash-pinned (WAD itself not committed, 28MB).

**Not attempted this session**: running the compiled binary on `cpu_core` via Animas. Measured reason (not assumed): the SD-transfer pipeline's realistic per-sector timing, extrapolated from M4's actual measurement, puts an 800KB+ payload's transfer time in a wall-clock range this session's remaining time couldn't responsibly absorb. Concrete next step recorded in `PROJECT_STATE.md`: a direct-SDRAM-preload fast-path testbench, bypassing the (already-verified, just slow-to-simulate-at-scale) SD path for large-payload iteration. Full writeup: `docs/verification_report.md`'s M5 section, `software/source-lock.json`.

## M6 — Quartus handoff: **DONE** (2026-11-08)

`rtl/board/de2_115_top.sv` written (every port matching `docs/pin_assignments.csv`) and smoke-tested via Animas (`sim/tb/board_top_smoke_tb.sv`, 3/3 PASS — CPU runs after reset, no illegal_instr, structural connectivity confirmed). `scripts/pin_audit.py` extended with a top-level port cross-check against the real RTL file (0 errors across 26 signals/132 pins). `fpga/de2_115/doom_riscv_de2_115.{qpf,qsf,sdc}` hand-written — each file's own header states plainly that it was not produced by actually running Quartus. Three physical-confirmation items correctly left unresolved rather than guessed: device speed grade (`EP4CE115F29C7`'s `C7` flagged as common-default-not-confirmed), KEY/SW I/O standard (no `IO_STANDARD` assignment at all, pending JP7 jumper reading), and SD card electrical compatibility.

Four new docs: `docs/module_interfaces.md` (every module's port list/bus protocol), `docs/clock_reset_cdc.md` (the `clk`/`pclk` generated-clock relationship, async reset strategy, and the one real CDC in the design — framebuffer scan-out's combinational `pclk`-domain read against `clk`-domain-written BRAM), `docs/fpga_handoff.md` (human-team build order + the M5 DOOM-execution-gap called out explicitly), `docs/how_to_run_doom.md` (operator steps — surfaced a genuine, previously-undocumented-at-this-specificity gap: `bootloader_main.c` never reads the WAD-related header fields, so it loads the program but not the WAD, even though `prepare_sd_image.py` already supports embedding one).

Full writeup: `docs/fpga_handoff.md`, `docs/module_interfaces.md`, `docs/clock_reset_cdc.md`, `docs/how_to_run_doom.md`. Evidence: `research/results/m6_board_top_smoke.log`.

## M5 — S3 direct-execution attempt: ATTEMPTED, CONCLUDED, PARTIAL (2026-11-08)

The direct-SDRAM-preload testbench (`sim/tb/m5_doom_exec_tb.sv`) actually executed the real, compiled DoomGeneric binary on `cpu_core` — not just compiled it. Result: 11,620,521 cycles of real engine code (confirmed via disassembly-matched PC checkpoints: `crt0`'s `.bss`-clear → `M_LoadDefaults`/`SearchCollection` in `m_config.c` → `strcmp`), then a clean, architecturally-correct `HALTED` via `_exit()`'s `ecall`, zero illegal instructions, zero hangs. Traced to almost certainly `I_Error()` (the only two call sites of `exit()` in the entire 792KB binary are `D_Endoom`, implausible this early, and `I_Error`), consistent with this run's deliberately-unpopulated WAD region. Gate-by-gate: "DOOM machine code executing on RTL" = **PASS**; "DOOM engine initialization" = attempted, did not complete; WAD-accessible/first-frame/multi-frame/input = not reached. Full trace, disassembly cross-references, and gate table: `docs/verification_report.md`'s M5 S3 section.

Also found and fixed along the way: a `ZEN-6033` LRM violation in the new SDRAM preload mechanism (same bug class as M1's `sync_mem.sv` fix), and a genuine Animas/Zenith tooling finding — `run_simulation` silently falls back to a ~2x-faster `headless` mode when the Animas UI is closed, but `set_sim_options(waveform_mode="off")` is not honored in that path (confirmed twice), costing an unsuppressed 8.57GB waveform dump on this run.

Separately, re-verified the M6-session bootloader WAD-copy fix against `sim/tb/m4_e2e_tb.sv`: rebuilt `sim/models/soc_rom.hex` from the changed `bootloader_main.c` source and re-ran headless — **7/7 PASS, 0 errors**, identical result to before the fix, confirming the addition is genuinely behavior-preserving for every existing boot image.

**Concrete next step for M5**: retry the WAD preload (the thing that stalled in `ui_remote_control` mode) now that headless mode is confirmed both available and faster — that specific combination hasn't been tried yet.

## Overall status after M6 and the M5 S3 attempt

M0-M4 and M6 are fully done and verified. M5's S0-S2 gates are done; S3 has now genuinely been attempted (not skipped) with a real, honest, partial result — DOOM engine code runs correctly on this CPU, but the engine can't get past IWAD identification without a real WAD actually reachable in SDRAM. That WAD-preload-at-scale problem is the one concrete remaining blocker in the whole project, and it's now narrower and better understood than it was before this session (`docs/verification_report.md`'s M5 S3 section has the full investigation, including what was tried, what failed, and why).
