// 40G (l_ethernet) management without a processor: what the RFSoC firmware does in
// rfsoc_8x8_40g_compat_hog (sw/ps_console/src/main.cpp eth40_boot_reset, eth40_recovery.h).
//
// - Power-up: sys_reset (and both GT datapath resets) for T_RESET_MS after dclk is up, then
//   released; the MAC/PCS resets (tx_reset/rx_reset) follow sys_reset through
//   eth40_core_reset in the GT TX clock (top).
// - GT TX drive: one setting for all four lanes from the registers, boot values as the
//   RFSoC firmware's for the same 3 m passive DAC to ConnectX-3 (docs/GT_LINK.md there:
//   TXDIFFCTRL 24, post-cursor 4, main 80, pre 0 gave 0 CRC errors in 490M frames).
// - Recovery: while auto is on, stat_rx_status low for RECOVER_MS (after the link was up
//   once, or after BOOT_MS from power-up) pulses gtwiz_reset_rx_datapath for T_PULSE_US.
// - Requests from the registers: full reset (as power-up), RX datapath reset.
// All in dclk (100 MHz); rx_status and powergood are asynchronous inputs.

module eth40_mgmt #(
    parameter int CLK_HZ     = 100_000_000,
    parameter int T_RESET_MS = 100,
    parameter int BOOT_MS    = 3000,
    parameter int RECOVER_MS = 2000,
    parameter int T_PULSE_US = 100
)(
    input  logic        clk,            // dclk
    input  logic        rst,

    // registers (clk)
    input  logic        req_full_reset,     // one-cycle pulses
    input  logic        req_rx_reset,
    input  logic        auto_recover,

    // l_ethernet
    input  logic        rx_status_async,    // stat_rx_status_0 (rx core clock)
    output logic        sys_reset,          // sys_reset, gtwiz_reset_tx_datapath_0
    output logic        rx_dp_reset,        // gtwiz_reset_rx_datapath_0

    // status (clk)
    output logic        rx_status,
    output logic [15:0] recover_count
);

    localparam int MS = CLK_HZ / 1000;
    localparam int US = CLK_HZ / 1_000_000;
    localparam int TW = $clog2((BOOT_MS > RECOVER_MS ? BOOT_MS : RECOVER_MS) * MS + 1);

    (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync;
    always_ff @(posedge clk) rx_sync <= {rx_sync[0], rx_status_async};
    assign rx_status = rx_sync[1];

    logic [TW-1:0] t_reset, t_down, t_pulse;
    logic          was_up, booted;

    always_ff @(posedge clk) begin
        if (rst || req_full_reset) begin
            sys_reset   <= 1'b1;
            rx_dp_reset <= 1'b0;
            t_reset     <= TW'(T_RESET_MS * MS);
            t_down      <= TW'(BOOT_MS * MS);
            t_pulse     <= '0;
            was_up      <= 1'b0;
            booted      <= 1'b0;
            if (rst) recover_count <= '0;
        end else begin
            if (t_reset != '0) begin
                t_reset <= t_reset - 1'b1;
            end else begin
                sys_reset <= 1'b0;
                booted    <= 1'b1;
            end

            if (t_pulse != '0) begin
                t_pulse <= t_pulse - 1'b1;
                if (t_pulse == TW'(1)) rx_dp_reset <= 1'b0;
            end

            if (booted) begin
                if (rx_status) begin
                    was_up <= 1'b1;
                    t_down <= TW'(RECOVER_MS * MS);
                end else if (t_down != '0) begin
                    t_down <= t_down - 1'b1;
                end

                if (req_rx_reset || (auto_recover && !rx_status && t_down == '0 && t_pulse == '0)) begin
                    rx_dp_reset   <= 1'b1;
                    t_pulse       <= TW'(T_PULSE_US * US);
                    t_down        <= TW'(RECOVER_MS * MS);
                    recover_count <= recover_count + 16'd1;
                end
            end
        end
    end

endmodule
