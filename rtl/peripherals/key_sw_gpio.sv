// Memory-mapped KEY[3:0]/SW[17:0] controller. See docs/memory_map.md for the
// register layout (offsets 0x00 KEY_STATUS, 0x04 SW_LEVEL, 0x08 SW_EDGE
// read-clears, 0x0C LED_STATUS). KEY[0] is the board's hardware reset and
// never appears here as a gameplay input (bit 0 of KEY_STATUS reads 0).
//
// KEY[3:0] arrives already hardware-debounced (Schmitt trigger, DE2-115
// manual Fig 4-6/4-7) but still asynchronous to our clock, so it still gets
// a 2-FF synchronizer here, same as the undebounced SW[17:0].
module key_sw_gpio (
    input  logic        clk,
    input  logic        rst_n,

    // board pins (active-low KEY per the manual; SW already active-high)
    input  logic [3:0]  key_n,
    input  logic [17:0] sw,
    output logic [17:0] ledr,

    // picorv32-style local bus port (addr is the LOCAL offset within this
    // peripheral's 256B window -- soc_bus.sv strips the base address)
    input  logic [7:0]  mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_wstrb,
    input  logic        mem_valid,
    output logic [31:0] mem_rdata,
    output logic        mem_ready
);
    // ---- synchronizers (2-FF) ----
    logic [3:0]  key_n_s0, key_n_s1;
    logic [17:0] sw_s0, sw_s1, sw_s1_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_n_s0 <= 4'hF; // idle = not pressed = high (active-low)
            key_n_s1 <= 4'hF;
            sw_s0      <= 18'd0;
            sw_s1      <= 18'd0;
            sw_s1_prev <= 18'd0;
        end else begin
            key_n_s0 <= key_n;
            key_n_s1 <= key_n_s0;
            sw_s0      <= sw;
            sw_s1      <= sw_s0;
            sw_s1_prev <= sw_s1;
        end
    end

    logic [3:0] key_level; // active-HIGH, synchronized
    assign key_level = ~key_n_s1;

    // ---- sticky rising-edge latch for SW, cleared on SW_EDGE read ----
    logic [17:0] sw_edge_pending;
    logic [17:0] sw_rising_now;
    assign sw_rising_now = sw_s1 & ~sw_s1_prev;

    logic sw_edge_read;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_edge_pending <= 18'd0;
        end else if (sw_edge_read) begin
            sw_edge_pending <= sw_rising_now; // clear-on-read, but don't drop an edge arriving this same cycle
        end else begin
            sw_edge_pending <= sw_edge_pending | sw_rising_now;
        end
    end

    // ---- LED_STATUS (software-writable) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ledr <= 18'd0;
        end else if (mem_valid && (|mem_wstrb) && mem_addr[7:0] == 8'h0C) begin
            if (mem_wstrb[0]) ledr[7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) ledr[15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) ledr[17:16] <= mem_wdata[17:16];
        end
    end

    // ---- bus read port (single-cycle: ready combinationally follows valid) ----
    assign mem_ready = mem_valid;
    assign sw_edge_read = mem_valid && (mem_wstrb == 4'd0) && (mem_addr[7:0] == 8'h08);

    always_comb begin
        case (mem_addr[7:0])
            8'h00:   mem_rdata = {28'd0, key_level};
            8'h04:   mem_rdata = {14'd0, sw_s1};
            8'h08:   mem_rdata = {14'd0, sw_edge_pending};
            8'h0C:   mem_rdata = {14'd0, ledr};
            default: mem_rdata = 32'hDEADBEEF;
        endcase
    end
endmodule
