# DE2-115 Board Resource Selection — M0

Status: **verified against the actual manual text** (direct PDF text extraction via `pypdf`, not assumed from the prompt). Source: `DE2_115_User_manual.pdf`, SHA-256 recorded in `research/experiment_manifest.json`. The manual is **122 PDF pages** (pypdf-confirmed); page numbers below are PDF page indices, which run one higher than the printed page number in the document footer.

## FPGA device (manual p.11, Chapter 2, Fig 2-3 block text)

- Cyclone IV **EP4CE115F29**
- 114,480 logic elements
- 432 M9K memory blocks, 3,888 Kbits embedded memory
- 4 PLLs
- Memory devices: 128 MB (32M×32bit) SDRAM, 2 MB (1M×16) SRAM, 8 MB Flash, EPCS64 config device

These match the prompt's claims exactly — no correction needed.

## Locked peripheral selection (per mission scope)

| Peripheral | Use | Verified pins (manual table) |
|---|---|---|
| CLOCK_50 | 50 MHz system clock | PIN_Y2, 3.3V — Table 4-5, p.39 |
| KEY[0..3] | reset + 3 gameplay buttons | M23/M21/N21/R24 — Table 4-2, p.36. **Hardware-debounced** (Schmitt trigger, Fig 4-6/4-7, p.34) |
| SW[0..17] | gameplay switches | Table 4-1, p.36 (SW[0..7] verified: AB28/AC28/AC27/AD27/AB27/AC26/AD26/AB26). **Not debounced**, level-sensitive by design (p.34 text) |
| VGA (ADV7123) | 640×480 output | VGA_CLK=A12, VGA_HS=G13, VGA_VS=C13, VGA_BLANK_N=F11, VGA_SYNC_N=C10, 8-bit R/G/B — Table 4-16, p.54-55. Board text confirms **8-bit** RGB (not 10-bit like older DE2 boards) |
| SDRAM | program/data/WAD/framebuffer | DRAM_CLK=AE5, DRAM_CKE=AA6, DRAM_RAS_N=U6, DRAM_CAS_N=V7, DRAM_WE_N=V6, DRAM_CS_N=T4, DQ[31:0], BA[1:0], DQM[3:0] — Table 4-28, p.69-70. All pins **3.3V**, no jumper dependency |
| SD Card socket | SPI-mode boot media | SD_CLK=AE13, SD_CMD=AD14, SD_DAT[0]=AE14, SD_DAT[3]=AC14, SD_WP_N=AF14 — Table 4-31, p.71-72. All pins **3.3V**. Manual explicitly states (p.68): "Users can implement custom controllers to access the SD Card in SPI mode **and** SD Card 4-bit or 1-bit mode" — SPI is a documented, supported access mode, not an invention |
| LEDR/LEDG | status | Table 4-3, p.36-37. **LEDs are 2.5V**, unlike VGA/SDRAM/SD which are 3.3V — do not blanket-assign one I/O standard across banks |

**Explicitly out of scope and confirmed unused:** PS/2, USB host/HID, audio CODEC (WM8731, Table 4-17), Ethernet, TV decoder, RS-232 (optional diagnostic only, Table 4-18).

## Important correction to the mission brief

Terasic's own **Chapter 6.6 "SD Card Demonstration"** (manual p.89-90) uses **SD 4-bit mode with a FAT filesystem, driven by a Nios II soft core**, not SPI mode and not a raw sector image. That reference design is a *existence proof that the socket and signals work*, but it is **not directly reusable** for this project's SPI/raw-image approach — the SD controller, FAT parsing, and Nios II software must all be replaced. This is consistent with the mission's own choice to simplify to SPI + raw sectors; just noting the reference example cannot be lifted as-is.

## I/O standard / jumper risk (hard requirement from the mission)

- KEY[0..3] and SW[0..17]: I/O standard is **"Depending on JP7"** per the table — not a fixed voltage. Must confirm JP7 position before finalizing `.qsf` I/O standard assignments for these banks. **Flagged as blocked pending jumper photo/confirmation from the human team** — not assumed.
- VGA, SDRAM, SD Card: all fixed at 3.3V in the table, no jumper dependency — safe to assign LVTTL/3.3-V I/O standard directly.
- LEDR/LEDG: fixed 2.5V — must NOT share a bank I/O standard setting with the 3.3V peripherals above.

## FPGA device string for Quartus

Manual names the device as **EP4CE115F29** (package/pin-count suffix F29, no explicit speed grade digit given in this block). The `.qsf` `DEVICE` setting must use the full part number including speed grade (commonly C7/C8 on these boards) — **this specific speed grade is not stated in the pages read so far and must be confirmed from the board's physical marking or the System Builder output before Quartus assignment**, per the mission's instruction not to invent specifications.

## Resource/bandwidth first-pass estimates (to be revised after M1-M3 measurements)

- Framebuffer candidates at 320×200: indexed-8 = 64,000 B, RGB565 = 128,000 B, 32-bit = 256,000 B. 432 M9K blocks × 9 Kbits ≈ 3,888 Kbits ≈ 486,000 bytes total embedded RAM budget — an indexed-8 or RGB565 on-chip dual-port framebuffer is plausible without starving the CPU's need for BRAM (register file, caches/buffers, boot ROM); 32-bit is the tightest fit and competes hardest with other BRAM uses. DoomGeneric's actual `DG_ScreenBuffer` format must be inspected (S3 gate) before locking this in — the mission explicitly warns against assuming 8-bit paletted output.
- SDRAM is a single shared 32-bit-wide interface across two 64 MB chips (confirmed DQ[31:0] is one bus in Table 4-28, not two independent 16-bit channels) — CPU fetch, WAD streaming, and VGA scan-out (if SDRAM-backed) all contend for one controller; arbitration design is a first-class concern, not an afterthought.
