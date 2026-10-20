// VCU128 platform registers (window 0x40000, doc/design.md): HBM, 40G link, QSFP1.
//
// AXI4-Lite slave in clk (core_clk), one transaction at a time (vcu128_axil_xbar).
// Status inputs are asynchronous unless named *_s (already in clk): each bit goes
// through a two-flop synchronizer (quasi-static values; counters are sampled values
// and may be read mid-change only in their low bits' gray-free sense — they are
// for monitoring, not for exact accounting).
//
//   0x00 ID          R   0x56313238 ("V128")
//   0x04 STATUS      R   [0] core MMCM locked, [2:1] HBM stacks calibrated (apb_complete),
//                        [4:3] HBM CATTRIP, [5] QSFP1 module present, [6] QSFP1 interrupt,
//                        [7] 40G rx_status, [8] 40G rx aligned, [9] 40G hi_ber,
//                        [13:10] GT powergood, [17:14] block lock, [18] uclk MMCM locked
//   0x08 HBM_TEMP    R   [6:0] stack 0, [14:8] stack 1 (degrees C, IP's DRAM_x_STAT_TEMP)
//   0x0C HBM_ERR     R   per channel j bit j: an AXI error response (sticky, otpu_hbm_port)
//   0x10 ETH_CTRL    R/W [0] W1: 40G full reset, [1] W1: RX datapath reset,
//                        [2] auto RX recovery (reset value 1), [3] RX LPM (0 DFE)
//   0x14 GT_TX       R/W [4:0] TXDIFFCTRL, [12:8] TXPRECURSOR, [20:16] TXPOSTCURSOR,
//                        [30:24] TXMAINCURSOR; one setting for all lanes (boot 24/0/4/80)
//   0x18 ETH_RECOVER R   [15:0] automatic/requested RX recoveries
//   0x1C SCRATCH     R/W

module vcu128_platform_regs (
    input  logic        clk,
    input  logic        rst,

    input  logic [19:0] s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [19:0] s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    // status (asynchronous)
    input  logic        core_locked,
    input  logic        uclk_locked,
    input  logic [1:0]  hbm_calib,
    input  logic [1:0]  hbm_cattrip,
    input  logic [6:0]  hbm_temp0,
    input  logic [6:0]  hbm_temp1,
    input  logic [7:0]  hbm_err,
    input  logic        qsfp_present_n,
    input  logic        qsfp_int_n,
    input  logic        eth_aligned,
    input  logic        eth_hi_ber,
    input  logic [3:0]  gt_powergood,
    input  logic [3:0]  eth_block_lock,
    // status (clk)
    input  logic        eth_rx_status_s,
    input  logic [15:0] eth_recover_count_s,

    // control (clk)
    output logic        eth_full_reset,     // one-cycle pulses
    output logic        eth_rx_reset,
    output logic        eth_auto_recover,
    output logic        gt_rxlpmen,
    output logic [4:0]  gt_txdiffctrl,
    output logic [4:0]  gt_txprecursor,
    output logic [4:0]  gt_txpostcursor,
    output logic [6:0]  gt_txmaincursor
);

    localparam logic [31:0] ID = 32'h56313238;   // "V128"

    localparam int NS = 1 + 1 + 2 + 2 + 7 + 7 + 8 + 1 + 1 + 1 + 1 + 4 + 4;
    (* ASYNC_REG = "TRUE" *) logic [NS-1:0] s1, s2;
    always_ff @(posedge clk) begin
        s1 <= {core_locked, uclk_locked, hbm_calib, hbm_cattrip, hbm_temp0, hbm_temp1, hbm_err,
               qsfp_present_n, qsfp_int_n, eth_aligned, eth_hi_ber, gt_powergood, eth_block_lock};
        s2 <= s1;
    end
    logic        c_core_locked, c_uclk_locked, c_qsfp_present_n, c_qsfp_int_n, c_aligned, c_hi_ber;
    logic [1:0]  c_calib, c_cattrip;
    logic [6:0]  c_temp0, c_temp1;
    logic [7:0]  c_err;
    logic [3:0]  c_pg, c_lock;
    assign {c_core_locked, c_uclk_locked, c_calib, c_cattrip, c_temp0, c_temp1, c_err,
            c_qsfp_present_n, c_qsfp_int_n, c_aligned, c_hi_ber, c_pg, c_lock} = s2;

    logic [31:0] scratch;

    // Write channel: AW and W together
    assign s_axil_awready = !s_axil_bvalid && s_axil_awvalid && s_axil_wvalid;
    assign s_axil_wready  = s_axil_awready;

    always_ff @(posedge clk) begin
        eth_full_reset <= 1'b0;
        eth_rx_reset   <= 1'b0;
        if (rst) begin
            s_axil_bvalid    <= 1'b0;
            eth_auto_recover <= 1'b1;
            gt_rxlpmen       <= 1'b0;
            gt_txdiffctrl    <= 5'd24;
            gt_txprecursor   <= 5'd0;
            gt_txpostcursor  <= 5'd4;
            gt_txmaincursor  <= 7'd80;
            scratch          <= 32'd0;
        end else begin
            if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
            if (s_axil_awready) begin
                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00;
                case (s_axil_awaddr[7:0])
                    8'h10: if (s_axil_wstrb[0]) begin
                        eth_full_reset   <= s_axil_wdata[0];
                        eth_rx_reset     <= s_axil_wdata[1];
                        eth_auto_recover <= s_axil_wdata[2];
                        gt_rxlpmen       <= s_axil_wdata[3];
                    end
                    8'h14: if (&s_axil_wstrb) begin
                        gt_txdiffctrl   <= s_axil_wdata[4:0];
                        gt_txprecursor  <= s_axil_wdata[12:8];
                        gt_txpostcursor <= s_axil_wdata[20:16];
                        gt_txmaincursor <= s_axil_wdata[30:24];
                    end
                    8'h1C: for (int b = 0; b < 4; b++)
                               if (s_axil_wstrb[b]) scratch[8 * b +: 8] <= s_axil_wdata[8 * b +: 8];
                    default: s_axil_bresp <= (s_axil_awaddr[7:0] < 8'h20) ? 2'b00 : 2'b10;
                endcase
            end
        end
    end

    // Read channel
    assign s_axil_arready = !s_axil_rvalid && s_axil_arvalid;

    logic [31:0] rd;
    logic        rd_ok;
    always_comb begin
        rd    = 32'd0;
        rd_ok = 1'b1;
        case (s_axil_araddr[7:0])
            8'h00: rd = ID;
            8'h04: rd = {13'd0, c_uclk_locked, c_lock, c_pg, c_hi_ber, c_aligned, eth_rx_status_s,
                         !c_qsfp_int_n, !c_qsfp_present_n, c_cattrip, c_calib, c_core_locked};
            8'h08: rd = {17'd0, c_temp1, 1'b0, c_temp0};
            8'h0C: rd = {24'd0, c_err};
            8'h10: rd = {28'd0, gt_rxlpmen, eth_auto_recover, 2'b00};
            8'h14: rd = {1'b0, gt_txmaincursor, 3'd0, gt_txpostcursor, 3'd0, gt_txprecursor,
                         3'd0, gt_txdiffctrl};
            8'h18: rd = {16'd0, eth_recover_count_s};
            8'h1C: rd = scratch;
            default: rd_ok = 1'b0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s_axil_rvalid <= 1'b0;
        end else begin
            if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 1'b0;
            if (s_axil_arready) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= rd_ok ? 2'b00 : 2'b10;
                s_axil_rdata  <= rd;
            end
        end
    end

endmodule
