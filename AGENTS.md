# Работа с этим проектом Hog

Сначала прочитать README.md и HOG_USAGE.md.
Устройство проекта — `vcu128_otpu/doc/design.md`; журнал и текущее состояние —
`vcu128_otpu/doc/journal.md`. В общей рабочей области дополнительно:
../AGENTS.md, ../HOG_AGENT_HANDOFF.md, ../HOG_MIGRATION_STATUS.md.

- Два проекта Hog (вариант A, только Vivado), исходники общие (решение пользователя 23.10):
  `otpu` — S = 2 (цель `target/vcu128.toml`, все модели, кроме MoE), `otpu_s4` — S = 4 (цель
  `target/vcu128_s4.toml`, `[generics]` S/ARCH_HASH и директивы реализации в его hog.conf; Qwen3.5-2B,
  Gemma и MoE на нём не идут). Создание — `./Hog/Do CREATE <проект>`, сборка —
  `./Hog/Do WORKFLOW -njobs 4 <проект>`; S = 4 — память ≥ 30 ГБ, ~4 ч.
  Параллельные Vivado (в т. ч. других агентов) допустимы при свободных
  ресурсах (`free -g`, загрузка CPU) — не ждать; во время сборки рабочую копию не менять (Hog
  берёт исходники на месте) — либо собирать из отдельного клона.
- Hog/ — сабмодуль на Hog2026.2-6 (db7af4f); Hog/ не патчить.
- `vcu128_otpu/src/otpu-fesens/` — копия RTL upstream openTPU (FeSens,
  Apache-2.0) = `upstream/` + патчи; обновлять только
  `../external/rtl/opentpu-fesens/scripts/sync_copy.sh vcu128_otpu/src/otpu-fesens`
  (из `patched/`, пишет UPSTREAM.json), сверка — `sync_copy.sh --check`.
  Править upstream разрешено (пользователь, 21.10.2026: «по максимуму»), но только
  серией патчей `../external/rtl/opentpu-fesens/patches/NNNN-*.patch` поверх чистого
  `upstream/` (сам `upstream/` не менять; список и SHA базы — в UPSTREAM.json; копия
  `src/otpu-fesens/` = upstream + патчи; рабочая копия `patched/` и скрипты
  `scripts/patched.sh`, `export_patches.sh` — README библиотеки). Каждый патч — тесты upstream
  (`tests/test_config_matrix.py` и затронутые), RTL = ISA бит-в-бит, наши регрессии;
  запись в `../external/CATALOG.md`.
  Цель — `vcu128_otpu/target/vcu128.toml` (`OTPU_TARGET=<путь>` для
  инструментов upstream); параметры верхнего уровня должны совпадать с ней.
- Регрессии: `vcu128_otpu/sim/hbm/run.sh`, `vcu128_otpu/sim/eth40/run.sh`,
  `vcu128_otpu/sim/thermal/run.sh` (термоконтроль, 8 тестов),
  pytest `vcu128_otpu/tools/test_otpu_eth.py` (окружение
  `../external/rtl/opentpu-fesens/.venv` и
  `PYTHONPATH=../external/rtl/opentpu-fesens/patched`, не `upstream/`: без него
  тесты совместимости с upstream Board молча пропускаются — пропуски не считать
  успехом, нужно все passed и 0 skipped).
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
  `<docs>/vcu128/` (UG1302, мастер-XDC).
