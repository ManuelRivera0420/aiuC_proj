# SD Card Preparation Guide (Human Team — Physical Write Procedure)

Target: **ADATA Premier 32 GB microSDHC UHS-I Class 10 (`AUSDH32GUICL10-RA1`)**, used via its bundled full-size SD adapter.

**Claude does not and cannot perform the physical write** — this document is instructions for the human team. No raw-disk write has been executed by this project; only image *preparation* (`prepare_sd_image.py`) and *simulation-side* verification (`sd_spi_tb.sv` against a behavioral model) have been done.

## What you are about to do, in plain terms

You will write a small (likely well under 1 MB) **raw binary image** directly onto the SD card's physical sectors, starting at the very first sector. This is **not** a filesystem copy — there is deliberately no FAT32 on this card for the boot image. **A raw sector write will destroy any existing partition table, filesystem, and files on the card.** Use a card you don't mind erasing, or back up its contents first with a normal file copy if it currently holds anything you want to keep.

## Step 1 — Build the image (safe, does not touch any disk)

```bash
source scripts/riscv_env.sh   # if the program needs compiling first
python3 scripts/prepare_sd_image.py \
    --program path/to/firmware.bin \
    --wad path/to/freedoom1.wad \
    --load-addr 0x10000000 --entry-addr 0x10000000 \
    --out boot_image.img \
    --manifest boot_image.manifest.json
python3 scripts/verify_sd_image.py boot_image.img --manifest boot_image.manifest.json
```

The verify step must print `PASS` before you go any further. If it doesn't, do not write the card — fix the image first.

## Step 2 — Identify the card device path (Linux example)

**Do this carefully. Writing to the wrong device will destroy that device's contents.**

```bash
lsblk    # before inserting the card
# insert the ADATA card (in its full-size adapter) into your computer's reader
lsblk    # after inserting -- note the NEW device that appeared, e.g. /dev/sdX
```

Confirm the new device's reported **size matches a 32 GB card** (roughly 29.8 GiB usable) before proceeding — this is your main defense against targeting the wrong disk. Never use a device path you aren't certain about.

## Step 3 — Write only the sectors the image occupies

There is no need to write all 32 GB — only the image's own length:

```bash
sync
sudo dd if=boot_image.img of=/dev/sdX bs=512 conv=fsync status=progress
sync
```

Replace `/dev/sdX` with the exact device path confirmed in Step 2. Do **not** use `/dev/sdX1` or any partition suffix — this is a raw, partition-less image starting at sector 0.

## Step 4 — Read back and verify

```bash
sudo dd if=/dev/sdX of=readback.img bs=512 count=$(( $(stat -c%s boot_image.img) / 512 ))
cmp boot_image.img readback.img && echo "READBACK OK"
python3 scripts/verify_sd_image.py readback.img --manifest boot_image.manifest.json
```

Both the `cmp` and the `verify_sd_image.py` run on the read-back copy must pass.

## Recovery: putting a normal filesystem back on the card afterward

Once you're done with this card for boot-image purposes, a standard reformat restores ordinary use:

```bash
sudo wipefs -a /dev/sdX
sudo mkfs.exfat /dev/sdX      # or mkfs.vfat, mkfs.ext4, etc. as you prefer
```

## Inserting into the DE2-115

Insert the ADATA microSDHC card into its bundled full-size adapter, then insert the adapter into the DE2-115's onboard SD socket. No separate card-reader module, no PS/2 or USB device, is involved — this is the integrated socket documented in the manual's Table 4-31 / Section 4.19.

## What this project has NOT verified

- Physical SPI-mode electrical/timing compatibility of this specific card with the DE2-115 socket — the manual documents the socket and generically supports SPI mode, but lab compatibility of this exact model is a human-team bring-up step, not something simulation can confirm.
- Read speed at the controller's post-init clock divider (`FAST_CLK_DIV`, currently a conservative ~12.5MHz default) against the real card and real board trace lengths — retune after measuring on hardware.
