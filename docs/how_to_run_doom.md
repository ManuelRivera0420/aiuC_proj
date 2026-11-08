# How to Run DOOM on This Board — Operator Guide (M6)

This is step-by-step instructions for the specific DOOM path, written for whoever picks up hardware bring-up after `docs/fpga_handoff.md`'s general build order. Read that document's §4 first if you haven't — this guide assumes you already know the headline fact: **DOOM compiles and links perfectly for this CPU, and a direct-SDRAM-preload test has now actually executed real, compiled DOOM engine code on `cpu_core` (see `docs/verification_report.md`'s M5 S3 section for exactly how far) — but it has never been exercised through the real SD/bootloader path or on physical hardware.** Nothing below pretends otherwise.

## The bootloader now copies the WAD too

`firmware/bootloader/bootloader_main.c` originally only copied the program from the SD image into SDRAM, never the WAD, even though the boot image format already had the fields for it (`scripts/prepare_sd_image.py`'s `wad_lba_start`/`wad_length`). This has since been extended: `main()` now reads `header[6]`/`header[7]` and, if `wad_lba_start` is nonzero, copies the WAD into `WAD_SDRAM_BASE` (`0x1400_0000` — matching `software/doom_port/w_file_de2115.c`) the same way it already copied the program, with a new `LED_BOOT_LOADING_WAD` (`0x6`) status code while it does (see `docs/boot_process.md`). Boot images built without `--wad` (every image built before this change existed) have `wad_lba_start=0`, so this step is a no-op for them — existing behavior is unchanged.

**Not yet re-verified through `sim/tb/m4_e2e_tb.sv`** with this new code path exercised (that test's boot image has no WAD, so it only exercises the no-op branch) — worth doing before trusting this on hardware, though the change is small and additive enough that it's a reasonable risk to proceed past.

## Step 1: build the DOOM binary

```
scripts/build_doom.sh
```

Produces `firmware/build/doom/<name>.elf` (last confirmed: 792,874 bytes, `.text=504420 .data=61810 .bss=244644`). Confirm the ISA gate still holds before going further — this project's own check, repeatable by anyone:

```
riscv64-unknown-elf-readelf -A firmware/build/doom/<name>.elf | grep Tag_RISCV_arch
# expect: rv32i2p1_m2p0_zmmul1p0 -- plain RV32IM, nothing else
riscv64-unknown-elf-objdump -d firmware/build/doom/<name>.elf | grep -iE '\b(fmadd|fadd|amoswap|lr\.w|sc\.w|vsetvli|c\.)\b'
# expect: no output at all
```

## Step 2: get a Freedoom WAD

This project vendors DoomGeneric's source but, consistent with upstream's own licensing split, does **not** commit the Freedoom WAD itself (GPL-2.0 engine vs. BSD-style Freedoom data, each with its own distribution terms — see `software/source-lock.json` for exact versions/hashes already pinned: Freedoom 0.13.0). Obtain `freedoom1.wad` (or `freedoom2.wad`) yourself and verify it against the hash already recorded in `software/source-lock.json` before using it, so you know you're running what this project was actually built and reasoned against.

## Step 3: build the SD boot image, including the WAD

```
objcopy -O binary firmware/build/doom/<name>.elf firmware/build/doom/<name>.bin
python3 scripts/prepare_sd_image.py \
    --program firmware/build/doom/<name>.bin \
    --wad /path/to/freedoom1.wad \
    --load-addr 0x10000000 \
    --entry-addr <entry address from readelf -h, e_entry field> \
    --out sd_image.bin \
    --manifest sd_image_manifest.json
```

Double-check `--load-addr`/`--entry-addr` against `firmware/linker/de2_115_soc.ld`'s actual SDRAM base and the ELF's real entry point rather than copying the numbers above blindly — `objcopy -O binary` uses each section's LMA, not VMA, which already bit this project once during M4/M5 (see `docs/verification_report.md`); don't re-learn that the hard way on hardware.

Write `sd_image.bin` to the physical SD card as a raw image (`dd` or equivalent) starting at LBA 0 — this is a raw sector layout, not a filesystem; do not format the card or create a partition table first. `scripts/verify_sd_image.py` can sanity-check the image file itself (magic, lengths, hash) before you write it to the card.

## Step 4: program the board and watch the LEDs

Boot should proceed through the LED status codes defined in `firmware/bootloader/bootloader_main.c` / documented in `docs/boot_process.md` (`LED_BOOT_SDSPI_INIT` → `LED_BOOT_LOADING` → `LED_BOOT_LOADING_WAD` → `LED_BOOT_JUMPING`, or a `_ERROR`/`_BAD_MAGIC` code if something's wrong before that). Getting to `LED_BOOT_JUMPING` means the SD read path, the program copy, and the WAD copy all worked — this itself is new, real information the first time you run it, since M4's simulation only ever exercised a ~200-byte test program, not an 800KB+ real binary plus a 28MB WAD, through the live SD timing.

**Be ready for this to simply not work on the first attempt.** Nothing from here on has been exercised against real SPI electrical timing, a real SD card's actual response latencies, or this specific DOOM binary's actual runtime behavior on `cpu_core` — only against `sim/models/sdhc_spi_model.sv`'s idealized SPI slave and, for every *other* firmware tested in this project, much smaller programs. If it hangs at `LED_BOOT_LOADING`, suspect the SPI clock divider (`rtl/peripherals/sd_spi.sv`'s `FAST_CLK_DIV=4`, flagged in `docs/fpga_handoff.md` §2 as never validated against real card timing) before suspecting the RTL logic itself, which has passed every simulation test this project could devise.

## Step 5: once it boots — what to expect, and what to check if it doesn't render correctly

If execution reaches DOOM's own code, VGA output should show whatever `doomgeneric_de2115.c`'s `DG_DrawFrame` produces via `rtl/peripherals/framebuffer.sv` each frame. Controls, per the mission's locked mapping (implemented in `software/doom_port/doomgeneric_de2115.c`):

| Input | Function |
|---|---|
| `SW[0:3]` | movement/strafe (level-sensitive) |
| `KEY[1]`/`KEY[2]` | turn left/right (held) |
| `KEY[3]` | fire (held) |
| `SW[4]` (edge) | use |
| `SW[5]` (edge) | next weapon — mapped to `'2'`, since vanilla DOOM has no dedicated "next weapon" key (documented simplification) |
| `SW[6]` (edge) | menu toggle |
| `SW[7]` (edge) | menu select |

If the image appears but looks wrong (garbled colors, static single frame, visible single-pixel flicker): check `docs/clock_reset_cdc.md` §3 first — the framebuffer's scan-out read is a genuine, documented clock-domain-crossing simplification (combinational `pclk`-domain read against `clk`-domain-written BRAM, no synchronizer) that this project's simulation structurally cannot exercise the same way real dual-port M9K hardware will. A single-pixel, single-frame glitch is the expected worst case of that specific issue, not a sign of a deeper bug — but total garbage or a persistently wrong image points elsewhere (check palette writes are actually landing — `DG_DrawFrame`'s palette-change path, `docs/verification_report.md`'s M5 framebuffer-reformat section — before suspecting VGA timing, which was independently verified standalone).

## What "done" looks like, and what this guide does not promise

This guide gets you to the point where, if every unverified assumption above holds, DOOM should run. It is deliberately not written as "connect these wires and DOOM plays" — that claim would not be backed by anything this project actually ran, which is the one thing the mission that produced this project was most insistent on never doing. The honest status, repeated from `docs/fpga_handoff.md`: RV32IM CPU, firmware boot, all peripherals, and the full SD-boot pipeline are simulation-verified end to end; the real DOOM binary is confirmed instruction-set-compatible and nothing more.
