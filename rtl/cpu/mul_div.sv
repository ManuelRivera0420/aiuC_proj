// Sequential (32-cycle) RV32M multiplier/divider.
// op encodes funct3 of the M-extension OP instructions:
//   000 MUL  001 MULH  010 MULHSU  011 MULHU
//   100 DIV  101 DIVU  110 REM     111 REMU
module rv32m_mul_div (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [2:0]  op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result,
    output logic        busy,
    output logic        done
);
    typedef enum logic [1:0] {ST_IDLE, ST_RUN, ST_DONE} state_t;
    state_t state;

    logic [5:0]  count;
    logic        is_mul;
    logic        a_sign_use, b_sign_use; // whether operand treated as signed for this op
    logic        a_neg, b_neg;
    logic [31:0] a_mag, b_mag;

    // ---- multiply datapath: 64-bit shift/add over magnitudes ----
    logic [63:0] mul_acc;
    logic [63:0] mul_mcand;  // multiplicand shifted left each cycle
    logic [31:0] mul_mplier;

    // ---- divide datapath: standard restoring division over magnitudes ----
    logic [63:0] div_rem;    // {remainder_hi(32), partial_dividend_lo(32)} shift register
    logic [31:0] div_quot;
    logic [31:0] div_divisor;

    // ---- values captured at launch, needed when forming the signed result ----
    logic [2:0]  op_q;
    logic        a_neg_q, b_neg_q;
    logic [31:0] a_q;
    logic        divisor_zero_q;

    assign is_mul = (op == 3'b000) || (op == 3'b001) || (op == 3'b010) || (op == 3'b011);

    always_comb begin
        case (op)
            3'b000:  begin a_sign_use = 1'b1; b_sign_use = 1'b1; end // MUL
            3'b001:  begin a_sign_use = 1'b1; b_sign_use = 1'b1; end // MULH
            3'b010:  begin a_sign_use = 1'b1; b_sign_use = 1'b0; end // MULHSU
            3'b011:  begin a_sign_use = 1'b0; b_sign_use = 1'b0; end // MULHU
            3'b100:  begin a_sign_use = 1'b1; b_sign_use = 1'b1; end // DIV
            3'b101:  begin a_sign_use = 1'b0; b_sign_use = 1'b0; end // DIVU
            3'b110:  begin a_sign_use = 1'b1; b_sign_use = 1'b1; end // REM
            default: begin a_sign_use = 1'b0; b_sign_use = 1'b0; end // REMU
        endcase
    end

    assign a_neg = a_sign_use && a[31];
    assign b_neg = b_sign_use && b[31];
    assign a_mag = a_neg ? (~a + 32'd1) : a;
    assign b_mag = b_neg ? (~b + 32'd1) : b;

    logic [63:0] shifted;
    logic [31:0] trial;
    logic [63:0] signed_prod;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= ST_IDLE;
            busy   <= 1'b0;
            done   <= 1'b0;
            count  <= 6'd0;
            result <= 32'd0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        op_q           <= op;
                        a_neg_q        <= a_neg;
                        b_neg_q        <= b_neg;
                        a_q            <= a;
                        divisor_zero_q <= (b == 32'd0);
                        busy           <= 1'b1;
                        count          <= 6'd0;
                        if (is_mul) begin
                            mul_acc    <= 64'd0;
                            mul_mcand  <= {32'd0, a_mag};
                            mul_mplier <= b_mag;
                        end else begin
                            div_rem     <= {32'd0, a_mag};
                            div_quot    <= 32'd0;
                            div_divisor <= b_mag;
                        end
                        state <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    if (is_mul) begin
                        if (mul_mplier[0])
                            mul_acc <= mul_acc + mul_mcand;
                        mul_mcand  <= mul_mcand << 1;
                        mul_mplier <= mul_mplier >> 1;
                    end else begin
                        // restoring division, one bit per cycle, MSB-first
                        shifted = div_rem << 1;
                        trial   = shifted[63:32] - div_divisor;
                        if (shifted[63:32] >= div_divisor) begin
                            div_rem  <= {trial, shifted[31:0]};
                            div_quot <= {div_quot[30:0], 1'b1};
                        end else begin
                            div_rem  <= shifted;
                            div_quot <= {div_quot[30:0], 1'b0};
                        end
                    end

                    if (count == 6'd31)
                        state <= ST_DONE;
                    count <= count + 6'd1;
                end

                ST_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                    case (op_q)
                        3'b000: result <= mul_acc[31:0]; // MUL
                        3'b001, 3'b010, 3'b011: begin // MULH/MULHSU/MULHU: sign-correct the 64b product
                            signed_prod = mul_acc;
                            if (a_neg_q ^ b_neg_q)
                                signed_prod = ~signed_prod + 64'd1;
                            result <= signed_prod[63:32];
                        end
                        3'b100: begin // DIV
                            if (divisor_zero_q)
                                result <= 32'hFFFFFFFF;
                            else if (a_neg_q != b_neg_q)
                                result <= (~div_quot + 32'd1);
                            else
                                result <= div_quot;
                        end
                        3'b101: result <= div_quot; // DIVU
                        3'b110: begin // REM
                            if (divisor_zero_q)
                                result <= a_q;
                            else if (a_neg_q)
                                result <= (~div_rem[63:32] + 32'd1);
                            else
                                result <= div_rem[63:32];
                        end
                        default: begin // REMU
                            if (divisor_zero_q)
                                result <= a_q;
                            else
                                result <= div_rem[63:32];
                        end
                    endcase
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
