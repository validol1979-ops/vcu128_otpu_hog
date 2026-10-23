#!/usr/bin/env bash
# Сборка варианта TikZ: slice_tikz.pdf (lualatex) и превью slice_tikz.png (~1800 px).
set -euo pipefail
cd "$(dirname "$0")"
lualatex -interaction=nonstopmode -halt-on-error slice_tikz.tex > /dev/null
pdftoppm -png -singlefile -scale-to-x 1800 -scale-to-y -1 slice_tikz.pdf slice_tikz
rm -f slice_tikz.aux slice_tikz.log
echo "slice_tikz.pdf, slice_tikz.png"
