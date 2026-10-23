// Служебные ответы 40G-моста: подтверждения записи (eth40_wr), ответы пачек регистров
// (eth40_regx, в том числе повторные из кэша) и ответы на неверные запросы
// (eth40_disp). Кадр — два beat заголовка (64 байта, не короче минимального кадра) и,
// у пачки регистров, слова результатов little-endian. Кадры — в кадровую FIFO
// служебных ответов (MAC получает кадр целиком). Приоритет: ошибки, регистры,
// подтверждения.
module eth40_ctl_tx
    import eth40_pkg::*;
#(
    parameter int REGMAX = 256
) (
    input  logic          clk,
    input  logic          rst,
    input  logic [47:0]   local_mac,
    input  logic [31:0]   local_ip,
    input  logic [15:0]   local_port,

    input  logic          er_valid,
    output logic          er_ready,
    input  req_t          er_req,
    input  logic [31:0]   er_idx,

    input  logic          rp_valid,
    output logic          rp_ready,
    output logic          rp_done,
    input  req_t          rp_req,
    input  logic [7:0]    rp_st,
    input  logic [31:0]   rp_idx,
    input  logic [31:0]   rp_nres,
    input  logic [1:0]    rp_resp,
    output logic [$clog2(REGMAX/8)-1:0] res_raddr,
    input  logic [255:0]  res_rdata,

    input  logic          ak_valid,
    output logic          ak_ready,
    input  req_t          ak_req,
    input  logic [7:0]    ak_st,

    output logic [255:0]  m_tdata,
    output logic [31:0]   m_tkeep,
    output logic          m_tvalid,
    output logic          m_tlast,
    input  logic          m_tready
);
    typedef enum logic [2:0] {C_IDLE, C_CS, C_MK, C_H0, C_H1, C_RA, C_RW, C_RD} cstate_t;
    cstate_t cs;
    logic         is_reg;
    peer_t        dst;
    logic [31:0]  seq, off, len, aux;
    logic [7:0]   op, st;
    logic [15:0]  dlen;
    logic [19:0]  ssum;                 // сумма заголовка IPv4 до свёртки (C_CS → C_MK)
    logic [17:0]  sbase;
    logic [511:0] hdr;
    logic [31:0]  nres, k;              // k — beat результатов
    logic [255:0] rbeat;

    always_ff @(posedge clk) sbase <= ip_sum_base(local_ip);

    assign er_ready = cs == C_IDLE && er_valid;
    assign rp_ready = cs == C_IDLE && !er_valid && rp_valid;
    assign ak_ready = cs == C_IDLE && !er_valid && !rp_valid && ak_valid;
    assign res_raddr = k[$clog2(REGMAX/8)-1:0];

    wire [31:0] left = nres - {k[28:0], 3'b0};          // слов результата в этом beat и дальше
    wire        rlast = left <= 32'd8;
    logic [31:0] keep_c;
    always_comb begin
        keep_c = '1;
        if (rlast) for (int b = 0; b < 32; b++) keep_c[b] = 32'(b) < {left[29:0], 2'b0};
    end

    always_comb begin
        m_tvalid = 1'b0;
        m_tlast  = 1'b0;
        m_tkeep  = '1;
        m_tdata  = hdr[255:0];
        case (cs)
            C_H0: m_tvalid = 1'b1;
            C_H1: begin m_tvalid = 1'b1; m_tdata = hdr[511:256]; m_tlast = nres == 0; end
            C_RD: begin m_tvalid = 1'b1; m_tdata = rbeat; m_tlast = rlast; m_tkeep = keep_c; end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        rp_done <= 1'b0;
        case (cs)
            C_IDLE: begin
                is_reg <= 1'b0;
                nres   <= '0;
                k      <= '0;
                if (er_valid) begin
                    dst <= er_req.src; seq <= er_req.seq; op <= er_req.op; st <= ST_BAD;
                    off <= er_req.off; len <= er_req.len; aux <= er_idx;
                    cs  <= C_CS;
                end else if (rp_valid) begin
                    is_reg <= 1'b1;
                    dst <= rp_req.src; seq <= rp_req.seq; op <= OP_REG; st <= rp_st;
                    off <= rp_idx; len <= rp_nres; aux <= {30'b0, rp_resp};
                    nres <= rp_nres;
                    cs  <= C_CS;
                end else if (ak_valid) begin
                    dst <= ak_req.src; seq <= ak_req.seq; op <= OP_WRITE; st <= ak_st;
                    off <= ak_req.off; len <= ak_req.len; aux <= {24'b0, ak_req.ch};
                    cs  <= C_CS;
                end
            end
            C_CS: begin
                dlen <= {nres[13:0], 2'b0};
                ssum <= 20'(sbase) + 16'(16'(20 + 8 + PHDR) + {nres[13:0], 2'b0})
                        + dst.ip[31:16] + dst.ip[15:0];
                cs   <= C_MK;
            end
            C_MK: begin
                hdr <= resp_hdr(dst, local_mac, local_ip, local_port, ip_csum_fin(ssum), dlen,
                                seq, op, st, off, len, aux);
                cs  <= C_H0;
            end
            C_H0: if (m_tready) cs <= C_H1;
            C_H1: if (m_tready) begin
                if (nres == 0) begin
                    cs <= C_IDLE;
                    if (is_reg) rp_done <= 1'b1;
                end else cs <= C_RA;
            end
            C_RA: cs <= C_RW;           // адрес ОЗУ результатов — k
            C_RW: begin rbeat <= res_rdata; cs <= C_RD; end
            C_RD: if (m_tready) begin
                k <= k + 32'd1;
                if (rlast) begin cs <= C_IDLE; rp_done <= 1'b1; end
                else cs <= C_RA;
            end
            default: cs <= C_IDLE;
        endcase
        if (rst) cs <= C_IDLE;
    end

endmodule
