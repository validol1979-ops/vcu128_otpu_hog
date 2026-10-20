# verilog-axis (копия подмножества)

Файлы из `../external/rtl/verilog-axis/upstream` (коммит `48ff7a7`, MIT,
лицензия — `COPYING`), пути сохранены. Копия нужна, чтобы сборка из чистого
клона не зависела от общего каталога `external/`. Локальных изменений нет;
обновлять копированием из `external/` с правкой `UPSTREAM.json`.

- `rtl/axis_fifo.v` — кадровые FIFO моста 40G (`otpu_eth_bridge`): приём
  (отбрасывание плохих кадров и кадров при переполнении) и передача
  (кадр уходит в MAC целиком, без разрывов `tvalid`);
- `rtl/axis_register.v` — выходной регистр тракта передачи
  (`eth40_tx_mux`, как `compat_arp_tx` в `rfsoc_8x8_40g_compat_hog`).
