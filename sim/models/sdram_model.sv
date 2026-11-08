// Behavioral SDR SDRAM model for testing sdram_ctrl.sv's command sequencing
// and data correctness. Tracks the activated {bank,row} like real SDRAM
// (so a READ/WRITE to the wrong row after a bad ACTIVATE would read back
// wrong data), stores contents in a sparse associative array (simulation-
// only technique -- not synthesizable, and not meant to be), and honors
// the CAS latency for read data timing. Does not model refresh data decay
// or power-up timing restrictions beyond what's needed to catch controller
// sequencing bugs (e.g. issuing ACTIVATE/READ before the controller's own
// init sequence would have issued PRECHARGE/REFRESH/MRS first).
module sdram_model #(
    parameter int CAS_LATENCY = 2,

    // ---- M5 S3 test-only direct preload ----
    // Bypasses the slow, already-verified-at-small-scale SD/bootloader
    // copy path (M4) for large-payload tests where simulating a
    // realistic CMD17 transfer would cost an impractical amount of
    // simulated time (see docs/verification_report.md's M5 section).
    // Each region is optional (empty *_FILE = skip) and is populated
    // once, in simulation time 0 before any clock edge -- this is
    // exactly as synthesizable as $readmemh itself, i.e. not at all;
    // it exists only so a testbench can get real program/data content
    // into this behavioral model's backing store without re-proving
    // the SD path at a scale it was never meant to be driven at.
    parameter string        PRELOAD1_FILE       = "",
    parameter int           PRELOAD1_WORDS      = 0,
    parameter logic [31:0]  PRELOAD1_BYTE_BASE  = 32'h0,
    parameter string        PRELOAD2_FILE       = "",
    parameter int           PRELOAD2_WORDS      = 0,
    parameter logic [31:0]  PRELOAD2_BYTE_BASE  = 32'h0
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [12:0] dram_addr,
    input  logic [1:0]  dram_ba,
    inout  wire  [31:0] dram_dq,
    input  logic [3:0]  dram_dqm,
    input  logic        dram_ras_n,
    input  logic        dram_cas_n,
    input  logic        dram_we_n,
    input  logic        dram_cs_n,
    input  logic        dram_cke,

    // test/debug visibility (not part of the real chip's pins)
    output logic [31:0] command_count_activate,
    output logic [31:0] command_count_read,
    output logic [31:0] command_count_write,
    output logic [31:0] command_count_refresh,
    output logic [31:0] command_count_precharge,
    output logic [31:0] command_count_mrs,
    output logic        saw_read_before_activate_error,
    output logic        saw_write_before_activate_error
);
    typedef enum logic [2:0] {CMD_NOP, CMD_ACTIVATE, CMD_READ, CMD_WRITE, CMD_PRECHARGE, CMD_REFRESH, CMD_MRS} cmd_t;
    cmd_t cmd;

    always_comb begin
        if (dram_cs_n) cmd = CMD_NOP;
        else if (!dram_ras_n && dram_cas_n && dram_we_n)       cmd = CMD_ACTIVATE;
        else if (dram_ras_n && !dram_cas_n && dram_we_n)        cmd = CMD_READ;
        else if (dram_ras_n && !dram_cas_n && !dram_we_n)        cmd = CMD_WRITE;
        else if (!dram_ras_n && dram_cas_n && !dram_we_n)         cmd = CMD_PRECHARGE;
        else if (!dram_ras_n && !dram_cas_n && dram_we_n)          cmd = CMD_REFRESH;
        else if (!dram_ras_n && !dram_cas_n && !dram_we_n)          cmd = CMD_MRS;
        else cmd = CMD_NOP;
    end

    // associative-array backing store, keyed by {bank,row,col} packed into one int
    logic [31:0] mem_store [logic [26:0]];

    logic activated;
    logic [1:0]  act_bank;
    logic [12:0] act_row;

    logic [26:0] write_key;
    logic [31:0] write_prev;
    logic [31:0] write_merged;

    // Read-data pipeline for CAS latency: depth CAS_LATENCY (not +1), and
    // dq_drive/dq_out are COMBINATIONAL off index[0] below -- not an extra
    // registered stage -- so that data lands on dram_dq exactly
    // CAS_LATENCY cycles after the READ command, matching what
    // sdram_ctrl.sv actually waits for. (An earlier version used a
    // CAS_LATENCY+1-deep pipeline AND a registered dq_drive/dq_out,
    // which added two extra cycles of latency the controller wasn't
    // waiting for -- caught by sdram_ctrl_tb.sv reading back 'z instead
    // of the written data.)
    logic [31:0] read_pipe [CAS_LATENCY-1:0];
    logic        read_valid_pipe [CAS_LATENCY-1:0];
    logic        dq_drive;
    logic [31:0] dq_out;
    assign dq_drive = read_valid_pipe[0];
    assign dq_out   = read_pipe[0];
    assign dram_dq  = dq_drive ? dq_out : 32'bz;

    function automatic logic [26:0] pack_key(logic [1:0] b, logic [12:0] r, logic [9:0] c);
        pack_key = {b, r, c};
    endfunction

    // ---- test-only bulk preload (see module header) ----
    // $readmemh only ever targets preload1_mem/preload2_mem here (never
    // mem_store directly) so this initial block doesn't become a second
    // process writing mem_store -- the actual mem_store[...] = ... copy
    // happens inside the always_ff below, in its reset branch, which is
    // the SAME process as mem_store's other writer (the CMD_WRITE case
    // further down). Splitting it into a separate initial block instead
    // hit ZEN-6033 (LRM 9.2.2.4: a variable written by an always_ff
    // procedure and by another process of the same instance, with
    // overlapping static prefixes, is forbidden) -- the exact same bug
    // class as M1's sync_mem.sv fix, just via a different code path.
    logic [31:0] preload1_mem [0:(PRELOAD1_WORDS > 0 ? PRELOAD1_WORDS : 1) - 1];
    logic [31:0] preload2_mem [0:(PRELOAD2_WORDS > 0 ? PRELOAD2_WORDS : 1) - 1];
    initial begin
        if (PRELOAD1_FILE != "" && PRELOAD1_WORDS > 0) $readmemh(PRELOAD1_FILE, preload1_mem);
        if (PRELOAD2_FILE != "" && PRELOAD2_WORDS > 0) $readmemh(PRELOAD2_FILE, preload2_mem);
    end

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            activated <= 1'b0;
            command_count_activate <= 0; command_count_read <= 0; command_count_write <= 0;
            command_count_refresh <= 0; command_count_precharge <= 0; command_count_mrs <= 0;
            saw_read_before_activate_error <= 1'b0;
            saw_write_before_activate_error <= 1'b0;
            for (i = 0; i < CAS_LATENCY; i = i + 1) read_valid_pipe[i] <= 1'b0;

            if (PRELOAD1_FILE != "" && PRELOAD1_WORDS > 0) begin
                for (int w = 0; w < PRELOAD1_WORDS; w++) begin
                    automatic logic [24:0] word_addr = PRELOAD1_BYTE_BASE[26:2] + 25'(w);
                    mem_store[pack_key(word_addr[24:23], word_addr[22:10], word_addr[9:0])] = preload1_mem[w];
                end
                $display("sdram_model: preloaded %0d words from %s at byte base 0x%08h", PRELOAD1_WORDS, PRELOAD1_FILE, PRELOAD1_BYTE_BASE);
            end
            if (PRELOAD2_FILE != "" && PRELOAD2_WORDS > 0) begin
                for (int w = 0; w < PRELOAD2_WORDS; w++) begin
                    automatic logic [24:0] word_addr = PRELOAD2_BYTE_BASE[26:2] + 25'(w);
                    mem_store[pack_key(word_addr[24:23], word_addr[22:10], word_addr[9:0])] = preload2_mem[w];
                end
                $display("sdram_model: preloaded %0d words from %s at byte base 0x%08h", PRELOAD2_WORDS, PRELOAD2_FILE, PRELOAD2_BYTE_BASE);
            end
        end else begin
            // shift the read-data pipeline every cycle (indices 0..CAS_LATENCY-1)
            for (i = 0; i < CAS_LATENCY - 1; i = i + 1) begin
                read_pipe[i]       <= read_pipe[i+1];
                read_valid_pipe[i] <= read_valid_pipe[i+1];
            end
            read_valid_pipe[CAS_LATENCY-1] <= 1'b0;

            case (cmd)
                CMD_ACTIVATE: begin
                    activated <= 1'b1;
                    act_bank  <= dram_ba;
                    act_row   <= dram_addr;
                    command_count_activate <= command_count_activate + 1;
                end
                CMD_READ: begin
                    command_count_read <= command_count_read + 1;
                    if (!activated) saw_read_before_activate_error <= 1'b1;
                    read_pipe[CAS_LATENCY-1]       <= mem_store.exists(pack_key(act_bank, act_row, dram_addr[9:0]))
                                                         ? mem_store[pack_key(act_bank, act_row, dram_addr[9:0])]
                                                         : 32'hXXXXXXXX;
                    read_valid_pipe[CAS_LATENCY-1] <= 1'b1;
                    if (dram_addr[10]) activated <= 1'b0; // auto-precharge (A10)
                end
                CMD_WRITE: begin
                    command_count_write <= command_count_write + 1;
                    if (!activated) saw_write_before_activate_error <= 1'b1;
                    else begin
                        write_key    = pack_key(act_bank, act_row, dram_addr[9:0]);
                        write_prev   = mem_store.exists(write_key) ? mem_store[write_key] : 32'd0;
                        write_merged[7:0]   = dram_dqm[0] ? write_prev[7:0]   : dram_dq[7:0];
                        write_merged[15:8]  = dram_dqm[1] ? write_prev[15:8]  : dram_dq[15:8];
                        write_merged[23:16] = dram_dqm[2] ? write_prev[23:16] : dram_dq[23:16];
                        write_merged[31:24] = dram_dqm[3] ? write_prev[31:24] : dram_dq[31:24];
                        mem_store[write_key] = write_merged;
                    end
                    if (dram_addr[10]) activated <= 1'b0; // auto-precharge (A10)
                end
                CMD_PRECHARGE: begin
                    activated <= 1'b0;
                    command_count_precharge <= command_count_precharge + 1;
                end
                CMD_REFRESH: command_count_refresh <= command_count_refresh + 1;
                CMD_MRS:     command_count_mrs     <= command_count_mrs + 1;
                default: ;
            endcase
        end
    end
endmodule
