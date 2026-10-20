// Запись памяти 40G-моста: адреса AW, раздача W по каналам, приём B и подтверждения.
//
// Порты DMA — в формате стороны XDMA upstream `otpu_bcu_sys` / `otpu_mem_ch` (x_*):
// 128 бит, адрес — байтовое смещение в канале (2 ГиБ, 31 бит), INCR из полных
// 16-байтных beat (AxSIZE 4), без ID. Запросы — целые 64-байтные beat с выровненного
// адреса (eth40_disp), поэтому частичных beat (и read-modify-write в otpu_mem_ch) нет.
// Пачки режутся на границах 4 КиБ (не более 256 beat). AW выдаются независимо от W
// (otpu_mem_ch принимает W только после своего AW), очередь AW опережает данные.
//
// Подтверждение запроса уходит, когда получены B всех его пачек (otpu_mem_ch даёт B
// только после того, как контроллер принял все beat пачки). Запросы подтверждаются по
// порядку приёма; B одного канала приходят по порядку его пачек, поэтому счётчика B на
// канал достаточно. Ответ B с ошибкой (otpu_mem_ch всегда даёт OKAY) отмечает
// STATUS = ST_AXI у подтверждения, которое забирает эти B (точно — до запроса).
module eth40_wr
    import eth40_pkg::*;
#(
    parameter int NC = 2,
    parameter int AQ = 32               // подтверждений в ожидании B
) (
    input  logic          clk,
    input  logic          rst,

    // от eth40_disp
    input  logic          wd_valid,
    output logic          wd_ready,
    input  logic [7:0]    wd_ch,
    input  logic [30:0]   wd_off,
    input  logic [31:0]   wd_len,
    output logic          aq_ready,
    input  req_t          wd_req,
    input  logic [3:0]    wd_nb,
    input  logic          w_valid,
    output logic          w_ready,
    input  logic [7:0]    w_ch,
    input  logic [127:0]  w_data,
    input  logic          w_last,

    // DMA, по каналу
    output logic [NC-1:0]        x_awvalid,
    input  logic [NC-1:0]        x_awready,
    output logic [NC-1:0][30:0]  x_awaddr,
    output logic [NC-1:0][7:0]   x_awlen,
    output logic [NC-1:0]        x_wvalid,
    input  logic [NC-1:0]        x_wready,
    output logic [NC-1:0][127:0] x_wdata,
    output logic [NC-1:0][15:0]  x_wstrb,
    output logic [NC-1:0]        x_wlast,
    input  logic [NC-1:0]        x_bvalid,
    output logic [NC-1:0]        x_bready,
    input  logic [NC-1:0][1:0]   x_bresp,

    // подтверждение (eth40_ctl_tx)
    output logic          ak_valid,
    input  logic          ak_ready,
    output req_t          ak_req,
    output logic [7:0]    ak_st,

    output logic          ev_axi_err,
    output logic          busy          // есть запись в работе
);

    // ---------------------------------------------------------------- AW
    logic        ad_v, ad_r;
    logic [7:0]  ad_ch;
    logic [30:0] ad_off;
    logic [31:0] ad_len;
    logic        wd_fire;
    assign wd_fire = wd_valid && wd_ready;

    logic ad_wr;
    eth40_fifo #(.W(8 + 31 + 32), .DEPTH(4)) u_ad (
        .clk, .rst, .wvalid(wd_fire), .wready(ad_wr), .wdata({wd_ch, wd_off, wd_len}),
        .rvalid(ad_v), .rready(ad_r), .rdata({ad_ch, ad_off, ad_len}));

    logic        aw_act;
    logic [26:0] aw_a;                  // адрес, 16 байт
    logic [27:0] aw_rem;                // beat осталось
    logic [7:0]  aw_ch;
    wire  [8:0]  to4k = 9'd256 - {1'b0, aw_a[7:0]};
    wire  [8:0]  aw_n = 28'(to4k) < aw_rem ? to4k : aw_rem[8:0];
    wire         aw_fire = aw_act && x_awready[aw_ch[$clog2(NC > 1 ? NC : 2)-1:0]];

    assign ad_r = !aw_act;
    always_ff @(posedge clk) begin
        if (!aw_act && ad_v) begin
            aw_act <= 1'b1;
            aw_a   <= ad_off[30:4];
            aw_rem <= ad_len[31:4];
            aw_ch  <= ad_ch;
        end
        if (aw_fire) begin
            aw_a   <= aw_a + 27'(aw_n);
            aw_rem <= aw_rem - 28'(aw_n);
            if (aw_rem == 28'(aw_n)) aw_act <= 1'b0;
        end
        if (rst) aw_act <= 1'b0;
    end

    for (genvar j = 0; j < NC; j++) begin : g_ch
        assign x_awvalid[j] = aw_act && aw_ch == 8'(j);
        assign x_awaddr[j]  = {aw_a, 4'b0};
        assign x_awlen[j]   = 8'(aw_n - 9'd1);
        assign x_wvalid[j]  = w_valid && w_ch == 8'(j);
        assign x_wdata[j]   = w_data;
        assign x_wstrb[j]   = 16'hFFFF;
        assign x_wlast[j]   = w_last;
        assign x_bready[j]  = 1'b1;
    end
    assign w_ready = x_wready[w_ch[$clog2(NC > 1 ? NC : 2)-1:0]];

    // ---------------------------------------------------------------- B и подтверждения
    localparam int RW = $bits(req_t);
    logic       aq_v, aq_r;
    req_t       aq_q;
    logic [3:0] aq_nb;
    eth40_fifo #(.W(RW + 4), .DEPTH(AQ)) u_aq (
        .clk, .rst, .wvalid(wd_fire), .wready(aq_ready), .wdata({wd_req, wd_nb}),
        .rvalid(aq_v), .rready(aq_r), .rdata({aq_q, aq_nb}));
    assign wd_ready = ad_wr && aq_ready;

    logic [NC-1:0][9:0] bcnt, ecnt;     // B (с ошибкой) получены и не забраны
    wire  [7:0] hc = aq_q.ch;
    wire        done = aq_v && bcnt[hc[$clog2(NC > 1 ? NC : 2)-1:0]] >= 10'(aq_nb);
    assign aq_r = done && (!ak_valid || ak_ready);

    // счётчики B на следующий такт: + принятые, − забранные головой очереди
    logic [NC-1:0][9:0] bcnt_n, ecnt_n;
    always_comb begin
        for (int j = 0; j < NC; j++) begin
            bcnt_n[j] = bcnt[j];
            ecnt_n[j] = ecnt[j];
            if (aq_r && hc == 8'(j)) begin
                bcnt_n[j] = bcnt_n[j] - 10'(aq_nb);
                ecnt_n[j] = ecnt_n[j] > 10'(aq_nb) ? ecnt_n[j] - 10'(aq_nb) : 10'd0;
            end
            if (x_bvalid[j]) begin
                bcnt_n[j] = bcnt_n[j] + 10'd1;
                if (x_bresp[j] != 2'b00) ecnt_n[j] = ecnt_n[j] + 10'd1;
            end
        end
    end

    always_ff @(posedge clk) begin
        ev_axi_err <= |(x_bvalid & bresp_err(x_bresp));
        if (ak_valid && ak_ready) ak_valid <= 1'b0;
        bcnt <= bcnt_n;
        ecnt <= ecnt_n;
        if (aq_r) begin
            ak_valid <= 1'b1;
            ak_req   <= aq_q;
            ak_st    <= ecnt[hc[$clog2(NC > 1 ? NC : 2)-1:0]] != 0 ? ST_AXI : ST_OK;
        end
        if (rst) begin
            ak_valid <= 1'b0;
            bcnt     <= '0;
            ecnt     <= '0;
        end
    end

    function automatic logic [NC-1:0] bresp_err(input logic [NC-1:0][1:0] r);
        logic [NC-1:0] e;
        for (int j = 0; j < NC; j++) e[j] = r[j] != 2'b00;
        return e;
    endfunction

    assign busy = aq_v || aw_act || ad_v || w_valid;

endmodule
