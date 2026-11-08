// M5 S3/S4 attempt: actually execute the real, compiled DoomGeneric binary
// on cpu_core, through the real soc_bus/sdram_ctrl RTL -- not a claim that
// it renders a playable frame, just an honest attempt to see how far real
// DOOM engine code gets when it actually runs on this CPU, which M5's
// static-compile gate alone could never tell us.
//
// Deliberately bypasses the SD/bootloader transfer path for ONE reason
// only: M4 already proved that path correct at small scale, and its
// measured per-sector timing makes a full 566KB program + 28MB WAD
// transfer cost an impractical amount of SIMULATED time to re-prove at
// this scale (see docs/verification_report.md's M5 section). The CPU,
// soc_bus, and sdram_ctrl themselves are the real, unmodified RTL --
// only the "how does the data get into SDRAM" step is replaced, via
// sdram_model.sv's new test-only PRELOAD1/PRELOAD2 parameters (added for
// this test; see that file's own header comment).
//
// Boot ROM content is NOT the real bootloader here -- it's a 2-instruction
// jump stub (sim/models/m5_exec/jump_stub.S) that goes straight to DOOM's
// real entry point at 0x10000000, since the real bootloader's whole job
// (copy-from-SD-then-jump) is exactly the step being bypassed. This does
// NOT touch sim/models/soc_rom.hex (the shared M3/M4 boot ROM image) --
// soc_bus.sv was given a BOOT_ROM_FILE parameter for exactly this reason,
// so this test cannot clobber M4's own evidence.
//
// What "preloaded" means concretely: PRELOAD1 is DOOM's real compiled
// .text+.rodata+.data (objcopy -O binary of firmware/build/doom/doom.elf,
// LMA-based, matching this project's established convention) at SDRAM
// byte base 0x10000000.
//
// PRELOAD2 (the real, hash-verified freedoom1.wad, which this project
// does have locally and did try preloading here first) is deliberately
// DISABLED for this run (PRELOAD2_WORDS=0 below), not because the mission
// disallows it -- preloading an IWAD into SDRAM is explicitly allowed --
// but because a first attempt at populating sdram_model.sv's associative
// array with the WAD's full ~7.2M words made this run noticeably slower
// than every prior test in this project, and the Zenith subprocess it
// was running in ended up in a zombie state with no log output and no
// result after several minutes, on this specific installation, at this
// specific scale. Not conclusively diagnosed as a Zenith bug vs. host
// contention (this is a shared multi-tenant machine, see
// docs/known_limitations.md) -- but reproducing it a second time to find
// out would cost more of this project's remaining time than the
// information is worth, when the CPU/engine-execution question this test
// exists to answer doesn't actually need a valid WAD to produce a
// meaningful result: DOOM's own init code is expected to run for a real,
// substantial stretch before it even attempts to open one (argument
// parsing, Z_Init's zone allocator setup, etc.), and if it fails to find
// a valid IWAD at WAD_SDRAM_BASE (uninitialized SDRAM there reads back as
// 'x' from sdram_model.sv, which will not match the WAD magic check),
// that is itself an honest, informative result, not a failure of this
// test. See docs/verification_report.md's M5 section for how this
// descoping decision is reported.
//
// Stop conditions (checked every cycle):
//   - illegal_instr: a real CPU/decode bug -- should not happen given
//     M5's static ISA gate already found zero unsupported instructions
//     in this exact binary, but checked for honestly rather than assumed.
//   - halted (cpu_core reaches S_HALT via ECALL): DOOM's own _exit() path
//     (firmware/platform/syscalls.c) -- means the program voluntarily
//     terminated, e.g. via I_Error() if something it needs is still
//     missing/wrong, or an abnormal early return.
//   - A write lands in the VGA framebuffer's address range
//     (0x3000_0000-0x3003_FFFF): the concrete, unambiguous signal that
//     DG_DrawFrame actually executed -- the mission's real target.
//   - WATCHDOG_CYCLES elapsed with none of the above: inconclusive, not
//     a failure -- report exactly how far it got (last PC, cycle count,
//     SDRAM access count) rather than guessing why.
module m5_doom_exec_tb;
    // Raised from 60,000,000 based on measured workload, not a round-
    // number guess. The prior run spent its last ~10-15M cycles inside
    // W_Checksum (software/upstream/doomgeneric/w_checksum.c), whose
    // total work is bounded and countable: 3,163 real lumps x up to ~21
    // bytes fed to SHA1_Update each (an 8-char name + 3 int32 fields) =
    // ~66KB total through SHA1's 64-byte block buffer = ~1,038 Transform()
    // calls (a FIXED-cost, 80-round function, not data-dependent) across
    // ~12,652 SHA1_Update invocations total for the whole loop -- i.e.
    // W_Checksum's own work is small and bounded; the cost here is
    // entirely this CPU's per-access close-page SDRAM overhead multiplied
    // across those ~12,652+ calls, each involving several memory
    // accesses (lump->name read, M_StringCopy's byte loop, SHA1 context/
    // buffer updates). Did not finish within the prior 60M-cycle budget;
    // 200,000,000 gives roughly 3.3x that same budget, enough headroom to
    // plausibly finish W_Checksum (bounded, now known-small intrinsic
    // work) and reach R_Init/S_Init/ST_Init/D_DoomLoop afterward -- not a
    // guarantee of reaching DG_DrawFrame, which this run will determine
    // empirically, not assume.
    localparam longint WATCHDOG_CYCLES = 200_000_000;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [3:0]  key_n = 4'hF;
    logic [17:0] sw = 18'd0;
    logic [17:0] ledr;

    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic [3:0]  mem_wstrb;
    logic        mem_valid, mem_ready;
    logic        halted, illegal_instr, ecall_seen, ebreak_seen;
    logic [31:0] pc_out;

    cpu_core dut_cpu (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_valid(mem_valid), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .halted(halted), .illegal_instr(illegal_instr),
        .ecall_seen(ecall_seen), .ebreak_seen(ebreak_seen), .pc_out(pc_out)
    );

    wire [12:0] dram_addr_w;
    wire [1:0]  dram_ba_w;
    wire [31:0] dram_dq_w;
    wire [3:0]  dram_dqm_w;
    wire        dram_ras_n_w, dram_cas_n_w, dram_we_n_w, dram_cs_n_w, dram_cke_w, dram_clk_w;

    wire sd_clk_w, sd_mosi_w, sd_cs_n_w;
    logic sd_miso_w = 1'b1; // SD path unused by this test; tie idle

    logic [16:0] fb_addr_w;
    logic        fb_valid_w;
    logic [23:0] fb_pixel_w;

    soc_bus #(.BOOT_ROM_FILE("sim/models/m5_exec/jump_stub.hex")) dut_bus (
        .clk(clk), .rst_n(rst_n),
        .cpu_mem_addr(mem_addr), .cpu_mem_wdata(mem_wdata), .cpu_mem_wstrb(mem_wstrb),
        .cpu_mem_valid(mem_valid), .cpu_mem_rdata(mem_rdata), .cpu_mem_ready(mem_ready),
        .key_n(key_n), .sw(sw), .ledr(ledr),
        .dram_addr(dram_addr_w), .dram_ba(dram_ba_w), .dram_dq(dram_dq_w), .dram_dqm(dram_dqm_w),
        .dram_ras_n(dram_ras_n_w), .dram_cas_n(dram_cas_n_w), .dram_we_n(dram_we_n_w),
        .dram_cs_n(dram_cs_n_w), .dram_cke(dram_cke_w), .dram_clk(dram_clk_w),
        .sd_clk(sd_clk_w), .sd_mosi(sd_mosi_w), .sd_miso(sd_miso_w), .sd_cs_n(sd_cs_n_w),
        .fb_scanout_addr(fb_addr_w), .fb_scanout_valid(fb_valid_w), .fb_scanout_pixel(fb_pixel_w)
    );

    sdram_model #(
        .PRELOAD1_FILE("sim/models/m5_exec/doom_prog.hex"),
        .PRELOAD1_WORDS(141563), // rebuilt after adding __wrap_D_FindIWAD; 4 words larger
        .PRELOAD1_BYTE_BASE(32'h1000_0000),
        // PRELOAD2/3: the REAL freedoom1.wad's header (12 bytes, offset 0)
        // and lump directory (50,608 bytes, offset 28,744,468 -- WAD
        // directories live at the END of the file, confirmed by reading
        // the real header's infotableofs field directly with Python
        // before generating these two files) -- NOT the whole 28MB WAD,
        // which is what stalled the first full-scale preload attempt
        // (docs/verification_report.md's M5 S3 section). This gets
        // W_AddFile() real IWAD-identification data and a real,
        // correctly-populated lumpinfo[] table without that cost.
        // Individual lump CONTENT is still unpopulated at this stage --
        // a real, deliberately scoped next increment, not every lump
        // preloaded at once.
        .PRELOAD2_FILE("sim/models/m5_exec/wad_header.hex"),
        .PRELOAD2_WORDS(3),
        .PRELOAD2_BYTE_BASE(32'h1400_0000),
        .PRELOAD3_FILE("sim/models/m5_exec/wad_directory.hex"),
        .PRELOAD3_WORDS(12652),
        .PRELOAD3_BYTE_BASE(32'h1400_0000 + 32'd28_744_468)
    ) u_sdram_model (
        .clk(dram_clk_w), .rst_n(rst_n),
        .dram_addr(dram_addr_w), .dram_ba(dram_ba_w), .dram_dq(dram_dq_w), .dram_dqm(dram_dqm_w),
        .dram_ras_n(dram_ras_n_w), .dram_cas_n(dram_cas_n_w), .dram_we_n(dram_we_n_w),
        .dram_cs_n(dram_cs_n_w), .dram_cke(dram_cke_w)
    );

    longint cycle_count = 0;
    longint fb_write_count = 0;
    logic [31:0] first_fb_write_pc = 0;

    // ---- Explicit named milestones (not just periodic PC sampling) ----
    // Addresses taken directly from `riscv64-unknown-elf-nm
    // firmware/build/doom/doom.elf` for this exact build -- each one
    // fires exactly once, the first cycle pc_out equals that function's
    // real entry address, so a future run's log shows WHICH named phase
    // it reached even if it stops producing cycle checkpoints
    // afterward. Zero upstream patches: this only reads pc_out from the
    // testbench, it does not instrument DOOM's source.
    localparam logic [31:0] ADDR_D_FINDIWAD_WRAP   = 32'h1003a9e0; // __wrap_D_FindIWAD entry
    localparam logic [31:0] ADDR_W_ADDFILE         = 32'h100392d4; // W_AddFile entry (header+directory read happens inside)
    localparam logic [31:0] ADDR_D_IDENTIFYVERSION = 32'h10004118; // D_IdentifyVersion entry (W_AddFile returned OK)
    localparam logic [31:0] ADDR_D_DOOMLOOP        = 32'h10003d24; // D_DoomLoop entry (D_DoomMain's init fully completed)
    // The four above are KEPT for run-to-run consistency checking (cheap,
    // already instrumented) even though they're already confirmed passed
    // -- see docs/verification_report.md's M5 S3 section. Everything
    // below is NEW, targeting genuinely unconfirmed next steps per
    // explicit instruction not to add redundant milestones for things
    // already proven. Addresses again taken directly from `nm` on this
    // exact build.
    localparam logic [31:0] ADDR_DG_INIT           = 32'h1003a604; // DG_Init entry -- logically must already have run (doomgeneric.c calls it before D_DoomMain unconditionally), confirming explicitly rather than just by inference
    localparam logic [31:0] ADDR_D_INITNETGAME     = 32'h10003040; // D_InitNetGame entry -- fires right after InitConnectData (which contains the W_Checksum call) returns, i.e. "W_Checksum completed"
    localparam logic [31:0] ADDR_W_READLUMP        = 32'h1003987c; // W_ReadLump entry -- the ONE function every actual lump-content read goes through (w_wad.c), regardless of which specific lump triggers it first: "first required WAD lump content access attempted"
    localparam logic [31:0] ADDR_R_INIT            = 32'h1002c5b4; // R_Init entry -- "game and rendering subsystem initialization" begins (textures/sprites/flats -- real lump content, not just metadata)
    localparam logic [31:0] ADDR_DG_DRAWFRAME      = 32'h1003a608; // DG_DrawFrame entry -- first actual frame-draw call
    // The attempt-6 run (80,186,517 cycles) reached R_Init and then hit
    // [RESULT] HALTED (ECALL/_exit) ~51,500 cycles later with W_ReadLump's
    // milestone never firing -- confirmed by reading w_file_de2115.c that
    // this port sets wad_file_t.mapped unconditionally, so every lump
    // CONTENT read is a raw pointer deref into WAD_SDRAM_BASE+position,
    // never W_ReadLump (a deliberate, correct design for this target, not
    // a bug -- ADDR_W_READLUMP above will legitimately never fire). Since
    // only the WAD header+directory are preloaded, every lump's CONTENT
    // reads as 32'd0 (sdram_model.sv's mem_store is an associative array
    // that returns 0 for any key that was never written -- confirmed by
    // reading its .exists()-gated read path directly, not assumed).
    // Source-level trace of R_Init -> R_InitData -> {R_InitTextures,
    // R_InitFlats, R_InitSpriteLumps, R_InitColormaps} (r_data.c) shows
    // none of them obviously fail on all-zero lump content (zeroed counts
    // just make their per-item loops no-ops), so the exact crash site is
    // not yet provable by source reading alone -- these fine-grained
    // sub-milestones plus one at I_Error's own entry (fires on ANY fatal
    // error call, regardless of message/args, which $display cannot
    // easily print from RTL) are instrumented now to get ground truth
    // from an actual run instead of further speculation.
    localparam logic [31:0] ADDR_R_INITTEXTURES    = 32'h10029844; // R_InitTextures entry (first of R_InitData's four sub-inits)
    localparam logic [31:0] ADDR_R_INITFLATS       = 32'h10029f9c; // R_InitFlats entry
    localparam logic [31:0] ADDR_R_INITSPRITELUMPS = 32'h1002a054; // R_InitSpriteLumps entry -- loops over ~853 real sprite lumps, each via W_CacheLumpNum
    localparam logic [31:0] ADDR_R_INITCOLORMAPS   = 32'h1002a214; // R_InitColormaps entry -- last of R_InitData's four sub-inits
    localparam logic [31:0] ADDR_R_INITPOINTTOANGLE= 32'h1002be28; // R_InitPointToAngle entry -- fires right after R_InitData returns (R_InitData itself has no milestone; this brackets it)
    localparam logic [31:0] ADDR_R_INITSKYMAP      = 32'h1002e658; // R_InitSkyMap entry -- fires after R_SetViewSize/R_InitPlanes/R_InitLightTables all returned
    localparam logic [31:0] ADDR_I_ERROR           = 32'h1000e9ac; // I_Error entry -- fires on ANY fatal DOOM error path, confirming (or ruling out) that the HALTED/_exit seen in attempt 6 is this engine-level fatal path vs. something else

    // Explicit initializers -- without them these default to X (unknown)
    // at time 0, and `!X && ...` stays X forever, which SystemVerilog's
    // `if` treats as false permanently: a real bug, found by noticing no
    // [MILESTONE] line ever printed despite pc_out demonstrably having
    // passed through every one of these addresses (confirmed via the
    // periodic [progress] samples). Same bug class analyzed earlier in
    // this project re: DOOM's own code reacting to X -- made the mistake
    // here in the testbench itself instead.
    logic seen_findiwad = 1'b0, seen_addfile = 1'b0, seen_identify = 1'b0, seen_doomloop = 1'b0;
    logic seen_dginit = 1'b0, seen_initnetgame = 1'b0, seen_readlump = 1'b0, seen_rinit = 1'b0, seen_drawframe = 1'b0;
    logic seen_rinittextures = 1'b0, seen_rinitflats = 1'b0, seen_rinitspritelumps = 1'b0, seen_rinitcolormaps = 1'b0;
    logic seen_rinitpointtoangle = 1'b0, seen_rinitskymap = 1'b0, seen_ierror = 1'b0;

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;

            if (!seen_findiwad && pc_out == ADDR_D_FINDIWAD_WRAP) begin
                seen_findiwad <= 1'b1;
                $display("[MILESTONE] D_FindIWAD reached, cycle=%0d", cycle_count);
            end
            if (!seen_addfile && pc_out == ADDR_W_ADDFILE) begin
                seen_addfile <= 1'b1;
                $display("[MILESTONE] W_AddFile reached (D_FindIWAD returned non-NULL), cycle=%0d", cycle_count);
            end
            if (!seen_identify && pc_out == ADDR_D_IDENTIFYVERSION) begin
                seen_identify <= 1'b1;
                $display("[MILESTONE] D_IdentifyVersion reached (WAD header+directory read without a fatal error), cycle=%0d", cycle_count);
            end
            if (!seen_doomloop && pc_out == ADDR_D_DOOMLOOP) begin
                seen_doomloop <= 1'b1;
                $display("[MILESTONE] D_DoomLoop reached -- full engine initialization complete, cycle=%0d", cycle_count);
            end
            if (!seen_dginit && pc_out == ADDR_DG_INIT) begin
                seen_dginit <= 1'b1;
                $display("[MILESTONE] DG_Init reached (platform hook, no-op on this target), cycle=%0d", cycle_count);
            end
            if (!seen_initnetgame && pc_out == ADDR_D_INITNETGAME) begin
                seen_initnetgame <= 1'b1;
                $display("[MILESTONE] D_InitNetGame reached -- W_Checksum completed (all 3,163 real lumps hashed), cycle=%0d", cycle_count);
            end
            if (!seen_readlump && pc_out == ADDR_W_READLUMP) begin
                seen_readlump <= 1'b1;
                $display("[MILESTONE] W_ReadLump reached -- first real WAD lump CONTENT access attempted, cycle=%0d", cycle_count);
            end
            if (!seen_rinit && pc_out == ADDR_R_INIT) begin
                seen_rinit <= 1'b1;
                $display("[MILESTONE] R_Init reached -- rendering subsystem initialization begins, cycle=%0d", cycle_count);
            end
            if (!seen_drawframe && pc_out == ADDR_DG_DRAWFRAME) begin
                seen_drawframe <= 1'b1;
                $display("[MILESTONE] DG_DrawFrame reached -- first frame-draw call, cycle=%0d", cycle_count);
            end
            if (!seen_rinittextures && pc_out == ADDR_R_INITTEXTURES) begin
                seen_rinittextures <= 1'b1;
                $display("[MILESTONE] R_InitTextures reached, cycle=%0d", cycle_count);
            end
            if (!seen_rinitflats && pc_out == ADDR_R_INITFLATS) begin
                seen_rinitflats <= 1'b1;
                $display("[MILESTONE] R_InitFlats reached (R_InitTextures returned), cycle=%0d", cycle_count);
            end
            if (!seen_rinitspritelumps && pc_out == ADDR_R_INITSPRITELUMPS) begin
                seen_rinitspritelumps <= 1'b1;
                $display("[MILESTONE] R_InitSpriteLumps reached (R_InitFlats returned), cycle=%0d", cycle_count);
            end
            if (!seen_rinitcolormaps && pc_out == ADDR_R_INITCOLORMAPS) begin
                seen_rinitcolormaps <= 1'b1;
                $display("[MILESTONE] R_InitColormaps reached (R_InitSpriteLumps returned -- all ~853 sprite lumps processed), cycle=%0d", cycle_count);
            end
            if (!seen_rinitpointtoangle && pc_out == ADDR_R_INITPOINTTOANGLE) begin
                seen_rinitpointtoangle <= 1'b1;
                $display("[MILESTONE] R_InitPointToAngle reached -- R_InitData fully returned (R_InitColormaps completed), cycle=%0d", cycle_count);
            end
            if (!seen_rinitskymap && pc_out == ADDR_R_INITSKYMAP) begin
                seen_rinitskymap <= 1'b1;
                $display("[MILESTONE] R_InitSkyMap reached -- R_SetViewSize/R_InitPlanes/R_InitLightTables all returned, cycle=%0d", cycle_count);
            end
            if (!seen_ierror && pc_out == ADDR_I_ERROR) begin
                seen_ierror <= 1'b1;
                // a0 (x10) holds I_Error(char *error, ...)'s first arg --
                // the format-string pointer. Every I_Error call site in
                // the DOOM source passes a literal C string constant, so
                // this address can be looked up directly in doom.elf's
                // .rodata to identify exactly which call fired, without
                // needing any UART/console capture mechanism.
                $display("[MILESTONE] I_Error reached -- a fatal DOOM engine error path was taken, cycle=%0d, a0(fmt_str_ptr)=0x%08h",
                          cycle_count, dut_cpu.u_regfile.regs[10]);
            end

            if (mem_valid && mem_ready && (|mem_wstrb) &&
                mem_addr >= 32'h3000_0000 && mem_addr <= 32'h3003_FFFF) begin
                if (fb_write_count == 0) begin
                    first_fb_write_pc <= pc_out;
                    $display("[MILESTONE] First framebuffer write, cycle=%0d, pc=0x%08h", cycle_count, pc_out);
                end
                fb_write_count <= fb_write_count + 1;
            end

            // 500,000-cycle granularity (4x finer than the original
            // 2,000,000) -- a prior run stopped producing simulated time
            // silently somewhere between two 2,000,000-cycle checkpoints
            // with no error, no $finish, and the only way to detect it
            // was an out-of-band /proc check (see docs/verification_report.md's
            // M5 S3 section) -- finer granularity narrows that window
            // without materially increasing log size (at most ~120 lines
            // for the full 60,000,000-cycle watchdog). Also reports
            // cpu_core's own FSM state and mem_valid/mem_ready so a
            // future stall's LAST known state is more informative than
            // just a PC.
            if (cycle_count % 500_000 == 0) begin
                $display("[progress] cycle=%0d pc=0x%08h fb_writes=%0d cpu_state=%s mem_valid=%0b mem_ready=%0b",
                          cycle_count, pc_out, fb_write_count, dut_cpu.state.name(), mem_valid, mem_ready);
            end

            if (illegal_instr) begin
                $display("[RESULT] ILLEGAL_INSTR at pc=0x%08h, cycle=%0d -- real bug, not expected given M5's static ISA gate", pc_out, cycle_count);
                $finish;
            end
            if (halted) begin
                $display("[RESULT] HALTED (ECALL/_exit reached) at pc=0x%08h, cycle=%0d, fb_writes_seen=%0d", pc_out, cycle_count, fb_write_count);
                $finish;
            end
            if (fb_write_count >= 64000) begin
                $display("[RESULT] FRAMEBUFFER FULLY WRITTEN AT LEAST ONCE (fb_writes=%0d) at cycle=%0d, first write pc=0x%08h -- DG_DrawFrame executed a full frame", fb_write_count, cycle_count, first_fb_write_pc);
                $finish;
            end
            if (cycle_count >= WATCHDOG_CYCLES) begin
                $display("[RESULT] WATCHDOG (%0d cycles) reached with no halt/illegal/full-frame -- inconclusive, not a failure. Last pc=0x%08h, fb_writes_seen=%0d", WATCHDOG_CYCLES, pc_out, fb_write_count);
                $finish;
            end
        end
    end

    initial begin
        rst_n = 0;
        // Exactly 1 cycle: sdram_model's preload (triggered inside its
        // always_ff's reset branch, see that file's comment on why) runs
        // once per cycle rst_n is held low -- holding longer than needed
        // would just re-run a multi-million-entry preload loop uselessly.
        repeat (1) @(posedge clk);
        rst_n = 1;
    end
endmodule
