// Пачка операций с регистрами 40G-моста и кэш последнего ответа.
//
// Операции (по 16 байт, две на beat; записаны eth40_disp в ОЗУ ops и уже проверены):
//   слово 0: [31:28] код (1 запись, 2 чтение, 3 опрос), [19:0] байтовый адрес;
//   слово 1: данные записи / маска опроса; слово 2: значение опроса;
//   слово 3: таймаут опроса, такты eth_clk.
// Выполняются по одной через мастер AXI-Lite (не больше одной транзакции в полёте,
// поэтому внешний декодер окон может быть простым). Чтение и опрос дают по слову
// результата (опрос — последнее прочитанное значение). Опрос повторяет чтение, пока
// (reg & mask) != val и не прошло timeout тактов от начала операции.
// Остановка на первой ошибке: RESP != OKAY → ST_AXI, таймаут опроса → ST_TIMEOUT;
// результат неудачного чтения/опроса включается в ответ.
//
// Кэш: ключ (SEQ, IP, порт) выполненной пачки и её ответ (заголовок, результаты в ОЗУ
// res) живут до следующей пачки. eth40_disp по совпадению ключа просит отправить ответ
// повторно (replay) вместо выполнения: повтор запроса ПК (потерянный ответ) не выполняет
// запись (например, старт программы) второй раз. busy — от старта до конца отправки
// ответа: ОЗУ результатов в это время не перезаписывается.
module eth40_regx
    import eth40_pkg::*;
#(
    parameter int REGMAX = 256,
    parameter int AW     = 20
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          op_we,
    input  logic [$clog2(REGMAX/2)-1:0] op_waddr,
    input  logic [255:0]  op_wdata,
    input  logic          start,
    input  req_t          start_req,
    input  logic          replay,

    output logic          busy,
    output logic          kvalid,
    output logic [31:0]   kseq,
    output logic [31:0]   kip,
    output logic [15:0]   kport,

    // ответ (eth40_ctl_tx)
    output logic          rp_valid,
    input  logic          rp_ready,     // ответ взят на отправку
    input  logic          rp_done,      // отправка закончена (ОЗУ res прочитано)
    output req_t          rp_req,
    output logic [7:0]    rp_st,
    output logic [31:0]   rp_idx,       // операций выполнено успешно
    output logic [31:0]   rp_nres,      // слов результата
    output logic [1:0]    rp_resp,      // RESP неудачной операции
    input  logic [$clog2(REGMAX/8)-1:0] res_raddr,
    output logic [255:0]  res_rdata,

    // мастер AXI-Lite
    output logic [AW-1:0] m_awaddr,
    output logic          m_awvalid,
    input  logic          m_awready,
    output logic [31:0]   m_wdata,
    output logic [3:0]    m_wstrb,
    output logic          m_wvalid,
    input  logic          m_wready,
    input  logic [1:0]    m_bresp,
    input  logic          m_bvalid,
    output logic          m_bready,
    output logic [AW-1:0] m_araddr,
    output logic          m_arvalid,
    input  logic          m_arready,
    input  logic [31:0]   m_rdata,
    input  logic [1:0]    m_rresp,
    input  logic          m_rvalid,
    output logic          m_rready,

    output logic          ev_axi_err
);
    localparam int OAW = $clog2(REGMAX/2);
    localparam int RAW = $clog2(REGMAX/8);

    logic [255:0] ops [REGMAX/2];
    logic [255:0] res [REGMAX/8];
    logic [255:0] op_q;
    always_ff @(posedge clk) begin
        if (op_we) ops[op_waddr] <= op_wdata;
    end

    typedef enum logic [3:0] {X_IDLE, X_FETCH, X_WAIT, X_DEC, X_WR, X_B, X_AR, X_R,
                              X_FLUSH, X_REPLY, X_SEND} xstate_t;
    xstate_t xs;
    logic [31:0] n, i, tcnt, nres;
    logic [127:0] rec;
    logic [255:0] acc;
    logic [2:0]   acc_n;
    logic [RAW-1:0] res_wa;
    logic aw_done, w_done;

    wire [3:0]  opc  = rec[31:28];
    wire [31:0] mask = rec[63:32];
    wire [31:0] val  = rec[95:64];
    wire [31:0] tmo  = rec[127:96];

    always_ff @(posedge clk) begin
        op_q      <= ops[i[OAW:1]];
        res_rdata <= res[res_raddr];
    end

    assign busy     = xs != X_IDLE;
    assign rp_valid = xs == X_REPLY;
    assign m_awaddr = rec[AW-1:0];
    assign m_araddr = rec[AW-1:0];
    assign m_wdata  = rec[63:32];
    assign m_wstrb  = 4'hF;
    assign m_awvalid = xs == X_WR && !aw_done;
    assign m_wvalid  = xs == X_WR && !w_done;
    assign m_bready  = xs == X_B;
    assign m_arvalid = xs == X_AR;
    assign m_rready  = xs == X_R;

    // результат в накопитель (8 слов на beat ОЗУ): каждое чтение, кроме повторяемого
    // чтения опроса (условие не выполнено, таймаут не вышел)
    wire r_ok    = m_rresp == 2'b00;
    wire r_wait  = opc == RO_POLL && (m_rdata & mask) != val;
    wire put     = xs == X_R && m_rvalid && !(r_ok && r_wait && tcnt < tmo);
    always_ff @(posedge clk) begin
        if (xs == X_IDLE) begin
            acc_n  <= '0;
            nres   <= '0;
            res_wa <= '0;
        end else if (put) begin
            acc[32*acc_n +: 32] <= m_rdata;
            acc_n <= acc_n + 3'd1;
            nres  <= nres + 32'd1;
            if (acc_n == 3'd7) res_wa <= res_wa + 1'b1;
        end
        // в ОЗУ: полный beat — с приходом восьмого слова; неполный последний — в X_FLUSH
        if (put && acc_n == 3'd7) res[res_wa] <= {m_rdata, acc[223:0]};
        else if (xs == X_FLUSH && acc_n != 3'd0) res[res_wa] <= acc;
    end

    always_ff @(posedge clk) begin
        ev_axi_err <= 1'b0;
        case (xs)
            X_IDLE: begin
                if (start) begin
                    kvalid  <= 1'b1;
                    kseq    <= start_req.seq;
                    kip     <= start_req.src.ip;
                    kport   <= start_req.src.port;
                    rp_req  <= start_req;
                    n       <= start_req.len;
                    i       <= '0;
                    rp_st   <= ST_OK;
                    rp_resp <= 2'b00;
                    xs      <= X_FETCH;
                end else if (replay && kvalid) begin
                    xs <= X_REPLY;
                end
            end
            X_FETCH: xs <= X_WAIT;      // адрес ops — от i, данные через такт
            X_WAIT:  xs <= X_DEC;
            X_DEC: begin
                rec     <= i[0] ? op_q[255:128] : op_q[127:0];
                aw_done <= 1'b0;
                w_done  <= 1'b0;
                tcnt    <= '0;
                xs      <= (i[0] ? op_q[159:156] : op_q[31:28]) == RO_WRITE ? X_WR : X_AR;
            end
            X_WR: begin
                if (m_awvalid && m_awready) aw_done <= 1'b1;
                if (m_wvalid && m_wready)   w_done  <= 1'b1;
                if ((aw_done || m_awready) && (w_done || m_wready)) xs <= X_B;
            end
            X_B: if (m_bvalid) begin
                if (m_bresp != 2'b00) begin
                    rp_st <= ST_AXI; rp_resp <= m_bresp; ev_axi_err <= 1'b1; xs <= X_FLUSH;
                end else begin
                    i  <= i + 32'd1;
                    xs <= i + 32'd1 == n ? X_FLUSH : X_FETCH;
                end
            end
            X_AR: begin
                tcnt <= tcnt + 32'd1;
                if (m_arready) xs <= X_R;
            end
            X_R: begin
                tcnt <= tcnt + 32'd1;
                if (m_rvalid) begin
                    if (!r_ok) begin
                        rp_st <= ST_AXI; rp_resp <= m_rresp; ev_axi_err <= 1'b1; xs <= X_FLUSH;
                    end else if (r_wait) begin
                        if (tcnt >= tmo) begin
                            rp_st <= ST_TIMEOUT; xs <= X_FLUSH;
                        end else begin
                            xs <= X_AR;
                        end
                    end else begin
                        i  <= i + 32'd1;
                        xs <= i + 32'd1 == n ? X_FLUSH : X_FETCH;
                    end
                end
            end
            X_FLUSH: begin
                rp_idx  <= i;
                rp_nres <= nres;
                xs      <= X_REPLY;
            end
            X_REPLY: if (rp_ready) xs <= X_SEND;
            X_SEND:  if (rp_done) xs <= X_IDLE;
            default: xs <= X_IDLE;
        endcase
        if (rst) begin
            xs     <= X_IDLE;
            kvalid <= 1'b0;
        end
    end

endmodule
