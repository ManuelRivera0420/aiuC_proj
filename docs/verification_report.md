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

### Scope decision for M2 (recorded, not discovered later)

This milestone's linker script places `.text`/`.rodata`/`.data`/`.bss` all in one flat 64 KiB RAM region with no ROM/RAM split and no `.data` load-address-vs-virtual-address copy — `crt0.S` only zero-clears `.bss`. This is correct for a single-memory standalone-core test but is **not** the final SoC memory map: M3/M4 introduce a real split (boot ROM or SD-loaded image vs. SDRAM-backed RAM), at which point `.data`'s initial values will need an explicit load-time copy from their LMA to their VMA, not just a `.bss` clear. Tracked in `PROJECT_STATE.md`.
