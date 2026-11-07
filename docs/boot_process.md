# Boot Process

Full cold-boot sequence, M4 implementation. "Verified" below means `sim/tb/m4_e2e_tb.sv` has actually demonstrated it in Animas — see `docs/verification_report.md` for the pass/fail record; this document describes the *design*, not a claim that it's already been proven (check the verification report for that).

## Sequence

1. **Reset**: `KEY[0]` (active-low) resets `cpu_core`, `soc_bus`, and every peripheral. PC starts at `0x0000_0000` (boot ROM base).
2. **ROM execution begins**: `firmware/bootloader/bootloader_main.c` (compiled via `firmware/linker/de2_115_bus.ld` + `firmware/startup/crt0_bus.S`) runs from ROM. Stack is set up in boot RAM (`0x0001_0000`-`0x0001_FFFF`).
3. **LED = `0x1`** (`LED_BOOT_SDSPI_INIT`): the bootloader waits for `sd_spi.sv`'s automatic init handshake (CMD0 through CMD58) to finish. This happens without any CPU involvement — `sd_spi.sv` runs its own state machine straight out of reset.
4. If the SD controller reports an error (`REG_STATUS` bit 2): **LED = `0x2`**, halt (spin, rewriting the LED register so a logic analyzer / LED freeze is visibly distinguishable from a hang).
5. **Read LBA 0** (the boot image header) via `CMD17`: the bootloader issues the read, polls busy, then reads 128 words from `REG_BUF_DATA`.
6. **Validate magic**: `header[0]` must equal `0x4D445652` — the four ASCII bytes `R`,`V`,`D`,`M` read as a little-endian `u32` (see `scripts/prepare_sd_image.py`'s header layout). If not: **LED = `0x3`**, halt.
7. **LED = `0x4`** (`LED_BOOT_LOADING`): read `header[2]` (load address), `header[3]` (entry address), `header[4]` (program length), `header[5]` (program's first LBA, always `1`). Compute sector count, then loop: `CMD17` each sequential LBA, copy its 128 words directly into SDRAM at `load_addr + sector_index*512`.
8. **LED = `0x5`** (`LED_BOOT_JUMPING`): call the loaded program as a function pointer at `entry_addr`. This is a real `jalr`, not a simulated transfer — `cpu_core`'s PC genuinely moves into SDRAM-resident code at this point.
9. The loaded program runs its own `crt0` (here, `firmware/startup/crt0.S` — no ROM/RAM split needed since the bootloader already placed its full image, including `.data`'s initial values, directly at the program's linked addresses), clears `.bss`, and calls `main()`.
10. The loaded program interacts with the VGA framebuffer (`0x3000_0000`+) and any other peripheral directly through the same memory map every other milestone's firmware has used.
11. Program exit (if it ever happens): `ecall` → `cpu_core` asserts `halted`/`ecall_seen` and stops fetching, same mechanism used throughout M1-M3.

## Byte-order note (why this mattered)

`sd_spi.sv`'s internal 512-byte block buffer packs received bytes **little-endian** (byte 0 of the sector into bits `[7:0]` of word 0), matching standard RV32 memory layout. An earlier version packed them the opposite way (byte 0 into bits `[31:24]`), which was internally self-consistent and passed its own unit test, but would have byte-reversed every 4 bytes of any program copied from SD into SDRAM via ordinary `sw` instructions. Caught and fixed during M4 design review, before — not after — writing the bootloader; see `docs/verification_report.md`.

## LED status code reference

| Code | Meaning |
|---|---|
| `0x1` | Waiting for SD/SPI init handshake |
| `0x2` | SD/SPI error (no card, bad echo, timeout, not SDHC — see `docs/sdhc_32gb_boot_protocol.md`'s error table for the specific `sd_spi.sv` error code, visible via `REG_STATUS` bits `[7:4]` to a debugger even though the bootloader's own LED code doesn't distinguish them yet) |
| `0x3` | Boot image magic mismatch (corrupted card / wrong image / card not prepared) |
| `0x4` | Loading program into SDRAM |
| `0x5` | Jumping to the loaded program's entry point |
| `0xF` | Loaded program unexpectedly returned to the bootloader (should never happen) |

## What a human watching the board would see (once this is on real hardware)

No VGA output and LEDs frozen at `0x1` → card not responding (check physical insertion, socket, SPI wiring). Frozen at `0x2` → card responded but failed some init step (see the detailed error code via JTAG debug if available). Frozen at `0x3` → card is present and SPI-functional but doesn't have a valid prepared image (re-run `scripts/prepare_sd_image.py` + the write procedure in `docs/sd_card_preparation.md`). Briefly `0x4` then `0x5` then the loaded program's own behavior (VGA output, gameplay) → boot succeeded.
