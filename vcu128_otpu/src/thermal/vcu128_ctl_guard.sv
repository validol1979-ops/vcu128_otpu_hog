// AXI4-Lite pass-through in front of otpu_board s_ctl that can write CTRL = 0 itself
// (vcu128_thermal's stop: the run stops at once, as the host's Board.abort; otpu_ctrl
// "Stopping a run (RUN 1 -> 0) stops the slice at once; what it gave the memory still goes").
//
// The request is kept until the slave port is idle: nothing of the interconnect's valid and
// nothing accepted without its response (vcu128_axil_xbar keeps one transaction at a time);
// then the guard's own write (AW and W together, response swallowed) goes, the interconnect
// held off (its ready low) meanwhile. Only the interconnect's handshakes are delayed.

module vcu128_ctl_guard #(
    parameter int AW = 20,
    parameter logic [AW-1:0] CTRL_ADDR = 'h8
)(
    input  logic          clk,
    input  logic          rst,
    input  logic          stop,         // pulse: write CTRL = 0

    // from the interconnect
    input  logic [AW-1:0] s_awaddr,
    input  logic          s_awvalid,
    output logic          s_awready,
    input  logic [31:0]   s_wdata,
    input  logic [3:0]    s_wstrb,
    input  logic          s_wvalid,
    output logic          s_wready,
    output logic [1:0]    s_bresp,
    output logic          s_bvalid,
    input  logic          s_bready,
    input  logic [AW-1:0] s_araddr,
    input  logic          s_arvalid,
    output logic          s_arready,
    output logic [31:0]   s_rdata,
    output logic [1:0]    s_rresp,
    output logic          s_rvalid,
    input  logic          s_rready,

    // to otpu_board s_ctl
    output logic [AW-1:0] m_awaddr,
    output logic          m_awvalid,
    input  logic          m_awready,
    output logic [31:0]   m_wdata,
    output logic [3:0]    m_wstrb,
    output logic          m_wvalid,
    input  logic          m_wready,
    input  logic [1:0]    m_bresp,
    input  logic          m_bvalid,
    output logic          m_bready,
    output logic [AW-1:0] m_araddr,
    output logic          m_arvalid,
    input  logic          m_arready,
    input  logic [31:0]   m_rdata,
    input  logic [1:0]    m_rresp,
    input  logic          m_rvalid,
    output logic          m_rready,

    output logic [15:0]   n_abort       // guard writes done
);

    logic pend;                     // abort requested, not yet issued
    logic own;                      // the guard's write in progress
    logic a_done, w_done;
    logic aw_out, w_out, ar_out;    // interconnect's: accepted, response not yet given

    wire idle = !s_awvalid && !s_wvalid && !s_arvalid && !aw_out && !w_out && !ar_out;
    wire take = pend && !own && idle;
    wire g    = own || take;        // the guard has the port this cycle

    always_comb begin
        m_awaddr  = g ? CTRL_ADDR : s_awaddr;
        m_wdata   = g ? 32'd0 : s_wdata;
        m_wstrb   = g ? 4'hF : s_wstrb;
        m_awvalid = g ? (own && !a_done) : s_awvalid;
        m_wvalid  = g ? (own && !w_done) : s_wvalid;
        m_bready  = g ? (own && a_done && w_done) : s_bready;
        m_araddr  = s_araddr;
        m_arvalid = g ? 1'b0 : s_arvalid;
        m_rready  = g ? 1'b0 : s_rready;
        s_awready = !g && m_awready;
        s_wready  = !g && m_wready;
        s_bvalid  = !g && m_bvalid;
        s_bresp   = m_bresp;
        s_arready = !g && m_arready;
        s_rvalid  = !g && m_rvalid;
        s_rdata   = m_rdata;
        s_rresp   = m_rresp;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pend    <= 1'b0;
            own     <= 1'b0;
            a_done  <= 1'b0;
            w_done  <= 1'b0;
            aw_out  <= 1'b0;
            w_out   <= 1'b0;
            ar_out  <= 1'b0;
            n_abort <= '0;
        end else begin
            if (stop) pend <= 1'b1;
            if (take) begin
                own    <= 1'b1;
                pend   <= stop;
                a_done <= 1'b0;
                w_done <= 1'b0;
            end
            if (own) begin
                if (m_awvalid && m_awready) a_done <= 1'b1;
                if (m_wvalid && m_wready)   w_done <= 1'b1;
                if (m_bready && m_bvalid) begin
                    own     <= 1'b0;
                    n_abort <= n_abort + 1'b1;
                end
            end
            if (!g) begin
                if (s_awvalid && s_awready) aw_out <= 1'b1;
                if (s_wvalid && s_wready)   w_out  <= 1'b1;
                if (s_bvalid && s_bready) begin aw_out <= 1'b0; w_out <= 1'b0; end
                if (s_arvalid && s_arready) ar_out <= 1'b1;
                if (s_rvalid && s_rready)   ar_out <= 1'b0;
            end
        end
    end

endmodule
