#!/usr/bin/env python3
"""Banked copies of upstream otpu_dram.sv / otpu_native_mem.sv for DRAMs over 1 GiB in Verilator.

Verilator 5.050 refuses an unpacked range over 2^28 elements ("Width of bit range is huge;
vector of over 1 billion bits"), and otpu_dram keeps a slice's DRAM as one array
`logic [31:0] mem [WORDS]`: 2^28 words = 1 GiB is the most it builds. Images over that
(Qwen3.5-4B at S = 1: 2.47 GiB, rounded up to 4 GiB) stop the RTL build. The copy splits the
array into NB banks of at most 2^28 words, `mem[NB][BWORDS]`, and turns every access
`mem[x]` into `mem[x >> BW][x & mask]`; the image load ($fread, word by word: it takes whole variables only) and the dump
address the banks.
For WORDS <= 2^28 it is the same memory with one bank.

The --mem axi model, sim/verilator/otpu_native_mem.sv, already splits its words in two arrays
(mem_lo / mem_hi: 2 GiB at most) and keeps a channel buffer `chm [WORDS / 2]`; `native_banked`
puts the words in the same NB banks (a 16-word beat never straddles two) and loads the image and
the channel files word by word, so 4 GiB per slice builds as well.

The upstream files are not edited: `patch(rtlsim)` writes the copies under sim/lens/out/rtl/,
points rtlsim's source list at the first (rtlsim joins RTL / name, and an absolute name replaces
RTL) and wraps rtlsim.build to swap the second (build_top names it itself). The transforms check
the fragments they rewrite and stop if upstream changed them.
"""
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent


def banked(src: str) -> str:
    decl = "  logic [31:0] mem [WORDS];"
    fread = "        nread = $fread(mem, fd);"
    assert src.count(decl) == 1 and src.count(fread) == 1, \
        "upstream otpu_dram.sv changed: review dram_banked.py"
    out, i = [], 0
    while True:                      # every mem[...] (balanced brackets), except the declaration
        j = src.find("mem[", i)
        if j < 0:
            out.append(src[i:])
            break
        out.append(src[i:j])
        k, depth = j + 4, 1
        while depth:
            depth += {"[": 1, "]": -1}.get(src[k], 0)
            k += 1
        expr = src[j + 4:k - 1]
        out.append(f"mem[bank_of({expr})][word_of({expr})]")
        i = k
    src = "".join(out)
    # $fread takes whole variables only: big-endian words one by one (its order), up to EOF
    src = src.replace(fread,
                      "        for (longint i = 0; i < WORDS; i++) begin\n"
                      "          nread = $fread(w32, fd);\n"
                      "          if (nread != 4) break;\n"
                      "          mem[bank_of(i)][word_of(i)] = w32;\n"
                      "        end")
    src = src.replace(
        decl,
        "  // banked (vcu128_otpu sim/lens/dram_banked.py): Verilator builds ranges up to 2^28\n"
        "  localparam int BW = (AW > 28) ? 28 : AW;\n"
        "  localparam int NB = (WORDS + (1 << BW) - 1) >> BW;\n"
        "  logic [31:0] mem [NB][1 << BW];\n"
        "  logic [31:0] w32;\n"
        "  function automatic int unsigned bank_of(input longint unsigned a);\n"
        "    return int'(a >> BW);\n"
        "  endfunction\n"
        "  function automatic int unsigned word_of(input longint unsigned a);\n"
        "    return int'(a & ((64'd1 << BW) - 1));\n"
        "  endfunction")
    assert "logic [31:0] mem [NB][1 << BW];" in src and "mem[" in src
    assert not re.search(r"\bmem\[(?!bank_of|NB)", src), "an access was not rewritten"
    return src


BANKS = (
    "  localparam int BW = (AW > 28) ? 28 : AW;\n"
    "  localparam int NB = (WORDS + (1 << BW) - 1) >> BW;\n"
    "  function automatic int unsigned bank_of(input longint unsigned a);\n"
    "    return int'(a >> BW);\n"
    "  endfunction\n"
    "  function automatic int unsigned word_of(input longint unsigned a);\n"
    "    return int'(a & ((64'd1 << BW) - 1));\n"
    "  endfunction\n")


def native_banked(src: str) -> str:
    def sub(a, b):
        nonlocal src
        assert src.count(a) == 1, f"upstream otpu_native_mem.sv changed: review dram_banked.py ({a!r})"
        src = src.replace(a, b)
    sub("""  // the image's words: word i is mem_lo[i] below H, else mem_hi[i - H] (two arrays, as Verilator
  // takes at most 2^28 entries in one: 1 GiB each); a beat (16 words) is in one of them
  localparam int H = WORDS / 2;
  logic [31:0] mem_lo [H];
  logic [31:0] mem_hi [WORDS - H];
  function automatic logic [31:0] rdw(input int i);
    return i < H ? mem_lo[i] : mem_hi[i - H];
  endfunction
  task automatic wrw(input int i, input logic [31:0] v);
    if (i < H) mem_lo[i] = v;
    else mem_hi[i - H] = v;
  endtask
""", "  // the image's words in NB banks of up to 2^28, the most one array takes in this\n"
        "  // simulator (vcu128_otpu sim/lens/dram_banked.py); a beat (16 words) is in one bank\n"
        "  localparam int AW = $clog2(WORDS);\n" + BANKS +
        """  logic [31:0] mem [NB][1 << BW];
  logic [31:0] w32;
  function automatic logic [31:0] rdw(input int i);
    return mem[bank_of(i)][word_of(i)];
  endfunction
  task automatic wrw(input int i, input logic [31:0] v);
    mem[bank_of(i)][word_of(i)] = v;
  endtask
""")
    sub("""              if (s[k] && b < H) mem_lo[b + k / 4][8 * (k % 4) +: 8] <= wq_d[c][0][8 * k +: 8];
              else if (s[k]) mem_hi[b - H + k / 4][8 * (k % 4) +: 8] <= wq_d[c][0][8 * k +: 8];
""", """              if (s[k]) mem[bank_of(b + k / 4)][word_of(b + k / 4)][8 * (k % 4) +: 8]
                  <= wq_d[c][0][8 * k +: 8];
""")
    sub("""  logic [31:0] chm [WORDS / 2];
""", "")
    sub("""    for (int i = 0; i < H; i++) mem_lo[i] = '0;
    for (int i = 0; i < WORDS - H; i++) mem_hi[i] = '0;
""", """    for (int i = 0; i < WORDS; i++) wrw(i, '0);
""")
    sub("""          nread = $fread(mem_lo, fd);  // the second continues where the first stopped
          nread = $fread(mem_hi, fd);
""", """          for (int i = 0; i < WORDS; i++) begin  // $fread takes whole variables only
            nread = $fread(w32, fd);
            if (nread != 4) break;
            wrw(i, w32);
          end
""")
    sub("""          for (int i = 0; i < WORDS / 2; i++) chm[i] = '0;
          fd = $fopen($sformatf("%s/ch%0d.bin", dir, 2 * SID + c), "rb");
          if (fd != 0) begin
            nread = $fread(chm, fd);
            $fclose(fd);
          end
          for (int j = 0; j < WORDS / 2; j++) wrw(lbeat(j / 16, c) * 16 + j % 16, chm[j]);
""", """          fd = $fopen($sformatf("%s/ch%0d.bin", dir, 2 * SID + c), "rb");
          for (int j = 0; j < WORDS / 2; j++) begin   // a short file leaves zeros
            w32 = '0;
            if (fd != 0) begin
              nread = $fread(w32, fd);
              if (nread != 4) w32 = '0;
            end
            wrw(lbeat(j / 16, c) * 16 + j % 16, w32);
          end
          if (fd != 0) $fclose(fd);
""")
    assert not any(n in src for n in ("mem_lo", "mem_hi", "chm")), "an access was not rewritten"
    return src


def patch(rtlsim) -> Path:
    """Point rtlsim at the banked copy (call before the first build)."""
    up = rtlsim.RTL / "mem" / "otpu_dram.sv"
    out = HERE / "out" / "rtl"
    out.mkdir(parents=True, exist_ok=True)
    dst = out / "otpu_dram.sv"
    text = banked(up.read_text())
    if not dst.exists() or dst.read_text() != text:
        dst.write_text(text)
    i = rtlsim.RTL_SOURCES.index("mem/otpu_dram.sv")
    rtlsim.RTL_SOURCES[i] = str(dst)
    nat_up = rtlsim.TB / "otpu_native_mem.sv"
    nat = out / "otpu_native_mem.sv"
    text = native_banked(nat_up.read_text())
    if not nat.exists() or nat.read_text() != text:
        nat.write_text(text)
    build = rtlsim.build
    if not getattr(build, "banked", False):
        def banked_build(top, sources, params=None):
            return build(top, [nat if Path(x) == nat_up else x for x in sources], params)
        banked_build.banked = True
        rtlsim.build = banked_build
    return dst


if __name__ == "__main__":
    import sys
    src = Path(sys.argv[1]).read_text()
    sys.stdout.write(native_banked(src) if "module otpu_native_mem" in src else banked(src))
