// On-chip dual-port framebuffer, REVISED for DoomGeneric's actual native
// format (see software/source-lock.json's pixel_format_finding, verified
// by reading software/upstream/doomgeneric/i_video.c at the pinned
// commit): 320x200 8-bit PALETTE-INDEXED pixels (64,000 bytes), not the
// 32-bit-RGB placeholder M4 used for initial SoC-integration testing.
//
// This module does the index->RGB palette lookup INTERNALLY, so vga.sv
// (already verified standalone, 29/29 checks, sim/tb/vga_tb.sv) needs NO
// changes at all -- it still just receives a 24-bit RGB fb_pixel exactly
// as before.
//
// Local address map within this module's 256KiB MMIO window
// (docs/memory_map.md's VGA_BASE, 0x3000_0000):
//   0x00000 - 0x0F9FF  pixel data: byte i = pixel i's palette index (0..63999)
//   0x10000 - 0x103FF  palette: 256 entries x 4 bytes (low 24 bits = RGB888),
//                      word-addressed, i.e. palette entry N at offset 0x10000+4*N
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
    localparam logic [17:0] PALETTE_BASE = 18'h10000;

    // ---- pixel storage: byte-indexed, packed 4-per-word for CPU writes ----
    logic [31:0] pixel_words [0:(PIXELS+3)/4 - 1];
    // ---- palette: 256 entries, low 24 bits RGB888 ----
    logic [31:0] palette [0:255];

    logic is_palette_access;
    assign is_palette_access = (mem_addr >= PALETTE_BASE);

    logic [15:0] pix_waddr;
    logic [7:0]  pal_waddr;
    assign pix_waddr = mem_addr[17:2];
    assign pal_waddr = mem_addr[9:2]; // offset within the palette region, word-indexed

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
        end else begin
            mem_ready <= mem_valid;
            if (mem_valid && (|mem_wstrb)) begin
                if (is_palette_access) begin
                    if (mem_wstrb[0]) palette[pal_waddr][7:0]   <= mem_wdata[7:0];
                    if (mem_wstrb[1]) palette[pal_waddr][15:8]  <= mem_wdata[15:8];
                    if (mem_wstrb[2]) palette[pal_waddr][23:16] <= mem_wdata[23:16];
                end else if (pix_waddr < 16'((PIXELS + 3) / 4)) begin
                    if (mem_wstrb[0]) pixel_words[pix_waddr][7:0]   <= mem_wdata[7:0];
                    if (mem_wstrb[1]) pixel_words[pix_waddr][15:8]  <= mem_wdata[15:8];
                    if (mem_wstrb[2]) pixel_words[pix_waddr][23:16] <= mem_wdata[23:16];
                    if (mem_wstrb[3]) pixel_words[pix_waddr][31:24] <= mem_wdata[31:24];
                end
            end
            if (is_palette_access) mem_rdata <= palette[pal_waddr];
            else                   mem_rdata <= pixel_words[pix_waddr];
        end
    end

    // ---- VGA-side scan-out: index lookup + palette lookup, both
    // combinational (matches vga.sv's zero-latency fb_addr->fb_pixel
    // assumption -- same simplification flagged in M4 for M6 synthesis
    // review: real M9K blocks this size typically want a registered read,
    // which would mean pipelining vga.sv's RGB output by one cycle). ----
    logic [31:0] scan_word;
    logic [7:0]  scan_index;
    assign scan_word  = pixel_words[fb_addr[16:2]];
    assign scan_index = scan_word[8*fb_addr[1:0] +: 8];
    assign fb_pixel   = (fb_valid && fb_addr < 17'(PIXELS)) ? palette[scan_index][23:0] : 24'd0;
endmodule
