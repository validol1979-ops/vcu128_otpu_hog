#!/usr/bin/env bash
# Render the five state diagrams of doc/inference_algorithm.md (Graphviz dot): SVG + PDF.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
for f in *.dot; do
  dot -Tsvg "$f" -o "${f%.dot}.svg"
  dot -Tpdf "$f" -o "${f%.dot}.pdf"
done
echo "rendered: $(ls *.svg | tr '\n' ' ')"
