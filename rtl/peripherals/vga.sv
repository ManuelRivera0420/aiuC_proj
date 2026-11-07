// VGA 640x480@60Hz timing generator + DOOM-framebuffer scan-out addressing.
//
// Timing: uses the well-known VESA/industry-standard 640x480@60Hz
// parameters (640 active / 16 front porch / 96 sync / 48 back porch
// horizontally = 800 total; 480/10/2/33 vertically = 525 total), negative
// HSYNC/VSYNC polarity. This is deliberately the standard timing, not a
// literal transcription of the DE2-115 manual's Table 4-14/4-15 figures,
// which are rounded to 1 decimal microsecond and -- as the manual itself
// says ("search...for VGA signal timing") -- are an approximate pointer to
// this exact standard rather than a DE2-115-specific spec. Cross-check:
// manual's vertical a/b/c/d = 2/33/480/10 lines sums to 525, exactly
// matching the standard total, confirming this is the same mode.
//
// Pixel clock: this module internally divides the 50MHz input clock by 2
// to approximate the standard 25.175MHz pixel clock (getting 25MHz exactly
// instead) -- acceptable for behavioral simulation and for a first FPGA
// bring-up, but the real Quartus build should generate a cleaner,
// lower-jitter pixel clock via a PLL megafunction; see
// docs/board_resource_selection.md / fpga_handoff notes for that instruction
// to the human team. This module does not and cannot instantiate real
// Cyclone IV PLL hardware itself.
//
// Scan-out: DOOM's logical 320x200 frame is shown 2x upscaled (nearest-
// neighbor) as a 640x400 image, centered vertically in the 640x480 active
// area (40-row black border top and bottom); horizontally it already
// exactly fills all 640 columns at 2x, so no horizontal border is needed.
module vga (
    input  logic        clk,        // 50 MHz board clock
    input  logic        rst_n,

    // DOOM framebuffer read port (320x200, format TBD -- this module only
    // consumes a pre-converted 24-bit RGB value; the conversion from
    // whatever on-chip format M5 settles on happens upstream of fb_pixel)
    output logic [16:0] fb_addr,     // 0..63999 (320*200-1), valid only when fb_valid
    output logic        fb_valid,
    input  logic [23:0] fb_pixel,    // {R,G,B}, 8 bits each

    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b,
    output logic        vga_hs,
    output logic        vga_vs,
    output logic        vga_blank_n,
    output logic        vga_sync_n,
    output logic        vga_clk
);
    localparam int H_ACTIVE = 640, H_FRONT = 16, H_SYNC = 96, H_BACK = 48;
    localparam int H_TOTAL  = H_ACTIVE + H_FRONT + H_SYNC + H_BACK; // 800
    localparam int V_ACTIVE = 480, V_FRONT = 10, V_SYNC = 2, V_BACK = 33;
    localparam int V_TOTAL  = V_ACTIVE + V_FRONT + V_SYNC + V_BACK; // 525

    localparam int DOOM_W = 320, DOOM_H = 200;
    localparam int V_BORDER = (V_ACTIVE - 2*DOOM_H) / 2; // 40

    // ---- pixel clock: divide-by-2 (see module header for the real-FPGA caveat) ----
    logic pclk;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pclk <= 1'b0;
        else        pclk <= ~pclk;
    end
    assign vga_clk = pclk;

    // ---- H/V counters, clocked on the pixel clock ----
    // (kept signed `int`, matching the signed localparams above -- an
    // earlier attempt to make these `int unsigned` for the shift-direction
    // warning below only created MORE signedness-mismatch warnings against
    // H_ACTIVE/H_TOTAL/etc. Values are always non-negative by construction,
    // so the right-shifts below are numerically correct either way.)
    int h_count, v_count;
    always_ff @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            h_count <= 0;
            v_count <= 0;
        end else begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= 0;
                v_count <= (v_count == V_TOTAL - 1) ? 0 : v_count + 1;
            end else begin
                h_count <= h_count + 1;
            end
        end
    end

    logic h_active, v_active;
    assign h_active = (h_count < H_ACTIVE);
    assign v_active = (v_count < V_ACTIVE);

    // negative polarity: sync pulse is the LOW period
    assign vga_hs = !(h_count >= H_ACTIVE + H_FRONT && h_count < H_ACTIVE + H_FRONT + H_SYNC);
    assign vga_vs = !(v_count >= V_ACTIVE + V_FRONT && v_count < V_ACTIVE + V_FRONT + V_SYNC);
    assign vga_blank_n = h_active && v_active;
    assign vga_sync_n  = 1'b0; // separate-sync mode (HS/VS used directly); ADV7123 convention

    // ---- DOOM scan-out addressing: 2x upscale, vertically centered ----
    logic doom_row_active;
    int   doom_y;
    assign doom_row_active = v_active && (v_count >= V_BORDER) && (v_count < V_BORDER + 2*DOOM_H);
    assign doom_y = (v_count - V_BORDER) >> 1;

    assign fb_valid = h_active && doom_row_active;
    assign fb_addr  = fb_valid ? (17'(doom_y) * 17'(DOOM_W) + 17'(h_count >> 1)) : 17'd0;

    assign vga_r = fb_valid ? fb_pixel[23:16] : 8'd0;
    assign vga_g = fb_valid ? fb_pixel[15:8]  : 8'd0;
    assign vga_b = fb_valid ? fb_pixel[7:0]   : 8'd0;
endmodule
