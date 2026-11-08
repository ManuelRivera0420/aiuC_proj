# Module Interface Reference — M6

A port-by-port reference for every synthesizable module in `rtl/` (the exact file list in `fpga/de2_115/doom_riscv_de2_115.qsf`'s `SYSTEMVERILOG_FILE` assignments), for a human engineer picking this design up for the first time. This is a companion to `docs/memory_map.md` (address map) and `docs/clock_reset_cdc.md` (clocking/reset/CDC) — this document is about module boundaries and bus protocol, not addresses or timing domains.

## The shared bus convention

Every peripheral and the CPU core itself use the same **picorv32-style synchronous memory port** convention throughout this design:

```
output logic [31:0] mem_addr      // (or a narrower local-offset width inside a peripheral)
output logic [31:0] mem_wdata
output logic [3:0]  mem_wstrb     // byte lane write-enable; 4'b0000 = read
output logic        mem_valid     // request asserted
input  logic [31:0] mem_rdata     // valid the cycle mem_ready is asserted
input  logic        mem_ready     // single-cycle pulse, 1 cycle after mem_valid for every peripheral in this design except sdram_ctrl/sd_spi, which hold mem_valid low-latency but can take many cycles (SDRAM row activation, SD card command/response) — callers must not assume fixed latency
```

A new request is only sampled while the previous one's `mem_ready` has been seen; there is no pipelining (no second `mem_valid` is driven before the first's `mem_ready`). This matches `cpu_core.sv`'s own single-outstanding-request behavior, so no peripheral needs to handle overlapping requests.

`rtl/bus/soc_bus.sv` is the only place that does address decoding — every peripheral below receives a **local** `mem_addr` (soc_bus has already stripped the region's base address and narrowed the bus width to what that peripheral needs), per `docs/memory_map.md`'s table.

## CPU core

### `cpu_core` (`rtl/cpu/cpu_core.sv`)
The top of the CPU itself — multicycle RV32IM, fetch/decode/execute/writeback state machine.

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | System clock, async active-low reset |
| `mem_addr/wdata/wstrb/valid` | out | 32/32/4/1 | Bus master request (see shared convention above) — byte address, word-aligned only |
| `mem_rdata/ready` | in | 32/1 | Bus response |
| `halted` | out | 1 | Asserted once an unrecoverable condition is reached (currently: illegal instruction) — simulation/debug visibility only, no hardware behavior keys off it |
| `illegal_instr` | out | 1 | Combinational flag for the cycle an undecodable instruction is executed |
| `ecall_seen`, `ebreak_seen` | out | 1 each | One-cycle pulses for ECALL/EBREAK execution — this design has no trap/exception vector table (mission-scoped minimal trap surface, see `docs/verification_report.md`); these exist for test/debug observability |
| `pc_out` | out | 32 | Current program counter, for waveform/test visibility |

Internally instantiates `rv32i_alu`, `rv32i_regfile`, `rv32im_decoder`, `rv32m_mul_div` (all four below) — none of these four are ever instantiated anywhere else in the design, so they have no board-level pin/CDC concerns of their own.

### `rv32i_alu` (`rtl/cpu/alu.sv`)
Pure combinational ALU, no ports beyond `a`, `b`, `alu_op` → `result`, `zero`. No clock, no reset — stateless by construction.

### `rv32i_regfile` (`rtl/cpu/regfile.sv`)
32×32-bit register file, `x0` hardwired to zero internally (not a port-level concern — `rd==0` writes are suppressed inside this module). Single write port (`we`/`rd`/`wdata`), two combinational read ports (`rs1`/`rs2` → `rdata1`/`rdata2`). Uses `always @(posedge clk or negedge rst_n)` (plain `always`, not `always_ff`) for the write — functionally equivalent here since there's exactly one write and no blocking-assignment hazard, just a minor style inconsistency versus every other module's `always_ff`, not a bug.

### `rv32im_decoder` (`rtl/cpu/decoder.sv`)
Pure combinational instruction decoder. Takes raw `instr[31:0]`, produces every field (`rs1/rs2/rd/funct3/imm`), the `alu_op` encoding (matching `rv32i_alu`'s own localparams — the two files must be kept in sync if either changes), and one-hot instruction-class flags (`is_lui`/`is_auipc`/.../`is_fence`) plus `illegal`.

### `rv32m_mul_div` (`rtl/cpu/mul_div.sv`)
Multi-cycle M-extension unit (MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU via the 3-bit `op` encoding). `start` pulses one cycle, `busy` stays high until `done` pulses for exactly one cycle with `result` valid. `cpu_core` stalls its own state machine on `busy` — this is the only source of variable-latency execution inside the CPU itself (every other instruction class is fixed-cycle).

## Peripherals (all local-bus slaves off `soc_bus`)

### `key_sw_gpio` (`rtl/peripherals/key_sw_gpio.sv`)
Board KEY/SW input + LEDR output. `key_n`/`sw` are raw board pins (`key_n` active-low per the board, inverted internally before exposure in `KEY_STATUS`; `sw` already active-high, passed through). `ledr` is a direct registered output from the `LED_STATUS` MMIO register. See `docs/memory_map.md` for the `KEY_STATUS`/`SW_LEVEL`/`SW_EDGE`/`LED_STATUS` register layout — this file only covers the port list, not the register semantics.

### `timer` (`rtl/peripherals/timer.sv`)
Free-running cycle counter, read-only via the bus port. No side-effect-producing writes; exists purely so firmware has a `DG_GetTicksMs`-capable time source.

### `sd_spi` (`rtl/peripherals/sd_spi.sv`)
SDHC SPI-mode controller. Bus-side port is the standard local-offset convention above; board-side port (`sd_clk`/`sd_mosi`/`sd_miso`/`sd_cs_n`) maps directly to `SD_CLK`/`SD_CMD`/`SD_DAT[0]`/`SD_DAT[3]` in `de2_115_top.sv` — see that file and `docs/sdhc_32gb_boot_protocol.md` for the SPI-mode-vs-4-bit-mode pin mapping (`SD_DAT[1:2]` are unused and tri-stated at the top level, not wired to this module at all). Two clock-divider parameters (`INIT_CLK_DIV`/`FAST_CLK_DIV`) set the SPI clock rate before/after card initialization; `FAST_CLK_DIV=4` (12.5 MHz) is explicitly commented in the source as conservative and worth retuning once real hardware is available — this project's SPI timing was only ever validated against the behavioral `sdhc_spi_model.sv`, not a real card's actual AC timing margins.

### `sdram_ctrl` (`rtl/memory/sdram_ctrl.sv`)
Close-page/auto-precharge SDR SDRAM controller. Bus-side port takes a full 32-bit *byte* address (word-aligned only — sub-word accesses are not supported, matching `cpu_core`'s own alignment guarantee). Board-side port matches DE2-115 Table 4-28 pins exactly. Five timing parameters (`T_RCD`/`T_CL`/`T_RP`/`POWERUP_CYCLES`/`REFRESH_INTERVAL`) encode this module's **assumed** device geometry/timing (4-bank/13-row/10-col, CAS latency 2) — flagged in `docs/known_limitations.md` as not datasheet-confirmed against the DE2-115's actual SDRAM part; the human team should verify these against the real chip's datasheet before relying on them at anything other than conservative default speeds.

### `framebuffer` (`rtl/peripherals/framebuffer.sv`)
Dual-port on-chip framebuffer + palette RAM. CPU-side port is the standard bus convention; VGA-side port (`fb_addr`/`fb_valid`/`fb_pixel`) is a separate, non-bus, always-combinational read port intended for a sibling `vga.sv` instance — **not** a second bus slave, and the one place in this design with a real clock-domain crossing (see `docs/clock_reset_cdc.md` §3 for the full analysis; do not treat this port as just another MMIO window).

### `vga` (`rtl/peripherals/vga.sv`)
VGA timing generator + DOOM scan-out addressing. Has no bus-slave port at all — it is pure output (`vga_r/g/b/hs/vs/blank_n/sync_n/clk`) plus the `fb_addr/fb_valid/fb_pixel` master port that drives into `framebuffer`'s VGA-side port described above. Runs its H/V counters on its own internally generated `pclk` (see `docs/clock_reset_cdc.md` §1), not directly on `clk`.

## Integration modules

### `soc_bus` (`rtl/bus/soc_bus.sv`)
The only address decoder in the design. Single CPU-facing bus-slave port; fans out to every peripheral above via their local-offset bus ports (see `docs/memory_map.md` for the exact base/size table); passes board-facing pins for GPIO/SDRAM/SD straight through to its own ports unmodified; separately exposes `fb_scanout_addr/valid/pixel` as a pass-through to/from its internal `framebuffer` instance, for `de2_115_top.sv` to wire to a sibling `vga` instance (this is why `vga` is instantiated at the top level rather than inside `soc_bus` itself — it needs to sit next to, not inside, the bus hierarchy, since it's a bus master into `framebuffer`'s second port, not a bus slave).

### `de2_115_top` (`rtl/board/de2_115_top.sv`)
Board-level top. Every port name/width matches `docs/pin_assignments.csv` exactly (cross-checked mechanically by `scripts/pin_audit.py`). Instantiates exactly three modules: `cpu_core`, `soc_bus`, `vga`, wired together as described above, plus the board-pin-level tri-state/passthrough logic for `SD_DAT`/`SD_WP_N`/`rst_n` documented in that file's own header comments. This is the module named in `fpga/de2_115/doom_riscv_de2_115.qsf`'s `TOP_LEVEL_ENTITY` assignment.
