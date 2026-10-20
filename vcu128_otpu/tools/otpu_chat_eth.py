"""otpu-chat (upstream openTPU) on the VCU128 over 40G Ethernet.

upstream chat.make_backend("board") builds opentpu.host.board.XdmaTransport(dev); here that
name is replaced by EthTransport before upstream's main runs, so `--backend board` talks to
the board over UDP and `--dev` is the board's IP (default 192.168.41.2). Nothing in upstream
is changed. Needs PYTHONPATH with upstream (external/rtl/opentpu-fesens/upstream) and this
directory; OTPU_TARGET may point at target/vcu128.toml (the ISA reference uses it).

    PYTHONPATH=../external/rtl/opentpu-fesens/upstream:vcu128_otpu/tools \\
      ../external/rtl/opentpu-fesens/.venv/bin/python vcu128_otpu/tools/otpu_chat_eth.py \\
      --model lfm2 --backend board --greedy --prompt "What is the capital of France?"
"""

import sys

import opentpu.host.board as board
from opentpu.host import chat

from otpu_eth import BOARD_IP, EthTransport


def _transport(dev=None, *args, **kw):
    host = dev if dev and not str(dev).startswith("/dev/") else BOARD_IP
    return EthTransport(host)


board.XdmaTransport = _transport

if __name__ == "__main__":
    sys.exit(chat.main())
