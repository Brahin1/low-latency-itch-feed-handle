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
