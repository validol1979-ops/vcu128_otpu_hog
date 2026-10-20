// VCU128 top: openTPU (FeSens) with its memory channels on HBM2 and the host link over
// 40G Ethernet (QSFP1), plus JTAG-to-AXI to the registers. doc/design.md.
//
//   QDR4_CLK_100MHZ -> MMCM: core_clk 100 MHz (otpu_board, registers, dclk, APB), uclk 225 MHz
//   (otpu_mem_ch controller side, otpu_hbm_port, HBM AXI ports). DDR4_CLK_100MHZ -> HBM_REF_CLK.
//   QSFP1 -> eth40_qsfp1 (l_ethernet, 40GBASE-R4, tx_clk_out 156.25 MHz = eth_clk) ->
//   otpu_eth_bridge: DMA (x_*, eth_clk = xclk of otpu_mem_ch) and AXI-Lite (eth_clk; window
//   0x50000 eth40_regs there, the rest through axil_cdc into core_clk).
//   core_clk AXI-Lite: vcu128_axil_xbar, masters JTAG and 40G; slaves 0x00000 otpu_board s_ctl,
//   0x40000 vcu128_platform_regs, 0x60000 l_ethernet s_axi (eth40_mac_init in front).
//   otpu_bcu_sys (upstream, unchanged): otpu_board + otpu_mem_ch per channel.
//
// LEDs: 0 core heartbeat, 1 MMCMs locked, 2 HBM calibrated (both stacks), 3 40G rx_status,
//       4..6 otpu_board led[2:0], 7 HBM AXI error.
//
// Parameters: the target's (target/vcu128.toml through opentpu.target rtl_params; defaults are
// its values) and Hog's version parameters.

module otpu_vcu128_top #(
    // Hog version parameters (hog_tools/templates/top_version_params.v)
    parameter [31:0] TOP_VER    = 32'h00000000,
    parameter [31:0] TOP_SHA    = 32'h00000000,
    parameter [31:0] HOG_VER    = 32'h00000000,
    parameter [31:0] HOG_SHA    = 32'h00000000,
    parameter [31:0] CON_VER    = 32'h00000000,
    parameter [31:0] CON_SHA    = 32'h00000000,
    parameter [31:0] OTHERS_VER = 32'h00000000,
    parameter [31:0] OTHERS_SHA = 32'h00000000,
    parameter [31:0] IPS_VER    = 32'h00000000,
    parameter [31:0] IPS_SHA    = 32'h00000000,
    // target vcu128 (stage 1)
    parameter int S          = 1,
    parameter int D          = 128,
    parameter int MCOLS      = 4,
    parameter int ACT_ROWS   = 4,
    parameter int ACT_BLOCKS = 128,
    parameter int TMEM_WORDS = 1 << 16,
    parameter int IMEM_WORDS = 1 << 15,
    parameter int FIFO_DEPTH = 1024,
    parameter int LANES      = 8,
    parameter int WIN        = 16,
    parameter int RPB        = 64,
    parameter int WPB        = 1,
    parameter int TMEM_IMPL  = 0,
    parameter int MXU_IMPL   = 2,
    parameter int MXU_CL     = 16,
    parameter int VPU_CL     = 2,
    parameter int ULANES     = 8,
    parameter int TRACE_DEPTH = 16384,
    parameter int PQ_WIN     = 1024,
    parameter bit CHASH      = 1'b1,
    parameter bit DSTEP      = 1'b1,
    parameter int CORE_KHZ   = 100000,
    parameter int DDR_MTS    = 1800,
    parameter bit SEQ_WC     = 1'b0,
    parameter int PLATFORM   = 3,
    parameter logic [31:0] ARCH_HASH = 32'hff270e6e
)(
    input  wire        QDR4_CLK_100MHZ_P,
    input  wire        QDR4_CLK_100MHZ_N,
    input  wire        DDR4_CLK_100MHZ_P,
    input  wire        DDR4_CLK_100MHZ_N,
    input  wire        CPU_RESET,
    output wire [7:0]  GPIO_LED,

    input  wire        QSFP1_SI570_CLOCK_P,
    input  wire        QSFP1_SI570_CLOCK_N,
    input  wire [3:0]  QSFP1_RX_P,
    input  wire [3:0]  QSFP1_RX_N,
    output wire [3:0]  QSFP1_TX_P,
    output wire [3:0]  QSFP1_TX_N,
    output wire        QSFP1_RESETL_LS,
    output wire        QSFP1_LPMODE_LS,
    output wire        QSFP1_MODSKLL_LS,
    input  wire        QSFP1_MODPRSL_LS,
    input  wire        QSFP1_INTL_LS
);

    localparam int NC = 2 * S;

    // ------------------------------------------------------------------ clocks
    wire clk_in, clk_fb, core_mmcm, uclk_mmcm, core_clk, uclk, locked;

    IBUFDS u_ibuf_sys (.I(QDR4_CLK_100MHZ_P), .IB(QDR4_CLK_100MHZ_N), .O(clk_in));

    // VCO 900 MHz: core_clk = 900 / 9 = 100 MHz, uclk = 900 / 4 = 225 MHz
    MMCME4_BASE #(
        .CLKIN1_PERIOD    (10.0),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (9.0),
        .CLKOUT0_DIVIDE_F (9.0),
        .CLKOUT1_DIVIDE   (4)
    ) u_mmcm (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (core_mmcm),
        .CLKOUT1  (uclk_mmcm),
        .LOCKED   (locked),
        .RST      (CPU_RESET),
        .PWRDWN   (1'b0)
    );
    BUFG u_bufg_core (.I(core_mmcm), .O(core_clk));
    BUFG u_bufg_u    (.I(uclk_mmcm), .O(uclk));

    wire hbm_ref;
    IBUFDS u_ibuf_hbm (.I(DDR4_CLK_100MHZ_P), .IB(DDR4_CLK_100MHZ_N), .O(hbm_ref));

    // Resets: asserted asynchronously with the MMCM unlocked, released synchronously.
    (* ASYNC_REG = "TRUE" *) logic [3:0] core_rst_sync = 4'hF;
    always_ff @(posedge core_clk or negedge locked)
        if (!locked) core_rst_sync <= 4'hF;
        else         core_rst_sync <= {core_rst_sync[2:0], 1'b0};
    wire core_rst = core_rst_sync[3];

    (* ASYNC_REG = "TRUE" *) logic [3:0] u_rst_sync = 4'hF;
    always_ff @(posedge uclk or negedge locked)
        if (!locked) u_rst_sync <= 4'hF;
        else         u_rst_sync <= {u_rst_sync[2:0], 1'b0};
    wire u_rst_mmcm = u_rst_sync[3];

    // ------------------------------------------------------------------ HBM
    // Stage 1: channel j's two controller ports on AXI_(2j) and AXI_(2j+1).
    localparam int NP = 2 * NC;
    wire [1:0] hbm_calib;
    wire [1:0] hbm_cattrip;
    wire [6:0] hbm_temp0, hbm_temp1;

    // calibration done in uclk: the HBM ports' reset is held until both stacks are up
    (* ASYNC_REG = "TRUE" *) logic [1:0] calib_u1, calib_u2;
    always_ff @(posedge uclk) begin
        calib_u1 <= hbm_calib;
        calib_u2 <= calib_u1;
    end
    wire u_rst = u_rst_mmcm || !(&calib_u2);

    logic [NP-1:0][32:0]  h_awaddr, h_araddr;
    logic [NP-1:0][5:0]   h_awid, h_arid, h_bid, h_rid;
    logic [NP-1:0][3:0]   h_awlen, h_arlen;
    logic [NP-1:0][2:0]   h_awsize, h_arsize;
    logic [NP-1:0][1:0]   h_awburst, h_arburst, h_bresp, h_rresp;
    logic [NP-1:0]        h_awvalid, h_awready, h_wvalid, h_wready, h_wlast;
    logic [NP-1:0]        h_bvalid, h_bready, h_arvalid, h_arready;
    logic [NP-1:0]        h_rvalid, h_rready, h_rlast;
    logic [NP-1:0][255:0] h_wdata, h_rdata;
    logic [NP-1:0][31:0]  h_wstrb, h_wpar;

    // write data parity from otpu_hbm_port (per byte; the IP's parity check is off)

    hbm_0 u_hbm (
        .HBM_REF_CLK_0       (hbm_ref),
        .HBM_REF_CLK_1       (hbm_ref),
        .AXI_00_ACLK         (uclk), .AXI_00_ARESET_N (!u_rst_mmcm),
        .AXI_00_ARADDR       (h_araddr[0]), .AXI_00_ARBURST (h_arburst[0]), .AXI_00_ARID (h_arid[0]),
        .AXI_00_ARLEN        (h_arlen[0]),  .AXI_00_ARSIZE  (h_arsize[0]),  .AXI_00_ARVALID (h_arvalid[0]),
        .AXI_00_ARREADY      (h_arready[0]),
        .AXI_00_AWADDR       (h_awaddr[0]), .AXI_00_AWBURST (h_awburst[0]), .AXI_00_AWID (h_awid[0]),
        .AXI_00_AWLEN        (h_awlen[0]),  .AXI_00_AWSIZE  (h_awsize[0]),  .AXI_00_AWVALID (h_awvalid[0]),
        .AXI_00_AWREADY      (h_awready[0]),
        .AXI_00_WDATA        (h_wdata[0]),  .AXI_00_WLAST   (h_wlast[0]),   .AXI_00_WSTRB (h_wstrb[0]),
        .AXI_00_WDATA_PARITY (h_wpar[0]),   .AXI_00_WVALID  (h_wvalid[0]),  .AXI_00_WREADY (h_wready[0]),
        .AXI_00_RREADY       (h_rready[0]), .AXI_00_RDATA   (h_rdata[0]),   .AXI_00_RDATA_PARITY (),
        .AXI_00_RID          (h_rid[0]),    .AXI_00_RLAST   (h_rlast[0]),   .AXI_00_RRESP (h_rresp[0]),
        .AXI_00_RVALID       (h_rvalid[0]),
        .AXI_00_BREADY       (h_bready[0]), .AXI_00_BID     (h_bid[0]),     .AXI_00_BRESP (h_bresp[0]),
        .AXI_00_BVALID       (h_bvalid[0]),
        .AXI_01_ACLK         (uclk), .AXI_01_ARESET_N (!u_rst_mmcm),
        .AXI_01_ARADDR       (h_araddr[1]), .AXI_01_ARBURST (h_arburst[1]), .AXI_01_ARID (h_arid[1]),
        .AXI_01_ARLEN        (h_arlen[1]),  .AXI_01_ARSIZE  (h_arsize[1]),  .AXI_01_ARVALID (h_arvalid[1]),
        .AXI_01_ARREADY      (h_arready[1]),
        .AXI_01_AWADDR       (h_awaddr[1]), .AXI_01_AWBURST (h_awburst[1]), .AXI_01_AWID (h_awid[1]),
        .AXI_01_AWLEN        (h_awlen[1]),  .AXI_01_AWSIZE  (h_awsize[1]),  .AXI_01_AWVALID (h_awvalid[1]),
        .AXI_01_AWREADY      (h_awready[1]),
        .AXI_01_WDATA        (h_wdata[1]),  .AXI_01_WLAST   (h_wlast[1]),   .AXI_01_WSTRB (h_wstrb[1]),
        .AXI_01_WDATA_PARITY (h_wpar[1]),   .AXI_01_WVALID  (h_wvalid[1]),  .AXI_01_WREADY (h_wready[1]),
        .AXI_01_RREADY       (h_rready[1]), .AXI_01_RDATA   (h_rdata[1]),   .AXI_01_RDATA_PARITY (),
        .AXI_01_RID          (h_rid[1]),    .AXI_01_RLAST   (h_rlast[1]),   .AXI_01_RRESP (h_rresp[1]),
        .AXI_01_RVALID       (h_rvalid[1]),
        .AXI_01_BREADY       (h_bready[1]), .AXI_01_BID     (h_bid[1]),     .AXI_01_BRESP (h_bresp[1]),
        .AXI_01_BVALID       (h_bvalid[1]),
        .AXI_02_ACLK         (uclk), .AXI_02_ARESET_N (!u_rst_mmcm),
        .AXI_02_ARADDR       (h_araddr[2]), .AXI_02_ARBURST (h_arburst[2]), .AXI_02_ARID (h_arid[2]),
        .AXI_02_ARLEN        (h_arlen[2]),  .AXI_02_ARSIZE  (h_arsize[2]),  .AXI_02_ARVALID (h_arvalid[2]),
        .AXI_02_ARREADY      (h_arready[2]),
        .AXI_02_AWADDR       (h_awaddr[2]), .AXI_02_AWBURST (h_awburst[2]), .AXI_02_AWID (h_awid[2]),
        .AXI_02_AWLEN        (h_awlen[2]),  .AXI_02_AWSIZE  (h_awsize[2]),  .AXI_02_AWVALID (h_awvalid[2]),
        .AXI_02_AWREADY      (h_awready[2]),
        .AXI_02_WDATA        (h_wdata[2]),  .AXI_02_WLAST   (h_wlast[2]),   .AXI_02_WSTRB (h_wstrb[2]),
        .AXI_02_WDATA_PARITY (h_wpar[2]),   .AXI_02_WVALID  (h_wvalid[2]),  .AXI_02_WREADY (h_wready[2]),
        .AXI_02_RREADY       (h_rready[2]), .AXI_02_RDATA   (h_rdata[2]),   .AXI_02_RDATA_PARITY (),
        .AXI_02_RID          (h_rid[2]),    .AXI_02_RLAST   (h_rlast[2]),   .AXI_02_RRESP (h_rresp[2]),
        .AXI_02_RVALID       (h_rvalid[2]),
        .AXI_02_BREADY       (h_bready[2]), .AXI_02_BID     (h_bid[2]),     .AXI_02_BRESP (h_bresp[2]),
        .AXI_02_BVALID       (h_bvalid[2]),
        .AXI_03_ACLK         (uclk), .AXI_03_ARESET_N (!u_rst_mmcm),
        .AXI_03_ARADDR       (h_araddr[3]), .AXI_03_ARBURST (h_arburst[3]), .AXI_03_ARID (h_arid[3]),
        .AXI_03_ARLEN        (h_arlen[3]),  .AXI_03_ARSIZE  (h_arsize[3]),  .AXI_03_ARVALID (h_arvalid[3]),
        .AXI_03_ARREADY      (h_arready[3]),
        .AXI_03_AWADDR       (h_awaddr[3]), .AXI_03_AWBURST (h_awburst[3]), .AXI_03_AWID (h_awid[3]),
        .AXI_03_AWLEN        (h_awlen[3]),  .AXI_03_AWSIZE  (h_awsize[3]),  .AXI_03_AWVALID (h_awvalid[3]),
        .AXI_03_AWREADY      (h_awready[3]),
        .AXI_03_WDATA        (h_wdata[3]),  .AXI_03_WLAST   (h_wlast[3]),   .AXI_03_WSTRB (h_wstrb[3]),
        .AXI_03_WDATA_PARITY (h_wpar[3]),   .AXI_03_WVALID  (h_wvalid[3]),  .AXI_03_WREADY (h_wready[3]),
        .AXI_03_RREADY       (h_rready[3]), .AXI_03_RDATA   (h_rdata[3]),   .AXI_03_RDATA_PARITY (),
        .AXI_03_RID          (h_rid[3]),    .AXI_03_RLAST   (h_rlast[3]),   .AXI_03_RRESP (h_rresp[3]),
        .AXI_03_RVALID       (h_rvalid[3]),
        .AXI_03_BREADY       (h_bready[3]), .AXI_03_BID     (h_bid[3]),     .AXI_03_BRESP (h_bresp[3]),
        .AXI_03_BVALID       (h_bvalid[3]),
        .APB_0_PCLK          (core_clk), .APB_0_PRESET_N (!core_rst),
        .APB_0_PWDATA        (32'd0), .APB_0_PADDR (22'd0), .APB_0_PENABLE (1'b0),
        .APB_0_PSEL          (1'b0),  .APB_0_PWRITE (1'b0),
        .APB_0_PRDATA        (), .APB_0_PREADY (), .APB_0_PSLVERR (),
        .APB_1_PCLK          (core_clk), .APB_1_PRESET_N (!core_rst),
        .APB_1_PWDATA        (32'd0), .APB_1_PADDR (22'd0), .APB_1_PENABLE (1'b0),
        .APB_1_PSEL          (1'b0),  .APB_1_PWRITE (1'b0),
        .APB_1_PRDATA        (), .APB_1_PREADY (), .APB_1_PSLVERR (),
        .apb_complete_0      (hbm_calib[0]),
        .apb_complete_1      (hbm_calib[1]),
        .DRAM_0_STAT_CATTRIP (hbm_cattrip[0]),
        .DRAM_0_STAT_TEMP    (hbm_temp0),
        .DRAM_1_STAT_CATTRIP (hbm_cattrip[1]),
        .DRAM_1_STAT_TEMP    (hbm_temp1)
    );

    // ------------------------------------------------------------------ 40G
    wire        eth_clk;            // tx_clk_out_0, also rx_core_clk_0
    wire        eth_sys_reset, eth_rx_dp_reset, eth_core_reset;
    wire        eth_user_tx_reset, eth_user_rx_reset;
    wire        eth_rx_status_async;
    wire [3:0]  gt_powergood, eth_block_lock;
    wire        eth_aligned, eth_hi_ber;
    wire        eth_rx_status;
    wire [15:0] eth_recover_count;
    wire        eth_full_reset_req, eth_rx_reset_req, eth_auto_recover, gt_rxlpmen;
    wire [4:0]  gt_txdiffctrl, gt_txprecursor, gt_txpostcursor;
    wire [6:0]  gt_txmaincursor;

    wire [255:0] rx_tdata, tx_tdata;
    wire [31:0]  rx_tkeep, tx_tkeep;
    wire         rx_tvalid, rx_tlast, rx_tuser, tx_tvalid, tx_tlast, tx_tuser, tx_tready;

    // l_ethernet register port (core_clk)
    wire [15:0] lm_awaddr, lm_araddr;
    wire [31:0] lm_wdata, lm_rdata;
    wire [3:0]  lm_wstrb;
    wire [1:0]  lm_bresp, lm_rresp;
    wire        lm_awvalid, lm_awready, lm_wvalid, lm_wready, lm_bvalid, lm_bready;
    wire        lm_arvalid, lm_arready, lm_rvalid, lm_rready;

    eth40_mgmt u_eth_mgmt (
        .clk             (core_clk),
        .rst             (core_rst),
        .req_full_reset  (eth_full_reset_req),
        .req_rx_reset    (eth_rx_reset_req),
        .auto_recover    (eth_auto_recover),
        .rx_status_async (eth_rx_status_async),
        .sys_reset       (eth_sys_reset),
        .rx_dp_reset     (eth_rx_dp_reset),
        .rx_status       (eth_rx_status),
        .recover_count   (eth_recover_count)
    );

    // MAC/PCS resets: assert even with the GT clock stopped, release on its edges
    // (rfsoc_8x8_40g_compat_hog eth40_core_reset.v)
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .RST_ACTIVE_HIGH(1)) u_eth_core_rst (
        .src_arst (eth_sys_reset), .dest_clk (eth_clk), .dest_arst (eth_core_reset));

    eth40_qsfp1 u_eth40 (
        .gt_rxp_in_0 (QSFP1_RX_P[0]), .gt_rxn_in_0 (QSFP1_RX_N[0]),
        .gt_txp_out_0 (QSFP1_TX_P[0]), .gt_txn_out_0 (QSFP1_TX_N[0]),
        .gt_rxp_in_1 (QSFP1_RX_P[1]), .gt_rxn_in_1 (QSFP1_RX_N[1]),
        .gt_txp_out_1 (QSFP1_TX_P[1]), .gt_txn_out_1 (QSFP1_TX_N[1]),
        .gt_rxp_in_2 (QSFP1_RX_P[2]), .gt_rxn_in_2 (QSFP1_RX_N[2]),
        .gt_txp_out_2 (QSFP1_TX_P[2]), .gt_txn_out_2 (QSFP1_TX_N[2]),
        .gt_rxp_in_3 (QSFP1_RX_P[3]), .gt_rxn_in_3 (QSFP1_RX_N[3]),
        .gt_txp_out_3 (QSFP1_TX_P[3]), .gt_txn_out_3 (QSFP1_TX_N[3]),
        .gt_refclk_p (QSFP1_SI570_CLOCK_P), .gt_refclk_n (QSFP1_SI570_CLOCK_N),
        .gt_refclk_out (),
        .txoutclksel_in_0 ({4{3'b101}}),
        .rxoutclksel_in_0 ({4{3'b101}}),
        .gt_txdiffctrl_0   ({4{gt_txdiffctrl}}),
        .gt_txprecursor_0  ({4{gt_txprecursor}}),
        .gt_txpostcursor_0 ({4{gt_txpostcursor}}),
        .gt_txmaincursor_0 ({4{gt_txmaincursor}}),
        .gt_rxlpmen_0      ({4{gt_rxlpmen}}),
        .gt_txinhibit_0 (4'b0), .gt_txpolarity_0 (4'b0), .gt_rxpolarity_0 (4'b0),
        .gt_txprbssel_0 (16'b0), .gt_rxprbssel_0 (16'b0), .gt_txprbsforceerr_0 (4'b0),
        .gt_rxprbscntreset_0 (4'b0), .gt_rxprbserr_0 (),
        .gt_eyescanreset_0 (4'b0), .gt_eyescantrigger_0 (4'b0), .gt_eyescandataerror_0 (),
        .gt_rxbufreset_0 (4'b0), .gt_rxbufstatus_0 (), .gt_txbufstatus_0 (),
        .gt_rxcdrhold_0 (4'b0), .gt_rxdfeagchold_0 (4'b0), .gt_rxdfelpmreset_0 (4'b0),
        .gt_rxpcsreset_0 (4'b0), .gt_rxpmareset_0 (4'b0), .gt_txpcsreset_0 (4'b0),
        .gt_txpmareset_0 (4'b0), .gt_rxrate_0 (12'b0), .gt_pcsrsvdin_0 (64'b0),
        .gt_rxcommadeten_0 (4'b0), .gt_rxslide_in_0 (4'b0), .gt_dmonitorout_0 (),
        .gt_rxlatclk_0 (4'b0), .gt_txlatclk_0 (4'b0), .gt_rxstartofseq_0 (),
        .rxrecclkout_0 (),
        .gt_common_drpclk (core_clk), .gt_common_drpdo (), .gt_common_drprdy (),
        .gt_common_drpen (1'b0), .gt_common_drpwe (1'b0), .gt_common_drpaddr (10'b0),
        .gt_common_drpdi (16'b0),
        .gt_ch_drpclk_0 (core_clk), .gt_ch_drpdo_0 (), .gt_ch_drprdy_0 (),
        .gt_ch_drpen_0 (1'b0), .gt_ch_drpwe_0 (1'b0), .gt_ch_drpaddr_0 (10'b0), .gt_ch_drpdi_0 (16'b0),
        .gt_ch_drpclk_1 (core_clk), .gt_ch_drpdo_1 (), .gt_ch_drprdy_1 (),
        .gt_ch_drpen_1 (1'b0), .gt_ch_drpwe_1 (1'b0), .gt_ch_drpaddr_1 (10'b0), .gt_ch_drpdi_1 (16'b0),
        .gt_ch_drpclk_2 (core_clk), .gt_ch_drpdo_2 (), .gt_ch_drprdy_2 (),
        .gt_ch_drpen_2 (1'b0), .gt_ch_drpwe_2 (1'b0), .gt_ch_drpaddr_2 (10'b0), .gt_ch_drpdi_2 (16'b0),
        .gt_ch_drpclk_3 (core_clk), .gt_ch_drpdo_3 (), .gt_ch_drprdy_3 (),
        .gt_ch_drpen_3 (1'b0), .gt_ch_drpwe_3 (1'b0), .gt_ch_drpaddr_3 (10'b0), .gt_ch_drpdi_3 (16'b0),
        .sys_reset (eth_sys_reset),
        .gtwiz_reset_tx_datapath_0 (eth_sys_reset),
        .gtwiz_reset_rx_datapath_0 (eth_sys_reset || eth_rx_dp_reset),
        .dclk (core_clk),
        .tx_clk_out_0 (eth_clk), .rx_clk_out_0 (), .rx_core_clk_0 (eth_clk),
        .gtpowergood_out_0 (gt_powergood),
        .s_axi_aclk_0 (core_clk), .s_axi_aresetn_0 (!core_rst), .pm_tick_0 (1'b0),
        .s_axi_awaddr_0 ({16'd0, lm_awaddr}), .s_axi_awvalid_0 (lm_awvalid), .s_axi_awready_0 (lm_awready),
        .s_axi_wdata_0 (lm_wdata), .s_axi_wstrb_0 (lm_wstrb), .s_axi_wvalid_0 (lm_wvalid),
        .s_axi_wready_0 (lm_wready), .s_axi_bresp_0 (lm_bresp), .s_axi_bvalid_0 (lm_bvalid),
        .s_axi_bready_0 (lm_bready),
        .s_axi_araddr_0 ({16'd0, lm_araddr}), .s_axi_arvalid_0 (lm_arvalid), .s_axi_arready_0 (lm_arready),
        .s_axi_rdata_0 (lm_rdata), .s_axi_rresp_0 (lm_rresp), .s_axi_rvalid_0 (lm_rvalid),
        .s_axi_rready_0 (lm_rready),
        .rx_reset_0 (eth_core_reset), .user_rx_reset_0 (eth_user_rx_reset),
        .rx_axis_tvalid_0 (rx_tvalid), .rx_axis_tdata_0 (rx_tdata), .rx_axis_tuser_0 (rx_tuser),
        .rx_axis_tkeep_0 (rx_tkeep), .rx_axis_tlast_0 (rx_tlast), .rx_preambleout_0 (),
        .tx_reset_0 (eth_core_reset), .user_tx_reset_0 (eth_user_tx_reset), .tx_unfout_0 (),
        .tx_axis_tready_0 (tx_tready), .tx_axis_tvalid_0 (tx_tvalid), .tx_axis_tdata_0 (tx_tdata),
        .tx_axis_tuser_0 (tx_tuser), .tx_axis_tkeep_0 (tx_tkeep), .tx_axis_tlast_0 (tx_tlast),
        .tx_preamblein_0 (56'b0),
        .ctl_tx_send_idle_0 (1'b0), .ctl_tx_send_lfi_0 (1'b0), .ctl_tx_send_rfi_0 (1'b0),
        .stat_rx_status_0 (eth_rx_status_async), .stat_rx_block_lock_0 (eth_block_lock),
        .stat_rx_aligned_0 (eth_aligned), .stat_rx_hi_ber_0 (eth_hi_ber),
        .user_reg0_0 ()
    );

    // bridge reset: the MAC's user resets (eth_clk)
    wire eth_rst = eth_user_tx_reset || eth_user_rx_reset;

    // ------------------------------------------------------------------ bridge
    wire [47:0] local_mac;
    wire [31:0] local_ip;
    wire [15:0] local_port;
    wire [16:0] bridge_ev;
    wire [31:0] bridge_status;

    logic [NC-1:0]        x_awvalid, x_awready, x_wvalid, x_wready, x_wlast, x_bvalid, x_bready;
    logic [NC-1:0]        x_arvalid, x_arready, x_rvalid, x_rready, x_rlast;
    logic [NC-1:0][30:0]  x_awaddr, x_araddr;
    logic [NC-1:0][7:0]   x_awlen, x_arlen;
    logic [NC-1:0][127:0] x_wdata, x_rdata;
    logic [NC-1:0][15:0]  x_wstrb;
    logic [NC-1:0][1:0]   x_bresp, x_rresp;

    // eth_clk AXI-Lite from the bridge
    wire [19:0] e_awaddr, e_araddr;
    wire [31:0] e_wdata, e_rdata;
    wire [3:0]  e_wstrb;
    wire [1:0]  e_bresp, e_rresp;
    wire        e_awvalid, e_awready, e_wvalid, e_wready, e_bvalid, e_bready;
    wire        e_arvalid, e_arready, e_rvalid, e_rready;

    otpu_eth_bridge #(.NC(NC)) u_bridge (
        .clk (eth_clk), .rst (eth_rst),
        .local_mac (local_mac), .local_ip (local_ip), .local_port (local_port),
        .rx_tdata (rx_tdata), .rx_tkeep (rx_tkeep), .rx_tvalid (rx_tvalid),
        .rx_tlast (rx_tlast), .rx_tuser (rx_tuser),
        .tx_tdata (tx_tdata), .tx_tkeep (tx_tkeep), .tx_tvalid (tx_tvalid),
        .tx_tlast (tx_tlast), .tx_tuser (tx_tuser), .tx_tready (tx_tready),
        .x_awvalid, .x_awready, .x_awaddr, .x_awlen, .x_wvalid, .x_wready, .x_wdata, .x_wstrb,
        .x_wlast, .x_bvalid, .x_bready, .x_bresp, .x_arvalid, .x_arready, .x_araddr, .x_arlen,
        .x_rvalid, .x_rready, .x_rdata, .x_rresp, .x_rlast,
        .m_axil_awaddr (e_awaddr), .m_axil_awvalid (e_awvalid), .m_axil_awready (e_awready),
        .m_axil_wdata (e_wdata), .m_axil_wstrb (e_wstrb), .m_axil_wvalid (e_wvalid),
        .m_axil_wready (e_wready), .m_axil_bresp (e_bresp), .m_axil_bvalid (e_bvalid),
        .m_axil_bready (e_bready), .m_axil_araddr (e_araddr), .m_axil_arvalid (e_arvalid),
        .m_axil_arready (e_arready), .m_axil_rdata (e_rdata), .m_axil_rresp (e_rresp),
        .m_axil_rvalid (e_rvalid), .m_axil_rready (e_rready),
        .ev (bridge_ev), .status (bridge_status)
    );

    // Window 0x50000 -> eth40_regs (eth_clk); the bridge keeps one transaction in flight
    // with a stable address, so the decode may be combinational.
    wire w_loc = e_awaddr[19:16] == 4'h5;
    wire r_loc = e_araddr[19:16] == 4'h5;

    wire [31:0] er_rdata;
    wire [1:0]  er_bresp, er_rresp;
    wire        er_awready, er_wready, er_bvalid, er_arready, er_rvalid;
    wire [19:0] c_awaddr, c_araddr;
    wire [31:0] c_rdata;
    wire [1:0]  c_bresp, c_rresp;
    wire        c_awready, c_wready, c_bvalid, c_arready, c_rvalid;

    // link status into eth_clk for eth40_regs
    (* ASYNC_REG = "TRUE" *) logic [31:0] link_s1, link_s2;
    always_ff @(posedge eth_clk) begin
        link_s1 <= {22'd0, eth_hi_ber, eth_aligned, gt_powergood, eth_block_lock};
        link_s2 <= link_s1;
    end

    eth40_regs #(.NEV(17), .PARAMS(32'(NC))) u_eth_regs (
        .clk (eth_clk), .rst (eth_rst),
        .s_awaddr (e_awaddr[7:0]), .s_awvalid (e_awvalid && w_loc), .s_awready (er_awready),
        .s_wdata (e_wdata), .s_wstrb (e_wstrb), .s_wvalid (e_wvalid && w_loc), .s_wready (er_wready),
        .s_bresp (er_bresp), .s_bvalid (er_bvalid), .s_bready (e_bready),
        .s_araddr (e_araddr[7:0]), .s_arvalid (e_arvalid && r_loc), .s_arready (er_arready),
        .s_rdata (er_rdata), .s_rresp (er_rresp), .s_rvalid (er_rvalid), .s_rready (e_rready),
        .local_mac (local_mac), .local_ip (local_ip), .local_port (local_port),
        .link_stat (link_s2), .bridge_stat (bridge_status), .ev (bridge_ev)
    );

    wire [19:0] k_awaddr, k_araddr;
    wire [31:0] k_wdata, k_rdata;
    wire [3:0]  k_wstrb;
    wire [1:0]  k_bresp, k_rresp;
    wire        k_awvalid, k_awready, k_wvalid, k_wready, k_bvalid, k_bready;
    wire        k_arvalid, k_arready, k_rvalid, k_rready;

    axil_cdc #(.DATA_WIDTH(32), .ADDR_WIDTH(20)) u_axil_cdc (
        .s_clk (eth_clk), .s_rst (eth_rst),
        .s_axil_awaddr (e_awaddr), .s_axil_awprot (3'b0), .s_axil_awvalid (e_awvalid && !w_loc),
        .s_axil_awready (c_awready), .s_axil_wdata (e_wdata), .s_axil_wstrb (e_wstrb),
        .s_axil_wvalid (e_wvalid && !w_loc), .s_axil_wready (c_wready),
        .s_axil_bresp (c_bresp), .s_axil_bvalid (c_bvalid), .s_axil_bready (e_bready),
        .s_axil_araddr (e_araddr), .s_axil_arprot (3'b0), .s_axil_arvalid (e_arvalid && !r_loc),
        .s_axil_arready (c_arready), .s_axil_rdata (c_rdata), .s_axil_rresp (c_rresp),
        .s_axil_rvalid (c_rvalid), .s_axil_rready (e_rready),
        .m_clk (core_clk), .m_rst (core_rst),
        .m_axil_awaddr (k_awaddr), .m_axil_awprot (), .m_axil_awvalid (k_awvalid),
        .m_axil_awready (k_awready), .m_axil_wdata (k_wdata), .m_axil_wstrb (k_wstrb),
        .m_axil_wvalid (k_wvalid), .m_axil_wready (k_wready), .m_axil_bresp (k_bresp),
        .m_axil_bvalid (k_bvalid), .m_axil_bready (k_bready),
        .m_axil_araddr (k_araddr), .m_axil_arprot (), .m_axil_arvalid (k_arvalid),
        .m_axil_arready (k_arready), .m_axil_rdata (k_rdata), .m_axil_rresp (k_rresp),
        .m_axil_rvalid (k_rvalid), .m_axil_rready (k_rready)
    );

    assign e_awready = w_loc ? er_awready : c_awready;
    assign e_wready  = w_loc ? er_wready  : c_wready;
    assign e_bvalid  = er_bvalid || c_bvalid;
    assign e_bresp   = er_bvalid ? er_bresp : c_bresp;
    assign e_arready = r_loc ? er_arready : c_arready;
    assign e_rvalid  = er_rvalid || c_rvalid;
    assign e_rdata   = er_rvalid ? er_rdata : c_rdata;
    assign e_rresp   = er_rvalid ? er_rresp : c_rresp;

    // ------------------------------------------------------------------ JTAG
    wire [31:0] j_awaddr, j_araddr, j_wdata, j_rdata;
    wire [2:0]  j_awprot, j_arprot;
    wire [3:0]  j_wstrb;
    wire [1:0]  j_bresp, j_rresp;
    wire        j_awvalid, j_awready, j_wvalid, j_wready, j_bvalid, j_bready;
    wire        j_arvalid, j_arready, j_rvalid, j_rready;

    jtag_axi_0 u_jtag_axi (
        .aclk (core_clk), .aresetn (!core_rst),
        .m_axi_awaddr (j_awaddr), .m_axi_awprot (j_awprot), .m_axi_awvalid (j_awvalid),
        .m_axi_awready (j_awready), .m_axi_wdata (j_wdata), .m_axi_wstrb (j_wstrb),
        .m_axi_wvalid (j_wvalid), .m_axi_wready (j_wready), .m_axi_bresp (j_bresp),
        .m_axi_bvalid (j_bvalid), .m_axi_bready (j_bready), .m_axi_araddr (j_araddr),
        .m_axi_arprot (j_arprot), .m_axi_arvalid (j_arvalid), .m_axi_arready (j_arready),
        .m_axi_rdata (j_rdata), .m_axi_rresp (j_rresp), .m_axi_rvalid (j_rvalid),
        .m_axi_rready (j_rready)
    );

    // ------------------------------------------------------------------ core_clk bus
    localparam int NS = 3;
    logic [19:0] x_s_awaddr [2], x_s_araddr [2];
    logic [31:0] x_s_wdata [2], x_s_rdata [2];
    logic [3:0]  x_s_wstrb [2];
    logic [1:0]  x_s_bresp [2], x_s_rresp [2];
    logic        x_s_awvalid [2], x_s_awready [2], x_s_wvalid [2], x_s_wready [2];
    logic        x_s_bvalid [2], x_s_bready [2], x_s_arvalid [2], x_s_arready [2];
    logic        x_s_rvalid [2], x_s_rready [2];

    logic [19:0] y_awaddr [NS], y_araddr [NS];
    logic [31:0] y_wdata [NS], y_rdata [NS];
    logic [3:0]  y_wstrb [NS];
    logic [1:0]  y_bresp [NS], y_rresp [NS];
    logic        y_awvalid [NS], y_awready [NS], y_wvalid [NS], y_wready [NS];
    logic        y_bvalid [NS], y_bready [NS], y_arvalid [NS], y_arready [NS];
    logic        y_rvalid [NS], y_rready [NS];

    always_comb begin
        x_s_awaddr[0] = j_awaddr[19:0]; x_s_awaddr[1] = k_awaddr;
        x_s_awvalid[0] = j_awvalid;     x_s_awvalid[1] = k_awvalid;
        x_s_wdata[0] = j_wdata;         x_s_wdata[1] = k_wdata;
        x_s_wstrb[0] = j_wstrb;         x_s_wstrb[1] = k_wstrb;
        x_s_wvalid[0] = j_wvalid;       x_s_wvalid[1] = k_wvalid;
        x_s_bready[0] = j_bready;       x_s_bready[1] = k_bready;
        x_s_araddr[0] = j_araddr[19:0]; x_s_araddr[1] = k_araddr;
        x_s_arvalid[0] = j_arvalid;     x_s_arvalid[1] = k_arvalid;
        x_s_rready[0] = j_rready;       x_s_rready[1] = k_rready;
    end
    assign j_awready = x_s_awready[0]; assign k_awready = x_s_awready[1];
    assign j_wready  = x_s_wready[0];  assign k_wready  = x_s_wready[1];
    assign j_bresp   = x_s_bresp[0];   assign k_bresp   = x_s_bresp[1];
    assign j_bvalid  = x_s_bvalid[0];  assign k_bvalid  = x_s_bvalid[1];
    assign j_arready = x_s_arready[0]; assign k_arready = x_s_arready[1];
    assign j_rdata   = x_s_rdata[0];   assign k_rdata   = x_s_rdata[1];
    assign j_rresp   = x_s_rresp[0];   assign k_rresp   = x_s_rresp[1];
    assign j_rvalid  = x_s_rvalid[0];  assign k_rvalid  = x_s_rvalid[1];

    vcu128_axil_xbar #(
        .AW   (20),
        .NS   (NS),
        .BASE ({20'h60000, 20'h40000, 20'h00000}),
        .MASK ({20'h0FFFF, 20'h0FFFF, 20'h0FFFF})
    ) u_xbar (
        .clk (core_clk), .rst (core_rst),
        .s_awaddr (x_s_awaddr), .s_awvalid (x_s_awvalid), .s_awready (x_s_awready),
        .s_wdata (x_s_wdata), .s_wstrb (x_s_wstrb), .s_wvalid (x_s_wvalid), .s_wready (x_s_wready),
        .s_bresp (x_s_bresp), .s_bvalid (x_s_bvalid), .s_bready (x_s_bready),
        .s_araddr (x_s_araddr), .s_arvalid (x_s_arvalid), .s_arready (x_s_arready),
        .s_rdata (x_s_rdata), .s_rresp (x_s_rresp), .s_rvalid (x_s_rvalid), .s_rready (x_s_rready),
        .m_awaddr (y_awaddr), .m_awvalid (y_awvalid), .m_awready (y_awready),
        .m_wdata (y_wdata), .m_wstrb (y_wstrb), .m_wvalid (y_wvalid), .m_wready (y_wready),
        .m_bresp (y_bresp), .m_bvalid (y_bvalid), .m_bready (y_bready),
        .m_araddr (y_araddr), .m_arvalid (y_arvalid), .m_arready (y_arready),
        .m_rdata (y_rdata), .m_rresp (y_rresp), .m_rvalid (y_rvalid), .m_rready (y_rready)
    );

    // slave 1: platform registers
    wire [7:0] hbm_err;
    vcu128_platform_regs u_plat (
        .clk (core_clk), .rst (core_rst),
        .s_axil_awaddr (y_awaddr[1]), .s_axil_awvalid (y_awvalid[1]), .s_axil_awready (y_awready[1]),
        .s_axil_wdata (y_wdata[1]), .s_axil_wstrb (y_wstrb[1]), .s_axil_wvalid (y_wvalid[1]),
        .s_axil_wready (y_wready[1]), .s_axil_bresp (y_bresp[1]), .s_axil_bvalid (y_bvalid[1]),
        .s_axil_bready (y_bready[1]),
        .s_axil_araddr (y_araddr[1]), .s_axil_arvalid (y_arvalid[1]), .s_axil_arready (y_arready[1]),
        .s_axil_rdata (y_rdata[1]), .s_axil_rresp (y_rresp[1]), .s_axil_rvalid (y_rvalid[1]),
        .s_axil_rready (y_rready[1]),
        .core_locked (locked), .uclk_locked (locked),
        .hbm_calib (hbm_calib), .hbm_cattrip (hbm_cattrip), .hbm_temp0 (hbm_temp0),
        .hbm_temp1 (hbm_temp1), .hbm_err (hbm_err),
        .qsfp_present_n (QSFP1_MODPRSL_LS), .qsfp_int_n (QSFP1_INTL_LS),
        .eth_aligned (eth_aligned), .eth_hi_ber (eth_hi_ber), .gt_powergood (gt_powergood),
        .eth_block_lock (eth_block_lock),
        .eth_rx_status_s (eth_rx_status), .eth_recover_count_s (eth_recover_count),
        .eth_full_reset (eth_full_reset_req), .eth_rx_reset (eth_rx_reset_req),
        .eth_auto_recover (eth_auto_recover), .gt_rxlpmen (gt_rxlpmen),
        .gt_txdiffctrl (gt_txdiffctrl), .gt_txprecursor (gt_txprecursor),
        .gt_txpostcursor (gt_txpostcursor), .gt_txmaincursor (gt_txmaincursor)
    );

    // slave 2: l_ethernet registers, configuration writes after each 40G reset
    logic eth_sys_reset_q;
    always_ff @(posedge core_clk) eth_sys_reset_q <= eth_sys_reset;
    wire mac_init_start = eth_sys_reset_q && !eth_sys_reset;

    eth40_mac_init #(
        .INIT_N    (3),
        .INIT_ADDR ({16'h0018, 16'h0014, 16'h000C}),
        .INIT_DATA ({32'h2580_0040, 32'h0000_0033, 32'h0000_3003}),
        .DELAY     (10000)
    ) u_mac_init (
        .clk (core_clk), .rst (core_rst), .start (mac_init_start), .busy (), .done (),
        .s_awaddr (y_awaddr[2][15:0]), .s_awvalid (y_awvalid[2]), .s_awready (y_awready[2]),
        .s_wdata (y_wdata[2]), .s_wstrb (y_wstrb[2]), .s_wvalid (y_wvalid[2]), .s_wready (y_wready[2]),
        .s_bresp (y_bresp[2]), .s_bvalid (y_bvalid[2]), .s_bready (y_bready[2]),
        .s_araddr (y_araddr[2][15:0]), .s_arvalid (y_arvalid[2]), .s_arready (y_arready[2]),
        .s_rdata (y_rdata[2]), .s_rresp (y_rresp[2]), .s_rvalid (y_rvalid[2]), .s_rready (y_rready[2]),
        .m_awaddr (lm_awaddr), .m_awvalid (lm_awvalid), .m_awready (lm_awready),
        .m_wdata (lm_wdata), .m_wstrb (lm_wstrb), .m_wvalid (lm_wvalid), .m_wready (lm_wready),
        .m_bresp (lm_bresp), .m_bvalid (lm_bvalid), .m_bready (lm_bready),
        .m_araddr (lm_araddr), .m_arvalid (lm_arvalid), .m_arready (lm_arready),
        .m_rdata (lm_rdata), .m_rresp (lm_rresp), .m_rvalid (lm_rvalid), .m_rready (lm_rready)
    );

    // ------------------------------------------------------------------ accelerator
    wire [2:0] board_led;
    logic [NC-1:0][1:0]        c_cmd_valid, c_cmd_ready, c_cmd_we;
    logic [NC-1:0][1:0][24:0]  c_cmd_addr;
    logic [NC-1:0][1:0]        c_wdata_valid, c_wdata_ready;
    logic [NC-1:0][1:0][511:0] c_wdata_data;
    logic [NC-1:0][1:0][63:0]  c_wdata_we;
    logic [NC-1:0][1:0]        c_rdata_valid;
    logic [NC-1:0][1:0][511:0] c_rdata_data;

    otpu_bcu_sys #(
        .S (S), .D (D), .MCOLS (MCOLS), .ACT_ROWS (ACT_ROWS), .ACT_BLOCKS (ACT_BLOCKS),
        .TMEM_WORDS (TMEM_WORDS), .IMEM_WORDS (IMEM_WORDS), .FIFO_DEPTH (FIFO_DEPTH),
        .LANES (LANES), .WIN (WIN), .RPB (RPB), .WPB (WPB), .TMEM_IMPL (TMEM_IMPL),
        .MXU_IMPL (MXU_IMPL), .MXU_CL (MXU_CL), .VPU_CL (VPU_CL), .ULANES (ULANES),
        .TRACE_DEPTH (TRACE_DEPTH), .PQ_WIN (PQ_WIN), .CHASH (CHASH), .DSTEP (DSTEP),
        .CORE_KHZ (CORE_KHZ), .BUILD_ID (TOP_SHA), .DDR_MTS (DDR_MTS), .SEQ_WC (SEQ_WC),
        .PLATFORM (PLATFORM), .ARCH_HASH (ARCH_HASH), .SLL (4'b0000)
    ) u_sys (
        .clk (core_clk), .clk_f (core_clk), .rst (core_rst), .ctl_mrst (core_rst),
        .xclk (eth_clk), .xrst (eth_rst),
        .calib ({NC{&hbm_calib}}), .ded ('0), .temp (12'd0),
        .led (board_led), .i2c_lo (), .i2c_pin (5'h1F),
        .s_ctl_awaddr (y_awaddr[0][11:0]), .s_ctl_awvalid (y_awvalid[0]), .s_ctl_awready (y_awready[0]),
        .s_ctl_wdata (y_wdata[0]), .s_ctl_wstrb (y_wstrb[0]), .s_ctl_wvalid (y_wvalid[0]),
        .s_ctl_wready (y_wready[0]), .s_ctl_bresp (y_bresp[0]), .s_ctl_bvalid (y_bvalid[0]),
        .s_ctl_bready (y_bready[0]),
        .s_ctl_araddr (y_araddr[0][11:0]), .s_ctl_arvalid (y_arvalid[0]), .s_ctl_arready (y_arready[0]),
        .s_ctl_rdata (y_rdata[0]), .s_ctl_rresp (y_rresp[0]), .s_ctl_rvalid (y_rvalid[0]),
        .s_ctl_rready (y_rready[0]),
        .x_awvalid, .x_awready, .x_awaddr, .x_awlen, .x_wvalid, .x_wready, .x_wdata, .x_wstrb,
        .x_wlast, .x_bvalid, .x_bready, .x_bresp, .x_arvalid, .x_arready, .x_araddr, .x_arlen,
        .x_rvalid, .x_rready, .x_rdata, .x_rresp, .x_rlast,
        .uclk ({NC{uclk}}), .urst ({NC{u_rst}}),
        .c_cmd_valid, .c_cmd_ready, .c_cmd_we, .c_cmd_addr,
        .c_wdata_valid, .c_wdata_ready, .c_wdata_data, .c_wdata_we,
        .c_rdata_valid, .c_rdata_data
    );

    // HBM adapters: channel j, ports 2j / 2j + 1, CH_BASE j x 2 GiB
    for (genvar j = 0; j < NC; j++) begin : g_hbm
        logic err, perr;
        otpu_hbm_port #(.CH_BASE(33'(j) << 31)) u_port (
            .uclk (uclk), .urst (u_rst),
            .c_cmd_valid (c_cmd_valid[j]), .c_cmd_ready (c_cmd_ready[j]), .c_cmd_we (c_cmd_we[j]),
            .c_cmd_addr (c_cmd_addr[j]),
            .c_wdata_valid (c_wdata_valid[j]), .c_wdata_ready (c_wdata_ready[j]),
            .c_wdata_data (c_wdata_data[j]), .c_wdata_we (c_wdata_we[j]),
            .c_rdata_valid (c_rdata_valid[j]), .c_rdata_data (c_rdata_data[j]),
            .m_awaddr (h_awaddr[2*j +: 2]), .m_awid (h_awid[2*j +: 2]), .m_awlen (h_awlen[2*j +: 2]),
            .m_awsize (h_awsize[2*j +: 2]), .m_awburst (h_awburst[2*j +: 2]),
            .m_awvalid (h_awvalid[2*j +: 2]), .m_awready (h_awready[2*j +: 2]),
            .m_wdata (h_wdata[2*j +: 2]), .m_wstrb (h_wstrb[2*j +: 2]), .m_wlast (h_wlast[2*j +: 2]),
            .m_wvalid (h_wvalid[2*j +: 2]), .m_wready (h_wready[2*j +: 2]),
            .m_wid (), .m_wdata_parity (h_wpar[2*j +: 2]),
            .m_bid (h_bid[2*j +: 2]), .m_bresp (h_bresp[2*j +: 2]), .m_bvalid (h_bvalid[2*j +: 2]),
            .m_bready (h_bready[2*j +: 2]),
            .m_araddr (h_araddr[2*j +: 2]), .m_arid (h_arid[2*j +: 2]), .m_arlen (h_arlen[2*j +: 2]),
            .m_arsize (h_arsize[2*j +: 2]), .m_arburst (h_arburst[2*j +: 2]),
            .m_arvalid (h_arvalid[2*j +: 2]), .m_arready (h_arready[2*j +: 2]),
            .m_rid (h_rid[2*j +: 2]), .m_rdata (h_rdata[2*j +: 2]), .m_rresp (h_rresp[2*j +: 2]),
            .m_rlast (h_rlast[2*j +: 2]), .m_rvalid (h_rvalid[2*j +: 2]), .m_rready (h_rready[2*j +: 2]),
            .st_rcmd (), .st_wcmd (), .st_rout (), .st_wout (), .st_dep (), .st_busy (),
            .st_err_cnt (), .st_err (err), .st_perr (perr)
        );
        assign hbm_err[j] = err || perr;
    end
    for (genvar j = NC; j < 8; j++) begin : g_noerr
        assign hbm_err[j] = 1'b0;
    end

    // ------------------------------------------------------------------ board I/O
    assign QSFP1_RESETL_LS  = 1'b1;
    assign QSFP1_LPMODE_LS  = 1'b0;
    assign QSFP1_MODSKLL_LS = 1'b0;

    logic [25:0] hb = '0;
    always_ff @(posedge core_clk) hb <= hb + 1'b1;

    // HBM error and 40G status into core_clk for the LEDs
    (* ASYNC_REG = "TRUE" *) logic [1:0] led_s1, led_s2;
    always_ff @(posedge core_clk) begin
        led_s1 <= {|hbm_err, &hbm_calib};
        led_s2 <= led_s1;
    end

    assign GPIO_LED = {led_s2[1], board_led, eth_rx_status, led_s2[0], locked, hb[25]};

endmodule
