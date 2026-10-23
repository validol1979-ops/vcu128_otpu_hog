"""Machine parameters: target/vcu128.toml, plus timing constants fitted to the upstream RTL
(Lens profiles of qwen-tiny / LFM2.5 on this configuration, sim/lens/)."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    # architecture (target/vcu128.toml [arch] / [uarch])
    D: int = 128                # MXU depth = bytes per DRAM chunk = INT8 elements per block
    MCOLS: int = 4              # MXU columns = most stationary activation rows of one MM
    LANES: int = 8              # VPU lanes = TMEM banks = FP32 words per cycle
    WIN: int = 16               # sequencer dispatch window
    FIFO_DEPTH: int = 1024      # MXU chunk FIFO (chunks of D bytes)
    TMEM_WORDS: int = 65536     # FP32 words
    ACT_BLOCKS: int = 128       # ACT RAM blocks of D bytes per row
    core_mhz: float = 100.0
    channels: int = 2           # HBM channels of the slice, interleaved by 64-byte beats
    beat: int = 64
    # timing (core cycles); fitted, not taken from the RTL source
    mem_lat: int = 20           # DRAM request -> data at the slice
    mxu_pipe: int = 24          # systolic array + epilogue latency of a row
    mxu_drain: int = 2          # FP32 results per cycle into TMEM (E = MCOLS / 2)
    vpu_lat: int = 15           # simple VOP pipeline
    vpu_comp_lat: int = 40      # composite VOP (exp2, recip, rsqrt) program latency
    vpu_comp_rate: int = 2      # composite elements per cycle (2 long lanes)
    quant_lat: int = 50         # QACT: two passes + pipeline
    qst_lat: int = 12

    @property
    def chunk(self) -> int:
        return self.D

    @property
    def port_b_Bps(self) -> float:
        return self.D * self.core_mhz * 1e6
