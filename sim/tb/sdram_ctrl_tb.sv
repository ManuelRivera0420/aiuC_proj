// Tests sdram_ctrl.sv against sdram_model.sv: init sequence (PRECHARGE,
// 2x REFRESH, MRS before any ACTIVATE), word write+read-back correctness
// through the picorv32-style bus port, byte-masked writes, and periodic
// refresh actually occurring during normal operation.
module sdram_ctrl_tb;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic [3:0]  mem_wstrb;
    logic        mem_valid, mem_ready;

    wire  [12:0] dram_addr;
    wire  [1:0]  dram_ba;
    wire  [31:0] dram_dq;
    wire  [3:0]  dram_dqm;
    wire         dram_ras_n, dram_cas_n, dram_we_n, dram_cs_n, dram_cke, dram_clk;

    // Small timing/interval parameters to keep this test fast while still
    // exercising every state in the FSM (POWERUP_CYCLES/REFRESH_INTERVAL
    // are overridden here; T_RCD/T_CL/T_RP use the real defaults).
    sdram_ctrl #(.POWERUP_CYCLES(200), .REFRESH_INTERVAL(60)) dut_ctrl (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_valid(mem_valid), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .dram_addr(dram_addr), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .dram_cs_n(dram_cs_n), .dram_cke(dram_cke), .dram_clk(dram_clk)
    );

    logic [31:0] cnt_act, cnt_rd, cnt_wr, cnt_ref, cnt_pre, cnt_mrs;
    logic        err_rd_before_act, err_wr_before_act;

    sdram_model dut_model (
        .clk(dram_clk), .rst_n(rst_n),
        .dram_addr(dram_addr), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .dram_cs_n(dram_cs_n), .dram_cke(dram_cke),
        .command_count_activate(cnt_act), .command_count_read(cnt_rd),
        .command_count_write(cnt_wr), .command_count_refresh(cnt_ref),
        .command_count_precharge(cnt_pre), .command_count_mrs(cnt_mrs),
        .saw_read_before_activate_error(err_rd_before_act),
        .saw_write_before_activate_error(err_wr_before_act)
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

    task check_true(string name, logic got);
        checks = checks + 1;
        if (!got) begin
            errors = errors + 1;
            $display("[FAIL] %-30s expected true, got false", name);
        end else begin
            $display("[PASS] %-30s true", name);
        end
    endtask

    task do_write(logic [31:0] addr, logic [31:0] data, logic [3:0] wstrb);
        mem_addr = addr; mem_wdata = data; mem_wstrb = wstrb; mem_valid = 1'b1;
        wait (mem_ready);
        @(negedge clk);
        mem_valid = 1'b0; mem_wstrb = 4'd0;
        @(negedge clk);
    endtask

    task do_read(logic [31:0] addr, output logic [31:0] data);
        mem_addr = addr; mem_wstrb = 4'd0; mem_valid = 1'b1;
        wait (mem_ready);
        data = mem_rdata;
        @(negedge clk);
        mem_valid = 1'b0;
        @(negedge clk);
    endtask

    logic [31:0] rd;

    initial begin
        mem_valid = 0; mem_wstrb = 0; mem_addr = 0; mem_wdata = 0;
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;

        // ---- wait for the controller to finish its init sequence ----
        wait (dut_ctrl.state == dut_ctrl.S_IDLE);
        @(negedge clk);

        check_eq("precharge count after init", cnt_pre, 1);
        check_eq("refresh count after init (2x)", cnt_ref, 2);
        check_eq("mrs count after init", cnt_mrs, 1);
        check_eq("activate count before any access", cnt_act, 0);
        check_true("no premature read-before-activate", !err_rd_before_act);
        check_true("no premature write-before-activate", !err_wr_before_act);

        // ---- basic write then read-back ----
        do_write(32'h1000_0004, 32'hDEADBEEF, 4'hF);
        do_read(32'h1000_0004, rd);
        check_eq("write/read-back word", rd, 32'hDEADBEEF);
        check_eq("activate count after 2 accesses", cnt_act, 2);

        // ---- byte-masked write: only update byte 0, leave the rest ----
        do_write(32'h1000_0004, 32'h000000AA, 4'h1);
        do_read(32'h1000_0004, rd);
        check_eq("byte-masked write preserves other bytes", rd, 32'hDEADBEAA);

        // ---- a different address must not alias the first ----
        do_write(32'h1000_0100, 32'hCAFEF00D, 4'hF);
        do_read(32'h1000_0100, rd);
        check_eq("second address write/read-back", rd, 32'hCAFEF00D);
        do_read(32'h1000_0004, rd);
        check_eq("first address unaffected by second write", rd, 32'hDEADBEAA);

        // ---- let periodic refresh actually fire during normal operation ----
        repeat (150) @(negedge clk);
        check_true("periodic refresh occurred during operation", cnt_ref > 2);

        check_true("still no read-before-activate error", !err_rd_before_act);
        check_true("still no write-before-activate error", !err_wr_before_act);

        $display("------------------------------------------------------------");
        $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
        if (errors == 0) $display("SDRAM_CTRL_TEST_RESULT: PASS");
        else              $display("SDRAM_CTRL_TEST_RESULT: FAIL");
        $finish;
    end
endmodule
