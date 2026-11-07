// RV32IM multicycle core. Memory interface follows the picorv32 convention:
// a single valid/ready handshake, byte write-strobes, synchronous (1+ cycle
// latency) memory -- this generalizes directly to a shared bus with wait
// states once SDRAM/peripherals are attached in later milestones.
module cpu_core (
    input  logic        clk,
    input  logic        rst_n,

    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    output logic        mem_valid,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ready,

    output logic        halted,
    output logic        illegal_instr,
    output logic        ecall_seen,
    output logic        ebreak_seen,
    output logic [31:0] pc_out
);
    typedef enum logic [3:0] {
        S_FETCH, S_WAIT_IFETCH, S_EXEC, S_MEM_REQ, S_WAIT_MEM, S_WRITEBACK, S_HALT
    } state_t;
    state_t state;

    logic [31:0] pc;
    logic [31:0] instr;

    assign pc_out = pc;

    // ---- decode (combinational, off the latched instruction) ----
    logic [4:0]  rs1, rs2, rd;
    logic [2:0]  funct3;
    logic [31:0] imm;
    logic [3:0]  alu_op;
    logic is_lui, is_auipc, is_jal, is_jalr, is_branch, is_load, is_store;
    logic is_op_imm, is_op, is_muldiv, is_system, is_fence, illegal;

    rv32im_decoder u_dec (
        .instr(instr), .rs1(rs1), .rs2(rs2), .rd(rd), .funct3(funct3), .imm(imm),
        .alu_op(alu_op), .is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal),
        .is_jalr(is_jalr), .is_branch(is_branch), .is_load(is_load), .is_store(is_store),
        .is_op_imm(is_op_imm), .is_op(is_op), .is_muldiv(is_muldiv), .is_system(is_system),
        .is_fence(is_fence), .illegal(illegal)
    );

    // ---- register file ----
    logic        rf_we; // driven combinationally below (assign rf_we = ...), not from the FSM always_ff
    logic [31:0] rf_wdata;
    logic [31:0] rs1_data, rs2_data;

    rv32i_regfile u_regfile (
        .clk(clk), .rst_n(rst_n), .we(rf_we),
        .rs1(rs1), .rs2(rs2), .rd(rd), .wdata(rf_wdata),
        .rdata1(rs1_data), .rdata2(rs2_data)
    );

    // ---- ALU ----
    logic [31:0] alu_a, alu_b, alu_result;
    logic        alu_zero;

    always_comb begin
        alu_a = rs1_data;
        alu_b = imm;
        if (is_op || is_branch)
            alu_b = rs2_data;
    end

    rv32i_alu u_alu (
        .a(alu_a), .b(alu_b), .alu_op(alu_op), .result(alu_result), .zero(alu_zero)
    );

    // ---- sequential multiply/divide ----
    logic        md_start, md_busy, md_done;
    logic [31:0] md_result;

    rv32m_mul_div u_muldiv (
        .clk(clk), .rst_n(rst_n), .start(md_start), .op(funct3),
        .a(rs1_data), .b(rs2_data), .result(md_result), .busy(md_busy), .done(md_done)
    );

    // ---- dedicated adders for PC-relative targets (kept off the shared ALU) ----
    logic [31:0] pc_plus_imm, pc_plus_4;
    assign pc_plus_imm = pc + imm;
    assign pc_plus_4   = pc + 32'd4;

    // ---- branch resolution ----
    logic branch_taken;
    always_comb begin
        case (funct3)
            3'b000:  branch_taken = alu_zero;        // BEQ
            3'b001:  branch_taken = ~alu_zero;       // BNE
            3'b100:  branch_taken = alu_result[0];   // BLT  (alu_op=SLT)
            3'b101:  branch_taken = ~alu_result[0];  // BGE
            3'b110:  branch_taken = alu_result[0];   // BLTU (alu_op=SLTU)
            3'b111:  branch_taken = ~alu_result[0];  // BGEU
            default: branch_taken = 1'b0;
        endcase
    end

    // ---- latched address/result for the memory-access phase ----
    logic [31:0] addr_reg;
    logic [31:0] mem_rdata_reg;

    // ---- load/store byte-lane shaping ----
    logic [3:0]  store_wstrb;
    logic [31:0] store_wdata;
    always_comb begin
        case (funct3[1:0])
            2'b00: begin // byte
                store_wstrb = 4'b0001 << addr_reg[1:0];
                store_wdata = {rs2_data[7:0], rs2_data[7:0], rs2_data[7:0], rs2_data[7:0]};
            end
            2'b01: begin // half
                store_wstrb = addr_reg[1] ? 4'b1100 : 4'b0011;
                store_wdata = {rs2_data[15:0], rs2_data[15:0]};
            end
            default: begin // word
                store_wstrb = 4'b1111;
                store_wdata = rs2_data;
            end
        endcase
    end

    logic [31:0] load_value;
    logic [7:0]  load_byte;
    logic [15:0] load_half;
    always_comb begin
        load_byte = mem_rdata_reg[(int'(addr_reg[1:0]) * 8) +: 8];
        load_half = mem_rdata_reg[(int'(addr_reg[1]) * 16) +: 16];
        case (funct3)
            3'b000:  load_value = {{24{load_byte[7]}}, load_byte};   // LB
            3'b001:  load_value = {{16{load_half[15]}}, load_half}; // LH
            3'b010:  load_value = mem_rdata_reg;                    // LW
            3'b100:  load_value = {24'd0, load_byte};               // LBU
            3'b101:  load_value = {16'd0, load_half};                // LHU
            default: load_value = mem_rdata_reg;
        endcase
    end

    // ---- rd writeback value ----
    always_comb begin
        rf_wdata = 32'd0;
        if (is_lui)        rf_wdata = imm;
        else if (is_auipc) rf_wdata = pc_plus_imm;
        else if (is_jal)   rf_wdata = pc_plus_4;
        else if (is_jalr)  rf_wdata = pc_plus_4;
        else if (is_op || is_op_imm) rf_wdata = alu_result;
        else if (is_load)  rf_wdata = load_value;
        else if (is_muldiv) rf_wdata = md_result;
    end

    logic we_rd_comb;
    assign we_rd_comb = is_lui || is_auipc || is_jal || is_jalr || is_op || is_op_imm || is_load || is_muldiv;

    // rf_we MUST be combinational (state==S_WRITEBACK), not registered one
    // more cycle behind: pc advances to next_pc on the very same edge that
    // ends S_WRITEBACK, so a registered enable would let the regfile sample
    // rf_wdata (e.g. pc_plus_imm for AUIPC/JAL) using the NEXT instruction's
    // already-advanced pc instead of the retiring instruction's pc.
    assign rf_we = (state == S_WRITEBACK) && we_rd_comb;

    // ---- next PC ----
    logic [31:0] next_pc;
    always_comb begin
        if (is_jal)                       next_pc = pc_plus_imm;
        else if (is_jalr)                 next_pc = {alu_result[31:1], 1'b0};
        else if (is_branch && branch_taken) next_pc = pc_plus_imm;
        else                               next_pc = pc_plus_4;
    end

    // ---- main FSM ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_FETCH;
            pc            <= 32'd0;
            instr         <= 32'd0;
            mem_valid     <= 1'b0;
            mem_wstrb     <= 4'd0;
            md_start      <= 1'b0;
            halted        <= 1'b0;
            illegal_instr <= 1'b0;
            ecall_seen    <= 1'b0;
            ebreak_seen   <= 1'b0;
        end else begin
            md_start <= 1'b0;

            case (state)
                S_FETCH: begin
                    mem_addr  <= pc;
                    mem_wstrb <= 4'd0;
                    mem_valid <= 1'b1;
                    state     <= S_WAIT_IFETCH;
                end

                S_WAIT_IFETCH: begin
                    if (mem_ready) begin
                        instr     <= mem_rdata;
                        mem_valid <= 1'b0;
                        state     <= S_EXEC;
                    end
                end

                S_EXEC: begin
                    if (illegal) begin
                        illegal_instr <= 1'b1;
                        halted        <= 1'b1;
                        state         <= S_HALT;
                    end else if (is_system) begin
                        ecall_seen  <= ~instr[20];
                        ebreak_seen <= instr[20];
                        halted      <= 1'b1;
                        state       <= S_HALT;
                    end else if (is_muldiv) begin
                        if (!md_busy && !md_done) begin
                            md_start <= 1'b1;
                        end else if (md_done) begin
                            state <= S_WRITEBACK;
                        end
                    end else if (is_load || is_store) begin
                        addr_reg <= alu_result;
                        state    <= S_MEM_REQ;
                    end else begin
                        state <= S_WRITEBACK;
                    end
                end

                S_MEM_REQ: begin
                    mem_addr  <= addr_reg;
                    mem_wdata <= store_wdata;
                    mem_wstrb <= is_store ? store_wstrb : 4'd0;
                    mem_valid <= 1'b1;
                    state     <= S_WAIT_MEM;
                end

                S_WAIT_MEM: begin
                    if (mem_ready) begin
                        mem_rdata_reg <= mem_rdata;
                        mem_valid     <= 1'b0;
                        mem_wstrb     <= 4'd0;
                        state         <= S_WRITEBACK;
                    end
                end

                S_WRITEBACK: begin
                    pc    <= next_pc;
                    state <= S_FETCH;
                end

                S_HALT: begin
                    // remain halted; mem_valid stays low
                end

                default: state <= S_FETCH;
            endcase
        end
    end
endmodule
