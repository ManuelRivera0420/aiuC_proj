# Milestone Status

## M0 — Feasibility and evidence plan: **DONE** (2026-11-07)

- Capability probe complete: shell, internet, git, RISC-V toolchain (needs `module load riscv-gnu-toolchain/elf-multilib/2026.07.15-elf`), Python/pip (needs `module load python3/3.11.16`), Animas MCP, Zenith simulator feature set. See `docs/known_limitations.md`.
- Initial prompt frozen (harness-truncated, provenance documented) at `research/prompts/initial_prompt.md`.
- Repository skeleton scaffolded per the mission's required structure.
- DE2-115 manual pin/resource claims in the mission brief **independently verified by direct PDF text extraction** against the actual manual (not assumed): clocks, KEY/SW, LEDs, VGA/ADV7123, SDRAM, SD Card socket, FPGA device resource counts. All matched exactly. See `docs/board_resource_selection.md`.
- Mandated Animas sanity check executed and passed on real (non-counter) RTL: a 32-bit RV32I ALU + 32×32 register file with a self-checking testbench, run through the actual Animas MCP `run_simulation` tool (UI remote-control mode) against the real Zenith v1.0.2 simulator. 17/17 directed checks passed, 0 errors, 0 warnings after two trivial RTL cleanups. See `research/evidence_index.md`.
- Correction recorded: the prior "counter pass" referenced in the initial prompt could not be verified in this project's starting state (0 registered sources, no ZWDB). Treated as unverified rather than fact.
- Correction recorded: manual page count is 122 (pypdf-confirmed), matching the prompt, not the 141 claimed by harness file metadata.

## M1 — CPU PASS: not started

Next step. Scope: full multicycle RV32IM datapath (ALU above is a reusable building block), control FSM, decode, load/store with byte/half/word + sign extension, branches/jumps, MUL/DIV/REM via the M extension, misaligned-access policy, reset/trap handling sufficient for a freestanding runtime, and an architectural retirement trace Animas can export for independent checking. This is a multi-session effort, not a single-turn deliverable — see `docs/known_limitations.md` for environment facts that will shape it (e.g., Zenith supports SVA/coverage, so M1's ISA tests should use concurrent assertions rather than only `$display` diffing).

## M2-M6: not started
