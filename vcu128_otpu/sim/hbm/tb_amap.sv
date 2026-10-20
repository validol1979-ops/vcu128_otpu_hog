// Полный перебор otpu_hbm_amap: все 2^25 beat канала для нескольких наборов параметров.
// Проверяется: адрес в окне канала (CH_BASE .. +2 GiB), кратен 64, отображение взаимно
// однозначно (битовая карта занятых beat), каждые 8 соседних блоков по 2^G beat (выровненных)
// лежат в 8 разных псевдоканалах. Запуск: run.sh (verilator --binary).
module tb_amap;
  localparam int NC = 6;
  localparam logic [32:0] BASE [NC] = '{33'h0, 33'h080000000, 33'h100000000, 33'h180000000,
                                        33'h0, 33'h100000000};
  localparam int GR [NC] = '{0, 0, 2, 5, 19, 22};
  localparam bit XR [NC] = '{1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0};
  logic [24:0] beat;
  logic [NC-1:0][32:0] addr;
  for (genvar i = 0; i < NC; i++) begin : g_c
    otpu_hbm_amap #(.CH_BASE(BASE[i]), .PC_GRAN(GR[i]), .PC_XOR(XR[i])) u (.beat(beat),
      .addr(addr[i]));
  end
  bit seen [NC][1 << 25];
  logic [7:0] pcs [NC];
  int errs = 0;
  initial begin
    for (int i = 0; i < NC; i++) begin
      for (int k = 0; k < (1 << 25); k++) seen[i][k] = 1'b0;
      pcs[i] = '0;
    end
    for (longint b = 0; b < (1 << 25); b++) begin
      beat = 25'(b);
      #1;
      for (int i = 0; i < NC; i++) begin
        logic [24:0] k;
        if (addr[i][32:31] != BASE[i][32:31] || addr[i][5:0] != 6'b0) begin
          if (errs < 10) $display("ОШИБКА: конфигурация %0d, beat %0d -> адрес %h вне окна", i, b, addr[i]);
          errs++;
        end
        k = addr[i][30:6];
        if (seen[i][k]) begin
          if (errs < 10) $display("ОШИБКА: конфигурация %0d, beat %0d -> адрес %h уже занят", i, b, addr[i]);
          errs++;
        end
        seen[i][k] = 1'b1;
        // псевдоканалы восьми соседних блоков
        if ((b & ((64'd1 << GR[i]) - 1)) == 0) pcs[i][addr[i][30:28]] = 1'b1;
        if (((b + 1) & ((64'd8 << GR[i]) - 1)) == 0) begin
          if (pcs[i] != 8'hFF) begin
            if (errs < 10) $display("ОШИБКА: конфигурация %0d, блоки до beat %0d: псевдоканалы %b", i, b, pcs[i]);
            errs++;
          end
          pcs[i] = '0;
        end
      end
    end
    if (errs == 0) $display("tb_amap: PASS, %0d конфигураций x %0d beat", NC, 1 << 25);
    else $display("tb_amap: FAIL, %0d ошибок", errs);
    $finish;
  end
endmodule
