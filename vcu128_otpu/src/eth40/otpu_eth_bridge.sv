// Мост «40G UDP ↔ AXI4 + AXI-Lite»: замена XDMA upstream openTPU (BCU1525) на 40G
// Ethernet VCU128. Протокол — doc/eth40_protocol.md. Всё в домене eth_clk
// (tx_clk_out l_ethernet, 156,25 МГц), синхронный сброс активной 1.
//
//   MAC RX ─┬─ eth40_rx_filter ─ axis_fifo (кадровая, RXB байт) ─ eth40_disp ─┬─ eth40_wr ─ AW/W/B
//           └─ eth40_arp_rx ──────────────────────┐                        ├─ eth40_rd ─ AR/R ─ FIFO данных ─┐
//                                                 │                        ├─ eth40_regx ─ AXI-Lite         │
//   MAC TX ── eth40_tx_mux (ARP, служебные, данные) ◄─ FIFO служебных ◄─ eth40_ctl_tx ◄┘                  │
//                          ◄─────────────────────────────────────────────────────────────────────────────────┘
//
// MAC (l_ethernet 3.3, 256-битный AXIS): RX без tready, tuser = 1 на TLAST — плохой
// кадр; FCS MAC удаляет (ctl_rx_delete_fcs) — если нет, хвост из 4 байт допускается.
// TX: FCS добавляет MAC (ctl_tx_fcs_ins_enable = 1, CONFIGURATION_TX_REG1 бит 1),
// tuser = 0; кадр подаётся без разрывов tvalid (кадровые FIFO).
//
// Порты DMA — по каналу j = 2s + c, в формате x_* upstream otpu_bcu_sys (сторона XDMA
// otpu_mem_ch): 128 бит, адрес — смещение в канале (31 бит), INCR из 16-байтных beat
// (AxSIZE 4), без ID, ответы по порядку. AXI-Lite — 20 бит адреса (окна 0x00000 ядро,
// 0x30000 SYSMON, 0x40000 платформа, 0x50000 eth40_regs), не больше одной транзакции
// в полёте. Окна декодирует и в домен ядра переводит верхний уровень.
module otpu_eth_bridge
    import eth40_pkg::*;
#(
    parameter int NC     = 2,           // каналов памяти (1..8: S = 1, 2, 4)
    parameter int RXB    = 131072,      // байт кадровой FIFO приёма
    parameter int TXDB   = 32768,       // байт FIFO кадров данных чтения
    parameter int TXCB   = 8192,        // байт FIFO служебных ответов
    parameter int MAXW   = 8192,        // байт данных в кадре, не больше
    parameter int AQ     = 32,          // записей в ожидании B
    parameter int REGMAX = 256,         // операций в пачке регистров
    parameter int NEV    = 17
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic [47:0]          local_mac,
    input  logic [31:0]          local_ip,
    input  logic [15:0]          local_port,

    // l_ethernet RX
    input  logic [255:0]         rx_tdata,
    input  logic [31:0]          rx_tkeep,
    input  logic                 rx_tvalid,
    input  logic                 rx_tlast,
    input  logic                 rx_tuser,
    // l_ethernet TX
    output logic [255:0]         tx_tdata,
    output logic [31:0]          tx_tkeep,
    output logic                 tx_tvalid,
    output logic                 tx_tlast,
    output logic                 tx_tuser,
    input  logic                 tx_tready,

    // DMA: AXI4-мастер на канал (otpu_bcu_sys x_*)
    output logic [NC-1:0]        x_awvalid,
    input  logic [NC-1:0]        x_awready,
    output logic [NC-1:0][30:0]  x_awaddr,
    output logic [NC-1:0][7:0]   x_awlen,
    output logic [NC-1:0]        x_wvalid,
    input  logic [NC-1:0]        x_wready,
    output logic [NC-1:0][127:0] x_wdata,
    output logic [NC-1:0][15:0]  x_wstrb,
    output logic [NC-1:0]        x_wlast,
    input  logic [NC-1:0]        x_bvalid,
    output logic [NC-1:0]        x_bready,
    input  logic [NC-1:0][1:0]   x_bresp,
    output logic [NC-1:0]        x_arvalid,
    input  logic [NC-1:0]        x_arready,
    output logic [NC-1:0][30:0]  x_araddr,
    output logic [NC-1:0][7:0]   x_arlen,
    input  logic [NC-1:0]        x_rvalid,
    output logic [NC-1:0]        x_rready,
    input  logic [NC-1:0][127:0] x_rdata,
    input  logic [NC-1:0][1:0]   x_rresp,
    input  logic [NC-1:0]        x_rlast,

    // регистры: мастер AXI-Lite
    output logic [19:0]          m_axil_awaddr,
    output logic                 m_axil_awvalid,
    input  logic                 m_axil_awready,
    output logic [31:0]          m_axil_wdata,
    output logic [3:0]           m_axil_wstrb,
    output logic                 m_axil_wvalid,
    input  logic                 m_axil_wready,
    input  logic [1:0]           m_axil_bresp,
    input  logic                 m_axil_bvalid,
    output logic                 m_axil_bready,
    output logic [19:0]          m_axil_araddr,
    output logic                 m_axil_arvalid,
    input  logic                 m_axil_arready,
    input  logic [31:0]          m_axil_rdata,
    input  logic [1:0]           m_axil_rresp,
    input  logic                 m_axil_rvalid,
    output logic                 m_axil_rready,

    // в eth40_regs
    output logic [NEV-1:0]       ev,
    output logic [31:0]          status
);
    initial if (NC < 1 || NC > 8) $fatal(1, "otpu_eth_bridge: NC must be 1..8");

    // ---------------------------------------------------------------- приём
    logic [255:0] f_tdata;
    logic [31:0]  f_tkeep;
    logic         f_tvalid, f_tlast, f_tuser;
    logic         ev_frame, ev_rxbad, ev_accept, ev_ignore;
    eth40_rx_filter u_filt (
        .clk, .rst, .local_mac, .local_ip, .local_port,
        .s_tdata(rx_tdata), .s_tkeep(rx_tkeep), .s_tvalid(rx_tvalid), .s_tlast(rx_tlast),
        .s_tuser(rx_tuser),
        .m_tdata(f_tdata), .m_tkeep(f_tkeep), .m_tvalid(f_tvalid), .m_tlast(f_tlast),
        .m_tuser(f_tuser),
        .ev_frame, .ev_bad(ev_rxbad), .ev_accept, .ev_ignore);

    logic        arp_req, ev_ctl;
    logic [47:0] arp_mac;
    logic [31:0] arp_ip;
    eth40_arp_rx u_arp (
        .clk, .rst, .local_mac, .local_ip,
        .s_tdata(rx_tdata), .s_tvalid(rx_tvalid), .s_tlast(rx_tlast), .s_tuser(rx_tuser),
        .req_valid(arp_req), .req_mac(arp_mac), .req_ip(arp_ip), .ev_ctl);

    logic [255:0] q_tdata;
    logic         q_tvalid, q_tlast, q_tready, ev_ovf;
    logic [$clog2(RXB):0] rx_depth;
    axis_fifo #(.DEPTH(RXB), .DATA_WIDTH(256), .KEEP_ENABLE(1), .KEEP_WIDTH(32),
        .LAST_ENABLE(1), .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
        .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(1), .DROP_WHEN_FULL(1)) u_rxq (
        .clk, .rst,
        .s_axis_tdata(f_tdata), .s_axis_tkeep(f_tkeep), .s_axis_tvalid(f_tvalid),
        .s_axis_tready(), .s_axis_tlast(f_tlast), .s_axis_tid(8'b0), .s_axis_tdest(8'b0),
        .s_axis_tuser(f_tuser),
        .m_axis_tdata(q_tdata), .m_axis_tkeep(), .m_axis_tvalid(q_tvalid),
        .m_axis_tready(q_tready), .m_axis_tlast(q_tlast), .m_axis_tid(), .m_axis_tdest(),
        .m_axis_tuser(),
        .pause_req(1'b0), .pause_ack(),
        .status_depth(), .status_depth_commit(rx_depth), .status_overflow(ev_ovf),
        .status_bad_frame(), .status_good_frame());

    // ---------------------------------------------------------------- разбор
    logic        wd_valid, wd_ready, aq_ready, w_valid, w_ready, w_last;
    logic [7:0]  wd_ch, w_ch;
    logic [30:0] wd_off;
    logic [31:0] wd_len;
    req_t        wd_req, rd_req, rx_req, er_req;
    logic [3:0]  wd_nb;
    logic [127:0] w_data;
    logic        rd_valid, rd_ready;
    logic        rx_busy, rx_kvalid, rx_replay, rx_we, rx_start;
    logic [31:0] rx_kseq, rx_kip;
    logic [15:0] rx_kport;
    logic [$clog2(REGMAX/2)-1:0] rx_waddr;
    logic [255:0] rx_wdata;
    logic        er_valid, er_ready;
    logic [31:0] er_idx;
    logic        ev_write, ev_read, ev_reg, ev_dup, ev_busy, ev_bad;

    eth40_disp #(.NC(NC), .MAXW(MAXW), .REGMAX(REGMAX)) u_disp (
        .clk, .rst,
        .s_tdata(q_tdata), .s_tvalid(q_tvalid), .s_tlast(q_tlast), .s_tready(q_tready),
        .wd_valid, .wd_ready, .wd_ch, .wd_off, .wd_len, .aq_ready, .wd_req, .wd_nb,
        .w_valid, .w_ready, .w_ch, .w_data, .w_last,
        .rd_valid, .rd_ready, .rd_req,
        .rx_busy, .rx_kvalid, .rx_kseq, .rx_kip, .rx_kport, .rx_replay, .rx_we, .rx_waddr,
        .rx_wdata, .rx_start, .rx_req,
        .er_valid, .er_ready, .er_req, .er_idx,
        .ev_write, .ev_read, .ev_reg, .ev_dup, .ev_busy, .ev_bad);

    // ---------------------------------------------------------------- запись
    logic   ak_valid, ak_ready, wr_busy, ev_werr;
    req_t   ak_req;
    logic [7:0] ak_st;
    eth40_wr #(.NC(NC), .AQ(AQ)) u_wr (
        .clk, .rst,
        .wd_valid, .wd_ready, .wd_ch, .wd_off, .wd_len, .aq_ready, .wd_req, .wd_nb,
        .w_valid, .w_ready, .w_ch, .w_data, .w_last,
        .x_awvalid, .x_awready, .x_awaddr, .x_awlen, .x_wvalid, .x_wready, .x_wdata,
        .x_wstrb, .x_wlast, .x_bvalid, .x_bready, .x_bresp,
        .ak_valid, .ak_ready, .ak_req, .ak_st, .ev_axi_err(ev_werr), .busy(wr_busy));

    // ---------------------------------------------------------------- чтение
    logic [255:0] d_tdata;
    logic [31:0]  d_tkeep;
    logic         d_tvalid, d_tlast, d_tready, rd_busy, ev_rframe, ev_rerr;
    eth40_rd #(.NC(NC), .MAXW(MAXW)) u_rd (
        .clk, .rst, .local_mac, .local_ip, .local_port,
        .rd_valid, .rd_ready, .rd_req,
        .x_arvalid, .x_arready, .x_araddr, .x_arlen, .x_rvalid, .x_rready, .x_rdata,
        .x_rresp, .x_rlast,
        .m_tdata(d_tdata), .m_tkeep(d_tkeep), .m_tvalid(d_tvalid), .m_tlast(d_tlast),
        .m_tready(d_tready), .ev_frame(ev_rframe), .ev_axi_err(ev_rerr), .busy(rd_busy));

    logic [255:0] dq_tdata;
    logic [31:0]  dq_tkeep;
    logic         dq_tvalid, dq_tlast, dq_tready;
    axis_fifo #(.DEPTH(TXDB), .DATA_WIDTH(256), .KEEP_ENABLE(1), .KEEP_WIDTH(32),
        .LAST_ENABLE(1), .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(0),
        .FRAME_FIFO(1)) u_txd (
        .clk, .rst,
        .s_axis_tdata(d_tdata), .s_axis_tkeep(d_tkeep), .s_axis_tvalid(d_tvalid),
        .s_axis_tready(d_tready), .s_axis_tlast(d_tlast), .s_axis_tid(8'b0),
        .s_axis_tdest(8'b0), .s_axis_tuser(1'b0),
        .m_axis_tdata(dq_tdata), .m_axis_tkeep(dq_tkeep), .m_axis_tvalid(dq_tvalid),
        .m_axis_tready(dq_tready), .m_axis_tlast(dq_tlast), .m_axis_tid(), .m_axis_tdest(),
        .m_axis_tuser(),
        .pause_req(1'b0), .pause_ack(),
        .status_depth(), .status_depth_commit(), .status_overflow(), .status_bad_frame(),
        .status_good_frame());

    // ---------------------------------------------------------------- регистры
    logic        rp_valid, rp_ready, rp_done, ev_gerr;
    req_t        rp_req;
    logic [7:0]  rp_st;
    logic [31:0] rp_idx, rp_nres;
    logic [1:0]  rp_resp;
    logic [$clog2(REGMAX/8)-1:0] res_raddr;
    logic [255:0] res_rdata;
    eth40_regx #(.REGMAX(REGMAX), .AW(20)) u_regx (
        .clk, .rst,
        .op_we(rx_we), .op_waddr(rx_waddr), .op_wdata(rx_wdata), .start(rx_start),
        .start_req(rx_req), .replay(rx_replay),
        .busy(rx_busy), .kvalid(rx_kvalid), .kseq(rx_kseq), .kip(rx_kip), .kport(rx_kport),
        .rp_valid, .rp_ready, .rp_done, .rp_req, .rp_st, .rp_idx, .rp_nres, .rp_resp,
        .res_raddr, .res_rdata,
        .m_awaddr(m_axil_awaddr), .m_awvalid(m_axil_awvalid), .m_awready(m_axil_awready),
        .m_wdata(m_axil_wdata), .m_wstrb(m_axil_wstrb), .m_wvalid(m_axil_wvalid),
        .m_wready(m_axil_wready), .m_bresp(m_axil_bresp), .m_bvalid(m_axil_bvalid),
        .m_bready(m_axil_bready), .m_araddr(m_axil_araddr), .m_arvalid(m_axil_arvalid),
        .m_arready(m_axil_arready), .m_rdata(m_axil_rdata), .m_rresp(m_axil_rresp),
        .m_rvalid(m_axil_rvalid), .m_rready(m_axil_rready), .ev_axi_err(ev_gerr));

    // ---------------------------------------------------------------- служебные ответы
    logic [255:0] c_tdata, cq_tdata;
    logic [31:0]  c_tkeep, cq_tkeep;
    logic         c_tvalid, c_tlast, c_tready, cq_tvalid, cq_tlast, cq_tready;
    eth40_ctl_tx #(.REGMAX(REGMAX)) u_ctl (
        .clk, .rst, .local_mac, .local_ip, .local_port,
        .er_valid, .er_ready, .er_req, .er_idx,
        .rp_valid, .rp_ready, .rp_done, .rp_req, .rp_st, .rp_idx, .rp_nres, .rp_resp,
        .res_raddr, .res_rdata,
        .ak_valid, .ak_ready, .ak_req, .ak_st,
        .m_tdata(c_tdata), .m_tkeep(c_tkeep), .m_tvalid(c_tvalid), .m_tlast(c_tlast),
        .m_tready(c_tready));

    axis_fifo #(.DEPTH(TXCB), .DATA_WIDTH(256), .KEEP_ENABLE(1), .KEEP_WIDTH(32),
        .LAST_ENABLE(1), .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(0),
        .FRAME_FIFO(1)) u_txc (
        .clk, .rst,
        .s_axis_tdata(c_tdata), .s_axis_tkeep(c_tkeep), .s_axis_tvalid(c_tvalid),
        .s_axis_tready(c_tready), .s_axis_tlast(c_tlast), .s_axis_tid(8'b0),
        .s_axis_tdest(8'b0), .s_axis_tuser(1'b0),
        .m_axis_tdata(cq_tdata), .m_axis_tkeep(cq_tkeep), .m_axis_tvalid(cq_tvalid),
        .m_axis_tready(cq_tready), .m_axis_tlast(cq_tlast), .m_axis_tid(), .m_axis_tdest(),
        .m_axis_tuser(),
        .pause_req(1'b0), .pause_ack(),
        .status_depth(), .status_depth_commit(), .status_overflow(), .status_bad_frame(),
        .status_good_frame());

    // ---------------------------------------------------------------- передача
    logic ev_arp_tx, ev_tx;
    eth40_tx_mux u_tx (
        .clk, .rst, .local_mac, .local_ip,
        .arp_req, .arp_mac, .arp_ip,
        .s0_tdata(cq_tdata), .s0_tkeep(cq_tkeep), .s0_tvalid(cq_tvalid), .s0_tlast(cq_tlast),
        .s0_tready(cq_tready),
        .s1_tdata(dq_tdata), .s1_tkeep(dq_tkeep), .s1_tvalid(dq_tvalid), .s1_tlast(dq_tlast),
        .s1_tready(dq_tready),
        .m_tdata(tx_tdata), .m_tkeep(tx_tkeep), .m_tvalid(tx_tvalid), .m_tlast(tx_tlast),
        .m_tuser(tx_tuser), .m_tready(tx_tready),
        .ev_arp_tx, .ev_tx);

    // ---------------------------------------------------------------- события и состояние
    logic [16:0] ev_c;
    assign ev_c = {ev_werr || ev_rerr || ev_gerr, ev_rframe, ev_tx, ev_bad, ev_busy, ev_dup,
                   ev_reg, ev_read, ev_write, ev_ctl, ev_arp_tx, arp_req, ev_ovf, ev_ignore,
                   ev_accept, ev_rxbad, ev_frame};
    always_ff @(posedge clk) begin
        ev     <= NEV'(ev_c);
        status <= {16'(rx_depth >> 5), 12'b0, rx_kvalid, rx_busy, rd_busy, wr_busy};
    end

endmodule
