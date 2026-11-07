// M1 directed-test harness for cpu_core.sv. Runs sim/tb/asm/cpu_directed_test.S
// (assembled with the real riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32,
// see scripts/riscv_env.sh and scripts/bin_to_readmemh.py) and checks final
// architectural state against values computed BY HAND from the assembly
// source, not from anything the CPU itself produced -- see the comment block
// in cpu_directed_test.S and docs/verification_report.md for the derivation
// of every expected value below.
module cpu_core_tb;
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

    sync_mem #(.WORDS(16384), .INIT_FILE("sim/models/program.hex")) u_mem (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_valid(mem_valid), .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    integer errors = 0;
    integer checks = 0;

    task check_reg(string name, int idx, logic [31:0] exp);
        logic [31:0] got;
        got = dut.u_regfile.regs[idx];
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] x%-2d %-6s got=0x%08h exp=0x%08h", idx, name, got, exp);
        end else begin
            $display("[PASS] x%-2d %-6s = 0x%08h", idx, name, got);
        end
    endtask

    task check_mem_word(string name, logic [31:0] byte_addr, logic [31:0] exp);
        logic [31:0] got;
        got = u_mem.mem[byte_addr >> 2];
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] mem[0x%04h] %-10s got=0x%08h exp=0x%08h", byte_addr, name, got, exp);
        end else begin
            $display("[PASS] mem[0x%04h] %-10s = 0x%08h", byte_addr, name, got);
        end
    endtask

    task check_mem_byte(string name, logic [31:0] byte_addr, logic [7:0] exp);
        logic [31:0] word;
        logic [7:0]  got;
        word = u_mem.mem[byte_addr >> 2];
        got  = word[(int'(byte_addr[1:0]) * 8) +: 8];
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] mem8[0x%04h] %-10s got=0x%02h exp=0x%02h", byte_addr, name, got, exp);
        end else begin
            $display("[PASS] mem8[0x%04h] %-10s = 0x%02h", byte_addr, name, got);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;

        // Run until the CPU halts (ECALL) or a generous cycle budget expires.
        // Each instruction here takes a handful of FSM cycles (fetch+exec[+mem]+wb);
        // 66 instructions, worst case ~6 cycles each plus two 32-cycle MUL/DIV/REM
        // sequences, comfortably fits in 5000 cycles.
        fork
            begin : watchdog
                repeat (5000) @(negedge clk);
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
        $display("CPU status: halted=%0b illegal_instr=%0b ecall_seen=%0b ebreak_seen=%0b pc=0x%08h",
                  halted, illegal_instr, ecall_seen, ebreak_seen, pc_out);
        checks = checks + 1;
        if (!halted || illegal_instr || !ecall_seen || ebreak_seen) begin
            errors = errors + 1;
            $display("[FAIL] expected clean ECALL halt (halted=1, illegal_instr=0, ecall_seen=1, ebreak_seen=0)");
        end else begin
            $display("[PASS] clean ECALL halt");
        end

        // ---- ALU reg-reg / reg-imm (x1=5, x2=7 at the time these executed) ----
        check_reg("x2",  2,  32'd7);
        check_reg("x3",  3,  32'd12);          // add x1,x2
        check_reg("x4",  4,  32'd2);            // sub x2,x1
        check_reg("x5",  5,  32'd20);            // slli x1,2
        check_reg("x6",  6,  32'd6);              // andi x2,0x6
        check_reg("x7",  7,  32'd13);               // ori x1,0x8
        check_reg("x8",  8,  32'd250);               // xori x1,0xFF
        check_reg("x9",  9,  32'd1);                   // slt x1,x2
        check_reg("x10", 10, 32'd0);                    // sltu x2,x1

        // ---- auipc + jalr self-relative jump ----
        check_reg("x30", 30, 32'd0);            // must stay 0 (skipped instruction)
        check_reg("x31", 31, 32'h900DF00D);      // landing point reached

        // ---- lui ----
        check_reg("x12", 12, 32'h12345000);

        // ---- signed vs unsigned compare (x13=-1, x1=5) ----
        check_reg("x23", 23, 32'd1);   // slt  -1,5  -> 1 (signed: -1 < 5)
        check_reg("x26", 26, 32'd0);   // sltu -1,5  -> 0 (unsigned: 0xFFFFFFFF not < 5)

        // ---- load/store ----
        check_reg("x15", 15, 32'd100);  // lw back from mem[0x1000]
        check_reg("x16", 16, 32'd5);     // lbu mem[0x1004]
        check_reg("x17", 17, 32'd5);      // lb  mem[0x1004] (sign bit 0, same as zero-extend)

        // ---- M extension ----
        check_reg("x18", 18, 32'd35);  // mul 5*7
        check_reg("x19", 19, 32'd1);    // div 7/5
        check_reg("x21", 21, 32'd2);     // rem 7%5

        // ---- branches ----
        check_reg("x22", 22, 32'hBAD0);    // beq taken (sentinel preserved)
        check_reg("x24", 24, 32'hBAD1);     // bne taken (sentinel preserved)
        check_reg("x25", 25, 32'h600D2);     // beq NOT taken (fallthrough executed)

        // ---- jal/jalr call-return round trip ----
        check_reg("x27", 27, 32'h1111);  // pre-call marker
        check_reg("x29", 29, 32'h2222);   // inside-function marker
        check_reg("x28", 28, 32'h3333);    // post-return marker (proves jalr returned correctly)

        // ---- memory contents from stores ----
        check_mem_word("sw@0x1000", 32'h1000, 32'd100);
        check_mem_byte("sb@0x1004", 32'h1004, 8'd5);
        check_mem_byte("sb@0x1005", 32'h1005, 8'd7);     // non-zero byte lane
        check_mem_word("blt_mark",  32'h1008, 32'hB1);   // BLT took the branch (signed)
        check_mem_word("bgeu_mark", 32'h100C, 32'hB2);   // BGEU took the branch (unsigned)

        $display("------------------------------------------------------------");
        $display("TOTAL CHECKS=%0d ERRORS=%0d", checks, errors);
        if (errors == 0) $display("M1_CPU_TEST_RESULT: PASS");
        else              $display("M1_CPU_TEST_RESULT: FAIL");
        $finish;
    end
endmodule
