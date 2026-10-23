"""The three memories a program sees, with real contents.

HBM  -- the slice's DRAM: bytes; logical address -> channel by 64-byte beats (beat % 2), so a
        128-byte MXU chunk is one beat from each channel (upstream otpu_native_dram, CHASH off).
TMEM -- 65536 FP32 words, 8 banks (address % 8): activations, residual, softmax state, logits.
ACT  -- ACT RAM: MCOLS rows x ACT_BLOCKS blocks of D INT8 codes + an FP32 scale Sa[row][block]:
        the stationary operands of upcoming MMs, each in its own block range (field ab).
"""
from dataclasses import dataclass, field

import numpy as np

from .config import Config

F32 = np.float32


@dataclass
class Region:
    name: str
    addr: int
    nbytes: int
    kind: str          # weights / scales / kv / io / program
    layer: int = -1


class HBM:
    def __init__(self, cfg: Config, size: int):
        self.cfg = cfg
        self.mem = np.zeros(size, np.uint8)
        self.regions: list[Region] = []
        self.top = 0

    def alloc(self, name, nbytes, kind, layer=-1, align=128) -> int:
        self.top = -(-self.top // align) * align
        addr = self.top
        assert addr + nbytes <= len(self.mem), f"HBM full at {name}"
        self.regions.append(Region(name, addr, nbytes, kind, layer))
        self.top += nbytes
        return addr

    # typed access
    def write_i8(self, addr, a):
        a = np.ascontiguousarray(a, np.int8).view(np.uint8).ravel()
        self.mem[addr:addr + a.size] = a

    def read_i8(self, addr, n):
        return self.mem[addr:addr + n].view(np.int8)

    def write_f32(self, addr, a):
        a = np.ascontiguousarray(a, F32).view(np.uint8).ravel()
        self.mem[addr:addr + a.size] = a

    def read_f32(self, addr, n):
        return self.mem[addr:addr + 4 * n].view(F32)

    def channel_bytes(self, addr, nbytes):
        """Bytes of [addr, addr + nbytes) on each channel (64-byte beat interleave)."""
        b = self.cfg.beat
        out = [0] * self.cfg.channels
        first, last = addr // b, (addr + nbytes - 1) // b
        for beat in range(first, last + 1):
            lo, hi = max(addr, beat * b), min(addr + nbytes, (beat + 1) * b)
            out[beat % self.cfg.channels] += hi - lo
        return out


@dataclass
class TAlloc:
    name: str
    addr: int
    words: int


class TMEM:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.mem = np.zeros(cfg.TMEM_WORDS, F32)
        self.allocs: list[TAlloc] = []
        self.top = 0
        self.by_name: dict[str, TAlloc] = {}

    def alloc(self, name, words, align=8) -> int:
        """Bump allocator (upstream: liveness-based next-fit with odd row strides)."""
        if name in self.by_name:
            return self.by_name[name].addr
        self.top = -(-self.top // align) * align
        a = TAlloc(name, self.top, words)
        assert self.top + words <= len(self.mem), f"TMEM full at {name}"
        self.allocs.append(a)
        self.by_name[name] = a
        self.top += words
        return a.addr


@dataclass
class ActRAM:
    cfg: Config
    codes: np.ndarray = field(init=False)
    scale: np.ndarray = field(init=False)
    rows: int = 0
    k: int = 0

    def __post_init__(self):
        self.codes = np.zeros((self.cfg.MCOLS, self.cfg.ACT_BLOCKS * self.cfg.D), np.int8)
        self.scale = np.ones((self.cfg.MCOLS, self.cfg.ACT_BLOCKS), F32)
