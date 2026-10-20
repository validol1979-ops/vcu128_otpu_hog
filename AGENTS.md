# Работа с этим проектом Hog

Сначала прочитать README.md и HOG_USAGE.md.
Устройство проекта — `vcu128_otpu/doc/design.md`; журнал и текущее состояние —
`vcu128_otpu/doc/journal.md`. В общей рабочей области дополнительно:
../AGENTS.md, ../HOG_AGENT_HANDOFF.md, ../HOG_MIGRATION_STATUS.md.

- Проект Hog один: `otpu` (вариант A, только Vivado). Создание —
  `./Hog/Do CREATE otpu`, сборка — `./Hog/Do WORKFLOW -njobs 4 otpu`.
  Vivado-сборки по одной; во время сборки рабочую копию не менять (Hog
  берёт исходники на месте) — либо собирать из отдельного клона.
- Hog/ — сабмодуль на Hog2026.2-6 (db7af4f); Hog/ не патчить.
- `vcu128_otpu/src/otpu-fesens/` — копия RTL upstream openTPU (FeSens,
  Apache-2.0) без правок; обновлять копированием из
  `../external/rtl/opentpu-fesens/upstream` с правкой UPSTREAM.json.
  Цель — `vcu128_otpu/target/vcu128.toml` (`OTPU_TARGET=<путь>` для
  инструментов upstream); параметры верхнего уровня должны совпадать с ней.
- Регрессии: `vcu128_otpu/sim/hbm/run.sh`, `vcu128_otpu/sim/eth40/run.sh`,
  pytest `vcu128_otpu/tools/test_otpu_eth.py` (окружение
  `../external/rtl/opentpu-fesens/.venv` и
  `PYTHONPATH=../external/rtl/opentpu-fesens/upstream`: без него два теста
  совместимости с upstream Board молча пропускаются — 14 passed + 2 skipped
  не считать успехом, нужно 16 passed).
- Перед признанием сборки эталонной — регрессии, WORKFLOW из чистого клона,
  тайминг (WNS/WHS), ресурсы, комплект артефактов (bit, ltx, отчёты).
- В конце работы записывать в журнал проверки, SHA, логи, активные процессы.

## Плата и стенд

- VCU128 Rev1.0, xcvu37p-fsvh2892-2L-e. HBM2 8 ГБ (два стека), опора HBM —
  DDR4_CLK_100MHZ; такты ядра — QDR4_CLK_100MHZ. CPU_RESET (BM29).
- 40G: QSFP1 (GTY квад 135) — пассивный DAC — ConnectX-3 `enp8s0` на ПК
  (отдельная подсеть, MTU 9000). Протокол — `vcu128_otpu/doc/eth40_protocol.md`.
- JTAG-to-AXI (`jtag_axi_0`) — второй мастер регистров, отладка без 40G.
- Документация платы — вне репозитория:
  UG1302 и мастер-XDC VCU128 Rev1.0 с сайта AMD.
