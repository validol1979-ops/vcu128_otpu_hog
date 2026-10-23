// SYSMONE4 of every SLR (xcvu37p: 3) and their DRP reader, clk100. doc/design.md
// "Температура и контроль".
//
// SSI device: one SYSMON per SLR; the master SLR's (SLR0 on the VU37P: SYSMONE4_X0Y0) is the
// one JTAG reaches (hw_manager / the configuration logic; the DRP arbitrates JTAG first, the
// fabric's read waits: vcu128_sysmon_drp's TIMEOUT). Placement as the System Management
// Wizard's for virtexuplusHBM (system_management_wiz_v1_3 xdc.ttcl: master X0Y0, slave0 X0Y1,
// slave1 X0Y2): constr/vcu128_thermal.xdc, so instance s sits in SLR s.
//
// Configuration (INIT_4x): the default sequencer mode (INIT_41[15:12] = 0: temperature and
// the supplies, averaged, calibrated), alarms as at power-up, OT threshold the default 125 C
// (INIT_53 = 0; BITSTREAM.CONFIG.OVERTEMPSHUTDOWN Enable in the XDC); only the ADC clock
// divider is set: INIT_42[15:8] = DCLK / 5 MHz.

module vcu128_sysmon #(
    parameter int NSLR     = 3,
    parameter int DCLK_KHZ = 100000,
    parameter int PERIOD   = 100000
)(
    input  logic                       clk,       // DRP clock (clk100)
    input  logic                       rst,
    output logic [NSLR-1:0][3:0][15:0] snap,
    output logic [NSLR-1:0]            snap_valid,
    output logic [NSLR-1:0]            snap_err,
    output logic                       snap_tog,
    output logic [NSLR-1:0]            ot          // SYSMON OT (over-temperature alarm), async
);

    localparam int CD = (DCLK_KHZ + 4999) / 5000;     // ADCCLK <= 5 MHz (UG580: 1 .. 5.2 MHz)
    localparam logic [15:0] INIT42 = {8'(CD < 2 ? 2 : CD), 8'h00};

    logic [NSLR-1:0]       drp_en, drp_rdy;
    logic [7:0]            drp_addr;
    logic [NSLR-1:0][15:0] drp_do;

    for (genvar s = 0; s < NSLR; s++) begin : g_sm
        SYSMONE4 #(
            .INIT_40 (16'h0000),
            .INIT_41 (16'h0000),
            .INIT_42 (INIT42),
            .SIM_DEVICE ("ULTRASCALE_PLUS")
        ) u_sysmon (
            .DCLK (clk), .DEN (drp_en[s]), .DWE (1'b0), .DADDR (drp_addr), .DI (16'h0000),
            .DO (drp_do[s]), .DRDY (drp_rdy[s]),
            .RESET (1'b0), .CONVST (1'b0), .CONVSTCLK (1'b0),
            .VP (), .VN (), .VAUXP (), .VAUXN (),   // dedicated analog inputs: unused
            .I2C_SCLK (1'b0), .I2C_SDA (1'b0),
            .ADC_DATA (), .ALM (), .BUSY (), .CHANNEL (), .EOC (), .EOS (),
            .I2C_SCLK_TS (), .I2C_SDA_TS (), .JTAGBUSY (), .JTAGLOCKED (), .JTAGMODIFIED (),
            .MUXADDR (), .OT (ot[s]), .SMBALERT_TS ()
        );
    end

    vcu128_sysmon_drp #(.NSLR (NSLR), .PERIOD (PERIOD)) u_drp (
        .clk, .rst, .drp_en, .drp_addr, .drp_do, .drp_rdy,
        .snap, .snap_valid, .snap_err, .snap_tog
    );

endmodule
