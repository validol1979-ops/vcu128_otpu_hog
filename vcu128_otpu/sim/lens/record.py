#!/usr/bin/env python3
"""Lens profiles (upstream openTPU profiler) of one decode token on the VCU128 configuration.

The tokens before --pos run on the ISA simulator, the traced one on the Verilator RTL of the
slice (upstream otpu_top, target/vcu128.toml: S=1 D=128 MCOLS=4 LANES=8, PAIR/DSTEP/STREAM as
in the bitstream). Same machinery as `python -m opentpu.lens record qwen-tiny --board`, extended
to LFM2 (the model that runs on the card). Upstream is not changed.

    workloads: lfm2-tiny (random LFM2, seconds), lfm2 (models/LFM2.5-230M, minutes),
               qwen35 / qwen35-4b (models/Qwen3.5-2B / -4B; --wformat fp4 --head-format int8 as
               on the card; the 4B image is over 1 GiB: banked DRAM, dram_banked.py),
               qwen-tiny (random Qwen3, upstream's workload)
    memory:    fixed (behavioural DRAM, upstream default) or axi (otpu_native_dram + the
               two-channel native model; --lat/--stall/--bw tune it, an HBM-like guess by default)

Run from the repository root with the upstream venv (sim/lens/run.sh does this).
"""
import argparse
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TARGET = HERE.parent.parent / "target" / "vcu128.toml"
os.environ.setdefault("OTPU_TARGET", str(TARGET))
# board_config() keeps the optional features off unless asked; the bitstream has them on
for k in ("PAIR", "DSTEP", "STREAM"):
    os.environ.setdefault(f"OTPU_{k}", "1")

LFM2_KINDS = ("conv", "conv", "attn", "conv", "attn", "conv")


def tiny_lfm2():
    """A random LFM2 with the real block mix (the upstream test's model, tests/test_lfm2.py)."""
    import torch
    import transformers
    from opentpu.llm.lfm2 import Spec
    torch.manual_seed(0)
    hc = transformers.Lfm2Config(
        hidden_size=256, num_hidden_layers=len(LFM2_KINDS), num_attention_heads=4,
        num_key_value_heads=2, intermediate_size=512, vocab_size=1000, norm_eps=1e-5,
        layer_types=["full_attention" if k == "attn" else "conv" for k in LFM2_KINDS],
        conv_L_cache=3, conv_bias=False, block_auto_adjust_ff_dim=False,
        tie_word_embeddings=True, max_position_embeddings=4096,
        rope_parameters={"rope_type": "default", "rope_theta": 1e6})
    m = transformers.Lfm2ForCausalLM(hc).float().eval()
    with torch.no_grad():
        for n, p in m.named_parameters():
            if "norm" in n:
                p.copy_(1 + 0.1 * torch.randn_like(p))
    W = {k: v.float().numpy() for k, v in m.state_dict().items()}
    return Spec(256, LFM2_KINDS, 4, 2, 64, 512, 1000), W


def record_lfm2(real, pos: int, run_kw: dict, wformat: str, head_format=None, dram_gib=0,
                check=False):
    import numpy as np
    from opentpu import lens, rtlsim
    from opentpu.isasim import board_config
    from opentpu.llm.qwen3 import Engine, load_weights
    from opentpu.profile import parse
    if real:
        from opentpu.llm import load_spec
        model = Path(lens.ROOT) / "models" / real
        spec, W = load_spec(model), load_weights(model)
        name = real
    else:
        spec, W = tiny_lfm2()
        name = "tiny LFM2"
    cap = max(256, pos + 1)
    uarch = dict(rtlsim.BOARD_UARCH)
    from opentpu.llm.qwen3 import PREFILL_ROWS
    probe = spec.image(board_config(DRAM_BYTES=1 << 40), cap, 1, PREFILL_ROWS, wformat,
                       head_format)
    size = 1 << max(20, (probe.nbytes - 1).bit_length())
    if dram_gib:
        size = max(size, int(dram_gib * 2**30))
    cfg = board_config(DRAM_BYTES=size)
    if size > 1 << 30 or dram_gib:      # Verilator builds arrays of at most 2^28 words
        import dram_banked
        print(f"DRAM {size / 2**30:g} GiB per slice: banked otpu_dram ({dram_banked.patch(rtlsim)})")
    holder = {}

    class Checked(lens._Capture):
        """--check: the traced token once more on the ISA simulator; the DRAMs must match."""
        def run(self, programs):
            if not (self.traced and check):
                return super().run(programs)
            before = [sl.dram.copy() for sl in self.isa.machine.slices]
            st = super().run(programs)
            rtl = [sl.dram.copy() for sl in self.isa.machine.slices]
            for sl, d in zip(self.isa.machine.slices, before):
                sl.dram[:] = d
            self.isa.run(programs)
            for s, (sl, r) in enumerate(zip(self.isa.machine.slices, rtl)):
                bad = np.flatnonzero(sl.dram != r)
                print(f"check slice {s}: RTL DRAM = ISA DRAM" if not len(bad) else
                      f"check slice {s}: {len(bad)} bytes differ, first at {bad[0]:#x}",
                      flush=True)
                holder["mismatch"] = holder.get("mismatch", 0) + len(bad)
            return st

    def mk(c, images):
        holder["b"] = Checked(c, images, uarch, run_kw)
        return holder["b"]
    eng = Engine(spec, W, cap=cap, cfg=cfg, backend=mk, wformat=wformat, head_format=head_format)
    toks = [int(t) for t in np.random.default_rng(1).integers(0, spec.vocab, pos + 1)]
    t0 = time.time()
    for t in toks[:-1]:
        eng.step(t)
    print(f"{pos} tokens on the ISA simulator in {time.time() - t0:.1f}s", flush=True)
    holder["b"].traced = True
    t0 = time.time()
    eng.step(toks[-1])
    print(f"traced token on the RTL in {time.time() - t0:.1f}s", flush=True)
    programs, st = holder["b"].last
    p = parse(st["trace"], cfg, programs,
              f"{name} {wformat} token at pos {pos} (VCU128 config, S={cfg.S})")
    p.cycles = st["cycles"]
    if holder.get("mismatch"):
        raise SystemExit("--check: the RTL and the ISA simulator disagree")
    return p, cfg, uarch


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("workload", choices=["lfm2-tiny", "lfm2", "qwen35", "qwen35-4b", "qwen-tiny"])
    ap.add_argument("--pos", type=int, default=8, help="traced token position (default 8)")
    ap.add_argument("--wformat", default="int8", help="weight format: int8, fp4, ...")
    ap.add_argument("--head-format", default=None, help="LM head format (default: the model's rule)")
    ap.add_argument("--dram-gib", type=float, default=0,
                    help="at least this DRAM per slice (forces the banked otpu_dram; for tests)")
    ap.add_argument("--check", action="store_true",
                    help="also run the traced token on the ISA simulator and compare the DRAMs")
    ap.add_argument("--mem", choices=["fixed", "axi"], default="fixed")
    ap.add_argument("--lat", type=int, default=40, help="axi: read latency, core cycles")
    ap.add_argument("--stall", type=int, default=5, help="axi: percent of withheld handshakes")
    ap.add_argument("--bw", type=int, default=100, help="axi: percent of a beat/cycle/channel")
    ap.add_argument("--bucket", type=int, default=64, help="cycles per counter bucket")
    ap.add_argument("-o", "--out", required=True, help="output .otpuprof")
    ap.add_argument("--html", help="also write a standalone Lens page")
    a = ap.parse_args()
    if a.mem == "axi":                    # rtlsim reads the model's knobs at import
        os.environ.update(OTPU_AXI="1", OTPU_LAT=str(a.lat), OTPU_STALL=str(a.stall),
                          OTPU_BW=str(a.bw))
    from opentpu import lens
    run_kw = {"plusargs": [f"+bucket={a.bucket}"], "axi": a.mem == "axi"}
    if a.workload == "qwen-tiny":
        d = lens.record("qwen-tiny", board=True, pos=a.pos, bucket=a.bucket, axi=a.mem == "axi")
    else:
        real = {"lfm2": "LFM2.5-230M", "qwen35": "Qwen3.5-2B",
                "qwen35-4b": "Qwen3.5-4B"}.get(a.workload)
        p, cfg, uarch = record_lfm2(real, a.pos, run_kw, a.wformat, a.head_format, a.dram_gib,
                                    a.check)
        d = lens._mem(lens.to_data(p, uarch), cfg, a.mem == "axi")
    if a.mem == "axi":
        d["notes"] = [{"level": "info", "text": (
            f"Memory model: otpu_native_dram + native channel model, latency {a.lat}, stall "
            f"{a.stall}%, bandwidth {a.bw}% (an HBM-like assumption, not the HBM IP).")}] + \
            list(d.get("notes", []))
    lens.save([d], a.out)
    print(f"{d['name']}: {d['cycles']} cycles; wrote {a.out}")
    if a.html:
        Path(a.html).write_text(lens.render(lens.load(a.out)))
        print(f"wrote {a.html}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
