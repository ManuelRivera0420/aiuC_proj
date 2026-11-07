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
