// Выход передачи 40G: ответ ARP и два потока кадров (служебные ответы и данные чтения)
// на один AXIS MAC, переключение только между кадрами.
//
// Ответ ARP (60 байт, два beat; FCS добавляет MAC) — по образцу
// rfsoc_8x8_40g_compat_hog, rfsoc_8x8_40g_compat/src/rtl/compat_arp_tx.sv (TODO 7,
// 02.10.2026): запрос хранится до отправки, запросы во время отправки теряются
// (ПК повторит). Отличия: три источника вместо одного, сброс активной 1.
// Приоритет на границе кадра: ARP, служебные, данные. Источники — кадровые FIFO
// (tvalid внутри кадра не снимается), поэтому MAC получает кадр без разрывов.
// Выход — через axis_register (verilog-axis), MAC управляется с регистров.
module eth40_tx_mux (
    input  logic         clk,
    input  logic         rst,
    input  logic [47:0]  local_mac,
    input  logic [31:0]  local_ip,

    input  logic         arp_req,
    input  logic [47:0]  arp_mac,
    input  logic [31:0]  arp_ip,

    input  logic [255:0] s0_tdata,      // служебные ответы
    input  logic [31:0]  s0_tkeep,
    input  logic         s0_tvalid,
    input  logic         s0_tlast,
    output logic         s0_tready,

    input  logic [255:0] s1_tdata,      // данные чтения
    input  logic [31:0]  s1_tkeep,
    input  logic         s1_tvalid,
    input  logic         s1_tlast,
    output logic         s1_tready,

    output logic [255:0] m_tdata,
    output logic [31:0]  m_tkeep,
    output logic         m_tvalid,
    output logic         m_tlast,
    output logic         m_tuser,
    input  logic         m_tready,

    output logic         ev_arp_tx,     // импульс: ответ ARP отправлен
    output logic         ev_tx          // импульс: кадр передан в MAC (TLAST)
);

    // 0 — нет, 1 — ARP, 2 — служебные, 3 — данные
    logic [1:0] sel;
    logic       pend, arp_second;
    logic [47:0] t_mac;
    logic [31:0] t_ip;
    logic        o_ready;

    function automatic logic [255:0] put(input logic [255:0] w, input int n, input logic [7:0] v);
        logic [255:0] r;
        r = w;
        r[8*n +: 8] = v;
        return r;
    endfunction

    logic [255:0] beat0, beat1;
    always_comb begin
        beat0 = '0;
        beat1 = '0;
        for (int k = 0; k < 6; k++) begin
            beat0 = put(beat0, k, t_mac[8*(5-k) +: 8]);          // назначение: запросивший
            beat0 = put(beat0, 6 + k, local_mac[8*(5-k) +: 8]);  // источник
            beat0 = put(beat0, 22 + k, local_mac[8*(5-k) +: 8]); // MAC отправителя
            beat1 = put(beat1, k, t_mac[8*(5-k) +: 8]);          // MAC цели (байты 32..37)
        end
        beat0 = put(beat0, 12, 8'h08); beat0 = put(beat0, 13, 8'h06);   // EtherType ARP
        beat0 = put(beat0, 15, 8'h01);                                  // htype 1
        beat0 = put(beat0, 16, 8'h08);                                  // ptype 0x0800
        beat0 = put(beat0, 18, 8'd6);  beat0 = put(beat0, 19, 8'd4);
        beat0 = put(beat0, 21, 8'h02);                                  // oper 2: ответ
        for (int k = 0; k < 4; k++) begin
            beat0 = put(beat0, 28 + k, local_ip[8*(3-k) +: 8]);  // IP отправителя
            beat1 = put(beat1, 6 + k, t_ip[8*(3-k) +: 8]);       // IP цели (38..41)
        end
    end

    // выбор на границе кадра (sel == 0): только регистры, без петли через ready
    logic [1:0] nsel;
    always_comb begin
        nsel = sel;
        if (sel == 2'd0) begin
            if (pend)           nsel = 2'd1;
            else if (s0_tvalid) nsel = 2'd2;
            else if (s1_tvalid) nsel = 2'd3;
        end
    end

    logic [255:0] o_tdata;
    logic [31:0]  o_tkeep;
    logic         o_tvalid, o_tlast;
    always_comb begin
        case (nsel)
            2'd1: begin
                o_tdata = arp_second ? beat1 : beat0;
                o_tkeep = arp_second ? 32'h0FFF_FFFF : 32'hFFFF_FFFF;
                o_tvalid = 1'b1; o_tlast = arp_second;
            end
            2'd2: begin o_tdata = s0_tdata; o_tkeep = s0_tkeep; o_tvalid = s0_tvalid; o_tlast = s0_tlast; end
            2'd3: begin o_tdata = s1_tdata; o_tkeep = s1_tkeep; o_tvalid = s1_tvalid; o_tlast = s1_tlast; end
            default: begin o_tdata = '0; o_tkeep = '0; o_tvalid = 1'b0; o_tlast = 1'b0; end
        endcase
    end
    assign s0_tready = nsel == 2'd2 && o_ready;
    assign s1_tready = nsel == 2'd3 && o_ready;

    wire o_fire = o_tvalid && o_ready;
    always_ff @(posedge clk) begin
        ev_arp_tx <= 1'b0;
        if (rst) begin
            sel <= 2'd0; pend <= 1'b0; arp_second <= 1'b0;
        end else begin
            sel <= nsel;
            if (o_fire) begin
                if (o_tlast) sel <= 2'd0;
                if (nsel == 2'd1) begin
                    arp_second <= !arp_second;
                    if (arp_second) begin pend <= 1'b0; ev_arp_tx <= 1'b1; end
                end
            end
            if (arp_req && nsel != 2'd1) begin pend <= 1'b1; t_mac <= arp_mac; t_ip <= arp_ip; end
        end
    end

    axis_register #(.DATA_WIDTH(256), .KEEP_ENABLE(1), .KEEP_WIDTH(32), .LAST_ENABLE(1),
        .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(0), .REG_TYPE(2)) u_out (
        .clk(clk), .rst(rst),
        .s_axis_tdata(o_tdata), .s_axis_tkeep(o_tkeep), .s_axis_tvalid(o_tvalid),
        .s_axis_tready(o_ready), .s_axis_tlast(o_tlast), .s_axis_tid(8'b0),
        .s_axis_tdest(8'b0), .s_axis_tuser(1'b0),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tid(), .m_axis_tdest(),
        .m_axis_tuser());
    assign m_tuser = 1'b0;              // TX: 1 — испортить кадр (не используется)
    assign ev_tx = m_tvalid && m_tready && m_tlast;

endmodule
