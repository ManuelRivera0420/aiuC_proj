# PROJECT_STATE.md — Autonomous RISC-V DOOM SoC on DE2-115

**Read this file first in any new session.** It is the single source of truth for what is actually done, what is in progress, and exactly how to resume.

Last updated: 2026-11-07T22:00Z, by this session, at start of M3.

## Current milestone: M3 (board peripheral behavioral models) — STARTING

## Completed (verified, committed)

- **M0** — capability probe, manual verification, Animas sanity check. Commit `a9a4f3b`.
- **M1** — RV32IM multicycle CPU, 32/32 directed-test checks PASS. Commit `ef09933`.
- **M2** — bare-metal firmware boot (S0/S1 gates), 6/6 checks PASS. Commit: the one immediately following this file's previous version — check `git log --oneline`.

## Environment facts needed to resume work (do not re-derive, just reuse)

```bash
# Working RV32IM/ILP32 cross-compiler in the current shell:
source scripts/riscv_env.sh
# If it warns the MPFR compat lib is missing (fresh /tmp scratchpad in a new
# session): bash scripts/build_mpfr_compat.sh, then source riscv_env.sh again.

# Reproducible firmware build:
#   bash scripts/build_firmware.sh <name> <linker.ld> <sources...>
# writes firmware/build/<name>.{elf,hex,disasm.txt,symbols.txt,attrs.txt,map}
# .hex/.disasm.txt/.symbols.txt/.attrs.txt/.map are committed (small, text,
# evidence); .elf/.o/.bin are gitignored (binary, regeneratable).

# Python with working pip (system python3.9 has NO pip):
module load python3/3.11.16
```

Animas project id `bff69947-9fc3-408f-bc64-4efffd9b8fe1`. Current `sim_top` is `sim/tb/firmware_m2_tb.sv`. Project root as seen by Animas and the local filesystem path are the SAME FILES (flatpak portal) — author files locally or via `add_source_file`/`register_existing_file`, either way.

## M1+M2 summary (for context, not to redo)

`rtl/cpu/{alu,regfile,decoder,mul_div,cpu_core}.sv`: working multicycle RV32IM core, picorv32-style mem port (`mem_valid/ready/addr/wdata/wstrb/rdata`, tolerates wait states). `sim/models/sync_mem.sv`: flat behavioral memory for standalone-core testing ONLY (not the final SoC memory map). `firmware/{linker/de2_115.ld, startup/crt0.S}`: minimal boot code — single flat 64KiB RAM, explicit `.bss` clear, NO `.data` load-copy yet (everything lives at one address, no ROM/RAM split yet — see below). Both milestones' bugs and fixes are fully written up in `docs/verification_report.md`; don't re-derive, read that file.

**Important for M3/M4**: the current linker script places `.text/.rodata/.data/.bss` all in one region. Once a real ROM (or SD-loaded boot image) vs. SDRAM-backed RAM split exists, `crt0.S` will need an explicit `.data` copy loop (load-address → virtual-address), not just the `.bss` clear it has now. Don't forget this when building the M4 bootloader.

## M3 plan (board peripheral behavioral models)

Per the mission's repo structure and milestone gate M3 ("modeled SDRAM/32GB-SDHC-SPI/VGA/KEY-SW-GPIO controller tests, raw-image loader tests and pin audit"). This is a big milestone; breaking it into independently-committable chunks rather than one giant commit:

- [ ] `rtl/peripherals/key_sw_gpio.sv` — memory-mapped KEY[3:0]/SW[17:0] input controller per the mission's locked mapping (Section 2A of the original prompt): synchronizers for metastability, rising-edge detection for SW[4:7] (use/weapon/menu/select), level-sensitive passthrough for SW[0:3] (movement/strafe) and KEY[1:3] (turn/fire). KEY[0] is reset, not a memory-mapped input.
- [ ] `rtl/peripherals/timer.sv` — free-running cycle counter MMIO register (needed for `DG_GetTicksMs`/`DG_SleepMs` later; also usable now as a watchdog-free "how long did boot take" metric).
- [ ] `rtl/bus/soc_bus.sv` — simple address-decoded bus: routes `cpu_core`'s single memory port to {boot ROM, RAM, GPIO, timer, (later) SDRAM, SD/SPI, VGA framebuffer} based on address ranges. Document the memory map in `docs/memory_map.md` before writing the RTL, not after.
- [ ] `rtl/memory/sdram_ctrl.sv` — behavioral-first: a correct init/refresh/read/write FSM modeled against Table 4-28 pins and generic SDR SDRAM timing (the manual doesn't give exact chip timing — flag as `docs/known_limitations.md` item, use conservative JEDEC-typical numbers and mark them as such, not invented specifics).
- [ ] `rtl/peripherals/sd_spi.sv` + `sim/models/sdhc_spi_model.sv` + `scripts/prepare_sd_image.py` + `scripts/verify_sd_image.py` — the SDHC SPI boot contract from the mission's Section 3A: CMD0/CMD8/ACMD41(HCS)/CMD58(CCS)/CMD17, LBA addressing, raw versioned image format, error states.
- [ ] `rtl/peripherals/vga.sv` — 640x480@60Hz timing generator (Table 4-14/4-15 confirmed numbers already in `docs/board_resource_selection.md`), framebuffer read port, palette/RGB565 path TBD pending M5's actual DoomGeneric pixel-format inspection (don't lock this in prematurely — the mission explicitly warns against assuming 8-bit paletted output before checking).
- [ ] `docs/pin_assignments.csv` + `scripts/pin_audit.py` + `docs/pin_audit_report.md`.
- [ ] Commit M3 (likely as several sub-commits per peripheral, each with its own Animas-verified testbench), then M4 (SoC integration: real SD→SDRAM→firmware boot path, basic RTL-driven framebuffer animation).

## Outstanding failures / open bugs

None blocking. Non-blocking M1 gaps are in `docs/verification_report.md`. M2's single-memory-region simplification (no `.data` load-copy) is tracked above, to be addressed when M4's real memory map lands.

## Scope decisions recorded so far (so they aren't re-litigated or silently reversed later)

1. M1 verification uses a curated directed-test suite, not full upstream `riscv-tests`.
2. CSR instructions are decoded as illegal (SYSTEM opcode, funct3!=0) — no Zicsr in this design.
3. Misaligned load/store gives silently-wrong byte lanes rather than trapping — documented simplification, not yet revisited.
4. M2's memory map is a single flat region; M3/M4 need a real split and a `.data` load-copy in `crt0.S` once it exists.
5. SDRAM controller timing will use conservative JEDEC-typical SDR SDRAM numbers where the DE2-115 manual doesn't specify exact chip timing, explicitly flagged as such rather than invented as if sourced from the manual.
