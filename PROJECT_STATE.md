# PROJECT_STATE.md — Autonomous RISC-V DOOM SoC on DE2-115

**Read this file first in any new session.** It is the single source of truth for what is actually done, what is in progress, and exactly how to resume.

Last updated: 2026-11-08T01:50Z, by this session, at start of M5.

## Current milestone: M5 (DoomGeneric + Freedoom port) — STARTING

## Completed and VERIFIED (committed, Animas-confirmed)

- **M0** — capability probe, manual verification, Animas sanity check. Commit `a9a4f3b`.
- **M1** — RV32IM multicycle CPU, 32/32 directed-test checks PASS. Commit `ef09933`.
- **M2** — bare-metal firmware boot (S0/S1 gates), 6/6 checks PASS. Commit `1f0fdfb`.
- **M3** — all board peripherals verified standalone. Commits `0de834d`, `9e34864`, `2c0db5c`, `a0860c5`, `cd53bd0`.
- **M4** — full SoC integration (real SD boot image → bootloader → cpu_core → SDRAM → jump → framebuffer → VGA), 7/7 checks PASS. `sd_spi_tb.sv` reconfirmed (9/9) after a byte-order fix. Commit: the one immediately following this file's previous version — check `git log --oneline`.

## Environment facts needed to resume work (do not re-derive, just reuse)

```bash
source scripts/riscv_env.sh   # RV32IM/ILP32 cross-compiler; sources workspace_env.sh automatically
bash scripts/build_firmware.sh <name> <linker.ld> <sources...>   # reproducible firmware build
module load python3/3.11.16   # for pip-installed tools (pypdf, etc) -- system python3.9 has no pip
```

**IMPORTANT — build scratch location changed this session**: all build/compile scratch (MPFR compat library, TMPDIR/TMP/TEMP) now lives under `.build_tmp/` in the project root, NOT `/tmp`. This host's `/tmp` is a small (20G) volume shared across every user on a multi-tenant machine and was observed at 84% full. `scripts/workspace_env.sh` sets this up; `scripts/riscv_env.sh` sources it automatically. If `.build_tmp/mpfr_local` is ever missing (e.g. a fresh clone), rebuild it with `bash scripts/build_mpfr_compat.sh`. **Confirmed by direct inspection** (before/after `/tmp` snapshot diff across a full simulation run, plus `lsof` on the running daemon) that Animas/Zenith itself does not write simulation artifacts to `/tmp` for this project — ZWDB/logs go to the project's own `output/` directory. Full writeup in `docs/known_limitations.md`.

**Animas daemon note**: the daemon CAN get stuck (`ERROR: ZenithDaemonClient: job already in progress`) in a way no available MCP tool can clear — happened once this project, required the user to restart the Animas application. If `run_simulation` returns that exact error repeatedly (not just once), that's the signal to ask the user to restart Animas, not to keep retrying indefinitely. Separately: a bare `list_projects` call has been seen to fail with `Invalid request parameters` even with correct zero-argument usage, while `get_project_info(project_id=...)` with the known project ID works fine — if `list_projects` ever fails, that alone does NOT mean the connection is down; verify with `get_project_info` using the known id (`bff69947-9fc3-408f-bc64-4efffd9b8fe1`) before concluding anything is actually broken.

**Animas performance note**: `ui_remote_control` mode (Animas UI open) can be dramatically slower than headless subprocess mode (triggered automatically when the UI backend isn't reachable) for fine-grained-toggle-heavy testbenches. Also: for a long-running test, a `run_simulation` call can return (`status: "ok"`) with the simulation still running in the background in the Animas UI — check the returned log for a `$finish`/result line, and if absent, poll `get_last_sim_result` (`finished` field) / `read_simulation_log` again WITHOUT issuing a new `run_simulation` call, rather than assuming failure or re-triggering redundantly.

Animas project id `bff69947-9fc3-408f-bc64-4efffd9b8fe1`. `sim_top` was last set to `sim/tb/m4_e2e_tb.sv`.

## What exists and is verified (read docs/verification_report.md for full detail, don't re-derive)

- `rtl/cpu/{alu,regfile,decoder,mul_div,cpu_core}.sv` — RV32IM core.
- `rtl/peripherals/{key_sw_gpio,timer,vga,sd_spi,framebuffer}.sv`, `rtl/memory/sdram_ctrl.sv`, `rtl/bus/soc_bus.sv` — all wired together and verified end-to-end as of M4, not just standalone.
- `sim/models/{sync_mem,sdram_model,sdhc_spi_model}.sv` — behavioral models.
- `firmware/bootloader/bootloader_main.c` — real bootloader: waits for SD/SPI init, validates the boot image header, copies the program into SDRAM via CMD17, jumps to its entry point, LED status codes per phase.
- `firmware/linker/{de2_115,de2_115_bus,de2_115_soc}.ld`, `firmware/startup/{crt0,crt0_bus}.S` — three linker-script/startup pairs now: M2's flat single-region, M3's ROM/RAM-split-with-data-copy (reused for the bootloader itself), M4's SDRAM-resident-program version (reuses the simple M2-style crt0 since the bootloader places the full image, data included, directly at link addresses).
- `scripts/{build_firmware,bin_to_readmemh,riscv_env,build_mpfr_compat,workspace_env,prepare_sd_image,verify_sd_image,pin_audit}.{sh,py}`.
- `docs/{memory_map,sdhc_32gb_boot_protocol,sd_card_preparation,pin_audit_report,board_resource_selection,known_limitations,verification_report,boot_process}.md`, `docs/pin_assignments.csv`.

## Lessons learned, cumulative (don't rediscover these)

1. **Same-cycle read-after-write** is the most common bug class in this project (hit 3 times: `cpu_core.sv` M1, `sd_spi.sv` M3 twice).
2. **SPI mode 0**: data changes on the falling edge, sampled on the rising edge.
3. **Don't clear a "busy" flag on the exact edge a peer samples your combinationally-muxed output** — defer by one more edge.
4. **Model a clock-domain peer by clocking directly off the actual derived clock**, not by polling it from a faster domain.
5. **`objcopy -O binary` uses each section's LMA** — confirmed empirically.
6. **A byte-order/endianness bug can be internally self-consistent and pass its own unit test while still being wrong relative to the real downstream consumer's assumptions.** Check against the actual consumer (here: RV32's little-endian `sw` semantics), not just internal consistency.
7. **Always add a bounding watchdog** to any testbench `wait(...)`.
8. **When an external tool gets stuck in a way no available tool can fix, retry a reasonable number of times with real elapsed time and unrelated work interspersed, then stop and document the blocker precisely** — don't fabricate progress or hammer the same failing call forever. This worked exactly as intended: the blocker was reported, the user fixed it (app restart), and work resumed cleanly from the documented checkpoint.
9. **After external tooling changes (daemon restart, app relaunch), verify connectivity with a cheap, specific call before resuming real work** — and don't treat every failing call as proof the fix didn't work; some endpoints can have their own narrow issues independent of the main problem (e.g. `list_projects` here).
10. **A `run_simulation` return doesn't always mean the simulation finished**, especially for a longer test — check `finished`, don't assume.
11. **Don't assume a tool/project writes to `/tmp` — check directly** (before/after snapshot diff, `lsof` on the live process) before changing behavior to work around an assumed problem.

## M5 plan (DoomGeneric + Freedoom)

Per the mission's software-gate ladder (S0-S4, already satisfied through S1 as of M2/M4's real compiled C running on `cpu_core`):

- [ ] Fetch DoomGeneric (`https://github.com/ozkl/doomgeneric`) and Freedoom (`https://freedoom.github.io/download.html` or the GitHub mirror) — confirmed internet access works (verified in M0). Pin exact commit/version/SHA-256 in `software/source-lock.json` per the mission's requirement. Keep upstream source pristine under `software/upstream/`, platform-hook adaptations under `software/doom_port/`.
- [ ] Inspect the pinned revision's actual `DG_ScreenBuffer` pixel format — do NOT assume 8-bit paletted; the mission explicitly warns this. `rtl/peripherals/framebuffer.sv`'s current 32-bit-RGB-per-pixel format was an M4 placeholder for testing, not a locked decision — revisit once the real format is known.
- [ ] Implement the `doomgeneric_*` platform hooks (`DG_Init`, `DG_DrawFrame`, `DG_SleepMs`, `DG_GetTicksMs`, `DG_GetKey`) against this project's actual memory map (`rtl/peripherals/key_sw_gpio.sv` for input, the framebuffer for output, `rtl/peripherals/timer.sv` for timing) — no SDL/X11/Windows.
- [ ] Static ISA/ABI gate on the compiled DoomGeneric binary (same `readelf -A`/`objdump` check used for every firmware build so far) before attempting to run it.
- [ ] S2/S3/S4 software gates: allocator/libc helpers needed by DoomGeneric, WAD file access via the SD image (extend `prepare_sd_image.py`'s format to include a WAD region — it already has `wad_lba_start`/`wad_length` fields, unused until now), then the actual game loop attempt on `cpu_core` via Animas.
- [ ] Expect this to be the hardest milestone yet — DoomGeneric is a real, non-trivial C codebase, not a small test program. Budget for multiple directed sub-tests before attempting the full game loop (per the mission's explicit instruction not to skip straight from code generation to a DOOM PASS claim).

## M6 plan (after M5): Quartus handoff

`.qpf`/`.qsf`/`.sdc`, `rtl/board/de2_115_top.sv`, extend `pin_audit.py` to cross-check the real top-level against `docs/pin_assignments.csv`. **Blocked item already known**: KEY[0:3]/SW[0:17] I/O standard needs a human-confirmed JP7 jumper reading before `.qsf` generation — don't guess it.

## Scope decisions recorded so far (so they aren't re-litigated or silently reversed later)

1. M1 verification uses a curated directed-test suite, not full upstream `riscv-tests`.
2. CSR instructions are decoded as illegal — no Zicsr in this design.
3. Misaligned load/store gives silently-wrong byte lanes rather than trapping.
4. SDRAM controller's geometry/timing parameters are explicitly NOT datasheet-confirmed.
5. SD/SPI controller does not check CRC on CMD17 read data.
6. KEY[0:3]/SW[0:17] I/O standard is "Depending on JP7" — `.qsf` generation (M6) is BLOCKED on a human-confirmed jumper reading.
7. Framebuffer's VGA-side read port is combinational, not registered — flagged for M6 synthesis review.
8. Framebuffer pixel format (32-bit RGB) is an M4 testing placeholder, explicitly not locked in — M5 must inspect DoomGeneric's real format before treating it as final.
