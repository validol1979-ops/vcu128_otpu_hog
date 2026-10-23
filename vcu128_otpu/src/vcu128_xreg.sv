// Register slices on the 40G bridge's DMA masters (eth_clk, 312.5 MHz), one chain per memory
// channel between otpu_eth_bridge (x_* master) and otpu_bcu_sys (otpu_mem_ch's xclk side).
// Each stage is verilog-axi axi_register with skid buffers on all five channels, so every
// signal of the interface, valid, data and ready, leaves a flip-flop: the bridge no longer sits
// combinationally on the otpu_mem_ch ports, which at S = 2 are spread along HBM (channels 0, 1 at
// AXI ports 00..03, 2, 3 at 16..19). Latency +STAGES cycles each way; the protocol is AXI4's.
// STAGES = 0: wires.
module vcu128_xreg #(
    parameter int NC     = 4,
    parameter int STAGES = 2
) (
    input  logic                  clk,
    input  logic                  rst,
    // slave: the bridge
    input  logic [NC-1:0]         s_awvalid,
    output logic [NC-1:0]         s_awready,
    input  logic [NC-1:0][30:0]   s_awaddr,
    input  logic [NC-1:0][7:0]    s_awlen,
    input  logic [NC-1:0]         s_wvalid,
    output logic [NC-1:0]         s_wready,
    input  logic [NC-1:0][127:0]  s_wdata,
    input  logic [NC-1:0][15:0]   s_wstrb,
    input  logic [NC-1:0]         s_wlast,
    output logic [NC-1:0]         s_bvalid,
    input  logic [NC-1:0]         s_bready,
    output logic [NC-1:0][1:0]    s_bresp,
    input  logic [NC-1:0]         s_arvalid,
    output logic [NC-1:0]         s_arready,
    input  logic [NC-1:0][30:0]   s_araddr,
    input  logic [NC-1:0][7:0]    s_arlen,
    output logic [NC-1:0]         s_rvalid,
    input  logic [NC-1:0]         s_rready,
    output logic [NC-1:0][127:0]  s_rdata,
    output logic [NC-1:0][1:0]    s_rresp,
    output logic [NC-1:0]         s_rlast,
    // master: otpu_bcu_sys
    output logic [NC-1:0]         m_awvalid,
    input  logic [NC-1:0]         m_awready,
    output logic [NC-1:0][30:0]   m_awaddr,
    output logic [NC-1:0][7:0]    m_awlen,
    output logic [NC-1:0]         m_wvalid,
    input  logic [NC-1:0]         m_wready,
    output logic [NC-1:0][127:0]  m_wdata,
    output logic [NC-1:0][15:0]   m_wstrb,
    output logic [NC-1:0]         m_wlast,
    input  logic [NC-1:0]         m_bvalid,
    output logic [NC-1:0]         m_bready,
    input  logic [NC-1:0][1:0]    m_bresp,
    output logic [NC-1:0]         m_arvalid,
    input  logic [NC-1:0]         m_arready,
    output logic [NC-1:0][30:0]   m_araddr,
    output logic [NC-1:0][7:0]    m_arlen,
    input  logic [NC-1:0]         m_rvalid,
    output logic [NC-1:0]         m_rready,
    input  logic [NC-1:0][127:0]  m_rdata,
    input  logic [NC-1:0][1:0]    m_rresp,
    input  logic [NC-1:0]         m_rlast
);
    for (genvar j = 0; j < NC; j++) begin : g_ch
        // stage k's slave side is c_*[k], its master side c_*[k + 1]
        logic [STAGES:0]        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
        logic [STAGES:0]        arvalid, arready, rvalid, rready, rlast;
        logic [STAGES:0][30:0]  awaddr, araddr;
        logic [STAGES:0][7:0]   awlen, arlen;
        logic [STAGES:0][127:0] wdata, rdata;
        logic [STAGES:0][15:0]  wstrb;
        logic [STAGES:0][1:0]   bresp, rresp;

        assign awvalid[0] = s_awvalid[j]; assign s_awready[j] = awready[0];
        assign awaddr[0]  = s_awaddr[j];  assign awlen[0]     = s_awlen[j];
        assign wvalid[0]  = s_wvalid[j];  assign s_wready[j]  = wready[0];
        assign wdata[0]   = s_wdata[j];   assign wstrb[0]     = s_wstrb[j];
        assign wlast[0]   = s_wlast[j];
        assign s_bvalid[j] = bvalid[0];   assign bready[0]    = s_bready[j];
        assign s_bresp[j]  = bresp[0];
        assign arvalid[0] = s_arvalid[j]; assign s_arready[j] = arready[0];
        assign araddr[0]  = s_araddr[j];  assign arlen[0]     = s_arlen[j];
        assign s_rvalid[j] = rvalid[0];   assign rready[0]    = s_rready[j];
        assign s_rdata[j]  = rdata[0];    assign s_rresp[j]   = rresp[0];
        assign s_rlast[j]  = rlast[0];

        assign m_awvalid[j] = awvalid[STAGES]; assign awready[STAGES] = m_awready[j];
        assign m_awaddr[j]  = awaddr[STAGES];  assign m_awlen[j]      = awlen[STAGES];
        assign m_wvalid[j]  = wvalid[STAGES];  assign wready[STAGES]  = m_wready[j];
        assign m_wdata[j]   = wdata[STAGES];   assign m_wstrb[j]      = wstrb[STAGES];
        assign m_wlast[j]   = wlast[STAGES];
        assign bvalid[STAGES] = m_bvalid[j];   assign m_bready[j]     = bready[STAGES];
        assign bresp[STAGES]  = m_bresp[j];
        assign m_arvalid[j] = arvalid[STAGES]; assign arready[STAGES] = m_arready[j];
        assign m_araddr[j]  = araddr[STAGES];  assign m_arlen[j]      = arlen[STAGES];
        assign rvalid[STAGES] = m_rvalid[j];   assign m_rready[j]     = rready[STAGES];
        assign rdata[STAGES]  = m_rdata[j];    assign rresp[STAGES]   = m_rresp[j];
        assign rlast[STAGES]  = m_rlast[j];

        for (genvar k = 0; k < STAGES; k++) begin : g_st
            axi_register #(
                .DATA_WIDTH (128), .ADDR_WIDTH (31), .STRB_WIDTH (16), .ID_WIDTH (1),
                .AW_REG_TYPE (2), .W_REG_TYPE (2), .B_REG_TYPE (2), .AR_REG_TYPE (2),
                .R_REG_TYPE (2)
            ) u_reg (
                .clk (clk), .rst (rst),
                .s_axi_awid (1'b0), .s_axi_awaddr (awaddr[k]), .s_axi_awlen (awlen[k]),
                .s_axi_awsize (3'd4), .s_axi_awburst (2'b01), .s_axi_awlock (1'b0),
                .s_axi_awcache (4'd0), .s_axi_awprot (3'd0), .s_axi_awqos (4'd0),
                .s_axi_awregion (4'd0), .s_axi_awuser (1'b0),
                .s_axi_awvalid (awvalid[k]), .s_axi_awready (awready[k]),
                .s_axi_wdata (wdata[k]), .s_axi_wstrb (wstrb[k]), .s_axi_wlast (wlast[k]),
                .s_axi_wuser (1'b0), .s_axi_wvalid (wvalid[k]), .s_axi_wready (wready[k]),
                .s_axi_bid (), .s_axi_bresp (bresp[k]), .s_axi_buser (),
                .s_axi_bvalid (bvalid[k]), .s_axi_bready (bready[k]),
                .s_axi_arid (1'b0), .s_axi_araddr (araddr[k]), .s_axi_arlen (arlen[k]),
                .s_axi_arsize (3'd4), .s_axi_arburst (2'b01), .s_axi_arlock (1'b0),
                .s_axi_arcache (4'd0), .s_axi_arprot (3'd0), .s_axi_arqos (4'd0),
                .s_axi_arregion (4'd0), .s_axi_aruser (1'b0),
                .s_axi_arvalid (arvalid[k]), .s_axi_arready (arready[k]),
                .s_axi_rid (), .s_axi_rdata (rdata[k]), .s_axi_rresp (rresp[k]),
                .s_axi_rlast (rlast[k]), .s_axi_ruser (),
                .s_axi_rvalid (rvalid[k]), .s_axi_rready (rready[k]),
                .m_axi_awid (), .m_axi_awaddr (awaddr[k+1]), .m_axi_awlen (awlen[k+1]),
                .m_axi_awsize (), .m_axi_awburst (), .m_axi_awlock (), .m_axi_awcache (),
                .m_axi_awprot (), .m_axi_awqos (), .m_axi_awregion (), .m_axi_awuser (),
                .m_axi_awvalid (awvalid[k+1]), .m_axi_awready (awready[k+1]),
                .m_axi_wdata (wdata[k+1]), .m_axi_wstrb (wstrb[k+1]), .m_axi_wlast (wlast[k+1]),
                .m_axi_wuser (), .m_axi_wvalid (wvalid[k+1]), .m_axi_wready (wready[k+1]),
                .m_axi_bid (1'b0), .m_axi_bresp (bresp[k+1]), .m_axi_buser (1'b0),
                .m_axi_bvalid (bvalid[k+1]), .m_axi_bready (bready[k+1]),
                .m_axi_arid (), .m_axi_araddr (araddr[k+1]), .m_axi_arlen (arlen[k+1]),
                .m_axi_arsize (), .m_axi_arburst (), .m_axi_arlock (), .m_axi_arcache (),
                .m_axi_arprot (), .m_axi_arqos (), .m_axi_arregion (), .m_axi_aruser (),
                .m_axi_arvalid (arvalid[k+1]), .m_axi_arready (arready[k+1]),
                .m_axi_rid (1'b0), .m_axi_rdata (rdata[k+1]), .m_axi_rresp (rresp[k+1]),
                .m_axi_rlast (rlast[k+1]), .m_axi_ruser (1'b0),
                .m_axi_rvalid (rvalid[k+1]), .m_axi_rready (rready[k+1])
            );
        end
    end
endmodule
