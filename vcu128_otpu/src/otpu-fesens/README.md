# openTPU (FeSens): копия RTL ядра и оболочки

Файлы из `../external/rtl/opentpu-fesens/upstream`, коммит `f237dab`
(2026-10-14), лицензия Apache-2.0 (`LICENSE`). Пути сохранены. Копия нужна,
чтобы сборка из чистого клона не зависела от `external/`. Локальных правок
нет: обновлять копированием из `external/` с правкой `UPSTREAM.json`.

- `rtl/top, mxu, vpu, mem, seq, dma` — ядро (без ячеек производителя);
- `rtl/shell` — общая оболочка FPGA-плат upstream (`otpu_board`,
  `otpu_mem_ch`, ...);
- `rtl/tech/xilinxus` — ячейки DSP48E2 (UltraScale+), `rtl/tech/generic` —
  поведенческие (RAM, симуляция);
- `rtl/boards/bcu1525/otpu_bcu_sys.sv` — `otpu_board` и `otpu_mem_ch` на каждый канал с
  выведенными портами хоста (`x_*`) и контроллера (`c_*`): используется без
  изменений, плата отличается только топом;
- `boards/ypcb-00338/constraints/otpu_mem_ch.tcl`, `otpu_clk2x.tcl` —
  ограничения CDC, которые upstream применяет и на BCU1525.

Плата VCU128 (топ, HBM, 40G) — в `../` этого проекта, не здесь.
