// M5 S3: fast, focused check of sdram_model.sv's PRELOAD2 (WAD header)
// and PRELOAD3 (WAD lump directory) regions, through the REAL memory
// path (cpu_core -> soc_bus -> sdram_ctrl -> sdram_model) -- not a
// DoomGeneric run. See firmware/tests/m5_wad_preload_check_main.c's own
// header for exactly what it checks and why this exists: to catch a
// WAD-preload/addressing bug in a few hundred cycles instead of needing
// DOOM's ~10,000,000+-cycle startup first.
module m5_wad_preload_check_tb;
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
    logic sd_miso_w = 1'b1;

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
        .PRELOAD1_FILE("sim/models/m5_exec/wad_check_prog.hex"),
        .PRELOAD1_WORDS(47),
        .PRELOAD1_BYTE_BASE(32'h1000_0000),
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

    localparam int WATCHDOG_CYCLES = 20_000;
    int cycle_count = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            if (halted) begin
                if (ledr == 18'h1) begin
                    $display("[PASS] WAD header+directory readable via the real memory path, cycle=%0d, pc=0x%08h", cycle_count, pc_out);
                    $display("M5_WAD_PRELOAD_CHECK_RESULT: PASS");
                end else begin
                    $display("[FAIL] WAD preload/addressing check failed (ledr=0x%05h), cycle=%0d, pc=0x%08h", ledr, cycle_count, pc_out);
                    $display("M5_WAD_PRELOAD_CHECK_RESULT: FAIL");
                end
                $finish;
            end
            if (illegal_instr) begin
                $display("[FAIL] illegal_instr at pc=0x%08h, cycle=%0d", pc_out, cycle_count);
                $display("M5_WAD_PRELOAD_CHECK_RESULT: FAIL");
                $finish;
            end
            if (cycle_count >= WATCHDOG_CYCLES) begin
                $display("[FAIL] watchdog (%0d cycles) -- never halted. pc=0x%08h", WATCHDOG_CYCLES, pc_out);
                $display("M5_WAD_PRELOAD_CHECK_RESULT: FAIL");
                $finish;
            end
        end
    end

    initial begin
        rst_n = 0;
        repeat (1) @(posedge clk);
        rst_n = 1;
    end
endmodule
