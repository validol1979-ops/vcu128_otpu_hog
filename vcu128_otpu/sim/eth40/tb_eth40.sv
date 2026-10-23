// Тестбенч-обёртка otpu_eth_bridge + eth40_regs для cocotb (Verilator): каналы DMA —
// плоские порты m0_…m7_ (модели AxiRam cocotbext-axi; AxSIZE 4 и INCR — константы, как
// их подразумевает otpu_mem_ch), AXI-Lite моста — простой декодер: окно 0x5xxxx — eth40_regs,
// остальное — порт r_* (модель AxiLiteRam). Мост держит не больше одной транзакции AXI-Lite
// и не меняет адрес до её конца, поэтому декодер комбинационный.
module tb_eth40 #(
    parameter int NC = 2
) (
    input  logic         clk,
    input  logic         rst,
    input  logic [255:0] rx_tdata, input logic [31:0] rx_tkeep, input logic rx_tvalid,
    input  logic         rx_tlast, input logic rx_tuser,
    output logic [255:0] tx_tdata, output logic [31:0] tx_tkeep, output logic tx_tvalid,
    output logic         tx_tlast, output logic tx_tuser, input logic tx_tready,
    // канал 0
    output logic [30:0]  m0_awaddr, output logic [7:0] m0_awlen, output logic [2:0] m0_awsize,
    output logic [1:0]   m0_awburst, output logic m0_awvalid, input logic m0_awready,
    output logic [127:0] m0_wdata, output logic [15:0] m0_wstrb, output logic m0_wlast,
    output logic         m0_wvalid, input logic m0_wready,
    input  logic [1:0]   m0_bresp, input logic m0_bvalid, output logic m0_bready,
    output logic [30:0]  m0_araddr, output logic [7:0] m0_arlen, output logic [2:0] m0_arsize,
    output logic [1:0]   m0_arburst, output logic m0_arvalid, input logic m0_arready,
    input  logic [127:0] m0_rdata, input logic [1:0] m0_rresp, input logic m0_rlast,
    input  logic         m0_rvalid, output logic m0_rready,
    output logic [0:0]   m0_awid, m0_arid, input logic [0:0] m0_bid, m0_rid,
    // канал 1
    output logic [30:0]  m1_awaddr, output logic [7:0] m1_awlen, output logic [2:0] m1_awsize,
    output logic [1:0]   m1_awburst, output logic m1_awvalid, input logic m1_awready,
    output logic [127:0] m1_wdata, output logic [15:0] m1_wstrb, output logic m1_wlast,
    output logic         m1_wvalid, input logic m1_wready,
    input  logic [1:0]   m1_bresp, input logic m1_bvalid, output logic m1_bready,
    output logic [30:0]  m1_araddr, output logic [7:0] m1_arlen, output logic [2:0] m1_arsize,
    output logic [1:0]   m1_arburst, output logic m1_arvalid, input logic m1_arready,
    input  logic [127:0] m1_rdata, input logic [1:0] m1_rresp, input logic m1_rlast,
    input  logic         m1_rvalid, output logic m1_rready,
    output logic [0:0]   m1_awid, m1_arid, input logic [0:0] m1_bid, m1_rid,
    // канал 2
    output logic [30:0]  m2_awaddr, output logic [7:0] m2_awlen, output logic [2:0] m2_awsize,
    output logic [1:0]   m2_awburst, output logic m2_awvalid, input logic m2_awready,
    output logic [127:0] m2_wdata, output logic [15:0] m2_wstrb, output logic m2_wlast,
    output logic         m2_wvalid, input logic m2_wready,
    input  logic [1:0]   m2_bresp, input logic m2_bvalid, output logic m2_bready,
    output logic [30:0]  m2_araddr, output logic [7:0] m2_arlen, output logic [2:0] m2_arsize,
    output logic [1:0]   m2_arburst, output logic m2_arvalid, input logic m2_arready,
    input  logic [127:0] m2_rdata, input logic [1:0] m2_rresp, input logic m2_rlast,
    input  logic         m2_rvalid, output logic m2_rready,
    output logic [0:0]   m2_awid, m2_arid, input logic [0:0] m2_bid, m2_rid,
    // канал 3
    output logic [30:0]  m3_awaddr, output logic [7:0] m3_awlen, output logic [2:0] m3_awsize,
    output logic [1:0]   m3_awburst, output logic m3_awvalid, input logic m3_awready,
    output logic [127:0] m3_wdata, output logic [15:0] m3_wstrb, output logic m3_wlast,
    output logic         m3_wvalid, input logic m3_wready,
    input  logic [1:0]   m3_bresp, input logic m3_bvalid, output logic m3_bready,
    output logic [30:0]  m3_araddr, output logic [7:0] m3_arlen, output logic [2:0] m3_arsize,
    output logic [1:0]   m3_arburst, output logic m3_arvalid, input logic m3_arready,
    input  logic [127:0] m3_rdata, input logic [1:0] m3_rresp, input logic m3_rlast,
    input  logic         m3_rvalid, output logic m3_rready,
    output logic [0:0]   m3_awid, m3_arid, input logic [0:0] m3_bid, m3_rid,
    // канал 4
    output logic [30:0]  m4_awaddr, output logic [7:0] m4_awlen, output logic [2:0] m4_awsize,
    output logic [1:0]   m4_awburst, output logic m4_awvalid, input logic m4_awready,
    output logic [127:0] m4_wdata, output logic [15:0] m4_wstrb, output logic m4_wlast,
    output logic         m4_wvalid, input logic m4_wready,
    input  logic [1:0]   m4_bresp, input logic m4_bvalid, output logic m4_bready,
    output logic [30:0]  m4_araddr, output logic [7:0] m4_arlen, output logic [2:0] m4_arsize,
    output logic [1:0]   m4_arburst, output logic m4_arvalid, input logic m4_arready,
    input  logic [127:0] m4_rdata, input logic [1:0] m4_rresp, input logic m4_rlast,
    input  logic         m4_rvalid, output logic m4_rready,
    output logic [0:0]   m4_awid, m4_arid, input logic [0:0] m4_bid, m4_rid,
    // канал 5
    output logic [30:0]  m5_awaddr, output logic [7:0] m5_awlen, output logic [2:0] m5_awsize,
    output logic [1:0]   m5_awburst, output logic m5_awvalid, input logic m5_awready,
    output logic [127:0] m5_wdata, output logic [15:0] m5_wstrb, output logic m5_wlast,
    output logic         m5_wvalid, input logic m5_wready,
    input  logic [1:0]   m5_bresp, input logic m5_bvalid, output logic m5_bready,
    output logic [30:0]  m5_araddr, output logic [7:0] m5_arlen, output logic [2:0] m5_arsize,
    output logic [1:0]   m5_arburst, output logic m5_arvalid, input logic m5_arready,
    input  logic [127:0] m5_rdata, input logic [1:0] m5_rresp, input logic m5_rlast,
    input  logic         m5_rvalid, output logic m5_rready,
    output logic [0:0]   m5_awid, m5_arid, input logic [0:0] m5_bid, m5_rid,
    // канал 6
    output logic [30:0]  m6_awaddr, output logic [7:0] m6_awlen, output logic [2:0] m6_awsize,
    output logic [1:0]   m6_awburst, output logic m6_awvalid, input logic m6_awready,
    output logic [127:0] m6_wdata, output logic [15:0] m6_wstrb, output logic m6_wlast,
    output logic         m6_wvalid, input logic m6_wready,
    input  logic [1:0]   m6_bresp, input logic m6_bvalid, output logic m6_bready,
    output logic [30:0]  m6_araddr, output logic [7:0] m6_arlen, output logic [2:0] m6_arsize,
    output logic [1:0]   m6_arburst, output logic m6_arvalid, input logic m6_arready,
    input  logic [127:0] m6_rdata, input logic [1:0] m6_rresp, input logic m6_rlast,
    input  logic         m6_rvalid, output logic m6_rready,
    output logic [0:0]   m6_awid, m6_arid, input logic [0:0] m6_bid, m6_rid,
    // канал 7
    output logic [30:0]  m7_awaddr, output logic [7:0] m7_awlen, output logic [2:0] m7_awsize,
    output logic [1:0]   m7_awburst, output logic m7_awvalid, input logic m7_awready,
    output logic [127:0] m7_wdata, output logic [15:0] m7_wstrb, output logic m7_wlast,
    output logic         m7_wvalid, input logic m7_wready,
    input  logic [1:0]   m7_bresp, input logic m7_bvalid, output logic m7_bready,
    output logic [30:0]  m7_araddr, output logic [7:0] m7_arlen, output logic [2:0] m7_arsize,
    output logic [1:0]   m7_arburst, output logic m7_arvalid, input logic m7_arready,
    input  logic [127:0] m7_rdata, input logic [1:0] m7_rresp, input logic m7_rlast,
    input  logic         m7_rvalid, output logic m7_rready,
    output logic [0:0]   m7_awid, m7_arid, input logic [0:0] m7_bid, m7_rid,
    // регистры вне окна eth40_regs
    output logic [19:0]  r_awaddr, output logic r_awvalid, input logic r_awready,
    output logic [31:0]  r_wdata, output logic [3:0] r_wstrb, output logic r_wvalid,
    input  logic         r_wready, input logic [1:0] r_bresp, input logic r_bvalid,
    output logic         r_bready,
    output logic [19:0]  r_araddr, output logic r_arvalid, input logic r_arready,
    input  logic [31:0]  r_rdata, input logic [1:0] r_rresp, input logic r_rvalid,
    output logic         r_rready,
    input  logic [31:0]  link_stat
);
    localparam int NEV = 17;
    logic [NC-1:0]        x_awvalid, x_awready, x_wvalid, x_wready, x_wlast, x_bvalid, x_bready;
    logic [NC-1:0][30:0]  x_awaddr, x_araddr;
    logic [NC-1:0][7:0]   x_awlen, x_arlen;
    logic [NC-1:0][127:0] x_wdata, x_rdata;
    logic [NC-1:0][15:0]  x_wstrb;
    logic [NC-1:0][1:0]   x_bresp, x_rresp;
    logic [NC-1:0]        x_arvalid, x_arready, x_rvalid, x_rready, x_rlast;

    logic [47:0] local_mac;
    logic [31:0] local_ip;
    logic [15:0] local_port;
    logic [NEV-1:0] ev;
    logic [31:0] status;

    logic [19:0] awaddr, araddr;
    logic awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic [1:0]  bresp, rresp;

    otpu_eth_bridge #(.NC(NC), .NEV(NEV)) dut (
        .clk, .rst, .local_mac, .local_ip, .local_port,
        .rx_tdata, .rx_tkeep, .rx_tvalid, .rx_tlast, .rx_tuser,
        .tx_tdata, .tx_tkeep, .tx_tvalid, .tx_tlast, .tx_tuser, .tx_tready,
        .x_awvalid, .x_awready, .x_awaddr, .x_awlen, .x_wvalid, .x_wready, .x_wdata, .x_wstrb,
        .x_wlast, .x_bvalid, .x_bready, .x_bresp, .x_arvalid, .x_arready, .x_araddr, .x_arlen,
        .x_rvalid, .x_rready, .x_rdata, .x_rresp, .x_rlast,
        .m_axil_awaddr(awaddr), .m_axil_awvalid(awvalid), .m_axil_awready(awready),
        .m_axil_wdata(wdata), .m_axil_wstrb(wstrb), .m_axil_wvalid(wvalid),
        .m_axil_wready(wready), .m_axil_bresp(bresp), .m_axil_bvalid(bvalid),
        .m_axil_bready(bready), .m_axil_araddr(araddr), .m_axil_arvalid(arvalid),
        .m_axil_arready(arready), .m_axil_rdata(rdata), .m_axil_rresp(rresp),
        .m_axil_rvalid(rvalid), .m_axil_rready(rready),
        .ev, .status);

    if (0 < NC) begin : g_c0
        assign m0_awaddr = x_awaddr[0]; assign m0_awlen = x_awlen[0];
        assign m0_awvalid = x_awvalid[0]; assign x_awready[0] = m0_awready;
        assign m0_wdata = x_wdata[0]; assign m0_wstrb = x_wstrb[0]; assign m0_wlast = x_wlast[0];
        assign m0_wvalid = x_wvalid[0]; assign x_wready[0] = m0_wready;
        assign x_bresp[0] = m0_bresp; assign x_bvalid[0] = m0_bvalid; assign m0_bready = x_bready[0];
        assign m0_araddr = x_araddr[0]; assign m0_arlen = x_arlen[0];
        assign m0_arvalid = x_arvalid[0]; assign x_arready[0] = m0_arready;
        assign x_rdata[0] = m0_rdata; assign x_rresp[0] = m0_rresp; assign x_rlast[0] = m0_rlast;
        assign x_rvalid[0] = m0_rvalid; assign m0_rready = x_rready[0];
    end else begin : g_n0
        assign m0_awaddr = '0; assign m0_awlen = '0; assign m0_awvalid = 1'b0;
        assign m0_wdata = '0; assign m0_wstrb = '0; assign m0_wlast = 1'b0; assign m0_wvalid = 1'b0;
        assign m0_bready = 1'b1; assign m0_araddr = '0; assign m0_arlen = '0;
        assign m0_arvalid = 1'b0; assign m0_rready = 1'b1;
    end
    assign m0_awid = 1'b0; assign m0_arid = 1'b0;
    assign m0_awsize = 3'd4; assign m0_awburst = 2'b01;
    assign m0_arsize = 3'd4; assign m0_arburst = 2'b01;
    if (1 < NC) begin : g_c1
        assign m1_awaddr = x_awaddr[1]; assign m1_awlen = x_awlen[1];
        assign m1_awvalid = x_awvalid[1]; assign x_awready[1] = m1_awready;
        assign m1_wdata = x_wdata[1]; assign m1_wstrb = x_wstrb[1]; assign m1_wlast = x_wlast[1];
        assign m1_wvalid = x_wvalid[1]; assign x_wready[1] = m1_wready;
        assign x_bresp[1] = m1_bresp; assign x_bvalid[1] = m1_bvalid; assign m1_bready = x_bready[1];
        assign m1_araddr = x_araddr[1]; assign m1_arlen = x_arlen[1];
        assign m1_arvalid = x_arvalid[1]; assign x_arready[1] = m1_arready;
        assign x_rdata[1] = m1_rdata; assign x_rresp[1] = m1_rresp; assign x_rlast[1] = m1_rlast;
        assign x_rvalid[1] = m1_rvalid; assign m1_rready = x_rready[1];
    end else begin : g_n1
        assign m1_awaddr = '0; assign m1_awlen = '0; assign m1_awvalid = 1'b0;
        assign m1_wdata = '0; assign m1_wstrb = '0; assign m1_wlast = 1'b0; assign m1_wvalid = 1'b0;
        assign m1_bready = 1'b1; assign m1_araddr = '0; assign m1_arlen = '0;
        assign m1_arvalid = 1'b0; assign m1_rready = 1'b1;
    end
    assign m1_awid = 1'b0; assign m1_arid = 1'b0;
    assign m1_awsize = 3'd4; assign m1_awburst = 2'b01;
    assign m1_arsize = 3'd4; assign m1_arburst = 2'b01;
    if (2 < NC) begin : g_c2
        assign m2_awaddr = x_awaddr[2]; assign m2_awlen = x_awlen[2];
        assign m2_awvalid = x_awvalid[2]; assign x_awready[2] = m2_awready;
        assign m2_wdata = x_wdata[2]; assign m2_wstrb = x_wstrb[2]; assign m2_wlast = x_wlast[2];
        assign m2_wvalid = x_wvalid[2]; assign x_wready[2] = m2_wready;
        assign x_bresp[2] = m2_bresp; assign x_bvalid[2] = m2_bvalid; assign m2_bready = x_bready[2];
        assign m2_araddr = x_araddr[2]; assign m2_arlen = x_arlen[2];
        assign m2_arvalid = x_arvalid[2]; assign x_arready[2] = m2_arready;
        assign x_rdata[2] = m2_rdata; assign x_rresp[2] = m2_rresp; assign x_rlast[2] = m2_rlast;
        assign x_rvalid[2] = m2_rvalid; assign m2_rready = x_rready[2];
    end else begin : g_n2
        assign m2_awaddr = '0; assign m2_awlen = '0; assign m2_awvalid = 1'b0;
        assign m2_wdata = '0; assign m2_wstrb = '0; assign m2_wlast = 1'b0; assign m2_wvalid = 1'b0;
        assign m2_bready = 1'b1; assign m2_araddr = '0; assign m2_arlen = '0;
        assign m2_arvalid = 1'b0; assign m2_rready = 1'b1;
    end
    assign m2_awid = 1'b0; assign m2_arid = 1'b0;
    assign m2_awsize = 3'd4; assign m2_awburst = 2'b01;
    assign m2_arsize = 3'd4; assign m2_arburst = 2'b01;
    if (3 < NC) begin : g_c3
        assign m3_awaddr = x_awaddr[3]; assign m3_awlen = x_awlen[3];
        assign m3_awvalid = x_awvalid[3]; assign x_awready[3] = m3_awready;
        assign m3_wdata = x_wdata[3]; assign m3_wstrb = x_wstrb[3]; assign m3_wlast = x_wlast[3];
        assign m3_wvalid = x_wvalid[3]; assign x_wready[3] = m3_wready;
        assign x_bresp[3] = m3_bresp; assign x_bvalid[3] = m3_bvalid; assign m3_bready = x_bready[3];
        assign m3_araddr = x_araddr[3]; assign m3_arlen = x_arlen[3];
        assign m3_arvalid = x_arvalid[3]; assign x_arready[3] = m3_arready;
        assign x_rdata[3] = m3_rdata; assign x_rresp[3] = m3_rresp; assign x_rlast[3] = m3_rlast;
        assign x_rvalid[3] = m3_rvalid; assign m3_rready = x_rready[3];
    end else begin : g_n3
        assign m3_awaddr = '0; assign m3_awlen = '0; assign m3_awvalid = 1'b0;
        assign m3_wdata = '0; assign m3_wstrb = '0; assign m3_wlast = 1'b0; assign m3_wvalid = 1'b0;
        assign m3_bready = 1'b1; assign m3_araddr = '0; assign m3_arlen = '0;
        assign m3_arvalid = 1'b0; assign m3_rready = 1'b1;
    end
    assign m3_awid = 1'b0; assign m3_arid = 1'b0;
    assign m3_awsize = 3'd4; assign m3_awburst = 2'b01;
    assign m3_arsize = 3'd4; assign m3_arburst = 2'b01;

    if (4 < NC) begin : g_c4
        assign m4_awaddr = x_awaddr[4]; assign m4_awlen = x_awlen[4];
        assign m4_awvalid = x_awvalid[4]; assign x_awready[4] = m4_awready;
        assign m4_wdata = x_wdata[4]; assign m4_wstrb = x_wstrb[4]; assign m4_wlast = x_wlast[4];
        assign m4_wvalid = x_wvalid[4]; assign x_wready[4] = m4_wready;
        assign x_bresp[4] = m4_bresp; assign x_bvalid[4] = m4_bvalid; assign m4_bready = x_bready[4];
        assign m4_araddr = x_araddr[4]; assign m4_arlen = x_arlen[4];
        assign m4_arvalid = x_arvalid[4]; assign x_arready[4] = m4_arready;
        assign x_rdata[4] = m4_rdata; assign x_rresp[4] = m4_rresp; assign x_rlast[4] = m4_rlast;
        assign x_rvalid[4] = m4_rvalid; assign m4_rready = x_rready[4];
    end else begin : g_n4
        assign m4_awaddr = '0; assign m4_awlen = '0; assign m4_awvalid = 1'b0;
        assign m4_wdata = '0; assign m4_wstrb = '0; assign m4_wlast = 1'b0; assign m4_wvalid = 1'b0;
        assign m4_bready = 1'b1; assign m4_araddr = '0; assign m4_arlen = '0;
        assign m4_arvalid = 1'b0; assign m4_rready = 1'b1;
    end
    assign m4_awid = 1'b0; assign m4_arid = 1'b0;
    assign m4_awsize = 3'd4; assign m4_awburst = 2'b01;
    assign m4_arsize = 3'd4; assign m4_arburst = 2'b01;

    if (5 < NC) begin : g_c5
        assign m5_awaddr = x_awaddr[5]; assign m5_awlen = x_awlen[5];
        assign m5_awvalid = x_awvalid[5]; assign x_awready[5] = m5_awready;
        assign m5_wdata = x_wdata[5]; assign m5_wstrb = x_wstrb[5]; assign m5_wlast = x_wlast[5];
        assign m5_wvalid = x_wvalid[5]; assign x_wready[5] = m5_wready;
        assign x_bresp[5] = m5_bresp; assign x_bvalid[5] = m5_bvalid; assign m5_bready = x_bready[5];
        assign m5_araddr = x_araddr[5]; assign m5_arlen = x_arlen[5];
        assign m5_arvalid = x_arvalid[5]; assign x_arready[5] = m5_arready;
        assign x_rdata[5] = m5_rdata; assign x_rresp[5] = m5_rresp; assign x_rlast[5] = m5_rlast;
        assign x_rvalid[5] = m5_rvalid; assign m5_rready = x_rready[5];
    end else begin : g_n5
        assign m5_awaddr = '0; assign m5_awlen = '0; assign m5_awvalid = 1'b0;
        assign m5_wdata = '0; assign m5_wstrb = '0; assign m5_wlast = 1'b0; assign m5_wvalid = 1'b0;
        assign m5_bready = 1'b1; assign m5_araddr = '0; assign m5_arlen = '0;
        assign m5_arvalid = 1'b0; assign m5_rready = 1'b1;
    end
    assign m5_awid = 1'b0; assign m5_arid = 1'b0;
    assign m5_awsize = 3'd4; assign m5_awburst = 2'b01;
    assign m5_arsize = 3'd4; assign m5_arburst = 2'b01;

    if (6 < NC) begin : g_c6
        assign m6_awaddr = x_awaddr[6]; assign m6_awlen = x_awlen[6];
        assign m6_awvalid = x_awvalid[6]; assign x_awready[6] = m6_awready;
        assign m6_wdata = x_wdata[6]; assign m6_wstrb = x_wstrb[6]; assign m6_wlast = x_wlast[6];
        assign m6_wvalid = x_wvalid[6]; assign x_wready[6] = m6_wready;
        assign x_bresp[6] = m6_bresp; assign x_bvalid[6] = m6_bvalid; assign m6_bready = x_bready[6];
        assign m6_araddr = x_araddr[6]; assign m6_arlen = x_arlen[6];
        assign m6_arvalid = x_arvalid[6]; assign x_arready[6] = m6_arready;
        assign x_rdata[6] = m6_rdata; assign x_rresp[6] = m6_rresp; assign x_rlast[6] = m6_rlast;
        assign x_rvalid[6] = m6_rvalid; assign m6_rready = x_rready[6];
    end else begin : g_n6
        assign m6_awaddr = '0; assign m6_awlen = '0; assign m6_awvalid = 1'b0;
        assign m6_wdata = '0; assign m6_wstrb = '0; assign m6_wlast = 1'b0; assign m6_wvalid = 1'b0;
        assign m6_bready = 1'b1; assign m6_araddr = '0; assign m6_arlen = '0;
        assign m6_arvalid = 1'b0; assign m6_rready = 1'b1;
    end
    assign m6_awid = 1'b0; assign m6_arid = 1'b0;
    assign m6_awsize = 3'd4; assign m6_awburst = 2'b01;
    assign m6_arsize = 3'd4; assign m6_arburst = 2'b01;

    if (7 < NC) begin : g_c7
        assign m7_awaddr = x_awaddr[7]; assign m7_awlen = x_awlen[7];
        assign m7_awvalid = x_awvalid[7]; assign x_awready[7] = m7_awready;
        assign m7_wdata = x_wdata[7]; assign m7_wstrb = x_wstrb[7]; assign m7_wlast = x_wlast[7];
        assign m7_wvalid = x_wvalid[7]; assign x_wready[7] = m7_wready;
        assign x_bresp[7] = m7_bresp; assign x_bvalid[7] = m7_bvalid; assign m7_bready = x_bready[7];
        assign m7_araddr = x_araddr[7]; assign m7_arlen = x_arlen[7];
        assign m7_arvalid = x_arvalid[7]; assign x_arready[7] = m7_arready;
        assign x_rdata[7] = m7_rdata; assign x_rresp[7] = m7_rresp; assign x_rlast[7] = m7_rlast;
        assign x_rvalid[7] = m7_rvalid; assign m7_rready = x_rready[7];
    end else begin : g_n7
        assign m7_awaddr = '0; assign m7_awlen = '0; assign m7_awvalid = 1'b0;
        assign m7_wdata = '0; assign m7_wstrb = '0; assign m7_wlast = 1'b0; assign m7_wvalid = 1'b0;
        assign m7_bready = 1'b1; assign m7_araddr = '0; assign m7_arlen = '0;
        assign m7_arvalid = 1'b0; assign m7_rready = 1'b1;
    end
    assign m7_awid = 1'b0; assign m7_arid = 1'b0;
    assign m7_awsize = 3'd4; assign m7_awburst = 2'b01;
    assign m7_arsize = 3'd4; assign m7_arburst = 2'b01;

    // декодер AXI-Lite
    wire w5 = awaddr[19:16] == 4'h5;
    wire r5 = araddr[19:16] == 4'h5;
    logic g_awready, g_wready, g_bvalid, g_arready, g_rvalid;
    logic [1:0] g_bresp, g_rresp;
    logic [31:0] g_rdata;
    eth40_regs #(.AW(8), .NEV(NEV), .PARAMS(32'(NC))) u_regs (
        .clk, .rst,
        .s_awaddr(awaddr[7:0]), .s_awvalid(awvalid && w5), .s_awready(g_awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid && w5), .s_wready(g_wready),
        .s_bresp(g_bresp), .s_bvalid(g_bvalid), .s_bready(bready && w5),
        .s_araddr(araddr[7:0]), .s_arvalid(arvalid && r5), .s_arready(g_arready),
        .s_rdata(g_rdata), .s_rresp(g_rresp), .s_rvalid(g_rvalid), .s_rready(rready && r5),
        .local_mac, .local_ip, .local_port, .link_stat, .bridge_stat(status), .ev);

    assign r_awaddr = awaddr; assign r_awvalid = awvalid && !w5;
    assign r_wdata = wdata; assign r_wstrb = wstrb; assign r_wvalid = wvalid && !w5;
    assign r_bready = bready && !w5;
    assign r_araddr = araddr; assign r_arvalid = arvalid && !r5; assign r_rready = rready && !r5;
    assign awready = w5 ? g_awready : r_awready;
    assign wready  = w5 ? g_wready : r_wready;
    assign bvalid  = w5 ? g_bvalid : r_bvalid;
    assign bresp   = w5 ? g_bresp : r_bresp;
    assign arready = r5 ? g_arready : r_arready;
    assign rvalid  = r5 ? g_rvalid : r_rvalid;
    assign rdata   = r5 ? g_rdata : r_rdata;
    assign rresp   = r5 ? g_rresp : r_rresp;

endmodule
