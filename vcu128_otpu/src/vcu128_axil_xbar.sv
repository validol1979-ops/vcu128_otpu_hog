// AXI4-Lite interconnect: 2 masters -> NS slaves, one transaction at a time.
//
// Derived from vcu128_opentpu_hog axil_xbar.sv (2 x 2, tested there by cocotb):
// the slave count and the address windows are parameters here. Masters: 0 JTAG-to-AXI,
// 1 the 40G bridge (after its clock crossing). Round-robin between masters with a
// pending request; a write is accepted only with AW and W valid together. The request
// is registered, issued to the slave, the response registered and returned.
//
// Slave i takes addresses with (addr & ~MASK[i]) == BASE[i] (byte addresses, AW bits);
// the slave sees the full address. Other addresses answer DECERR.

module vcu128_axil_xbar #(
    parameter int AW = 20,
    parameter int NS = 3,
    parameter logic [NS-1:0][AW-1:0] BASE = '0,
    parameter logic [NS-1:0][AW-1:0] MASK = '0      // ones: address bits inside the window
)(
    input  logic        clk,
    input  logic        rst,

    // Masters (slave ports)
    input  logic [AW-1:0] s_awaddr  [2],
    input  logic          s_awvalid [2],
    output logic          s_awready [2],
    input  logic [31:0]   s_wdata   [2],
    input  logic [3:0]    s_wstrb   [2],
    input  logic          s_wvalid  [2],
    output logic          s_wready  [2],
    output logic [1:0]    s_bresp   [2],
    output logic          s_bvalid  [2],
    input  logic          s_bready  [2],
    input  logic [AW-1:0] s_araddr  [2],
    input  logic          s_arvalid [2],
    output logic          s_arready [2],
    output logic [31:0]   s_rdata   [2],
    output logic [1:0]    s_rresp   [2],
    output logic          s_rvalid  [2],
    input  logic          s_rready  [2],

    // Slaves (master ports)
    output logic [AW-1:0] m_awaddr  [NS],
    output logic          m_awvalid [NS],
    input  logic          m_awready [NS],
    output logic [31:0]   m_wdata   [NS],
    output logic [3:0]    m_wstrb   [NS],
    output logic          m_wvalid  [NS],
    input  logic          m_wready  [NS],
    input  logic [1:0]    m_bresp   [NS],
    input  logic          m_bvalid  [NS],
    output logic          m_bready  [NS],
    output logic [AW-1:0] m_araddr  [NS],
    output logic          m_arvalid [NS],
    input  logic          m_arready [NS],
    input  logic [31:0]   m_rdata   [NS],
    input  logic [1:0]    m_rresp   [NS],
    input  logic          m_rvalid  [NS],
    output logic          m_rready  [NS]
);

    localparam int TW = $clog2(NS > 1 ? NS : 2);

    typedef enum logic [2:0] {S_IDLE, S_WR, S_BRESP, S_RD, S_RRESP} state_t;
    state_t state;

    logic          grant, last;
    logic [TW-1:0] tgt;
    logic          decerr;
    logic [AW-1:0] addr;
    logic [31:0]   wdata, rdata;
    logic [3:0]    wstrb;
    logic [1:0]    resp;
    logic          a_done, w_done;   // AW (or AR) and W accepted by the slave

    logic wr_req [2], req [2];
    always_comb
        for (int i = 0; i < 2; i++) begin
            wr_req[i] = s_awvalid[i] && s_wvalid[i];
            req[i]    = wr_req[i] || s_arvalid[i];
        end

    wire pick     = req[!last] ? !last : last;
    wire start    = state == S_IDLE && req[pick];
    wire start_wr = start && wr_req[pick];
    wire [AW-1:0] new_addr = start_wr ? s_awaddr[pick] : s_araddr[pick];

    // Decode
    logic          hit;
    logic [TW-1:0] hit_idx;
    always_comb begin
        hit = 1'b0;
        hit_idx = '0;
        for (int i = NS - 1; i >= 0; i--)
            if ((new_addr & ~MASK[i]) == BASE[i]) begin
                hit = 1'b1;
                hit_idx = TW'(i);
            end
    end

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            s_awready[i] = start_wr && pick == i[0];
            s_wready[i]  = s_awready[i];
            s_arready[i] = start && !wr_req[pick] && pick == i[0];
            s_bvalid[i]  = state == S_BRESP && grant == i[0];
            s_bresp[i]   = resp;
            s_rvalid[i]  = state == S_RRESP && grant == i[0];
            s_rresp[i]   = resp;
            s_rdata[i]   = rdata;
        end
        for (int i = 0; i < NS; i++) begin
            m_awaddr[i]  = addr;
            m_awvalid[i] = state == S_WR && !decerr && tgt == TW'(i) && !a_done;
            m_wdata[i]   = wdata;
            m_wstrb[i]   = wstrb;
            m_wvalid[i]  = state == S_WR && !decerr && tgt == TW'(i) && !w_done;
            m_bready[i]  = state == S_WR && !decerr && tgt == TW'(i) && a_done && w_done;
            m_araddr[i]  = addr;
            m_arvalid[i] = state == S_RD && !decerr && tgt == TW'(i) && !a_done;
            m_rready[i]  = state == S_RD && !decerr && tgt == TW'(i) && a_done;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            grant  <= 1'b0;
            last   <= 1'b1;
            a_done <= 1'b0;
            w_done <= 1'b0;
        end else begin
            case (state)
                S_IDLE:
                    if (start) begin
                        grant  <= pick;
                        last   <= pick;
                        addr   <= new_addr;
                        tgt    <= hit_idx;
                        decerr <= !hit;
                        wdata  <= s_wdata[pick];
                        wstrb  <= s_wstrb[pick];
                        a_done <= 1'b0;
                        w_done <= 1'b0;
                        state  <= start_wr ? S_WR : S_RD;
                    end
                S_WR:
                    if (decerr) begin
                        resp  <= 2'b11;
                        state <= S_BRESP;
                    end else begin
                        if (m_awvalid[tgt] && m_awready[tgt]) a_done <= 1'b1;
                        if (m_wvalid[tgt] && m_wready[tgt])   w_done <= 1'b1;
                        if (m_bready[tgt] && m_bvalid[tgt]) begin
                            resp  <= m_bresp[tgt];
                            state <= S_BRESP;
                        end
                    end
                S_BRESP:
                    if (s_bready[grant]) state <= S_IDLE;
                S_RD:
                    if (decerr) begin
                        resp  <= 2'b11;
                        rdata <= 32'd0;
                        state <= S_RRESP;
                    end else begin
                        if (m_arvalid[tgt] && m_arready[tgt]) a_done <= 1'b1;
                        if (m_rready[tgt] && m_rvalid[tgt]) begin
                            resp  <= m_rresp[tgt];
                            rdata <= m_rdata[tgt];
                            state <= S_RRESP;
                        end
                    end
                S_RRESP:
                    if (s_rready[grant]) state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
