// Синхронная FIFO без задержки чтения (голова видна сразу, распределённая память):
// очереди дескрипторов 40G-моста. DEPTH — степень двойки.
module eth40_fifo #(
    parameter int W     = 32,
    parameter int DEPTH = 4
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         wvalid,
    output logic         wready,
    input  logic [W-1:0] wdata,
    output logic         rvalid,
    input  logic         rready,
    output logic [W-1:0] rdata
);
    localparam int AW = DEPTH > 1 ? $clog2(DEPTH) : 1;

    logic [W-1:0] mem [DEPTH];
    logic [AW:0]  wp, rp;

    assign wready = (wp - rp) != (AW+1)'(DEPTH);
    assign rvalid = wp != rp;
    assign rdata  = mem[rp[AW-1:0]];

    always_ff @(posedge clk) begin
        if (wvalid && wready) begin
            mem[wp[AW-1:0]] <= wdata;
            wp <= wp + 1'b1;
        end
        if (rvalid && rready) rp <= rp + 1'b1;
        if (rst) begin
            wp <= '0;
            rp <= '0;
        end
    end
endmodule
