// DE2-115 board-level top module. Every port name/width here matches
// docs/pin_assignments.csv exactly (cross-checked by scripts/pin_audit.py,
// extended in M6 to parse this file) and traces to a specific manual
// table/PDF page recorded there, independently verified against the real
// manual text in M0 (see docs/board_resource_selection.md).
//
// NOT run through Quartus synthesis/fitting/timing by this project --
// that is explicitly the human team's responsibility (see
// docs/fpga_handoff.md). This file is prepared for that handoff, not a
// claim that it has been synthesized.
//
// KEY[0] is both the physical reset button AND is read by the GPIO
// controller like the other KEY bits (key_sw_gpio.sv masks bit 0 out of
// its KEY_STATUS register internally, rather than this top level needing
// to do anything special) -- KEY is active-low on this board, which
// conveniently matches this design's active-low rst_n convention exactly:
// pressing KEY[0] drives it to 0, which IS the reset-active level, with
// no inversion needed.
//
// SD_DAT[1]/SD_DAT[2] are unused in SPI mode (sd_spi.sv only drives
// SD_DAT[3] as CS_N and reads SD_DAT[0] as MISO) and are left tri-stated
// here rather than driven to an arbitrary level, per the mission's
// instruction to define safe unused-pin handling explicitly.
//
// VGA pixel clock: vga.sv internally divides CLOCK_50 by 2 (behavioral,
// already verified in simulation -- sim/tb/vga_tb.sv, 29/29 PASS). This
// is NOT a clean, low-jitter PLL-generated clock; it is adequate for a
// first bring-up but the mission recommends a PLL megafunction for
// production quality. That substitution is a human-team Quartus IP step
// (docs/fpga_handoff.md), not something this RTL can validate itself.
module de2_115_top (
    input  logic        CLOCK_50,

    input  logic [3:0]  KEY,
    input  logic [17:0] SW,
    output logic [17:0] LEDR,

    output logic        VGA_CLK,
    output logic        VGA_HS,
    output logic        VGA_VS,
    output logic        VGA_BLANK_N,
    output logic        VGA_SYNC_N,
    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,

    output logic [12:0] DRAM_ADDR,
    output logic [1:0]  DRAM_BA,
    inout  wire  [31:0] DRAM_DQ,
    output logic [3:0]  DRAM_DQM,
    output logic        DRAM_RAS_N,
    output logic        DRAM_CAS_N,
    output logic        DRAM_WE_N,
    output logic        DRAM_CS_N,
    output logic        DRAM_CKE,
    output logic        DRAM_CLK,

    output logic        SD_CLK,
    output logic        SD_CMD,
    inout  wire  [3:0]  SD_DAT,
    output logic        SD_WP_N
);
    logic rst_n;
    assign rst_n = KEY[0];

    // SD_WP_N (write-protect sense) is not read by sd_spi.sv in this
    // design (documented simplification, docs/sdhc_32gb_boot_protocol.md);
    // drive it as an input-only sense line by not driving it from the FPGA.
    assign SD_WP_N = 1'bz;

    // SD_DAT[1:2]: unused in SPI mode, tri-stated (not driven) rather than
    // forced to an arbitrary level.
    assign SD_DAT[1] = 1'bz;
    assign SD_DAT[2] = 1'bz;

    logic sd_mosi_w, sd_cs_n_w, sd_clk_w;
    logic sd_miso_w;
    assign SD_CLK   = sd_clk_w;
    assign SD_CMD   = sd_mosi_w;
    assign SD_DAT[3] = sd_cs_n_w;
    assign SD_DAT[0] = 1'bz; // MISO is an input; never drive it
    assign sd_miso_w = SD_DAT[0];

    logic [31:0] cpu_mem_addr, cpu_mem_wdata, cpu_mem_rdata;
    logic [3:0]  cpu_mem_wstrb;
    logic        cpu_mem_valid, cpu_mem_ready;
    logic        halted, illegal_instr, ecall_seen, ebreak_seen;
    logic [31:0] pc_out;

    cpu_core u_cpu (
        .clk(CLOCK_50), .rst_n(rst_n),
        .mem_addr(cpu_mem_addr), .mem_wdata(cpu_mem_wdata), .mem_wstrb(cpu_mem_wstrb),
        .mem_valid(cpu_mem_valid), .mem_rdata(cpu_mem_rdata), .mem_ready(cpu_mem_ready),
        .halted(halted), .illegal_instr(illegal_instr),
        .ecall_seen(ecall_seen), .ebreak_seen(ebreak_seen), .pc_out(pc_out)
    );

    logic [16:0] fb_scanout_addr;
    logic        fb_scanout_valid;
    logic [23:0] fb_scanout_pixel;

    soc_bus u_bus (
        .clk(CLOCK_50), .rst_n(rst_n),
        .cpu_mem_addr(cpu_mem_addr), .cpu_mem_wdata(cpu_mem_wdata), .cpu_mem_wstrb(cpu_mem_wstrb),
        .cpu_mem_valid(cpu_mem_valid), .cpu_mem_rdata(cpu_mem_rdata), .cpu_mem_ready(cpu_mem_ready),
        .key_n(KEY), .sw(SW), .ledr(LEDR),
        .dram_addr(DRAM_ADDR), .dram_ba(DRAM_BA), .dram_dq(DRAM_DQ), .dram_dqm(DRAM_DQM),
        .dram_ras_n(DRAM_RAS_N), .dram_cas_n(DRAM_CAS_N), .dram_we_n(DRAM_WE_N),
        .dram_cs_n(DRAM_CS_N), .dram_cke(DRAM_CKE), .dram_clk(DRAM_CLK),
        .sd_clk(sd_clk_w), .sd_mosi(sd_mosi_w), .sd_miso(sd_miso_w), .sd_cs_n(sd_cs_n_w),
        .fb_scanout_addr(fb_scanout_addr), .fb_scanout_valid(fb_scanout_valid),
        .fb_scanout_pixel(fb_scanout_pixel)
    );

    vga u_vga (
        .clk(CLOCK_50), .rst_n(rst_n),
        .fb_addr(fb_scanout_addr), .fb_valid(fb_scanout_valid), .fb_pixel(fb_scanout_pixel),
        .vga_r(VGA_R), .vga_g(VGA_G), .vga_b(VGA_B),
        .vga_hs(VGA_HS), .vga_vs(VGA_VS), .vga_blank_n(VGA_BLANK_N),
        .vga_sync_n(VGA_SYNC_N), .vga_clk(VGA_CLK)
    );
endmodule
