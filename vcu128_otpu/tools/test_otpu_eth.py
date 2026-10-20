"""pytest для otpu_eth.EthTransport против эмулятора платы на 127.0.0.1 (otpu_eth_emu.py,
отдельный процесс): обмен с потерями, дублями и перестановкой, повтор пачек регистров,
опрос, ошибки, потоки; совместимость с upstream Board (модель — FakeTransport); замер
скорости ПК против платы-заглушки на C.

Запуск (нужен импорт upstream opentpu):
    cd vcu128_otpu/tools
    PYTHONPATH=../../../external/rtl/opentpu-fesens/upstream \\
        ../../../external/rtl/opentpu-fesens/.venv/bin/python -m pytest -q test_otpu_eth.py
"""
from __future__ import annotations

import ctypes
import multiprocessing as mp
import os
import socket
import threading
import time

import numpy as np
import pytest

import otpu_eth as E
import otpu_eth_emu as M


@pytest.fixture(autouse=True)
def _env(tmp_path, monkeypatch):
    monkeypatch.setenv("OTPU_RUN_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_CACHE_HOME", os.environ.get("XDG_CACHE_HOME",
                                                        str(tmp_path / "cache")))


class Emu:
    """Эмулятор в своём процессе (без общего GIL с транспортом)."""

    def __init__(self, fake: dict | None = None, **kw):
        ctx = mp.get_context("spawn")
        q = ctx.Queue()
        self.p = ctx.Process(target=M.run_process, args=(q, dict(port=0, **kw), fake),
                             daemon=True)
        self.p.start()
        self.port = q.get(timeout=60)

    def close(self):
        self.p.terminate()
        self.p.join(5)


@pytest.fixture(scope="module")
def emu_clean():
    e = Emu()
    yield e
    e.close()


@pytest.fixture(scope="module")
def emu_faulty():
    e = Emu(drop=0.03, dup=0.03, reorder=0.03, seed=7)
    yield e
    e.close()


def transport(emu, fast, **kw) -> E.EthTransport:
    kw.setdefault("rto", 0.01)
    kw.setdefault("reg_rto", 0.02)
    return E.EthTransport("127.0.0.1", emu.port, fast=fast, **kw)


FAST = [pytest.param(True, id="c"), pytest.param(False, id="py")]


# ------------------------------------------------------------------------------ память
@pytest.mark.parametrize("fast", FAST)
@pytest.mark.parametrize("faulty", [False, True], ids=["clean", "faulty"])
def test_mem_roundtrip(fast, faulty, emu_clean, emu_faulty):
    """Размеры и выравнивания (в том числе не по beat: края читаются и сливаются), кадры
    чтения разных размеров, все каналы; с потерями/дублями/перестановкой — тот же итог."""
    emu = emu_faulty if faulty else emu_clean
    rng = np.random.default_rng(1 + faulty + 2 * fast)
    with transport(emu, fast) as t:
        ref = [np.zeros(1 << 20, np.uint8) for _ in range(4)]
        for ch in range(4):
            t.mem_write(ch, 0, ref[ch])
        cases = [(0, 0, 64), (1, 64, 8192), (2, 4032, 8256), (3, 100, 1), (0, 63, 2),
                 (1, 5000, 70000), (2, 0, 300000), (3, 8191, 8193)]
        for ch, off, n in cases:
            d = rng.integers(0, 256, n, dtype=np.uint8)
            t.mem_write(ch, off, d)
            ref[ch][off:off + n] = d
        for ch in range(4):
            assert np.array_equal(t.mem_read(ch, 0, 1 << 20), ref[ch])
        for fr in (64, 1024, 4096):
            with transport(emu, fast, frame=fr, read_req=fr * 5) as t2:
                assert np.array_equal(t2.mem_read(1, 4000, 50000), ref[1][4000:54000])
        out = np.empty(3000, np.uint8)
        assert t.mem_read(2, 10, 3000, out) is out and np.array_equal(out, ref[2][10:3010])
        if faulty:
            assert t.stats["resend"] > 0 or t.stats["stray"] > 0


@pytest.mark.parametrize("fast", FAST)
def test_mem_errors(fast, emu_clean):
    with transport(emu_clean, fast) as t:
        with pytest.raises(ValueError):
            t.mem_read(0, (1 << 31) - 64, 128)
        with pytest.raises(E.EthError, match="bad request"):
            t.mem_write(5, 0, np.zeros(64, np.uint8))          # канала нет (у эмулятора 4)


@pytest.mark.parametrize("fast", FAST)
def test_no_board(fast):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))                                    # порт есть, ответа нет
    port = s.getsockname()[1]
    t = E.EthTransport("127.0.0.1", port, fast=fast, rto=0.005, reg_rto=0.005, retries=3)
    with pytest.raises(E.EthError, match="no answer"):
        t.mem_write(0, 0, np.zeros(128, np.uint8))
    with pytest.raises(E.EthError, match="no answer"):
        t.mem_read(0, 0, 128)
    with pytest.raises(E.EthError, match="no answer"):
        t.reg_read(0)
    t.close()
    s.close()


# ------------------------------------------------------------------------------ регистры
@pytest.mark.parametrize("faulty", [False, True], ids=["clean", "faulty"])
def test_regs_exactly_once(faulty, emu_clean, emu_faulty):
    """Запись с побочным эффектом (R_STROBE: +1 на каждую выполненную запись) при
    потерях ответов и дублях запросов выполняется ровно столько раз, сколько вызвана."""
    emu = emu_faulty if faulty else emu_clean
    with transport(emu, True) as t:
        n0 = t.reg_read(M.R_STROBE_N)
        for i in range(200):
            t.reg_write(M.R_STROBE, 1)
        assert t.reg_read(M.R_STROBE_N) == n0 + 200
        t.reg_write_many([(0x100 + 4 * i, i * 3) for i in range(300)])     # > REGMAX: 2 пачки
        assert t.reg_read_many([0x100 + 4 * i for i in range(300)]) == [i * 3 for i in range(300)]
        if faulty:
            assert t.stats["reg_resend"] > 0


def test_poll(emu_clean):
    with transport(emu_clean, True, poll_slice=0.005) as t:
        t.reg_write(M.R_TIMER, 30_000)                  # готово через 30 мс
        t0 = time.monotonic()
        assert t.poll(M.R_TIMER, 1, 1, timeout=5.0) == 1
        assert 0.025 < time.monotonic() - t0 < 2.0
        assert t.poll_exact
        t.reg_write(M.R_TIMER, 10_000_000)
        with pytest.raises(TimeoutError, match="waiting for 0x1"):
            t.poll(M.R_TIMER, 1, 1, timeout=0.05)


def test_reg_errors(emu_clean):
    with transport(emu_clean, True) as t:
        with pytest.raises(E.EthError, match="AXI error"):
            t.reg_read(M.R_BAD)
        st, done, vals = t.reg_batch([E.op_write(0x2000, 1), E.op_write(M.R_BAD, 1),
                                      E.op_write(0x2004, 1)])
        assert (st, done) == (E.ST_AXI, 1) and t.reg_read_many([0x2000, 0x2004]) == [1, 0]
        with pytest.raises(E.EthError, match="rejected"):
            t.reg_batch([E.OPREC.pack(0x7 << 28, 0, 0, 0)])


def test_threads(emu_clean):
    """Регистры из одного потока, память из другого (как Board с рабочим потоком DMA)."""
    with transport(emu_clean, True) as t:
        d = np.random.default_rng(3).integers(0, 256, 1 << 20, dtype=np.uint8)
        err = []

        def mem():
            try:
                for _ in range(5):
                    t.mem_write(0, 0, d)
                    assert np.array_equal(t.mem_read(0, 0, len(d)), d)
            except Exception as e:      # noqa: BLE001
                err.append(e)

        th = threading.Thread(target=mem)
        th.start()
        k = 0
        while th.is_alive():
            t.reg_write(0x300, k)
            assert t.reg_read(0x300) == k
            k += 1
        th.join()
        assert not err and k > 0


# ------------------------------------------------------------------------------ upstream Board
def _upstream():
    return pytest.importorskip("opentpu.host.board")


def test_board_on_eth_transport():
    """upstream Board поверх EthTransport (модель — FakeTransport upstream в эмуляторе):
    замок устройства, info, логическая запись/чтение с чередованием каналов, загрузка
    программы, прогон, счётчики — как с FakeTransport напрямую."""
    B = _upstream()
    from opentpu import isa as I
    from opentpu.host.fake import FakeTransport
    kw = dict(devname=None, regmap=4, ch_bytes=1 << 20, run_s=0.02)
    emu = Emu(fake=kw)
    try:
        t = transport(emu, True, devname="otpu-eth-test")
        b = B.Board(transport=t)                         # ID, quiesce, замок
        i = b.info()
        ref = B.Board(FakeTransport(**kw), lock=False).info()
        assert {k: i[k] for k in ("D", "MCOLS", "LANES", "regmap", "cfg")} == \
               {k: ref[k] for k in ("D", "MCOLS", "LANES", "regmap", "cfg")}
        rng = np.random.default_rng(5)
        x = rng.integers(0, 256, 300_000, dtype=np.uint8)
        b.write(1000, x)
        assert np.array_equal(b.read(1000, len(x)), x)
        y = np.arange(37, dtype=np.uint8)
        b.write(100, y)
        assert np.array_equal(b.read(100, 37), y)
        # чередование: beat b логической памяти — в канале b % 2 (без CHASH)
        assert np.array_equal(t.mem_read(1, 0, 64), b.read(64, 64))
        w = np.asarray(I.assemble([I.nop(), I.nop(), I.halt()]), np.uint32)
        b.load_program(1 << 16, w)
        t0 = time.monotonic()
        res = b.run(timeout=10)
        assert res["instructions"] in (3, [3]) and time.monotonic() - t0 >= 0.02
        snap = b.snapshot()
        assert snap is not None and snap["snaps"] >= 1
        b.close()
        b2 = B.Board(transport=t)                        # замок освобождён: снова можно
        b2.close()
        t.close()
    finally:
        emu.close()


def test_board_threaded_pipe():
    """Board.write / read крупнее PIPE (16 МиБ): рабочий поток DMA и основной вместе."""
    B = _upstream()
    kw = dict(devname=None, regmap=4, ch_bytes=24 << 20)
    emu = Emu(fake=kw)
    try:
        with transport(emu, True) as t:
            b = B.Board(transport=t, lock=False)
            x = np.random.default_rng(6).integers(0, 256, 40 << 20, dtype=np.uint8)
            b.write(0, x)
            assert np.array_equal(b.read(0, len(x)), x)
            b.close()
    finally:
        emu.close()


# ------------------------------------------------------------------------------ скорость ПК
def test_host_throughput_loopback(capsys):
    """Помощник на C против платы-заглушки на C (127.0.0.1): сколько может сторона ПК.
    (Не скорость платы: та — RTL-симуляция, sim/eth40 test_throughput.)"""
    lib = E._fast_lib()
    if lib is None:
        pytest.skip("no C helper")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for o in (socket.SO_RCVBUF, socket.SO_SNDBUF):
        s.setsockopt(socket.SOL_SOCKET, o, 64 << 20)
    s.bind(("127.0.0.1", 0))
    chb = 64 << 20
    mem = np.zeros(2 * chb, np.uint8)
    stop = ctypes.c_int(0)
    th = threading.Thread(target=lib.oe_emu, args=(s.fileno(), E._buf_addr(mem), chb, 2,
                                                   ctypes.byref(stop)), daemon=True)
    th.start()
    try:
        with E.EthTransport("127.0.0.1", s.getsockname()[1], fast=True, rto=0.05) as t:
            d = np.random.default_rng(7).integers(0, 256, chb, dtype=np.uint8)
            t.mem_write(0, 0, d[:1 << 20])
            t0 = time.perf_counter()
            for _ in range(4):
                t.mem_write(0, 0, d)
            tw = time.perf_counter() - t0
            out = np.empty(chb, np.uint8)
            t0 = time.perf_counter()
            for _ in range(4):
                t.mem_read(0, 0, chb, out)
            tr = time.perf_counter() - t0
            assert np.array_equal(out, d)
            gw, gr = 4 * chb / tw / 1e9, 4 * chb / tr / 1e9
            with capsys.disabled():
                print(f"\nloopback C helper: write {gw:.2f} GB/s, read {gr:.2f} GB/s, "
                      f"stats {t.stats}")
    finally:
        stop.value = 1
        th.join(2)
        s.close()
