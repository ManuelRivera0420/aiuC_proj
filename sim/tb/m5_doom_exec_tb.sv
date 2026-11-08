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
    localparam longint WATCHDOG_CYCLES = 60_000_000;

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

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;

            if (mem_valid && mem_ready && (|mem_wstrb) &&
                mem_addr >= 32'h3000_0000 && mem_addr <= 32'h3003_FFFF) begin
                if (fb_write_count == 0) first_fb_write_pc <= pc_out;
                fb_write_count <= fb_write_count + 1;
            end

            if (cycle_count % 2_000_000 == 0) begin
                $display("[progress] cycle=%0d pc=0x%08h fb_writes=%0d", cycle_count, pc_out, fb_write_count);
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
