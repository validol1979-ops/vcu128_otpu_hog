// Чтение памяти 40G-моста: запрос диапазона → поток ответных кадров.
//
// Дескрипторы (eth40_disp) идут в очередь; сторона AR выдаёт пачки всего диапазона
// (границы 4 КиБ, до 256 beat по 16 байт) и передаёт дескриптор стороне R; сторона R
// режет данные на кадры по FSZ байт (последний короче): два beat заголовка (SEQ запроса,
// OFFSET — смещение данных кадра в канале, LEN — их длина, AUX — начало запроса), затем
// данные, по два beat R на beat AXIS. Кадры пишутся в кадровую FIFO передачи данных,
// MAC получает кадр только целиком. R (16 байт/такт) — узкое место, 2,5 ГБ/с на канал
// при 156,25 МГц; пока пишется заголовок (2 такта на кадр), R ждёт.
// RRESP с ошибкой (otpu_mem_ch всегда даёт OKAY) кадр не портит: только ev_axi_err.
module eth40_rd
    import eth40_pkg::*;
#(
    parameter int NC   = 2,
    parameter int MAXW = 8192
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [47:0]   local_mac,
    input  logic [31:0]   local_ip,
    input  logic [15:0]   local_port,

    input  logic          rd_valid,
    output logic          rd_ready,
    input  req_t          rd_req,

    output logic [NC-1:0]        x_arvalid,
    input  logic [NC-1:0]        x_arready,
    output logic [NC-1:0][30:0]  x_araddr,
    output logic [NC-1:0][7:0]   x_arlen,
    input  logic [NC-1:0]        x_rvalid,
    output logic [NC-1:0]        x_rready,
    input  logic [NC-1:0][127:0] x_rdata,
    input  logic [NC-1:0][1:0]   x_rresp,
    input  logic [NC-1:0]        x_rlast,

    output logic [255:0]  m_tdata,
    output logic [31:0]   m_tkeep,
    output logic          m_tvalid,
    output logic          m_tlast,
    input  logic          m_tready,

    output logic          ev_frame,     // импульс: кадр данных записан в FIFO
    output logic          ev_axi_err,
    output logic          busy
);
    localparam int CW = $clog2(NC > 1 ? NC : 2);
    localparam int RW = $bits(req_t);

    // ---------------------------------------------------------------- AR
    logic q1_v, q1_r, q2_w, q2_v, q2_r;
    req_t q1, q2;
    eth40_fifo #(.W(RW), .DEPTH(4)) u_q1 (.clk, .rst, .wvalid(rd_valid), .wready(rd_ready),
        .wdata(rd_req), .rvalid(q1_v), .rready(q1_r), .rdata(q1));
    eth40_fifo #(.W(RW), .DEPTH(4)) u_q2 (.clk, .rst, .wvalid(q1_v && q1_r), .wready(q2_w),
        .wdata(q1), .rvalid(q2_v), .rready(q2_r), .rdata(q2));

    logic        ar_act;
    logic [26:0] ar_a;
    logic [27:0] ar_rem;
    logic [7:0]  ar_ch;
    wire  [8:0]  to4k = 9'd256 - {1'b0, ar_a[7:0]};
    wire  [8:0]  ar_n = 28'(to4k) < ar_rem ? to4k : ar_rem[8:0];
    wire         ar_fire = ar_act && x_arready[ar_ch[CW-1:0]];
    assign q1_r = !ar_act && q2_w;
    always_ff @(posedge clk) begin
        if (q1_v && q1_r) begin
            ar_act <= 1'b1;
            ar_a   <= q1.off[30:4];
            ar_rem <= q1.len[31:4];
            ar_ch  <= q1.ch;
        end
        if (ar_fire) begin
            ar_a   <= ar_a + 27'(ar_n);
            ar_rem <= ar_rem - 28'(ar_n);
            if (ar_rem == 28'(ar_n)) ar_act <= 1'b0;
        end
        if (rst) ar_act <= 1'b0;
    end
    for (genvar j = 0; j < NC; j++) begin : g_ar
        assign x_arvalid[j] = ar_act && ar_ch == 8'(j);
        assign x_araddr[j]  = {ar_a, 4'b0};
        assign x_arlen[j]   = 8'(ar_n - 9'd1);
    end

    // ---------------------------------------------------------------- R → кадры
    typedef enum logic [2:0] {R_IDLE, R_PREP, R_HDR, R_MK, R_H0, R_H1, R_DATA} rstate_t;
    rstate_t     rs;
    logic [31:0] r_off, r_rem, r_flen, fsz;
    logic [27:0] r_beats;               // beat AXIS данных кадра осталось
    logic [17:0] sbase;
    logic [19:0] ssum;                  // sbase + адрес назначения (такт R_PREP)
    logic [15:0] csum;
    logic [511:0] hdr;
    logic [127:0] lo;
    logic        half;

    always_ff @(posedge clk) sbase <= ip_sum_base(local_ip);

    wire [7:0]  ch  = q2.ch;
    wire        rv  = x_rvalid[ch[CW-1:0]];
    wire [127:0] rd = x_rdata[ch[CW-1:0]];
    wire        rdat = rs == R_DATA;
    // R принимается: младшая половина — всегда, старшая — вместе с записью beat AXIS
    for (genvar j = 0; j < NC; j++) begin : g_r
        assign x_rready[j] = rdat && ch == 8'(j) && (!half || m_tready);
    end
    assign q2_r = rs == R_DATA && rv && half && m_tready && r_beats == 28'd1 && r_rem == r_flen;

    always_comb begin
        m_tvalid = 1'b0;
        m_tlast  = 1'b0;
        m_tkeep  = '1;
        m_tdata  = {rd, lo};
        case (rs)
            R_H0: begin m_tvalid = 1'b1; m_tdata = hdr[255:0]; end
            R_H1: begin m_tvalid = 1'b1; m_tdata = hdr[511:256]; end
            R_DATA: begin m_tvalid = rv && half; m_tlast = r_beats == 28'd1; end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        ev_frame   <= 1'b0;
        ev_axi_err <= 1'b0;
        case (rs)
            R_IDLE: if (q2_v) begin
                r_off <= q2.off;
                r_rem <= q2.len;
                fsz   <= q2.aux == 0 ? 32'(MAXW) : q2.aux;
                rs    <= R_PREP;
            end
            R_PREP: begin
                r_flen <= r_rem < fsz ? r_rem : fsz;
                ssum   <= 20'(sbase) + q2.src.ip[31:16] + q2.src.ip[15:0];
                rs     <= R_HDR;
            end
            R_HDR: begin
                csum <= ip_csum_fin(ssum + 16'(16'(20 + 8 + PHDR) + r_flen[15:0]));
                rs   <= R_MK;
            end
            R_MK: begin
                hdr <= resp_hdr(q2.src, local_mac, local_ip, local_port, csum, r_flen[15:0],
                                q2.seq, OP_READ, ST_OK, r_off, r_flen, q2.off);
                rs  <= R_H0;
            end
            R_H0: if (m_tready) rs <= R_H1;
            default: ;
        endcase
        if (rs == R_H1 && m_tready) begin
            rs      <= R_DATA;
            half    <= 1'b0;
            r_beats <= r_flen[31:5];
        end
        if (rs == R_DATA && rv) begin
            if (x_rresp[ch[CW-1:0]] != 2'b00) ev_axi_err <= 1'b1;
            if (!half) begin
                lo   <= rd;
                half <= 1'b1;
            end else if (m_tready) begin
                half    <= 1'b0;
                r_beats <= r_beats - 28'd1;
                if (r_beats == 28'd1) begin
                    ev_frame <= 1'b1;
                    r_off    <= r_off + r_flen;
                    r_rem    <= r_rem - r_flen;
                    rs       <= r_rem == r_flen ? R_IDLE : R_PREP;
                end
            end
        end
        if (rst) rs <= R_IDLE;
    end

    assign busy = q1_v || q2_v || ar_act || rs != R_IDLE;

endmodule
