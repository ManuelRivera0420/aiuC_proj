# Clock, Reset, and Clock-Domain-Crossing Notes — M6

Written from reading the actual RTL (`rtl/`), not inferred from the block diagram. Every claim below cites the specific file/line pattern it is based on; where this project's own simulation cannot confirm something (real FPGA clock skew, BRAM read/write-collision behavior under Quartus's inferred M9K), that is stated as unconfirmed rather than guessed.

## 1. Clock domains in this design

There are exactly **two** clock domains, both ultimately derived from the single 50 MHz `CLOCK_50` board oscillator — there is no PLL anywhere in `rtl/` (confirmed: `grep -rn "altpll\|pll" rtl/` matches nothing).

| Domain | Source | Used by |
|---|---|---|
| `clk` (50 MHz) | `CLOCK_50` directly, undivided | `cpu_core`, `soc_bus` and everything it instantiates (`key_sw_gpio`, `timer`, `sdram_ctrl`, `sd_spi`, `framebuffer`'s CPU-side port), and `vga`'s own H/V-timing-adjacent logic that still runs on `clk` |
| `pclk` (25 MHz) | `rtl/peripherals/vga.sv:57-60` — a plain toggle flip-flop, `pclk <= ~pclk` on every `posedge clk` | `vga.sv`'s H/V counters and all VGA timing/RGB output logic (`always_ff @(posedge pclk ...)`, `vga.sv:70`), and drives `VGA_CLK` out to the ADV7123 DAC |

`pclk` is a **generated clock**, not an independent oscillator — it is a register in the `clk` domain, toggling once per `clk` edge, so it is exactly `clk`-synchronous and exactly half rate by construction. This is declared to Quartus TimeQuest as `create_generated_clock -source CLOCK_50 -divide_by 2 [get_ports VGA_CLK]` in `fpga/de2_115/doom_riscv_de2_115.sdc` — the textbook-correct way to describe this topology, not a second unrelated `create_clock`.

**Caveat already flagged in `vga.sv`'s own header comment and `docs/board_resource_selection.md`**: a toggle-FF divider is adequate for simulation and a first bring-up, but has more jitter than a PLL-generated pixel clock. The human team should consider replacing it with a Cyclone IV PLL megafunction (`altpll`) for production image quality — RTL simulation cannot measure real jitter, so this project cannot validate that substitution itself.

## 2. Reset

Single asynchronous, active-low `rst_n`, driven directly from `KEY[0]` (`rtl/board/de2_115_top.sv:64`, `assign rst_n = KEY[0]`) with no inversion needed since the board's KEY is already active-low and this design's reset convention is already active-low.

Every sequential block in `rtl/` uses the same pattern: `always_ff @(posedge <its clock> or negedge rst_n)` (confirmed by `grep -rn "negedge rst_n" rtl/` — 13 files, every clocked module in the design, including both `clk`-domain and `pclk`-domain blocks in `vga.sv`). `rst_n` fans out as a single asynchronous reset net to both domains; there is **no reset synchronizer chain** anywhere in this RTL.

This is a deliberate simplification, not an oversight, and it is safe specifically *because*:
- `KEY[0]` is one of the DE2-115's hardware-debounced buttons (Schmitt-trigger input, per `docs/board_resource_selection.md` citing manual Fig 4-6/4-7 p.34) — so the external signal itself has no electrical bounce/glitch for the fabric to resolve.
- `pclk` is `clk`-synchronous (see §1), so there is no genuine *asynchronous* reset-domain-crossing between `clk` and `pclk` the way there would be between two truly independent oscillators — both domains see the same `rst_n` edge within one `clk` period of each other at worst.

What this project has **not** done, and flags for the human team: a real multi-cycle reset-deassertion synchronizer (reset released synchronously to each domain's own clock, a few cycles after the button physically releases) is standard practice for production designs and costs almost nothing to add. It was not added here because nothing in this design's current behavior depends on reset-deassertion skew, and adding it without a test that could demonstrate why would be exactly the kind of unjustified complexity the mission asks to avoid — but it is a reasonable low-risk hardening step before shipping.

## 3. The one real clock-domain-crossing in this design: the framebuffer scan-out read

This is the one place `clk`-domain and `pclk`-domain logic actually touch data, and it deserves explicit attention rather than silent passing-over:

- **Write side** (`clk` domain): the CPU writes pixel bytes and palette entries into `rtl/peripherals/framebuffer.sv`'s `pixel_words[]` / `palette[]` arrays via a registered port (`always_ff @(posedge clk ...)`, `framebuffer.sv:51-68`).
- **Read side** (`pclk` domain): `vga.sv`'s H/V counters (running on `pclk`) drive `fb_addr`, which `framebuffer.sv` turns into `fb_pixel` **combinationally** (`framebuffer.sv:75-83`, explicitly commented there as "combinational (matches vga.sv's zero-latency fb_addr->fb_pixel assumption)").

So a `pclk`-domain combinational read is indexing directly into memory cells written by `clk`-domain registered writes, with **no synchronizer, no dual-clock FIFO, no handshake** — just simulation-model-accurate Verilog array read/write semantics. In `sim/tb/vga_tb.sv` and the M4/M5 end-to-end tests this behaves correctly because the behavioral simulator resolves `pixel_words[addr]` reads and writes deterministically every delta cycle.

**What is genuinely unconfirmed, and must not be glossed over**: when Quartus infers real M9K block RAM for `pixel_words[]`/`palette[]`, simultaneous read (from the `pclk` domain) and write (from the `clk` domain) to the *same* address is a true dual-clock BRAM read/write collision. Cyclone IV M9K blocks support this electrically (true dual-port, independent clocks is a supported M9K configuration), but the **data value read back during a same-address collision is implementation-defined** unless the RAM is explicitly instantiated or inferred with a stated collision policy (old data / new data / don't care). This project's RTL does not specify one, because plain inferred-array Verilog has no syntax for it — Quartus's RAM inference will pick *something*, and this project's simulation cannot observe or validate what that something is, since the behavioral simulator has no concept of a real dual-port M9K collision window.

**Practical risk assessment**: this is a single-pixel, single-frame glitch at worst (one pixel briefly reads stale or indeterminate data on the one `clk` cycle a write happens to land on the exact address the scan-out is reading), not a functional or stability hazard — it cannot corrupt program state, hang the CPU, or desync VGA timing (`fb_pixel`'s consumer in `vga.sv` has no feedback path back into timing logic). The human team should be aware of it if they ever see a single-frame visual flicker during Quartus-synthesized hardware testing and wonder why simulation never showed it — simulation structurally cannot show it, for the reason above.

## 4. What is NOT a clock-domain-crossing in this design (confirmed, not assumed)

- `SD_CLK`/`SD_CMD`/`SD_DAT` in `rtl/peripherals/sd_spi.sv`: the SPI clock is itself generated from and synchronous to `clk` (no independent SD-card-side oscillator drives anything back into this FPGA's fabric on a clock port) — `SD_DAT[0]` (MISO) is an async *data* input (correctly `set_false_path`'d in the `.sdc`, §5 of `docs/known_limitations.md`-adjacent reasoning), not a second clock domain.
- `KEY[3:0]`/`SW[17:0]`: asynchronous *data* inputs into the single `clk` domain (`key_sw_gpio.sv`), not a separate clock domain — synchronized by that module's own registers, not a CDC in the clock sense.
- `DRAM_*`: all driven and sampled entirely within the `clk` domain by `sdram_ctrl.sv` — no second domain involved.
