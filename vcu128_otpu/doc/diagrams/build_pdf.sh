#!/usr/bin/env bash
# Rebuild the three-page structural diagram with LuaLaTeX/TikZ.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
mkdir -p build
for pass in 1 2; do
    lualatex -interaction=nonstopmode -halt-on-error -output-directory=build \
        project_structure.tex > "build/compile-${pass}.log" 2>&1
done
cp build/project_structure.pdf project_structure.pdf
printf 'PDF: %s/project_structure.pdf\n' "$PWD"
