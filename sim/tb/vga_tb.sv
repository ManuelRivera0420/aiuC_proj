// Direct unit test of vga.sv: timing (H_TOTAL/V_TOTAL, sync pulse windows,
// blank_n), and the 320x200->640x480 2x-upscale/vertically-centered
// scan-out addressing. Uses hierarchical references to the DUT's internal
// h_count/v_count/pclk for precise, fast-to-reach checks instead of
// simulating full frames blindly.
module vga_tb;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; // 50MHz-equivalent system clock in sim time units

    logic [16:0] fb_addr;
    logic        fb_valid;
    logic [23:0] fb_pixel = 24'hAABBCC;

    logic [7:0] vga_r, vga_g, vga_b;
    logic       vga_hs, vga_vs, vga_blank_n, vga_sync_n, vga_clk;

    vga dut (
        .clk(clk), .rst_n(rst_n),
        .fb_addr(fb_addr), .fb_valid(fb_valid), .fb_pixel(fb_pixel),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .vga_hs(vga_hs), .vga_vs(vga_vs), .vga_blank_n(vga_blank_n),
        .vga_sync_n(vga_sync_n), .vga_clk(vga_clk)
    );

    integer errors = 0, checks = 0;

    task check_eq(string name, logic [31:0] got, logic [31:0] exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] %-30s got=%0d exp=%0d", name, got, exp);
        end else begin
            $display("[PASS] %-30s = %0d", name, got);
        end
    endtask

    task check_bit(string name, logic got, logic exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] %-30s got=%0b exp=%0b", name, got, exp);
        end else begin
            $display("[PASS] %-30s = %0b", name, got);
        end
    endtask

    // advance until dut.h_count==target (within the current line), using pclk edges
    task goto_h(int target);
        while (dut.h_count != target) @(posedge dut.pclk);
    endtask

    initial begin
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // ---- frame geometry ----
        check_eq("H_TOTAL",  dut.H_TOTAL,  800);
        check_eq("V_TOTAL",  dut.V_TOTAL,  525);
        check_eq("H_ACTIVE", dut.H_ACTIVE, 640);
        check_eq("V_ACTIVE", dut.V_ACTIVE, 480);

        // ---- line 0: blank_n / hsync windows within one line ----
        goto_h(0);
        check_bit("blank_n high at h=0,v=0",   vga_blank_n, 1'b1);
        check_bit("hsync inactive(high) h=0",  vga_hs,      1'b1);

        goto_h(639);
        check_bit("blank_n high at h=639",     vga_blank_n, 1'b1);
        goto_h(640);
        check_bit("blank_n low at h=640 (front porch)", vga_blank_n, 1'b0);

        goto_h(655);
        check_bit("hsync still high at h=655", vga_hs, 1'b1);
        goto_h(656);
        check_bit("hsync low at h=656 (sync start)", vga_hs, 1'b0);
        goto_h(751);
        check_bit("hsync low at h=751 (sync end)",   vga_hs, 1'b0);
        goto_h(752);
        check_bit("hsync high at h=752 (back porch)", vga_hs, 1'b1);

        // ---- advance to v=40 (first DOOM row) and check fb_valid/fb_addr ----
        while (dut.v_count != 40) @(posedge dut.pclk);
        goto_h(0);
        check_bit("fb_valid at v=40,h=0", fb_valid, 1'b1);
        check_eq("fb_addr at v=40,h=0",   fb_addr, 0);
        goto_h(1);
        check_eq("fb_addr at v=40,h=1 (2x dup)", fb_addr, 0);
        goto_h(2);
        check_eq("fb_addr at v=40,h=2", fb_addr, 1);
        goto_h(639);
        check_eq("fb_addr at v=40,h=639 (last col)", fb_addr, 319);

        check_eq("vga_r passthrough when valid", vga_r, 8'hAA);
        check_eq("vga_g passthrough when valid", vga_g, 8'hBB);
        check_eq("vga_b passthrough when valid", vga_b, 8'hCC);

        // ---- v=41: still doom_y=0 (2x vertical duplication) ----
        while (dut.v_count != 41) @(posedge dut.pclk);
        goto_h(0);
        check_eq("fb_addr at v=41,h=0 (vert dup of row0)", fb_addr, 0);

        // ---- v=42: doom_y=1 ----
        while (dut.v_count != 42) @(posedge dut.pclk);
        goto_h(0);
        check_eq("fb_addr at v=42,h=0 (row1 start)", fb_addr, 320);

        // ---- border rows: v<40 and v>=440 must have fb_valid=0, black output ----
        while (dut.v_count != 0) @(posedge dut.pclk);
        goto_h(0);
        check_bit("fb_valid=0 in top border (v=0)", fb_valid, 1'b0);
        check_eq("vga_r black in top border", vga_r, 0);

        while (dut.v_count != 440) @(posedge dut.pclk);
        goto_h(0);
        check_bit("fb_valid=0 in bottom border (v=440)", fb_valid, 1'b0);

        // ---- vsync window ----
        while (dut.v_count != 489) @(posedge dut.pclk);
        check_bit("vsync high at v=489", vga_vs, 1'b1);
        while (dut.v_count != 490) @(posedge dut.pclk);
        check_bit("vsync low at v=490 (sync start)", vga_vs, 1'b0);
        while (dut.v_count != 492) @(posedge dut.pclk);
        check_bit("vsync high at v=492 (sync end+1)", vga_vs, 1'b1);

        check_bit("sync_n held low (separate-sync mode)", vga_sync_n, 1'b0);

        $display("------------------------------------------------------------");
        $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
        if (errors == 0) $display("VGA_UNIT_TEST_RESULT: PASS");
        else              $display("VGA_UNIT_TEST_RESULT: FAIL");
        $finish;
    end
endmodule
