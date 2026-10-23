// Testbench of the thermal monitor: vcu128_sysmon_drp (clk100) with a DRP model of three
// SYSMONs, vcu128_platform_regs (core_clk, with vcu128_thermal) and vcu128_ctl_guard in
// front of a register slave (cocotb's AxiLiteRam). Driven by test_thermal.py.

`timescale 1ns / 1ps

module tb_thermal #(
    parameter int PERIOD = 64
)(
    input  logic        clk,          // core_clk
    input  logic        clk100,
    input  logic        rst,
    input  logic        rst100,

    // DRP model: per SLR temperature / VCCINT / VCCAUX / VCCBRAM register values
    input  logic [15:0] sm_t0, sm_t1, sm_t2,
    input  logic [15:0] sm_vint, sm_vaux, sm_vbram,
    input  logic [2:0]  sm_dead,      // SLR s never answers (DRP timeout)
    input  logic [7:0]  sm_lat,       // DRDY latency in clk100 cycles (JTAG arbitration)
    input  logic [2:0]  sm_ot,

    // HBM
    input  logic [6:0]  hbm_temp0, hbm_temp1,
    input  logic [1:0]  hbm_calib, hbm_cattrip,

    // platform registers (AXI-Lite, 20-bit addresses)
    input  logic [19:0] p_awaddr, input logic p_awvalid, output logic p_awready,
    input  logic [31:0] p_wdata, input logic [3:0] p_wstrb, input logic p_wvalid,
    output logic p_wready, output logic [1:0] p_bresp, output logic p_bvalid,
    input  logic p_bready,
    input  logic [19:0] p_araddr, input logic p_arvalid, output logic p_arready,
    output logic [31:0] p_rdata, output logic [1:0] p_rresp, output logic p_rvalid,
    input  logic p_rready,

    // guard: interconnect side
    input  logic [19:0] c_awaddr, input logic c_awvalid, output logic c_awready,
    input  logic [31:0] c_wdata, input logic [3:0] c_wstrb, input logic c_wvalid,
    output logic c_wready, output logic [1:0] c_bresp, output logic c_bvalid,
    input  logic c_bready,
    input  logic [19:0] c_araddr, input logic c_arvalid, output logic c_arready,
    output logic [31:0] c_rdata, output logic [1:0] c_rresp, output logic c_rvalid,
    input  logic c_rready,
    // guard: slave side
    output logic [19:0] k_awaddr, output logic k_awvalid, input logic k_awready,
    output logic [31:0] k_wdata, output logic [3:0] k_wstrb, output logic k_wvalid,
    input  logic k_wready, input logic [1:0] k_bresp, input logic k_bvalid,
    output logic k_bready,
    output logic [19:0] k_araddr, output logic k_arvalid, input logic k_arready,
    input  logic [31:0] k_rdata, input logic [1:0] k_rresp, input logic k_rvalid,
    output logic k_rready,

    output logic        th_hold,
    output logic [11:0] th_temp_code,
    output logic        calib_gated
);

    // ------------------------------------------------------------------ DRP model
    logic [2:0]            drp_en, drp_rdy;
    logic [7:0]            drp_addr;
    logic [2:0][15:0]      drp_do;
    logic [2:0][3:0][15:0] sm_snap;
    logic [2:0]            sm_valid, sm_err;
    logic                  sm_tog;
    logic [2:0][15:0]      temps;
    assign temps = {sm_t2, sm_t1, sm_t0};

    for (genvar s = 0; s < 3; s++) begin : g_m
        logic [7:0] cnt;
        logic       busy;
        logic [7:0] a;
        always_ff @(posedge clk100) begin
            drp_rdy[s] <= 1'b0;
            if (rst100) begin
                busy <= 1'b0;
            end else if (drp_en[s]) begin
                busy <= 1'b1;
                cnt  <= sm_lat;
                a    <= drp_addr;
            end else if (busy && !sm_dead[s]) begin
                if (cnt != 0) cnt <= cnt - 1'b1;
                else begin
                    busy       <= 1'b0;
                    drp_rdy[s] <= 1'b1;
                    case (a)
                        8'h00: drp_do[s] <= temps[s];
                        8'h01: drp_do[s] <= sm_vint + 16'(s << 6);
                        8'h02: drp_do[s] <= sm_vaux + 16'(s << 6);
                        8'h06: drp_do[s] <= sm_vbram + 16'(s << 6);
                        default: drp_do[s] <= 16'hDEAD;
                    endcase
                end
            end
        end
    end

    vcu128_sysmon_drp #(.NSLR (3), .PERIOD (PERIOD), .TIMEOUT (200)) u_drp (
        .clk (clk100), .rst (rst100), .drp_en, .drp_addr, .drp_do, .drp_rdy,
        .snap (sm_snap), .snap_valid (sm_valid), .snap_err (sm_err), .snap_tog (sm_tog)
    );

    // ------------------------------------------------------------------ registers
    logic        th_abort;
    logic [15:0] n_abort;

    vcu128_platform_regs u_plat (
        .clk, .rst,
        .s_axil_awaddr (p_awaddr), .s_axil_awvalid (p_awvalid), .s_axil_awready (p_awready),
        .s_axil_wdata (p_wdata), .s_axil_wstrb (p_wstrb), .s_axil_wvalid (p_wvalid),
        .s_axil_wready (p_wready), .s_axil_bresp (p_bresp), .s_axil_bvalid (p_bvalid),
        .s_axil_bready (p_bready),
        .s_axil_araddr (p_araddr), .s_axil_arvalid (p_arvalid), .s_axil_arready (p_arready),
        .s_axil_rdata (p_rdata), .s_axil_rresp (p_rresp), .s_axil_rvalid (p_rvalid),
        .s_axil_rready (p_rready),
        .core_locked (1'b1), .uclk_locked (1'b1), .hbm_calib, .hbm_cattrip,
        .hbm_temp0, .hbm_temp1, .hbm_err (8'd0), .qsfp_present_n (1'b0), .qsfp_int_n (1'b1),
        .eth_aligned (1'b1), .eth_hi_ber (1'b0), .gt_powergood (4'hF), .eth_block_lock (4'hF),
        .eth_rx_status_s (1'b1), .eth_recover_count_s (16'd0),
        .eth_full_reset (), .eth_rx_reset (), .eth_auto_recover (), .gt_rxlpmen (),
        .gt_txdiffctrl (), .gt_txprecursor (), .gt_txpostcursor (), .gt_txmaincursor (),
        .sm_snap, .sm_valid, .sm_err, .sm_tog, .sm_ot, .th_n_abort_s (n_abort),
        .th_hold, .th_abort, .th_temp_code
    );

    assign calib_gated = &hbm_calib && !th_hold;

    vcu128_ctl_guard u_guard (
        .clk, .rst, .stop (th_abort), .n_abort,
        .s_awaddr (c_awaddr), .s_awvalid (c_awvalid), .s_awready (c_awready),
        .s_wdata (c_wdata), .s_wstrb (c_wstrb), .s_wvalid (c_wvalid), .s_wready (c_wready),
        .s_bresp (c_bresp), .s_bvalid (c_bvalid), .s_bready (c_bready),
        .s_araddr (c_araddr), .s_arvalid (c_arvalid), .s_arready (c_arready),
        .s_rdata (c_rdata), .s_rresp (c_rresp), .s_rvalid (c_rvalid), .s_rready (c_rready),
        .m_awaddr (k_awaddr), .m_awvalid (k_awvalid), .m_awready (k_awready),
        .m_wdata (k_wdata), .m_wstrb (k_wstrb), .m_wvalid (k_wvalid), .m_wready (k_wready),
        .m_bresp (k_bresp), .m_bvalid (k_bvalid), .m_bready (k_bready),
        .m_araddr (k_araddr), .m_arvalid (k_arvalid), .m_arready (k_arready),
        .m_rdata (k_rdata), .m_rresp (k_rresp), .m_rvalid (k_rvalid), .m_rready (k_rready)
    );

endmodule
