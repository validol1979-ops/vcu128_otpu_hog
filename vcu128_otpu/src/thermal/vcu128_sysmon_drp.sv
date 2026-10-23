// SYSMONE4 DRP reader (clk100): the status registers of every SLR's SYSMON, round robin.
// doc/design.md "Температура и контроль".
//
// Each round reads, for SLR s = 0 .. NSLR-1, the DRP status registers 0x00 (temperature),
// 0x01 (VCCINT), 0x02 (VCCAUX) and 0x06 (VCCBRAM): one read at a time (DEN pulse, wait DRDY,
// at most TIMEOUT cycles: a JTAG access of the master SYSMON delays the fabric's DRP, UG580).
// After the round the snapshot (snap_*) is updated at once and snap_tog toggles; the next round
// starts PERIOD cycles later, so the snapshot holds for >= PERIOD cycles -- the consumer
// (vcu128_thermal, core_clk) captures it a few cycles after it sees the toggle
// (constr/vcu128_thermal.tcl: set_max_delay -datapath_only on snap_* -> cap_*).
//
// The registers' 16 bits as the SYSMON gives them (10-bit ADC code in [15:6], the rest the
// averaging's extra resolution). snap_valid[s]: SLR s answered with a temperature at least
// once; snap_err[s]: a read of SLR s timed out in the round (vcu128_thermal keeps it sticky).

module vcu128_sysmon_drp #(
    parameter int NSLR    = 3,
    parameter int PERIOD  = 100000,       // cycles between rounds (1 ms at 100 MHz)
    parameter int TIMEOUT = 65535         // cycles a read may wait for DRDY
)(
    input  logic                      clk,
    input  logic                      rst,

    // DRP: one SYSMONE4 per SLR; address and write port shared
    output logic [NSLR-1:0]           drp_en,
    output logic [7:0]                drp_addr,
    input  logic [NSLR-1:0][15:0]     drp_do,
    input  logic [NSLR-1:0]           drp_rdy,

    // snapshot: per SLR {VCCBRAM, VCCAUX, VCCINT, TEMP}
    output logic [NSLR-1:0][3:0][15:0] snap,
    output logic [NSLR-1:0]           snap_valid,
    output logic [NSLR-1:0]           snap_err,
    output logic                      snap_tog
);

    localparam int SW = $clog2(NSLR > 1 ? NSLR : 2);
    localparam int PW = $clog2(PERIOD + 1);
    localparam int TW = $clog2(TIMEOUT + 1);

    typedef enum logic [1:0] {S_WAIT, S_REQ, S_RESP} state_t;
    state_t state;

    logic [SW-1:0] slr;
    logic [1:0]    reg_i;
    logic [PW-1:0] pause;
    logic [TW-1:0] tmo;
    logic [NSLR-1:0][3:0][15:0] acc;
    logic [NSLR-1:0] acc_valid, acc_err;

    function automatic logic [7:0] reg_addr(input logic [1:0] i);
        case (i)
            2'd0: return 8'h00;   // temperature
            2'd1: return 8'h01;   // VCCINT
            2'd2: return 8'h02;   // VCCAUX
            default: return 8'h06; // VCCBRAM
        endcase
    endfunction

    assign drp_addr = reg_addr(reg_i);

    always_ff @(posedge clk) begin
        drp_en <= '0;
        if (rst) begin
            state      <= S_WAIT;
            slr        <= '0;
            reg_i      <= '0;
            pause      <= PW'(PERIOD);
            tmo        <= '0;
            acc_valid  <= '0;
            acc_err    <= '0;
            snap       <= '0;
            snap_valid <= '0;
            snap_err   <= '0;
            snap_tog   <= 1'b0;
        end else begin
            case (state)
                S_WAIT:
                    if (pause != 0) pause <= pause - 1'b1;
                    else            state <= S_REQ;
                S_REQ: begin
                    drp_en[slr] <= 1'b1;
                    tmo         <= TW'(TIMEOUT);
                    state       <= S_RESP;
                end
                S_RESP: begin
                    if (drp_rdy[slr] || tmo == 0) begin
                        if (drp_rdy[slr]) begin
                            acc[slr][reg_i] <= drp_do[slr];
                            if (reg_i == 2'd0) acc_valid[slr] <= 1'b1;
                        end else begin
                            acc_err[slr] <= 1'b1;
                        end
                        state <= S_REQ;
                        if (reg_i != 2'd3) begin
                            reg_i <= reg_i + 1'b1;
                        end else begin
                            reg_i <= '0;
                            if (slr != SW'(NSLR - 1)) begin
                                slr <= slr + 1'b1;
                            end else begin
                                slr   <= '0;
                                state <= S_WAIT;
                                pause <= PW'(PERIOD);
                            end
                        end
                    end else begin
                        tmo <= tmo - 1'b1;
                    end
                end
                default: state <= S_WAIT;
            endcase
            // end of a round: the snapshot (the last read lands in acc next cycle: one
            // cycle of S_WAIT later, pause == PERIOD - 1)
            if (state == S_WAIT && pause == PW'(PERIOD - 1)) begin
                snap       <= acc;
                snap_valid <= acc_valid;
                snap_err   <= acc_err;
                acc_err    <= '0;
                snap_tog   <= !snap_tog;
            end
        end
    end

endmodule
