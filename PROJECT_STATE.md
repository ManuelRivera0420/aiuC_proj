# PROJECT_STATE.md — Autonomous RISC-V DOOM SoC on DE2-115

**Read this file first in any new session.** It is the single source of truth for what is actually done, what is in progress, and exactly how to resume.

Last updated: 2026-11-07T21:35Z, by this session, at start of M2.

## Current milestone: M2 (bare-metal firmware boot: S0-S1 software gates) — STARTING

## Completed (verified, committed)

- **M0** — capability probe, manual verification, Animas sanity check. Commit `a9a4f3b`.
- **M1** — RV32IM multicycle CPU, 32/32 directed-test checks PASS. Commit: see the one immediately following this file's previous version (check `git log --oneline`). Details: `docs/verification_report.md`, `research/evidence_index.md`, `research/results/m1_cpu_core_tb_final.log`.

## Environment facts needed to resume work (do not re-derive, just reuse)

```bash
# One-liner for a working RV32IM/ILP32 cross-compiler in the current shell:
source scripts/riscv_env.sh
# This loads the Lmod module AND points LD_LIBRARY_PATH at a user-space-built
# libmpfr.so.4 (the module's cc1 needs it; system only has .so.6; no root
# available to fix system-wide). If scripts/riscv_env.sh warns the compat lib
# is missing (e.g. a fresh /tmp scratchpad in a new session), rebuild it:
#   bash scripts/build_mpfr_compat.sh
# then source scripts/riscv_env.sh again.

# Compile+disassemble pattern used throughout M1 (adapt paths as needed):
#   riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#     -Wl,-Ttext=0x0 -o out.elf some.S
#   riscv64-unknown-elf-objdump -d out.elf
#   riscv64-unknown-elf-objcopy -O binary out.elf out.bin
#   python3 scripts/bin_to_readmemh.py out.bin sim/models/program.hex

# Python with working pip (system python3.9 has NO pip):
module load python3/3.11.16
```

Animas project: id `bff69947-9fc3-408f-bc64-4efffd9b8fe1`, name `aiuC_proj`. Its root path as seen by Animas and the local filesystem path (`/home/marivera/Documents/aiuC_proj`) are the SAME FILES through a flatpak portal. New RTL/sim files: author with local Write/Edit or `add_source_file`/`register_existing_file`; same bytes either way. Current `sim_top` is `sim/tb/cpu_core_tb.sv`, `rtl_top`/`top_module` is whatever `set_rtl_top` was last called with (check `get_project_info` — M1 never explicitly called `set_rtl_top` since the testbench instantiates `cpu_core` directly and `sim_top` alone drove elaboration).

## M1 summary (for context, not to redo)

`rtl/cpu/{alu,regfile,decoder,mul_div,cpu_core}.sv` form a working multicycle RV32IM core with a picorv32-style memory port (`mem_valid/mem_ready/mem_addr/mem_wdata/mem_wstrb/mem_rdata`, synchronous, FSM already tolerates wait states). `sim/models/sync_mem.sv` is a flat 64KB word-addressable behavioral memory for standalone-core testing ONLY — not the final SoC memory map. Verified via `sim/tb/cpu_core_tb.sv` + `sim/tb/asm/cpu_directed_test.S`. Two bugs found/fixed (see `docs/verification_report.md`): (1) `rf_we` had to be combinational, not registered, because `pc` advances on the same edge that would otherwise lag the write by a cycle; (2) a test-program jump-offset bug, unrelated to the CPU. Known test-coverage gaps are listed in `docs/verification_report.md` "Known gaps" — not blockers, just honest disclosure.

## M2 plan (bare-metal firmware boot — mission's S0/S1 software gates)

Goal: a tiny freestanding C program, compiled with the confirmed toolchain, executing correctly on `cpu_core` in Animas, with correct `.data` init, `.bss` clear, and a working stack — i.e. prove the CPU can run *compiled C*, not just hand-written assembly, before building any peripheral or SoC-level RTL.

- [ ] `firmware/linker/de2_115.ld` — minimal version for M2: a single flat RAM region (reusing `sync_mem`-style address space for now; the real ROM/SDRAM split comes in M3/M4), `.text/.rodata/.data/.bss`, stack pointer at top of RAM.
- [ ] `firmware/startup/crt0.S` — set `sp`, clear `.bss`, copy `.data` init image, call `main`, loop/ecall on return.
- [ ] A tiny `main.c` (e.g. write a few known values to memory-mapped-like addresses, or just do arithmetic and write results to fixed RAM addresses the testbench checks) — S0/S1 gate per the mission: "tiny C firmware execute on the Animas RTL processor with correct stack, .data, .bss".
- [ ] `scripts/build_firmware.sh` — reproducible compile/link/objcopy/objdump/readelf pipeline, `-march=rv32im -mabi=ilp32 -ffreestanding -fno-pic -fno-pie`.
- [ ] Static ISA/ABI gate: `readelf -A`/`objdump -d` check for stray C/F/D/A/V instructions or CSR ops the CPU doesn't support (decoder currently flags non-zero-funct3 SYSTEM opcodes as illegal — i.e. CSR use will HALT with illegal_instr, not silently misbehave, which is a safe failure mode but worth checking for before spending simulation cycles on it).
- [ ] New testbench (or extend `cpu_core_tb.sv` pattern) loading the compiled image, running to halt/ecall, checking memory contents against independently-known expected values.
- [ ] Commit M2, then proceed to M3 (peripheral behavioral models: SDRAM, SD/SPI + `prepare_sd_image.py`/`verify_sd_image.py`, VGA timing, KEY/SW GPIO) per the original mission's repo structure.

## Outstanding failures / open bugs

None blocking at this checkpoint. Documented non-blocking gaps are in `docs/verification_report.md`.

## Scope decisions recorded so far (so they aren't re-litigated or silently reversed later)

1. M1 verification uses a curated directed-test suite, not the full upstream `riscv-tests` regression (documented in `docs/verification_report.md`).
2. CSR instructions (any SYSTEM-opcode instruction with funct3!= 0) are decoded as illegal, not implemented — matches mission's "RV32IM baseline, no CSR" framing. Firmware/libc choices in M2+ must avoid relying on CSR access (e.g. no `rdcycle`/`rdinstret` via CSR; use a memory-mapped timer peripheral instead, to be designed in M3).
3. Misaligned load/store behavior is currently silently wrong (wrong byte lanes) rather than trapped — acceptable for now per mission's "document the simplification" allowance; firmware should avoid misaligned accesses by construction (natural alignment from the C compiler already guarantees this for ordinary code).
