#!/usr/bin/env python3
"""
ps_hil.py — hardware-in-the-loop self-check, run as root on the Zynq's ARM.

  1. configure the fabric feed handler over AXI4-Lite (/dev/mem)
  2. send MoldUDP64 packets out the PS Ethernet port (cable -> PL port)
  3. drain decoded records from the record queue, applying the commit markers
  4. compare against tools/itch.py's golden model fed the same packets
  5. print counters and PASS/FAIL

The comparison uses the same golden model and the same record unpacking as the
cocotb testbench, so a hardware pass means the board behaves the way the
simulation said it would.

Usage
  sudo python3 ps_hil.py --messages 20000 --watch AAPL NVDA TSLA AMD
  sudo python3 ps_hil.py --mold aapl_open.mold --pass-all
"""
from __future__ import annotations

import argparse
import mmap
import os
import sys
import time

import gen_feed
import itch
import net
import ps_replay
import regmap

AXI_BASE = 0x43C00000          # from assign_bd_address in vivado/build.tcl


class Regs:
    """32-bit register access through /dev/mem. memoryview.cast('I') guarantees
    word-sized loads/stores (byte-wise access to AXI-Lite would be wrong)."""
    def __init__(self, base=AXI_BASE, size=0x1000):
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                            offset=base)
        self.w = memoryview(self.mm).cast("I")

    def rd(self, off: int) -> int:
        return self.w[off // 4]

    def wr(self, off: int, val: int):
        self.w[off // 4] = val & 0xFFFFFFFF


def configure(r: Regs, watch, pass_all, port):
    assert r.rd(regmap.ID) == regmap.ID_VALUE, "bitstream not loaded / wrong address"
    r.wr(regmap.CTRL, 0)
    r.wr(regmap.UDP_PORT, port)
    for i, s in enumerate(watch):
        hi, lo = regmap.sym_words(s)
        r.wr(regmap.WATCH_HI(i), hi)
        r.wr(regmap.WATCH_LO(i), lo)
    r.wr(regmap.WATCH_EN, (1 << len(watch)) - 1)
    r.wr(regmap.CTRL, regmap.CTRL_CLEAR | regmap.CTRL_RELEARN)
    r.wr(regmap.CTRL, regmap.CTRL_ENABLE | (regmap.CTRL_PASS_ALL if pass_all else 0))


def drain(r: Regs, committed: list, pending: list):
    n = r.rd(regmap.REC_COUNT)
    for _ in range(n):
        words = [r.rd(regmap.REC_W0 + 4 * i) for i in range(16)]
        r.wr(regmap.REC_POP, 1)
        kind, val, _cyc = regmap.unpack_record(words)
        if kind == "rec":
            pending.append(val)
        else:
            if val:
                committed.extend(pending)
            pending.clear()
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mold")
    ap.add_argument("--messages", type=int, default=20000)
    ap.add_argument("--watch", nargs="*", default=["AAPL", "NVDA", "TSLA", "AMD"])
    ap.add_argument("--pass-all", action="store_true")
    ap.add_argument("--pps", type=float, default=20_000)
    ap.add_argument("--batch", type=int, default=40, help="packets per send/drain round")
    a = ap.parse_args()

    payloads = (ps_replay.load_mold(a.mold) if a.mold else
                [p for _, _, p in net.pack_messages(gen_feed.generate(a.messages), 1)])
    watch = [] if a.pass_all else a.watch
    golden = itch.GoldenFeedHandler(udp_port=net.MCAST_PORT, watch=watch, pass_all=a.pass_all)

    r = Regs()
    configure(r, watch, a.pass_all, net.MCAST_PORT)
    committed, pending = [], []
    t0 = time.perf_counter()
    for i in range(0, len(payloads), a.batch):
        chunk = payloads[i:i + a.batch]
        ps_replay.replay(chunk, a.pps)
        for p in chunk:
            golden.frame(p, net.MCAST_PORT, True)
        time.sleep(0.002)                       # let the last frame clear the fabric
        drain(r, committed, pending)
    dt = time.perf_counter() - t0

    hw = {n: r.rd(regmap.STAT(n)) for n in regmap.STATS}
    print(f"{len(payloads)} packets in {dt:.2f} s")
    for k in regmap.STATS:
        g = golden.stats.get(k, "-")
        flag = "" if g == "-" or g == hw[k] else "   <-- MISMATCH"
        print(f"  {k:<11} hw {hw[k]:>9}   golden {g!s:>9}{flag}")
    print(f"  fifo_max    {r.rd(regmap.FIFO_MAX)} / 16")

    ok = committed == golden.committed and hw["fcs_err"] == 0 and hw["rec_drop"] == 0
    if not ok:
        for j, (h, g) in enumerate(zip(committed, golden.committed)):
            if h != g:
                print(f"first mismatch at record {j}:\n  hw  : {h}\n  gold: {g}")
                break
    print(f"{'PASS' if ok else 'FAIL'}: {len(committed)} records, golden {len(golden.committed)}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
