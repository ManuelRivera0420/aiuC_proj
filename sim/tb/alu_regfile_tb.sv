module alu_regfile_tb;
    logic clk = 0;
    logic rst_n = 0;

    logic [31:0] alu_a, alu_b, alu_result;
    logic [3:0]  alu_op;
    logic        alu_zero;

    rv32i_alu dut_alu (
        .a(alu_a), .b(alu_b), .alu_op(alu_op),
        .result(alu_result), .zero(alu_zero)
    );

    logic        rf_we;
    logic [4:0]  rf_rs1, rf_rs2, rf_rd;
    logic [31:0] rf_wdata, rf_rdata1, rf_rdata2;

    rv32i_regfile dut_rf (
        .clk(clk), .rst_n(rst_n),
        .we(rf_we), .rs1(rf_rs1), .rs2(rf_rs2), .rd(rf_rd),
        .wdata(rf_wdata), .rdata1(rf_rdata1), .rdata2(rf_rdata2)
    );

    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    task check32(string name, logic [31:0] got, logic [31:0] exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[FAIL] %-28s got=0x%08h exp=0x%08h @t=%0t", name, got, exp, $time);
        end else begin
            $display("[PASS] %-28s got=0x%08h @t=%0t", name, got, $time);
        end
    endtask

    // ALU opcode encodings mirrored from rv32i_alu.sv
    localparam ALU_ADD  = 4'b0000;
    localparam ALU_SUB  = 4'b0001;
    localparam ALU_SLL  = 4'b0010;
    localparam ALU_SLT  = 4'b0011;
    localparam ALU_SLTU = 4'b0100;
    localparam ALU_XOR  = 4'b0101;
    localparam ALU_SRL  = 4'b0110;
    localparam ALU_SRA  = 4'b0111;
    localparam ALU_OR   = 4'b1000;
    localparam ALU_AND  = 4'b1001;

    initial begin
        rf_we = 0; rf_rs1 = 0; rf_rs2 = 0; rf_rd = 0; rf_wdata = 0;
        alu_a = 0; alu_b = 0; alu_op = 0;

        // ---- ALU directed vectors ----
        alu_a = 32'd10;        alu_b = 32'd15;        alu_op = ALU_ADD;  #1; check32("ADD 10+15",        alu_result, 32'd25);
        alu_a = 32'd5;         alu_b = 32'd20;        alu_op = ALU_SUB;  #1; check32("SUB 5-20 (wrap)",  alu_result, 32'hFFFFFFF1);
        alu_a = 32'h00000001;  alu_b = 32'd31;        alu_op = ALU_SLL;  #1; check32("SLL 1<<31",        alu_result, 32'h80000000);
        alu_a = -32'sd5;       alu_b = 32'd3;         alu_op = ALU_SLT;  #1; check32("SLT -5<3 signed",  alu_result, 32'd1);
        alu_a = 32'hFFFFFFFB;  alu_b = 32'd3;         alu_op = ALU_SLTU; #1; check32("SLTU big<3 unsgn", alu_result, 32'd0);
        alu_a = 32'hF0F0F0F0;  alu_b = 32'h0F0F0F0F;  alu_op = ALU_XOR;  #1; check32("XOR all-bits",     alu_result, 32'hFFFFFFFF);
        alu_a = 32'h80000000;  alu_b = 32'd4;         alu_op = ALU_SRL;  #1; check32("SRL logical",      alu_result, 32'h08000000);
        alu_a = 32'h80000000;  alu_b = 32'd4;         alu_op = ALU_SRA;  #1; check32("SRA arithmetic",   alu_result, 32'hF8000000);
        alu_a = 32'hAAAA0000;  alu_b = 32'h0000AAAA;  alu_op = ALU_OR;   #1; check32("OR disjoint",      alu_result, 32'hAAAAAAAA);
        alu_a = 32'hFFFFFFFF;  alu_b = 32'h12345678;  alu_op = ALU_AND;  #1; check32("AND identity",     alu_result, 32'h12345678);
        alu_a = 32'd7;         alu_b = 32'd7;         alu_op = ALU_SUB;  #1;
        if (!alu_zero) begin errors = errors + 1; $display("[FAIL] zero flag on 7-7"); end
        else $display("[PASS] zero flag on 7-7");

        // ---- Register file reset-to-zero check ----
        @(negedge clk); rst_n = 0; @(negedge clk); rst_n = 1;
        rf_rs1 = 5'd1; rf_rs2 = 5'd31; #1; check32("x1 after reset", rf_rdata1, 32'd0);
        check32("x31 after reset", rf_rdata2, 32'd0);

        // ---- x0 hardwired to zero: write attempt must not stick ----
        @(negedge clk);
        rf_we = 1; rf_rd = 5'd0; rf_wdata = 32'hDEADBEEF;
        @(negedge clk);
        rf_we = 0; rf_rs1 = 5'd0; #1;
        check32("x0 stays zero after write attempt", rf_rdata1, 32'd0);

        // ---- Ordinary write/read-back through two ports ----
        @(negedge clk);
        rf_we = 1; rf_rd = 5'd5; rf_wdata = 32'hCAFEF00D;
        @(negedge clk);
        rf_we = 0; rf_rs1 = 5'd5; rf_rs2 = 5'd5; #1;
        check32("x5 write/read port1", rf_rdata1, 32'hCAFEF00D);
        check32("x5 write/read port2", rf_rdata2, 32'hCAFEF00D);

        // ---- Independent write doesn't disturb other registers ----
        @(negedge clk);
        rf_we = 1; rf_rd = 5'd17; rf_wdata = 32'h0000BEEF;
        @(negedge clk);
        rf_we = 0; rf_rs1 = 5'd5; rf_rs2 = 5'd17; #1;
        check32("x5 unaffected by x17 write", rf_rdata1, 32'hCAFEF00D);
        check32("x17 holds new value",        rf_rdata2, 32'h0000BEEF);

        $display("----------------------------------------------------");
        $display("TOTAL CHECKS=%0d  ERRORS=%0d", checks, errors);
        if (errors == 0) $display("SANITY_CHECK_RESULT: PASS");
        else              $display("SANITY_CHECK_RESULT: FAIL");
        $finish;
    end
endmodule
