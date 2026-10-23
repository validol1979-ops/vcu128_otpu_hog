// Thermal monitor and protection (core_clk): the SYSMON temperatures of every SLR
// (vcu128_sysmon, clk100) and the two HBM stacks' (HBM IP), thresholds with hysteresis,
// sticky flags, maxima, and the action: holding the accelerator. doc/design.md
// "Температура и контроль". Registers: vcu128_platform_regs 0x20 .. 0x5C (its bus below).
//
// Sensors i: 0 .. NSLR-1 the SLRs' die temperature, NSLR / NSLR+1 HBM stacks 0 / 1.
// FPGA in 1/16 C (signed): T = code12 * 509.3140064 / 4096 - 280.2308787 (UG580, SYSMONE4 with
// its internal reference; code12 = the status register's [15:4]), here
// ((code12 * 32596 + 8192) >> 14) - 4484 (within 1/16 C). HBM: whole degrees (DRAM_x_STAT_TEMP,
// 7 bits), taken once two consecutive samples agree (the bits pass separate synchronizers).
//
// Per sensor, two levels with hysteresis H: WARN rises at T >= W, falls at T < W - H; ALARM
// the same with A. FPGA sensors use FPGA_LIM, HBM HBM_LIM. An invalid sensor (no SYSMON reading
// yet; HBM before calibration) takes no part.
//
// HOLD (the action): rises when ACT_EN and (an ALARM, or CATTRIP_ACT and an HBM CATTRIP), or with
// FORCE_HOLD; on its rise stop pulses (vcu128_ctl_guard writes CTRL = 0: the run stops, as the
// host's Board.abort) and while HOLD the accelerator's calibration input is held low (otpu_ctrl
// takes neither RUN nor LOAD). HOLD falls when not FORCE_HOLD and either ACT_EN is cleared, or
// every ALARM has fallen (below A - H), no CATTRIP counts, and AUTO_RESUME or a RESUME write.

module vcu128_thermal #(
    parameter int NSLR       = 3,
    parameter int MASTER_SLR = 0,
    parameter logic [23:0] FPGA_LIM0 = {8'd10, 8'd100, 8'd85},   // {hyst, alarm, warn} C
    parameter logic [23:0] HBM_LIM0  = {8'd5,  8'd95,  8'd85}
)(
    input  logic        clk,
    input  logic        rst,

    // vcu128_sysmon (clk100): stable while sm_tog does not change
    input  logic [NSLR-1:0][3:0][15:0] sm_snap,
    input  logic [NSLR-1:0]            sm_valid,
    input  logic [NSLR-1:0]            sm_err,
    input  logic                       sm_tog,
    input  logic [NSLR-1:0]            sm_ot,       // asynchronous

    // HBM (already synchronized into clk)
    input  logic [6:0]  hbm_temp0,
    input  logic [6:0]  hbm_temp1,
    input  logic        hbm_valid,
    input  logic [1:0]  hbm_cattrip,
    input  logic [15:0] n_abort,                    // vcu128_ctl_guard's CTRL writes

    // register bus (vcu128_platform_regs)
    input  logic        wr,
    input  logic [7:0]  waddr,
    input  logic [31:0] wdata,
    input  logic [7:0]  raddr,
    output logic [31:0] rdata,
    output logic        rhit,

    output logic        hold,
    output logic        stop,                       // one-cycle pulse: CTRL = 0
    output logic [11:0] temp_code,                  // the hottest valid SLR's code (otpu_board temp)
    output logic        st_warn,                    // for STATUS
    output logic        st_alarm_l
);

    localparam int NT = NSLR + 2;
    localparam logic [7:0] VERSION = 8'd1;

    // ------------------------------------------------------------------ SYSMON into clk
    (* ASYNC_REG = "TRUE" *) logic tog_s1, tog_s2;
    logic tog_s3;
    (* ASYNC_REG = "TRUE" *) logic [NSLR-1:0] ot_s1, ot_s2;
    logic [NSLR-1:0][3:0][15:0] cap_snap;
    logic [NSLR-1:0]            cap_valid, cap_err;
    logic                       fresh;
    always_ff @(posedge clk) begin
        tog_s1 <= sm_tog;
        tog_s2 <= tog_s1;
        tog_s3 <= tog_s2;
        ot_s1  <= sm_ot;
        ot_s2  <= ot_s1;
        fresh  <= 1'b0;
        if (rst) begin
            cap_valid <= '0;
            cap_err   <= '0;
        end else if (tog_s2 != tog_s3) begin
            cap_snap  <= sm_snap;
            cap_valid <= sm_valid;
            cap_err   <= sm_err;
            fresh     <= 1'b1;
        end
    end

    // FPGA temperatures in 1/16 C
    function automatic logic signed [15:0] code_q4(input logic [11:0] c);
        logic [27:0] p;
        p = 28'(c) * 28'd32596 + 28'd8192;
        return 16'(p[27:14]) - 16'sd4484;
    endfunction

    logic signed [15:0] t_cur [NT];         // current, 1/16 C
    logic [NT-1:0]      t_ok;
    logic [11:0]        code [NSLR];
    logic signed [15:0] f_cur [NSLR];
    logic [NSLR-1:0]    f_ok;
    always_ff @(posedge clk) begin
        for (int s = 0; s < NSLR; s++) begin
            code[s]  <= cap_snap[s][0][15:4];
            f_cur[s] <= code_q4(cap_snap[s][0][15:4]);
            f_ok[s]  <= cap_valid[s];
        end
    end

    // HBM: a value counts once two consecutive samples agree
    logic [6:0] h_prev [2], h_q [2];
    logic [1:0] h_ok;
    always_ff @(posedge clk) begin
        h_prev[0] <= hbm_temp0;
        h_prev[1] <= hbm_temp1;
        if (rst || !hbm_valid) begin
            h_ok <= '0;
        end else begin
            if (hbm_temp0 == h_prev[0]) begin h_q[0] <= hbm_temp0; h_ok[0] <= 1'b1; end
            if (hbm_temp1 == h_prev[1]) begin h_q[1] <= hbm_temp1; h_ok[1] <= 1'b1; end
        end
    end
    always_comb begin
        for (int s = 0; s < NSLR; s++) begin
            t_cur[s] = f_cur[s];
            t_ok[s]  = f_ok[s];
        end
        for (int k = 0; k < 2; k++) begin
            t_cur[NSLR + k] = {5'd0, h_q[k], 4'd0};
            t_ok[NSLR + k]  = h_ok[k];
        end
    end

    // ------------------------------------------------------------------ registers
    logic        act_en, auto_resume, cattrip_act, force_hold;
    logic [7:0]  f_warn, f_alarm, f_hyst, h_warn, h_alarm, h_hyst;
    logic        w_resume, w_clr_flags, w_clr_max;

    always_ff @(posedge clk) begin
        w_resume    <= 1'b0;
        w_clr_flags <= 1'b0;
        w_clr_max   <= 1'b0;
        if (rst) begin
            act_en      <= 1'b1;
            auto_resume <= 1'b0;
            cattrip_act <= 1'b1;
            force_hold  <= 1'b0;
            {f_hyst, f_alarm, f_warn} <= FPGA_LIM0;
            {h_hyst, h_alarm, h_warn} <= HBM_LIM0;
        end else if (wr) begin
            case (waddr)
                8'h24: begin
                    act_en      <= wdata[0];
                    auto_resume <= wdata[1];
                    cattrip_act <= wdata[2];
                    force_hold  <= wdata[3];
                    w_resume    <= wdata[8];
                    w_clr_flags <= wdata[9];
                    w_clr_max   <= wdata[10];
                end
                8'h2C: {f_hyst, f_alarm, f_warn} <= wdata[23:0];
                8'h30: {h_hyst, h_alarm, h_warn} <= wdata[23:0];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------ levels
    logic signed [15:0] lim_w [NT], lim_wl [NT], lim_a [NT], lim_al [NT];
    always_ff @(posedge clk) begin
        for (int i = 0; i < NT; i++) begin
            lim_w[i]  <= (i < NSLR) ? {4'd0, f_warn, 4'd0} : {4'd0, h_warn, 4'd0};
            lim_a[i]  <= (i < NSLR) ? {4'd0, f_alarm, 4'd0} : {4'd0, h_alarm, 4'd0};
            lim_wl[i] <= (i < NSLR) ? ({4'd0, f_warn, 4'd0} - {4'd0, f_hyst, 4'd0})
                                    : ({4'd0, h_warn, 4'd0} - {4'd0, h_hyst, 4'd0});
            lim_al[i] <= (i < NSLR) ? ({4'd0, f_alarm, 4'd0} - {4'd0, f_hyst, 4'd0})
                                    : ({4'd0, h_alarm, 4'd0} - {4'd0, h_hyst, 4'd0});
        end
    end

    logic [NT-1:0] warn, alarm, warn_l, alarm_l;
    logic          cattrip_l, hold_l, sm_err_l;
    logic signed [15:0] t_max [NT];
    logic [15:0]   n_hold, n_warn;

    wire warn_any  = |warn;
    wire alarm_any = |alarm;
    wire cattrip_any = |hbm_cattrip;
    wire cool = !alarm_any && !(cattrip_act && cattrip_any);
    wire trigger = (act_en && (alarm_any || (cattrip_act && cattrip_any))) || force_hold;
    wire release_ = !force_hold && (!act_en || (cool && (auto_resume || w_resume)));
    logic warn_any_q;

    always_ff @(posedge clk) begin
        stop <= 1'b0;
        if (rst) begin
            warn      <= '0;
            alarm     <= '0;
            warn_l    <= '0;
            alarm_l   <= '0;
            cattrip_l <= 1'b0;
            hold      <= 1'b0;
            hold_l    <= 1'b0;
            sm_err_l  <= 1'b0;
            n_hold    <= '0;
            n_warn    <= '0;
            warn_any_q <= 1'b0;
            for (int i = 0; i < NT; i++) t_max[i] <= 16'sh8000;
        end else begin
            for (int i = 0; i < NT; i++) begin
                if (!t_ok[i]) begin
                    warn[i]  <= 1'b0;
                    alarm[i] <= 1'b0;
                end else begin
                    if (t_cur[i] >= lim_w[i])      warn[i] <= 1'b1;
                    else if (t_cur[i] < lim_wl[i]) warn[i] <= 1'b0;
                    if (t_cur[i] >= lim_a[i])      alarm[i] <= 1'b1;
                    else if (t_cur[i] < lim_al[i]) alarm[i] <= 1'b0;
                end
                if (w_clr_max)
                    t_max[i] <= t_ok[i] ? t_cur[i] : 16'sh8000;
                else if (t_ok[i] && (t_max[i] == 16'sh8000 || t_cur[i] > t_max[i]))
                    t_max[i] <= t_cur[i];
            end
            warn_l    <= (w_clr_flags ? '0 : warn_l) | warn;
            alarm_l   <= (w_clr_flags ? '0 : alarm_l) | alarm;
            cattrip_l <= (w_clr_flags ? 1'b0 : cattrip_l) | cattrip_any;
            hold_l    <= (w_clr_flags ? 1'b0 : hold_l) | hold;
            sm_err_l  <= (w_clr_flags ? 1'b0 : sm_err_l) | (|cap_err);

            warn_any_q <= warn_any;
            if (warn_any && !warn_any_q && n_warn != 16'hFFFF) n_warn <= n_warn + 1'b1;

            if (!hold && trigger) begin
                hold  <= 1'b1;
                stop <= 1'b1;
                if (n_hold != 16'hFFFF) n_hold <= n_hold + 1'b1;
            end else if (hold && release_) begin
                hold <= 1'b0;
            end
        end
    end

    // the hottest valid SLR's code (upstream R_TEMP: 0 = no reading yet)
    always_ff @(posedge clk) begin
        logic [11:0] m;
        m = '0;
        for (int s = 0; s < NSLR; s++)
            if (t_ok[s] && code[s] > m) m = code[s];
        temp_code <= m;
    end

    assign st_warn    = warn_any;
    assign st_alarm_l = |alarm_l;

    // ------------------------------------------------------------------ read
    always_comb begin
        rdata = 32'd0;
        rhit  = 1'b1;
        case (raddr)
            8'h20: rdata = {15'd0, 1'b1, VERSION, 4'(MASTER_SLR), 4'(NSLR)};
            8'h24: rdata = {28'd0, force_hold, cattrip_act, auto_resume, act_en};
            8'h28: rdata = {3'd0, 5'(alarm_l), 3'd0, 5'(warn_l), 5'd0, sm_err_l, &t_ok[NSLR-1:0],
                            cool, hold_l, cattrip_l, |alarm_l, |warn_l,
                            hold, cattrip_any, alarm_any, warn_any};
            8'h2C: rdata = {8'd0, f_hyst, f_alarm, f_warn};
            8'h30: rdata = {8'd0, h_hyst, h_alarm, h_warn};
            8'h34: rdata = {n_warn, n_hold};
            8'h38: rdata = {13'd0, 3'(ot_s2), 4'd0, temp_code};
            8'h3C: rdata = {16'd0, n_abort};
            8'h4C: rdata = {t_max[NSLR + 1][11:4], t_max[NSLR][11:4],
                            t_cur[NSLR + 1][11:4], t_cur[NSLR][11:4]};
            default: begin
                rhit = 1'b0;
                for (int s = 0; s < NSLR; s++) begin
                    if (raddr == 8'h40 + 8'(4 * s)) begin
                        rdata = {t_max[s], t_cur[s]};
                        rhit  = 1'b1;
                    end
                    if (raddr == 8'h50 + 8'(4 * s)) begin
                        rdata = {2'd0, cap_snap[s][3][15:6], cap_snap[s][2][15:6],
                                 cap_snap[s][1][15:6]};
                        rhit  = 1'b1;
                    end
                end
                if (raddr == 8'h5C) rhit = 1'b1;
            end
        endcase
    end

endmodule
