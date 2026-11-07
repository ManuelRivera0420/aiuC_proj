// M2 bring-up: runs real compiled C (firmware/tests/m2_bringup_main.c +
// firmware/startup/crt0.S, linked with firmware/linker/de2_115.ld) on
// cpu_core.sv and checks the MMIO-style memory addresses it writes against
// independently-known expected values (see that C file's comments).
module firmware_m2_tb;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic [3:0]  mem_wstrb;
    logic        mem_valid, mem_ready;
    logic        halted, illegal_instr, ecall_seen, ebreak_seen;
    logic [31:0] pc_out;

    cpu_core dut (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_valid(mem_valid), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .halted(halted), .illegal_instr(illegal_instr),
        .ecall_seen(ecall_seen), .ebreak_seen(ebreak_seen), .pc_out(pc_out)
    );

    // 64 KiB, matching firmware/linker/de2_115.ld's RAM region.
    sync_mem #(.WORDS(16384), .INIT_FILE("firmware/build/m2_bringup.hex")) u_mem (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_valid(mem_valid), .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    integer errors = 0;
    integer checks = 0;

    task check_mem_word(string name, logic [31:0] byte_addr, logic [31:0] exp);
        logic [31:0] got;
        got = u_mem.mem[byte_addr >> 2];
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] mem[0x%04h] %-16s got=0x%08h exp=0x%08h", byte_addr, name, got, exp);
        end else begin
            $display("[PASS] mem[0x%04h] %-16s = 0x%08h", byte_addr, name, got);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;

        fork
            begin : watchdog
                repeat (2000) @(negedge clk);
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
            $display("[PASS] clean ECALL halt (main() returned, crt0 executed ecall)");
        end

        check_mem_word("g_initialized",  32'h2000, 32'h1234ABCD); // .data loaded correctly
        check_mem_word("g_zero(cleared)",32'h2004, 32'h00000000); // crt0's .bss clear actually ran
        check_mem_word("stack_sum",      32'h2008, 32'd14);        // 0+1+4+9, stack-resident array+loop
        check_mem_word("call_return",    32'h200C, 32'd333);        // 111+222 via a real function call
        check_mem_word("bss_writable",   32'h2010, 32'hCAFEBABE);    // .bss is ordinary writable RAM after startup

        $display("------------------------------------------------------------");
        $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
        if (errors == 0) $display("M2_FIRMWARE_TEST_RESULT: PASS");
        else              $display("M2_FIRMWARE_TEST_RESULT: FAIL");
        $finish;
    end
endmodule
