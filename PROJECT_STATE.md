# PROJECT_STATE.md — Autonomous RISC-V DOOM SoC on DE2-115

**Read this file first in any new session.** It is the single source of truth for what is actually done, what is in progress, and exactly how to resume.

Last updated: 2026-11-08T00:15Z, by this session, at start of M4.

## Current milestone: M4 (SoC integration) — STARTING

## Completed (verified, committed)

- **M0** — capability probe, manual verification, Animas sanity check. Commit `a9a4f3b`.
- **M1** — RV32IM multicycle CPU, 32/32 directed-test checks PASS. Commit `ef09933`.
- **M2** — bare-metal firmware boot (S0/S1 gates), 6/6 checks PASS. Commit `1f0fdfb`.
- **M3** — all board peripherals verified standalone. Commits `0de834d` (GPIO/timer/bus/ROM-RAM split), `9e34864` (VGA), `2c0db5c` (SDRAM), `a0860c5` (SD/SPI). Pin audit done (not yet committed as of this checkpoint — do that first if resuming).

## Environment facts needed to resume work (do not re-derive, just reuse)

```bash
# Working RV32IM/ILP32 cross-compiler in the current shell:
source scripts/riscv_env.sh
# If it warns the MPFR compat lib is missing (fresh /tmp scratchpad in a new
# session): bash scripts/build_mpfr_compat.sh, then source riscv_env.sh again.

# Reproducible firmware build:
#   bash scripts/build_firmware.sh <name> <linker.ld> <sources...>

# Python with working pip (system python3.9 has NO pip):
module load python3/3.11.16
```

**IMPORTANT Animas performance finding**: when the Animas UI is open and connected, `run_simulation` runs in `"ui_remote_control"` mode, which for this project's longer testbenches (anything doing real bit-level SPI or similar fine-grained toggling) was observed to be **~1000x slower** than when Animas's UI connection is down and the MCP tool falls back to `"headless"` subprocess mode (6-10 seconds vs 125-180+ seconds for the same test). If a `run_simulation` call seems to be taking far longer than the simulated time should warrant, this is likely why — not a sign of an actual infinite loop. No direct way to force headless mode was found; it happens automatically when the Animas UI backend isn't reachable. **Always add a watchdog `fork`/`join_any`-based timeout in new testbenches** (pattern already used in `cpu_core_tb.sv`, `soc_bus_tb.sv`, `sd_spi_tb.sv`) so a genuine hang fails fast instead of consuming the tool-call timeout.

Animas project id `bff69947-9fc3-408f-bc64-4efffd9b8fe1`. Current `sim_top` is `sim/tb/sd_spi_tb.sv` (or whatever was last set — always call `get_project_info` to check, the user may have changed it in the UI). Project root as seen by Animas and the local filesystem path are the SAME FILES (flatpak portal) — author files locally or via `add_source_file`/`register_existing_file`.

## What exists and is verified (read docs/verification_report.md for full detail, don't re-derive)

- `rtl/cpu/{alu,regfile,decoder,mul_div,cpu_core}.sv` — RV32IM core, picorv32-style mem port.
- `rtl/peripherals/{key_sw_gpio,timer,vga,sd_spi}.sv`, `rtl/memory/sdram_ctrl.sv`, `rtl/bus/soc_bus.sv` — all verified STANDALONE (own testbench/model each). `soc_bus.sv` currently only wires up boot ROM, boot RAM, GPIO, and timer; the SDRAM/SD-SPI/VGA address ranges are decoded (reserved, won't alias) but **not yet connected** to their actual controllers.
- `sim/models/{sync_mem,sdram_model,sdhc_spi_model}.sv` — behavioral models for testing.
- `firmware/linker/{de2_115,de2_115_bus}.ld`, `firmware/startup/{crt0,crt0_bus}.S` — two linker-script/startup pairs: M2's flat single-region version, and M3's real ROM/RAM-split version with an actual `.data` load-copy.
- `scripts/{build_firmware,bin_to_readmemh,riscv_env,build_mpfr_compat,prepare_sd_image,verify_sd_image,pin_audit}.{sh,py}` — all working, reproducible.
- `docs/{memory_map,sdhc_32gb_boot_protocol,sd_card_preparation,pin_audit_report,board_resource_selection,known_limitations,verification_report}.md`, `docs/pin_assignments.csv`.

## Lessons learned this session, worth remembering (not just "it worked", but WHY)

1. **Same-cycle read-after-write is the single most common bug class in this whole project.** Non-blocking-assigning a signal and then reading it (expecting the NEW value) within the SAME always_ff invocation always gives the OLD value. Hit this three separate times: `cpu_core.sv`'s `rf_we` (M1), `sd_spi.sv`'s `resp_bytes[4]` check (M3). Watch for it reflexively in every new always_ff block: "am I reading something I just non-blocking-assigned two lines up?"
2. **SPI mode 0 data must change on the FALLING edge, sample on the RISING edge** — got this backwards once in `sd_spi.sv` (shifted `shift_tx` on the rising-edge branch), corrupting every bit after the first.
3. **Clearing a "busy" flag on the exact edge a peer module samples your combinationally-muxed output is a race.** Defer side-effect-visible-signal changes (like reverting to an idle default) by at least one additional edge after the "real" data was sampled, when another module's sampling is keyed off the same edge.
4. **Model a clock-domain-crossing peer (like an SPI slave) by clocking directly off the actual derived clock signal (`posedge sd_clk`), not by polling/registering it in a faster domain and comparing against the previous sample.** The latter adds a detection-delay that doesn't exist on real silicon and silently shifts what you sample.
5. **`objcopy -O binary` uses each section's LMA (load address), not VMA** — confirmed empirically (M3's bus-integration firmware build produced a compact 184-byte image, not one padded out through the ROM/RAM address gap), which is exactly why the AT>ROM linker-script idiom works for producing ROM images.
6. **Headless Animas runs are dramatically faster than UI-remote-control runs** for fine-grained-toggle-heavy testbenches — see the Animas performance note above.
7. Always add a bounding watchdog to any testbench with a `wait(...)` on a condition that could plausibly never resolve if there's a bug — a real deadlock in `sd_spi_tb.sv` without one cost real wall-clock time to notice.

## M4 plan (SoC integration)

Per the mission's M4 gate: "real SD/bootloader startup into SDRAM, basic framebuffer animation driven by RTL-executed code."

- [ ] Wire `sdram_ctrl.sv`, `sd_spi.sv`, and `vga.sv` into `soc_bus.sv`'s currently-reserved-but-unwired address ranges (update `docs/memory_map.md` if the exact VGA framebuffer address/size needs adjusting once wired).
- [ ] Write the actual bootloader: ROM-resident code that drives `sd_spi.sv` through its MMIO registers to read the boot image header (LBA 0) via CMD17, parse it (magic/version/load+entry addr/length — reuse the exact format `prepare_sd_image.py` emits), then loop reading sequential LBAs to copy the program into SDRAM at its load address, then jump to the entry address. This is real firmware, written in C or assembly, built with `scripts/build_firmware.sh`, not just more RTL.
- [ ] A small SDRAM-resident test program (framebuffer animation: write a few different frames into the VGA framebuffer region, prove the VGA module scans them out — "basic framebuffer animation driven by RTL-executed code" per the gate).
- [ ] End-to-end testbench: real SD image (built by `prepare_sd_image.py`) → `sdhc_spi_model.sv` → bootloader on `cpu_core` → SDRAM → jump → test program writes frames → `vga.sv` scans out → check `fb_addr`/pixel values at specific times, matching the pattern already proven in `vga_tb.sv`.
- [ ] Commit M4, then M5 (fetch real DoomGeneric + Freedoom, port the platform hooks, attempt the real game loop on the RTL CPU) and M6 (Quartus handoff: `.qpf`/`.qsf`/`.sdc`, `rtl/board/de2_115_top.sv`, extend `pin_audit.py` to cross-check it).

## Scope decisions recorded so far (so they aren't re-litigated or silently reversed later)

1. M1 verification uses a curated directed-test suite, not full upstream `riscv-tests`.
2. CSR instructions are decoded as illegal (SYSTEM opcode, funct3!=0) — no Zicsr in this design.
3. Misaligned load/store gives silently-wrong byte lanes rather than trapping — documented simplification.
4. SDRAM controller's geometry (4-bank/13-row/10-col) and timing parameters are explicitly NOT datasheet-confirmed — flagged for human-team verification against the real installed chips before hardware bring-up.
5. SD/SPI controller does not check CRC on CMD17 read data (only on the commands it sends, which DOES use real CRC7) — documented simplification per the mission's own allowance.
6. KEY[0:3]/SW[0:17] I/O standard is "Depending on JP7" per the manual — `.qsf` generation (M6) is BLOCKED on a human-confirmed jumper reading; do not default/guess this.
