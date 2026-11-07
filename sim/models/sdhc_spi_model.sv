// Deterministic behavioral SDHC SPI card model for testing sd_spi.sv.
// Acts as an SPI slave (mode 0), clocked directly off sd_clk (NOT the fast
// system clock) so its sampling point exactly matches the controller's own
// edge timing -- an earlier version detected sd_clk edges by registering it
// in the fast `clk` domain and comparing against the previous sample, which
// added a one system-clock-cycle detection delay; since the controller
// updates its output bit AT the rising edge (same simulation instant, zero
// extra delay), that delay caused the model to sample the NEXT bit instead
// of the current one, corrupting every received byte. Clocking this model
// directly off sd_clk's own edges removes that mismatch entirely.
//
// Protocol behavior modeled:
//   CMD0  -> R1 = 0x01 (idle)
//   CMD8  -> R7 = 0x01, 0x00,0x00, voltage/pattern echo (0x01,0xAA)
//   CMD55 -> R1 = 0x01 (still idle, app-cmd prefix accepted)
//   ACMD41(HCS) -> R1 = 0x01 for the first ACMD41_IDLE_RESPONSES times
//                  (deliberately exercises the controller's retry loop),
//                  then R1 = 0x00 (ready)
//   CMD58 -> R3 = 0x00, then OCR bytes with CCS=1 (bit6 of byte1): SDHC
//   CMD17(lba) -> R1 = 0x00, then data token 0xFE, then 512 bytes read
//                 from `image_mem` at byte offset lba*512, then 2 dummy
//                 CRC bytes (not checked by sd_spi.sv on read data)
//
// `image_mem` is loaded via $readmemh from a file prepared by
// scripts/prepare_sd_image.py -- the SAME image format intended for the
// real ADATA card, so this model is testing against the real boot-image
// layout, not an ad hoc fixture.
module sdhc_spi_model #(
    parameter int ACMD41_IDLE_RESPONSES = 2,
    parameter      IMAGE_FILE = "sim/models/sd_fixture.hex",
    parameter int  IMAGE_BYTES = 65536
) (
    input  logic clk,      // unused except as the async-reset-adjacent domain; kept for port compatibility
    input  logic rst_n,

    input  logic sd_clk,
    input  logic sd_mosi,
    output logic sd_miso,
    input  logic sd_cs_n,

    output logic [31:0] cmd_seen_count,
    output logic [31:0] last_cmd_index,
    output logic [31:0] last_cmd_arg
);
    logic [7:0] image_mem [0:IMAGE_BYTES-1];
    initial $readmemh(IMAGE_FILE, image_mem);

    logic [7:0] rx_shift;
    logic [2:0] rx_bit_cnt;
    logic [7:0] byte_in;

    logic [7:0] tx_shift;
    assign sd_miso = sd_cs_n ? 1'b1 : tx_shift[7];

    typedef enum logic [3:0] {
        M_IDLE, M_CMD_BODY, M_RESPOND_R1, M_RESPOND_R7_1, M_RESPOND_R7_2,
        M_RESPOND_R7_3, M_RESPOND_R7_4, M_RESPOND_R3_1, M_RESPOND_R3_2,
        M_RESPOND_R3_3, M_RESPOND_R3_4, M_SEND_TOKEN, M_SEND_DATA, M_SEND_CRC
    } mstate_t;
    mstate_t mstate;

    logic [47:0] cmd_shift;
    logic [2:0]  cmd_byte_cnt;
    logic [5:0]  cmd_index;
    logic [7:0]  acmd41_count;
    logic        next_is_app_cmd;
    logic [15:0] data_byte_idx;
    logic [31:0] image_byte_off;
    logic [47:0] frame;
    logic [7:0]  next_tx_byte;

    logic [31:0] cmd_count_q;
    logic [5:0]  last_cmd_q;
    logic [31:0] last_arg_q;
    assign cmd_seen_count = cmd_count_q;
    assign last_cmd_index = {26'd0, last_cmd_q};
    assign last_cmd_arg   = last_arg_q;

    always_ff @(posedge sd_clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_bit_cnt      <= 3'd0;
            tx_shift        <= 8'hFF;
            mstate          <= M_IDLE;
            cmd_byte_cnt    <= 3'd0;
            acmd41_count    <= 8'd0;
            next_is_app_cmd <= 1'b0;
            cmd_count_q     <= 32'd0;
            last_cmd_q      <= 6'd0;
            last_arg_q      <= 32'd0;
        end else if (!sd_cs_n) begin
            byte_in = {rx_shift[6:0], sd_mosi}; // this bit's sample, combined with the 7 already shifted in
            rx_shift <= byte_in;

            if (rx_bit_cnt != 3'd7) begin
                rx_bit_cnt <= rx_bit_cnt + 3'd1;
                tx_shift   <= {tx_shift[6:0], 1'b0}; // present the next bit of the current response byte
            end else begin
                rx_bit_cnt <= 3'd0;
                // byte_in now holds a complete received byte; decide the next
                // response byte (next_tx_byte) and load it for the upcoming
                // bit period (visible starting the very next rising edge).
                next_tx_byte = 8'hFF;

                case (mstate)
                    M_IDLE: begin
                        if (byte_in[7:6] == 2'b01) begin
                            cmd_shift    <= {40'd0, byte_in};
                            cmd_byte_cnt <= 3'd1;
                            mstate       <= M_CMD_BODY;
                        end
                        // else: 0xFF polling byte while idle, ignore (keep sending 0xFF)
                    end
                    M_CMD_BODY: begin
                        cmd_shift <= {cmd_shift[39:0], byte_in};
                        if (cmd_byte_cnt == 3'd5) begin
                            frame = {cmd_shift[39:0], byte_in};
                            cmd_index   <= frame[45:40];
                            cmd_count_q <= cmd_count_q + 32'd1;
                            last_cmd_q  <= frame[45:40];
                            last_arg_q  <= frame[39:8];

                            if (next_is_app_cmd && frame[45:40] == 6'd41) begin
                                next_is_app_cmd <= 1'b0;
                                if (acmd41_count < 8'(ACMD41_IDLE_RESPONSES)) begin
                                    acmd41_count <= acmd41_count + 8'd1;
                                    next_tx_byte = 8'h01;
                                end else begin
                                    next_tx_byte = 8'h00;
                                end
                                mstate <= M_RESPOND_R1;
                            end else begin
                                next_is_app_cmd <= 1'b0;
                                case (frame[45:40])
                                    6'd0: begin next_tx_byte = 8'h01; mstate <= M_RESPOND_R1; end
                                    6'd8: begin next_tx_byte = 8'h01; mstate <= M_RESPOND_R7_1; end
                                    6'd55: begin next_is_app_cmd <= 1'b1; next_tx_byte = 8'h01; mstate <= M_RESPOND_R1; end
                                    6'd58: begin next_tx_byte = 8'h00; mstate <= M_RESPOND_R3_1; end
                                    6'd17: begin
                                        image_byte_off <= frame[39:8] * 32'd512; // LBA * 512 (SDHC block addressing)
                                        next_tx_byte = 8'h00;
                                        mstate <= M_RESPOND_R1;
                                    end
                                    default: begin next_tx_byte = 8'h05; mstate <= M_RESPOND_R1; end // illegal command
                                endcase
                            end
                            cmd_byte_cnt <= 3'd0;
                        end else begin
                            cmd_byte_cnt <= cmd_byte_cnt + 3'd1;
                            next_tx_byte = 8'hFF;
                        end
                    end

                    M_RESPOND_R1: begin
                        if (cmd_index == 6'd17 && tx_shift == 8'h00) begin
                            // R1=0 for CMD17 was just fully presented; next byte is the data start token.
                            next_tx_byte = 8'hFE;
                            data_byte_idx <= 16'd0;
                            mstate <= M_SEND_TOKEN;
                        end else begin
                            next_tx_byte = 8'hFF;
                            mstate <= M_IDLE;
                        end
                    end
                    M_RESPOND_R7_1: begin next_tx_byte = 8'h00; mstate <= M_RESPOND_R7_2; end
                    M_RESPOND_R7_2: begin next_tx_byte = 8'h00; mstate <= M_RESPOND_R7_3; end
                    M_RESPOND_R7_3: begin next_tx_byte = 8'h01; mstate <= M_RESPOND_R7_4; end
                    M_RESPOND_R7_4: begin next_tx_byte = 8'hAA; mstate <= M_IDLE; end

                    M_RESPOND_R3_1: begin next_tx_byte = 8'h40; mstate <= M_RESPOND_R3_2; end // CCS=1 (bit6)
                    M_RESPOND_R3_2: begin next_tx_byte = 8'hFF; mstate <= M_RESPOND_R3_3; end
                    M_RESPOND_R3_3: begin next_tx_byte = 8'h80; mstate <= M_RESPOND_R3_4; end
                    M_RESPOND_R3_4: begin next_tx_byte = 8'h00; mstate <= M_IDLE; end

                    M_SEND_TOKEN: begin
                        next_tx_byte = image_mem[image_byte_off];
                        mstate <= M_SEND_DATA;
                    end
                    M_SEND_DATA: begin
                        if (data_byte_idx == 16'd511) begin
                            next_tx_byte = 8'h00; // CRC hi (dummy)
                            mstate <= M_SEND_CRC;
                        end else begin
                            data_byte_idx <= data_byte_idx + 16'd1;
                            next_tx_byte  = image_mem[image_byte_off + 32'(data_byte_idx) + 32'd1];
                        end
                    end
                    M_SEND_CRC: begin
                        next_tx_byte = 8'h00; // CRC lo (dummy)
                        mstate <= M_IDLE;
                    end

                    default: mstate <= M_IDLE;
                endcase

                tx_shift <= next_tx_byte;
            end
        end
    end
endmodule
