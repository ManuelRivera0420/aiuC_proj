// M4 end-to-end integration test: real SD boot image (scripts/
// prepare_sd_image.py) -> sdhc_spi_model.sv -> bootloader (ROM, real
// compiled C) -> cpu_core+soc_bus -> SDRAM -> jump to the loaded program
// -> framebuffer writes -> vga.sv scan-out, all through real RTL and real
// compiled firmware. This is the mission's M4 gate: "real SD/bootloader
// startup into SDRAM, basic framebuffer animation driven by RTL-executed
// code."
module m4_e2e_tb;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [3:0]  key_n = 4'hF;
    logic [17:0] sw = 18'd0;
    logic [17:0] ledr;

    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic [3:0]  mem_wstrb;
    logic        mem_valid, mem_ready;
    logic        halted, illegal_instr, ecall_seen;
    logic [31:0] pc_out;

    cpu_core dut_cpu (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_valid(mem_valid), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .halted(halted), .illegal_instr(illegal_instr),
        .ecall_seen(ecall_seen), .ebreak_seen(), .pc_out(pc_out)
    );

    wire [12:0] dram_addr_w;
    wire [1:0]  dram_ba_w;
    wire [31:0] dram_dq_w;
    wire [3:0]  dram_dqm_w;
    wire        dram_ras_n_w, dram_cas_n_w, dram_we_n_w, dram_cs_n_w, dram_cke_w, dram_clk_w;

    wire sd_clk_w, sd_mosi_w, sd_miso_w, sd_cs_n_w;

    logic [16:0] fb_addr_w;
    logic        fb_valid_w;
    logic [23:0] fb_pixel_w;

    soc_bus dut_bus (
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

    sdram_model u_sdram_model (
        .clk(dram_clk_w), .rst_n(rst_n),
        .dram_addr(dram_addr_w), .dram_ba(dram_ba_w), .dram_dq(dram_dq_w), .dram_dqm(dram_dqm_w),
        .dram_ras_n(dram_ras_n_w), .dram_cas_n(dram_cas_n_w), .dram_we_n(dram_we_n_w),
        .dram_cs_n(dram_cs_n_w), .dram_cke(dram_cke_w)
    );

    logic [31:0] cmd_seen_count, last_cmd_index, last_cmd_arg;
    sdhc_spi_model #(.ACMD41_IDLE_RESPONSES(0), .IMAGE_FILE("sim/models/m4_boot.hex"), .IMAGE_BYTES(2048)) u_sd_model (
        .clk(clk), .rst_n(rst_n),
        .sd_clk(sd_clk_w), .sd_mosi(sd_mosi_w), .sd_miso(sd_miso_w), .sd_cs_n(sd_cs_n_w),
        .cmd_seen_count(cmd_seen_count), .last_cmd_index(last_cmd_index), .last_cmd_arg(last_cmd_arg)
    );

    vga u_vga (
        .clk(clk), .rst_n(rst_n),
        .fb_addr(fb_addr_w), .fb_valid(fb_valid_w), .fb_pixel(fb_pixel_w),
        .vga_r(), .vga_g(), .vga_b(), .vga_hs(), .vga_vs(),
        .vga_blank_n(), .vga_sync_n(), .vga_clk()
    );

    integer errors = 0, checks = 0;

    task check_eq(string name, logic [31:0] got, logic [31:0] exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] %-30s got=0x%08h exp=0x%08h", name, got, exp);
        end else begin
            $display("[PASS] %-30s = 0x%08h", name, got);
        end
    endtask

    // Reads back a framebuffer pixel directly from sync_mem's... no: the
    // framebuffer lives in dut_bus.u_framebuffer.mem, a 32-bit word array.
    // Returns pixel pixel_idx's PALETTE INDEX (8-bit), reading it out of
    // framebuffer.sv's 4-pixels-per-word packed storage (pixel_words), per
    // the M5 format revision -- not a full RGB word like M4's original
    // placeholder expected.
    function automatic logic [31:0] fb_word(int pixel_idx);
        logic [31:0] w;
        w = dut_bus.u_framebuffer.pixel_words[pixel_idx >> 2];
        fb_word = {24'd0, w[8 * (pixel_idx[1:0]) +: 8]};
    endfunction

    initial begin
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;

        fork
            begin : watchdog
                repeat (400000) @(negedge clk);
                $display("[FAIL] watchdog expired (cpu halted=%0b pc=0x%08h, sd cmds seen=%0d)",
                          halted, pc_out, cmd_seen_count);
                errors = errors + 1;
                $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
                $display("M4_E2E_TEST_RESULT: FAIL");
                $finish;
            end
            begin : wait_halt
                wait (halted);
            end
        join_any
        disable watchdog;
        disable wait_halt;

        $display("------------------------------------------------------------");
        $display("CPU status: halted=%0b illegal_instr=%0b ecall_seen=%0b pc=0x%08h",
                  halted, illegal_instr, ecall_seen, pc_out);
        check_eq("clean ECALL halt (bit1)", {31'd0, ~illegal_instr}, 32'd1);
        check_eq("ecall_seen", {31'd0, ecall_seen}, 32'd1);

        // 320*0+0=0, 100*320+159=32159, 199*320+319=63999, 50*320+50=16050.
        // Pixel storage now holds the 8-bit PALETTE INDEX (2 = green, set
        // via set_palette(2, 0x00FF00) in firmware/tests/m4_framebuffer_main.c),
        // not a raw RGB word -- see the M5 framebuffer format revision.
        check_eq("pixel(0,0) final index = 2 (green)",     fb_word(0),     32'h00000002);
        check_eq("pixel(159,100) final index = 2 (green)", fb_word(32159), 32'h00000002);
        check_eq("pixel(319,199) final index = 2 (green)", fb_word(63999), 32'h00000002);
        check_eq("pixel(50,50) final index = 2 (green)",   fb_word(16050), 32'h00000002);

        // confirm the NEW integration point -- framebuffer.sv's scan-out
        // port actually wired to vga.sv's live fb_addr/fb_valid outputs,
        // not just the CPU-write side -- by waiting for vga's own h/v
        // counters (already proven correct standalone in vga_tb.sv) to
        // naturally reach pixel(0,0) and checking fb_pixel at that moment.
        // fb_valid_w/fb_addr_w are vga.sv's own outputs here, not
        // testbench-driven -- unlike vga_tb.sv, which drove them directly.
        fork
            begin : scan_watchdog
                repeat (2_000_000) @(posedge clk);
                $display("[FAIL] scan-out watchdog expired waiting for pixel(0,0)");
                errors = errors + 1;
            end
            begin : scan_wait
                wait (u_vga.v_count == 40 && u_vga.h_count == 0);
            end
        join_any
        disable scan_watchdog;
        disable scan_wait;
        #1;
        check_eq("vga scan-out of pixel(0,0) via fb_pixel", {8'd0, fb_pixel_w}, 32'h0000FF00);

        $display("------------------------------------------------------------");
        $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
        if (errors == 0) $display("M4_E2E_TEST_RESULT: PASS");
        else              $display("M4_E2E_TEST_RESULT: FAIL");
        $finish;
    end
endmodule
