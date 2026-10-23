#!/usr/bin/env python3
"""Generate Questa-only net wiring for mixed procedural/port array drivers.

The versioned upstream RTL is never edited. Questa 2024.1 reports vsim-3839
on wc: column zero is driven by module outputs, later columns by always_ff.
Give each later column its own register and make the shared array a net.
"""
import sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:])
s = src.read_text()
old = '''  always_ff @(posedge clk)
    for (int j = 1; j < MCOLS; j++) wc[j] <= wc[j-1];'''
new = '''  for (genvar j = 1; j < MCOLS; j++) begin : g_questa_wc
    logic [D-1:0][15:0] wc_q;
    always_ff @(posedge clk) wc_q <= wc[j-1];
    assign wc[j] = wc_q;
  end'''
assert s.count(old) == 1, 'Upstream changed: review compatibility transform'
s = s.replace('logic [D-1:0][15:0] wc [MCOLS];', 'wire [D-1:0][15:0] wc [MCOLS];').replace(old, new)
dst.write_text(s)
