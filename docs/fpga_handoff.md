# FPGA Handoff — M6

This is the single document a human team member should start from to take this project's RTL/firmware from "fully verified in Animas/Zenith simulation" to "running on a physical Terasic DE2-115 board." It consolidates what is provided, what is genuinely verified, what is explicitly NOT done, and the concrete build order — with pointers into the supporting docs rather than repeating their full content.

**Scope boundary, stated plainly**: this project never ran Quartus (synthesis, fitting, timing analysis, or device programming) at any point — that was out of scope by explicit mission instruction throughout M0-M6, not an oversight or a thing attempted and abandoned. Everything below is prepared *for* that human-run step, not a claim that it already happened.

## 1. What is provided

| Category | Location | Status |
|---|---|---|
| RTL (CPU + all peripherals + board top) | `rtl/` | Verified in Animas/Zenith simulation, see `docs/verification_report.md` for the full per-milestone pass/fail record |
| Board-level top module | `rtl/board/de2_115_top.sv` | Smoke-tested (`sim/tb/board_top_smoke_tb.sv`, 3/3 PASS) — CPU runs after reset, structural connectivity confirmed, NOT synthesized |
| Pin assignments | `docs/pin_assignments.csv` | Independently audited against the board manual (M0) and mechanically cross-checked against `de2_115_top.sv`'s actual ports (`scripts/pin_audit.py`, 0 errors as of this writing) |
| Quartus project files | `fpga/de2_115/doom_riscv_de2_115.{qpf,qsf,sdc}` | Hand-written to the correct file format, **not Quartus-generated** — see §2 before opening |
| Firmware | `firmware/` (bootloader, linker scripts, startup code, syscall stubs) | Compiles and runs in simulation through M4's full SD-boot pipeline |
| DOOM port | `software/doom_port/`, vendored `software/upstream/doomgeneric/` | Compiles and links clean for RV32IM (M5, S0-S2 gates) — see §4, this is **not yet proven to execute** on this CPU |
| Documentation | `docs/` (this file plus memory map, module interfaces, CDC, boot process, SD protocol, known limitations, verification report) | Written incrementally alongside the RTL, cross-referenced below |

## 2. Before you open Quartus: three unresolved items

These are genuine open questions, not items this project could have resolved without the physical board in hand. All three are already tracked in `docs/known_limitations.md`; repeated here because they directly block a correct Quartus compile:

1. **Device speed grade.** `fpga/de2_115/doom_riscv_de2_115.qsf` sets `DEVICE EP4CE115F29C7` — `C7` is the commonly shipped Terasic DE2-115 configuration, used here as a reasonable starting point, but **not confirmed** against this specific board's physical device marking (the manual text read in M0 only gives `EP4CE115F29`, no speed-grade digit). Check the chip markings or Quartus's own device-detection on first programming attempt; correct the `.qsf` if different.
2. **JP6/JP7 jumper position.** `KEY[0:3]` and `SW[0:17]` have **no `IO_STANDARD` assignment** in the `.qsf` at all — the manual marks these pins "Depending on JP7" rather than a fixed voltage, and guessing would risk an incorrect (and on some FPGA families, damaging) I/O standard. Read the physical jumper position on the board, then add the matching `set_instance_assignment -name IO_STANDARD "<2.5-V|3.3-V> LVTTL" -to KEY[*]` / `SW[*]` lines before compiling.
3. **SD card electrical compatibility.** The manual confirms the socket supports SPI mode generically; it does not constitute lab-verified compatibility with the specific ADATA `AUSDH32GUICL10-RA1` card this project's SD-image prep scripts target (`scripts/prepare_sd_image.py`). Worth a quick continuity/bring-up check with a scope or logic analyzer before assuming the SPI timing in `rtl/peripherals/sd_spi.sv` (12.5 MHz fast-mode default, `FAST_CLK_DIV=4`) works with your specific card — that parameter was only ever validated against the behavioral `sdhc_spi_model.sv`, never real SD card AC timing.

## 3. Build order

1. **Resolve §2's three items first.**
2. Open Quartus, create/import the project from `fpga/de2_115/doom_riscv_de2_115.qsf` (or start a fresh Quartus project and point it at the same file list — either way, let Quartus rewrite the `.qpf`/`.qsf` on first save; this project's hand-written versions are a reviewed starting point, not something to defend against Quartus's own normalization).
3. **Consider adding a PLL megafunction for the VGA pixel clock** before compiling. `rtl/peripherals/vga.sv` currently divides `CLOCK_50` by a plain toggle flip-flop to approximate 25 MHz (see `docs/clock_reset_cdc.md` §1) — adequate for simulation and first bring-up, measurably jittier than a real Cyclone IV `altpll` output. This is an optional quality improvement, not a correctness blocker.
4. Run Analysis & Synthesis, then Fitter, then TimeQuest. **Add `set_input_delay`/`set_output_delay` constraints** for the board-level I/O before trusting TimeQuest's timing closure numbers — `fpga/de2_115/doom_riscv_de2_115.sdc` deliberately does not fabricate these (see that file's own header comment): they depend on board trace lengths and external device timing (the ADV7123 VGA DAC, the SDRAM chips, the SD socket) that this project had no way to measure from RTL simulation alone.
5. Verify the Fitter's resource usage against the DE2-115's actual device (114,480 LEs, 432 M9K blocks — `docs/board_resource_selection.md`) — this project never ran synthesis, so there is no utilization estimate to compare against beyond the module-level BRAM sizing math already in `docs/memory_map.md`.
6. Program the device and confirm the board boots to whatever `firmware/bootloader/bootloader_main.c` does first (LED status codes per `docs/boot_process.md`) before attempting anything DOOM-related — see §4 for why that's a materially separate, unverified step.

## 4. The DOOM gap — read this before expecting DOOM to run

`docs/verification_report.md`'s M5 section is explicit about this and it is repeated here because it is the single most important thing for a human team to understand before investing hardware bring-up time on it: **the real, complete DoomGeneric engine compiles and links cleanly for this CPU's exact instruction set (RV32IM, zero unsupported instructions across the entire 792KB binary) — but this project never executed that binary on `cpu_core`, not in simulation and certainly not on real hardware.**

Two concrete, measured reasons this wasn't attempted (not hand-waved):
- The verified SD-boot pipeline (M4) scales roughly linearly with sector count; DOOM's `.text+.data` alone is ~566KB (≈1,106 sectors), and M4's own measured per-sector timing extrapolates to an impractically long simulated-time cost to exercise through Animas.
- A faster direct-SDRAM-preload testbench (bypassing the slow SD path, analogous to how M1-M3 tested modules standalone) was identified as the right next step but not yet built — `sim/models/sdram_model.sv` has no bulk-preload capability as written.

**A second, separate, real gap**: even once DOOM's binary is on SDRAM, `firmware/bootloader/bootloader_main.c` does not yet copy the Freedoom WAD file into SDRAM alongside the program — only the program binary. `software/doom_port/w_file_de2115.c` assumes the WAD is already present at `WAD_SDRAM_BASE` (0x1400_0000); something has to put it there first. This is a real, scoped-but-not-yet-done piece of bootloader work, not a hidden design flaw — the WAD backend interface itself is complete and correct (see `docs/verification_report.md`'s M5 section, item 2).

**What this means in practice for the human team**: expect the board to boot firmware and run the verified peripherals (VGA output, SD-card program loading, GPIO input, SDRAM) correctly — that path is simulation-verified end to end (M4). Do **not** expect DOOM gameplay to appear without first (a) extending the bootloader to also copy the WAD, and (b) either tolerating a very long first boot while the real SD path copies ~566KB+WAD, or building the faster direct-preload path for initial hardware bring-up/debugging. Treat getting an actual DOOM frame on the VGA output as the next real milestone after hardware bring-up succeeds on the already-verified parts, not as something this handoff already delivers.

## 5. Where to look for more detail

- `docs/memory_map.md` — address map, GPIO register layout
- `docs/module_interfaces.md` — every module's port list and bus protocol
- `docs/clock_reset_cdc.md` — clock domains, reset strategy, the one real CDC in this design (framebuffer scan-out)
- `docs/boot_process.md`, `docs/sdhc_32gb_boot_protocol.md`, `docs/sd_card_preparation.md` — SD boot details
- `docs/board_resource_selection.md` — manual citations for every pin/peripheral choice
- `docs/pin_audit_report.md` — the pin-consistency audit methodology and results
- `docs/known_limitations.md` — every honestly-flagged gap found across the whole project, in one place
- `docs/verification_report.md` — the full milestone-by-milestone simulation evidence trail
- `software/source-lock.json` — DoomGeneric/Freedoom provenance, licenses, and the pixel-format finding with citations
- `docs/how_to_run_doom.md` — step-by-step operator instructions for the DOOM path specifically, written with the §4 gap in mind
