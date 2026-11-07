# Evidence Index

Every PASS claim below links to a reproducible artifact. "Reproducible" means: re-running the cited command against the cited source files, in this same project, should regenerate the cited log/zwdb.

| Claim | Evidence | How to reproduce |
|---|---|---|
| RV32I ALU (10 ops incl. ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND) is functionally correct for the tested vectors | `output/zsim.log` (via Animas `get_last_sim_result`: error_count=0, warning_count=0, finish_time=91ns); raw PASS lines for all 10 directed ALU vectors + zero-flag check | Animas MCP: `set_sim_top(sim/tb/alu_regfile_tb.sv)` → `run_simulation(project_id)` → `get_last_sim_result` / `read_simulation_log` |
| RV32I register file: reset clears all regs, x0 is hardwired to zero (write attempts do not stick), independent writes do not disturb other registers, dual read ports return correct values | Same log as above, 6 additional PASS lines (`x1 after reset`, `x31 after reset`, `x0 stays zero after write attempt`, `x5 write/read port1`, `x5 write/read port2`, `x5 unaffected by x17 write`, `x17 holds new value`) | Same as above |
| Total: 17/17 self-checking assertions passed, 0 simulator errors, 0 elaboration warnings | `get_sim_diagnostics` returned `{"error":0,"warning":0,"fatal":0}` after the second run (first run had 2 cosmetic warnings, fixed via `patch_source_file` and re-verified) | Same as above; ZWDB at `output/alu_regfile_tb.zwdb` |
| DE2-115 pin assignments cited in the mission brief (CLOCK_50, KEY[0:3], SW[0:7], VGA/ADV7123, SDRAM, SD Card socket) match the actual manual | Direct text extracted from `DE2_115_User_manual.pdf` via `pypdf`, PDF pages 36, 39, 54-55, 69-70, 71-72 — full extracted text quoted in the conversation transcript and summarized in `docs/board_resource_selection.md` | `python3 -c "from pypdf import PdfReader; r=PdfReader('DE2_115_User_manual.pdf'); print(r.pages[N-1].extract_text())"` for PDF page N |
| RV32IM/ILP32 bare-metal cross-compilation is available in this environment | `riscv64-unknown-elf-gcc --version` → 16.1.0; `-print-multi-lib` lists `rv32im/ilp32` | `module load riscv-gnu-toolchain/elf-multilib/2026.07.15-elf && riscv64-unknown-elf-gcc -print-multi-lib` |

## What is explicitly NOT claimed yet

- No RV32IM CPU core exists yet (M1 not started) — the ALU/regfile above are building blocks, not a processor.
- No firmware has been compiled or executed on any RTL (S0-S4 software gates not started).
- No SDRAM, SD/SPI, VGA, or GPIO peripheral RTL exists yet.
- No DoomGeneric source has been fetched or inspected yet.
- Nothing in this project has been synthesized, fit, timed, or programmed onto physical hardware — and nothing here claims otherwise.
