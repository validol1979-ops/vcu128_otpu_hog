// l_ethernet configuration writes after every reset, then the register port to the bus.
//
// The RFSoC firmware (rfsoc_8x8_40g_compat_hog, sw/ps_console/src/main.cpp) writes
// CONFIGURATION_TX_REG1 explicitly instead of trusting the reset image: without FCS
// insertion the far-end NIC counts every jumbo frame as bad FCS. Here, without a
// processor, this module does it: while busy it owns the IP's s_axi (AXI4-Lite,
// s_axi_aclk = clk) and writes INIT_N (address, data) pairs; afterwards s_axi is
// passed through to the system bus (m_* from vcu128_axil_xbar) so the statistics stay
// readable from JTAG and the PC. A bus transaction arriving while busy waits.
// start: one-cycle pulse (sys_reset of l_ethernet released, synchronized to clk).

module eth40_mac_init #(
    parameter int              INIT_N    = 3,
    parameter logic [INIT_N-1:0][15:0] INIT_ADDR = '0,
    parameter logic [INIT_N-1:0][31:0] INIT_DATA = '0,
    parameter int              DELAY     = 1000    // clk cycles after start before the first write
)(
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    output logic        busy,
    output logic        done,

    // from the system bus (slave port of the xbar), 16-bit offsets in the 64 KiB window
    input  logic [15:0] s_awaddr,
    input  logic        s_awvalid,
    output logic        s_awready,
    input  logic [31:0] s_wdata,
    input  logic [3:0]  s_wstrb,
    input  logic        s_wvalid,
    output logic        s_wready,
    output logic [1:0]  s_bresp,
    output logic        s_bvalid,
    input  logic        s_bready,
    input  logic [15:0] s_araddr,
    input  logic        s_arvalid,
    output logic        s_arready,
    output logic [31:0] s_rdata,
    output logic [1:0]  s_rresp,
    output logic        s_rvalid,
    input  logic        s_rready,

    // to l_ethernet s_axi_0
    output logic [15:0] m_awaddr,
    output logic        m_awvalid,
    input  logic        m_awready,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_wstrb,
    output logic        m_wvalid,
    input  logic        m_wready,
    input  logic [1:0]  m_bresp,
    input  logic        m_bvalid,
    output logic        m_bready,
    output logic [15:0] m_araddr,
    output logic        m_arvalid,
    input  logic        m_arready,
    input  logic [31:0] m_rdata,
    input  logic [1:0]  m_rresp,
    input  logic        m_rvalid,
    output logic        m_rready
);

    localparam int IW = $clog2(INIT_N + 1);
    localparam int DW = $clog2(DELAY + 1);

    typedef enum logic [1:0] {I_IDLE, I_WAIT, I_WRITE, I_RESP} istate_t;
    istate_t       st;
    logic [IW-1:0] idx;
    logic [DW-1:0] cnt;
    logic          aw_done, w_done;
    // An outside transaction in progress: do not take the port in its middle.
    logic          ext_wr, ext_rd;

    assign busy = st != I_IDLE;

    always_ff @(posedge clk) begin
        if (rst) begin
            st      <= I_IDLE;
            done    <= 1'b0;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
        end else begin
            case (st)
                I_IDLE:
                    if (start) begin
                        done <= 1'b0;
                        cnt  <= DW'(DELAY);
                        idx  <= '0;
                        st   <= I_WAIT;
                    end
                I_WAIT:
                    if (cnt != '0)            cnt <= cnt - 1'b1;
                    else if (!ext_wr && !ext_rd) begin
                        aw_done <= 1'b0;
                        w_done  <= 1'b0;
                        st      <= I_WRITE;
                    end
                I_WRITE: begin
                    if (m_awvalid && m_awready) aw_done <= 1'b1;
                    if (m_wvalid && m_wready)   w_done  <= 1'b1;
                    if ((aw_done || m_awready) && (w_done || m_wready)) st <= I_RESP;
                end
                I_RESP:
                    if (m_bvalid) begin
                        aw_done <= 1'b0;
                        w_done  <= 1'b0;
                        if (idx == IW'(INIT_N - 1)) begin
                            done <= 1'b1;
                            st   <= I_IDLE;
                        end else begin
                            idx <= idx + 1'b1;
                            st  <= I_WRITE;
                        end
                    end
                default: st <= I_IDLE;
            endcase
            if (start && st != I_IDLE) begin       // restart from the beginning
                done <= 1'b0;
                cnt  <= DW'(DELAY);
                idx  <= '0;
                st   <= I_WAIT;
            end
        end
    end

    // Outside transactions: tracked so the init never cuts one.
    always_ff @(posedge clk) begin
        if (rst) begin
            ext_wr <= 1'b0;
            ext_rd <= 1'b0;
        end else begin
            if (!busy && s_awvalid && s_awready) ext_wr <= 1'b1;
            if (s_bvalid && s_bready)            ext_wr <= 1'b0;
            if (!busy && s_arvalid && s_arready) ext_rd <= 1'b1;
            if (s_rvalid && s_rready)            ext_rd <= 1'b0;
        end
    end

    wire own = st == I_WRITE || st == I_RESP;

    always_comb begin
        if (own) begin
            m_awaddr  = INIT_ADDR[idx];
            m_awvalid = !aw_done;
            m_wdata   = INIT_DATA[idx];
            m_wstrb   = 4'hF;
            m_wvalid  = !w_done;
            m_bready  = st == I_RESP;
            m_araddr  = '0;
            m_arvalid = 1'b0;
            m_rready  = 1'b0;
            s_awready = 1'b0;
            s_wready  = 1'b0;
            s_bvalid  = 1'b0;
            s_arready = 1'b0;
            s_rvalid  = 1'b0;
        end else begin
            // New outside transactions start only when idle; ones in progress finish.
            m_awaddr  = s_awaddr;
            m_awvalid = s_awvalid && (!busy || ext_wr);
            m_wdata   = s_wdata;
            m_wstrb   = s_wstrb;
            m_wvalid  = s_wvalid && (!busy || ext_wr);
            m_bready  = s_bready;
            m_araddr  = s_araddr;
            m_arvalid = s_arvalid && (!busy || ext_rd);
            m_rready  = s_rready;
            s_awready = m_awready && (!busy || ext_wr);
            s_wready  = m_wready && (!busy || ext_wr);
            s_bvalid  = m_bvalid;
            s_arready = m_arready && (!busy || ext_rd);
            s_rvalid  = m_rvalid;
        end
        s_bresp = m_bresp;
        s_rdata = m_rdata;
        s_rresp = m_rresp;
    end

endmodule
