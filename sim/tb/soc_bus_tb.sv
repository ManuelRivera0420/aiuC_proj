// M3 SoC-level integration test: cpu_core.sv + soc_bus.sv running real
// compiled C (firmware/tests/m3_bus_gpio_main.c) that reads the GPIO and
// timer peripherals through their real memory-mapped addresses and
// exercises the real ROM/RAM split with an actual .data load-copy.
module soc_bus_tb;
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

    soc_bus dut_bus (
        .clk(clk), .rst_n(rst_n),
        .cpu_mem_addr(mem_addr), .cpu_mem_wdata(mem_wdata), .cpu_mem_wstrb(mem_wstrb),
        .cpu_mem_valid(mem_valid), .cpu_mem_rdata(mem_rdata), .cpu_mem_ready(mem_ready),
        .key_n(key_n), .sw(sw), .ledr(ledr)
    );

    integer errors = 0, checks = 0;

    task check_bram_word(string name, logic [31:0] byte_addr, logic [31:0] exp);
        logic [31:0] local_off;
        logic [31:0] got;
        local_off = byte_addr - 32'h0001_0000;
        got = dut_bus.u_bram.mem[local_off >> 2];
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] bram[0x%08h] %-14s got=0x%08h exp=0x%08h", byte_addr, name, got, exp);
        end else begin
            $display("[PASS] bram[0x%08h] %-14s = 0x%08h", byte_addr, name, got);
        end
    endtask

    initial begin
        // Fixed KEY/SW pattern held for the whole run (level-only test;
        // edge-detect timing was already unit-tested in key_sw_gpio_tb.sv).
        key_n = 4'b0101; // KEY[3]=pressed KEY[2]=released KEY[1]=pressed
        sw    = 18'b10_1010_1010_1010_1010;

        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;

        fork
            begin : watchdog
                repeat (3000) @(negedge clk);
                if (!halted) begin
                    $display("[FAIL] watchdog expired before CPU halted (pc=0x%08h)", pc_out);
                    errors = errors + 1;
                end
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
        checks = checks + 1;
        if (!halted || illegal_instr || !ecall_seen) begin
            errors = errors + 1;
            $display("[FAIL] expected clean ECALL halt");
        end else begin
            $display("[PASS] clean ECALL halt");
        end

        check_bram_word("key_status", 32'h0001_1000, 32'h0000000A); // KEY[3:1]=101 -> 0xA
        check_bram_word("sw_level",   32'h0001_1004, 32'h0002AAAA);
        check_bram_word("timer_live", 32'h0001_1008, 32'd1);          // t1>t0: timer is free-running
        check_bram_word("data_copy",  32'h0001_100C, 32'hA5A5A5A5);    // ROM->RAM .data copy worked
        check_bram_word("ram_write",  32'h0001_1010, 32'h00C0FFEE);

        $display("------------------------------------------------------------");
        $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
        if (errors == 0) $display("M3_BUS_TEST_RESULT: PASS");
        else              $display("M3_BUS_TEST_RESULT: FAIL");
        $finish;
    end
endmodule
