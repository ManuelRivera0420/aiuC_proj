# Known Limitations and Environment Facts — M0

Honest record of what this environment can and cannot do, established by direct probing (not assumption), per the mission's integrity requirements.

## Confirmed available

- **Shell access**: yes, ordinary user `marivera`, no root, no passwordless `sudo`.
- **Internet access**: yes (verified `curl` to github.com returned HTTP 200).
- **Git**: yes, 2.52.0. This directory was already a git repo with 2 prior commits before this session (`47d0ae9 first commit`, `7627ea6 added de2-115 doc`).
- **RISC-V bare-metal toolchain**: present but **not on default PATH** — requires `module load riscv-gnu-toolchain/elf-multilib/2026.07.15-elf` (Lmod environment-modules system at `/edatools`). Once loaded: `riscv64-unknown-elf-gcc` 16.1.0, confirmed multilib includes `rv32im/ilp32` (and rv32i, rv32iac, rv32imac, rv32imafc, rv64imac, rv64imafdc). The `riscv64-unknown-elf-` prefix does produce RV32 output when `-march=rv32im -mabi=ilp32` is passed, confirmed via `-print-multi-lib`/`-print-multi-directory` — matches the mission's warning not to assume this blindly.
- **Other pre-installed opensrc tools**: `riscv-dv/2026.08.27` (instruction-stream generation, could help differential ISA testing in M1), `qemu-riscv/8.2.0` (present but explicitly NOT to be used as the RTL simulator per mission scope — reserved at most for independent host-side reference comparison, never as a substitute for Animas execution).
- **Python**: system `/usr/bin/python3` is 3.9 with **no pip module**. A separate module `python3/3.11.16` (also via Lmod) provides working `pip`; used to install `pypdf` for manual-table verification (see below).
- **Animas MCP**: real, working connection. `list_projects`, `get_project_info`, `add_source_file`, `set_sim_top`, `run_simulation`, `get_last_sim_result`, `get_sim_diagnostics`, `patch_source_file` all function and were exercised in this session with a genuine (non-counter) RTL design — see `research/evidence_index.md`.
- **Zenith simulator** (Animas's backend, v1.0.2): a real SystemVerilog simulator — `--help` output confirms support for classes, UVM 1.2/2020, DPI-C, SVA assertions, functional coverage, ZWDB waveform export, file lists, `$readmemh`-style memory files (via `mem` file role), parameter overrides (`-G`). This is a materially more capable tool than "just enough to blink a counter."

## Confirmed NOT available / blocked

- **pdftoppm / poppler-utils**: not installed, and the Read tool's PDF-page-image rendering path depends on it — every attempt to `Read` the manual with a `pages` range failed with "pdftoppm is not installed." **Worked around** by installing `pypdf` (pure Python, no root needed) under the `python3/3.11.16` module and extracting text programmatically instead of rendering page images. This is why manual verification in `docs/board_resource_selection.md` cites extracted text rather than visual page captures.
- **No root/sudo**: cannot install poppler-utils, cannot modify the default PATH/module auto-load, cannot do system-wide package installation. All toolchain access goes through user-space Lmod modules or `pip install --user`.
- **Quartus / any synthesis, fitter, timing analyzer, or programmer**: not invoked, per explicit mission scope boundary. Not probed for presence or absence — irrelevant to this phase and not our responsibility to run even if present.
- **Any RTL simulator other than Animas/Zenith**: not invoked, per explicit mission scope boundary.

## Correction to a claim in the initial prompt

The prompt states the attached manual is "122 PDF pages." The harness's own file-metadata system-reminder claimed **141 pages**. Direct extraction with `pypdf.PdfReader` (`len(reader.pages)`) returns **122**, matching the prompt's figure and contradicting the harness metadata. Treating the independently measured value (122, pypdf) as authoritative for this project; the 141 figure from the system reminder appears to have been wrong, possibly from a pre-rendering/OCR size estimate rather than an actual page count.

## Correction to a claim about prior Animas validation

The prompt states "the human team has already connected Claude to Animas via MCP and has successfully demonstrated autonomous generation/simulation of a counter." At the start of this session, `get_project_info` showed `source_count: 0` and `latest_zwdb: null`, even though `project.apf`'s settings block still referenced `top_module=counter` / `sim_top=test/counter_tb.sv`. No `counter.sv` or `counter_tb.sv` file existed anywhere in the project (confirmed via `list_all_files`). **The counter pass could not be independently verified in this session's starting state** — it may have happened in a different/prior project session whose source files were since removed or never committed. Per the mission's own integrity rule ("never claim Animas... was executed unless you have its actual output"), this session ran its own first sanity check from scratch rather than relying on the unverifiable prior claim. See `research/evidence_index.md`.

## SDRAM controller: assumed geometry and timing, not datasheet-confirmed

`rtl/memory/sdram_ctrl.sv` assumes a conventional 4-bank/13-bit-row/10-bit-column SDR SDRAM geometry (chosen because it multiplies out to exactly the manual's stated 128MB/32M-word total capacity) and conservative, JEDEC-generic timing parameters (tRCD/CL/tRP = 2 cycles each at 50MHz, ~100us power-up wait, ~7.8us refresh interval) — **not** figures taken from the actual installed SDRAM chips' datasheet, because no such datasheet is attached to this project and the DE2-115 manual itself only gives total capacity and pins (Table 4-28), not per-chip timing. This is flagged in the RTL file's header comment as well. Before trusting this controller on physical hardware, the human team must identify the actual SDRAM part number (chip markings or Terasic's published BOM) and confirm/adjust the geometry and the `T_RCD`/`T_CL`/`T_RP`/`POWERUP_CYCLES`/`REFRESH_INTERVAL` parameters against its real datasheet.

## Still unresolved before Quartus handoff can be considered safe

- Exact Cyclone IV E speed grade suffix for the installed device (manual block text gives `EP4CE115F29` without a speed-grade digit) — needed for an accurate `.qsf` `DEVICE` setting.
- JP6/JP7 physical jumper positions — needed to pick the correct I/O standard for KEY[0:3], SW[0:17], and several HEX/display pins that are marked "Depending on JP6/JP7" rather than a fixed voltage.
- Physical SPI-mode compatibility of the specific ADATA `AUSDH32GUICL10-RA1` card in this socket — the manual documents the socket and confirms SPI is a supported protocol mode generically, but (as the mission itself says) does not constitute lab-verified compatibility with this exact card model.

None of these block RTL/firmware development (M1-M5 can proceed in simulation), but all three must be resolved before the human team programs real hardware (M6).
