// RV32IM combinational instruction decoder + immediate generator.
// Produces control fields consumed by cpu_core.sv's multicycle FSM.
module rv32im_decoder (
    input  logic [31:0] instr,

    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [4:0]  rd,
    output logic [2:0]  funct3,
    output logic [31:0] imm,

    output logic [3:0]  alu_op,      // encoding matches rv32i_alu.sv localparams

    output logic        is_lui,
    output logic        is_auipc,
    output logic        is_jal,
    output logic        is_jalr,
    output logic        is_branch,
    output logic        is_load,
    output logic        is_store,
    output logic        is_op_imm,
    output logic        is_op,
    output logic        is_muldiv,
    output logic        is_system,   // ECALL/EBREAK
    output logic        is_fence,    // treated as NOP
    output logic         illegal
);
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

    logic [6:0] opcode;
    logic [6:0] funct7;

    assign opcode = instr[6:0];
    assign funct7 = instr[31:25];
    assign funct3 = instr[14:12];
    assign rd     = instr[11:7];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];

    localparam OPCODE_LOAD    = 7'b0000011;
    localparam OPCODE_FENCE   = 7'b0001111;
    localparam OPCODE_OP_IMM  = 7'b0010011;
    localparam OPCODE_AUIPC   = 7'b0010111;
    localparam OPCODE_STORE   = 7'b0100011;
    localparam OPCODE_OP      = 7'b0110011;
    localparam OPCODE_LUI     = 7'b0110111;
    localparam OPCODE_BRANCH  = 7'b1100011;
    localparam OPCODE_JALR    = 7'b1100111;
    localparam OPCODE_JAL     = 7'b1101111;
    localparam OPCODE_SYSTEM  = 7'b1110011;

    // Immediate formats
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    assign imm_i = {{20{instr[31]}}, instr[31:20]};
    assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    assign imm_u = {instr[31:12], 12'b0};
    assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    always_comb begin
        is_lui    = 1'b0;
        is_auipc  = 1'b0;
        is_jal    = 1'b0;
        is_jalr   = 1'b0;
        is_branch = 1'b0;
        is_load   = 1'b0;
        is_store  = 1'b0;
        is_op_imm = 1'b0;
        is_op     = 1'b0;
        is_muldiv = 1'b0;
        is_system = 1'b0;
        is_fence  = 1'b0;
        illegal   = 1'b0;
        imm       = 32'd0;
        alu_op    = ALU_ADD;

        case (opcode)
            OPCODE_LUI: begin
                is_lui = 1'b1;
                imm    = imm_u;
            end
            OPCODE_AUIPC: begin
                is_auipc = 1'b1;
                imm      = imm_u;
            end
            OPCODE_JAL: begin
                is_jal = 1'b1;
                imm    = imm_j;
            end
            OPCODE_JALR: begin
                is_jalr = 1'b1;
                imm     = imm_i;
            end
            OPCODE_BRANCH: begin
                is_branch = 1'b1;
                imm       = imm_b;
                case (funct3)
                    3'b000, 3'b001: alu_op = ALU_SUB;  // BEQ/BNE via subtraction + zero
                    3'b100, 3'b101: alu_op = ALU_SLT;  // BLT/BGE
                    3'b110, 3'b111: alu_op = ALU_SLTU; // BLTU/BGEU
                    default:        illegal = 1'b1;
                endcase
            end
            OPCODE_LOAD: begin
                is_load = 1'b1;
                imm     = imm_i;
                alu_op  = ALU_ADD;
                if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111)
                    illegal = 1'b1; // no LD/unused encodings in RV32I
            end
            OPCODE_STORE: begin
                is_store = 1'b1;
                imm      = imm_s;
                alu_op   = ALU_ADD;
                if (funct3 != 3'b000 && funct3 != 3'b001 && funct3 != 3'b010)
                    illegal = 1'b1;
            end
            OPCODE_OP_IMM: begin
                is_op_imm = 1'b1;
                imm       = imm_i;
                case (funct3)
                    3'b000: alu_op = ALU_ADD;
                    3'b010: alu_op = ALU_SLT;
                    3'b011: alu_op = ALU_SLTU;
                    3'b100: alu_op = ALU_XOR;
                    3'b110: alu_op = ALU_OR;
                    3'b111: alu_op = ALU_AND;
                    3'b001: alu_op = ALU_SLL;
                    3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                    default: illegal = 1'b1;
                endcase
            end
            OPCODE_OP: begin
                if (funct7 == 7'b0000001) begin
                    is_muldiv = 1'b1;
                end else begin
                    is_op = 1'b1;
                    case (funct3)
                        3'b000: alu_op = funct7[5] ? ALU_SUB : ALU_ADD;
                        3'b001: alu_op = ALU_SLL;
                        3'b010: alu_op = ALU_SLT;
                        3'b011: alu_op = ALU_SLTU;
                        3'b100: alu_op = ALU_XOR;
                        3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                        3'b110: alu_op = ALU_OR;
                        3'b111: alu_op = ALU_AND;
                        default: illegal = 1'b1;
                    endcase
                    if (funct7 != 7'b0000000 && funct7 != 7'b0100000)
                        illegal = 1'b1;
                end
            end
            OPCODE_SYSTEM: begin
                // Only plain ECALL/EBREAK (funct3==0, no Zicsr) are supported in M1.
                if (funct3 == 3'b000)
                    is_system = 1'b1;
                else
                    illegal = 1'b1; // CSR instructions: out of scope, flagged rather than misread as ECALL/EBREAK
            end
            OPCODE_FENCE: begin
                is_fence = 1'b1;
            end
            default: illegal = 1'b1;
        endcase
    end
endmodule
