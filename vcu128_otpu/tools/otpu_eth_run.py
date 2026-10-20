"""Run an upstream openTPU script with the board reached over 40G Ethernet.

opentpu.host.board.XdmaTransport is replaced by EthTransport (otpu_chat_eth.py does the same
for otpu-chat), then the script runs as __main__ with the remaining arguments. `--backend
board` in upstream tools then talks to the VCU128 over UDP. Board address: OTPU_ETH_HOST
(default 192.168.41.2). Upstream is not changed.

    PYTHONPATH=<upstream>:vcu128_otpu/tools python vcu128_otpu/tools/otpu_eth_run.py \\
      <upstream>/tools/validate.py --model lfm2 --backend board --against isa
"""

import os
import runpy
import sys

import opentpu.host.board as board

from otpu_eth import BOARD_IP, EthTransport


def _transport(dev=None, *args, **kw):
    return EthTransport(os.environ.get("OTPU_ETH_HOST", BOARD_IP))


board.XdmaTransport = _transport

if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    if sys.argv[1] == "-m":                 # a module of the package, e.g. opentpu.serve.api
        module = sys.argv[2]
        sys.argv = [module] + sys.argv[3:]
        runpy.run_module(module, run_name="__main__", alter_sys=True)
    else:
        script = sys.argv[1]
        sys.argv = sys.argv[1:]
        runpy.run_path(script, run_name="__main__")
