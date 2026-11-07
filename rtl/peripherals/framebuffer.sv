// On-chip dual-port framebuffer: one 32-bit-per-pixel word per DOOM pixel
// (320x200 = 64,000 pixels, low 24 bits = {R,G,B}), CPU write/read port on
// one side, vga.sv's independent scan-out read port on the other -- a
// standard dual-port BRAM usage pattern.
//
// Pixel format (32-bit word, low 24 bits RGB888) is an M4 interim choice
// for testing the SoC integration end-to-end, NOT the final locked format
// -- the mission explicitly warns against assuming DoomGeneric's actual
// pixel format before inspecting it (M5). Revisit this module's width and
// soc_bus.sv's VGA_TOP region size once that's known; 256 KiB is already
// reserved in docs/memory_map.md to cover the worst case (32-bit) without
// needing to redo the address map later.
module framebuffer #(
    parameter int PIXELS = 64000 // 320*200
) (
    input  logic        clk,
    input  logic        rst_n,

    // CPU-side port (local byte offset within the 256KiB window)
    input  logic [17:0] mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_wstrb,
    input  logic        mem_valid,
    output logic [31:0] mem_rdata,
    output logic        mem_ready,

    // VGA-side scan-out read port (vga.sv's fb_addr/fb_valid/fb_pixel)
    input  logic [16:0] fb_addr,
    input  logic        fb_valid,
    output logic [23:0] fb_pixel
);
    logic [31:0] mem [0:PIXELS-1];

    logic [15:0] waddr;
    assign waddr = mem_addr[17:2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
        end else begin
            mem_ready <= mem_valid;
            if (mem_valid && (|mem_wstrb) && waddr < 16'(PIXELS)) begin
                if (mem_wstrb[0]) mem[waddr][7:0]   <= mem_wdata[7:0];
                if (mem_wstrb[1]) mem[waddr][15:8]  <= mem_wdata[15:8];
                if (mem_wstrb[2]) mem[waddr][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) mem[waddr][31:24] <= mem_wdata[31:24];
            end
            if (waddr < 16'(PIXELS)) mem_rdata <= mem[waddr];
            else                      mem_rdata <= 32'hDEADBEEF;
        end
    end

    // Independent VGA-side read port: deliberately COMBINATIONAL (no clock
    // at all), matching vga.sv's current assumption of zero-latency
    // fb_addr->fb_pixel lookup. This also sidesteps a real clock-domain
    // question -- vga.sv operates on its own divided pixel clock (pclk),
    // not this module's `clk` -- that a registered read port would have to
    // address properly. Flagged for M6 synthesis review: real Cyclone IV
    // M9K blocks this large typically want a registered (1-cycle-latency)
    // read port; adopting one later means adjusting vga.sv to pipeline its
    // RGB output by one pclk cycle relative to h_count/v_count, a standard
    // and small change, not attempted now to keep this M4 integration step
    // focused.
    assign fb_pixel = (fb_valid && fb_addr < 17'(PIXELS)) ? mem[fb_addr][23:0] : 24'd0;
endmodule
