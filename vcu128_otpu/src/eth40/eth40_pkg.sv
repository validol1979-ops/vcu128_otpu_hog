// Константы и функции протокола 40G-моста (doc/eth40_protocol.md).
//
// Кадр Ethernet II + IPv4 (без опций) + UDP: заголовки 42 байта, затем заголовок
// протокола 22 байта, так что данные (запись/чтение памяти, операции регистров,
// результаты) начинаются ровно с байта 64 — с третьего 256-битного beat AXIS.
// Байт n кадра — tdata[8*(n%32) +: 8] beat n/32. Поля Ethernet/IP/UDP — сетевой
// порядок (big-endian), поля протокола — little-endian.
package eth40_pkg;

    localparam logic [31:0] MAGIC_REQ  = 32'h3034_544F;   // байты "OT40"
    localparam logic [31:0] MAGIC_RESP = 32'h5234_544F;   // байты "OT4R"

    // OP
    localparam logic [7:0] OP_WRITE = 8'd1;     // запись памяти
    localparam logic [7:0] OP_READ  = 8'd2;     // чтение памяти
    localparam logic [7:0] OP_REG   = 8'd3;     // пачка операций с регистрами

    // STATUS ответа
    localparam logic [7:0] ST_OK      = 8'd0;
    localparam logic [7:0] ST_AXI     = 8'd1;   // SLVERR/DECERR на AXI-Lite
    localparam logic [7:0] ST_BAD     = 8'd2;   // неверный запрос, ничего не выполнено
    localparam logic [7:0] ST_TIMEOUT = 8'd3;   // опрос регистра не дождался условия

    // операции регистров (биты 31:28 слова 0 записи операции)
    localparam logic [3:0] RO_WRITE = 4'd1;
    localparam logic [3:0] RO_READ  = 4'd2;
    localparam logic [3:0] RO_POLL  = 4'd3;

    localparam int HDR_BYTES = 64;              // Ethernet+IPv4+UDP+заголовок протокола
    localparam int PHDR      = 22;              // заголовок протокола

    typedef struct packed {
        logic [47:0] mac;
        logic [31:0] ip;
        logic [15:0] port;
    } peer_t;

    // байт n 512-битного окна (beat 0 и 1)
    function automatic logic [7:0] b8(input logic [511:0] w, input int n);
        return w[8*n +: 8];
    endfunction

    function automatic logic [15:0] be16(input logic [511:0] w, input int n);
        return {w[8*n +: 8], w[8*(n+1) +: 8]};
    endfunction

    function automatic logic [31:0] be32(input logic [511:0] w, input int n);
        return {w[8*n +: 8], w[8*(n+1) +: 8], w[8*(n+2) +: 8], w[8*(n+3) +: 8]};
    endfunction

    function automatic logic [31:0] le32(input logic [511:0] w, input int n);
        return w[8*n +: 32];
    endfunction

    function automatic logic [47:0] be48(input logic [511:0] w, input int n);
        return {w[8*n +: 8], w[8*(n+1) +: 8], w[8*(n+2) +: 8],
                w[8*(n+3) +: 8], w[8*(n+4) +: 8], w[8*(n+5) +: 8]};
    endfunction

    // заголовок запроса из beat 0 и 1
    typedef struct packed {
        peer_t       src;       // MAC/IP/порт источника — адрес ответа
        logic [15:0] udp_len;
        logic [31:0] seq;
        logic [7:0]  op;
        logic [7:0]  ch;
        logic [31:0] off;
        logic [31:0] len;
        logic [31:0] aux;
    } req_t;

    function automatic req_t parse_req(input logic [511:0] w);
        req_t r;
        r.src.mac  = be48(w, 6);
        r.src.ip   = be32(w, 26);
        r.src.port = be16(w, 34);
        r.udp_len  = be16(w, 38);
        r.seq      = le32(w, 46);
        r.op       = b8(w, 50);
        r.ch       = b8(w, 51);
        r.off      = le32(w, 52);
        r.len      = le32(w, 56);
        r.aux      = le32(w, 60);
        return r;
    endfunction

    // Неизменная часть суммы заголовка IPv4 ответа: 0x4500, ID 0, флаги DF,
    // TTL 64 / UDP, адрес источника. Плюс длина и адрес назначения — в ip_csum.
    function automatic logic [17:0] ip_sum_base(input logic [31:0] sip);
        return 18'h04500 + 18'h04000 + 18'h04011 + sip[31:16] + sip[15:0];
    endfunction

    function automatic logic [15:0] ip_csum(input logic [17:0] base, input logic [15:0] tot,
                                            input logic [31:0] dip);
        return ip_csum_fin(20'(base) + tot + dip[31:16] + dip[15:0]);
    endfunction

    // Свёртка 20-битной суммы в контрольную сумму. Сумма не переполняется: base < 2^18 плюс
    // три слагаемых < 2^16, поэтому её можно копить по частям в разных тактах (тайминг 40G).
    function automatic logic [15:0] ip_csum_fin(input logic [19:0] s0);
        logic [19:0] s;
        s = 20'(s0[15:0]) + s0[19:16];
        s = 20'(s[15:0]) + s[19:16];
        return ~s[15:0];
    endfunction

    // Два первых beat ответа (64 байта): Ethernet, IPv4, UDP (контрольная сумма 0),
    // заголовок протокола. dlen — байты после заголовка (данные/результаты).
    function automatic logic [511:0] resp_hdr(
        input peer_t dst, input logic [47:0] smac, input logic [31:0] sip,
        input logic [15:0] sport, input logic [15:0] csum, input logic [15:0] dlen,
        input logic [31:0] seq, input logic [7:0] op, input logic [7:0] st,
        input logic [31:0] off, input logic [31:0] len, input logic [31:0] aux);
        logic [511:0] w;
        logic [15:0]  tot, ulen;
        tot  = 16'(20 + 8 + PHDR) + dlen;
        ulen = 16'(8 + PHDR) + dlen;
        w = '0;
        for (int k = 0; k < 6; k++) begin
            w[8*k +: 8]     = dst.mac[8*(5-k) +: 8];
            w[8*(6+k) +: 8] = smac[8*(5-k) +: 8];
        end
        w[8*12 +: 8] = 8'h08; w[8*13 +: 8] = 8'h00;           // IPv4
        w[8*14 +: 8] = 8'h45;
        w[8*16 +: 8] = tot[15:8]; w[8*17 +: 8] = tot[7:0];
        w[8*20 +: 8] = 8'h40;                                 // DF
        w[8*22 +: 8] = 8'd64;  w[8*23 +: 8] = 8'd17;          // TTL, UDP
        w[8*24 +: 8] = csum[15:8]; w[8*25 +: 8] = csum[7:0];
        for (int k = 0; k < 4; k++) begin
            w[8*(26+k) +: 8] = sip[8*(3-k) +: 8];
            w[8*(30+k) +: 8] = dst.ip[8*(3-k) +: 8];
        end
        w[8*34 +: 8] = sport[15:8];    w[8*35 +: 8] = sport[7:0];
        w[8*36 +: 8] = dst.port[15:8]; w[8*37 +: 8] = dst.port[7:0];
        w[8*38 +: 8] = ulen[15:8];     w[8*39 +: 8] = ulen[7:0];
        w[8*42 +: 32] = MAGIC_RESP;
        w[8*46 +: 32] = seq;
        w[8*50 +: 8]  = op;
        w[8*51 +: 8]  = st;
        w[8*52 +: 32] = off;
        w[8*56 +: 32] = len;
        w[8*60 +: 32] = aux;
        return w;
    endfunction

endpackage
