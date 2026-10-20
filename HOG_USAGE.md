# Как работать с Hog: VCU128 openTPU

| Назначение | Путь |
|---|---|
| Проект Hog | `otpu` |
| Настройки | `Top/otpu/hog.conf` |
| Состав HDL, IP, ограничений | `Top/otpu/list/` (others.src, ips.src, sources.con) |
| Исходники | `vcu128_otpu/src/`, `vcu128_otpu/ip/`, `vcu128_otpu/constr/` |
| Приложения Vitis | нет (вариант A) |
| Vivado-проект | `Projects/otpu/otpu.xpr` (генерируется) |
| Результаты | `bin/otpu-v<версия>-<SHA>/` |

```bash
git clone --recurse-submodules https://github.com/validol1979-ops/vcu128_otpu_hog.git
source /tools/Xilinx/Vivado/2024.2/settings64.sh
./Hog/Do CREATE otpu
./Hog/Do WORKFLOW -njobs 4 otpu
```

Projects/ и bin/ не редактировать.
После CREATE `git status` должен быть чистым. Ограничения CDC — Tcl-файлы с
`nosynth` в `sources.con` (последними; `otpu_mem_ch.tcl` с
`scoped_to_ref=otpu_mem_ch`, как у upstream).
