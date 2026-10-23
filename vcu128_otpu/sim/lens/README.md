# Lens: потактовая картина инференса на RTL (конфигурация VCU128)

Lens — штатный профайлер upstream openTPU (`opentpu/lens.py`, `lens_app.html`,
`../../../../external/rtl/opentpu-fesens/patched/docs/lens.md`). Он
прогоняет настоящую программу ISA, скомпилированную из модели Hugging Face,
на Verilator-RTL слайса и показывает её в браузере:

- **Floorplan** — схема блоков (HBM-каналы, порты A/B, DMA, ACT RAM, MXU с
  FIFO и колонками, QUANT, TMEM по банкам, VPU по полосам, окно секвенсора).
  Активные пути данных обозначены бегущим пунктиром, цвет блока показывает
  состояние: busy, stalled, ожидание зависимости. Есть воспроизведение
  по тактам или по инструкциям; наведение на блок открывает карточку
  «что это / что сейчас делает / почему ждёт»;
- **Timeline** — строка на блок, полоски счётчиков (порт B, MXU, FIFO);
- **Instructions / Source** — каждая динамическая инструкция со строкой
  исходника компилятора (`lib.py:10 rmsnorm`, `attention.py:117`, …);
- **Overview** — доля от предела по памяти и разбор, на что ушёл каждый такт
  порта B.

Это не оценочная модель, а сам upstream RTL (`otpu_top`: SEQ, DMA, MXU,
QUANT, VPU, TMEM) с параметрами `target/vcu128.toml`: S=1, D=128, MCOLS=4,
LANES=8, WIN=16, FIFO 1024, PAIR/DSTEP/STREAM включены, как в битстриме.
Не моделируются только HBM IP, `otpu_hbm_port`, `otpu_mem_ch` и 40G: вместо
них поведенческая память (`fixed`) или upstream-модель native-портов (`axi`).

## Запуск

Из корня репозитория `vcu128_otpu_hog/`:

```bash
vcu128_otpu/sim/lens/run.sh                  # lfm2-tiny, qwen-tiny, lfm2 (pos 8, память fixed)
vcu128_otpu/sim/lens/run.sh lfm2             # только настоящая LFM2.5-230M
MEM=axi vcu128_otpu/sim/lens/run.sh lfm2     # модель памяти с задержкой/отказами
POS=64 vcu128_otpu/sim/lens/run.sh lfm2      # более поздний токен (длиннее attention)
```

Нужны окружение `../external/rtl/opentpu-fesens/.venv` (numpy, torch,
transformers) и Verilator 5.050 в `~/.local/bin`. Для `lfm2` нужен чекпойнт
`upstream/models/LFM2.5-230M`. Первая сборка Verilator для новой
конфигурации занимает несколько минут; сборки кэшируются upstream в своём
игнорируемом `build/verilator/`.

Результат для каждого прогона лежит в `out/<workload>_pos<P>_<mem>.*`:

| Файл | Что это |
|---|---|
| `.html` | автономная страница Lens; открыть в браузере, сервер не нужен |
| `.otpuprof` | профиль (gzip JSON); открывается в любой странице Lens через **Open profile…** |
| `.summary.txt` | `lens summary`: такты, roofline, куда ушли такты порта B, загрузка блоков, находки |
| `.md` | `explain.py`: пути данных, шаги модели, все инструкции с путём и исходником |
| `.csv` | одна строка на динамическую инструкцию (для своих графиков) |
| `.log` | вывод записи |

Открыть интерактивно с сервером upstream:
`PYTHONPATH=<upstream> <venv>/bin/python -m opentpu.lens open out/<имя>.otpuprof`.
Глубокие ссылки: `…html#view=floor&t=6000&pin=mxu`, `#tour` — обзорная экскурсия.

## Нагрузки

| Нагрузка | Модель | Источник | Время записи (этот ПК) |
|---|---|---|---|
| `lfm2-tiny` | случайная LFM2, H=256, 6 слоёв (conv/attn как у LFM2) | модель теста upstream `tests/test_lfm2.py` | ~25 с |
| `qwen-tiny` | случайная Qwen3, 2 слоя, H=256 | `lens._tiny_qwen` | ~25 с |
| `lfm2` | **LFM2.5-230M int8** — та, что работает на плате | `models/LFM2.5-230M` | ~1 мин (fixed), ~2 мин (axi) |
| `qwen35-4b` | **Qwen3.5-4B fp4, голова int8** (`--wformat fp4 --head-format int8`) | `models/Qwen3.5-4B` | 10 мин (fixed), 13,5 мин (axi); ОЗУ 17–28 ГБ |

Предыдущие `--pos` токенов прогоняются на ISA-симуляторе: он бит-точный,
но без тактов. Трассируется на RTL только последний токен — так же, как в
`lens record qwen-tiny --board`.

## Результаты 20.10.2026 (pos 8, Verilator 5.050, `run.sh` + `MEM=axi run.sh lfm2`, всего ~4 мин)

| Прогон | Тактов | мкс при 100 МГц | Инструкций | Roofline | Порт B |
|---|---:|---:|---:|---:|---:|
| qwen-tiny, fixed | 20 135 | 201 | 255 | 76,3 % | 74,2 % |
| lfm2-tiny, fixed | 43 012 | 430 | 457 | 75,6 % | 75,2 % |
| **LFM2.5-230M, fixed** | **1 858 909** | 18 589 | 3587 | 97,0 % | 96,9 % |
| **LFM2.5-230M, axi** (lat 40, stall 5 %) | **1 964 214** | 19 642 | 3587 | 91,8 % | 91,8 % |

Сравнение с платой: в журнале за 19.10 у LFM2.5-230M на VCU128 записано
1,95 Мтакта на токен (51,3 ток/с на устройстве). RTL с моделью памяти `axi`
даёт 1,96 Мтакта, с `fixed` — 1,86 Мтакта. Совпадение в пределах 5 %
подтверждает, что Lens-профили описывают реальный ход вычислений на плате.
Это сравнение средних величин, а не бит-в-бит одной позиции.

Что видно в профиле LFM2.5-230M, данные из `explain.py`:

- за токен порт B читает 220 МиБ, почти всё — веса: MLP gate/up — 32 %,
  LM head (65536 × 1024 INT8) — 29 %, down — 16 %, short-conv — 15 %,
  проекции attention — 8 %. K/V при pos 8 — доли процента;
- MXU занят 99,9 % времени, VPU — 6,5 %, QUANT — 2,9 %. Декод упирается
  в память: при M=1 работает одна колонка MXU из четырёх;
- главные потери с моделью `axi`: MXU считает, но не стримит (3,8 %), и
  дренаж и кредиты строк (3,3 %).

### Qwen3.5-4B: DRAM 4 ГиБ в Verilator (20.10.2026)

Образ Qwen3.5-4B занимает 2,47 ГиБ, поэтому DRAM слайса округляется до 4 ГиБ (2^30 слов).
Verilator 5.050 не строит массив больше 2^28 элементов, а upstream `otpu_dram.sv` (`fixed`)
хранит DRAM одним массивом, `otpu_native_mem.sv` (`axi`) — двумя половинами. Поэтому сборка
останавливалась на «Width of bit range is huge». `dram_banked.py` делает копии обоих модулей
с банками по 2^28 слов в `out/rtl/` и подставляет их в сборку rtlsim; upstream не меняется.
`record.py` включает их сам, если DRAM больше 1 ГиБ (или задан `--dram-gib`).

`--check` прогоняет трассируемый токен ещё раз на ISA-симуляторе и сравнивает всю DRAM
слайса побайтно (результаты, KV-кэш, состояние).

| Прогон | Тактов | Roofline / порт B | RTL = ISA (`--check`) |
|---|---:|---:|---|
| lfm2-tiny, fixed, 1 банк / `--dram-gib 2` (2 банка) | 43 012 / 43 012 | — | да / да |
| lfm2-tiny, axi, 1 банк / `--dram-gib 2` | 43 137 / 43 137 | — | да / да |
| **Qwen3.5-4B, fixed**, 4 ГиБ | **19 972 815** | 99,0 % / 99,0 % | да, 4 ГиБ |
| **Qwen3.5-4B, axi**, 4 ГиБ | **22 545 417** | 87,7 % / 88,1 % | да, 4 ГиБ |

Плата (журнал 20.10, чат 128 токенов, greedy): **21,57 Мтакта** на токен. Fixed даёт на
7,4 % меньше, axi — на 4,5 % больше; плата между ними, как у LFM2.5 (1,86 / 1,95 / 1,96).
За токен 2,42 ГиБ портом B: gate/up 30 %, LM head int8 25 %, входные проекции Gated DeltaNet (`project`) 15 %,
down 15 %, attention 6 %. С axi главные потери — MXU не принимает поток (дренаж и кредиты
строк, 5,6 %) и считает без потока (5,0 %).

## Аппаратная трассировка с платы (не проверено на VCU128)

В битстриме есть буфер трассы `otpu_ctrl` (TRACE_DEPTH 16384, register
map 2, upstream `docs/observability.md`). Upstream-инструмент `otpu-lens`
(`opentpu/host/hwlens.py`) читает его после трассируемого шага и строит
такой же профиль (kind `hw`). Он создаёт `XdmaTransport` внутри функции,
поэтому подмена транспорта из `tools/otpu_eth_run.py` подходит без правок
upstream:

```bash
OTPU_ETH_HOST=192.168.41.2 OTPU_TARGET=vcu128_otpu/target/vcu128.toml \
PYTHONPATH=../external/rtl/opentpu-fesens/patched:vcu128_otpu/tools \
  ../external/rtl/opentpu-fesens/.venv/bin/python vcu128_otpu/tools/otpu_eth_run.py \
  -m opentpu.host.hwlens record --model ../external/rtl/opentpu-fesens/patched/models/LFM2.5-230M \
  --prompt "What is the capital of France?" --tokens 2 -o card.otpuprof
```

На модели платы этот путь проверен: `otpu-lens record --sim --workload qwen-tiny --pos 8`,
Verilator `tb_board` с тем же буфером трассы и `Board.run(trace=…)`, 20.10.2026.
Результат: 20 040 тактов, 2204 записи, drop 0, lost 0. Прямой RTL-профиль дал
20 135 тактов. Обёртка `otpu_eth_run.py -m opentpu.host.hwlens` запускается
(`record --help`).
На самой VCU128 команда **не запускалась**: для этого нужна плата с
прошивкой и линк 40G. Это следующий шаг: он даст профиль с реальным HBM
вместо модели памяти.

## Файлы

- `record.py` — запись профиля: `lfm2`/`lfm2-tiny`/`qwen35`/`qwen35-4b` (своя обвязка
  вокруг `lens._Capture`, `Engine`, `profile.parse`; `--check` — сверка с ISA) и
  `qwen-tiny` (upstream `lens.record`). Upstream не меняется.
- `dram_banked.py` — банкованные копии `otpu_dram.sv` и `otpu_native_mem.sv` для DRAM
  больше 1 ГиБ (сама проверяет, что upstream-фрагменты не изменились).
- `explain.py` — читаемый разбор профиля на русском: пути данных по
  опкодам, итоги по шагам модели, список инструкций. Читает только
  `.otpuprof`, пакет upstream не нужен.
- `run.sh` — запись, `lens summary`, разбор и HTML для каждой нагрузки.
