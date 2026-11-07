# SDHC 32GB SPI Boot Protocol

Target medium: **ADATA Premier 32 GB microSDHC UHS-I Class 10, model `AUSDH32GUICL10-RA1`**, inserted via its bundled full-size SD adapter into the DE2-115's onboard SD socket (Table 4-31, manual p.71-72: `SD_CLK`=PIN_AE13, `SD_CMD`=PIN_AD14, `SD_DAT[0]`=PIN_AE14, `SD_DAT[3]`=PIN_AC14, `SD_WP_N`=PIN_AF14, all 3.3V). The manual documents the socket and confirms SPI is a supported access mode (p.68: "Users can implement custom controllers to access the SD Card in SPI mode and SD Card 4-bit or 1-bit mode") but does **not** constitute lab-verified compatibility with this exact card — that remains a human-team physical bring-up step (see `docs/known_limitations.md`).

## Pin mapping (SPI mode)

| SPI signal | DE2-115 pin | Direction (from FPGA) |
|---|---|---|
| SCLK | `SD_CLK` (PIN_AE13) | out |
| MOSI (DI) | `SD_CMD` (PIN_AD14) | out |
| MISO (DO) | `SD_DAT[0]` (PIN_AE14) | in |
| CS_N | `SD_DAT[3]` (PIN_AC14) | out |
| — (unused in SPI mode) | `SD_DAT[1:2]`, `SD_WP_N` | not driven by `sd_spi.sv`; the board top-level wrapper must pull/tri-state these safely (documented as an open item for `fpga_handoff.md`, not yet written) |

## Controller behavior (`rtl/peripherals/sd_spi.sv`)

1. **Idle clocks**: ≥80 clock cycles (10 bytes of `0xFF`) with `CS_N` high before the first command, per spec.
2. **CMD0** (`GO_IDLE_STATE`, arg=0): expects R1 with bit0=1 (idle). Byte sequence sent: `0x40 0x00 0x00 0x00 0x00 0x95` (the universally-documented CMD0 CRC).
3. **CMD8** (`SEND_IF_COND`, arg=`0x0000_01AA`: voltage range + check pattern `0xAA`): expects R7 (5 bytes) whose last byte echoes `0xAA`. Validated via `CRC7` computed in-RTL (`crc7_update`, polynomial x^7+x^3+1), not hand-coded per command.
4. **CMD55+ACMD41(HCS)** repeated: `CMD55` (APP_CMD prefix) then `ACMD41` with the HCS bit (bit30 of the argument, `0x4000_0000`) set, requesting high-capacity support. Repeats while R1 bit0=1 (still idle); the SDHC model exercises this retry path by deliberately responding "still idle" exactly `ACMD41_IDLE_RESPONSES` (default 2) times before reporting ready, which the testbench checks was actually exercised (not just structurally present).
5. **CMD58** (`READ_OCR`): inspects the OCR's CCS bit (bit30 of the OCR, i.e. bit6 of the OCR's second byte in the 5-byte R3 response) to confirm high-capacity (SDHC) addressing. A `CCS=0` card is reported as `ERR_NOT_SDHC` rather than silently misreading it as SDSC.
6. **CMD17** (`READ_SINGLE_BLOCK`, arg=LBA): LBA is the raw 32-bit logical block number — **not** a byte offset (SDHC addressing). Expects R1=0x00, then a data start token `0xFE`, then exactly 512 data bytes, then 2 CRC bytes (not checked on read by this controller — a documented simplification, not a silent gap).
7. **Clock rate**: starts at `INIT_CLK_DIV=128` (50MHz/128 ≈ 390 KHz) for the whole init handshake, then switches to `FAST_CLK_DIV=4` (≈12.5 MHz) only after CMD58 succeeds. Both are module parameters — per the mission's explicit allowance, no specific post-init throughput is promised without physical measurement on real hardware.

## Error codes (`REG_STATUS` bits `[7:4]`)

| Code | Meaning |
|---|---|
| 0 | none |
| 1 | CMD0 timeout (no card / not responding) |
| 2 | CMD8 check-pattern echo mismatch |
| 3 | ACMD41 timeout (card never leaves idle) |
| 4 | CMD58 CCS=0 (not a high-capacity/SDHC card) |
| 5 | CMD17 rejected (R1 error bits set) |
| 6 | Data start token timeout after CMD17's R1 |
| 7 | No card / reserved |

## Raw boot image format (`scripts/prepare_sd_image.py` / `verify_sd_image.py`)

A fixed, versioned binary layout — deliberately **not** a filesystem (no FAT32 parser in RTL or bootloader, per the mission's explicit preference for a minimal raw design):

- **LBA 0**: 512-byte header — magic `"RVDM"`, version, program load/entry addresses, program length, program LBA start (always 1), optional WAD LBA start/length, SHA-256 of the program image, SHA-256 of the WAD image (zero if absent). Full field layout documented in `prepare_sd_image.py`'s module docstring.
- **LBA 1..N**: the program image, zero-padded to a 512-byte boundary.
- **LBA (1+N)..M**: the WAD image (if provided), zero-padded similarly.

`verify_sd_image.py` independently re-slices the image by LBA using only the raw bytes (not trusting the JSON manifest) and recomputes SHA-256 over each region, so a corrupted image with an intact-looking manifest sitting next to it is still caught.

## Verification status

`sim/tb/sd_spi_tb.sv` + `sim/models/sdhc_spi_model.sv`: 9/9 PASS, including the full init handshake with ACMD41 genuinely retried twice, and a CMD17 read verified byte-for-byte against the same raw-image format intended for the physical card (`sim/models/sd_fixture.img`, built by `prepare_sd_image.py` from a synthetic 300-byte program and converted to the model's `$readmemh` input via a byte-wide hex dump). Four real RTL bugs and one model bug were found and fixed during this work — full writeup in `docs/verification_report.md`.

**Not yet done** (tracked for M4): wiring `sd_spi.sv` into `soc_bus.sv`'s address map (currently a reserved-but-unwired range, see `docs/memory_map.md`), and the actual bootloader code that drives a CMD17 read loop to copy a program from SD into SDRAM.
