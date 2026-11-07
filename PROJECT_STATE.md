# PROJECT_STATE.md — Autonomous RISC-V DOOM SoC on DE2-115

**Read this file first in any new session.** It is the single source of truth for what is actually done, what is in progress, and exactly how to resume.

Last updated: 2026-11-08T01:10Z, by this session.

## Current milestone: M4 (SoC integration) — CODE WRITTEN, VERIFICATION BLOCKED

**BLOCKER (read this first)**: the Animas simulation daemon got into a stuck state (`ERROR: ZenithDaemonClient: job already in progress`) partway through M4 and did not recover across 8+ retries spread over real elapsed time (with other, non-Animas work done in between each retry to rule out a transient lock). No MCP tool available in this session can cancel or restart the daemon. **The Animas application likely needs a human to close and reopen it.** Once it's responsive again (test with a trivial `run_simulation` call first), resume with the exact steps in "What to do when resuming" in `docs/verification_report.md`'s M4 section — don't skip re-running `sd_spi_tb.sv` first, since its expected values changed (see below) and it hasn't been reconfirmed.

## Completed and VERIFIED (committed, Animas-confirmed)

- **M0** — capability probe, manual verification, Animas sanity check. Commit `a9a4f3b`.
- **M1** — RV32IM multicycle CPU, 32/32 directed-test checks PASS. Commit `ef09933`.
- **M2** — bare-metal firmware boot (S0/S1 gates), 6/6 checks PASS. Commit `1f0fdfb`.
- **M3** — all board peripherals verified standalone. Commits `0de834d`, `9e34864`, `2c0db5c`, `a0860c5`, `cd53bd0`.
  - **IMPORTANT CAVEAT**: `sd_spi.sv` was modified AFTER M3's commit (the byte-order fix below) and `sd_spi_tb.sv`'s expected values were updated to match, but neither has been re-run since — M3's SD/SPI result is "last known PASS, code since changed, not reconfirmed," not a currently-valid PASS. Re-run it first when Animas recovers.

## Code written but NOT YET VERIFIED (M4, blocked on the daemon)

- `rtl/peripherals/framebuffer.sv` — new, dual-port CPU-write/VGA-read framebuffer. Never simulated.
- `rtl/bus/soc_bus.sv` — modified: now wires SDRAM/SD-SPI/VGA-framebuffer (previously reserved-but-unwired placeholders). Never simulated in this new form.
- `rtl/peripherals/sd_spi.sv` — modified: fixed a byte-order bug in `ST_READ_DATA`'s `block_buf` packing (was MSB-first, now correctly little-endian to match RV32 memory semantics — see `docs/boot_process.md`'s "byte-order note"). **Caught by design review, not simulation** — the old (wrong) packing had already passed its own unit test because that test's expectations matched the bug. Never re-simulated since the fix.
- `sim/tb/sd_spi_tb.sv` — modified: expected values updated for the byte-order fix (`0x18110A03`/`0x342D261F` replacing `0x030A1118`/`0x1F262D34`). Never re-run.
- `firmware/bootloader/bootloader_main.c` + `firmware/linker/de2_115_bus.ld` (reused from M3) + `firmware/startup/crt0_bus.S` (reused from M3) — compiles cleanly (`firmware/build/bootloader.*`), ISA/ABI-clean (`rv32i2p1_m2p0_zmmul1p0`, no stray instructions), but never executed on `cpu_core`.
- `firmware/tests/m4_framebuffer_main.c` + `firmware/linker/de2_115_soc.ld` (new) — compiles cleanly (`firmware/build/m4_framebuffer.*`), `_start` confirmed at `0x10000000` matching the intended load/entry address. Never executed.
- `sim/models/m4_boot.img` + `.manifest.json` + `.hex` — built via `scripts/prepare_sd_image.py` from the compiled framebuffer test program; **independently verified structurally correct** by `scripts/verify_sd_image.py` (PASS) — that part IS confirmed, it's a host-side Python check, not Animas-dependent.
- `sim/tb/m4_e2e_tb.sv` — full end-to-end testbench (SD model → bootloader on real cpu_core → SDRAM → jump → framebuffer writes → vga.sv scan-out). **Never elaborated even once** — there could be a compile error or further RTL bug in here that neither code review nor the toolchain would catch; do not assume it's close to passing just because the individual pieces were each reasoned through carefully.
- `docs/boot_process.md` — written, describes the intended design; explicitly flagged internally as design documentation, not a verified-behavior claim.

## Environment facts needed to resume work (do not re-derive, just reuse)

```bash
source scripts/riscv_env.sh   # RV32IM/ILP32 cross-compiler; rebuild MPFR compat lib
                                # first if scratchpad is gone: bash scripts/build_mpfr_compat.sh
bash scripts/build_firmware.sh <name> <linker.ld> <sources...>   # reproducible firmware build
module load python3/3.11.16   # for pip-installed tools (pypdf, etc) -- system python3.9 has no pip
```

**Animas performance note (from M3, still true)**: headless subprocess mode (triggered automatically when Animas's UI backend isn't reachable) runs ~1000x faster than `ui_remote_control` mode for fine-grained-toggle-heavy testbenches. The M4 daemon lock happened while in `ui_remote_control` mode; it's possible (not confirmed) that closing the Animas UI entirely and letting calls fall back to headless would both avoid this lock AND run faster — worth trying first on resume, before assuming a full daemon restart is needed.

Animas project id `bff69947-9fc3-408f-bc64-4efffd9b8fe1`. `sim_top` was last set to `sim/tb/m4_e2e_tb.sv` — but per the resume plan, set it back to `sd_spi_tb.sv` FIRST and confirm that passes before moving on.

## Lessons learned this session (carried forward from the previous checkpoint, still true)

1. **Same-cycle read-after-write** is the most common bug class in this project (hit 3 times: `cpu_core.sv` M1, `sd_spi.sv` M3 twice).
2. **SPI mode 0**: data changes on the falling edge, sampled on the rising edge — got this backwards once.
3. **Don't clear a "busy" flag on the exact edge a peer samples your combinationally-muxed output** — defer by one more edge.
4. **Model a clock-domain peer by clocking directly off the actual derived clock**, not by polling it from a faster domain.
5. **`objcopy -O binary` uses each section's LMA**, confirmed empirically — this is why `AT>ROM` linker-script sections work for ROM images.
6. **Headless Animas runs are dramatically faster** than UI-remote-control runs for bit-toggle-heavy testbenches.
7. **Always add a bounding watchdog** to any testbench `wait(...)` — a real deadlock without one costs real wall-clock time to notice.
8. **NEW this session**: a byte-order/endianness bug can be "internally consistent" and pass its own unit test while still being wrong relative to the actual downstream consumer's assumptions (RV32's little-endian memory model, in this case). When a module's output will be consumed by code that has its own strong format assumptions (here: `sw` instructions storing to SDRAM), check against THAT consumer's assumptions explicitly, not just self-consistency.
9. **NEW this session**: when a required external tool (here, the Animas daemon) gets stuck, retry with real elapsed time and unrelated work in between (to rule out transient state) a reasonable number of times, then STOP and document the blocker precisely rather than continuing to fabricate progress or hammer the same failing call indefinitely. Preserve all completed work via commit, clearly labeled as unverified where it genuinely hasn't been verified.

## M4 remaining plan (once daemon recovers)

1. Re-run `sd_spi_tb.sv`, confirm 9/9 PASS with updated expected values.
2. Run `m4_e2e_tb.sv`, debug via the normal Animas run→diagnose→patch→rerun loop (same as every prior milestone).
3. Commit M4 once genuinely passing, with real evidence (log + research/results/ entry), not before.
4. Proceed to M5 (fetch real DoomGeneric + Freedoom, port platform hooks, attempt the real game loop on the RTL CPU) and M6 (Quartus handoff: `.qpf`/`.qsf`/`.sdc`, `rtl/board/de2_115_top.sv`, extend `pin_audit.py`).

## Scope decisions recorded so far (so they aren't re-litigated or silently reversed later)

1. M1 verification uses a curated directed-test suite, not full upstream `riscv-tests`.
2. CSR instructions are decoded as illegal (SYSTEM opcode, funct3!=0) — no Zicsr in this design.
3. Misaligned load/store gives silently-wrong byte lanes rather than trapping — documented simplification.
4. SDRAM controller's geometry (4-bank/13-row/10-col) and timing parameters are explicitly NOT datasheet-confirmed.
5. SD/SPI controller does not check CRC on CMD17 read data (only on commands it sends).
6. KEY[0:3]/SW[0:17] I/O standard is "Depending on JP7" — `.qsf` generation (M6) is BLOCKED on a human-confirmed jumper reading.
7. Framebuffer's VGA-side read port is combinational (zero-latency), not registered — a simplification flagged for M6 synthesis review (real M9K blocks this size typically want a registered read port; adopting one means pipelining vga.sv's RGB output by one cycle, a small, well-understood change not attempted now).
