# vcu128_otpu_hog

Ускоритель языковых моделей openTPU ([FeSens/openTPU](https://github.com/FeSens/openTPU),
Apache-2.0) на отладочной плате AMD VCU128 (Virtex UltraScale+ xcvu37p-fsvh2892-2L-e):
веса и KV-кеш в HBM2 (8 ГБ, 32 псевдоканала), связь с ПК по 40G Ethernet (QSFP1 → ConnectX-3,
свой протокол поверх UDP), JTAG-to-AXI для отладки. Генерация токенов идёт на плате, ПК —
токенизатор, чат и сервер API в стиле OpenAI. Проект Hog (вариант A, только Vivado).

## Состояние (23.10.2026)

Две сборки из одних исходников — два проекта Hog:

| Проект | Слайсы openTPU | Ядро | HBM | Тайминг | Ресурсы (LUT / DSP) |
|---|---|---|---|---|---|
| `Top/otpu` | 2 (SLR0, SLR1) | 200 МГц | 4 канала × 2 ГиБ, 16 AXI-портов | WNS +0,003 нс, WHS 0 | 323k (25 %) / 1447 |
| `Top/otpu_s4` | 4 (SLR0–SLR2) | 200 МГц | 8 каналов × 1 ГиБ, 32 AXI-порта | WNS +0,002 нс, WHS +0,001 нс | 616k (47 %) / 2891 |

Замеры на плате (генерация на устройстве, жадный выбор; ответ платы совпадает с симулятором
набора команд (ISA) в конфигурации платы бит-в-бит):

| Модель / тест | 1 слайс, 100 МГц (19–20.10) | 2 слайса, 200 МГц | **4 слайса, 200 МГц** |
|---|---|---|---|
| Qwen3.5-2B, веса fp4, голова int8 | 9,6 ток/с | 36,0 ток/с | **66,3 ток/с** (prefill 152 ток/с) |
| Qwen3.5-4B, веса fp4, голова int8 | 4,6 ток/с | 17,6 ток/с | **33,1 ток/с** (prefill 69 ток/с) |
| GEMM INT8 2048×2048, M = 1 (поток весов) | — | 84 GOPS (42 ГБ/с) | **143 GOPS (71 ГБ/с)** |
| GEMM INT8 2048×2048, M = 16 (у 1 слайса — большие M) | 94 GOPS | 237 GOPS | 338 GOPS |
| HBM ↔ ПК по 40G | 2,2–2,75 ГБ/с | — | — |

Какие модели на какой сборке:

| Модель | `otpu` (2 слайса) | `otpu_s4` (4 слайса) |
|---|---|---|
| Qwen3.5-2B, Qwen3.5-4B | да (на плате) | да (на плате) |
| LFM2.5-230M | раскладывается, на этих сборках не запускалась | то же |
| Gemma 4 (E4B) | в работе (компилятор на 2/4 слайса, проверка на плате впереди) | то же |
| MoE (LFM2.5-8B-A1B, Qwen3.5-35B-A3B), MTP | нет | нет — в upstream только один слайс |

Контекст по умолчанию — 32k токенов (`chat_board.sh`, `CAP=...`); у Qwen3.5 KV-кеш невелик
(внимание в каждом четвёртом слое), при 4 слайсах в HBM помещается контекст до ~110k.

Что сделано поверх upstream (подробно — [журнал](vcu128_otpu/doc/journal.md)):
- тракт HBM: адаптер `otpu_hbm_port` (4 AXI-порта на канал, каналы 1 или 2 ГиБ без боковых
  путей коммутатора HBM), 256 кредитов чтения `otpu_mem_ch`;
- 40G: MAC `l_ethernet`, мост UDP ↔ AXI до 8 каналов, ARP, пачки регистровых операций;
- размещение по трём SLR (pblock, регистры на пересечениях, Laguna), директивы реализации;
- датчики SYSMON трёх SLR и HBM, термозащита с остановкой прогона;
- серия патчей к upstream (кредиты чтения, размер канала и пересечения SLR, раздача KV-голов
  на слайсы при n_kv < S, таблица эмбеддингов по памяти слайса, конфигурация цели в чате и др.).

## Планы

По убыванию эффекта ([TODO](vcu128_otpu/doc/TODO.md)):
- поток канала HBM 8,9 → 12,8 ГБ/с (слоты чтения `otpu_hbm_port` 64; сборка идёт) — до +40 %;
- голова LM в fp4 — +15…18 % без пересборки;
- 4 канала HBM на слайс (сейчас 2) — до ×2 к генерации;
- Gemma 4 на 4 слайсах; 1G Ethernet с DHCP рядом с 40G; запас тайминга → частота выше 200 МГц.

## Документы

- [Журнал](vcu128_otpu/doc/journal.md) — решения, найденные ошибки, все замеры; [TODO](vcu128_otpu/doc/TODO.md);
- [Устройство](vcu128_otpu/doc/design.md) — блоки, такты, карта адресов, размещение, термоконтроль;
- [Протокол 40G](vcu128_otpu/doc/eth40_protocol.md); [адаптер HBM](vcu128_otpu/src/hbm/README.md);
- [Жизненный цикл токена — вход в проект с нуля](vcu128_otpu/doc/token_lifecycle.md);
- [Как идёт инференс: пути данных, ISA, один слой](vcu128_otpu/doc/inference.md);
  [алгоритм по уровням с диаграммами состояний](vcu128_otpu/doc/inference_algorithm.md);
- [Компилятор upstream: от модели до инструкций](vcu128_otpu/doc/compiler.md);
  [слайс openTPU: состав, арбитраж, такт, несколько слайсов](vcu128_otpu/doc/slice.md);
- схемы: [редактируемые структурные схемы](vcu128_otpu/doc/diagrams/README.md),
  [схема слайса в вариантах](vcu128_otpu/doc/diagrams/variants/index.html);
- симуляция и модели: [Lens — потактовый RTL-профиль](vcu128_otpu/sim/lens/README.md),
  [учебный симулятор слайса на Python](vcu128_otpu/sim/pysim/README.md),
  [QuestaSim, анимация, Simulink](vcu128_otpu/sim/inference/README.md),
  [MATLAB: модель LLM + HBM](vcu128_otpu/sim/matlab/README.md);
- [HOG_USAGE.md](HOG_USAGE.md), [AGENTS.md](AGENTS.md) — сборка и правила работы.

## Клонирование и сборка

    git clone --recurse-submodules https://github.com/validol1979-ops/vcu128_otpu_hog.git
    source /tools/Xilinx/Vivado/2024.2/settings64.sh
    ./Hog/Do CREATE otpu                   # или otpu_s4 (четыре слайса)
    ./Hog/Do WORKFLOW -njobs 4 otpu        # ~1,5 ч (otpu_s4 ~4 ч, ≥ 30 ГБ ОЗУ), результат в bin/

Два проекта Hog с общими исходниками: `otpu` — два слайса (цель `vcu128_otpu/target/vcu128.toml`),
`otpu_s4` — четыре слайса (`vcu128_s4.toml`; MoE-модели и Gemma 4 на нём пока не идут, см. TODO).

Сабмодуль `Hog/` — публичный Hog2026.2-6 (`db7af4f`, gitlab.com/hog-cern/Hog,
Apache-2.0); скачивается при клонировании, учётная запись не нужна. Если `Hog/`
пустой (клон без `--recurse-submodules`):

    git submodule update --init

Если gitlab.com недоступен — официальное зеркало на GitHub (тот же коммит):

    git config submodule.Hog.url https://github.com/hog-cern/Hog.git
    git submodule update --init

Для сборки FPGA больше ничего не нужно: RTL openTPU (upstream + локальные патчи) и библиотек
скопированы в `vcu128_otpu/src/`.

## Окружение ПК-стороны и регрессий

Чат, API, `tools/` и регрессии ищут openTPU и окружения Python рядом с репозиторием, в
`../external/`. Подготовить (git, python3.13; ~2 ГБ, torch CPU):

    env/setup_external.sh            # --no-rtl — без окружения cocotb

Скрипт скачивает [FeSens/openTPU](https://github.com/FeSens/openTPU) на коммите `f237dab` в
`../external/rtl/opentpu-fesens/upstream`, собирает рабочую копию
`../external/rtl/opentpu-fesens/patched` = upstream + серия патчей `env/opentpu-patches/`
(кредиты чтения HBM, конфигурация цели в чате, раздача KV-голов на слайсы, таблица эмбеддингов
по памяти слайса и др.) и ставит версии из `env/requirements-pc.txt`
(`../external/rtl/opentpu-fesens/.venv`) и `env/requirements-rtl.txt`
(`../external/rtl/opentpu/.venv`). Для RTL-регрессий нужен Verilator 5.050 в `PATH` или
`~/.local/bin`.

Проверка без платы (нужно 20 passed без skipped):

    cd vcu128_otpu/tools
    PYTHONPATH=../../../external/rtl/opentpu-fesens/patched \
        ../../../external/rtl/opentpu-fesens/.venv/bin/python -m pytest -q test_otpu_eth.py

RTL: `vcu128_otpu/sim/hbm/run.sh`, `vcu128_otpu/sim/eth40/run.sh` (NC = 2, 4, 8),
`vcu128_otpu/sim/thermal/run.sh`.

Модели скачать в `upstream/models/` (открытые, токен HF не нужен; `patched/models` ссылается туда):

    cd ../external/rtl/opentpu-fesens/upstream
    ../.venv/bin/hf download Qwen/Qwen3.5-2B      --local-dir models/Qwen3.5-2B
    ../.venv/bin/hf download Qwen/Qwen3.5-4B      --local-dir models/Qwen3.5-4B

## Запуск модели на плате

Нужны: прошитая плата, линк 40G (на ПК порт с адресом 192.168.41.1/24 и
`ethtool -s <порт> speed 40000 autoneg off`; однократно `sudo
vcu128_otpu/tools/host/install.sh` — sysctl буферов сокетов и юнит systemd, которые
восстанавливают это после перезагрузки, см. `vcu128_otpu/doc/eth40_protocol.md`),
окружение и модель (раздел выше).
Проще всего — `vcu128_otpu/tools/chat_board.sh 2b|4b` (контекст 32k, `CAP=...`). Вручную:

    cd <repo>/../external/rtl/opentpu-fesens/patched
    export OTPU_TARGET=<repo>/vcu128_otpu/target/vcu128.toml
    export PYTHONPATH=.:<repo>/vcu128_otpu/tools
    ../.venv/bin/python <repo>/vcu128_otpu/tools/otpu_chat_eth.py \
        --model qwen35-2b --backend board --wformat fp4 --head-format int8

Чат открывается после загрузки (~30–50 с). Сервер API OpenAI —
`tools/otpu_eth_run.py -m opentpu.serve.api ...`; замер GEMM — `tools/gemm_bench.py`.
С платой одновременно работает только одна программа.

Сверка ответа платы с симулятором ISA — только в конфигурации прошитой сборки: `--backend isa` с
`OTPU_TARGET=.../vcu128.toml` (2 слайса) или `vcu128_s4.toml` (4 слайса); строка `config: ... hash` в
логе чата должна совпадать с платой.

## Температура ПЛИС и HBM, термозащита

SYSMON каждого из трёх SLR и датчики HBM читает логика платы; при перегреве (по умолчанию
ПЛИС ≥ 100 °C, HBM ≥ 95 °C или HBM CATTRIP) она останавливает прогон и не даёт запустить
новый до охлаждения и команды хоста — 40G и регистры при этом работают. Подробно —
[design.md, «Температура и контроль»](vcu128_otpu/doc/design.md#температура-и-контроль).

    PYTHONPATH=vcu128_otpu/tools python vcu128_otpu/tools/otpu_temp.py            # чтение
    PYTHONPATH=vcu128_otpu/tools python vcu128_otpu/tools/otpu_temp.py --watch 2  # опрос
    ... otpu_temp.py --fpga 85 100 10 --hbm 85 95 5   # пороги warn/alarm/гистерезис, °C
    ... otpu_temp.py --resume                         # снять удержание после охлаждения
    vivado -mode batch -nolog -nojournal -source vcu128_otpu/tools/jtag/thermal.tcl   # по JTAG

`Board.info()["temp_c"]` upstream по 40G показывает температуру самого горячего SLR
(формула UltraScale+ ставится `EthTransport` сам).
