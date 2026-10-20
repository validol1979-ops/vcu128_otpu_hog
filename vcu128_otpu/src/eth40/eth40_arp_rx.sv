// Ответчик ARP 40G, сторона приёма.
//
// Источник: rfsoc_8x8_40g_compat_hog, rfsoc_8x8_40g_compat/src/rtl/compat_arp_rx.sv
// (TODO 7, 02.10.2026). Изменения: синхронный сброс активной 1, счётчики вынесены
// в eth40_regs (здесь импульсы событий), поля разбираются функциями eth40_pkg.
//
// Смотрит поток MAC (без обратного давления). Запрос ARP (Ethernet II 0x0806,
// htype 1, ptype IPv4, hlen 6, plen 4, oper 1) на широковещательный или свой MAC,
// спрашивающий local_ip и закончившийся без ошибки (tuser = 0 на TLAST), даёт
// req_valid на такт с MAC/IP запросившего; ответ отправляет eth40_tx_mux.
// ev_ctl — кадр управления MAC (EtherType 0x8808, например PAUSE от карты ПК):
// плата его не исполняет, только считает.
module eth40_arp_rx
    import eth40_pkg::*;
(
    input  logic         clk,
    input  logic         rst,
    input  logic [47:0]  local_mac,
    input  logic [31:0]  local_ip,
    input  logic [255:0] s_tdata,
    input  logic         s_tvalid,
    input  logic         s_tlast,
    input  logic         s_tuser,
    output logic         req_valid,
    output logic [47:0]  req_mac,
    output logic [31:0]  req_ip,
    output logic         ev_ctl        // импульс: начало кадра управления MAC
);

    wire [511:0] w = {256'b0, s_tdata};
    logic in_frame, is_arp, header_ok, target_ok, second;
    wire sof     = !in_frame;
    wire sof_arp = be16(w, 12) == 16'h0806;
    wire sof_ctl = be16(w, 12) == 16'h8808;

    wire [47:0] dst = be48(w, 0);
    wire word0_ok = (dst == 48'hFFFF_FFFF_FFFF || dst == local_mac) &&
                    be16(w, 14) == 16'h0001 && be16(w, 16) == 16'h0800 &&
                    b8(w, 18) == 8'd6 && b8(w, 19) == 8'd4 && be16(w, 20) == 16'h0001;
    // второй beat: байты 32..63, IP цели — байты кадра 38..41
    wire tpa_ok = be32(w, 6) == local_ip && local_ip != 0;

    always_ff @(posedge clk) begin
        req_valid <= 1'b0;
        ev_ctl    <= 1'b0;
        if (rst) begin
            in_frame <= 1'b0; is_arp <= 1'b0; header_ok <= 1'b0; target_ok <= 1'b0;
            second   <= 1'b0;
        end else if (s_tvalid) begin
            in_frame <= !s_tlast;
            if (sof) begin
                is_arp    <= sof_arp;
                header_ok <= sof_arp && word0_ok;
                second    <= 1'b1;
                target_ok <= 1'b0;
                ev_ctl    <= sof_ctl;
                req_mac   <= be48(w, 22);
                req_ip    <= be32(w, 28);
            end else begin
                second <= 1'b0;
                if (second) target_ok <= tpa_ok;
                // TLAST кадра из >= 2 beat (кадр ARP дополнен до 60 байт)
                if (s_tlast && is_arp && header_ok && (second ? tpa_ok : target_ok) && !s_tuser)
                    req_valid <= 1'b1;
            end
        end
    end

endmodule
