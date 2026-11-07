// Tests sd_spi.sv end-to-end against sdhc_spi_model.sv: full init handshake
// (CMD0/CMD8/CMD55+ACMD41 retried twice on purpose/CMD58-CCS), then a
// CMD17 single-block read of LBA 1 (the fixture image's program sector,
// see scripts/prepare_sd_image.py), checked byte-for-byte against the
// known fixture contents.
module sd_spi_tb;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    wire sd_clk, sd_mosi, sd_miso, sd_cs_n;

    logic [7:0]  mem_addr;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_wstrb;
    logic        mem_valid;
    logic [31:0] mem_rdata;
    logic        mem_ready;

    sd_spi #(.INIT_CLK_DIV(8), .FAST_CLK_DIV(2)) dut_ctrl (
        .clk(clk), .rst_n(rst_n),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_valid(mem_valid), .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    logic [31:0] cmd_seen_count, last_cmd_index, last_cmd_arg;

    sdhc_spi_model #(.ACMD41_IDLE_RESPONSES(2), .IMAGE_FILE("sim/models/sd_fixture.hex"), .IMAGE_BYTES(2048)) dut_model (
        .clk(clk), .rst_n(rst_n),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .cmd_seen_count(cmd_seen_count), .last_cmd_index(last_cmd_index), .last_cmd_arg(last_cmd_arg)
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

    task do_write(logic [7:0] addr, logic [31:0] data);
        mem_addr = addr; mem_wdata = data; mem_wstrb = 4'hF; mem_valid = 1'b1;
        @(negedge clk);
        mem_valid = 1'b0; mem_wstrb = 4'd0;
        @(negedge clk);
    endtask

    task do_read(logic [7:0] addr, output logic [31:0] data);
        mem_addr = addr; mem_wstrb = 4'd0; mem_valid = 1'b1;
        #1;
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

        // ---- wait for the init handshake to complete, with a hard bound so
        // a genuine protocol deadlock fails fast instead of hanging the
        // whole MCP call (an earlier run with a real command-encoding bug
        // did exactly that -- this watchdog is the fix for THAT, as well
        // as a general safety net). ----
        fork
            begin : init_watchdog
                repeat (200000) @(negedge clk);
                $display("[FAIL] init watchdog expired (state=%s ready=%0b error=%0b)",
                          dut_ctrl.state.name(), dut_ctrl.ready, dut_ctrl.error_flag);
                errors = errors + 1;
                $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
                $display("SD_SPI_TEST_RESULT: FAIL");
                $finish;
            end
            begin : init_wait
                wait (dut_ctrl.ready || dut_ctrl.error_flag);
            end
        join_any
        disable init_watchdog;
        @(negedge clk);

        check_eq("no init error", {31'd0, dut_ctrl.error_flag}, 32'd0);
        check_eq("ready after init", {31'd0, dut_ctrl.ready}, 32'd1);
        check_eq("ACMD41 retried exactly twice before ready",
                 {24'd0, dut_ctrl.retry_ctr}, 32'd2);

        do_read(8'h04, rd); // REG_STATUS
        check_eq("STATUS: busy=0", rd[0], 1'b0);
        check_eq("STATUS: ready=1", rd[1], 1'b1);
        check_eq("STATUS: error=0", rd[2], 1'b0);

        // ---- CMD17 read of LBA 1 (program sector, known fixture bytes) ----
        do_write(8'h08, 32'd1);  // REG_LBA = 1
        do_write(8'h00, 32'h2);  // REG_CTRL: bit1 = start_read

        fork
            begin : read_watchdog
                repeat (200000) @(negedge clk);
                $display("[FAIL] CMD17 read watchdog expired (state=%s)", dut_ctrl.state.name());
                errors = errors + 1;
                $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
                $display("SD_SPI_TEST_RESULT: FAIL");
                $finish;
            end
            begin : read_wait
                wait (dut_ctrl.state == dut_ctrl.ST_READY && !dut_ctrl.busy);
            end
        join_any
        disable read_watchdog;
        @(negedge clk);

        do_read(8'h04, rd);
        check_eq("STATUS after read: error=0", rd[2], 1'b0);

        // Fixture program bytes are (i*7+3)&0xFF for i=0..299 (see the
        // Bash step that generated fixture_program.bin); LBA1 word0 bytes
        // [0,1,2,3] = i=0,1,2,3 -> 3,10,17,24 = 0x03,0x0A,0x11,0x18.
        // block_buf word0 packs byte0 into bits[31:24] (MSB-first per the
        // controller's SPI shift order), so word0 = 0x030A1118.
        do_read(8'h0C, rd); // REG_BUF_DATA word 0 (auto-increments)
        check_eq("block word0 (fixture bytes 0-3)", rd, 32'h030A1118);
        do_read(8'h0C, rd); // word 1 -> bytes 4,5,6,7 = i=4..7 -> 31,38,45,52
        check_eq("block word1 (fixture bytes 4-7)", rd, 32'h1F262D34);

        $display("------------------------------------------------------------");
        $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
        if (errors == 0) $display("SD_SPI_TEST_RESULT: PASS");
        else              $display("SD_SPI_TEST_RESULT: FAIL");
        $finish;
    end
endmodule
