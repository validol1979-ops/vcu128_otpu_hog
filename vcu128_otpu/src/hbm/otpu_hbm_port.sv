// Один канал памяти openTPU на HBM2 (VCU128): сторона контроллера otpu_mem_ch (два native-порта
// LiteDRAM, c_*) -> 2 x NS AXI3-мастеров к портам Xilinx HBM IP (PG276). Всё в домене uclk
// (225 МГц). Описание, функция адресов и ограничения: README.md рядом.
//
// Native-порт p (= бит 7 номера beat, его выбирает otpu_mem_ch) обслуживают NS независимых
// AXI-портов («подпорты» k = 0..NS-1, AXI-порт a = p + 2k): beat идёт в подпорт по старшим битам
// номера своего псевдоканала (otpu_hbm_amap), так что подпорт k обращается только к псевдоканалам
// своей четверти (NS = 2) канала -- на плате это псевдоканалы мини-коммутатора его AXI-порта.
// Поток соседних beat одного native-порта (серия 128 beat) делится между NS AXI-портами: native-
// порт принимает beat каждый такт uclk (64 байта), AXI-порт -- 32 байта за такт. Одинаковые beat
// всегда в одном подпорте, поэтому порядок по beat держит подпорт, как прежде порт; данные чтения
// native-порта собираются из подпортов в порядке его команд (FIFO номеров подпортов).
// Beat (64 байта) = пакет из двух 256-битных слов: AxLEN = 1, AxSIZE = 5, INCR.
//
// Конвейер команд подпорта: A (приём команды; сравнение её beat со всеми невыполненными
// операциями подпорта -- CAM, результат в вектор зависимостей) -> H (голова: выдаёт AR или AW,
// когда её вектор пуст) -> FIFO AR/AW (выходы из регистров) -> HBM. Каналы чтения и записи HBM
// между собой не упорядочены, поэтому порядок по beat держится здесь:
//   - запись невыполнена до своего B (слот записи = AWID, освобождается по B);
//   - чтение невыполнено до своего последнего R (слот чтения = ARID);
//   - любая команда ждёт невыполненную запись того же beat (RAW, WAW), запись ждёт и невыполненное
//     чтение того же beat (WAR); чтение после чтения не ждёт.
// Команда в A сравнивается с таблицами в такте приёма, а с командой, которую H выдаёт в том же
// такте (её ещё нет в таблицах), -- отдельным компаратором; бит зависимости гаснет, когда
// операция завершается. Так проверка на голове -- регистр (h_ok), без CAM на пути c_cmd_ready.
//
// Запись: otpu_mem_ch кладёт данные записи в свою FIFO порта в такте, когда команда входит в
// очередь команд порта, поэтому к моменту, когда команда записи стоит на c_cmd, её данные уже на
// голове c_wdata (данные идут в порядке команд записи). Команда записи принимается только вместе
// с данными (c_wdata_ready = приём команды записи); данные ждут в FIFO WQ подпорта и уходят на W
// после своего AW (W никогда не опережает AW, по 2 слова, WLAST на втором). c_wdata_we -> WSTRB.
//
// Чтение: каждому AR при выдаче резервируется слот кольцевого буфера подпорта (ARID = слот),
// поэтому R принимается всегда (RREADY = 1), в любом порядке ID и с чередованием пакетов разных
// ID. Данные уходят в otpu_mem_ch в порядке команд native-порта (голова кольца подпорта, который
// назван на голове FIFO номеров, когда оба слова пришли), без обратного давления; два native-порта
// делят одну шину c_rdata_data: арбитр (по очереди при конфликте) выдаёт не больше одного beat за
// такт, valid ровно одного порта.
//
// Ошибки: RRESP/BRESP != OKAY -- счётчик st_err_cnt (насыщающийся) и флаг st_err; нарушение
// протокола HBM (R/B с неизвестным ID, неверный RLAST) -- флаг st_perr. Оба держатся до urst.
// Сброс urst синхронный.
module otpu_hbm_port #(
  parameter logic [32:0] CH_BASE = 33'h0, // байтовый адрес канала в HBM (кратен размеру канала)
  parameter int  PCB = 3,                 // log2 псевдоканалов в канале: 3 -- 8 (2 GiB), 2 -- 4 (1 GiB)
  parameter int  PC_GRAN = 0,             // log2 соседних beat подряд в одном псевдоканале
  parameter bit  PC_XOR  = 1'b1,          // номер псевдоканала XOR со следующими тремя битами
  parameter int  NS = 1,                  // AXI-портов на native-порт: 1, 2, 4
  parameter int  RD = 32,                 // слоты чтения на AXI-порт (ARID, буфер), 2^k, 4..64
  parameter int  WD = 32,                 // слоты записи на AXI-порт (AWID), 2^k, 4..64
  parameter int  WQ = 8,                  // FIFO данных записи на AXI-порт, beats
  parameter int  AQ = 4,                  // FIFO AR и AW на AXI-порт
  localparam int NA = 2 * NS              // AXI-портов: a = p + 2k (native-порт p, подпорт k)
) (
  input  logic              uclk,
  input  logic              urst,
  // сторона контроллера otpu_mem_ch (native-порты LiteDRAM)
  input  logic [1:0]        c_cmd_valid,
  output logic [1:0]        c_cmd_ready,
  input  logic [1:0]        c_cmd_we,
  input  logic [1:0][24:0]  c_cmd_addr,
  input  logic [1:0]        c_wdata_valid,
  output logic [1:0]        c_wdata_ready,
  input  logic [1:0][511:0] c_wdata_data,
  input  logic [1:0][63:0]  c_wdata_we,
  output logic [1:0]        c_rdata_valid,
  output logic [1:0][511:0] c_rdata_data,  // одна шина: [1] = [0]
  // NA AXI3-мастеров к портам HBM IP
  output logic [NA-1:0]        m_awvalid,
  input  logic [NA-1:0]        m_awready,
  output logic [NA-1:0][32:0]  m_awaddr,
  output logic [NA-1:0][5:0]   m_awid,
  output logic [NA-1:0][3:0]   m_awlen,
  output logic [NA-1:0][2:0]   m_awsize,
  output logic [NA-1:0][1:0]   m_awburst,
  output logic [NA-1:0]        m_wvalid,
  input  logic [NA-1:0]        m_wready,
  output logic [NA-1:0][255:0] m_wdata,
  output logic [NA-1:0][31:0]  m_wstrb,
  output logic [NA-1:0]        m_wlast,
  output logic [NA-1:0][5:0]   m_wid,           // AXI3 WID (= AWID); у HBM IP вывода нет
  output logic [NA-1:0][31:0]  m_wdata_parity,  // XOR битов байта (если в IP включена чётность)
  input  logic [NA-1:0]        m_bvalid,
  output logic [NA-1:0]        m_bready,
  input  logic [NA-1:0][5:0]   m_bid,
  input  logic [NA-1:0][1:0]   m_bresp,
  output logic [NA-1:0]        m_arvalid,
  input  logic [NA-1:0]        m_arready,
  output logic [NA-1:0][32:0]  m_araddr,
  output logic [NA-1:0][5:0]   m_arid,
  output logic [NA-1:0][3:0]   m_arlen,
  output logic [NA-1:0][2:0]   m_arsize,
  output logic [NA-1:0][1:0]   m_arburst,
  input  logic [NA-1:0]        m_rvalid,
  output logic [NA-1:0]        m_rready,
  input  logic [NA-1:0][5:0]   m_rid,
  input  logic [NA-1:0][255:0] m_rdata,
  input  logic [NA-1:0][1:0]   m_rresp,
  input  logic [NA-1:0]        m_rlast,
  // состояние (регистр платформы), по AXI-портам
  output logic [NA-1:0][31:0]  st_rcmd,         // команды чтения, принятые от otpu_mem_ch
  output logic [NA-1:0][31:0]  st_wcmd,         // команды записи
  output logic [NA-1:0][6:0]   st_rout,         // чтения в HBM (AR выдан, последний R не пришёл)
  output logic [NA-1:0][6:0]   st_wout,         // записи в HBM (AW выдан, B не пришёл)
  output logic [NA-1:0][31:0]  st_dep,          // такты, которые голова ждала зависимость по beat
  output logic [NA-1:0]        st_busy,         // в порту есть команда или операция
  output logic [15:0]          st_err_cnt,      // ответы RRESP/BRESP != OKAY (насыщается)
  output logic                 st_err,          // был ответ != OKAY
  output logic                 st_perr          // HBM нарушил протокол (ID, RLAST)
);
  localparam int RSW = $clog2(RD);
  localparam int WSW = $clog2(WD);
  localparam int KW  = (NS > 1) ? $clog2(NS) : 1;   // номер подпорта (при NS = 1 -- всегда 0)
  localparam int TQ  = 2 * NS * RD;         // FIFO номеров подпортов чтения native-порта
  localparam int QW  = 33 + 6;              // AR/AW: {адрес, ID}
  localparam int DW  = 64 + 512;            // данные записи: {WSTRB, WDATA}
  localparam int G   = PC_GRAN;
  initial begin
    if (RD != (1 << RSW) || RD < 4 || RD > 64) $fatal(1, "otpu_hbm_port: RD = 2^k, 4..64");
    if (WD != (1 << WSW) || WD < 4 || WD > 64) $fatal(1, "otpu_hbm_port: WD = 2^k, 4..64");
    if (NS != 1 && NS != 2 && NS != 4) $fatal(1, "otpu_hbm_port: NS = 1, 2, 4");
    if (PCB != 2 && PCB != 3) $fatal(1, "otpu_hbm_port: PCB = 2, 3");
    if (NS > (1 << PCB)) $fatal(1, "otpu_hbm_port: NS больше числа псевдоканалов");
    if ((CH_BASE & ((33'd1 << (28 + PCB)) - 33'd1)) != '0)
      $fatal(1, "otpu_hbm_port: CH_BASE не кратен размеру канала");
    if (PC_GRAN < 0 || PC_GRAN + (PC_XOR ? 2 * PCB : PCB) > 22 + PCB)
      $fatal(1, "otpu_hbm_port: PC_GRAN");
  end

  // подпорт beat: старшие биты номера псевдоканала в канале (как в otpu_hbm_amap)
  function automatic logic [KW-1:0] sub_of(input logic [24:0] b);
    logic [PCB-1:0] pc;
    pc = b[G +: PCB] ^ (PC_XOR ? b[G + PCB +: PCB] : PCB'(0));
    return (NS == 1) ? '0 : KW'(pc >> (PCB - KW));
  endfunction

  // ================================================================ native-порты: выбор подпорта
  logic [1:0][KW-1:0] sel;                  // подпорт команды на c_cmd
  logic [NA-1:0]      e_rdy;                // подпорт готов принять команду своего native-порта
  logic [1:0]         tq_wr, tq_rv;         // FIFO номеров подпортов чтения: место, непуста
  logic [1:0][KW-1:0] tq_rd;                // подпорт следующего beat чтения native-порта
  logic [NA-1:0]      hr;                   // голова кольца чтения подпорта готова (оба слова)
  logic [NA-1:0]      pk;                   // её beat уходит в otpu_mem_ch в этом такте
  logic [NA-1:0][511:0] q;                  // beat, прочитанный из буфера подпорта при выдаче
  logic [1:0]         hn, pkn;              // native-порт: голова готова / выдаёт beat
  logic [NA-1:0]      e_rr, e_br, e_prot;   // ошибки этого такта: RRESP, BRESP, протокол
  logic [1:0]         ck_wnd;               // (симуляция) команда записи без данных

  for (genvar p = 0; p < 2; p++) begin : g_n
    logic rdy_s;
    assign sel[p] = sub_of(c_cmd_addr[p]);
    always_comb begin
      rdy_s = 1'b0;
      for (int k = 0; k < NS; k++) if (sel[p] == KW'(k)) rdy_s = e_rdy[p + 2 * k];
    end
    // чтение принимается, только если есть место для номера его подпорта
    assign c_cmd_ready[p]   = rdy_s && (c_cmd_we[p] || tq_wr[p]);
    assign c_wdata_ready[p] = c_cmd_valid[p] && c_cmd_ready[p] && c_cmd_we[p];
    assign ck_wnd[p] = c_cmd_valid[p] && c_cmd_we[p] && !c_wdata_valid[p];
    if (NS > 1) begin : g_tq
      otpu_hbm_fifo #(.W(KW), .DEPTH(TQ)) u_tq (.clk(uclk), .rst(urst),
        .wvalid(c_cmd_valid[p] && c_cmd_ready[p] && !c_cmd_we[p]), .wready(tq_wr[p]),
        .wdata(sel[p]), .rvalid(tq_rv[p]), .rready(pkn[p]), .rdata(tq_rd[p]));
    end else begin : g_ntq
      assign tq_wr[p] = 1'b1;
      assign tq_rv[p] = 1'b1;
      assign tq_rd[p] = '0;
    end
    always_comb begin
      hn[p] = 1'b0;
      for (int k = 0; k < NS; k++) if (tq_rd[p] == KW'(k)) hn[p] = tq_rv[p] && hr[p + 2 * k];
    end
  end

  // ================================================================ AXI-порты (подпорты)
  for (genvar a = 0; a < NA; a++) begin : g_p
    localparam int p = a % 2;               // native-порт
    localparam int k = a / 2;               // подпорт
    // ---------------------------------------------------------------- таблицы операций
    logic [RD-1:0]        r_pend;           // чтение в HBM (для CAM)
    logic [RD-1:0]        r_done;           // оба слова в буфере, ждёт выдачи
    logic [RD-1:0]        r_half;           // принято первое слово
    logic [RD-1:0][24:0]  r_beat;
    logic [RSW-1:0]       r_wp, r_rp;       // кольцо слотов чтения: выдача AR, выдача данных
    logic [RSW:0]         r_cnt;            // занятые слоты
    logic [RD-1:0]        r_fr;             // чтение завершилось в прошлом такте (onehot)
    logic [WD-1:0]        w_v;              // запись в HBM (до B)
    logic [WD-1:0][24:0]  w_beat;
    logic [WSW-1:0]       w_wp;
    logic [WD-1:0]        w_fr;             // B пришёл в прошлом такте (onehot)
    logic                 rs_ok, ws_ok;     // свободен следующий слот чтения / записи

    // ---------------------------------------------------------------- A и H
    logic                 a_v, a_we, h_v, h_we, h_ok;
    logic [24:0]          a_beat, h_beat;
    logic [RD-1:0]        a_rdep, h_rdep, c_rm;
    logic [WD-1:0]        a_wdep, h_wdep, c_wm;
    logic                 h_go, a_mv, c_acc, al_r, al_w, eq_c, eq_a;
    logic [RD-1:0]        al_rv, a_rdep_n;
    logic [WD-1:0]        al_wv, a_wdep_n;
    logic                 ar_wr, aw_wr, wq_wr;   // место в FIFO AR, AW, WQ (регистры)
    logic [32:0]          h_addr;

    assign h_go  = h_v && h_ok && (h_we ? (aw_wr && ws_ok) : (ar_wr && rs_ok));
    assign a_mv  = a_v && (!h_v || h_go);
    assign e_rdy[a] = !urst && (!a_v || a_mv) &&
                      (!c_cmd_we[p] || (c_wdata_valid[p] && wq_wr));
    assign c_acc = c_cmd_valid[p] && c_cmd_ready[p] && sel[p] == KW'(k);
    assign al_r  = h_go && !h_we;
    assign al_w  = h_go && h_we;
    assign al_rv = RD'(al_r) << r_wp;
    assign al_wv = WD'(al_w) << w_wp;
    assign eq_c  = h_beat == c_cmd_addr[p];
    assign eq_a  = h_beat == a_beat;

    // CAM: невыполненные операции подпорта с beat принимаемой команды
    always_comb begin
      for (int e = 0; e < RD; e++) c_rm[e] = r_pend[e] && r_beat[e] == c_cmd_addr[p];
      for (int e = 0; e < WD; e++) c_wm[e] = w_v[e] && w_beat[e] == c_cmd_addr[p];
    end
    // вектор зависимостей A в следующем такте (если A не принимает новую команду): завершённые
    // гаснут, выданная сейчас головой операция того же beat добавляется
    assign a_rdep_n = (a_rdep & ~r_fr) | ((eq_a && a_we) ? al_rv : '0);
    assign a_wdep_n = (a_wdep & ~w_fr) | (eq_a ? al_wv : '0);

    always_ff @(posedge uclk) begin
      if (urst) a_v <= 1'b0;
      else if (c_acc) a_v <= 1'b1;
      else if (a_mv) a_v <= 1'b0;
      if (c_acc) begin
        a_we   <= c_cmd_we[p];
        a_beat <= c_cmd_addr[p];
        a_rdep <= c_cmd_we[p] ? ((c_rm & ~r_fr) | (eq_c ? al_rv : '0)) : '0;
        a_wdep <= (c_wm & ~w_fr) | (eq_c ? al_wv : '0);
      end else begin
        a_rdep <= a_rdep_n;
        a_wdep <= a_wdep_n;
      end

      if (urst) h_v <= 1'b0;
      else if (a_mv) h_v <= 1'b1;
      else if (h_go) h_v <= 1'b0;
      if (a_mv) begin
        h_we   <= a_we;
        h_beat <= a_beat;
        h_rdep <= a_rdep_n;
        h_wdep <= a_wdep_n;
        h_ok   <= !(|(a_rdep & ~r_fr)) && !(|(a_wdep & ~w_fr)) &&
                  !(eq_a && (al_w || (al_r && a_we)));
      end else begin
        h_rdep <= h_rdep & ~r_fr;
        h_wdep <= h_wdep & ~w_fr;
        h_ok   <= !(|(h_rdep & ~r_fr)) && !(|(h_wdep & ~w_fr));
      end
    end

    otpu_hbm_amap #(.CH_BASE(CH_BASE), .PCB(PCB), .PC_GRAN(PC_GRAN), .PC_XOR(PC_XOR)) u_amap (
      .beat(h_beat), .addr(h_addr));

    // ---------------------------------------------------------------- AR, AW
    logic [QW-1:0] ar_rd, aw_rd;
    otpu_hbm_fifo #(.W(QW), .DEPTH(AQ)) u_arq (.clk(uclk), .rst(urst), .wvalid(al_r),
      .wready(ar_wr), .wdata({h_addr, 6'(r_wp)}), .rvalid(m_arvalid[a]), .rready(m_arready[a]),
      .rdata(ar_rd));
    otpu_hbm_fifo #(.W(QW), .DEPTH(AQ)) u_awq (.clk(uclk), .rst(urst), .wvalid(al_w),
      .wready(aw_wr), .wdata({h_addr, 6'(w_wp)}), .rvalid(m_awvalid[a]), .rready(m_awready[a]),
      .rdata(aw_rd));
    assign m_araddr[a]  = ar_rd[QW-1 -: 33];
    assign m_arid[a]    = ar_rd[5:0];
    assign m_arlen[a]   = 4'd1;
    assign m_arsize[a]  = 3'd5;
    assign m_arburst[a] = 2'b01;
    assign m_awaddr[a]  = aw_rd[QW-1 -: 33];
    assign m_awid[a]    = aw_rd[5:0];
    assign m_awlen[a]   = 4'd1;
    assign m_awsize[a]  = 3'd5;
    assign m_awburst[a] = 2'b01;

    // ---------------------------------------------------------------- W
    // данные записи в порядке команд записи подпорта = в порядке AW; пакет начинается, только
    // когда его AW уже принят HBM (w_cred: AW принятые минус начатые пакеты W)
    logic          wq_rv, wq_rr, wo_v, wo_h, w_start, aw_hs;
    logic [DW-1:0] wq_rd;
    logic [$clog2(WQ)+1:0] w_cred;
    logic [WSW-1:0] w_idc;
    logic [255:0]  wo_data;
    logic [31:0]   wo_strb, wo_par;
    logic          wo_last;
    logic [5:0]    wo_id;
    otpu_hbm_fifo #(.W(DW), .DEPTH(WQ)) u_wq (.clk(uclk), .rst(urst), .wvalid(c_acc && c_cmd_we[p]),
      .wready(wq_wr), .wdata({c_wdata_we[p], c_wdata_data[p]}), .rvalid(wq_rv), .rready(wq_rr),
      .rdata(wq_rd));
    assign aw_hs   = m_awvalid[a] && m_awready[a];
    assign w_start = (!wo_v || m_wready[a]) && !wo_h && wq_rv && w_cred != 0;
    assign wq_rr   = (!wo_v || m_wready[a]) && wo_h;
    always_ff @(posedge uclk) begin
      if (urst) begin
        wo_v <= 1'b0; wo_h <= 1'b0; w_cred <= '0; w_idc <= '0;
      end else begin
        w_cred <= w_cred + ($clog2(WQ) + 2)'(aw_hs) - ($clog2(WQ) + 2)'(w_start);
        if (!wo_v || m_wready[a]) begin
          wo_v <= w_start || wo_h;
          wo_h <= w_start;
          if (wo_h) w_idc <= w_idc + 1'b1;
        end
      end
      if (!wo_v || m_wready[a]) begin
        wo_data <= wo_h ? wq_rd[511:256] : wq_rd[255:0];
        wo_strb <= wo_h ? wq_rd[575:544] : wq_rd[543:512];
        wo_last <= wo_h;
        wo_id   <= 6'(w_idc);
        for (int i = 0; i < 32; i++)
          wo_par[i] <= ^(wo_h ? wq_rd[256 + 8 * i +: 8] : wq_rd[8 * i +: 8]);
      end
    end
    assign m_wvalid[a]       = wo_v;
    assign m_wdata[a]        = wo_data;
    assign m_wstrb[a]        = wo_strb;
    assign m_wlast[a]        = wo_last;
    assign m_wid[a]          = wo_id;
    assign m_wdata_parity[a] = wo_par;

    // ---------------------------------------------------------------- B
    logic          bb_v;
    logic [5:0]    bb_id;
    logic [1:0]    bb_resp;
    assign m_bready[a] = 1'b1;
    always_ff @(posedge uclk) begin
      bb_v    <= !urst && m_bvalid[a];
      bb_id   <= m_bid[a];
      bb_resp <= m_bresp[a];
    end

    // ---------------------------------------------------------------- R
    logic          rr_v, rr_last, rr_h;
    logic [5:0]    rr_id;
    logic [1:0]    rr_resp;
    logic [255:0]  rr_data;
    logic [RSW-1:0] rr_s;
    (* ram_style = "distributed" *) logic [255:0] r_lo [RD];
    (* ram_style = "distributed" *) logic [255:0] r_hi [RD];
    assign m_rready[a] = 1'b1;
    always_ff @(posedge uclk) begin
      rr_v    <= !urst && m_rvalid[a];
      rr_id   <= m_rid[a];
      rr_resp <= m_rresp[a];
      rr_last <= m_rlast[a];
      rr_data <= m_rdata[a];
    end
    assign rr_s = rr_id[RSW-1:0];
    assign rr_h = r_half[rr_s];
    always_ff @(posedge uclk) begin
      if (rr_v && !rr_h) r_lo[rr_s] <= rr_data;
      if (rr_v &&  rr_h) r_hi[rr_s] <= rr_data;
    end

    // ---------------------------------------------------------------- состояние таблиц
    logic [RSW:0] r_cnt_n;
    logic [WSW-1:0] w_wp_n;
    logic [WD-1:0] w_v_n;
    logic [6:0]   r_inf, w_inf;
    logic [511:0] qd;
    assign hr[a]   = r_done[r_rp];
    assign pk[a]   = pkn[p] && tq_rd[p] == KW'(k);
    assign q[a]    = qd;
    assign r_cnt_n = r_cnt + (RSW + 1)'(al_r) - (RSW + 1)'(pk[a]);
    assign w_wp_n  = w_wp + WSW'(al_w);
    assign w_v_n   = (w_v & ~w_fr) | al_wv;
    always_ff @(posedge uclk) begin
      if (urst) begin
        r_pend <= '0; r_done <= '0; r_half <= '0; r_wp <= '0; r_rp <= '0; r_cnt <= '0;
        r_fr <= '0; rs_ok <= 1'b1;
        w_v <= '0; w_wp <= '0; w_fr <= '0; ws_ok <= 1'b1;
        r_inf <= '0; w_inf <= '0;
      end else begin
        r_pend <= (r_pend & ~r_fr) | al_rv;
        r_fr   <= (rr_v && rr_h) ? RD'(1) << rr_s : '0;
        if (rr_v) r_half[rr_s] <= !rr_h;
        r_done <= (r_done | ((rr_v && rr_h) ? RD'(1) << rr_s : '0)) &
                  ~(pk[a] ? RD'(1) << r_rp : '0);
        if (al_r)  r_wp <= r_wp + 1'b1;
        if (pk[a]) r_rp <= r_rp + 1'b1;
        r_cnt <= r_cnt_n;
        rs_ok <= r_cnt_n != (RSW + 1)'(RD);
        w_v   <= w_v_n;
        w_fr  <= bb_v ? WD'(1) << bb_id[WSW-1:0] : '0;
        w_wp  <= w_wp_n;
        ws_ok <= !w_v_n[w_wp_n];
        r_inf <= r_inf + 7'(al_r) - 7'(rr_v && rr_h);
        w_inf <= w_inf + 7'(al_w) - 7'(bb_v);
      end
      if (al_r) r_beat[r_wp] <= h_beat;
      if (al_w) w_beat[w_wp] <= h_beat;
      // голова кольца читается каждый такт (без разветвления pk на 512 разрядов): в такте
      // после выбора qd -- выбранный beat, r_rp сдвигается тем же фронтом
      qd <= {r_hi[r_rp], r_lo[r_rp]};
    end

    // ошибки этого такта: ответ != OKAY; R/B с ID без операции, RLAST не на втором слове
    assign e_rr[a]   = rr_v && rr_resp != 2'b00;
    assign e_br[a]   = bb_v && bb_resp != 2'b00;
    assign e_prot[a] = (rr_v && ({1'b0, rr_id} >= 7'(RD) || !r_pend[rr_s] || r_done[rr_s] ||
                                 rr_last != rr_h)) ||
                       (bb_v && ({1'b0, bb_id} >= 7'(WD) || !w_v[bb_id[WSW-1:0]]));

    // ---------------------------------------------------------------- счётчики
    logic [31:0] s_rcmd, s_wcmd, s_dep;
    logic        s_busy;
    always_ff @(posedge uclk) begin
      if (urst) begin
        s_rcmd <= '0; s_wcmd <= '0; s_dep <= '0; s_busy <= 1'b0;
      end else begin
        if (c_acc && !c_cmd_we[p]) s_rcmd <= s_rcmd + 1'b1;
        if (c_acc &&  c_cmd_we[p]) s_wcmd <= s_wcmd + 1'b1;
        if (h_v && !h_ok) s_dep <= s_dep + 1'b1;
        s_busy <= a_v || h_v || r_cnt != 0 || w_inf != 0 || wq_rv || wo_v ||
                  m_arvalid[a] || m_awvalid[a];
      end
    end
    assign st_rcmd[a] = s_rcmd;
    assign st_wcmd[a] = s_wcmd;
    assign st_dep[a]  = s_dep;
    assign st_busy[a] = s_busy;
    assign st_rout[a] = r_inf;
    assign st_wout[a] = w_inf;
  end

  // ================================================================ данные чтения в otpu_mem_ch
  // по очереди при конфликте: beat уходит через 2 такта после выбора, valid ровно одного порта
  logic       last1;
  logic [1:0] o_v;
  localparam int OAW = $clog2(NA);
  logic [OAW-1:0] o_a;                      // AXI-порт выбранного beat
  assign pkn[0] = hn[0] && (!hn[1] || last1);
  assign pkn[1] = hn[1] && (!hn[0] || !last1);
  always_ff @(posedge uclk) begin
    if (urst) begin
      last1 <= 1'b0; o_v <= '0; c_rdata_valid <= '0;
    end else begin
      if (pkn[1]) last1 <= 1'b1;
      else if (pkn[0]) last1 <= 1'b0;
      o_v <= pkn;
      c_rdata_valid <= o_v;
    end
    o_a <= pkn[1] ? OAW'(1 + 2 * tq_rd[1]) : OAW'(2 * tq_rd[0]);
    c_rdata_data[0] <= q[o_a];
    c_rdata_data[1] <= q[o_a];
  end

  // ================================================================ ошибки
  logic [15:0] e_n;
  always_comb begin
    e_n = '0;
    for (int a = 0; a < NA; a++) e_n = e_n + 16'(e_rr[a]) + 16'(e_br[a]);
  end
  always_ff @(posedge uclk) begin
    if (urst) begin
      st_err_cnt <= '0; st_err <= 1'b0; st_perr <= 1'b0;
    end else begin
      if (e_n != 0) st_err_cnt <= (st_err_cnt > 16'hFFFF - e_n) ? 16'hFFFF : st_err_cnt + e_n;
      if (e_n != 0) st_err <= 1'b1;
      if (|e_prot) st_perr <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge uclk) if (!urst) begin
    for (int p = 0; p < 2; p++) begin
      if (c_cmd_valid[p] && c_cmd_addr[p][7] != 1'(p))
        $error("otpu_hbm_port: beat %0d на порту %0d (бит 7)", c_cmd_addr[p], p);
      if (ck_wnd[p])
        $warning("otpu_hbm_port: порт %0d: команда записи без данных на c_wdata", p);
      if (pkn[p] && !tq_rv[p])
        $error("otpu_hbm_port: порт %0d: данные чтения без номера подпорта", p);
    end
    if (&c_rdata_valid) $error("otpu_hbm_port: c_rdata_valid обоих портов в одном такте");
    if (|e_prot) $error("otpu_hbm_port: HBM нарушил протокол (R/B: ID, RLAST)");
  end
`endif
endmodule

// Отображение номера beat канала в глобальный байтовый адрес HBM (взаимно однозначное).
// G = PC_GRAN, P = PCB (2^P псевдоканалов по 256 MiB в канале): блок из 2^G соседних beat лежит
// в одном псевдоканале; номер псевдоканала в канале (адрес[27+P:28]) -- биты beat[G+P-1:G], при
// PC_XOR ещё XOR beat[G+2P-1:G+P]; остальные биты beat по порядку -- адрес внутри псевдоканала
// (адрес[27:6]). Канал -- 2^(22+P) beat; старшие биты beat выше этого не используются.
// Обоснование: README.md.
module otpu_hbm_amap #(
  parameter logic [32:0] CH_BASE = 33'h0,
  parameter int  PCB     = 3,
  parameter int  PC_GRAN = 0,
  parameter bit  PC_XOR  = 1'b1
) (
  input  logic [24:0] beat,
  output logic [32:0] addr
);
  localparam int G = PC_GRAN;
  logic [PCB-1:0] pc;
  logic [21:0]    off;
  always_comb begin
    pc = beat[G +: PCB];
    if (PC_XOR) pc = pc ^ beat[G + PCB +: PCB];
    off = 22'((beat >> (G + PCB)) << G) | 22'(beat & ((25'd1 << G) - 25'd1));
    addr = CH_BASE | (33'(pc) << 28) | (33'(off) << 6);
  end
endmodule

// Синхронная FIFO, first-word fall-through, распределённая RAM; rvalid, wready и голова -- из
// регистров (как otpu_sfifo RO в otpu_mem_ch.sv), чтобы выходы AXI и c_cmd_ready начинались с
// триггеров.
module otpu_hbm_fifo #(
  parameter int W = 8,
  parameter int DEPTH = 4
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         wvalid,
  output logic         wready,
  input  logic [W-1:0] wdata,
  output logic         rvalid,
  input  logic         rready,
  output logic [W-1:0] rdata
);
  localparam int AW = $clog2(DEPTH);
  initial if (DEPTH != (1 << AW) || DEPTH < 2) $fatal(1, "otpu_hbm_fifo: DEPTH = 2^k >= 2");
  (* ram_style = "distributed" *) logic [W-1:0] mem [DEPTH];
  logic [AW:0]   wp, rp, wp_n, rp_n;
  logic [AW-1:0] rp1;
  logic          one, rv, wr, push, pop;
  logic [W-1:0]  head;
  assign push = wvalid && wr;
  assign pop  = rv && rready;
  assign wp_n = wp + (AW + 1)'(push);
  assign rp_n = rp + (AW + 1)'(pop);
  assign rp1  = rp[AW-1:0] + 1'b1;
  assign one  = (wp - rp) == (AW + 1)'(1);
  always_ff @(posedge clk) begin
    if (rst) begin
      wp <= '0; rp <= '0; rv <= 1'b0; wr <= 1'b1;
    end else begin
      wp <= wp_n; rp <= rp_n;
      rv <= wp_n != rp_n;
      wr <= (wp_n - rp_n) != (AW + 1)'(DEPTH);
    end
    if (push) mem[wp[AW-1:0]] <= wdata;
    if (pop) head <= one ? wdata : mem[rp1];
    else if (!rv) head <= wdata;
  end
  assign rvalid = rv;
  assign wready = wr;
  assign rdata  = head;
endmodule
