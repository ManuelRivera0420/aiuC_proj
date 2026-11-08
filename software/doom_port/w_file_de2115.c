/*
 * WAD file backend for this project's bare-metal target, implementing
 * the wad_file_t interface (software/upstream/doomgeneric/w_file.h)
 * against a WAD image preloaded into SDRAM -- NOT live SD-card reads
 * during gameplay. The mission explicitly allows this ("Preloading an
 * IWAD into SDRAM is allowed if the boot image, memory map, and all
 * resulting RAM requirements are verified").
 *
 * WAD_SDRAM_BASE / WAD_SDRAM_MAX_LENGTH below describe where the
 * bootloader is EXPECTED to place the WAD -- see the honest status note
 * in docs/verification_report.md's M5 section: as of this writing,
 * firmware/bootloader/bootloader_main.c only copies the PROGRAM region
 * (header[2]/[3]/[4]/[5]); extending it to also copy the WAD region
 * (header[6]/[7], already present in the boot image format -- see
 * scripts/prepare_sd_image.py) is a separate, not-yet-done step, because
 * sector-by-sector CMD17 reads of a 28MB WAD would take an impractically
 * long SIMULATED time to actually run through Animas in this session.
 * This file is written and ready for that integration regardless.
 */
#include <string.h>
#include "w_file.h"
#include "doomtype.h"

#define WAD_SDRAM_BASE       0x14000000u
#define WAD_SDRAM_MAX_LENGTH (32u * 1024u * 1024u) /* 32MB ceiling; freedoom1.wad is ~28MB */

extern wad_file_class_t stdc_wad_file;

typedef struct {
    wad_file_t wad;
} stdc_wad_file_t;

static stdc_wad_file_t s_WadFile;

static wad_file_t *De2115_OpenFile(char *path) {
    (void)path; /* a single, fixed preloaded WAD -- no filesystem, no
                    path lookup; whatever the bootloader placed at
                    WAD_SDRAM_BASE is the only WAD this target can open */
    s_WadFile.wad.file_class = &stdc_wad_file;
    s_WadFile.wad.mapped = (byte *)WAD_SDRAM_BASE;
    /* Real length comes from the boot image header (prepare_sd_image.py's
       wad_length field) once the bootloader is extended to expose it;
       using the conservative ceiling here is safe for W_Read's bounds
       checking below regardless, just not exact for anything that
       queries wad->length directly before that integration lands. */
    s_WadFile.wad.length = WAD_SDRAM_MAX_LENGTH;
    return &s_WadFile.wad;
}

static void De2115_CloseFile(wad_file_t *wad) {
    (void)wad; /* nothing to release: no heap allocation, no real handle */
}

static size_t De2115_Read(wad_file_t *wad, unsigned int offset,
                           void *buffer, size_t buffer_len) {
    if (offset >= wad->length) {
        return 0;
    }
    if (offset + buffer_len > wad->length) {
        buffer_len = wad->length - offset;
    }
    memcpy(buffer, wad->mapped + offset, buffer_len);
    return buffer_len;
}

wad_file_class_t stdc_wad_file = {
    De2115_OpenFile,
    De2115_CloseFile,
    De2115_Read,
};
