// Direct unit test of key_sw_gpio.sv -- drives board pins and the local
// bus port directly (no CPU involved) so edge-detect timing is exact and
// controllable, unlike a software-polling integration test would be.
module key_sw_gpio_tb;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [3:0]  key_n = 4'hF;
    logic [17:0] sw = 18'd0;
    logic [17:0] ledr;

    logic [7:0]  mem_addr;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_wstrb;
    logic        mem_valid;
    logic [31:0] mem_rdata;
    logic        mem_ready;

    key_sw_gpio dut (
        .clk(clk), .rst_n(rst_n), .key_n(key_n), .sw(sw), .ledr(ledr),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_valid(mem_valid), .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    integer errors = 0, checks = 0;

    // Samples mem_rdata via the COMBINATIONAL path, before the same-edge
    // clock edge that would commit any read-triggered side effect (e.g.
    // SW_EDGE's clear-on-read). This matches how cpu_core.sv's own FSM
    // observes mem_rdata: it captures the pre-edge combinational value at
    // the very edge where mem_ready is first seen, which is the same edge
    // that commits any clear-on-read -- so it never races itself the way
    // a "wait a full cycle, then sample" testbench protocol would.
    task do_read(logic [7:0] addr, output logic [31:0] data);
        mem_addr  = addr;
        mem_wstrb = 4'd0;
        mem_valid = 1'b1;
        #1;
        data = mem_rdata;
        @(negedge clk);
        mem_valid = 1'b0;
        @(negedge clk);
    endtask

    task do_write(logic [7:0] addr, logic [31:0] data);
        mem_addr  = addr;
        mem_wdata = data;
        mem_wstrb = 4'hF;
        mem_valid = 1'b1;
        @(negedge clk);
        mem_valid = 1'b0;
        mem_wstrb = 4'd0;
        @(negedge clk);
    endtask

    task check32(string name, logic [31:0] got, logic [31:0] exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] %-28s got=0x%08h exp=0x%08h", name, got, exp);
        end else begin
            $display("[PASS] %-28s = 0x%08h", name, got);
        end
    endtask

    logic [31:0] rd;

    initial begin
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // ---- KEY_STATUS: active-low board pins -> active-high register, bit0 reserved ----
        key_n = 4'b0101; // KEY[3]=0(pressed) KEY[2]=1(released) KEY[1]=0(pressed) KEY[0]=1(N/A, reset pin)
        repeat (3) @(negedge clk); // let the 2-FF synchronizer settle
        do_read(8'h00, rd);
        check32("KEY_STATUS pressed pattern", rd, 32'h0000000A); // bits[3:1]=101 ->0xA with bit0=0

        key_n = 4'hF; // release all
        repeat (3) @(negedge clk);
        do_read(8'h00, rd);
        check32("KEY_STATUS all released", rd, 32'h00000000);

        // ---- SW_LEVEL: continuous level passthrough (synchronized) ----
        sw = 18'b10_1010_1010_1010_1010;
        repeat (3) @(negedge clk);
        do_read(8'h04, rd);
        check32("SW_LEVEL pattern", rd, 32'h0002AAAA);

        // ---- SW_EDGE: rising-edge detect, sticky until read, clears on read ----
        sw = 18'd0;
        repeat (3) @(negedge clk);
        do_read(8'h08, rd); // drain any stale edge from the pattern load above
        sw[2] = 1'b1; // rising edge on bit2
        repeat (3) @(negedge clk);
        do_read(8'h08, rd);
        check32("SW_EDGE catches rising bit2", rd, 32'h00000004);

        do_read(8'h08, rd);
        check32("SW_EDGE cleared after read", rd, 32'h00000000);

        // holding the switch high (no new edge) must not re-latch
        repeat (5) @(negedge clk);
        do_read(8'h08, rd);
        check32("SW_EDGE stays clear while held", rd, 32'h00000000);

        // falling edge then rising edge again -> re-latches
        sw[2] = 1'b0;
        repeat (3) @(negedge clk);
        sw[2] = 1'b1;
        repeat (3) @(negedge clk);
        do_read(8'h08, rd);
        check32("SW_EDGE re-latches on new rising edge", rd, 32'h00000004);

        // ---- LED_STATUS: read-write register ----
        do_write(8'h0C, 32'h0002_3456);
        do_read(8'h0C, rd);
        check32("LED_STATUS write/read-back", rd, 32'h00023456);
        check32("ledr output port matches", {14'd0, ledr}, 32'h00023456);

        // ---- unmapped offset ----
        do_read(8'h10, rd);
        check32("unmapped offset returns DEADBEEF", rd, 32'hDEADBEEF);

        $display("------------------------------------------------------------");
        $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
        if (errors == 0) $display("GPIO_UNIT_TEST_RESULT: PASS");
        else              $display("GPIO_UNIT_TEST_RESULT: FAIL");
        $finish;
    end
endmodule
