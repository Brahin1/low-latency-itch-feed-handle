"""
fh_tb.py — reusable cocotb components for feed_handler_top.

  AxiLiteMaster   drives the register interface exactly like the ARM would
  RgmiiSource     drives the four RGMII data pins + RX_CTL on both clock edges,
                  and time-stamps when chosen bytes finish crossing the pins
  RecordMonitor   watches the decoded record stream and applies the commit
                  protocol (records are provisional until their frame's marker)
  Stimulus        builds frames and feeds the same frames to the golden model
"""
from __future__ import annotations

import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, First, ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import itch      # noqa: E402
import net       # noqa: E402
import regmap    # noqa: E402

RXC_PS = 8000          # 125 MHz, PHY-recovered clock
CORE_PS = 4990         # ~200.4 MHz: deliberately not a rational multiple of 8 ns


# ---------------------------------------------------------------- AXI4-Lite
class AxiLiteMaster:
    def __init__(self, dut, clk):
        self.dut, self.clk = dut, clk
        dut.s_axil_awvalid.value = 0
        dut.s_axil_wvalid.value = 0
        dut.s_axil_arvalid.value = 0
        dut.s_axil_bready.value = 1
        dut.s_axil_rready.value = 1
        dut.s_axil_wstrb.value = 0xF

    async def write(self, addr: int, data: int):
        d = self.dut
        await RisingEdge(self.clk)
        d.s_axil_awaddr.value = addr
        d.s_axil_wdata.value = data & 0xFFFFFFFF
        d.s_axil_awvalid.value = 1
        d.s_axil_wvalid.value = 1
        while True:
            await ReadOnly()
            ready = int(d.s_axil_awready.value)
            await RisingEdge(self.clk)
            if ready:
                break
        d.s_axil_awvalid.value = 0
        d.s_axil_wvalid.value = 0
        while True:
            await ReadOnly()
            if int(d.s_axil_bvalid.value):
                break
            await RisingEdge(self.clk)
        await RisingEdge(self.clk)

    async def read(self, addr: int) -> int:
        d = self.dut
        await RisingEdge(self.clk)
        d.s_axil_araddr.value = addr
        d.s_axil_arvalid.value = 1
        while True:
            await ReadOnly()
            ready = int(d.s_axil_arready.value)
            await RisingEdge(self.clk)
            if ready:
                break
        d.s_axil_arvalid.value = 0
        while True:
            await ReadOnly()
            if int(d.s_axil_rvalid.value):
                val = int(d.s_axil_rdata.value)
                break
            await RisingEdge(self.clk)
        await RisingEdge(self.clk)
        return val

    async def stats(self) -> dict:
        return {n: await self.read(regmap.STAT(n)) for n in regmap.STATS}


# ---------------------------------------------------------------- RGMII
class RgmiiSource:
    """
    RGMII-ID timing: the PHY centres the clock in the data eye, so data is
    changed half-way between edges. Low nibble + RX_DV are sampled on the
    rising edge, high nibble + (RX_DV ^ RX_ER) on the falling edge.
    """
    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.rgmii_rxc
        dut.rgmii_rxd.value = 0
        dut.rgmii_rx_ctl.value = 0
        self.byte_times: dict[int, float] = {}

    async def idle(self, n_bytes: int):
        await FallingEdge(self.clk)
        self.dut.rgmii_rx_ctl.value = 0
        self.dut.rgmii_rxd.value = 0
        if n_bytes > 1:
            await ClockCycles(self.clk, n_bytes - 1, rising=False)

    async def send(self, data: bytes, er_at: int | None = None, marks: dict | None = None):
        """Send bytes with DV high. marks: {key: byte_index} to time-stamp."""
        d = self.dut
        idx_to_key = {v: k for k, v in (marks or {}).items()}
        for i, b in enumerate(data):
            er = 1 if er_at is not None and i == er_at else 0
            await FallingEdge(self.clk)
            d.rgmii_rxd.value = b & 0xF
            d.rgmii_rx_ctl.value = 1
            await RisingEdge(self.clk)
            d.rgmii_rxd.value = b >> 4
            d.rgmii_rx_ctl.value = 1 ^ er
            if i in idx_to_key:
                # the byte is fully captured at the next falling edge (+4 ns)
                self.byte_times[idx_to_key[i]] = get_sim_time("ps") + RXC_PS // 2
        await FallingEdge(self.clk)
        d.rgmii_rx_ctl.value = 0
        d.rgmii_rxd.value = 0


# ---------------------------------------------------------------- monitor
class RecordMonitor:
    def __init__(self, dut):
        self.dut = dut
        self.pending: list = []
        self.committed: list = []
        self.discarded: list = []
        self.markers: list[bool] = []
        self.out_time: dict[int, float] = {}          # seq -> ps when record appeared
        self._task = cocotb.start_soon(self._run())

    def _read_record(self):
        d = self.dut
        return itch.Record(
            type=int(d.rec_type.value), locate=int(d.rec_locate.value), ts=int(d.rec_ts.value),
            ref=int(d.rec_ref.value), new_ref=int(d.rec_new_ref.value), side=int(d.rec_side.value),
            shares=int(d.rec_shares.value), price=int(d.rec_price.value),
            stock=int(d.rec_stock.value), match=int(d.rec_match.value), seq=int(d.rec_seq.value),
            sym_idx=int(d.rec_sym_idx.value))

    async def _run(self):
        d = self.dut
        while True:
            await First(RisingEdge(d.rec_valid), RisingEdge(d.rec_fend))
            await ReadOnly()
            now = get_sim_time("ps")
            if int(d.rec_valid.value):
                r = self._read_record()
                self.pending.append(r)
                self.out_time.setdefault(r.seq, now)
            if int(d.rec_fend.value):
                ok = bool(int(d.rec_fend_ok.value))
                self.markers.append(ok)
                (self.committed if ok else self.discarded).extend(self.pending)
                self.pending = []


# ---------------------------------------------------------------- env
async def start(dut, core_ps=CORE_PS):
    cocotb.start_soon(Clock(dut.rgmii_rxc, RXC_PS, unit="ps").start())
    dut._core_clk_task = cocotb.start_soon(Clock(dut.core_clk, core_ps, unit="ps").start())
    dut.core_rst.value = 1
    axi = AxiLiteMaster(dut, dut.core_clk)
    src = RgmiiSource(dut)
    await ClockCycles(dut.core_clk, 20)
    dut.core_rst.value = 0
    await ClockCycles(dut.rgmii_rxc, 10)
    mon = RecordMonitor(dut)
    return axi, src, mon


async def configure(axi, port=net.MCAST_PORT, watch=(), pass_all=False, enable=True):
    assert await axi.read(regmap.ID) == regmap.ID_VALUE
    await axi.write(regmap.UDP_PORT, port)
    for i, s in enumerate(watch):
        hi, lo = regmap.sym_words(s)
        await axi.write(regmap.WATCH_HI(i), hi)
        await axi.write(regmap.WATCH_LO(i), lo)
    await axi.write(regmap.WATCH_EN, (1 << len(watch)) - 1)
    await axi.write(regmap.CTRL, (regmap.CTRL_ENABLE if enable else 0)
                    | (regmap.CTRL_PASS_ALL if pass_all else 0))


class Stimulus:
    """Builds wire frames and keeps the golden model in lock-step."""
    def __init__(self, src: RgmiiSource, golden: itch.GoldenFeedHandler, ifg=12):
        self.src, self.golden, self.ifg = src, golden, ifg
        self.sent_msgs = 0
        self.wire_bytes = 0

    async def mold(self, seq: int, msgs: list[bytes], *, bad_fcs=False, er_at=None,
                   dport=net.MCAST_PORT, ip_options=b"", proto=17, mark=False, ifg=None):
        payload = net.mold_packet(b"TESTSESS01", seq, msgs)
        l3 = net.udp_ipv4(payload, dport=dport, ip_options=ip_options, proto=proto)
        frame = net.eth_frame(l3, bad_fcs=bad_fcs)
        w = net.wire(frame)
        marks = None
        if mark:
            # index of the last byte of each message on the wire
            off = 8 + 14 + 20 + len(ip_options) + 8 + 20
            marks = {}
            for i, m in enumerate(msgs):
                off += 2 + len(m)
                marks[seq + i] = off - 1
        await self.src.send(w, er_at=er_at, marks=marks)
        await self.src.idle(self.ifg if ifg is None else ifg)
        ok = not bad_fcs and er_at is None
        dp, pl = net.parse_udp(frame) if proto == 17 else (None, None)
        self.golden.frame(pl, dp, ok)
        self.sent_msgs += len(msgs)
        self.wire_bytes += len(w) + (self.ifg if ifg is None else ifg)

    async def raw(self, frame_with_fcs: bytes, frame_ok: bool, preamble=True):
        w = net.wire(frame_with_fcs) if preamble else frame_with_fcs
        await self.src.send(w)
        await self.src.idle(self.ifg)
        dp, pl = net.parse_udp(frame_with_fcs)
        self.golden.frame(pl, dp, frame_ok)


def retune_core_clock(dut, core_ps):
    """Model fixing a mis-programmed MMCM: stop the core clock, restart at a new period."""
    dut._core_clk_task.cancel()
    dut._core_clk_task = cocotb.start_soon(Clock(dut.core_clk, core_ps, unit="ps").start())


async def drain(dut, cycles=400):
    await ClockCycles(dut.core_clk, cycles)


def compare(committed, expected, log, label=""):
    if committed == expected:
        log.info("%s: %d committed records match the golden model exactly", label, len(expected))
        return
    for i, (a, b) in enumerate(zip(committed, expected)):
        if a != b:
            raise AssertionError(f"{label}: first mismatch at record {i}\n  hw  : {a}\n  gold: {b}")
    raise AssertionError(f"{label}: count mismatch hw={len(committed)} gold={len(expected)}")
