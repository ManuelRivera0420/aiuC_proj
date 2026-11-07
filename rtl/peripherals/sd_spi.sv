// SD card SPI-mode controller implementing the mission's locked SDHC boot
// contract: CMD0, CMD8 (check pattern + voltage, valid CRC7), CMD55+ACMD41
// (HCS) until ready, CMD58 (inspect CCS for high-capacity confirmation),
// then CMD17 single-block (512B) reads using LBA (not byte) addressing.
// SPI mode 0 (CPOL=0,CPHA=0): MOSI/MISO shift MSB-first, data launched on
// the falling edge of sd_clk and sampled on the rising edge.
//
// Clock: starts at a conservative ~390 KHz (50MHz/128) during the whole
// init handshake, as SD cards require; after CMD58 succeeds, switches to a
// faster divider for CMD17 reads. Both dividers are module parameters so
// the human team can retune the post-init rate against real measured
// signal integrity on the physical board (Section 3A of the mission brief
// explicitly allows "operate substantially slower than the card's quoted
// speeds" and warns against promising throughput without measurement).
module sd_spi #(
    parameter int INIT_CLK_DIV = 128,  // 50MHz/128 ~= 390 KHz
    parameter int FAST_CLK_DIV = 4     // 50MHz/4   = 12.5 MHz (conservative; retune on hardware)
) (
    input  logic        clk,
    input  logic        rst_n,

    output logic        sd_clk,
    output logic        sd_mosi,   // -> SD_CMD (DI)
    input  logic        sd_miso,   // <- SD_DAT[0] (DO)
    output logic        sd_cs_n,   // -> SD_DAT[3]

    // picorv32-style local bus port (local offset within the 256B window)
    input  logic [7:0]  mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_wstrb,
    input  logic        mem_valid,
    output logic [31:0] mem_rdata,
    output logic        mem_ready
);
    // ---- register offsets (see docs/sdhc_32gb_boot_protocol.md) ----
    localparam logic [7:0] REG_CTRL     = 8'h00; // W: bit0=start_init bit1=start_read
    localparam logic [7:0] REG_STATUS   = 8'h04; // R: bit0=busy bit1=ready bit2=error bits[7:4]=error_code
    localparam logic [7:0] REG_LBA      = 8'h08; // W: 32-bit LBA for the next CMD17
    localparam logic [7:0] REG_BUF_DATA = 8'h0C; // R: next word of the 512B block buffer, auto-increments

    // ---- error codes ----
    localparam logic [3:0] ERR_NONE            = 4'h0;
    localparam logic [3:0] ERR_CMD0_TIMEOUT    = 4'h1;
    localparam logic [3:0] ERR_CMD8_BAD_ECHO   = 4'h2;
    localparam logic [3:0] ERR_ACMD41_TIMEOUT  = 4'h3;
    localparam logic [3:0] ERR_NOT_SDHC        = 4'h4;
    localparam logic [3:0] ERR_CMD17_REJECTED  = 4'h5;
    localparam logic [3:0] ERR_DATA_TOKEN_TMO  = 4'h6;
    localparam logic [3:0] ERR_NO_CARD         = 4'h7;

    // declared early: used inside the command FSM below, assigned from the
    // MMIO register block further down (Zenith requires textual
    // declare-before-use even though plain SV allows forward references).
    logic ctrl_start_read_pulse_w;
    logic ctrl_start_read_pulse;
    assign ctrl_start_read_pulse = ctrl_start_read_pulse_w;

    // =====================================================================
    // Byte-level SPI shifter primitive
    // =====================================================================
    logic [15:0] clk_div_cnt;
    logic [15:0] clk_div_target;
    logic        spi_clk_en;   // pulses at 2x the target SPI bit rate (toggle edges)
    logic        sd_clk_r;
    assign sd_clk = sd_clk_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div_cnt <= 16'd0;
            spi_clk_en  <= 1'b0;
        end else begin
            spi_clk_en <= 1'b0;
            if (clk_div_cnt >= clk_div_target - 1) begin
                clk_div_cnt <= 16'd0;
                spi_clk_en  <= 1'b1;
            end else begin
                clk_div_cnt <= clk_div_cnt + 16'd1;
            end
        end
    end

    logic       xfer_start;
    logic [7:0] xfer_tx_byte;
    logic [7:0] xfer_rx_byte;
    logic       xfer_busy, xfer_done;
    logic [3:0] bit_idx;
    logic [7:0] shift_tx, shift_rx;
    logic       clk_phase; // 0 = about to drive falling edge, 1 = about to drive rising edge

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xfer_busy <= 1'b0;
            xfer_done <= 1'b0;
            sd_clk_r  <= 1'b0;
            clk_phase <= 1'b0;
            bit_idx   <= 4'd0;
        end else begin
            xfer_done <= 1'b0;
            if (!xfer_busy) begin
                if (xfer_start) begin
                    xfer_busy <= 1'b1;
                    shift_tx  <= xfer_tx_byte;
                    shift_rx  <= 8'd0;
                    bit_idx   <= 4'd0;
                    clk_phase <= 1'b0;
                    sd_clk_r  <= 1'b0;
                end
            end else if (spi_clk_en) begin
                if (clk_phase == 1'b0) begin
                    // Falling-edge phase: clock goes low, and THIS is where the
                    // next MOSI bit must become visible (SPI mode 0: data
                    // changes on the falling edge, sampled on the rising edge).
                    // bit_idx==0 means shift_tx already holds bit7 pre-loaded
                    // by xfer_start -- nothing to shift yet for the very first
                    // falling edge of a byte. An earlier version shifted
                    // shift_tx in the RISING-edge branch below instead, which
                    // made MOSI change exactly at the rising edge -- the same
                    // instant the slave samples it -- corrupting every byte
                    // (caught by sd_spi_tb.sv reading back a sequence that
                    // matched neither the sent command nor any simple
                    // rotation of it).
                    sd_clk_r  <= 1'b0;
                    clk_phase <= 1'b1;
                    if (bit_idx == 4'd8) begin
                        // Deferred completion step (see rising-edge branch
                        // below): clear busy on THIS falling edge, one full
                        // half-cycle after the slave already sampled the
                        // real final bit at the previous rising edge. An
                        // earlier version cleared xfer_busy on that SAME
                        // rising edge the slave samples, which raced the
                        // combinational `sd_mosi = xfer_busy ? ... : 1'b1`
                        // mux against the slave's sampling at the identical
                        // simulation instant -- the slave consistently saw
                        // the post-clear "idle" value (1) instead of the
                        // real last bit, corrupting every byte's LSB
                        // (caught by sd_spi_tb.sv/manual waveform trace:
                        // every received byte had bit0 forced to 1).
                        xfer_busy <= 1'b0;
                    end else if (bit_idx != 4'd0) begin
                        shift_tx <= {shift_tx[6:0], 1'b0};
                    end
                end else begin
                    // rising-edge phase: sample MISO, clock goes high
                    sd_clk_r  <= 1'b1;
                    shift_rx  <= {shift_rx[6:0], sd_miso};
                    clk_phase <= 1'b0;
                    if (bit_idx == 4'd7) begin
                        xfer_done    <= 1'b1;
                        xfer_rx_byte <= {shift_rx[6:0], sd_miso};
                        bit_idx      <= 4'd8; // busy clears next falling edge, not this rising edge
                    end else if (bit_idx != 4'd8) begin
                        bit_idx  <= bit_idx + 4'd1;
                    end
                end
            end
        end
    end

    assign sd_mosi = xfer_busy ? shift_tx[7] : 1'b1; // idle high between bytes

    // =====================================================================
    // CRC7 for command frames (x^7 + x^3 + 1), MSB-first, matches the SD spec
    // =====================================================================
    function automatic [6:0] crc7_update(logic [6:0] crc_in, logic bit_in);
        logic fb;
        fb = crc_in[6] ^ bit_in;
        crc7_update = {crc_in[5:0], 1'b0} ^ (fb ? 7'b0001001 : 7'b0000000);
    endfunction

    // =====================================================================
    // Command-level sequencer
    // =====================================================================
    typedef enum logic [5:0] {
        ST_RESET_IDLE_CLKS, ST_IDLE,
        ST_CMD_SEND_BYTE, ST_CMD_WAIT_BYTE,
        ST_CMD0_WAIT_R1, ST_CMD8_WAIT_R7,
        ST_CMD55_WAIT_R1, ST_ACMD41_WAIT_R1,
        ST_CMD58_WAIT_R3,
        ST_READY,
        ST_CMD17_WAIT_R1, ST_WAIT_DATA_TOKEN, ST_READ_DATA, ST_READ_CRC,
        ST_DONE_READ, ST_ERROR
    } state_t;
    state_t state, after_cmd_state;

    logic [2:0]  cmd_byte_idx;   // 0..5 within the 6-byte command frame
    logic [47:0] cmd_frame;      // {start+cmd(8), arg(32), crc7+stop(8)}
    logic [7:0]  resp_bytes [0:4]; // up to R3/R7's 5 bytes
    logic [3:0]  resp_byte_idx;
    logic [7:0]  ncr_timeout;     // bytes waited for a response before giving up
    logic [15:0] block_byte_idx;  // 0..511 within the data block
    logic [31:0] block_buf [0:127]; // 512 bytes = 128 words
    logic [7:0]  retry_ctr;       // ACMD41 poll retries / data-token wait retries

    logic        busy, ready, error_flag;
    logic [3:0]  error_code;
    logic [31:0] lba_reg;
    logic [6:0]  buf_rd_ptr;

    function automatic [47:0] build_cmd(logic [5:0] idx, logic [31:0] arg);
        logic [6:0] crc;
        logic [39:0] body;
        int i;
        body = {2'b01, idx, arg}; // command byte = 0b01_<6-bit idx> = (0x40 | idx), then 32-bit arg
        crc = 7'b0000000;
        for (i = 39; i >= 0; i = i - 1) crc = crc7_update(crc, body[i]);
        build_cmd = {body, crc, 1'b1};
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_RESET_IDLE_CLKS;
            sd_cs_n        <= 1'b1;
            clk_div_target <= INIT_CLK_DIV;
            xfer_start     <= 1'b0;
            cmd_byte_idx   <= 3'd0;
            retry_ctr       <= 8'd0;
            busy           <= 1'b0;
            ready          <= 1'b0;
            error_flag     <= 1'b0;
            error_code     <= ERR_NONE;
        end else begin
            xfer_start <= 1'b0;

            case (state)
                // 74+ clock cycles with CS high, MOSI high, before the first command
                ST_RESET_IDLE_CLKS: begin
                    busy <= 1'b1;
                    sd_cs_n <= 1'b1;
                    if (!xfer_busy && !xfer_start) begin
                        if (retry_ctr >= 10) begin // 10 bytes * 8 = 80 idle clocks
                            retry_ctr <= 8'd0;
                            sd_cs_n <= 1'b0;
                            cmd_frame <= build_cmd(6'd0, 32'd0); // CMD0: GO_IDLE_STATE
                            cmd_byte_idx <= 3'd0;
                            after_cmd_state <= ST_CMD0_WAIT_R1;
                            state <= ST_CMD_SEND_BYTE;
                        end else begin
                            xfer_tx_byte <= 8'hFF;
                            xfer_start   <= 1'b1;
                            retry_ctr    <= retry_ctr + 8'd1;
                        end
                    end
                end

                ST_CMD_SEND_BYTE: begin
                    if (!xfer_busy) begin
                        xfer_tx_byte <= cmd_frame[47:40];
                        xfer_start   <= 1'b1;
                        state        <= ST_CMD_WAIT_BYTE;
                    end
                end
                ST_CMD_WAIT_BYTE: begin
                    if (xfer_done) begin
                        cmd_frame <= {cmd_frame[39:0], 8'h00};
                        if (cmd_byte_idx == 3'd5) begin
                            cmd_byte_idx  <= 3'd0;
                            resp_byte_idx <= 4'd0;
                            ncr_timeout   <= 8'd0;
                            state         <= after_cmd_state;
                        end else begin
                            cmd_byte_idx <= cmd_byte_idx + 3'd1;
                            state        <= ST_CMD_SEND_BYTE;
                        end
                    end
                end

                // ---- R1 response: poll bytes until MSB=0 (or timeout) ----
                ST_CMD0_WAIT_R1: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        if (!xfer_rx_byte[7]) begin
                            // CMD0 OK (idle state entered) -> send CMD8
                            sd_cs_n      <= 1'b0;
                            cmd_frame    <= build_cmd(6'd8, 32'h0000_01AA); // voltage 2.7-3.6V, check pattern 0xAA
                            cmd_byte_idx <= 3'd0;
                            after_cmd_state <= ST_CMD8_WAIT_R7;
                            state        <= ST_CMD_SEND_BYTE;
                        end else if (ncr_timeout >= 8'hFE) begin
                            error_flag <= 1'b1; error_code <= ERR_CMD0_TIMEOUT; state <= ST_ERROR;
                        end else begin
                            ncr_timeout <= ncr_timeout + 8'd1;
                        end
                    end
                end

                ST_CMD8_WAIT_R7: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        if (!xfer_rx_byte[7] || resp_byte_idx != 4'd0) begin
                            resp_bytes[resp_byte_idx] <= xfer_rx_byte;
                            if (resp_byte_idx == 4'd4) begin
                                // Check xfer_rx_byte directly, not resp_bytes[4]: the
                                // array write above is non-blocking and wouldn't be
                                // visible until next cycle (same read-after-write
                                // hazard class as cpu_core.sv's M1 rf_we bug).
                                if (xfer_rx_byte == 8'hAA) begin
                                    sd_cs_n      <= 1'b0;
                                    cmd_frame    <= build_cmd(6'd55, 32'd0); // APP_CMD
                                    cmd_byte_idx <= 3'd0;
                                    after_cmd_state <= ST_CMD55_WAIT_R1;
                                    state        <= ST_CMD_SEND_BYTE;
                                end else begin
                                    error_flag <= 1'b1; error_code <= ERR_CMD8_BAD_ECHO; state <= ST_ERROR;
                                end
                            end else begin
                                resp_byte_idx <= resp_byte_idx + 4'd1;
                            end
                        end else if (ncr_timeout >= 8'hFE) begin
                            error_flag <= 1'b1; error_code <= ERR_CMD0_TIMEOUT; state <= ST_ERROR;
                        end else begin
                            ncr_timeout <= ncr_timeout + 8'd1;
                        end
                    end
                end

                ST_CMD55_WAIT_R1: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        if (!xfer_rx_byte[7]) begin
                            sd_cs_n      <= 1'b0;
                            cmd_frame    <= build_cmd(6'd41, 32'h4000_0000); // ACMD41 with HCS bit set
                            cmd_byte_idx <= 3'd0;
                            after_cmd_state <= ST_ACMD41_WAIT_R1;
                            state        <= ST_CMD_SEND_BYTE;
                        end else if (ncr_timeout >= 8'hFE) begin
                            error_flag <= 1'b1; error_code <= ERR_ACMD41_TIMEOUT; state <= ST_ERROR;
                        end else ncr_timeout <= ncr_timeout + 8'd1;
                    end
                end

                ST_ACMD41_WAIT_R1: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        if (xfer_rx_byte == 8'h00) begin
                            // card initialized -> CMD58, inspect OCR/CCS
                            sd_cs_n      <= 1'b0;
                            cmd_frame    <= build_cmd(6'd58, 32'd0);
                            cmd_byte_idx <= 3'd0;
                            after_cmd_state <= ST_CMD58_WAIT_R3;
                            state        <= ST_CMD_SEND_BYTE;
                        end else if (xfer_rx_byte[7:1] == 7'd0 && xfer_rx_byte[0]) begin
                            // still idle (bit0=1): retry CMD55+ACMD41
                            if (retry_ctr >= 8'hFE) begin
                                error_flag <= 1'b1; error_code <= ERR_ACMD41_TIMEOUT; state <= ST_ERROR;
                            end else begin
                                retry_ctr    <= retry_ctr + 8'd1;
                                sd_cs_n      <= 1'b0;
                                cmd_frame    <= build_cmd(6'd55, 32'd0);
                                cmd_byte_idx <= 3'd0;
                                after_cmd_state <= ST_CMD55_WAIT_R1;
                                state        <= ST_CMD_SEND_BYTE;
                            end
                        end else if (ncr_timeout >= 8'hFE) begin
                            error_flag <= 1'b1; error_code <= ERR_ACMD41_TIMEOUT; state <= ST_ERROR;
                        end else ncr_timeout <= ncr_timeout + 8'd1;
                    end
                end

                ST_CMD58_WAIT_R3: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        if (!xfer_rx_byte[7] || resp_byte_idx != 4'd0) begin
                            resp_bytes[resp_byte_idx] <= xfer_rx_byte;
                            if (resp_byte_idx == 4'd4) begin
                                // resp_bytes[1] is OCR byte containing CCS at bit6
                                if (resp_bytes[1][6]) begin
                                    ready <= 1'b1;
                                    busy  <= 1'b0;
                                    clk_div_target <= FAST_CLK_DIV;
                                    sd_cs_n <= 1'b1;
                                    state <= ST_READY;
                                end else begin
                                    error_flag <= 1'b1; error_code <= ERR_NOT_SDHC; state <= ST_ERROR;
                                end
                            end else resp_byte_idx <= resp_byte_idx + 4'd1;
                        end else if (ncr_timeout >= 8'hFE) begin
                            error_flag <= 1'b1; error_code <= ERR_NOT_SDHC; state <= ST_ERROR;
                        end else ncr_timeout <= ncr_timeout + 8'd1;
                    end
                end

                ST_READY: begin
                    busy <= 1'b0;
                    if (ctrl_start_read_pulse) begin
                        busy <= 1'b1;
                        sd_cs_n <= 1'b0;
                        cmd_frame <= build_cmd(6'd17, lba_reg); // CMD17: READ_SINGLE_BLOCK, LBA addressing (SDHC)
                        cmd_byte_idx <= 3'd0;
                        after_cmd_state <= ST_CMD17_WAIT_R1;
                        state <= ST_CMD_SEND_BYTE;
                    end
                end

                ST_CMD17_WAIT_R1: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        if (xfer_rx_byte == 8'h00) begin
                            retry_ctr <= 8'd0;
                            state <= ST_WAIT_DATA_TOKEN;
                        end else if (!xfer_rx_byte[7]) begin
                            error_flag <= 1'b1; error_code <= ERR_CMD17_REJECTED; state <= ST_ERROR;
                        end else if (ncr_timeout >= 8'hFE) begin
                            error_flag <= 1'b1; error_code <= ERR_CMD17_REJECTED; state <= ST_ERROR;
                        end else ncr_timeout <= ncr_timeout + 8'd1;
                    end
                end

                ST_WAIT_DATA_TOKEN: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        if (xfer_rx_byte == 8'hFE) begin
                            block_byte_idx <= 16'd0;
                            state <= ST_READ_DATA;
                        end else if (retry_ctr >= 8'hFF) begin
                            error_flag <= 1'b1; error_code <= ERR_DATA_TOKEN_TMO; state <= ST_ERROR;
                        end else retry_ctr <= retry_ctr + 8'd1;
                    end
                end

                ST_READ_DATA: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        block_buf[block_byte_idx[8:2]][8*(3-block_byte_idx[1:0]) +: 8] <= xfer_rx_byte;
                        if (block_byte_idx == 16'd511) begin
                            block_byte_idx <= 16'd0;
                            state <= ST_READ_CRC;
                        end else begin
                            block_byte_idx <= block_byte_idx + 16'd1;
                        end
                    end
                end

                ST_READ_CRC: begin
                    if (!xfer_busy && !xfer_start) begin
                        xfer_tx_byte <= 8'hFF;
                        xfer_start   <= 1'b1;
                    end
                    if (xfer_done) begin
                        if (block_byte_idx == 16'd1) begin
                            sd_cs_n <= 1'b1;
                            busy <= 1'b0;
                            state <= ST_READY;
                        end else begin
                            block_byte_idx <= block_byte_idx + 16'd1;
                        end
                    end
                end

                ST_ERROR: begin
                    busy <= 1'b0;
                    sd_cs_n <= 1'b1;
                    // sticky error state; cleared only by a full reset in this M3 cut
                end

                default: state <= ST_ERROR;
            endcase
        end
    end

    // ---- MMIO register interface ----
    assign mem_ready = mem_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lba_reg <= 32'd0;
            ctrl_start_read_pulse_w <= 1'b0;
            buf_rd_ptr <= 7'd0;
        end else begin
            ctrl_start_read_pulse_w <= 1'b0;
            if (mem_valid && (|mem_wstrb)) begin
                case (mem_addr)
                    REG_CTRL: begin
                        if (mem_wdata[1]) begin
                            ctrl_start_read_pulse_w <= 1'b1;
                            buf_rd_ptr <= 7'd0; // reset the read pointer for the new block
                        end
                    end
                    REG_LBA: lba_reg <= mem_wdata;
                    default: ;
                endcase
            end else if (mem_valid && mem_wstrb == 4'd0 && mem_addr == REG_BUF_DATA) begin
                buf_rd_ptr <= buf_rd_ptr + 7'd1;
            end
        end
    end

    always_comb begin
        case (mem_addr)
            REG_STATUS:   mem_rdata = {24'd0, error_code, 1'b0, error_flag, ready, busy};
            REG_BUF_DATA: mem_rdata = block_buf[buf_rd_ptr];
            default:      mem_rdata = 32'hDEADBEEF;
        endcase
    end
endmodule
