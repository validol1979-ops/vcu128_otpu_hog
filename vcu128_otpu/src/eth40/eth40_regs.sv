// Регистры 40G-моста (окно 0x50000 карты регистров, домен eth_clk): MAC/IP/порт
// платы, состояние линка и моста, счётчики событий. Карта — doc/eth40_protocol.md,
// раздел «Регистры eth40_regs». AXI-Lite slave, одна транзакция за раз; адрес — байтовый
// внутри окна (младшие AW бит), выравнивание на 4. Нет такого регистра — 0, OKAY.
// Счётчики 32-битные, с переполнением, сбрасываются записью CTRL[0] = 1.
module eth40_regs #(
    parameter int          AW        = 8,
    parameter int          NEV       = 17,
    parameter logic [47:0] MAC       = 48'h02_00_5E_41_00_01,
    parameter logic [31:0] IP        = 32'hC0A8_2902,      // 192.168.41.2
    parameter logic [15:0] UDP_PORT  = 16'h4F54,           // 20308
    parameter logic [31:0] PARAMS    = 32'h0                // NC и размеры (от верхнего уровня)
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [AW-1:0] s_awaddr,
    input  logic          s_awvalid,
    output logic          s_awready,
    input  logic [31:0]   s_wdata,
    input  logic [3:0]    s_wstrb,
    input  logic          s_wvalid,
    output logic          s_wready,
    output logic [1:0]    s_bresp,
    output logic          s_bvalid,
    input  logic          s_bready,
    input  logic [AW-1:0] s_araddr,
    input  logic          s_arvalid,
    output logic          s_arready,
    output logic [31:0]   s_rdata,
    output logic [1:0]    s_rresp,
    output logic          s_rvalid,
    input  logic          s_rready,

    output logic [47:0]   local_mac,
    output logic [31:0]   local_ip,
    output logic [15:0]   local_port,

    input  logic [31:0]   link_stat,    // состояние l_ethernet, синхронизировано снаружи
    input  logic [31:0]   bridge_stat,  // otpu_eth_bridge.status
    input  logic [NEV-1:0] ev           // импульсы событий otpu_eth_bridge
);
    localparam logic [31:0] ID      = 32'h3034_5445;   // байты "ET40"
    localparam logic [31:0] VERSION = 32'h0000_0001;

    logic [31:0] cnt [NEV];
    logic        clr;

    // ---------------------------------------------------------------- запись
    logic          aw_h, w_h;
    logic [AW-1:0] aw_a;
    logic [31:0]   w_d;
    logic [3:0]    w_s;
    assign s_awready = !aw_h && !s_bvalid;
    assign s_wready  = !w_h && !s_bvalid;
    assign s_bresp   = 2'b00;

    function automatic logic [31:0] merge(input logic [31:0] o, input logic [31:0] d,
                                          input logic [3:0] s);
        logic [31:0] r;
        for (int b = 0; b < 4; b++) r[8*b +: 8] = s[b] ? d[8*b +: 8] : o[8*b +: 8];
        return r;
    endfunction

    always_ff @(posedge clk) begin
        clr <= 1'b0;
        if (s_awvalid && s_awready) begin aw_h <= 1'b1; aw_a <= s_awaddr; end
        if (s_wvalid && s_wready)   begin w_h <= 1'b1; w_d <= s_wdata; w_s <= s_wstrb; end
        if (s_bvalid && s_bready) s_bvalid <= 1'b0;
        if (aw_h && w_h) begin
            aw_h     <= 1'b0;
            w_h      <= 1'b0;
            s_bvalid <= 1'b1;
            case ({aw_a[AW-1:2], 2'b00})
                AW'('h10): clr <= w_d[0] && w_s[0];
                AW'('h14): local_mac[31:0]  <= merge(local_mac[31:0], w_d, w_s);
                AW'('h18): local_mac[47:32] <= 16'(merge({16'b0, local_mac[47:32]}, w_d, w_s));
                AW'('h1C): local_ip         <= merge(local_ip, w_d, w_s);
                AW'('h20): local_port       <= 16'(merge({16'b0, local_port}, w_d, w_s));
                default: ;
            endcase
        end
        if (rst) begin
            aw_h       <= 1'b0;
            w_h        <= 1'b0;
            s_bvalid   <= 1'b0;
            local_mac  <= MAC;
            local_ip   <= IP;
            local_port <= UDP_PORT;
        end
    end

    // ---------------------------------------------------------------- счётчики
    always_ff @(posedge clk) begin
        for (int k = 0; k < NEV; k++) begin
            if (rst || clr) cnt[k] <= '0;
            else if (ev[k]) cnt[k] <= cnt[k] + 32'd1;
        end
    end

    // ---------------------------------------------------------------- чтение
    assign s_arready = !s_rvalid;
    wire [AW-1:0] a = {s_araddr[AW-1:2], 2'b00};
    assign s_rresp   = 2'b00;
    always_ff @(posedge clk) begin
        if (s_rvalid && s_rready) s_rvalid <= 1'b0;
        if (s_arvalid && s_arready) begin
            s_rvalid <= 1'b1;
            s_rdata  <= '0;
            case (a)
                AW'('h00): s_rdata <= ID;
                AW'('h04): s_rdata <= VERSION;
                AW'('h08): s_rdata <= link_stat;
                AW'('h0C): s_rdata <= bridge_stat;
                AW'('h14): s_rdata <= local_mac[31:0];
                AW'('h18): s_rdata <= {16'b0, local_mac[47:32]};
                AW'('h1C): s_rdata <= local_ip;
                AW'('h20): s_rdata <= {16'b0, local_port};
                AW'('h24): s_rdata <= PARAMS;
                default:
                    if (a >= AW'('h40) && a < AW'('h40 + 4 * NEV))
                        s_rdata <= cnt[(a - AW'('h40)) >> 2];
            endcase
        end
        if (rst) s_rvalid <= 1'b0;
    end

endmodule
