// Фильтр приёма 40G: помечает (tuser = 1 на TLAST) всё, что не является запросом
// протокола этой плате, чтобы кадровая FIFO приёма отбросила кадр целиком.
//
// Поток MAC (l_ethernet, AXIS 256 бит) без обратного давления, один регистр задержки.
// Кадр принимается, если: MAC без ошибки (tuser = 0 на TLAST), MAC назначения свой,
// EtherType 0x0800, IPv4 без опций (0x45) и без фрагментации (MF = 0, смещение 0),
// протокол UDP, IP назначения свой, контрольная сумма заголовка IPv4 верна, порт UDP
// назначения свой, длина UDP = общая длина IP − 20, кадр не короче 14 + длина IP
// (хвост — выравнивание до 60 байт или FCS, если MAC её не удаляет, — допустим),
// полезная нагрузка не короче заголовка протокола и начинается с MAGIC_REQ.
// Контрольная сумма UDP не проверяется (кадр защищён FCS).
// Решение по полям beat k регистрируется вместе с самим beat, поэтому к выходу TLAST
// все признаки уже в регистрах.
module eth40_rx_filter
    import eth40_pkg::*;
(
    input  logic         clk,
    input  logic         rst,

    input  logic [47:0]  local_mac,
    input  logic [31:0]  local_ip,
    input  logic [15:0]  local_port,

    input  logic [255:0] s_tdata,
    input  logic [31:0]  s_tkeep,
    input  logic         s_tvalid,
    input  logic         s_tlast,
    input  logic         s_tuser,      // 1 на TLAST: ошибка кадра (FCS и т.п.)

    output logic [255:0] m_tdata,
    output logic [31:0]  m_tkeep,
    output logic         m_tvalid,
    output logic         m_tlast,
    output logic         m_tuser,      // 1 на TLAST: кадр отбросить

    // импульсы на TLAST выхода
    output logic         ev_frame,     // любой кадр
    output logic         ev_bad,       // ошибка MAC
    output logic         ev_accept,    // запрос протокола принят в FIFO
    output logic         ev_ignore     // исправный кадр не для протокола (ARP, PAUSE, чужие)
);

    logic        in_frame;             // входной кадр продолжается (не первый beat)
    logic        second;               // входной beat — второй в кадре
    logic [15:0] nbeats;               // полных beat перед текущим входным
    logic        ok0, ok1, len_ok, two, u_r;
    logic [15:0] tot_len;
    logic [19:0] sum0;

    wire [511:0] w0 = {256'b0, s_tdata};             // поля beat 0
    wire [511:0] w1 = {s_tdata, 256'b0};             // поля beat 1 (байты 32..63)

    // beat 0: байты 0..31
    logic [19:0] sum0_c;
    always_comb begin
        sum0_c = '0;
        for (int k = 0; k < 9; k++) sum0_c += 20'(be16(w0, 14 + 2*k));
    end
    wire ok0_c = be48(w0, 0) == local_mac && be16(w0, 12) == 16'h0800 &&
                 b8(w0, 14) == 8'h45 && (be16(w0, 20) & 16'h3FFF) == 16'h0 &&
                 b8(w0, 23) == 8'd17 && be16(w0, 30) == local_ip[31:16];

    // beat 1: байты 32..63
    logic [19:0] sum1;
    always_comb begin
        sum1 = sum0 + be16(w1, 32);
        sum1 = 20'(sum1[15:0]) + sum1[19:16];
        sum1 = 20'(sum1[15:0]) + sum1[19:16];
    end
    wire ok1_c = be16(w1, 32) == local_ip[15:0] && sum1[15:0] == 16'hFFFF &&
                 be16(w1, 36) == local_port && be16(w1, 38) == tot_len - 16'd20 &&
                 tot_len >= 16'(20 + 8 + PHDR) && le32(w1, 42) == MAGIC_REQ;

    // байты кадра до конца текущего beat
    logic [5:0] nkeep;
    always_comb begin
        nkeep = '0;
        for (int k = 0; k < 32; k++) nkeep += 6'(s_tkeep[k]);
    end
    wire [20:0] nbytes_c = {nbeats, 5'b0} + nkeep;

    always_ff @(posedge clk) begin
        m_tvalid <= s_tvalid;
        m_tdata  <= s_tdata;
        m_tkeep  <= s_tkeep;
        m_tlast  <= s_tlast;
        if (s_tvalid) begin
            if (!in_frame) begin
                ok0     <= ok0_c;
                sum0    <= sum0_c;
                tot_len <= be16(w0, 16);
                ok1     <= 1'b0;
                two     <= 1'b0;
            end else if (second) begin
                ok1 <= ok1_c;
                two <= 1'b1;
            end
            if (s_tlast) len_ok <= nbytes_c >= 21'(16'd14 + (in_frame ? tot_len : be16(w0, 16)));
            in_frame <= !s_tlast;
            second   <= !in_frame && !s_tlast;
            nbeats   <= s_tlast ? 16'd0 : nbeats + 16'd1;
        end
        u_r      <= s_tuser;
        if (rst) begin
            m_tvalid <= 1'b0;
            in_frame <= 1'b0;
            second   <= 1'b0;
            nbeats   <= '0;
        end
    end

    wire good = ok0 && ok1 && two && len_ok;
    wire last = m_tvalid && m_tlast;
    // на TLAST: плохой кадр MAC или не наш (на других beat FIFO tuser не смотрит)
    assign m_tuser = u_r || !good;

    assign ev_frame  = last;
    assign ev_bad    = last && u_r;
    assign ev_accept = last && !m_tuser;
    assign ev_ignore = last && !u_r && !good;

endmodule
