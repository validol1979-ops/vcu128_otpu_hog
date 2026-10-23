# Структурные схемы VCU128 openTPU

- `project_structure.drawio` — редактируемая схема diagrams.net, три листа.
- `structure_01.svg/pdf` — интерфейсы платы, HBM, управление и тактирование.
- `structure_02.svg/pdf` — SEQ, DMA, QUANT, ACT, MXU, VPU, TMEM, арбитраж.
- `structure_03.svg/pdf` — численный LLaMA-подобный декодер, KV (INT8, QST) и обратная связь.
- `project_structure.tex/pdf` — ранее подготовленный русскоязычный комплект TikZ.
- `algorithm/` — пять диаграмм состояний к `../inference_algorithm.md` (сеанс ПК, прогон,
  инструкция в SEQ, команда MM, программа токена); пересборка `algorithm/build.sh`.
- `inference_dataflow.dot/svg/pdf` — пути данных инференса ПК → 40G → HBM → слайс с
  инструкциями ISA на рёбрах (к `../inference.md`); пересборка:
  `dot -Tsvg inference_dataflow.dot -o inference_dataflow.svg` (и `-Tpdf`).
- `slice_structure.dot/svg/pdf` — устройство одного слайса `otpu_slice`: блоки, порты
  памяти A/B/SW, арбитр TMEM (к `../slice.md`); пересборка так же через `dot`.
- `variants/` — та же схема слайса в других инструментах, для выбора; сравнение рядом —
  `variants/index.html` (открыть в браузере). Содержание у всех из `slice_structure.dot`:

  | Вариант | Файлы | Пересборка | Для чего |
  |---|---|---|---|
  | LaTeX/TikZ | `variants/tikz/slice_tikz.{tex,pdf,png}` | `variants/tikz/build.sh` (lualatex) | печать, отчёты |
  | KiCad 10 | `variants/kicad/slice_kicad.{kicad_pro,kicad_sch,pdf,svg}` | `variants/kicad/build.sh` (gen.py → kicad-cli, ERC) | чертёж A3, правка в Eeschema |
  | SVG, ручная раскладка | `variants/svg/slice_svg.{svg,pdf,png}` | `python3 variants/svg/gen_slice_svg.py` | документация, тёмная тема |
  | Изометрия | `variants/isometric/slice_isometric.{html,svg,png}` | `python3 variants/isometric/build.py` | презентации (подсказки, анимация) |

  В каждом каталоге `NOTES.md` — плюсы и минусы. Раскладка в TikZ, KiCad и SVG ручная
  (координаты в исходнике/генераторе): при изменении состава слайса их правят вручную.

Повторный экспорт редактируемой схемы и трёх SVG/PDF:

```bash
python3 vcu128_otpu/doc/diagrams/build_editable.py
```

Нужны Python 3 и Graphviz `dot`. Graphviz автоматически размещает блоки;
координаты в draw.io настроены отдельно для редактирования. Данные обеих
версий берутся из одного списка узлов и связей генератора. Если схема
редактируется вручную в draw.io, повторная генерация перезапишет эти правки.

Источники аппаратной структуры: `src/otpu_vcu128_top.sv`,
`src/otpu-fesens/rtl/{top/otpu_slice.sv,boards/bcu1525/otpu_bcu_sys.sv}`,
`target/vcu128.toml`. INT8/4-bit — возможности реального MXU; алгоритмический
лист показывает **численный пример** INT8 с GQA, а не архитектуру Qwen/LFM.
В двунаправленных аппаратных интерфейсах подпись означает запросы и ответы;
стрелки задают основной путь, не каждый отдельный канал handshake.
Для VPU/TMEM и DMA/TMEM есть чтение и запись; ACT читается MXU и пишется QUANT.
Интегральный блок FIFO/эпилога на листе 2 находится внутри `otpu_mxu`,
это детализация одного модуля, не отдельный внешний IP.

Текущая конфигурация S=1: активное окно HBM 4 GiB из физических 8 GiB.
Каналов 2, по 2 native/AXI3-порта. Разделение логических и физических объёмов
существенно при расчёте вместимости весов и KV-cache.
