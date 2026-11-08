// Address-decoded bus per docs/memory_map.md. M4: all peripherals are now
// wired -- boot ROM, boot RAM, GPIO, timer, SDRAM, SD/SPI, and the VGA
// framebuffer (write side; vga.sv's independent scan-out read port
// connects to the fb_* pins exposed here, from a sibling instantiation at
// the next level up, e.g. an end-to-end testbench or the future
// rtl/board/de2_115_top.sv).
module soc_bus #(
    // Overridable so different testbenches can load different boot ROM
    // content without each one needing its own copy of this module.
    // Defaults to the shared M3/M4 boot ROM image used by every test that
    // doesn't override it.
    parameter string BOOT_ROM_FILE = "sim/models/soc_rom.hex"
) (
    input  logic        clk,
    input  logic        rst_n,

    // cpu_core-facing port
    input  logic [31:0] cpu_mem_addr,
    input  logic [31:0] cpu_mem_wdata,
    input  logic [3:0]  cpu_mem_wstrb,
    input  logic        cpu_mem_valid,
    output logic [31:0] cpu_mem_rdata,
    output logic        cpu_mem_ready,

    // board-facing GPIO pins
    input  logic [3:0]  key_n,
    input  logic [17:0] sw,
    output logic [17:0] ledr,

    // DE2-115 Table 4-28 SDRAM pins
    output logic [12:0] dram_addr,
    output logic [1:0]  dram_ba,
    inout  wire  [31:0] dram_dq,
    output logic [3:0]  dram_dqm,
    output logic        dram_ras_n,
    output logic        dram_cas_n,
    output logic        dram_we_n,
    output logic        dram_cs_n,
    output logic        dram_cke,
    output logic        dram_clk,

    // DE2-115 Table 4-31 SD card (SPI mode) pins
    output logic        sd_clk,
    output logic        sd_mosi,
    input  logic        sd_miso,
    output logic        sd_cs_n,

    // VGA framebuffer scan-out read port (driven by a sibling vga.sv instance)
    input  logic [16:0] fb_scanout_addr,
    input  logic        fb_scanout_valid,
    output logic [23:0] fb_scanout_pixel
);
    localparam logic [31:0] ROM_BASE   = 32'h0000_0000;
    localparam logic [31:0] ROM_TOP    = 32'h0000_FFFF;
    localparam logic [31:0] BRAM_BASE  = 32'h0001_0000;
    localparam logic [31:0] BRAM_TOP   = 32'h0001_FFFF;
    localparam logic [31:0] SDRAM_BASE = 32'h1000_0000;
    localparam logic [31:0] SDRAM_TOP  = 32'h17FF_FFFF;
    localparam logic [31:0] GPIO_BASE  = 32'h2000_0000;
    localparam logic [31:0] GPIO_TOP   = 32'h2000_00FF;
    localparam logic [31:0] TIMER_BASE = 32'h2000_0100;
    localparam logic [31:0] TIMER_TOP  = 32'h2000_01FF;
    localparam logic [31:0] SDSPI_BASE = 32'h2000_0200;
    localparam logic [31:0] SDSPI_TOP  = 32'h2000_02FF;
    localparam logic [31:0] VGA_BASE   = 32'h3000_0000;
    localparam logic [31:0] VGA_TOP    = 32'h3003_FFFF;

    typedef enum logic [3:0] {
        SEL_NONE, SEL_ROM, SEL_BRAM, SEL_GPIO, SEL_TIMER, SEL_SDRAM, SEL_SDSPI, SEL_VGA
    } sel_t;
    sel_t sel;

    always_comb begin
        if (cpu_mem_addr >= ROM_BASE && cpu_mem_addr <= ROM_TOP)
            sel = SEL_ROM;
        else if (cpu_mem_addr >= BRAM_BASE && cpu_mem_addr <= BRAM_TOP)
            sel = SEL_BRAM;
        else if (cpu_mem_addr >= GPIO_BASE && cpu_mem_addr <= GPIO_TOP)
            sel = SEL_GPIO;
        else if (cpu_mem_addr >= TIMER_BASE && cpu_mem_addr <= TIMER_TOP)
            sel = SEL_TIMER;
        else if (cpu_mem_addr >= SDRAM_BASE && cpu_mem_addr <= SDRAM_TOP)
            sel = SEL_SDRAM;
        else if (cpu_mem_addr >= SDSPI_BASE && cpu_mem_addr <= SDSPI_TOP)
            sel = SEL_SDSPI;
        else if (cpu_mem_addr >= VGA_BASE && cpu_mem_addr <= VGA_TOP)
            sel = SEL_VGA;
        else
            sel = SEL_NONE;
    end

    // ---- boot ROM / boot RAM: reuse sync_mem.sv, each sees a LOCAL address ----
    logic [31:0] rom_rdata, bram_rdata;
    logic        rom_ready, bram_ready;

    sync_mem #(.WORDS(16384), .INIT_FILE(BOOT_ROM_FILE)) u_rom (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(cpu_mem_addr - ROM_BASE),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(sel == SEL_ROM ? cpu_mem_wstrb : 4'd0),
        .mem_valid(sel == SEL_ROM && cpu_mem_valid),
        .mem_rdata(rom_rdata), .mem_ready(rom_ready)
    );

    sync_mem #(.WORDS(16384), .INIT_FILE("sim/models/soc_bram_empty.hex")) u_bram (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(cpu_mem_addr - BRAM_BASE),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(sel == SEL_BRAM ? cpu_mem_wstrb : 4'd0),
        .mem_valid(sel == SEL_BRAM && cpu_mem_valid),
        .mem_rdata(bram_rdata), .mem_ready(bram_ready)
    );

    // ---- GPIO / timer: local 8-bit offset within their 256B windows ----
    logic [31:0] gpio_rdata, timer_rdata;
    logic        gpio_ready, timer_ready;

    key_sw_gpio u_gpio (
        .clk(clk), .rst_n(rst_n),
        .key_n(key_n), .sw(sw), .ledr(ledr),
        .mem_addr(cpu_mem_addr[7:0]),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(sel == SEL_GPIO ? cpu_mem_wstrb : 4'd0),
        .mem_valid(sel == SEL_GPIO && cpu_mem_valid),
        .mem_rdata(gpio_rdata), .mem_ready(gpio_ready)
    );

    timer u_timer (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(cpu_mem_addr[7:0]),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(sel == SEL_TIMER ? cpu_mem_wstrb : 4'd0),
        .mem_valid(sel == SEL_TIMER && cpu_mem_valid),
        .mem_rdata(timer_rdata), .mem_ready(timer_ready)
    );

    // ---- SDRAM: mem_addr's low 27 bits are used internally (word_addr =
    // mem_addr[26:2]), so the FULL cpu_mem_addr can be passed directly --
    // SDRAM_BASE's bit pattern (0x1000_0000, i.e. only bit28 set) doesn't
    // overlap the bits sdram_ctrl.sv actually inspects. ----
    logic [31:0] sdram_rdata;
    logic        sdram_ready;

    sdram_ctrl u_sdram (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(sel == SEL_SDRAM ? cpu_mem_wstrb : 4'd0),
        .mem_valid(sel == SEL_SDRAM && cpu_mem_valid),
        .mem_rdata(sdram_rdata), .mem_ready(sdram_ready),
        .dram_addr(dram_addr), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .dram_cs_n(dram_cs_n), .dram_cke(dram_cke), .dram_clk(dram_clk)
    );

    // ---- SD/SPI: local 8-bit offset (SDSPI_BASE's low byte is 0) ----
    logic [31:0] sdspi_rdata;
    logic        sdspi_ready;

    sd_spi u_sdspi (
        .clk(clk), .rst_n(rst_n),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .mem_addr(cpu_mem_addr[7:0]),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(sel == SEL_SDSPI ? cpu_mem_wstrb : 4'd0),
        .mem_valid(sel == SEL_SDSPI && cpu_mem_valid),
        .mem_rdata(sdspi_rdata), .mem_ready(sdspi_ready)
    );

    // ---- VGA framebuffer: local 18-bit offset (VGA_BASE's low 18 bits are 0) ----
    logic [31:0] vga_rdata;
    logic        vga_ready;

    framebuffer u_framebuffer (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(cpu_mem_addr[17:0]),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(sel == SEL_VGA ? cpu_mem_wstrb : 4'd0),
        .mem_valid(sel == SEL_VGA && cpu_mem_valid),
        .mem_rdata(vga_rdata), .mem_ready(vga_ready),
        .fb_addr(fb_scanout_addr), .fb_valid(fb_scanout_valid), .fb_pixel(fb_scanout_pixel)
    );

    // ---- response mux ----
    always_comb begin
        case (sel)
            SEL_ROM:   begin cpu_mem_rdata = rom_rdata;   cpu_mem_ready = rom_ready; end
            SEL_BRAM:  begin cpu_mem_rdata = bram_rdata;  cpu_mem_ready = bram_ready; end
            SEL_GPIO:  begin cpu_mem_rdata = gpio_rdata;  cpu_mem_ready = gpio_ready; end
            SEL_TIMER: begin cpu_mem_rdata = timer_rdata; cpu_mem_ready = timer_ready; end
            SEL_SDRAM: begin cpu_mem_rdata = sdram_rdata; cpu_mem_ready = sdram_ready; end
            SEL_SDSPI: begin cpu_mem_rdata = sdspi_rdata; cpu_mem_ready = sdspi_ready; end
            SEL_VGA:   begin cpu_mem_rdata = vga_rdata;   cpu_mem_ready = vga_ready; end
            default:   begin cpu_mem_rdata = 32'hDEADBEEF; cpu_mem_ready = cpu_mem_valid; end
        endcase
    end
endmodule
