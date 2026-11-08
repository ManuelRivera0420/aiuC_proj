# PROJECT_STATE.md — Autonomous RISC-V DOOM SoC on DE2-115

**Read this file first in any new session.** It is the single source of truth for what is actually done, what is in progress, and exactly how to resume.

Last updated: 2026-11-08, by this session, mid-run on M5's S3 attempt.

## Current milestone: M6 (Quartus handoff) — DONE. M5's S3 direct-execution attempt is IN PROGRESS (not yet concluded) — see below for exactly how to check on it or resume it.

## If you're resuming because the session ended mid-run: check this FIRST

A real simulation (`sim/tb/m5_doom_exec_tb.sv`, Animas project id below, already set as `sim_top`) was left running when this file was last updated. Before doing anything else:

1. Call `get_last_sim_result(project_id)`. If `log_line_count` has grown past 95 and/or `finished` is `true`, read `read_simulation_log(last_n_lines=30)` for the `[RESULT]` line the testbench prints (ILLEGAL_INSTR / HALTED / FRAMEBUFFER FULLY WRITTEN / WATCHDOG) and write that outcome into `docs/verification_report.md`'s "M5 — S3 direct-execution attempt" section (currently marked IN PROGRESS) and into the "Completed and VERIFIED" list below. Do NOT re-trigger `run_simulation` first — you'd lose whatever progress already happened; check the existing result first.
2. If it's still at `log_line_count=95` (last known value) and not finished: it's probably still genuinely running (confirmed once already via direct host `ps` inspection showing a live, CPU-accumulating `zenith` subprocess under `marivera`, parented by `animas-backend` — not a repeat of the earlier daemon-lock issue). Check `ps -u marivera -o pid,pcpu,etimes,stat,cmd | grep zenith` yourself before assuming it's stuck; only consider it a genuine blocker if that shows no live process or a zombie with no forward progress across multiple checks spaced several minutes apart.
3. This specific test is known to run **slowly** in `ui_remote_control` mode (full CPU+bus+SDRAM RTL, toggling every cycle, for up to `WATCHDOG_CYCLES=60_000_000` cycles) — budget real patience, not a quick poll-and-give-up.

## Completed and VERIFIED (committed, Animas-confirmed)

- **M0** — capability probe, manual verification, Animas sanity check. Commit `a9a4f3b`.
- **M1** — RV32IM multicycle CPU, 32/32 directed-test checks PASS. Commit `ef09933`.
- **M2** — bare-metal firmware boot (S0/S1 gates), 6/6 checks PASS. Commit `1f0fdfb`.
- **M3** — all board peripherals verified standalone. Commits `0de834d`, `9e34864`, `2c0db5c`, `a0860c5`, `cd53bd0`.
- **M4** — full SoC integration (real SD boot image → bootloader → cpu_core → SDRAM → jump → framebuffer → VGA), 7/7 checks PASS. Commit `03d0df7`.
- **M5 (partial)** — real DoomGeneric compiles+links clean for RV32IM/ILP32 (S0-S2 gates), 0 unsupported-instruction hits. Framebuffer reformatted to the real 8-bit-indexed+palette format, re-verified 7/7 PASS. Commits `a7e4132` (fetch+finding), `a75f57b` (framebuffer reformat).
- **M6 (done)** — `rtl/board/de2_115_top.sv` written and smoke-tested via Animas (`sim/tb/board_top_smoke_tb.sv`, 3/3 PASS). `scripts/pin_audit.py` extended with a top-level port cross-check (0 errors across 26 signals/132 pins). `fpga/de2_115/doom_riscv_de2_115.{qpf,qsf,sdc}` hand-written (not Quartus-generated; device speed grade and KEY/SW I/O standard both explicitly flagged rather than guessed — see those files' own headers and `docs/fpga_handoff.md` §2). `docs/{module_interfaces,clock_reset_cdc,fpga_handoff,how_to_run_doom}.md` written. See the commit immediately after this file's previous version for the exact file list.

## M5's honest status — read this before doing anything with DOOM

**Done (verified)**: DoomGeneric compiles and links (S0-S2). **In progress, not yet concluded**: executing it on `cpu_core` (S3) — see the "if you're resuming mid-run" section above. Do NOT conflate "compiles" with "runs," and do NOT conflate "a test is running" with "a test has passed" — check the actual `[RESULT]` line before writing anything into the verified-list above.

The direct-SDRAM-preload fast-path testbench this section used to describe as a future plan now exists: `sim/tb/m5_doom_exec_tb.sv`, using `sdram_model.sv`'s new `PRELOAD1_FILE`/`PRELOAD2_FILE` parameters (option 1 from the old plan) and `soc_bus.sv`'s new `BOOT_ROM_FILE` parameter (so this test's custom 2-instruction jump-to-entry boot ROM, `sim/models/m5_exec/jump_stub.S`, doesn't clobber M3/M4's shared `sim/models/soc_rom.hex`). Two real things were found and fixed while building it — a `ZEN-6033` LRM violation (same bug class as M1's `sync_mem.sv` fix) and a host-scale limitation preloading the full 28MB WAD (see `docs/verification_report.md`'s M5 S3 section for both, in detail). The real freedoom1.wad (hash-verified against `software/source-lock.json`) lives at `.build_tmp/freedoom-0.13.0/freedoom1.wad` if a future attempt wants to retry WAD preloading with a smaller chunk or a different approach than one giant associative-array loop.

**Rebuild command** (if `firmware/build/doom/doom.elf` is stale or missing): `bash scripts/build_doom.sh`. Takes under a minute; no Animas needed for this step. The preload hex files (`sim/models/m5_exec/*.hex`, gitignored) are regenerated via `scripts/bin_to_readmemh.py` — see `sim/tb/m5_doom_exec_tb.sv`'s header for exact paths/sizes expected.

## Environment facts needed to resume work (do not re-derive, just reuse)

```bash
source scripts/riscv_env.sh   # RV32IM/ILP32 cross-compiler; sources workspace_env.sh automatically
bash scripts/build_firmware.sh <name> <linker.ld> <sources...>   # reproducible firmware build
bash scripts/build_doom.sh                                        # builds the full DoomGeneric port
module load python3/3.11.16   # for pip-installed tools (pypdf, etc) -- system python3.9 has no pip
```

**Build scratch lives under `.build_tmp/` in the project root, NOT `/tmp`** (host `/tmp` is a small shared volume observed at 84% full across a multi-tenant machine). `scripts/workspace_env.sh` sets `TMPDIR`/`TMP`/`TEMP`; `scripts/riscv_env.sh` sources it automatically. Confirmed by direct inspection that Animas/Zenith itself doesn't write to `/tmp` for this project. Full details: `docs/known_limitations.md`.

**Animas daemon**: can get stuck (`ERROR: ZenithDaemonClient: job already in progress`) in a way no available MCP tool can clear — happened once this project, needed a human to restart the Animas application. If `run_simulation` returns that exact error repeatedly, that's the signal to ask for a restart, not to keep retrying. Separately, `list_projects` has been seen to fail with `Invalid request parameters` even called correctly — verify connectivity with `get_project_info(project_id=...)` using the known id instead if that happens. For a LONG test, `run_simulation` can return (`status:"ok"`) with the simulation still running in the background in `ui_remote_control` mode — check `get_last_sim_result`'s `finished` field (poll it again WITHOUT a new `run_simulation` call) rather than assuming an early return means failure. **When querying waveforms with `find_signal_transitions`, the `value` parameter is always a BINARY string, never decimal** — passing `"40"` searches for binary `101000`'s complement-of-intent, not decimal 40; this looked like a simulation hang once and wasn't.

Animas project id `bff69947-9fc3-408f-bc64-4efffd9b8fe1`. `sim_top` was last set to `sim/tb/m4_e2e_tb.sv`.

## What exists and is verified (read docs/verification_report.md for full detail, don't re-derive)

- `rtl/cpu/{alu,regfile,decoder,mul_div,cpu_core}.sv` — RV32IM core.
- `rtl/peripherals/{key_sw_gpio,timer,vga,sd_spi,framebuffer}.sv`, `rtl/memory/sdram_ctrl.sv`, `rtl/bus/soc_bus.sv` — all wired together, verified end-to-end. `framebuffer.sv` stores 8-bit palette indices (64,000 bytes) + an integrated 256-entry palette RAM — NOT 32-bit RGB (that was an M4-only placeholder, superseded in M5).
- `sim/models/{sync_mem,sdram_model,sdhc_spi_model}.sv` — behavioral models. `sdram_model.sv` does NOT currently support bulk preload (see "concrete next step" above).
- `firmware/bootloader/bootloader_main.c` — copies the PROGRAM region from SD into SDRAM; does NOT yet copy a WAD region (the boot-image format already has `wad_lba_start`/`wad_length` fields, unused so far).
- `firmware/linker/de2_115_soc.ld` — 32MiB SDRAM window (enlarged from M4's 1MiB placeholder once DOOM's real heap needs became apparent).
- `software/upstream/doomgeneric/` — pristine vendored GPL-2.0 source, pinned commit `e257a09527062bfb986b6e5e0780839b6cbd5b71`. **Not patched** — every integration need was met via existing extension points (swappable WAD backend, non-static `colors[]`/`palette_changed` globals under `CMAP256`).
- `software/doom_port/{doomgeneric_de2115,w_file_de2115,main_de2115}.c` — the platform port.
- `firmware/platform/syscalls.c` — the ~14-function Newlib syscall stub layer.
- `scripts/build_doom.sh` — builds all of the above into `firmware/build/doom/doom.elf`.
- `software/source-lock.json` — DoomGeneric/Freedoom provenance, the pixel-format finding with citations.
- `rtl/board/de2_115_top.sv` — board-level top, instantiates `cpu_core`+`soc_bus`+`vga` directly, every port matching `docs/pin_assignments.csv`. Smoke-tested (3/3 PASS), not synthesized.
- `fpga/de2_115/doom_riscv_de2_115.{qpf,qsf,sdc}` — hand-written Quartus project files for human-team handoff. Never opened in real Quartus by this project.
- `scripts/pin_audit.py` — now cross-checks the CSV against `de2_115_top.sv`'s real ports too, not just self-consistency.

## Lessons learned, cumulative (don't rediscover these)

1. **Same-cycle read-after-write** is the most common RTL bug class in this project.
2. **SPI mode 0**: data changes on the falling edge, sampled on the rising edge.
3. **Don't clear a "busy" flag on the exact edge a peer samples your combinationally-muxed output.**
4. **Model a clock-domain peer by clocking directly off the actual derived clock.**
5. **`objcopy -O binary` uses each section's LMA.**
6. **A byte-order bug can pass its own self-consistent unit test while still being wrong relative to the real downstream consumer** — check against the actual consumer, not just internal consistency.
7. **Always add a bounding watchdog** to any testbench `wait(...)`.
8. **When an external tool gets stuck in a way no available tool can fix, retry a reasonable number of times with real elapsed time and unrelated work interspersed, then stop and document the blocker precisely.**
9. **After external tooling changes, verify connectivity with a cheap, specific call before resuming** — don't treat every failing call as proof a fix didn't work.
10. **A `run_simulation` return doesn't always mean the simulation finished** — check `finished`.
11. **Don't assume a tool writes to `/tmp` — check directly.**
12. **`find_signal_transitions`'s `value` parameter is binary, not decimal** — learned the hard way mid-M5, cost real time second-guessing a healthy simulation as "stuck."
13. **Before hand-writing a libc, try actually linking against what the toolchain bundles** — Newlib was there the whole time, built for the exact target triple, and discovering the ~14 needed syscall stubs by reading real linker errors took minutes, not the hours a from-scratch libc would have.
14. **Before assuming a third-party codebase needs patching for platform integration, check whether it already has an extension point** — DoomGeneric's swappable WAD-backend vtable and its deliberately-non-static `colors`/`palette_changed` globals under `CMAP256` both existed specifically for this purpose; patching would have been unnecessary extra risk.
15. **"Compiles and links" is not "runs" — don't let a big static-gate win create momentum toward claiming more than was actually verified.** This file's own M5 section is deliberately blunt about the line between the two.
16. **A preload/bulk-write mechanism added to a model with an existing `always_ff` writer of the same array must write from inside that SAME process, not a separate `initial` block** — ZEN-6033 (LRM 9.2.2.4) rejects two processes writing one variable even when their actual write targets never overlap at runtime; the elaborator checks statically, not by value.
17. **A multi-million-entry SystemVerilog associative array populated via a procedural loop can be dramatically slower (or get the simulator subprocess stuck/zombied) than the same mechanism at thousands-of-entries scale** — tested directly (7.2M WAD words vs. 141K program words on the exact same mechanism), not assumed; descope to the smaller, still-meaningful version rather than burning unbounded time chasing the larger one.
18. **A live `ps`/`/proc` check of the actual host process (state, accumulated CPU time across repeated samples) is the way to tell "genuinely still running" apart from "silently stuck" when an MCP tool's own status call keeps returning the same unchanged snapshot** — don't conflate "no new log output" with "nothing is happening."

## M6 plan (Quartus handoff — DONE)

Per the mission's M6 gate and Section 4/7's repo structure requirements. Did not depend on M5's runtime gap — proceeded independently of it, as planned.

- [x] `docs/module_interfaces.md` + `docs/clock_reset_cdc.md` — every RTL module's port interface, the two clock domains (`clk`/`pclk`, `pclk` a divide-by-2 generated clock off `clk`, no PLL), the async-reset strategy, and the one real CDC in the whole design (framebuffer scan-out: `pclk`-domain combinational read against `clk`-domain-written BRAM, no synchronizer — documented as a bounded, cosmetic-worst-case risk, not swept under the rug).
- [x] `rtl/board/de2_115_top.sv` — the real board-level top module, every port matching `docs/pin_assignments.csv` exactly (mechanically cross-checked, see next item). KEY/SW I/O standard correctly left unassigned in the `.qsf` rather than guessed (see below).
- [x] `fpga/de2_115/doom_riscv_de2_115.{qpf,qsf,sdc}` — Quartus project files, hand-written and explicitly labeled as such in each file's header. `.qsf` pin assignments generated directly from `docs/pin_assignments.csv` (132 pins); KEY[0:3]/SW[0:17] deliberately have NO `IO_STANDARD` line (flagged as JP7-blocked, not guessed); device set to `EP4CE115F29C7` with the `C7` speed-grade digit explicitly flagged as the common-default-not-confirmed value. `.sdc` declares `CLOCK_50` (50MHz) and `VGA_CLK` as a proper `create_generated_clock -divide_by 2`, sets `set_false_path` only where this project's own RTL/sim actually justifies it (async KEY/SW/SD_DAT[0] inputs), and explicitly does NOT fabricate `set_input_delay`/`set_output_delay` values it has no basis for — left as a named human-team follow-up instead.
- [x] Extended `scripts/pin_audit.py` with `parse_top_level_ports()` (regex-based port extraction) and a bidirectional cross-check against `rtl/board/de2_115_top.sv` — run as `python3 scripts/pin_audit.py docs/pin_assignments.csv rtl/board/de2_115_top.sv`, currently **0 errors** across 26 signals/132 pins.
- [x] `docs/fpga_handoff.md` — the human team's complete build-order document: what's provided, the three unresolved physical-confirmation items (device speed grade, JP6/JP7 jumper reading, SD card electrical compatibility) that block a correct Quartus compile, the build order itself, and — most importantly — an explicit, unambiguous statement of the M5 DOOM-execution gap (§4) so no one mistakes "compiles cleanly" for "runs."
- [x] `docs/how_to_run_doom.md` — operator's guide for the DOOM path specifically. Documents a genuine, previously-undocumented-at-this-level-of-specificity gap found while writing it: `firmware/bootloader/bootloader_main.c`'s `main()` only reads header words `[0..5]` (magic/version/load_addr/entry_addr/length/prog_lba_start) and never touches `header[6]`/`header[7]` (`wad_lba_start`/`wad_length`) — so it copies the program but never the WAD, even though `scripts/prepare_sd_image.py` already supports embedding one. Small, mechanical fix (repeat the existing copy loop over a second LBA range into `WAD_SDRAM_BASE = 0x14000000`), explicitly scoped as a near-term human-team (or future-session) task, not done in this pass because M6's own deliverables took priority.

## Scope decisions recorded so far (so they aren't re-litigated or silently reversed later)

1. M1 verification uses a curated directed-test suite, not full upstream `riscv-tests`.
2. CSR instructions are decoded as illegal — no Zicsr in this design.
3. Misaligned load/store gives silently-wrong byte lanes rather than trapping.
4. SDRAM controller's geometry/timing parameters are explicitly NOT datasheet-confirmed.
5. SD/SPI controller does not check CRC on CMD17 read data.
6. KEY[0:3]/SW[0:17] I/O standard is "Depending on JP7" — `.qsf` generation is BLOCKED on a human-confirmed jumper reading.
7. Framebuffer's VGA-side read port is combinational, not registered — flagged for M6 synthesis review.
8. Framebuffer pixel format is 8-bit indexed + palette RAM (locked in M5, superseding M4's 32-bit-RGB placeholder), matching DoomGeneric's actual native format.
9. DoomGeneric's networking (`d_net.c`, kept) is compiled but never actually used (always single-player, `drone=false`/`net_client_connected=false` from `dummy.c`) — no multiplayer support, matching mission scope.
10. The "next weapon" switch (`SW[5]`) maps to ASCII `'2'` (a specific weapon-select key) rather than a dedicated cycle key, because vanilla DOOM's control scheme has no such key — documented substitution, not an oversight.
11. WAD access is via a full SDRAM preload (`software/doom_port/w_file_de2115.c`'s `WAD_SDRAM_BASE`), not live SD reads during gameplay — matches the mission's explicit allowance for this. The bootloader does not yet implement the WAD-copy half of this (only the program-copy half); that's required before any real game session, tracked as a near-term next step alongside the direct-SDRAM-preload testbench above.
