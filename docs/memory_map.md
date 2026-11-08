# SoC Memory Map (M3+)

Written before the bus RTL, not reverse-engineered from it afterward. Supersedes M2's single-flat-64KiB-region linker script, which was a standalone-core test simplification only (see `docs/verification_report.md` M2 section and `PROJECT_STATE.md`).

`cpu_core.sv`'s single picorv32-style memory port (`mem_valid/ready/addr/wdata/wstrb/rdata`) connects to `rtl/bus/soc_bus.sv`, a combinational address decoder that routes each request to exactly one of the regions below and forwards `ready`/`rdata` back. No region overlaps; addresses outside all ranges return a defined error behavior (see "Unmapped access" below) rather than aliasing silently.

| Region | Base | Size | Notes |
|---|---|---|---|
| Boot ROM | `0x0000_0000` | 64 KiB | On-chip, `$readmemh`-loaded bootloader in simulation; in the real SoC this is the code that drives the SD/SPI controller to load the real program into SDRAM. Writable in simulation for test convenience; the real Quartus build will back this with a read-only-in-practice M9K init, same as any BRAM-initialized boot ROM. |
| Boot RAM (scratch) | `0x0001_0000` | 64 KiB | On-chip scratch RAM for the bootloader's stack/buffers before SDRAM is confirmed initialized. Not reused once the real program is running in SDRAM. |
| SDRAM | `0x1000_0000` | 128 MiB (`0x1000_0000`-`0x17FF_FFFF`) | Matches the manual's 128MB (32M×32bit) total capacity (Section 2, p.11; Table 4-28). Real program code+data, heap, stack, WAD working set once the bootloader jumps here. |
| GPIO (KEY/SW) | `0x2000_0000` | 256 B | `rtl/peripherals/key_sw_gpio.sv`. See register layout below. |
| Timer | `0x2000_0100` | 256 B | `rtl/peripherals/timer.sv`. Free-running cycle counter; needed later for DoomGeneric's `DG_GetTicksMs`/`DG_SleepMs`. |
| SD/SPI controller | `0x2000_0200` | 256 B | `rtl/peripherals/sd_spi.sv`. See Section 3A of the original mission prompt for the command/register contract. |
| UART (optional diagnostic) | `0x2000_0300` | 256 B | Not required for boot or gameplay per mission scope; implemented only if it measurably helps debugging. |
| VGA framebuffer | `0x3000_0000` | up to `0x0004_0000` (256 KiB) reserved, `0x28400` actually used | On-chip dual-port M9K framebuffer, `rtl/peripherals/framebuffer.sv`. **Locked in M5** after inspecting DoomGeneric's real `DG_ScreenBuffer` format (320×200, 8-bit palette-indexed, not 32-bit RGB as originally guessed-against). CPU write port at this address range: `0x3000_0000`-`0x3000_F9FF` pixel data (byte = palette index, 4 pixels packed per 32-bit word), `0x3001_0000`-`0x3001_03FF` palette (256 entries × 4 B, low 24 bits RGB888, word-addressed — entry N at `0x3001_0000 + 4*N`). Index→RGB lookup happens inside this module, so the independent VGA-clock-domain read port in `rtl/peripherals/vga.sv` only ever sees a plain 24-bit RGB value and needed no changes. 256 KiB stays reserved (sized for the original worst case) even though only ~161 KiB is used, to avoid re-deciding the memory map again. |

### GPIO register layout (`0x2000_0000` base)

| Offset | Name | Access | Bits | Meaning |
|---|---|---|---|---|
| `0x00` | `KEY_STATUS` | RO | `[3:0]` | Synchronized, active-HIGH (inverted from the board's active-low signal) current state of `KEY[3:0]`. `KEY[0]` (board reset) is NOT visible here — it never reaches the fabric as a gameplay input, it IS the SoC reset. So this register only ever reflects `KEY[1:3]`; bit 0 reads 0 always (reserved). |
| `0x04` | `SW_LEVEL` | RO | `[17:0]` | Synchronized, continuous level state of `SW[17:0]` — used directly for movement/strafe (`SW[0:3]`), level-sensitive per the mission's locked mapping. |
| `0x08` | `SW_EDGE` | RO, read-clears | `[17:0]` | Rising-edge (0→1 transition) detect for every switch, latched until read. Software uses this for `SW[4]` (use), `SW[5]` (next weapon), `SW[6]` (menu toggle), `SW[7]` (menu select) — the mission's edge-triggered controls — while still exposing all 18 bits in case later menu logic wants more. Reading this register clears the latch (standard "read-to-acknowledge" event register), so software must poll it, not `SW_LEVEL`, for one-shot actions. |
| `0x0C` | `LED_STATUS` | RW | `[17:0]` red / write-only mirror | Software-controlled status LEDs (`LEDR[17:0]`) — boot/SD-init/SDRAM-init/loading/running/error codes per `docs/boot_process.md` (to be written in M4). |

### Unmapped access

`soc_bus.sv` asserts `mem_ready` with `mem_rdata = 32'hDEAD_BEEF` for any read to an address not covered by the table above, and silently drops (acks without side effect) any write to one — chosen over a bus-level trap/exception because `cpu_core.sv`'s M1 trap surface is intentionally minimal (ECALL/EBREAK/illegal-decode only, see `docs/verification_report.md`). A visibly wrong readback value is preferred over a silent zero so a firmware bug manifests as an obviously-wrong number during debugging rather than looking like valid data.

### What is deliberately NOT in this map yet

- **2 MB SRAM**, **8 MB Flash**: optional per the mission's locked peripheral selection ("optional only if it measurably helps") — not added until a concrete need appears (e.g. SRAM as a fast scratch buffer if SDRAM bandwidth contention becomes a measured bottleneck in M4/M5).
- Any PS/2, USB, audio, Ethernet, or RS-232-as-gameplay-input address range — explicitly out of scope.
