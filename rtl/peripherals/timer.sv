// Free-running cycle counter, memory-mapped per docs/memory_map.md
// (0x2000_0100 base). Offset 0x00 = CYCLES (RO, wraps silently at 2^32).
// Millisecond conversion (for DoomGeneric's DG_GetTicksMs) is a software
// concern once the real CPU clock frequency is fixed in M4 -- this
// peripheral only ever exposes the raw count.
module timer (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_wstrb,
    input  logic        mem_valid,
    output logic [31:0] mem_rdata,
    output logic        mem_ready
);
    logic [31:0] cycles;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycles <= 32'd0;
        else        cycles <= cycles + 32'd1;
    end

    assign mem_ready = mem_valid;

    always_comb begin
        case (mem_addr[7:0])
            8'h00:   mem_rdata = cycles;
            default: mem_rdata = 32'hDEADBEEF;
        endcase
    end
endmodule
