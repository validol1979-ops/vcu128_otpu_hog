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
- [MATLAB: модель LLM + HBM](vcu128_otpu/sim/matlab/README.md);
- [HOG_USAGE.md](HOG_USAGE.md), [AGENTS.md](AGENTS.md) — сборка и правила работы.

## Клонирование и сборка

    git clone --recurse-submodules https://github.com/validol1979-ops/vcu128_otpu_hog.git
    source /tools/Xilinx/Vivado/2024.2/settings64.sh
    ./Hog/Do CREATE otpu
    ./Hog/Do WORKFLOW -njobs 4 otpu        # ~2 ч, результат в bin/

Сабмодуль `Hog/` — публичный Hog2026.2-6 (`db7af4f`, gitlab.com/hog-cern/Hog).

## Запуск модели на плате

Нужны: прошитая плата, линк 40G (на ПК порт с адресом 192.168.41.1/24 и
`ethtool -s <порт> speed 40000 autoneg off`), upstream openTPU с окружением
(`external/rtl/opentpu-fesens` общей рабочей области: `upstream/` и `.venv`) и
скачанная модель в `upstream/models/`.

    cd <xilinx>/external/rtl/opentpu-fesens/upstream
    export OTPU_TARGET=<repo>/vcu128_otpu/target/vcu128.toml
    export PYTHONPATH=.:<repo>/vcu128_otpu/tools
    ../.venv/bin/python <repo>/vcu128_otpu/tools/otpu_chat_eth.py \
        --model qwen35-2b --backend board --wformat fp4 --head-format int8

Чат открывается после загрузки (~30–50 с). Сервер API OpenAI —
`tools/otpu_eth_run.py -m opentpu.serve.api ...`; замер GEMM — `tools/gemm_bench.py`.
С платой одновременно работает только одна программа.
