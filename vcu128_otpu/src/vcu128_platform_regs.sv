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
//   0x20 .. 0x5C     thermal monitor and protection (vcu128_thermal; doc/design.md
//                    "Температура и контроль"):
//   0x20 TH_INFO     R   [3:0] SLRs (3), [7:4] master SLR (0), [15:8] version (1), [16] 1
//   0x24 TH_CTRL     R/W [0] ACT_EN (reset 1): hold the accelerator on an alarm,
//                        [1] AUTO_RESUME (0), [2] CATTRIP_ACT (1): HBM CATTRIP holds too,
//                        [3] FORCE_HOLD (0); W1: [8] RESUME, [9] clear flags, [10] clear maxima
//   0x28 TH_STATUS   R   [0] WARN, [1] ALARM, [2] CATTRIP, [3] HOLD, [4] WARN sticky,
//                        [5] ALARM sticky, [6] CATTRIP sticky, [7] HOLD sticky, [8] COOL (no
//                        alarm, no counted CATTRIP), [9] every SLR read, [10] DRP timeout
//                        sticky, [20:16] / [28:24] sensors' WARN / ALARM sticky
//                        (SLR0, SLR1, SLR2, HBM0, HBM1)
//   0x2C TH_FPGA_LIM R/W [7:0] warn C (85), [15:8] alarm C (100), [23:16] hysteresis C (10)
//   0x30 TH_HBM_LIM  R/W the same for HBM (85, 95, 5)
//   0x34 TH_EVENTS   R   [15:0] HOLD entries, [31:16] WARN rises
//   0x38 TH_RAW      R   [11:0] the code given to otpu_board temp (hottest SLR), [18:16] OT
//   0x3C TH_ABORTS   R   [15:0] CTRL = 0 writes done by vcu128_ctl_guard
//   0x40 + 4s T_SLRs R   [15:0] current, [31:16] maximum, signed 1/16 C (0x8000: none)
//   0x4C T_HBM       R   [7:0] / [15:8] stack 0 / 1 current, [23:16] / [31:24] maximum, C
//   0x50 + 4s V_SLRs R   [9:0] VCCINT, [19:10] VCCAUX, [29:20] VCCBRAM: code x 3 V / 1024
//   STATUS also [19] thermal WARN, [20] ALARM sticky, [21] HOLD.

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
    output logic [6:0]  gt_txmaincursor,

    // thermal (vcu128_sysmon, clk100: stable while sm_tog does not change)
    input  logic [2:0][3:0][15:0] sm_snap,
    input  logic [2:0]  sm_valid,
    input  logic [2:0]  sm_err,
    input  logic        sm_tog,
    input  logic [2:0]  sm_ot,
    input  logic [15:0] th_n_abort_s,
    output logic        th_hold,            // clk
    output logic        th_abort,           // one-cycle pulse
    output logic [11:0] th_temp_code
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

    // thermal monitor (registers 0x20 .. 0x5C)
    wire         th_wr = s_axil_awready && s_axil_awaddr[7:0] >= 8'h20 && s_axil_awaddr[7:0] < 8'h60;
    logic [31:0] th_rdata;
    logic        th_rhit, th_warn, th_alarm_l;
    vcu128_thermal #(.NSLR (3), .MASTER_SLR (0)) u_thermal (
        .clk, .rst,
        .sm_snap, .sm_valid, .sm_err, .sm_tog, .sm_ot,
        .hbm_temp0 (c_temp0), .hbm_temp1 (c_temp1), .hbm_valid (&c_calib), .hbm_cattrip (c_cattrip),
        .n_abort (th_n_abort_s),
        .wr (th_wr), .waddr (s_axil_awaddr[7:0]), .wdata (s_axil_wdata),
        .raddr (s_axil_araddr[7:0]), .rdata (th_rdata), .rhit (th_rhit),
        .hold (th_hold), .stop (th_abort), .temp_code (th_temp_code),
        .st_warn (th_warn), .st_alarm_l (th_alarm_l)
    );

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
                    default: s_axil_bresp <= (s_axil_awaddr[7:0] < 8'h60) ? 2'b00 : 2'b10;
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
            8'h04: rd = {10'd0, th_hold, th_alarm_l, th_warn, c_uclk_locked, c_lock, c_pg, c_hi_ber, c_aligned, eth_rx_status_s,
                         !c_qsfp_int_n, !c_qsfp_present_n, c_cattrip, c_calib, c_core_locked};
            8'h08: rd = {17'd0, c_temp1, 1'b0, c_temp0};
            8'h0C: rd = {24'd0, c_err};
            8'h10: rd = {28'd0, gt_rxlpmen, eth_auto_recover, 2'b00};
            8'h14: rd = {1'b0, gt_txmaincursor, 3'd0, gt_txpostcursor, 3'd0, gt_txprecursor,
                         3'd0, gt_txdiffctrl};
            8'h18: rd = {16'd0, eth_recover_count_s};
            8'h1C: rd = scratch;
            default: begin
                rd    = th_rdata;
                rd_ok = th_rhit;
            end
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
