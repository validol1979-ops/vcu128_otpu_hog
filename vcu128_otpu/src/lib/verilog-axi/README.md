# verilog-axi (копия подмножества)

`axil_cdc` (AXI-Lite через два такта) из `../external/rtl/verilog-axi/upstream`
(MIT, `COPYING`); коммит — `UPSTREAM.json`. Пути сохранены, правок нет.
Используется в верхнем уровне: AXI-Lite моста 40G (eth_clk) → регистры в
домене ядра. Ограничения CDC — `syn/vivado/axil_cdc.tcl` (nosynth).
