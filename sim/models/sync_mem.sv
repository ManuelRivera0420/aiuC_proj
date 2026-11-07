// Behavioral synchronous memory for standalone cpu_core testing (M1 only).
// picorv32-style valid/ready port. NOT the final SoC memory map -- this is a
// single flat word array covering both instructions and data so M1's
// directed tests can run before any bus/SDRAM/ROM split exists.
module sync_mem #(
    parameter int WORDS = 16384,            // 64 KiB
    parameter      INIT_FILE = "sim/models/program.hex"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [3:0]  mem_wstrb,
    input  logic        mem_valid,
    output logic [31:0] mem_rdata,
    output logic        mem_ready
);
    logic [31:0] mem [0:WORDS-1];

    initial begin
        $readmemh(INIT_FILE, mem);
    end

    logic [$clog2(WORDS)-1:0] waddr;
    assign waddr = mem_addr[$clog2(WORDS)+1:2];

    // Written only at whole-word granularity (same static prefix depth as
    // the $readmemh initial block above) -- Zenith's elaborator rejects
    // mixing a whole-array initializer with sub-word bit-sliced writes to
    // the same array from an always_ff (LRM 9.2.2.4, ZEN-6033).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
        end else begin
            mem_ready <= mem_valid;
            if (mem_valid) begin
                if (|mem_wstrb) begin
                    mem[waddr] <= {
                        mem_wstrb[3] ? mem_wdata[31:24] : mem[waddr][31:24],
                        mem_wstrb[2] ? mem_wdata[23:16] : mem[waddr][23:16],
                        mem_wstrb[1] ? mem_wdata[15:8]  : mem[waddr][15:8],
                        mem_wstrb[0] ? mem_wdata[7:0]   : mem[waddr][7:0]
                    };
                end
                mem_rdata <= mem[waddr];
            end
        end
    end
endmodule
