// SDR SDRAM controller: picorv32-style bus port in, DE2-115 Table 4-28 SDRAM
// pins out. Close-page (auto-precharge-after-every-access) policy -- the
// simplest correct policy, at the cost of row-locality performance, which
// is an acceptable M3 starting point; an open-page optimization is a later,
// measured improvement if bandwidth analysis in M4/M5 shows it's needed.
//
// IMPORTANT ASSUMED GEOMETRY: the DE2-115 manual (Table 4-28, Section 2)
// gives total capacity (128MB, 32Mx32bit across two chips) and pins, but
// NOT the exact per-chip row/column/bank geometry -- no SDRAM datasheet is
// attached to this project. This controller assumes a conventional 4-bank,
// 13-bit-row, 10-bit-column mapping (4*8192*1024 = 32M words = exactly
// 128MB/4), which is a REASONABLE SDR SDRAM geometry but NOT confirmed
// against the board's actual installed chips. The human team must verify
// this against the real SDRAM part number (silkscreen/datasheet) before
// trusting read/write correctness on physical hardware -- flagged here and
// in docs/known_limitations.md, not silently assumed as fact.
//
// Timing parameters below are conservative, typical SDR-SDRAM-class values
// (JEDEC-generic, not from a specific verified datasheet) at a 50MHz
// controller clock: tRCD=2 cycles, CL=2 cycles, tRP=2 cycles, power-up wait
// ~100us (5000 cycles), refresh interval ~7.8us (390 cycles, matching the
// standard 8192-refreshes/64ms spec). All are module parameters so the
// human team can retune them once the real chip's datasheet is in hand.
module sdram_ctrl #(
    parameter int T_RCD      = 2,
    parameter int T_CL       = 2,
    parameter int T_RP       = 2,
    parameter int POWERUP_CYCLES    = 5000,
    parameter int REFRESH_INTERVAL  = 390
) (
    input  logic        clk,
    input  logic        rst_n,

    // picorv32-style bus port (byte address; this controller only supports
    // word-aligned 32-bit accesses, matching cpu_core.sv's own alignment)
    input  logic [31:0] mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_wstrb,
    input  logic        mem_valid,
    output logic [31:0] mem_rdata,
    output logic        mem_ready,

    // DE2-115 Table 4-28 pins
    output logic [12:0] dram_addr,
    output logic [1:0]  dram_ba,
    inout  wire  [31:0] dram_dq,
    output logic [3:0]  dram_dqm,
    output logic        dram_ras_n,
    output logic        dram_cas_n,
    output logic        dram_we_n,
    output logic        dram_cs_n,
    output logic        dram_cke,
    output logic        dram_clk
);
    assign dram_clk = clk;
    assign dram_cke = 1'b1; // never self-refresh/power-down in this design

    // ---- address decomposition (see geometry note in the header) ----
    logic [24:0] word_addr;
    logic [1:0]  bank;
    logic [12:0] row;
    logic [9:0]  col;
    assign word_addr = mem_addr[26:2];
    assign bank = word_addr[24:23];
    assign row  = word_addr[22:10];
    assign col  = word_addr[9:0];

    // ---- tri-state data bus ----
    logic        dq_drive;
    logic [31:0] dq_out;
    assign dram_dq = dq_drive ? dq_out : 32'bz;

    typedef enum logic [3:0] {
        S_POWERUP, S_INIT_PRECHARGE, S_INIT_REFRESH1, S_INIT_WAIT1,
        S_INIT_REFRESH2, S_INIT_WAIT2, S_INIT_MRS, S_INIT_WAIT3,
        S_IDLE, S_ACTIVATE, S_RCD_WAIT, S_ACCESS, S_CAS_WAIT, S_PRECHARGE_WAIT,
        S_REFRESH, S_REFRESH_WAIT
    } state_t;
    state_t state;

    logic [15:0] wait_ctr;
    logic [15:0] refresh_ctr;
    logic        refresh_pending;
    logic        pending_we;
    logic [31:0] pending_wdata;
    logic [3:0]  pending_wstrb;
    logic [31:0] rdata_q;

    // ---- SDRAM command outputs: default NOP every cycle unless overridden ----
    task automatic cmd_nop();
        dram_cs_n = 1'b0; dram_ras_n = 1'b1; dram_cas_n = 1'b1; dram_we_n = 1'b1;
    endtask

    always_comb begin
        // defaults (NOP); overridden below per-state where a real command issues
        dram_cs_n  = 1'b0;
        dram_ras_n = 1'b1;
        dram_cas_n = 1'b1;
        dram_we_n  = 1'b1;
        dram_addr  = 13'd0;
        dram_ba    = 2'd0;
        dram_dqm   = 4'd0;
        dq_drive   = 1'b0;
        dq_out     = 32'd0;
        mem_rdata  = rdata_q;

        case (state)
            S_INIT_PRECHARGE: begin
                dram_ras_n = 1'b0; dram_cas_n = 1'b1; dram_we_n = 1'b0;
                dram_addr[10] = 1'b1; // precharge ALL banks
            end
            S_INIT_REFRESH1, S_INIT_REFRESH2, S_REFRESH: begin
                dram_ras_n = 1'b0; dram_cas_n = 1'b0; dram_we_n = 1'b1;
            end
            S_INIT_MRS: begin
                dram_ras_n = 1'b0; dram_cas_n = 1'b0; dram_we_n = 1'b0;
                // mode register: burst length=1 (000), sequential (0), CAS latency=2 (010)
                dram_addr = 13'b0_000_0_010_0_000;
            end
            S_ACTIVATE: begin
                dram_ras_n = 1'b0; dram_cas_n = 1'b1; dram_we_n = 1'b1;
                dram_addr = row;
                dram_ba   = bank;
            end
            S_ACCESS: begin
                dram_ba   = bank;
                dram_addr = {2'b00, col}; // A10=1 (bit10 of col range is 0 here since col<1024<2^10... ensure A10 set for auto-precharge below
                dram_addr[10] = 1'b1; // auto-precharge
                if (pending_we) begin
                    dram_ras_n = 1'b1; dram_cas_n = 1'b0; dram_we_n = 1'b0;
                    dram_dqm = ~pending_wstrb;
                    dq_drive = 1'b1;
                    dq_out   = pending_wdata;
                end else begin
                    dram_ras_n = 1'b1; dram_cas_n = 1'b0; dram_we_n = 1'b1;
                end
            end
            default: ; // NOP (defaults above already apply)
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_POWERUP;
            wait_ctr <= 16'd0;
            refresh_ctr <= 16'd0;
            refresh_pending <= 1'b0;
            rdata_q <= 32'd0;
        end else begin
            // periodic refresh request counter runs independent of state
            if (refresh_ctr >= REFRESH_INTERVAL - 1) begin
                refresh_ctr <= 16'd0;
                refresh_pending <= 1'b1;
            end else begin
                refresh_ctr <= refresh_ctr + 16'd1;
            end

            case (state)
                S_POWERUP: begin
                    if (wait_ctr >= POWERUP_CYCLES - 1) begin
                        wait_ctr <= 16'd0;
                        state <= S_INIT_PRECHARGE;
                    end else wait_ctr <= wait_ctr + 16'd1;
                end
                S_INIT_PRECHARGE: state <= S_INIT_REFRESH1;
                S_INIT_REFRESH1:  state <= S_INIT_WAIT1;
                S_INIT_WAIT1: begin
                    if (wait_ctr >= 8) begin wait_ctr <= 16'd0; state <= S_INIT_REFRESH2; end
                    else wait_ctr <= wait_ctr + 16'd1;
                end
                S_INIT_REFRESH2: state <= S_INIT_WAIT2;
                S_INIT_WAIT2: begin
                    if (wait_ctr >= 8) begin wait_ctr <= 16'd0; state <= S_INIT_MRS; end
                    else wait_ctr <= wait_ctr + 16'd1;
                end
                S_INIT_MRS: state <= S_INIT_WAIT3;
                S_INIT_WAIT3: begin
                    if (wait_ctr >= 2) begin wait_ctr <= 16'd0; state <= S_IDLE; end
                    else wait_ctr <= wait_ctr + 16'd1;
                end

                S_IDLE: begin
                    if (refresh_pending) begin
                        refresh_pending <= 1'b0;
                        state <= S_REFRESH;
                    end else if (mem_valid) begin
                        pending_we    <= (mem_wstrb != 4'd0);
                        pending_wdata <= mem_wdata;
                        pending_wstrb <= mem_wstrb;
                        state <= S_ACTIVATE;
                    end
                end

                S_ACTIVATE: begin
                    wait_ctr <= 16'd0;
                    state <= S_RCD_WAIT;
                end
                S_RCD_WAIT: begin
                    if (wait_ctr >= T_RCD - 1) begin
                        wait_ctr <= 16'd0;
                        state <= S_ACCESS;
                    end else wait_ctr <= wait_ctr + 16'd1;
                end
                S_ACCESS: begin
                    if (pending_we) begin
                        state <= S_PRECHARGE_WAIT; // write data already placed this cycle
                        wait_ctr <= 16'd0;
                    end else begin
                        state <= S_CAS_WAIT;
                        wait_ctr <= 16'd0;
                    end
                end
                S_CAS_WAIT: begin
                    if (wait_ctr >= T_CL - 1) begin
                        rdata_q <= dram_dq;
                        wait_ctr <= 16'd0;
                        state <= S_PRECHARGE_WAIT;
                    end else wait_ctr <= wait_ctr + 16'd1;
                end
                S_PRECHARGE_WAIT: begin
                    // auto-precharge already triggered by A10 during S_ACCESS;
                    // just wait tRP before the bus can report completion.
                    if (wait_ctr >= T_RP - 1) begin
                        wait_ctr <= 16'd0;
                        state <= S_IDLE;
                    end else wait_ctr <= wait_ctr + 16'd1;
                end

                S_REFRESH: state <= S_REFRESH_WAIT;
                S_REFRESH_WAIT: begin
                    if (wait_ctr >= 8) begin wait_ctr <= 16'd0; state <= S_IDLE; end
                    else wait_ctr <= wait_ctr + 16'd1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // mem_ready pulses for exactly one cycle, the cycle the access completes
    always_comb begin
        mem_ready = (state == S_PRECHARGE_WAIT) && (wait_ctr == T_RP - 1);
    end
endmodule
