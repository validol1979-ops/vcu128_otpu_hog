# vcu128_otpu_hog

Ускоритель языковых моделей openTPU ([FeSens/openTPU](https://github.com/FeSens/openTPU),
Apache-2.0) на отладочной плате AMD VCU128 (xcvu37p-fsvh2892-2L-e): веса в HBM2
(8 ГБ на плате), связь с ПК по 40G Ethernet (QSFP1 → ConnectX-3), JTAG-to-AXI для
отладки. Проект Hog, вариант A (только Vivado).

## Состояние (19.10.2026)

Работает на плате (сборка `a8ddbc5`, 1 вычислительный блок, ядро 100 МГц):

| Что | Результат |
|---|---|
| LFM2.5-230M, int8 | ответ совпадает с эталонным симулятором; 51,3 ток/с на плате, 30,4 с учётом обмена |
| Qwen3.5-2B, 4-bit | 9,6 ток/с, отвечает по-русски; чат и API в стиле OpenAI |
| GEMM INT8, 2048×2048 | 93,7 GOPS (91,5 % пика), результат побитно = симулятор |
| HBM ↔ ПК по 40G | 2,2–2,75 ГБ/с, данные сверены |

Сборка ещё не эталонная (тайминг 40G-части не закрыт на 0,22 нс). План разгона
(частота, несколько вычислительных блоков, ×10–15 к GEMM) — [TODO](vcu128_otpu/doc/TODO.md).

Документы:
- [Журнал](vcu128_otpu/doc/journal.md) — решения, найденные ошибки, все замеры;
- [Устройство](vcu128_otpu/doc/design.md) — блоки, такты, карта адресов;
- [Протокол 40G](vcu128_otpu/doc/eth40_protocol.md);
- [Как идёт инференс: пути данных, ISA, один слой](vcu128_otpu/doc/inference.md);
- [Алгоритм работы по уровням с диаграммами состояний](vcu128_otpu/doc/inference_algorithm.md);
- [Компилятор upstream: от модели до инструкций, пример на VCU128](vcu128_otpu/doc/compiler.md);
- [Слайс openTPU: состав, арбитраж, алгоритм такта, несколько слайсов](vcu128_otpu/doc/slice.md);
  схема слайса в вариантах TikZ / KiCad / SVG / изометрия —
  [сравнение](vcu128_otpu/doc/diagrams/variants/index.html), [описание](vcu128_otpu/doc/diagrams/README.md);
- [Lens: потактовый RTL-профиль LFM2.5-230M на конфигурации VCU128](vcu128_otpu/sim/lens/README.md);
- [Учебный симулятор слайса на Python: анимация путей данных, графики](vcu128_otpu/sim/pysim/README.md);
- [QuestaSim, анимация инференса и Simulink](vcu128_otpu/sim/inference/README.md);
- [Редактируемые структурные схемы](vcu128_otpu/doc/diagrams/README.md);
- [MATLAB: модель LLM + HBM](vcu128_otpu/sim/matlab/README.md);
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
