#!/usr/bin/env bash
# Сборка структурной схемы слайса в KiCad 10: генератор → ERC → SVG/PDF → PNG-превью.
#   ./build.sh            (из любого каталога)
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
python3 gen.py
sch=slice_kicad.kicad_sch
kicad-cli sch erc --severity-all --exit-code-violations -o erc.rpt "$sch" || { cat erc.rpt; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
kicad-cli sch export svg -o "$tmp" "$sch" >/dev/null
mv "$tmp/slice_kicad.svg" slice_kicad.svg
kicad-cli sch export pdf -o slice_kicad.pdf "$sch" >/dev/null
inkscape slice_kicad.svg --export-type=png --export-filename=slice_kicad.png -w 1800 2>/dev/null
rm -f slice_kicad.kicad_prl
echo "ok: slice_kicad.{kicad_sch,svg,pdf,png}; ERC: 0 нарушений"
