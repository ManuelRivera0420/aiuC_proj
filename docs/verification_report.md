# Verification Report

## M1 — RV32IM CPU core

**Status: PASS** (2026-11-07). Evidence: `research/evidence_index.md`, raw log reproducible via Animas MCP (`set_sim_top(sim/tb/cpu_core_tb.sv)` → `run_simulation`).

### Scope decision (recorded up front, not discovered after the fact)

Full verification uses a **curated, hand-written directed-test program** (`sim/tb/asm/cpu_directed_test.S`, 66 instructions) assembled with the real `riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32` toolchain, rather than the complete upstream `riscv-tests` regression suite (~56 tests across `rv32ui`/`rv32um`). This is a deliberate scope reduction given the overall project's size — running each upstream test individually through the MCP tool loop would cost dozens of additional round trips for marginal additional confidence once every instruction class is covered directedly, as it is here. If deeper regression coverage is wanted later, the toolchain and infrastructure already in place (`scripts/riscv_env.sh`, `sim/models/sync_mem.sv`) support dropping in upstream `riscv-tests` ELFs directly.

### Coverage

Every instruction class the decoder implements is exercised and independently checked (expected values computed by hand from the assembly source, documented in `sim/tb/asm/cpu_directed_test.S`'s header comment and reproduced in `sim/tb/cpu_core_tb.sv`):

- ALU reg-reg and reg-imm: ADD, SUB, SLLI, ANDI, ORI, XORI, SLT, SLTU (incl. a signed-vs-unsigned pair using a negative operand, which specifically catches a signed/unsigned decode mixup)
- LUI, AUIPC (verified via a self-relative AUIPC+JALR jump that depends on AUIPC's address computation being exactly correct, not just "some jump happened")
- Branches: BEQ taken, BEQ not-taken (fallthrough executed), BNE taken, BLT taken (signed), BGEU taken (unsigned) — the BLT/BGEU pair specifically catches a signed/unsigned mixup in the branch comparator mux
- JAL/JALR call-return round trip (pre-call / in-function / post-return markers, which only all land correctly if the link address and return jump are both exactly right)
- Loads/stores: LW/SW word, LBU/LB/SB byte at two different byte lanes (0 and 1, exercising the byte-select shift logic), sign vs zero extension
- M extension: MUL, DIV, REM (one directed case each; see "Known gaps" below)

### Bugs found and fixed during this milestone (both via the Animas run→diagnose→patch→rerun loop)

1. **RTL bug, `rtl/cpu/cpu_core.sv`**: `rf_we` (register-file write enable) was registered through the FSM's `always_ff`, lagging the `S_WRITEBACK`→`S_FETCH` state transition by one cycle. Since `pc` advances to `next_pc` on that *same* transition, any writeback value that depends on `pc` (AUIPC's `pc_plus_imm`, JAL/JALR's `pc_plus_4`) was being sampled by the register file one cycle late — using the *next* instruction's already-advanced `pc` instead of the retiring instruction's `pc`. Symptom: JAL's return address was off by +4, causing `jalr` to return 4 bytes past the correct point. Fix: made `rf_we` purely combinational (`assign rf_we = (state == S_WRITEBACK) && we_rd_comb;`) so the enable and the pc-dependent data are evaluated from the same pre-edge state. Confirmed fixed: x28/x29 (jal/jalr round-trip markers) went from wrong/garbage to exactly correct after this one change, with no other lines changed.
2. **Test-program bug, `sim/tb/asm/cpu_directed_test.S`**: the AUIPC+JALR self-jump used offset 12, but needed offset 20 — `li` is a pseudo-op that expands to 2 real instructions (LUI+ADDI), and the offset has to clear the ADDI/JALR pair (8 bytes) plus the 2-instruction `li x30,0xBADBAD` block being skipped (8 bytes) from AUIPC's own address, not just one instruction. This was a bug in the test, not the CPU — confirmed by checking the actual instruction addresses in the `objdump` disassembly rather than assuming.
3. Elaboration issue (not a logic bug, but a real LRM violation Zenith correctly rejected): `sim/models/sync_mem.sv` mixed a whole-array `initial`-block write ($readmemh) with sub-word bit-sliced `always_ff` writes to the same array, which LRM 9.2.2.4 forbids as "overlapping longest static prefixes." Fixed by making the `always_ff` write always a whole 32-bit word (read-modify-write constructed combinationally, then one non-blocking assignment to `mem[waddr]`), matching the initializer's granularity.

### Known gaps (honest, not hidden)

- Only one directed test per M-extension opcode (MUL, DIV, REM); MULH/MULHSU/MULHU/DIVU/REMU are implemented in `rtl/cpu/mul_div.sv` (including the RISC-V spec's divide-by-zero and signed-overflow special cases, which fall out correctly from the magnitude-based algorithm — reasoned through by hand, not yet independently exercised by a directed test).
- BGE and BLTU (as opposed to their siblings BLT/BGEU, which ARE tested) are not independently exercised, though they share the exact same comparator/mux logic already validated.
- No LH/LHU (halfword load) directed test yet, though SH is implementable via the same `store_wstrb`/`store_wdata` mux already validated for SB.
- No illegal-instruction or CSR-rejection directed test yet (the decoder does flag CSR instructions as illegal per the M1 scope decision — see `rtl/cpu/decoder.sv` — but this path isn't exercised by `cpu_directed_test.S`).
- Misaligned load/store behavior is unspecified/untested (the mission allows documenting a simplification here rather than inventing a policy; current RTL simply uses whatever address bits are given, which for a misaligned word access would silently give wrong byte-lane results rather than trapping — flagged as a follow-up, not a blocker for M2).

These gaps are candidates for the upstream `riscv-tests` regression mentioned above, or additional directed cases, in a later hardening pass -- not required to proceed to M2 (bare-metal firmware boot), which exercises the CPU against real compiled C rather than hand-written assembly and will surface any of these gaps that matter in practice.

## M2 — Bare-metal firmware boot (mission's S0/S1 software gates)

**Status: PASS** (2026-11-07). Evidence: `research/results/m2_firmware_tb_final.log`, `research/evidence_index.md`.

- **S0** (cross-compiler produces an inspected RV32IM/ILP32 ELF): confirmed via `readelf -A firmware/build/m2_bringup.elf` → `Tag_RISCV_arch: "rv32i2p1_m2p0_zmmul1p0"`, and an `objdump -d` grep for F/D/A/V/compressed/CSR/AMO mnemonics found none.
- **S1** (`_start` + tiny C firmware executes on the Animas RTL processor with correct stack, `.data`, `.bss`, MMIO): `firmware/tests/m2_bringup_main.c` + `firmware/startup/crt0.S`, linked with `firmware/linker/de2_115.ld`, run on `cpu_core.sv` in Animas. 6/6 checks PASS: a nonzero initialized global loads correctly from `.data`, an uninitialized global reads back exactly zero after `crt0`'s explicit `.bss`-clear loop, a stack-resident array+loop computes the right sum, a real function call/return round-trips correctly through the stack, and `.bss` is confirmed ordinary writable RAM after startup.

### Bugs found via static analysis, before spending any simulation cycles

Both of these were caught by reading `readelf -S` / `objdump -d` output on the *first* compiled build, before registering anything with Animas — exactly the "static ISA/ABI gate" the mission calls for:

1. **Linker script gap**: `firmware/linker/de2_115.ld` originally matched only `.data`/`.bss`, but the RV32 ABI's default small-data optimization places 4-byte globals in `.sdata`/`.sbss` instead. The uninitialized test global landed in `.sbss`, entirely outside the `__bss_start`/`__bss_end` range `crt0.S` uses to zero `.bss` — meaning the zero-clear loop ran 0 iterations and would have left that word at whatever the simulator's default unknown-memory value is. Fixed by adding `.sdata`/`.sbss`/`.srodata` to the respective output sections — a correctness fix needed for any future C code, not a one-off test workaround.
2. **Test bug**: the "proves `.data` loads correctly" global was never mutated after its initializer, so `-O1` constant-folded every read of it into an immediate, silently defeating the test (it would have passed even with a broken `.data` loader, since no memory access to it remained in the compiled code). Fixed by marking it `volatile`.

## M3 — Board peripheral behavioral models (in progress)

### KEY/SW GPIO + timer + address-decoded bus + ROM/RAM split: PASS

16/16 checks across two testbenches (`key_sw_gpio_tb.sv`: 10/10; `soc_bus_tb.sv`: 6/6). One real bug found: `key_sw_gpio_tb.sv`'s `do_read` task sampled `mem_rdata` one full clock cycle after the DUT's clear-on-read side effect had already committed, because it used a "wait a cycle, then sample" protocol instead of matching `cpu_core.sv`'s own convention of sampling the pre-edge combinational value at the exact edge where `mem_ready` is first seen. This is a general lesson for any future bus-master code (firmware drivers included): a clear-on-read MMIO register's value must be captured in the same cycle the read request is issued, not the cycle after. Documented in `sim/tb/key_sw_gpio_tb.sv`'s comments.

### VGA timing generator: PASS

29/29 checks in `vga_tb.sv`. Uses the standard VESA 640x480@60Hz timing (640/16/96/48 horizontal = 800 total; 480/10/2/33 vertical = 525 total) rather than a literal transcription of the manual's rounded Table 4-14/4-15 microsecond figures — cross-checked and consistent (the manual's vertical figures sum to exactly 525, confirming the same mode). The pixel clock is a simple divide-by-2 from the 50MHz input (giving 25MHz, not the standard's 25.175MHz) — acceptable for simulation and initial bring-up, but the real Quartus build should use a PLL megafunction for a cleaner clock; this RTL cannot instantiate real Cyclone IV PLL hardware itself, and the module's header comment says so explicitly rather than silently pretending the divide-by-2 is production-ready. Scan-out addressing (2x nearest-neighbor upscale of DOOM's 320x200 frame, centered in a 40-row top/bottom black border) is verified directly, including the vertical-duplication behavior and the border-row blanking.

### SDRAM controller: PASS

14/14 checks in `sdram_ctrl_tb.sv` against the behavioral `sdram_model.sv`: correct init sequence (PRECHARGE-ALL, 2x AUTO-REFRESH, LOAD-MODE-REGISTER, all before the first ACTIVATE), word write/read-back, byte-masked writes (verified the untouched bytes are preserved, not just that the touched byte is right), address non-aliasing between two different {bank,row,col} locations, and periodic refresh actually firing during normal operation (not just during init). One real bug found: the model's read-data pipeline was `CAS_LATENCY+1` deep with an extra registered output stage, adding 2 cycles of latency beyond what the controller actually waits for — every read returned high-Z. Diagnosed by a careful cycle-by-cycle trace of exactly when the command is decoded vs. when the controller samples the bus, then fixed by making the pipeline exactly `CAS_LATENCY` deep with a combinational (not registered) output stage. The controller's assumed SDRAM geometry (4 banks/13-bit row/10-bit column) and timing parameters are explicitly flagged as NOT datasheet-confirmed — see `docs/known_limitations.md`.

### SD/SPI controller: PASS (hardest debugging session of this project so far)

9/9 checks in `sd_spi_tb.sv` against the behavioral `sdhc_spi_model.sv`: the full SDHC SPI init handshake (CMD0, CMD8 with check-pattern/voltage echo, CMD55+ACMD41(HCS) retried exactly twice on purpose, CMD58 with CCS inspection) followed by a CMD17 single-block read verified byte-for-byte against `scripts/prepare_sd_image.py`'s fixture image. This took four real RTL bugs plus one model bug to converge, found exclusively through Animas's waveform-inspection tools (`query_signals_window`, `find_signal_transitions`) rather than guesswork — each fix was verified against an actual decoded bit sequence before moving to the next:

1. **Command encoding bug**: `build_cmd`'s `6'b01_0000 | idx` computed a 6-bit OR, not the intended 8-bit `(0x40 | idx)` command byte — every SD command was wrong from the start. Fixed with proper concatenation `{2'b01, idx}`.
2. **SPI mode violation**: `shift_tx` (driving `sd_mosi`) was updated during the RISING clock-phase branch instead of the FALLING one. SPI mode 0 requires data to change on the falling edge and be sampled on the rising edge; updating it on the rising edge made every bit after the first arrive one half-cycle early, corrupting the byte the slave received.
3. **Same-edge race**: `xfer_busy` was cleared on the exact same rising edge where the SPI slave samples the final bit of a byte. Because `sd_mosi` is a combinational mux on `xfer_busy`, the slave and the busy-clear raced at the identical simulation instant — the slave consistently saw the post-clear "idle" value instead of the real last bit, forcing every byte's LSB to 1. Fixed by deferring the busy-clear to the *next* falling edge, decoupling it from the sampling instant.
4. **Read-after-write hazard**: `ST_CMD8_WAIT_R7` checked `resp_bytes[4] == 8'hAA` in the same cycle `resp_bytes[4] <= xfer_rx_byte` was issued — the non-blocking write isn't visible until the next cycle, so the check always read the stale (pre-write) value. This is the exact same bug class as M1's `rf_we` timing bug. Fixed by checking `xfer_rx_byte` directly.
5. **Model-side latency mismatch**: the first version of `sdhc_spi_model.sv` detected `sd_clk` edges by registering it into the fast system-clock domain and comparing against the previous sample — adding a one-system-cycle detection delay. Since the controller updates its output bit at the rising edge with zero extra delay, that one-cycle lag meant the model sampled MOSI one bit-position late. Rewrote the model to be clocked directly off `sd_clk`'s own edges, eliminating the cross-domain mismatch entirely (and this is also just the architecturally correct way to model an SPI slave).

The debugging method that actually worked: rather than re-deriving timing by hand (which produced a wrong theory at least once), pull the actual waveform with `query_signals_window`/`find_signal_transitions` on the raw SPI lines plus the relevant internal registers, and read off exactly what was sent vs. received bit-by-bit.

## M4 — SoC integration: **PASS** (2026-11-08, after an Animas daemon restart)

The Animas daemon got stuck (`ERROR: ZenithDaemonClient: job already in progress`) partway through M4 and did not recover across 9+ retries in the prior session; the user restarted the Animas application, which cleared it. Connection verification after the restart: `get_project_info` worked immediately (confirming the backend/project layer was healthy), while a bare `list_projects` call returned `Invalid request parameters` — a narrower, apparently unrelated issue in that specific zero-argument endpoint, not a sign the restart failed (every call that matters, including every `run_simulation`, worked fine afterward). The first `run_simulation` call post-restart surfaced `"Zenith server connection lost — attempting restart… Please run the simulation again"`; the immediate retry succeeded (`alu_regfile_tb.sv`, 17/17 PASS in 0.98s), confirming the daemon was genuinely healthy again, not just silent about still being stuck.

**`sd_spi_tb.sv` re-run** (the byte-order fix made before the daemon got stuck had never actually been simulated): 9/9 PASS with the corrected little-endian values `0x18110a03`/`0x342d261f`. The fix is now actually verified, not just reasoned through.

**`m4_e2e_tb.sv`**: 7/7 PASS, 0 errors. Full pipeline: the real SD boot image (`sim/models/m4_boot.img`, built by `prepare_sd_image.py` from the compiled `firmware/build/m4_framebuffer.elf`) → `sdhc_spi_model.sv` → the real bootloader (`firmware/bootloader/bootloader_main.c`, compiled RV32IM C, running from boot ROM on `cpu_core.sv`) → `soc_bus.sv` → `sd_spi.sv` (full CMD0..CMD58 init handshake *and* CMD17 sector reads, at the realistic default clock dividers — not `sd_spi_tb.sv`'s sped-up test-only ones) → `sdram_ctrl.sv`/`sdram_model.sv` → a jump into the loaded program at its SDRAM entry point → `framebuffer.sv` writes (two successive pixel "frames") → `vga.sv` scan-out, all through real RTL and real compiled firmware. `pc=0x10000030` at halt (inside the SDRAM region) is the detail that actually proves the bootloader's jump worked, not just that it ran — see `research/results/m4_e2e_tb_final.log`.

One operational wrinkle, not a correctness bug: the first `run_simulation` call for this test returned (`status: "ok"`) with the log visibly mid-run (`finished: false`, no `$finish` line) rather than waiting for completion — the realistic SD/SPI clock dividers make this test take far more simulated cycles than anything run before it, and the tool's own polling window elapsed before the Animas UI's background simulation actually finished. Polling `get_last_sim_result`/`read_simulation_log` again (without triggering a new run) a short while later showed it had completed normally. Worth remembering: a `run_simulation` return isn't always the final word for a long test in `ui_remote_control` mode — check `finished` before concluding anything from an immediate response.

One real design issue was caught by review rather than simulation, before the daemon got stuck: `sd_spi.sv`'s `ST_READ_DATA` packed received sector bytes MSB-first into `block_buf` (byte 0 → bits `[31:24]`), which was internally self-consistent and had already passed `sd_spi_tb.sv`'s own checks (which asserted exactly that packing), but is backwards relative to standard little-endian RV32 memory layout — a `sw` of such a word into SDRAM would byte-reverse every 4 bytes of any program or WAD copied from the card. Fixed to byte-0-into-bits-`[7:0]`; now confirmed correct by both `sd_spi_tb.sv` and the full `m4_e2e_tb.sv` pipeline actually loading and running a program through it.

## M5 — DoomGeneric compiles and links clean for bare-metal RV32IM: PASS (S0-S2 gates)

The full, real DoomGeneric engine (86 compilation units: the complete game — rendering, playsim, menus, automap, HUD, status bar, wipe/finale effects, demo/savegame code — minus only the other-platform display backends, sound/music backends, and the host filesystem WAD reader, all of which are legitimately out of scope) **compiles and links successfully** for `-march=rv32im -mabi=ilp32`, producing a 792,874-byte ELF (`.text`=504,420 `.data`=61,810 `.bss`=244,644 bytes). This is the mission's S2 gate ("DoomGeneric compiles/links without host platform assumptions and without unsupported instructions").

**Static ISA/ABI gate (the same check used for every firmware build since M2), run on this binary specifically**: `readelf -A` reports `Tag_RISCV_arch: "rv32i2p1_m2p0_zmmul1p0"` — exactly RV32IM, nothing more. A full disassembly grep for every F/D/A/V/compressed/CSR/AMO/LR/SC mnemonic across the entire 792KB binary returns **zero matches**. The ELF header's architecture flags field is `0x0` (no RVC bit). This means every single instruction in the entire real DOOM engine, as compiled, is something `cpu_core.sv` already implements and has verified (M1).

### How this was achieved (the key unlocks)

1. **Newlib is bundled with the toolchain, built for rv32im/ilp32** (confirmed by direct link attempt, not assumed — see `docs/known_limitations.md`). This meant `malloc`/`free`, the full string function family, `sprintf`, `qsort`, etc. did not need to be hand-written at all. Only the classic ~14-function Newlib syscall stub layer (`firmware/platform/syscalls.c`: `_sbrk`, `_write`, `_read`, `_close`, `_lseek`, `_fstat`, `_isatty`, `_kill`, `_getpid`, `_exit`, `_open`, `_unlink`, `_link`, `mkdir`) was needed, discovered by attempting the link and reading the exact undefined-symbol list rather than guessing — `_sbrk` (heap growth, backing `malloc`) is the only one that matters for correctness; the rest fail cleanly (`ENOENT`/`ENOSYS`) rather than faking success, since this target genuinely has no filesystem, terminal, or process model.
2. **The WAD backend is a clean, swappable interface** (`wad_file_class_t` in `software/upstream/doomgeneric/w_file.h`) — `software/doom_port/w_file_de2115.c` implements it against a WAD preloaded into SDRAM (exporting its vtable under the exact symbol name `w_file.c`'s generic dispatcher expects, `stdc_wad_file`), so the real `w_file_stdc.c` (host `fopen`/`fread`) is simply excluded from the build. Zero patches to upstream needed for this.
3. **The palette-update path needed no patch either**, once actually checked: `i_video.c`'s `CMAP256` build path declares `colors[256]` and `palette_changed` as plain (non-`static`) globals specifically so a platform backend can read them directly — exactly what `doomgeneric_allegro.c` already does upstream. `software/doom_port/doomgeneric_de2115.c`'s `DG_DrawFrame` reads these directly and pushes changed palettes to the hardware palette RAM (`rtl/peripherals/framebuffer.sv`) — no `software/patches/` needed, contrary to the tentative plan recorded when the pixel-format finding was first made.
4. **`dummy.c` and `statdump.c`, initially excluded on the assumption they were platform-specific/debug-only**, turned out to supply symbols (`net_client_connected`, `drone`, `StatDump`, `StatCopy`) that core single-player code references unconditionally. Found by reading the actual linker errors rather than guessing further — re-including them resolved it with no stubbing needed.
5. Two small bugs in `software/doom_port/doomgeneric_de2115.c` itself: a reference to a nonexistent `KEY_WEAPONUP` constant (vanilla DOOM has no dedicated "next weapon" key — mapped to `'2'` instead, a documented simplification) and `mkdir`'s stub using `int mode` instead of the declared `mode_t`.

### What was NOT attempted this session, and why (honest scope limit, not a hidden gap)

Actually **executing** this binary on `cpu_core` via Animas (the mission's S3/S4 software gates and the eventual DOOM-boots-and-renders-frames claim) was not attempted. Two real, measured constraints, not assumptions:

- The correct way to get this binary onto SDRAM is the same SD-image → bootloader → CMD17-sector-copy pipeline already verified in M4 — but that pipeline's realistic clock timing (confirmed in M4: ~9,040,016 ns simulated just for a ~200-byte test program's init handshake + 2 sectors) scales roughly linearly with sector count. This binary's `.text`+`.data` alone is ~566KB (≈1,106 sectors); a back-of-envelope estimate using M4's measured per-sector cost puts the data-transfer portion alone in the hundreds-of-millions-of-ns range of simulated time — a wall-clock risk this session's remaining time could not responsibly absorb, especially after already losing real time once to an Animas daemon lock this same session.
- Bypassing the SD path with a direct SDRAM preload (the obvious faster alternative, analogous to M1-M3's standalone-module testbenches) would need new test infrastructure — `sdram_model.sv` is a command-protocol-driven behavioral model with no `$readmemh`-style bulk-preload capability, so exercising it would require either adding one or writing a testbench that replicates `sdram_ctrl.sv`'s bank/row/column address decomposition to pre-populate the model's internal store directly. Not attempted rather than attempted hastily and left half-verified.

This is recorded as the precise, measured blocker it is — see `PROJECT_STATE.md` for the concrete next step (build a direct-SDRAM-preload fast-path testbench) rather than treating "it compiles" as equivalent to "it runs," which the mission explicitly warns against.

## M5 — framebuffer format revision for DoomGeneric's real pixel format: PASS

Per the mission's explicit warning not to assume DoomGeneric's pixel format, the pinned source was read directly (`software/upstream/doomgeneric/i_video.c`), confirming the true native render is 320×200 8-bit palette-indexed, not the 32-bit RGB M4 used as a placeholder — full citations in `software/source-lock.json`. `rtl/peripherals/framebuffer.sv` was rewritten accordingly: 64,000-byte indexed pixel storage plus an integrated 256-entry palette RAM that does the index→RGB lookup internally, so `vga.sv` (already independently verified, 29/29) needed **zero changes**. Re-ran `m4_e2e_tb.sv` end-to-end with updated firmware (`firmware/tests/m4_framebuffer_main.c` now sets palette entries and writes pixel indices via byte stores instead of raw RGB words): 7/7 PASS, including a check that `vga.sv`'s unmodified scan-out path correctly resolves a written palette index back to the right RGB value — confirming the new format integrates correctly end-to-end, not just in module isolation. See `research/results/m5_framebuffer_reformat_e2e.log`.

### Scope decision for M2 (recorded, not discovered later)

This milestone's linker script places `.text`/`.rodata`/`.data`/`.bss` all in one flat 64 KiB RAM region with no ROM/RAM split and no `.data` load-address-vs-virtual-address copy — `crt0.S` only zero-clears `.bss`. This is correct for a single-memory standalone-core test but is **not** the final SoC memory map: M3/M4 introduce a real split (boot ROM or SD-loaded image vs. SDRAM-backed RAM), at which point `.data`'s initial values will need an explicit load-time copy from their LMA to their VMA, not just a `.bss` clear. Tracked in `PROJECT_STATE.md`.

## M5 — S3 direct-execution attempt: IN PROGRESS (started 2026-11-08, after M6)

An actual attempt to execute the real, compiled DoomGeneric binary on `cpu_core` via Animas, bypassing the slow SD/bootloader path per the concrete next step `PROJECT_STATE.md` recorded at the end of M5's static-compile pass. `sim/tb/m5_doom_exec_tb.sv` instantiates the real `cpu_core`+`soc_bus`+`sdram_model` (no SD/SPI involved), with `soc_bus.sv` newly given a `BOOT_ROM_FILE` parameter (default unchanged, so this doesn't disturb M3/M4's shared `sim/models/soc_rom.hex`) pointing at a 2-instruction jump stub (`sim/models/m5_exec/jump_stub.S`) that goes straight to DOOM's real entry point (`0x10000000`), and `sdram_model.sv` given new test-only `PRELOAD1_FILE`/`PRELOAD2_FILE` parameters that bulk-populate its backing store at time 0.

**A real bug found and fixed while building this**: the first version put the preload's `mem_store[...] = ...` writes in a separate `initial` block from the model's existing `always_ff`-based writer of the same array, which Zenith's elaborator correctly rejected (`ZEN-6033`, LRM 9.2.2.4 — a variable written by an `always_ff` procedure and by another process of the same instance is forbidden) — the same bug class as M1's `sync_mem.sv` fix, via a different code path. Fixed by moving the preload copy loop inside the `always_ff`'s own reset branch (same process as the existing writer), keeping only the `$readmemh` calls themselves in a separate `initial` block (which targets different, non-conflicting signals).

**A real scale limitation found and honestly descoped**: the first full attempt also preloaded the actual, hash-verified `freedoom1.wad` (confirmed against `software/source-lock.json`'s pinned SHA-256 before use) at `WAD_SDRAM_BASE`, per the mission's explicit allowance for SDRAM-preloaded IWADs. Populating `sdram_model.sv`'s associative array with the WAD's ~7.2 million words made the run markedly slower than anything else in this project, and the Zenith subprocess running it ended up in a zombie state (confirmed via `ps`/`/proc`) with no log output and no result after several minutes, on this specific Animas/Zenith installation (v1.0.2 / EDA-Server v1.0.1-beta) and this specific shared, multi-tenant host. Not conclusively root-caused as a Zenith bug vs. host resource contention (`docs/known_limitations.md`) — rather than spend more of this project's remaining time diagnosing it, the WAD preload was disabled (`PRELOAD2_WORDS` left at its default 0) for this attempt, since the CPU-execution question this test exists to answer doesn't require a valid WAD to produce a meaningful result (DOOM's own init code runs for a real stretch before it even attempts to open one).

### Gates tracked separately — only mark PASS when its own acceptance criterion is actually observed

Per explicit instruction: these six are not interchangeable, and an earlier one passing is not evidence for a later one.

| Gate | Criterion | Status |
|---|---|---|
| DOOM machine code executing on RTL | Any real (non-CRT) DOOM source code observably executing correctly on `cpu_core` | **PASS** — see trace below |
| DOOM engine initialization | Engine init functions (not just one isolated call) running through to completion | IN PROGRESS |
| WAD successfully accessible | A read of `WAD_SDRAM_BASE` returns real WAD content and is used | NOT ATTEMPTED (this run has no WAD preloaded — see above) |
| First genuine framebuffer produced | `fb_write_count` reaches a full 64,000-pixel frame | NOT YET |
| Multiple frames rendered | Repeated full-frame write cycles observed | NOT YET |
| User input affecting gameplay | Not meaningfully testable without a rendered frame first | NOT YET |

### Live execution trace (direct evidence: `[progress]` lines from the testbench's own `$display`, cross-referenced against `riscv64-unknown-elf-objdump`/`nm` on `firmware/build/doom/doom.elf`)

| Cycle | PC | Location | What this proves |
|---|---|---|---|
| 0 | `0x00000000` | reset vector | Boot ROM jump stub about to fire |
| 2,000,000 | `0x10000020` | `clear_bss_loop` (`firmware/startup/crt0.S`) | Correct `.bss`-clear in progress (244,644 bytes = 61,161 words to zero; not a hang — this address is one specific instruction inside a loop body that legitimately runs 61,161 times) |
| 4,000,000 | `0x1000f974` | `SearchCollection` (`software/upstream/doomgeneric/m_config.c:1563`) | **First real DOOM engine code** — `SearchCollection` is called from `M_LoadDefaults`, part of `D_DoomMain()`'s config-loading step, not CRT/bootstrap |
| 6,000,000 | `0x10045968` | `strcmp` (Newlib) | Still inside the same config-matching call path (`SearchCollection` compares default-entry names via `strcmp`) — continuous, sensible progress, not erratic jumping |

Full raw evidence, throughput measurement methodology, and the WAD-access static analysis: `research/results/m5_s3_attempt1_baseline.log`.

### Throughput measurement (direct, not estimated)

Measured via the host's own `ps -o etimes` against the live Zenith subprocess (PID confirmed via direct `/proc` inspection), cross-referenced with the testbench's own cycle counter in the log — **not** inferred from the MCP tool's return values alone:

**~4,900-5,300 simulated cycles per wall-clock second** in Animas's `ui_remote_control` mode (the mode used throughout, since the Animas UI was open and reachable for this entire run). At this rate, the testbench's own `WATCHDOG_CYCLES=60,000,000` ceiling would take roughly **3.4 hours** of wall-clock time — classified as a genuine, measured throughput limitation, not a stuck simulation (the CPU's PC is unambiguously, continuously advancing through real, identifiable, sensible code).

**Root cause, not just the symptom**: every single instruction fetch AND every data access in this design goes through `sdram_ctrl.sv`'s close-page policy (`docs/memory_map.md`/that file's own header) — ACTIVATE + READ-or-WRITE + PRECHARGE for every access, no row-buffer reuse, because the program itself (not just its data) lives entirely in SDRAM in this configuration. A 4-instruction loop body like `clear_bss_loop` costs roughly 32-40 cycles per iteration once both the multicycle CPU's own per-instruction state machine (`cpu_core.sv`'s `S_FETCH`/`S_WAIT_IFETCH`/`S_EXEC`/`S_MEM_REQ`/`S_WAIT_MEM`/`S_WRITEBACK`) and the close-page SDRAM cost of each of its instruction fetches and its one data store are counted — consistent with the measured ~2,000,000-cycle cost of the 61,161-iteration `.bss`-clear loop (≈32.7 cycles/iteration).

### Acceleration: `waveform_mode="off"` had no measurable effect; `headless` mode is real but modest (~2x, not the hoped-for order of magnitude)

Per Zenith's own documented options (`get_zenith_help`), the only simulation-only (non-RTL) throughput lever exposed through this project's tooling appeared to be waveform capture — `set_sim_options(waveform_mode="off")` was applied (confirmed via the tool's own `changed_fields` response). A follow-up `run_simulation` call unexpectedly returned `"mode": "headless"` instead of `"ui_remote_control"`, timing out after 120s with no result. Investigating why led to the real finding: **the Animas UI application itself had been closed** (confirmed via `ps`: `animas-backend`, PID 974517, stayed alive throughout, but `run_simulation`'s own responses started explicitly stating `"Animas was not running — simulation ran as headless subprocess"`). `run_simulation` falls back to headless automatically whenever it can't reach a live UI to click "Run" in — this is normal, documented behavior, not a bug, and explains both that timeout and every headless result that follows.

With the UI confirmed closed, two clean headless runs became possible to measure directly:

1. **`m4_e2e_tb.sv` regression** (see the M6 bootloader-follow-up section below): 9,040,016ns of simulated time (904,002 cycles at the 10ns/cycle timescale) completed in **87.6s wall-clock**, including elaboration (~11s). Net simulation rate: **≈(904,002)/(87.6-11) ≈ 11,800 cycles/second.**
2. A fresh headless attempt at `sim/tb/m5_doom_exec_tb.sv` (started after the regression run, running independently alongside the still-live `ui_remote_control` baseline run from the previous section — confirmed not to disturb it, see below) — in progress as of this entry; see the next section for its outcome.

**Both headless commands still included a `--zwdb <path>` argument despite `waveform_mode="off"` being set** — confirmed by reading the exact command line each `run_simulation` call returned. This setting is **not honored by Animas's headless fallback path** on this version; the ≈2.3x speedup measured above (≈11,800 vs. the previous section's ≈5,000 cycles/sec) is attributable entirely to **running headless instead of through the UI**, not to disabling waveforms, which — per this evidence — never actually happened. This corrects the earlier, more tentative note in this section; stated here as the honest, re-derived conclusion rather than silently edited away.

**A genuine finding, stated plainly**: this project's available Animas/Zenith tooling offers no demonstrated order-of-magnitude acceleration for this kind of bulk sequential-execution test — only the ~2x headless-vs-UI difference, which itself was discovered opportunistically (the user closed the UI) rather than through a setting this project controls. The dominant cost remains architectural, not tooling-related: every instruction fetch and data access in this design pays the full close-page SDRAM activate/access/precharge sequence (see the root-cause paragraph above), and no lever available through Animas/Zenith changes that. A genuinely faster re-run of this specific test would require either a different SDRAM model/controller configuration (out of scope — the mission's own policy choice) or accepting the ~85-minute-at-headless-speed order of magnitude for a full `WATCHDOG_CYCLES=60,000,000` run, which is what the next section's run was left to attempt.

### Running both a slow and a fast attempt concurrently — confirmed safe, not recommended as routine practice

Rather than kill the still-progressing `ui_remote_control` baseline run (1,700+ seconds of valid, uncontended evidence already in it — see the trace table above) to free up the project's simulation slot for a faster headless attempt, both were run at once: the original `ui_remote_control` Zenith daemon process and a brand-new headless `zenith` subprocess, confirmed via `ps` to be two genuinely separate OS processes. Checked directly (not assumed) that the baseline run's process continued climbing in `%cpu`/`etimes` across every check spanning this entire investigation, with no interruption, crash, or log regression — concurrent runs against the same Animas project did not corrupt or disrupt each other in this instance. This is **not** recommended as routine practice (shared host CPU contention is real and was already observed once this project, in the WAD-preload zombie incident above) — it was a deliberate, evidence-checked exception made specifically to avoid discarding sunk, irreplaceable progress while still pursuing a faster path, not a new default workflow.

### Concluded result: HALTED cleanly via `_exit()`, no crash, no hang, consistent with the expected no-WAD path

The headless run reached a genuine terminal state. Raw evidence: `research/results/m5_s3_attempt2_headless_final.log`.

```
[progress] cycle=10000000 pc=0x1000f954 fb_writes=0
[RESULT] HALTED (ECALL/_exit reached) at pc=0x1003ab58, cycle=11620521, fb_writes_seen=0
[sim] $finish at time 116205215 (exit code 0)
```

**PC at halt (`0x1003ab58`) is the exact `ecall` instruction inside `_exit()`** (`firmware/platform/syscalls.c`), confirmed by disassembly:
```
1003ab58 <_exit>:
1003ab58:  00000073   ecall
1003ab5c:  0000006f   j  1003ab5c <_exit+0x4>
```
`cpu_core.sv` halted on exactly that instruction, exactly as designed (`docs/clock_reset_cdc.md`/`docs/module_interfaces.md`'s description of the ECALL trap surface) — this is a clean, architecturally-correct program-initiated exit, not a crash, not an illegal-instruction trap, not a watchdog timeout.

**Why `_exit()` was called — traced, not guessed**: `_exit()` is only ever reached through `exit()` (`newlib`), and a full disassembly cross-reference of the entire 792,874-byte binary shows **exactly two call sites of `exit()` in the whole program**:
- `0x10003528`, inside `D_Endoom` — DOOM's *normal, end-of-game* shutdown path (shows the ENDOOM text screen before quitting)
- `0x1000eabc`, inside `I_Error` (`software/upstream/doomgeneric/i_system.c:359`) — the *fatal-error* handler

Given the last confirmed `[progress]` checkpoint (cycle 10,000,000, PC `0x1000f954`, inside `M_LoadDefaults`'s config-loading area — see the trace table above) is unambiguously *early-startup* code, not anywhere near a completed game session, `D_Endoom`'s normal-quit path is not a plausible explanation for an exit roughly 1.6M cycles later. By elimination — and consistent with this run's own WAD-access static analysis earlier in this section (no WAD was preloaded; any read of `WAD_SDRAM_BASE` returns `X`, which cleanly fails any "IWAD"/"PWAD" magic check) — **`I_Error()` is the overwhelmingly likely call site**, almost certainly triggered by the engine failing to find a valid IWAD. This is stated as a strong, traced inference (only two possible call sites exist in the entire binary, and only one is plausible given the timing), not a definitive register/stack-level proof — a full backtrace would need the waveform database, which for this run is enormous (see below) and wasn't inspected for this specific question.

### Gates — final status for this attempt

| Gate | Status |
|---|---|
| DOOM machine code executing on RTL | **PASS** — 11,620,521 cycles of real, continuously-progressing, correctly-decoded DOOM/Newlib code, terminating in an architecturally clean program-initiated halt, zero illegal instructions |
| DOOM engine initialization | **ATTEMPTED, DID NOT COMPLETE** — reached and ran real `D_DoomMain`-path config-loading code (`M_LoadDefaults`/`SearchCollection`) for millions of cycles, but initialization aborted (almost certainly via `I_Error`) before completing — consistent with, not a failure of, this run's deliberately-no-WAD configuration |
| WAD successfully accessible | **NOT ACHIEVED this run** (by design — `PRELOAD2` was disabled; see above) |
| First genuine framebuffer produced | **NOT REACHED** — `fb_writes_seen=0` |
| Multiple frames rendered | **NOT REACHED** |
| User input affecting gameplay | **NOT REACHED** (not testable without a rendered frame) |

**What this result means for next steps**: this is strong, positive, honestly-earned evidence that the CPU/bus/SDRAM-controller RTL correctly executes substantial, real DOOM engine code — the thing M5's S3 gate exists to test. It also sharply narrows the remaining work: the next meaningful attempt needs a real WAD actually reachable at `WAD_SDRAM_BASE`, which circles back to the WAD-preload scale problem documented earlier in this section (the 7.2M-word associative-array preload that stalled). With headless mode now confirmed available (~2x faster) and this run's own evidence that `I_Error`'s path is reached within ~12M cycles even withOUT a WAD, a real next attempt is far more tractable than it looked before this run — worth retrying the WAD preload specifically in headless mode (not `ui_remote_control`, where it stalled) before concluding it's infeasible outright.

### A costly side effect: the un-suppressed ZWDB waveform dump

`waveform_mode="off"` was set (see above) but, as already noted, not honored in headless mode — this run captured a full ZWDB of every signal across all 11,620,521 cycles, producing a **8,569,446,043-byte (8.57 GB) waveform file** (`output/m5_doom_exec_tb.zwdb`). The simulation itself reached its terminal state well before the OS process actually exited — `ps` continued showing the process alive and alternating `R+`/`S+` (consistent with disk I/O) for an extended period after `zsim.log` already contained the final `[RESULT]`/`$finish` lines, strongly suggesting a meaningful fraction of this run's total wall-clock cost was spent writing that one file, not simulating. This is a second, now fully quantified, concrete cost of `waveform_mode="off"` not being honored in this fallback path — worth flagging to Animas/Zenith's maintainers as a real inefficiency for any long headless run, and worth deleting (`output/*.zwdb` is already outside this project's own disposable-artifact gitignore scope, since `output/` as a whole is gitignored) once its diagnostic value is no longer needed, given its size.

**A supported workaround identified, not yet tried**: `get_zenith_help`'s own documentation lists `--zwdb-start-off` ("Start with ZWDB recording off; the testbench turns it on with `$zwdb_on`/`$zwdb_window`") as a Zenith CLI flag, independent of whether a `--zwdb <path>` output argument is present. `run_simulation`'s `extra_flags` parameter accepts arbitrary additional CLI flags, so passing `extra_flags=["--zwdb-start-off"]` should make Zenith create the (still-specified) output file but record nothing into it unless this project's own testbenches call `$zwdb_on` — which none of them do — genuinely suppressing the dump regardless of whether Animas's higher-level `waveform_mode` setting is honored in a given run mode. This is a real, supported, Zenith-native mechanism (not a workaround outside the tool), orthogonal to `set_sim_options`, and distinct from (does not require) any RTL change. Not yet tested against this specific long-running test — queued as the next thing to try on the next `run_simulation` call, once the currently-running post-fix execution (see below) concludes and it's safe to trigger a new one without disrupting it.

### Other run: the original `ui_remote_control` baseline — superseded, left running, not force-stopped

The slower baseline run from the previous section (PID 1077927) remained alive and still progressing (confirmed via repeated `ps` checks throughout this entire investigation, `etimes`/`%cpu` climbing monotonically, no crash or stall) at the time the headless run above concluded. It is **superseded** by the concluded result — both runs execute the identical testbench/preload/boot-stub configuration, so the headless run's terminal outcome is what the baseline run would also eventually reach, just roughly 2x slower. No tool is available to this project to cleanly stop a running Animas-launched simulation, and force-killing an OS process outside Animas's own management was judged a disproportionate, unnecessary action for a harmlessly-running background process that was simply going to reach the same conclusion on its own — so it was left running rather than killed. If it is still running in a future session, its eventual `[RESULT]` line (once `read_simulation_log` shows a `halted` entry matching cycle count in the same ballpark as the headless run's 11,620,521) would be a second, independent confirmation of the same outcome, not new information.

### Deeper root cause found: `D_FindIWAD()` can never succeed on a filesystem-less target — fixed, re-verification IN PROGRESS

Reading `software/upstream/doomgeneric/d_iwad.c` to understand exactly *why* `I_Error` was reached (rather than stopping at "almost certainly I_Error") surfaced a more fundamental gap than this section's earlier WAD-access analysis assumed. `D_FindIWAD()` has exactly two code paths, and **both depend on a working `fopen()`/`stat()`-backed filesystem**:

- No `-iwad` argument (this project's `main_de2115.c` passes none): searches a list of directories (`BuildIWADDirList`/`SearchDirectoryForIWAD`) built from environment variables that don't exist on this target.
- With `-iwad <name>`: calls `D_FindWADByName(name)`, which starts with `M_FileExists(name)` — a real filesystem check that always fails here (`firmware/platform/syscalls.c`'s `_open` always returns `-1`).

Either way, `D_FindIWAD()` returns `NULL` before `software/doom_port/w_file_de2115.c`'s custom WAD backend is ever reached — so the earlier hypothesis (I_Error triggered by reading unpopulated/X-valued WAD *content*) was reasonable given the evidence available at the time, but incomplete: the real failure point is one layer earlier, at the IWAD *lookup* step, independent of whether the WAD's actual bytes are present in SDRAM at all.

**Fixed without patching upstream**: `software/doom_port/d_find_iwad_de2115.c` defines `__wrap_D_FindIWAD()`, and `scripts/build_doom.sh` now links with `-Wl,--wrap=D_FindIWAD` — a linker-level symbol redirection (every caller of `D_FindIWAD` is redirected to this function instead), not a source change to any upstream file. The wrap returns a fixed, non-NULL dummy name immediately (this target has exactly one WAD, always preloaded at a fixed address — there is nothing to search for), skipping the entire filesystem-search mechanism and letting `D_DoomMain()` proceed to `D_AddFile(iwadfile)` → `W_AddFile()` → `W_OpenFile()` → the existing, already-correct `w_file_de2115.c` backend. Confirmed via disassembly that the call site inside `D_DoomMain` now resolves to `__wrap_D_FindIWAD`, not the original (dead, unreferenced) `D_FindIWAD` body.

Rebuilt (`firmware/build/doom/doom.elf`: 810,906 bytes, +16 bytes over the pre-fix build, ISA gate re-confirmed clean: `rv32i2p1_m2p0_zmmul1p0`, 0 unsupported-instruction hits), re-preloaded (141,563 words, up from 141,559), and a fresh `sim/tb/m5_doom_exec_tb.sv` run is in progress as of this entry to see whether this gets DOOM past where it halted before. **Important, honestly stated caveat**: `WAD_SDRAM_BASE` is still completely unpopulated in this specific run (`PRELOAD2` still disabled, for the scale reasons documented above) — getting past `D_FindIWAD` only removes one gate; `D_AddFile`/`W_CheckCorrectIWAD`/`D_IdentifyVersion` all read real WAD *content* next, which will very likely fail differently (reading `X` where a real lump directory/magic is expected) rather than succeed outright. This is expected, and still useful: it moves the observable failure point deeper into the real engine, narrowing what's left before the actual WAD-preload-at-scale problem is the only remaining blocker.

### Monitoring the post-fix run: progress check and a stall investigation that turned up a reassuring finding

Checked repeatedly, without disrupting the run, across an extended wait: cycle checkpoints `0 → 2,000,000 → 4,000,000 → 6,000,000 → 8,000,000 → 10,000,000` all appeared (each PC matching the pre-fix run's trajectory exactly, as expected — the fix only changes behavior *after* `D_FindIWAD` is called later in `D_DoomMain`), but the next checkpoint took markedly longer to arrive than the roughly uniform spacing of the previous ones. Investigated directly rather than assumed:

- **Process liveness, with CPU-tick-level proof, not just a process-state snapshot**: `/proc/<pid>/stat`'s `utime` field advanced by ~196 jiffies (~1.96s of actual CPU time) across a 3-second wall-clock window — this is a stronger check than `ps`'s `%cpu` average or `R+`/`S+` state, and confirms the process is genuinely executing instructions, not idly blocked.
- **Host resources**: `RSS` ~297MB, host has 90GB memory available and a load average of ~6-7 on this shared machine — no sign of memory exhaustion or the process being starved to zero scheduling.
- **Whether this could be a genuine infinite loop** (not a tool/daemon hang, but DOOM's own C code looping forever given the X-valued WAD header it's about to read, since this run has no WAD preloaded at all): traced the specific downstream code (`Z_Malloc` in `z_zone.c`, which `W_AddFile`'s `Z_Malloc(length, ...)` call would reach with an X-valued `length` once `header.numlumps`/`infotableofs` are read as X). The relevant loop's exit condition (`base->tag != PU_FREE || base->size < size`) involves a comparison against the X-valued `size`. Under standard SystemVerilog `if`-statement semantics (IEEE 1800: an unknown/X-valued condition is treated as **false**, not ambiguous or true — a definitive rule, not an edge case left to interpretation), an X-valued comparison resolves to "false" for branch-taken purposes. Working through the specific loop structures DOOM's zone allocator and lump-count loops use, this consistently means **loops tend to terminate early (often immediately) rather than spin forever** when fed X — the opposite of my working hypothesis before doing this trace. This is a reassuring, evidence-based finding, not a guess: it lowers the likelihood that the observed slowdown is an algorithmic hang, and raises the likelihood that this specific code region is simply more memory-access-heavy (and therefore slower in wall-clock terms, given the close-page SDRAM cost model already identified as this design's dominant bottleneck) than the `.bss`-clear/config-loading code seen in the first 10,000,000 cycles.
- **Conclusion for this check**: progressing, not stalled in the "genuine blocking condition" sense — continuing to let it run rather than intervening, consistent with the evidence (live CPU ticks, a traced reason the code shouldn't hang) rather than the raw wait time alone.

### The actual blocker behind the apparent stall: disk quota exhaustion, not an algorithmic hang

The run described above never did produce a new checkpoint. Bounded, monitored observation (18 minutes, per explicit instruction) confirmed via `/proc/<pid>/stat` that it consumed ~809 seconds of genuine CPU time in that window with zero new `[progress]` lines — a real, quantified slowdown (every prior 2,000,000-cycle span had taken ~400s; this one exceeded 1,080s with nothing to show). Attempting to write the evidence file for this exact finding failed with `Disk quota exceeded`. Direct investigation: this run's own `m5_doom_exec_tb.zwdb` had grown to **19,583,426,560 bytes (~19.58GB)** — more than double the previous (pre-fix) run's 8.57GB, still actively growing, `waveform_mode="off"` still not honored. This is the real, confirmed cause — not primarily an algorithmic hang (the SystemVerilog-X-as-false analysis above still stands as a separate, correct piece of reasoning, just not the explanation for *this* symptom). Terminated the process (`kill -TERM`, confirmed first via `ps -o user` that it was this session's own), deleted the file, confirmed write access restored. Full detail: `research/results/m5_s3_attempt3_postfix_stalled_at_10M.log`.

### Fixed and re-verified: `--zwdb-start-off` + a header/directory-preloaded re-run

Two things built and verified *before* re-attempting the long DOOM run, per explicit instruction to validate with small tests first:

1. **The real waveform-suppression mechanism**: Zenith's own `--zwdb-start-off` CLI flag (documented in `get_zenith_help`, passed via `run_simulation`'s `extra_flags`) starts ZWDB recording off regardless of whether a `--zwdb <path>` output argument is present, and only turns on if the testbench calls `$zwdb_on` (none of this project's testbenches do). Verified via an actual run: `sim/tb/m5_wad_preload_check_tb.sv` run with `extra_flags=["--zwdb-start-off"]` produced **no ZWDB file at all** (`find` confirms absence, not just small size) — this is the real fix, as opposed to `set_sim_options(waveform_mode="off")`, confirmed on two separate prior occasions to not be honored in headless/`ui_remote_control` fallback paths.
2. **The small, focused WAD-access test** (`sim/tb/m5_wad_preload_check_tb.sv` + `firmware/tests/m5_wad_preload_check_main.c`, ~6,000 cycles): reads the preloaded WAD header and lump-directory entry 0 through the real `cpu_core`→`soc_bus`→`sdram_ctrl`→`sdram_model` path and checks the result against ground truth read directly from `freedoom1.wad` with Python. First version asserted lump 0's `size > 0`, which failed — investigated and found this was a **wrong test assumption**, not a preload bug: freedoom1.wad's real lump 0 is `"E1M1"`, a standard, correctly zero-size WAD map-marker lump (confirmed directly against the file). Fixed the assertion to check the actual expected `filepos`/`name` instead: **PASSES**. This confirms the WAD backend's offset-to-address translation is correct against real data, independent of the much larger, slower DOOM integration test.

**Operational note worth recording**: `run_simulation`'s own `output_tail` returned a stale (previous-run) snapshot on both of these re-runs, even though the fresh run had elaborated and produced new preload messages — confirmed by reading `zsim.log` directly afterward, which showed the real, current result both times. Treat `output_tail` as informational only; `read_simulation_log` is the source of truth for a run that just happened.

### The WAD-preloaded DOOM integration run: genuine progress past the previous stall point

With the WAD header+directory preloaded (`PRELOAD2`/`PRELOAD3`, already wired into `sim/tb/m5_doom_exec_tb.sv`) and `--zwdb-start-off` applied from the start, re-ran the full test. Progress, monitored continuously via checkpoints cross-referenced against `objdump`/`nm` (methodology identical to earlier sections):

| Cycle | PC | Function | Significance |
|---|---|---|---|
| 0 – 10,000,000 | (see earlier table) | `clear_bss_loop` → `SearchCollection` → `strcmp` | Identical to every prior run up to this point, as expected |
| 12,000,000 | `0x10045620` | `memset` | **First checkpoint past where the no-WAD run got stuck** |
| 14,000,000 | `0x10044128` | `strncpy` | Continued, varied real engine code |
| 16,000,000 | `0x100395b8` | **`W_AddFile`** | Confirms execution has reached and is actively running the real WAD-loading function — direct validation of the `D_FindIWAD` fix and the header/directory preload working together |
| 18,000,000 – 22,000,000 | `0x10043ffc`/`0x10044038` | `strncasecmp` | Consistent with `W_CheckNumForName`-style lump-name lookups (`W_CheckCorrectIWAD`/`D_IdentifyVersion`, both traced earlier in this section as needing only directory names, not lump content) |
| 24,000,000 | `0x10039280` | `W_LumpNameHash` | The hash function backing `W_CheckNumForName`'s lookups — real, expected engine code building/querying the lump-name hash table across 3,163 real lumps |

This is the first run in this project to demonstrably execute inside `W_AddFile` itself — concrete, traced evidence that the WAD-access gate is now passable, not just theorized.

### Confirmed with explicit, named checkpoints (not just post-hoc PC matching), on a fresh run under an unlimited wall-clock setting

Human-operator-confirmed via direct Animas GUI observation: the previous run was in fact cancelled by a 30-minute wall-clock cap (the GUI showed `Wall-clock cap (30 min) reached — simulation cancelled.`), invisible to this session through the MCP interface or OS-level process state (documented as its own job-lifecycle discrepancy finding in `research/results/m5_s3_attempt4_wad_preload_stuck_at_24M.log`). The operator disabled this cap and authorized a fresh run.

That fresh run reproduced the prior run's trajectory deterministically through cycle 24,000,000 (identical PCs at every checkpoint), then — now with the previously-buggy milestone flags fixed (see above) — produced explicit, named confirmations for the first time:

```
[MILESTONE] D_FindIWAD reached, cycle=11299768
[MILESTONE] W_AddFile reached (D_FindIWAD returned non-NULL), cycle=11324822
[MILESTONE] D_IdentifyVersion reached (WAD header+directory read without a fatal error), cycle=20517472
```

The gap between `D_FindIWAD` and `W_AddFile` (25,054 cycles) directly confirms the `--wrap=D_FindIWAD` fix returns promptly and execution proceeds into the real WAD-loading function. The `D_IdentifyVersion` milestone is the strongest evidence yet: it is only reachable if `W_AddFile` completed **without** hitting `I_Error` — i.e., the preloaded WAD header and lump directory passed real validation against real data, not a placeholder.

The run then continued, monitored continuously (`utime`-delta and `wchan` checked every heartbeat), **past the previous 30-minute cap point with no cap this time** — confirmed empirically by watching it cross that wall-clock threshold live (cycle 24,000,000 → 25,500,000 → 28,000,000 → 31,500,000, each a new high-water mark, none matching the previous run's stopping point). This stands as working confirmation of the unlimited-wall-clock setting, obtained by observing the run actually survive past the threshold rather than assuming the setting change was sufficient on its own.

### A genuine Animas/Zenith observability limitation: "OS process alive" is not "simulation progressing"

The run above eventually stopped producing new `[progress]` checkpoints past cycle 24,000,000. Across three successive bounded observation windows (~44 minutes total), `ps` kept showing the process `R+`/alive with a climbing cumulative `%cpu` average — signals that, on their own, are consistent with either "still computing slowly" or "idle." Direct investigation (not assumed) distinguished the two: `/proc/<pid>/stat`'s `utime` field showed **zero new CPU ticks** across a fresh 3-second check (every earlier check that session had shown ticks advancing), `ps -o wchan` showed the process blocked in `inet_csk_accept` — the daemon's own idle network-listener loop, not simulation code — and `zsim.log`'s mtime was **1 hour 41 minutes stale**. `RSS` had also dropped from ~431MB to 98MB, consistent with the simulation's own working set having been torn down. No `$finish`, `[RESULT]` line, or error was ever printed; the run had simply stopped producing simulated time at some point, silently, with no MCP-exposed signal distinguishing this from "still running." Full evidence: `research/results/m5_s3_attempt4_wad_preload_stuck_at_24M.log`.

Terminated the confirmed-idle process after preserving this evidence. Investigated (per explicit instruction) whether Animas exposes a non-disruptive way to inspect a running simulation's live state: `get_waveform_state` returns an empty snapshot (confirmed directly) because no ZWDB exists at all with `--zwdb-start-off` active — every waveform-query tool (`query_signals_at_time`, `get_clock_info`, etc.) is consequently unusable for a live, still-running job under this waveform-suppression strategy. The only live signal available is the testbench's own `$display` output in `zsim.log`, at whatever granularity the testbench itself chooses to log.

### Improved diagnostics before retrying, and a bug found in the improvement itself

Reduced the periodic checkpoint interval from 2,000,000 to 500,000 cycles and added `cpu_core`'s own FSM state plus `mem_valid`/`mem_ready` to each line. Also added four explicit, one-shot `[MILESTONE]` checkpoints keyed to real function entry addresses (`D_FindIWAD`, `W_AddFile`, `D_IdentifyVersion`, `D_DoomLoop`) — a zero-upstream-patch way to get named progress markers by watching `pc_out` from the testbench alone.

**A bug was found in this improvement itself, and it is the same bug class this whole investigation keeps surfacing in DOOM's own code**: the `seen_*` latch variables backing each milestone were declared with no initializer, defaulting to **X** at time 0. `!X && (condition)` stays X, and SystemVerilog's `if` treats X as false — permanently, regardless of whether `pc_out` ever matched. Found by noticing no `[MILESTONE]` line had printed despite the periodic `[progress]` samples clearly showing `pc_out` passing through `W_AddFile`'s exact entry address. Fixed with explicit `= 1'b0` initializers (matching how `cycle_count`/`fb_write_count` were already initialized in the same file) — not applied retroactively to the run already in flight, since editing a source file doesn't affect an already-elaborated simulation; queued for the next one.

### Re-run: genuinely passes the exact point the previous attempt stopped at

Re-ran with the finer-grained testbench. Confirmed the job lock was released first (fresh elaboration succeeded with no "already in progress" error). The new run reproduced the previous one's trajectory almost exactly cycle-for-cycle through 24,000,000 (same PCs at 12M/14M/16M/18M/20M/22M/24M, confirming deterministic execution given identical inputs), then — unlike the previous attempt — **continued**:

| Cycle | PC | Function | Significance |
|---|---|---|---|
| 24,000,000 | `0x10039280` | `W_LumpNameHash` | Exactly the PC the previous run was stuck at — this time confirmed still actively computing (`utime` delta positive) |
| 24,500,000 | `0x10039bc0` | **`W_GenerateHashTable`** | **Genuinely new territory, past the previous attempt's stop point** — building the lump-name hash table across all 3,163 real directory entries |
| 25,000,000 | `0x100392a4` | near `D_AddFile`/`W_AddFile` boundary | Consistent with returning from the hash-table build |

Monitored continuously with `utime`-delta and `wchan` checked every heartbeat this time (not just process-alive state), specifically to catch a repeat of the silent-stop failure mode within minutes rather than ~44. As of this entry the run remains alive and genuinely computing (fresh `utime` deltas confirmed, no `wchan` block, no ZWDB growth) past cycle 25,000,000 — not yet concluded, being monitored further.

### Final result of the unlimited-wall-clock run: the testbench's own 60,000,000-cycle watchdog concluded it cleanly

The run continued being monitored (utime/wchan-aware, per the operator's explicit instructions) all the way to its own built-in watchdog limit, crossing every previous stopping point along the way as new high-water marks (28,000,000 → 35,000,000 → 45,000,000 → 50,000,000, each confirmed via fresh checkpoints, never repeating a prior run's exact failure point). It concluded on its own, cleanly, with no intervention needed:

```
[progress] cycle=60000000 pc=0x1003157c fb_writes=0 cpu_state=S_WAIT_IFETCH mem_valid=1 mem_ready=0
[RESULT] WATCHDOG (60000000 cycles) reached with no halt/illegal/full-frame -- inconclusive, not a failure. Last pc=0x1003157c, fb_writes_seen=0
[sim] $finish at time 600000005 (exit code 0)
```

Confirmed via `get_last_sim_result` (`"finished": true, "finish_time": 600000005`) — matching the log exactly, no GUI/MCP discrepancy this time. Full raw log: `research/results/m5_s3_attempt5_full_run_watchdog_60M.log`.

**The final PC, traced**: `0x1003157c` is inside `SHA1_Update` (`software/upstream/doomgeneric/sha1.c`); the handful of addresses the last several checkpoints rotated through (`Transform`, `M_StringCopy`) are SHA1's internal block-compression function and a string-copy helper. Traced the call path: `d_net.c:204` calls `W_Checksum(connect_data->wad_sha1sum)` — part of vanilla DOOM's always-present network-game-info setup (this project's own scope decision #9 already noted `d_net.c` is compiled but never used for actual networking, yet this setup code still runs). `W_Checksum` (`w_checksum.c`) iterates over **every one of the 3,163 real lumps** now correctly present in `lumpinfo[]`, feeding each lump's name/file-number/position/size (metadata only, from the preloaded directory — not lump content) into a running SHA1 hash. This is real, correct, bounded (`O(numlumps)`) engine code — not a hang, not an unexpected path — computing the loaded WAD's identity hash as a standard part of DOOM's startup sequence, on a CPU where every memory access costs several cycles via the close-page SDRAM controller, over thousands of lumps.

**Honest conclusion for this attempt**: engine initialization — now provably including real `D_FindIWAD`, `W_AddFile`, `D_IdentifyVersion`, and a full WAD-identity checksum pass over all 3,163 lumps — takes longer than 60,000,000 simulated cycles to reach the first framebuffer write (`fb_writes_seen=0` at the watchdog). This is not a failure of the RTL, the fix, or the preload strategy — every one of those is now demonstrated working, concretely, with named milestones. It is a genuine, now-quantified statement about how much simulated time DOOM's real startup sequence needs on this design, which the next session should budget for explicitly (a larger `WATCHDOG_CYCLES`, not further debugging) rather than treating as something to fix.

### Attempt 6 (watchdog raised to 200,000,000): reaches `R_Init`, then a controlled fatal exit — not a hang

With `WATCHDOG_CYCLES` raised to 200,000,000 (justified by the measured `W_Checksum` workload: 3,163 lumps × SHA1, ~1,038 `Transform()` calls), re-ran. The run reproduced every previously-confirmed milestone at identical cycle counts (`D_FindIWAD`=11,299,768, `W_AddFile`=11,324,822, `D_IdentifyVersion`=20,517,472 — fully deterministic given identical preloaded inputs), then reached two **new** milestones never seen before:

```
[MILESTONE] D_InitNetGame reached -- W_Checksum completed (all 3,163 real lumps hashed), cycle=80104015
[MILESTONE] R_Init reached -- rendering subsystem initialization begins, cycle=80134964
[RESULT] HALTED (ECALL/_exit reached) at pc=0x1003ab68, cycle=80186517, fb_writes_seen=0
[sim] $finish at time 801865175 (exit code 0)
```

`W_ReadLump`'s milestone never fired. Root-caused by reading `software/doom_port/w_file_de2115.c:40` directly: `De2115_OpenFile` sets `wad_file_t.mapped = (byte *)WAD_SDRAM_BASE` unconditionally, so `w_wad.c`'s `W_CacheLumpNum` always takes the memory-mapped branch (`result = lump->wad_file->mapped + lump->position`) and never calls `W_ReadLump` — a deliberate, correct design for this target (the WAD lives directly in the CPU's address space, no real filesystem), not a bug. This means every lump-CONTENT access is a raw pointer dereference into `WAD_SDRAM_BASE + lump->position` — exactly the region this project has only ever preloaded the header (12 bytes) and directory (50,608 bytes) into, never lump content. Confirmed directly from `sim/models/sdram_model.sv:78/178-179` that `mem_store` is an associative array whose read path is `mem_store.exists(key) ? mem_store[key] : 32'd0` — any address never explicitly written reads back as a deterministic `32'd0`, not `X`. So every un-preloaded lump's content reads as zero.

The halt is a controlled `ECALL`/`_exit` — i.e. the program itself called `exit()` — not a crash, hang, or illegal instruction. This is real, new evidence that the engine's `W_Checksum`/metadata path is fully correct; the open question became whether `R_Init` fails *because* real lump content is unavailable, or for some unrelated reason.

### Attempt 7: fine-grained `R_Init*` sub-milestones narrow the halt to inside `R_InitTextures`

Added one milestone per `R_InitData`'s four sub-inits (`R_InitTextures`, `R_InitFlats`, `R_InitSpriteLumps`, `R_InitColormaps`) plus `R_InitPointToAngle`/`R_InitSkyMap` (bracketing `R_InitData`'s return and `R_SetViewSize`/`R_InitPlanes`/`R_InitLightTables`'s return) and `I_Error`'s own entry (fires on any fatal DOOM error, regardless of message). Re-ran:

```
[MILESTONE] R_Init reached -- rendering subsystem initialization begins, cycle=80134964
[MILESTONE] R_InitTextures reached, cycle=80135116
[MILESTONE] I_Error reached -- a fatal DOOM engine error path was taken, cycle=80140294
[RESULT] HALTED (ECALL/_exit reached) at pc=0x1003ab68, cycle=80186517, fb_writes_seen=0
```

None of `R_InitFlats`/`R_InitSpriteLumps`/`R_InitColormaps`/`R_InitPointToAngle`/`R_InitSkyMap` fired — confirming `I_Error` is called from inside `R_InitTextures` itself (only 152 cycles after entry, then only 5,178 more cycles to `I_Error`: a handful of instructions, not a long computation first).

Re-examined `software/upstream/doomgeneric/r_data.c`'s `R_InitTextures` and `GenerateTextureHashTable` by hand against the "every un-preloaded lump reads as zero" fact: `nummappatches`/`numtextures1`/`numtextures2` all evaluate to 0 (read from zeroed PNAMES/TEXTURE1/TEXTURE2 content), making `numtextures=0`, which makes every per-texture loop (including `GenerateTextureHashTable`'s `% numtextures` divide, which looked like a plausible divide-by-zero candidate) a no-op since the loop bound is 0. Every `Z_Malloc(0-ish size, PU_STATIC, NULL/0)` call in this path matches a pattern (`d_main.c`'s earlier `gamename = Z_Malloc(gamename_size, PU_STATIC, 0)`) already proven to succeed earlier in this exact run. `I_ConsoleStdout()` is hardcoded to return 0 on this target, so the `printf` box-drawing path is dead code. **No further candidate was provable from source reading alone** — logged as an open question rather than guessed at.

### Attempt 8/9: capturing `a0`-`a7` at `I_Error` resolves the exact call site via ELF `.rodata`

Rather than keep guessing from source, added a register capture at the `I_Error` milestone: `a0` (`x10`, RISC-V's first integer argument) holds `I_Error(char *error, ...)`'s format-string pointer, and every `I_Error` call site in the DOOM source passes a distinct literal C string constant — so the resolved address can be looked up directly in `doom.elf`'s `.rodata` to identify exactly which of the many call sites fired, with certainty. `a1`-`a7` were captured alongside it to resolve any `%s`/`%d` argument (several candidate messages, e.g. `"W_GetNumForName: %s not found!"` or `"Z_Malloc: failed on allocation of %i bytes"`, take one) in the same run. Implementation: `dut_cpu.u_regfile.regs[10..17]` read directly in the testbench at the same `posedge clk` the `I_Error` milestone already fires on.

**An Animas orchestration quirk surfaced while relaunching for this**: calling `run_simulation` while a previous daemon-backed job was still mid-run caused the MCP tool call itself to time out client-side after 300s with "no response" — but the underlying request *had* actually reached Animas and triggered a fresh `handleRunSim()` (confirmed by `zsim.log` being freshly rewritten, line count reset, a brand-new compile with no `cycle=0` yet, under the exact same daemon PID). Separately, a second, fully independent headless Zenith subprocess also got spawned (apparently a client-side retry before the tool gave up) whose stdout/stderr went to anonymous pipes with no readable log path at all — a real duplicate-job/observability gap, distinct from the GUI-cancellation-vs-MCP-state discrepancy found earlier in M5 S3. Resolved by identifying and terminating only the orphaned duplicate (confirmed via `ps`/`/proc` ownership before acting) and continuing to monitor the one daemon-backed job that was actually progressing correctly.

## M6 (bootloader follow-up) — WAD-copy gap closed in firmware, regression re-verified: PASS

While writing `docs/how_to_run_doom.md` during M6, found that `firmware/bootloader/bootloader_main.c` read the SD boot image header's `wad_lba_start`/`wad_length` fields (`header[6]`/`header[7]`) nowhere, even though `scripts/prepare_sd_image.py` already supported embedding a WAD via those exact fields — so the bootloader copied the program but silently never copied any embedded WAD. Fixed: added a second copy loop (same `sdspi_read_block` mechanism as the existing program copy) guarded on `wad_lba_start != 0`, copying into the fixed `WAD_SDRAM_BASE = 0x1400_0000` that `software/doom_port/w_file_de2115.c` already assumes, with a new `LED_BOOT_LOADING_WAD` (`0x6`) status code. Every boot image built so far has `wad_lba_start=0` (none were built with `--wad`), so this is purely additive.

**Re-verified, not just asserted**: rebuilt the bootloader from the changed source (`scripts/build_firmware.sh bootloader firmware/linker/de2_115_bus.ld firmware/startup/crt0_bus.S firmware/bootloader/bootloader_main.c` — 736 bytes / 184 words, up from the original 584 bytes / 146 words, confirming the new WAD-copy code actually compiled in), copied the result over `sim/models/soc_rom.hex` (previous version backed up as `sim/models/soc_rom.hex.bak_pre_wad_copy_fix`, not deleted), and re-ran `sim/tb/m4_e2e_tb.sv` headless: **7/7 checks PASS, 0 errors, `pc=0x10000030` at halt, identical pixel-check results to the pre-fix run** — confirming the additive change is genuinely behavior-preserving for every existing boot image, not just assumed to be by inspection. Ran in 87.6s wall-clock (headless mode — see the M5 S3 section's throughput discussion for why this run went through headless rather than `ui_remote_control`).
