#!/usr/bin/env bash
# Внешние зависимости ПК-стороны и регрессий (вне репозитория, рядом с ним):
#   <ext>/rtl/opentpu-fesens/upstream  openTPU FeSens, коммит f237dab (Apache-2.0)
#   <ext>/rtl/opentpu-fesens/.venv     чат, API, компилятор, симулятор ISA, test_otpu_eth.py
#   <ext>/rtl/opentpu/.venv            cocotb для vcu128_otpu/sim/{hbm,eth40}/run.sh
# <ext> по умолчанию ../external относительно корня репозитория: этот путь ждут
# скрипты и инструкции. Нужны git и python3.13; Verilator 5.050 ставится отдельно.
#   env/setup_external.sh [--no-rtl] [<ext>]
set -euo pipefail

OPENTPU_URL=https://github.com/FeSens/openTPU.git
OPENTPU_SHA=f237dab2f196855a59a083b1454786df8f01291f
PYTHON=${PYTHON:-python3.13}

env_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$env_dir/.." && pwd)
rtl=1
if [ "${1:-}" = --no-rtl ]; then rtl=0; shift; fi
ext=${1:-$repo/../external}
mkdir -p "$ext/rtl"
ext=$(cd "$ext" && pwd)

up=$ext/rtl/opentpu-fesens/upstream
if [ ! -d "$up/.git" ]; then
    mkdir -p "$up"
    git -C "$up" init -q
    git -C "$up" remote add origin "$OPENTPU_URL"
fi
git -C "$up" fetch -q --depth 1 origin "$OPENTPU_SHA"
git -C "$up" checkout -q "$OPENTPU_SHA"
echo "openTPU: $(git -C "$up" rev-parse --short HEAD) в $up"

venv=$ext/rtl/opentpu-fesens/.venv
[ -x "$venv/bin/python" ] || "$PYTHON" -m venv "$venv"
"$venv/bin/pip" install -q --upgrade pip
"$venv/bin/pip" install -q -r "$env_dir/requirements-pc.txt" \
    --extra-index-url https://download.pytorch.org/whl/cpu
"$venv/bin/python" -c "import torch, transformers; print('ПК-окружение:', torch.__version__, transformers.__version__)"

if [ "$rtl" = 1 ]; then
    venv=$ext/rtl/opentpu/.venv
    [ -x "$venv/bin/python" ] || "$PYTHON" -m venv "$venv"
    "$venv/bin/pip" install -q --upgrade pip
    "$venv/bin/pip" install -q -r "$env_dir/requirements-rtl.txt"
    "$venv/bin/python" -c "import cocotb; print('RTL-окружение: cocotb', cocotb.__version__)"
fi

[ "$ext" = "$(cd "$repo/.." && pwd)/external" ] ||
    echo "Внимание: скрипты репозитория ищут ../external; создайте ссылку: ln -s $ext $repo/../external"
