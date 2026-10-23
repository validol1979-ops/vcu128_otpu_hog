// VCU128 top: openTPU (FeSens) with its memory channels on HBM2 and the host link over
// 40G Ethernet (QSFP1), plus JTAG-to-AXI to the registers. doc/design.md.
//
//   QDR4_CLK_100MHZ -> MMCM: core_clk 200 MHz (otpu_board, registers, l_ethernet s_axi),
//   uclk 225 MHz (otpu_mem_ch controller side, otpu_hbm_port, HBM AXI ports), clk100 100 MHz
//   (HBM APB, l_ethernet dclk / DRP: the IPs are configured for 100 MHz, USER_APB_PCLK_0 and
//   GT_DRP_CLK). DDR4_CLK_100MHZ -> HBM_REF_CLK.
//   QSFP1 -> eth40_qsfp1 (l_ethernet, 40GBASE-R4, tx_clk_out 156.25 MHz = eth_clk) ->
//   otpu_eth_bridge: DMA (x_*, eth_clk = xclk of otpu_mem_ch) and AXI-Lite (eth_clk; window
//   0x50000 eth40_regs there, the rest through axil_cdc into core_clk).
//   core_clk AXI-Lite: vcu128_axil_xbar, masters JTAG and 40G; slaves 0x00000 otpu_board s_ctl,
//   0x40000 vcu128_platform_regs (with the thermal monitor), 0x60000 l_ethernet s_axi
//   (eth40_mac_init in front); s_ctl through vcu128_ctl_guard (thermal hold).
//   vcu128_sysmon: SYSMONE4 of every SLR, DRP in clk100.
//   otpu_bcu_sys (upstream + patch 0001: ARD): otpu_board + otpu_mem_ch per channel; each channel's
//   otpu_hbm_port drives four HBM AXI ports (NS = 2 per controller port, vcu128_hbm). S = 2:
//   four channels, all 16 ports; placement by SLR in constr/vcu128_floorplan.tcl (slice 0 and the
//   shell with HBM in SLR0, slice 1 in SLR1).
//
// LEDs: 0 core heartbeat, 1 MMCMs locked, 2 HBM calibrated (both stacks), 3 40G rx_status,
//       4..6 otpu_board led[2:0], 7 HBM AXI error.
//
// Parameters: the target's (target/vcu128.toml through opentpu.target rtl_params; defaults are
// its values) and Hog's version parameters.

module otpu_vcu128_top #(
    // Hog version parameters (Hog's top version parameters)
    // GLOBAL_SHA: the newest commit of every project list (sources, constraints, IP; no Vitis
    // application here, so software never moves it) -- the board's BUILD_ID. TOP_SHA misses a
    // constraints-only change (6817049 reported Top's d3cadc3).
    parameter [31:0] GLOBAL_SHA = 32'h00000000,
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
    // target vcu128 (stage 2: two slices)
    parameter int S          = 2,           // Top/otpu; S = 4: Top/otpu_s4 [generics]
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
    parameter int CORE_KHZ   = 200000,
    parameter int DDR_MTS    = 1800,
    parameter bit SEQ_WC     = 1'b0,
    parameter int PLATFORM   = 3,
    parameter logic [31:0] ARCH_HASH = 32'hc6166c02  // target/vcu128.toml; S = 4: f83fc219
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
    // otpu_bcu_sys SLL: channel j's native port crosses an SLR (two otpu_native_reg, flip-flop to
    // flip-flop); SLL2 (patch 0004): it crosses two (a third, u_mid, in the SLR between).
    // constr/vcu128_floorplan.tcl. HBM and every otpu_mem_ch sit in SLR0.
    //   S = 2: slice 0 in SLR0, slice 1 in SLR1 (its channels 2, 3 cross).
    //   S = 4 (layout L2): slice 0 in SLR0, slices 1, 2 in SLR1 (channels 2..5 cross), slice 3 in
    //          SLR2 (channels 6, 7 cross two SLRs). L1 (slices 0, 1 in SLR1, 2, 3 in SLR2; 8'hFF /
    //          8'hF0) congested SLR1's long lines (build B, 22.10).
    localparam logic [2*S-1:0] SLL  = (2 * S)'((S == 4) ? 8'hFC : (S == 2) ? 8'h0C : 8'h00);
    localparam logic [2*S-1:0] SLL2 = (2 * S)'((S == 4) ? 8'hC0 : 8'h00);
    // HBM per channel: 2 GiB (8 pseudo-channels) at S <= 2, 1 GiB (4, one mini-switch) at S = 4
    // (eight channels in 8 GB); otpu_board reports it (CFG_DRAM, patch 0004), DRAM_BYTES 2 x that
    localparam int CH_LOG2 = (S == 4) ? 30 : 31;
    localparam int PCB     = CH_LOG2 - 28;      // otpu_hbm_port: log2 pseudo-channels a channel
    // register-slice stages between the 40G bridge and the channels (vcu128_xreg)
    localparam int XREG = 2;

    // ------------------------------------------------------------------ clocks
    wire clk_in, clk_fb, core_mmcm, uclk_mmcm, clk100_mmcm, core_clk, uclk, clk100, locked;

    IBUFDS u_ibuf_sys (.I(QDR4_CLK_100MHZ_P), .IB(QDR4_CLK_100MHZ_N), .O(clk_in));

    // VCO 900 MHz: core_clk = 900 / 4.5 = 200 MHz (CORE_KHZ; CLKOUT0, the only output with a
    // fractional divider), uclk = 900 / 4 = 225 MHz, clk100 = 900 / 9 = 100 MHz. 900 MHz is the
    // only VCO in range (800..1600) that is a multiple of both 225 and 100.
    MMCME4_BASE #(
        .CLKIN1_PERIOD    (10.0),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (9.0),
        .CLKOUT0_DIVIDE_F (4.5),
        .CLKOUT1_DIVIDE   (4),
        .CLKOUT2_DIVIDE   (9)
    ) u_mmcm (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (core_mmcm),
        .CLKOUT1  (uclk_mmcm),
        .CLKOUT2  (clk100_mmcm),
        .LOCKED   (locked),
        .RST      (CPU_RESET),
        .PWRDWN   (1'b0)
    );
    BUFG u_bufg_core (.I(core_mmcm), .O(core_clk));
    BUFG u_bufg_u    (.I(uclk_mmcm), .O(uclk));
    BUFG u_bufg_100  (.I(clk100_mmcm), .O(clk100));

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

    (* ASYNC_REG = "TRUE" *) logic [3:0] r100_rst_sync = 4'hF;
    always_ff @(posedge clk100 or negedge locked)
        if (!locked) r100_rst_sync <= 4'hF;
        else         r100_rst_sync <= {r100_rst_sync[2:0], 1'b0};
    wire rst100 = r100_rst_sync[3];          // HBM APB

    // ------------------------------------------------------------------ HBM
    // Channel j: otpu_hbm_port with NS = 2 AXI ports per controller port, its port a = p + 2k
    // (controller port p, sub-port k) on the IP's AXI_(hp(j, a)) (vcu128_hbm: h_*[i] = AXI_i).
    // Sub-port k only addresses pseudo-channels of its own mini-switch (no lateral path):
    //   2 GiB (S <= 2): pseudo-channels 8j .. 8j + 7, sub-port k 8j + 4k .. + 3: AXI 8j + 4k + p;
    //   1 GiB (S = 4):  pseudo-channels 4j .. 4j + 3 = mini-switch j, all four: AXI 4j + a.
    // AXI ports no channel uses are tied off below.
    localparam int HNS = 2;             // otpu_hbm_port NS
    localparam int HRD = 32;            // otpu_hbm_port RD: read slots per AXI port (64: full
                                        //   stream at 200 MHz up to 200 uclk, sim/hbm)
    // otpu_mem_ch read credits per channel (otpu_bcu_sys ARD, patch 0001): upstream's 64 caps the
    // read stream at 7.7 GB/s at an HBM latency of 100 uclk cycles; 256 holds 12.8 GB/s (200 MHz
    // core) to 150 cycles with HRD 64, 12.5 at 80 with HRD 32 (sim/hbm test_system_ard)
    localparam int ARD = 256;
    localparam int NP  = 32;            // vcu128_hbm's AXI ports
    function automatic int hp(input int j, input int a);
        return (PCB == 2) ? 4 * j + a : 8 * j + 4 * (a / 2) + a % 2;
    endfunction
    function automatic logic [NP-1:0] hp_used();
        logic [NP-1:0] u = '0;
        for (int j = 0; j < NC; j++)
            for (int a = 0; a < 2 * HNS; a++) u[hp(j, a)] = 1'b1;
        return u;
    endfunction
    localparam logic [NP-1:0] HP_USED = hp_used();
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

    vcu128_hbm u_hbm (
        .hbm_ref (hbm_ref), .aclk (uclk), .aresetn (!u_rst_mmcm), .pclk (clk100), .presetn (!rst100),
        .h_awaddr, .h_awburst, .h_awid, .h_awlen, .h_awsize, .h_awvalid, .h_awready,
        .h_wdata, .h_wlast, .h_wstrb, .h_wpar, .h_wvalid, .h_wready,
        .h_bready, .h_bid, .h_bresp, .h_bvalid,
        .h_araddr, .h_arburst, .h_arid, .h_arlen, .h_arsize, .h_arvalid, .h_arready,
        .h_rready, .h_rdata, .h_rid, .h_rlast, .h_rresp, .h_rvalid,
        .calib (hbm_calib), .cattrip (hbm_cattrip), .temp0 (hbm_temp0), .temp1 (hbm_temp1)
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

    eth40_mgmt #(.CLK_HZ (CORE_KHZ * 1000)) u_eth_mgmt (
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
        .gt_common_drpclk (clk100), .gt_common_drpdo (), .gt_common_drprdy (),
        .gt_common_drpen (1'b0), .gt_common_drpwe (1'b0), .gt_common_drpaddr (10'b0),
        .gt_common_drpdi (16'b0),
        .gt_ch_drpclk_0 (clk100), .gt_ch_drpdo_0 (), .gt_ch_drprdy_0 (),
        .gt_ch_drpen_0 (1'b0), .gt_ch_drpwe_0 (1'b0), .gt_ch_drpaddr_0 (10'b0), .gt_ch_drpdi_0 (16'b0),
        .gt_ch_drpclk_1 (clk100), .gt_ch_drpdo_1 (), .gt_ch_drprdy_1 (),
        .gt_ch_drpen_1 (1'b0), .gt_ch_drpwe_1 (1'b0), .gt_ch_drpaddr_1 (10'b0), .gt_ch_drpdi_1 (16'b0),
        .gt_ch_drpclk_2 (clk100), .gt_ch_drpdo_2 (), .gt_ch_drprdy_2 (),
        .gt_ch_drpen_2 (1'b0), .gt_ch_drpwe_2 (1'b0), .gt_ch_drpaddr_2 (10'b0), .gt_ch_drpdi_2 (16'b0),
        .gt_ch_drpclk_3 (clk100), .gt_ch_drpdo_3 (), .gt_ch_drprdy_3 (),
        .gt_ch_drpen_3 (1'b0), .gt_ch_drpwe_3 (1'b0), .gt_ch_drpaddr_3 (10'b0), .gt_ch_drpdi_3 (16'b0),
        .sys_reset (eth_sys_reset),
        .gtwiz_reset_tx_datapath_0 (eth_sys_reset),
        .gtwiz_reset_rx_datapath_0 (eth_sys_reset || eth_rx_dp_reset),
        .dclk (clk100),
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

    // x_*: otpu_bcu_sys's DMA slaves (otpu_mem_ch xclk sides); xb_*: the bridge's masters;
    // vcu128_xreg between them (register slices, eth_clk)
    logic [NC-1:0]        x_awvalid, x_awready, x_wvalid, x_wready, x_wlast, x_bvalid, x_bready;
    logic [NC-1:0]        x_arvalid, x_arready, x_rvalid, x_rready, x_rlast;
    logic [NC-1:0][30:0]  x_awaddr, x_araddr;
    logic [NC-1:0][7:0]   x_awlen, x_arlen;
    logic [NC-1:0][127:0] x_wdata, x_rdata;
    logic [NC-1:0][15:0]  x_wstrb;
    logic [NC-1:0][1:0]   x_bresp, x_rresp;
    logic [NC-1:0]        xb_awvalid, xb_awready, xb_wvalid, xb_wready, xb_wlast, xb_bvalid, xb_bready;
    logic [NC-1:0]        xb_arvalid, xb_arready, xb_rvalid, xb_rready, xb_rlast;
    logic [NC-1:0][30:0]  xb_awaddr, xb_araddr;
    logic [NC-1:0][7:0]   xb_awlen, xb_arlen;
    logic [NC-1:0][127:0] xb_wdata, xb_rdata;
    logic [NC-1:0][15:0]  xb_wstrb;
    logic [NC-1:0][1:0]   xb_bresp, xb_rresp;

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
        .x_awvalid (xb_awvalid), .x_awready (xb_awready), .x_awaddr (xb_awaddr),
        .x_awlen (xb_awlen), .x_wvalid (xb_wvalid), .x_wready (xb_wready), .x_wdata (xb_wdata),
        .x_wstrb (xb_wstrb), .x_wlast (xb_wlast), .x_bvalid (xb_bvalid), .x_bready (xb_bready),
        .x_bresp (xb_bresp), .x_arvalid (xb_arvalid), .x_arready (xb_arready),
        .x_araddr (xb_araddr), .x_arlen (xb_arlen), .x_rvalid (xb_rvalid), .x_rready (xb_rready),
        .x_rdata (xb_rdata), .x_rresp (xb_rresp), .x_rlast (xb_rlast),
        .m_axil_awaddr (e_awaddr), .m_axil_awvalid (e_awvalid), .m_axil_awready (e_awready),
        .m_axil_wdata (e_wdata), .m_axil_wstrb (e_wstrb), .m_axil_wvalid (e_wvalid),
        .m_axil_wready (e_wready), .m_axil_bresp (e_bresp), .m_axil_bvalid (e_bvalid),
        .m_axil_bready (e_bready), .m_axil_araddr (e_araddr), .m_axil_arvalid (e_arvalid),
        .m_axil_arready (e_arready), .m_axil_rdata (e_rdata), .m_axil_rresp (e_rresp),
        .m_axil_rvalid (e_rvalid), .m_axil_rready (e_rready),
        .ev (bridge_ev), .status (bridge_status)
    );

    // The DMA masters through two register-slice stages into otpu_bcu_sys (S = 2: the channels'
    // otpu_mem_ch sit along HBM, from AXI port 00 to 19; the 312.5 MHz eth_clk paths did not
    // close with the bridge on them directly, 88f6cb5)
    vcu128_xreg #(.NC (NC), .STAGES (XREG)) u_xreg (
        .clk (eth_clk), .rst (eth_rst),
        .s_awvalid (xb_awvalid), .s_awready (xb_awready), .s_awaddr (xb_awaddr), .s_awlen (xb_awlen),
        .s_wvalid (xb_wvalid), .s_wready (xb_wready), .s_wdata (xb_wdata), .s_wstrb (xb_wstrb),
        .s_wlast (xb_wlast), .s_bvalid (xb_bvalid), .s_bready (xb_bready), .s_bresp (xb_bresp),
        .s_arvalid (xb_arvalid), .s_arready (xb_arready), .s_araddr (xb_araddr), .s_arlen (xb_arlen),
        .s_rvalid (xb_rvalid), .s_rready (xb_rready), .s_rdata (xb_rdata), .s_rresp (xb_rresp),
        .s_rlast (xb_rlast),
        .m_awvalid (x_awvalid), .m_awready (x_awready), .m_awaddr (x_awaddr), .m_awlen (x_awlen),
        .m_wvalid (x_wvalid), .m_wready (x_wready), .m_wdata (x_wdata), .m_wstrb (x_wstrb),
        .m_wlast (x_wlast), .m_bvalid (x_bvalid), .m_bready (x_bready), .m_bresp (x_bresp),
        .m_arvalid (x_arvalid), .m_arready (x_arready), .m_araddr (x_araddr), .m_arlen (x_arlen),
        .m_rvalid (x_rvalid), .m_rready (x_rready), .m_rdata (x_rdata), .m_rresp (x_rresp),
        .m_rlast (x_rlast)
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
    // (link_s3: a plain stage after the synchronizer, placed with eth40_regs, away from the GTs)
    (* ASYNC_REG = "TRUE" *) logic [31:0] link_s1, link_s2;
    logic [31:0] link_s3;
    always_ff @(posedge eth_clk) begin
        link_s1 <= {22'd0, eth_hi_ber, eth_aligned, gt_powergood, eth_block_lock};
        link_s2 <= link_s1;
        link_s3 <= link_s2;
    end

    eth40_regs #(.NEV(17), .PARAMS(32'(NC))) u_eth_regs (
        .clk (eth_clk), .rst (eth_rst),
        .s_awaddr (e_awaddr[7:0]), .s_awvalid (e_awvalid && w_loc), .s_awready (er_awready),
        .s_wdata (e_wdata), .s_wstrb (e_wstrb), .s_wvalid (e_wvalid && w_loc), .s_wready (er_wready),
        .s_bresp (er_bresp), .s_bvalid (er_bvalid), .s_bready (e_bready),
        .s_araddr (e_araddr[7:0]), .s_arvalid (e_arvalid && r_loc), .s_arready (er_arready),
        .s_rdata (er_rdata), .s_rresp (er_rresp), .s_rvalid (er_rvalid), .s_rready (e_rready),
        .local_mac (local_mac), .local_ip (local_ip), .local_port (local_port),
        .link_stat (link_s3), .bridge_stat (bridge_status), .ev (bridge_ev)
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

    // die temperature and supplies of every SLR (thermal/vcu128_sysmon, DRP in clk100)
    logic [2:0][3:0][15:0] sm_snap;
    logic [2:0]            sm_valid, sm_err, sm_ot;
    logic                  sm_tog;
    vcu128_sysmon #(.NSLR (3), .DCLK_KHZ (100000)) u_sysmon (
        .clk (clk100), .rst (rst100), .snap (sm_snap), .snap_valid (sm_valid),
        .snap_err (sm_err), .snap_tog (sm_tog), .ot (sm_ot)
    );
    wire        th_hold, th_abort;
    wire [11:0] th_temp_code;
    wire [15:0] th_n_abort;

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
        .gt_txpostcursor (gt_txpostcursor), .gt_txmaincursor (gt_txmaincursor),
        .sm_snap (sm_snap), .sm_valid (sm_valid), .sm_err (sm_err), .sm_tog (sm_tog),
        .sm_ot (sm_ot), .th_n_abort_s (th_n_abort),
        .th_hold (th_hold), .th_abort (th_abort), .th_temp_code (th_temp_code)
    );

    // slave 2: l_ethernet registers, configuration writes after each 40G reset
    logic eth_sys_reset_q;
    always_ff @(posedge core_clk) eth_sys_reset_q <= eth_sys_reset;
    wire mac_init_start = eth_sys_reset_q && !eth_sys_reset;

    eth40_mac_init #(
        .INIT_N    (3),
        .INIT_ADDR ({16'h0018, 16'h0014, 16'h000C}),
        .INIT_DATA ({32'h2580_0040, 32'h0000_0033, 32'h0000_3003}),
        .DELAY     (CORE_KHZ / 10)    // 100 us
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
    // slave 0 through vcu128_ctl_guard: the thermal hold's CTRL = 0 (doc/design.md
    // "Температура и контроль"); while th_hold the calibration input is low (no RUN, no LOAD)
    logic [19:0] g_awaddr, g_araddr;
    logic [31:0] g_wdata, g_rdata;
    logic [3:0]  g_wstrb;
    logic [1:0]  g_bresp, g_rresp;
    logic        g_awvalid, g_awready, g_wvalid, g_wready, g_bvalid, g_bready;
    logic        g_arvalid, g_arready, g_rvalid, g_rready;
    vcu128_ctl_guard u_ctl_guard (
        .clk (core_clk), .rst (core_rst), .stop (th_abort), .n_abort (th_n_abort),
        .s_awaddr (y_awaddr[0]), .s_awvalid (y_awvalid[0]), .s_awready (y_awready[0]),
        .s_wdata (y_wdata[0]), .s_wstrb (y_wstrb[0]), .s_wvalid (y_wvalid[0]), .s_wready (y_wready[0]),
        .s_bresp (y_bresp[0]), .s_bvalid (y_bvalid[0]), .s_bready (y_bready[0]),
        .s_araddr (y_araddr[0]), .s_arvalid (y_arvalid[0]), .s_arready (y_arready[0]),
        .s_rdata (y_rdata[0]), .s_rresp (y_rresp[0]), .s_rvalid (y_rvalid[0]), .s_rready (y_rready[0]),
        .m_awaddr (g_awaddr), .m_awvalid (g_awvalid), .m_awready (g_awready),
        .m_wdata (g_wdata), .m_wstrb (g_wstrb), .m_wvalid (g_wvalid), .m_wready (g_wready),
        .m_bresp (g_bresp), .m_bvalid (g_bvalid), .m_bready (g_bready),
        .m_araddr (g_araddr), .m_arvalid (g_arvalid), .m_arready (g_arready),
        .m_rdata (g_rdata), .m_rresp (g_rresp), .m_rvalid (g_rvalid), .m_rready (g_rready)
    );

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
        .CORE_KHZ (CORE_KHZ), .BUILD_ID (GLOBAL_SHA), .DDR_MTS (DDR_MTS), .SEQ_WC (SEQ_WC),
        .PLATFORM (PLATFORM), .ARCH_HASH (ARCH_HASH), .SLL (SLL), .SLL2 (SLL2), .CH_LOG2 (CH_LOG2),
        .ARD (ARD)
    ) u_sys (
        .clk (core_clk), .clk_f (core_clk), .rst (core_rst), .ctl_mrst (core_rst),
        .xclk (eth_clk), .xrst (eth_rst),
        .calib ({NC{&hbm_calib && !th_hold}}), .ded ('0), .temp (th_temp_code),
        .led (board_led), .i2c_lo (), .i2c_pin (5'h1F),
        .s_ctl_awaddr (g_awaddr[11:0]), .s_ctl_awvalid (g_awvalid), .s_ctl_awready (g_awready),
        .s_ctl_wdata (g_wdata), .s_ctl_wstrb (g_wstrb), .s_ctl_wvalid (g_wvalid),
        .s_ctl_wready (g_wready), .s_ctl_bresp (g_bresp), .s_ctl_bvalid (g_bvalid),
        .s_ctl_bready (g_bready),
        .s_ctl_araddr (g_araddr[11:0]), .s_ctl_arvalid (g_arvalid), .s_ctl_arready (g_arready),
        .s_ctl_rdata (g_rdata), .s_ctl_rresp (g_rresp), .s_ctl_rvalid (g_rvalid),
        .s_ctl_rready (g_rready),
        .x_awvalid, .x_awready, .x_awaddr, .x_awlen, .x_wvalid, .x_wready, .x_wdata, .x_wstrb,
        .x_wlast, .x_bvalid, .x_bready, .x_bresp, .x_arvalid, .x_arready, .x_araddr, .x_arlen,
        .x_rvalid, .x_rready, .x_rdata, .x_rresp, .x_rlast,
        .uclk ({NC{uclk}}), .urst ({NC{u_rst}}),
        .c_cmd_valid, .c_cmd_ready, .c_cmd_we, .c_cmd_addr,
        .c_wdata_valid, .c_wdata_ready, .c_wdata_data, .c_wdata_we,
        .c_rdata_valid, .c_rdata_data
    );

    // HBM adapters: channel j at CH_BASE j x 2^CH_LOG2, its ports a on AXI_(hp(j, a))
    for (genvar j = 0; j < NC; j++) begin : g_hbm
        logic err, perr;
        logic [3:0][32:0]  awaddr, araddr;
        logic [3:0][5:0]   awid, arid, bid, rid;
        logic [3:0][3:0]   awlen, arlen;
        logic [3:0][2:0]   awsize, arsize;
        logic [3:0][1:0]   awburst, arburst, bresp, rresp;
        logic [3:0]        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
        logic [3:0]        arvalid, arready, rvalid, rready, rlast;
        logic [3:0][255:0] wdata, rdata;
        logic [3:0][31:0]  wstrb, wpar;
        otpu_hbm_port #(.CH_BASE(33'(j) << CH_LOG2), .PCB(PCB), .NS(HNS), .RD(HRD)) u_port (
            .uclk (uclk), .urst (u_rst),
            .c_cmd_valid (c_cmd_valid[j]), .c_cmd_ready (c_cmd_ready[j]), .c_cmd_we (c_cmd_we[j]),
            .c_cmd_addr (c_cmd_addr[j]),
            .c_wdata_valid (c_wdata_valid[j]), .c_wdata_ready (c_wdata_ready[j]),
            .c_wdata_data (c_wdata_data[j]), .c_wdata_we (c_wdata_we[j]),
            .c_rdata_valid (c_rdata_valid[j]), .c_rdata_data (c_rdata_data[j]),
            .m_awaddr (awaddr), .m_awid (awid), .m_awlen (awlen), .m_awsize (awsize),
            .m_awburst (awburst), .m_awvalid (awvalid), .m_awready (awready),
            .m_wdata (wdata), .m_wstrb (wstrb), .m_wlast (wlast), .m_wvalid (wvalid),
            .m_wready (wready), .m_wid (), .m_wdata_parity (wpar),
            .m_bid (bid), .m_bresp (bresp), .m_bvalid (bvalid), .m_bready (bready),
            .m_araddr (araddr), .m_arid (arid), .m_arlen (arlen), .m_arsize (arsize),
            .m_arburst (arburst), .m_arvalid (arvalid), .m_arready (arready),
            .m_rid (rid), .m_rdata (rdata), .m_rresp (rresp), .m_rlast (rlast),
            .m_rvalid (rvalid), .m_rready (rready),
            .st_rcmd (), .st_wcmd (), .st_rout (), .st_wout (), .st_dep (), .st_busy (),
            .st_err_cnt (), .st_err (err), .st_perr (perr)
        );
        for (genvar a = 0; a < 4; a++) begin : g_ax
            localparam int H = hp(j, a);
            assign h_awaddr[H] = awaddr[a];   assign h_awid[H] = awid[a];
            assign h_awlen[H] = awlen[a];     assign h_awsize[H] = awsize[a];
            assign h_awburst[H] = awburst[a]; assign h_awvalid[H] = awvalid[a];
            assign awready[a] = h_awready[H];
            assign h_wdata[H] = wdata[a];     assign h_wstrb[H] = wstrb[a];
            assign h_wlast[H] = wlast[a];     assign h_wvalid[H] = wvalid[a];
            assign h_wpar[H] = wpar[a];       assign wready[a] = h_wready[H];
            assign bid[a] = h_bid[H];         assign bresp[a] = h_bresp[H];
            assign bvalid[a] = h_bvalid[H];   assign h_bready[H] = bready[a];
            assign h_araddr[H] = araddr[a];   assign h_arid[H] = arid[a];
            assign h_arlen[H] = arlen[a];     assign h_arsize[H] = arsize[a];
            assign h_arburst[H] = arburst[a]; assign h_arvalid[H] = arvalid[a];
            assign arready[a] = h_arready[H];
            assign rid[a] = h_rid[H];         assign rdata[a] = h_rdata[H];
            assign rresp[a] = h_rresp[H];     assign rlast[a] = h_rlast[H];
            assign rvalid[a] = h_rvalid[H];   assign h_rready[H] = rready[a];
        end
        assign hbm_err[j] = err || perr;
    end
    for (genvar j = NC; j < 8; j++) begin : g_noerr
        assign hbm_err[j] = 1'b0;
    end
    for (genvar p = 0; p < NP; p++) begin : g_hbm_off
      if (!HP_USED[p]) begin : g_off
        assign h_awaddr[p] = '0;  assign h_awid[p] = '0;   assign h_awlen[p] = '0;
        assign h_awsize[p] = '0;  assign h_awburst[p] = '0; assign h_awvalid[p] = 1'b0;
        assign h_wdata[p] = '0;   assign h_wstrb[p] = '0;   assign h_wlast[p] = 1'b0;
        assign h_wvalid[p] = 1'b0; assign h_wpar[p] = '0;   assign h_bready[p] = 1'b1;
        assign h_araddr[p] = '0;  assign h_arid[p] = '0;   assign h_arlen[p] = '0;
        assign h_arsize[p] = '0;  assign h_arburst[p] = '0; assign h_arvalid[p] = 1'b0;
        assign h_rready[p] = 1'b1;
      end
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
