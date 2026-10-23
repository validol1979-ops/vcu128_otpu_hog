// Разборщик запросов 40G-моста: берёт принятые кадры из кадровой FIFO приёма
// (только запросы протокола этой плате, eth40_rx_filter) и раздаёт их:
//
// - запись памяти: проверка, дескриптор пачек AW (eth40_wr), запись в очередь
//   подтверждений (eth40_wr), данные кадра — в канал W через «редуктор» 256 → 128 бит
//   (поток FIFO читается через такт: W 16 байт/такт);
// - чтение памяти: проверка, дескриптор в очередь чтения (eth40_rd);
// - пачка регистров: проверка, сверка с ключом кэша ответа (eth40_regx): повтор
//   последнего запроса (тот же SEQ, IP и порт) — повторная отправка сохранённого ответа
//   без выполнения; иначе операции копируются в ОЗУ eth40_regx и проверяются по ходу
//   копирования, при ошибке формата ничего не выполняется;
// - неверный запрос — ответ STATUS = ST_BAD (eth40_ctl_tx).
// Хвост кадра (выравнивание, FCS) дочитывается до TLAST.
module eth40_disp
    import eth40_pkg::*;
#(
    parameter int NC     = 2,
    parameter int MAXW   = 8192,        // байт данных записи в кадре, не больше
    parameter int REGMAX = 256          // операций в пачке регистров, не больше
) (
    input  logic          clk,
    input  logic          rst,

    // кадровая FIFO приёма
    input  logic [255:0]  s_tdata,
    input  logic          s_tvalid,
    input  logic          s_tlast,
    output logic          s_tready,

    // запись: дескриптор пачек AW (канал, смещение, длина)
    output logic          wd_valid,
    input  logic          wd_ready,
    output logic [7:0]    wd_ch,
    output logic [30:0]   wd_off,
    output logic [31:0]   wd_len,
    // запись: элемент очереди подтверждений (принимается вместе с wd)
    input  logic          aq_ready,
    output req_t          wd_req,
    output logic [3:0]    wd_nb,        // число пачек AXI (границы 4 КиБ)
    // данные W (канал w_ch)
    output logic          w_valid,
    input  logic          w_ready,
    output logic [7:0]    w_ch,
    output logic [127:0]  w_data,
    output logic          w_last,

    // чтение: дескриптор
    output logic          rd_valid,
    input  logic          rd_ready,
    output req_t          rd_req,

    // регистры
    input  logic          rx_busy,      // выполняет пачку или отправляет её ответ
    input  logic          rx_kvalid,
    input  logic [31:0]   rx_kseq,
    input  logic [31:0]   rx_kip,
    input  logic [15:0]   rx_kport,
    output logic          rx_replay,    // импульс: отправить сохранённый ответ ещё раз
    output logic          rx_we,        // запись beat операций в ОЗУ
    output logic [$clog2(REGMAX/2)-1:0] rx_waddr,
    output logic [255:0]  rx_wdata,
    output logic          rx_start,     // импульс: выполнить (вместе с rx_req)
    output req_t          rx_req,

    // ответ об ошибке формата
    output logic          er_valid,
    input  logic          er_ready,
    output req_t          er_req,
    output logic [31:0]   er_idx,       // номер неверной операции пачки (иначе 0)

    output logic          ev_write, ev_read, ev_reg, ev_dup, ev_busy, ev_bad
);

    typedef enum logic [2:0] {S_H0, S_H1, S_DEC, S_WDATA, S_RLOAD, S_RCHK, S_DRAIN, S_ERR}
        state_t;
    state_t st;

    logic [255:0] h0;
    req_t         q;
    logic         fe;                   // TLAST кадра уже прочитан
    logic [31:0]  bad_idx;

    // проверки (по зарегистрированному заголовку q)
    wire [32:0] end_c  = {1'b0, q.off} + {1'b0, q.len};
    wire ch_ok   = q.ch < 8'(NC);
    wire rng_ok  = q.off[5:0] == 6'd0 && q.len[5:0] == 6'd0 && q.len != 0 &&
                   end_c <= 33'h0_8000_0000;
    wire w_ok    = ch_ok && rng_ok && q.len <= 32'(MAXW) &&
                   32'(q.udp_len) == 32'(8 + PHDR) + q.len;
    wire [31:0] fsz = q.aux == 0 ? 32'(MAXW) : q.aux;
    wire r_ok    = ch_ok && rng_ok && fsz[5:0] == 6'd0 && fsz != 0 && fsz <= 32'(MAXW);
    wire g_ok    = q.len != 0 && q.len <= 32'(REGMAX) &&
                   32'(q.udp_len) == 32'(8 + PHDR) + {q.len[27:0], 4'b0};
    wire k_hit   = rx_kvalid && rx_kseq == q.seq && rx_kip == q.src.ip &&
                   rx_kport == q.src.port;
    wire [3:0] nb_c = 4'((end_c[31:0] - 32'd1) >> 12) - 4'(q.off >> 12) + 4'd1;

    // проверки -- из триггеров (тайминг 40G: q.len -> w_ok -> wd_valid -> WE очереди u_aq
    // в eth40_wr было 9 уровней логики, −0,09 нс при 312,5 МГц): q меняется только при
    // переходе S_H1 -> S_DEC, поэтому S_DEC решает со второго такта (dec_go), когда
    // *_q уже посчитаны по новому q
    logic       w_ok_q, r_ok_q, g_ok_q, dec_go;
    logic [3:0] nb_q;
    always_ff @(posedge clk) begin
        w_ok_q <= w_ok;
        r_ok_q <= r_ok;
        g_ok_q <= g_ok;
        nb_q   <= nb_c;
        dec_go <= st == S_DEC;
    end

    // редуктор W: beat 256 бит, младшая половина первой
    logic [255:0] wb;
    logic         wb_v, wb_h, wb_l0, wb_l1;
    logic [7:0]   wb_ch;
    logic [26:0]  la;                   // адрес следующей загружаемой половины, 16 байт
    logic [27:0]  lrem;                 // половин осталось загрузить
    assign w_valid = wb_v;
    assign w_data  = wb_h ? wb[255:128] : wb[127:0];
    assign w_last  = wb_h ? wb_l1 : wb_l0;
    assign w_ch    = wb_ch;
    wire w_fire = w_valid && w_ready;
    wire wb_free = !wb_v || (w_fire && wb_h);
    wire w_load  = st == S_WDATA && s_tvalid && wb_free;
    wire [26:0] la1 = la + 27'd1;

    // операции пачки в принятом beat
    logic [$clog2(REGMAX/2):0] rbeat;   // beat операций загружено
    function automatic logic op_ok(input logic [127:0] r);
        return (r[31:28] == RO_WRITE || r[31:28] == RO_READ || r[31:28] == RO_POLL) &&
               r[27:20] == 8'd0 && r[1:0] == 2'b00;
    endfunction
    wire [31:0] i0 = {rbeat, 1'b0};
    wire op0_bad = !op_ok(s_tdata[127:0]);
    wire op1_bad = i0 + 32'd1 < q.len && !op_ok(s_tdata[255:128]);
    wire r_last  = i0 + 32'd2 >= q.len;

    always_comb begin
        s_tready = 1'b0;
        case (st)
            S_H0, S_H1: s_tready = 1'b1;
            S_DRAIN: s_tready = !fe;
            S_WDATA: s_tready = wb_free;
            S_RLOAD: s_tready = 1'b1;
            default: s_tready = 1'b0;
        endcase
    end
    wire s_fire = s_tvalid && s_tready;

    assign rx_we    = st == S_RLOAD && s_tvalid;
    assign rx_waddr = rbeat[$clog2(REGMAX/2)-1:0];
    assign rx_wdata = s_tdata;
    assign wd_req   = q;
    assign rd_req   = q;
    assign rx_req   = q;
    assign er_req   = q;
    assign er_idx   = bad_idx;
    assign wd_ch    = q.ch;
    assign wd_off   = q.off[30:0];
    assign wd_len   = q.len;
    assign wd_nb    = nb_q;

    always_comb begin
        wd_valid = 1'b0;
        rd_valid = 1'b0;
        if (st == S_DEC && dec_go) begin
            if (q.op == OP_WRITE && w_ok_q) wd_valid = aq_ready;
            if (q.op == OP_READ && r_ok_q)  rd_valid = 1'b1;
        end
    end
    assign er_valid = st == S_ERR;

    always_ff @(posedge clk) begin
        {ev_write, ev_read, ev_reg, ev_dup, ev_busy, ev_bad} <= '0;
        rx_replay <= 1'b0;
        rx_start  <= 1'b0;
        if (s_fire) fe <= s_tlast;
        if (w_fire && wb_h) wb_v <= 1'b0;
        if (w_fire) wb_h <= !wb_h;
        if (w_load) begin
            wb    <= s_tdata;
            wb_v  <= 1'b1;
            wb_h  <= 1'b0;
            wb_ch <= q.ch;
            wb_l0 <= la[7:0] == 8'hFF || lrem == 28'd1;
            wb_l1 <= la1[7:0] == 8'hFF || lrem == 28'd2;
            la    <= la + 27'd2;
            lrem  <= lrem - 28'd2;
        end
        case (st)
            S_H0: if (s_fire) begin
                h0 <= s_tdata;
                if (!s_tlast) st <= S_H1;     // кадр в один beat фильтр не пропускает
            end
            S_H1: if (s_fire) begin
                q  <= parse_req({s_tdata, h0});
                st <= S_DEC;
            end
            S_DEC: if (dec_go) begin
                bad_idx <= '0;
                case (q.op)
                    OP_WRITE:
                        if (!w_ok_q) st <= S_ERR;
                        else if (wd_valid && wd_ready) begin
                            ev_write <= 1'b1;
                            la       <= q.off[30:4];
                            lrem     <= q.len[31:4];
                            st       <= S_WDATA;
                        end
                    OP_READ:
                        if (!r_ok_q) st <= S_ERR;
                        else if (rd_ready) begin ev_read <= 1'b1; st <= S_DRAIN; end
                    OP_REG:
                        if (!g_ok_q) st <= S_ERR;
                        else if (k_hit) begin
                            // повтор: ответ ещё отправляется или выполняется — его и дождётся ПК
                            if (!rx_busy) begin rx_replay <= 1'b1; ev_dup <= 1'b1; end
                            else ev_busy <= 1'b1;
                            st <= S_DRAIN;
                        end else if (rx_busy) begin
                            ev_busy <= 1'b1;
                            st      <= S_DRAIN;
                        end else begin
                            rbeat <= '0;
                            st    <= S_RLOAD;
                        end
                    default: st <= S_ERR;
                endcase
            end
            S_WDATA: if (w_load && lrem == 28'd2) st <= S_DRAIN;
            S_RLOAD: if (s_fire) begin
                rbeat <= rbeat + 1'b1;
                if (op0_bad || op1_bad) begin
                    bad_idx <= op0_bad ? i0 : i0 + 32'd1;
                    st      <= S_ERR;
                end else if (r_last) begin
                    st <= S_RCHK;
                end
            end
            S_RCHK: begin
                rx_start <= 1'b1;
                ev_reg   <= 1'b1;
                st       <= S_DRAIN;
            end
            S_ERR: if (er_ready) begin
                ev_bad <= 1'b1;
                st     <= S_DRAIN;
            end
            S_DRAIN: ;
            default: st <= S_H0;
        endcase
        // конец кадра: в DRAIN после TLAST (или если TLAST уже был) — к следующему
        if (st == S_DRAIN && (fe || (s_fire && s_tlast))) st <= S_H0;
        if (rst) begin
            st   <= S_H0;
            fe   <= 1'b0;
            wb_v <= 1'b0;
            wb_h <= 1'b0;
        end
    end

endmodule
