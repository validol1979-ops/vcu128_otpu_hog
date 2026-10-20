"""GEMM on the openTPU matrix unit of the VCU128 over 40G: cycles, GOPS, check.

out[M, N] = A[M, K] @ W[N, K]^T with upstream's ol.dot (block-scaled int8 operands, fp32
accumulation; A quantized on the fly, W streamed from HBM). Each shape is compiled with
upstream's compiler for the board's configuration (device_config of its CFG registers),
run on the board (BoardBackend over EthTransport), and its output compared with the ISA
simulator (bit-exact expected) and with float64 numpy (relative error of the quantization).
GOPS = 2 M N K / (cycles / f_core); the cycles are the board's own counter of the run.

    PYTHONPATH=<upstream>:vcu128_otpu/tools python vcu128_otpu/tools/gemm_bench.py \\
        [--host 192.168.41.2] [--k 2048] [--n 2048] [--m 1,4,8,16]
"""

import argparse
import dataclasses
import time

import numpy as np

from opentpu import language as ol
from opentpu.host.board import Board, BoardBackend, device_config
from opentpu.runtime import Input, Output, Weight, collect, compile_kernel, run

from otpu_eth import BOARD_IP, EthTransport


@ol.jit
def gemm(a, w, out):
    ol.store(out, ol.dot(ol.load(a), w))


def bench(host, cfg, khz, M, N, K, reps, rng):
    A = rng.standard_normal((M, K)).astype(np.float32)
    W = (rng.standard_normal((N, K)) / np.sqrt(K)).astype(np.float32)
    args = dict(a=Input(A), w=Weight(W, 0), out=Output((M, N)))
    # images span the configuration's DRAM: compile for a 64 MiB one, so the program area
    # fits after it in the board's (cfg) memory
    compiled, images = compile_kernel(gemm, dataclasses.replace(cfg, DRAM_BYTES=1 << 26), **args)

    isa = run(compiled, images, "isa").outputs["out"]
    be = BoardBackend(cfg, images, transport=EthTransport(host))
    try:
        cycles = []
        for _ in range(reps):
            st = be.run(compiled.programs)
            cycles.append(int(st["cycles"]))
        n_img = len(images[0])
        dram = np.asarray(be.read(0, 0, n_img), np.uint8).copy()
    finally:
        be.close()
    card = collect(compiled, [dram], [None], {}).outputs["out"]

    ref = A.astype(np.float64) @ W.astype(np.float64).T
    exact = np.array_equal(card.view(np.uint32), isa.view(np.uint32))
    rel = float(np.linalg.norm(card - ref) / np.linalg.norm(ref))
    cyc = min(cycles)
    secs = cyc / (khz * 1e3)
    gops = 2 * M * N * K / secs / 1e9
    wbytes = N * K                    # int8 weights streamed once per row group
    return dict(M=M, N=N, K=K, cycles=cyc, us=secs * 1e6, gops=gops,
                wgbs=wbytes / secs / 1e9, exact=exact, rel=rel, runs=cycles)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default=BOARD_IP)
    ap.add_argument("--k", type=int, default=2048)
    ap.add_argument("--n", type=int, default=2048)
    ap.add_argument("--m", default="1,4,8,16")
    ap.add_argument("--reps", type=int, default=3)
    a = ap.parse_args()

    b = Board(EthTransport(a.host), lock=False)
    info = b.info()
    b.close()
    cfg = device_config(info)
    khz = info["core_khz"]
    peak_mac = cfg.D * cfg.MCOLS                     # MACs per cycle of the MXU
    print(f"board: S={cfg.S} D={cfg.D} MCOLS={cfg.MCOLS} core {khz / 1e3:.1f} MHz, "
          f"peak {2 * peak_mac * khz * 1e3 / 1e9:.1f} GOPS int8 ({peak_mac} MAC/cycle)")
    rng = np.random.default_rng(0)
    for M in (int(x) for x in a.m.split(",")):
        t = time.time()
        r = bench(a.host, cfg, khz, M, a.n, a.k, a.reps, rng)
        print(f"M={r['M']:3d} N={r['N']} K={r['K']}: {r['cycles']:9d} cycles {r['us']:9.1f} us  "
              f"{r['gops']:6.1f} GOPS ({100 * r['gops'] / (2 * peak_mac * khz / 1e6):4.1f}% of peak)  "
              f"weights {r['wgbs']:5.2f} GB/s  card==ISA {r['exact']}  rel.err {r['rel']:.4f}  "
              f"runs {r['runs']}  [{time.time() - t:.0f} s]", flush=True)


if __name__ == "__main__":
    main()
