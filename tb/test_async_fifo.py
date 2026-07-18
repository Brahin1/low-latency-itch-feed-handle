"""
test_async_fifo.py — randomized dual-clock scoreboard for rtl/async_fifo.sv.

Three clock ratios (slow writer, fast writer, near-equal), random enables on
both sides. Checks: every accepted word comes out exactly once, in order;
nothing is accepted while full or produced while empty; occupancy never
exceeds depth.
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer


async def run(dut, wper, rper, n, p_wr, p_rd, seed):
    rng = random.Random(seed)
    cocotb.start_soon(Clock(dut.wclk, wper, unit="ps").start())
    cocotb.start_soon(Clock(dut.rclk, rper, unit="ps").start())
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.wrst.value = 1
    dut.rrst.value = 1
    await ClockCycles(dut.wclk, 5)
    await ClockCycles(dut.rclk, 5)
    dut.wrst.value = 0
    dut.rrst.value = 0

    expected, got = [], []
    stats = dict(full_cycles=0, empty_cycles=0, max_level=0)

    async def writer():
        nxt = 0
        while nxt < n:
            await RisingEdge(dut.wclk)
            await ReadOnly()
            full = int(dut.full.value)
            stats["full_cycles"] += full
            await Timer(1, "ps")
            if rng.random() < p_wr:
                dut.wr_en.value = 1
                dut.wdata.value = nxt & 0x3FF
                if not full:
                    expected.append(nxt & 0x3FF)
                    nxt += 1
            else:
                dut.wr_en.value = 0
        await RisingEdge(dut.wclk)
        await Timer(1, "ps")
        dut.wr_en.value = 0

    async def reader():
        while len(got) < n:
            await RisingEdge(dut.rclk)
            await ReadOnly()
            empty = int(dut.empty.value)
            data = int(dut.rdata.value) if not empty else None
            lvl = int(dut.rlevel.value)
            stats["max_level"] = max(stats["max_level"], lvl)
            stats["empty_cycles"] += empty
            await Timer(1, "ps")
            take = rng.random() < p_rd
            dut.rd_en.value = int(take)
            if take and not empty:
                got.append(data)

    w = cocotb.start_soon(writer())
    await reader()
    await w
    assert got == expected[:len(got)] and len(got) == n, "data mismatch / loss"
    assert stats["max_level"] <= 16
    dut._log.info("wclk %d ps, rclk %d ps: %d words OK | cycles full=%d empty=%d | max level %d",
                  wper, rper, n, stats["full_cycles"], stats["empty_cycles"], stats["max_level"])


@cocotb.test()
async def fifo_fast_writer(dut):
    await run(dut, wper=4000, rper=9970, n=3000, p_wr=0.9, p_rd=0.8, seed=1)


@cocotb.test()
async def fifo_slow_writer(dut):
    await run(dut, wper=8000, rper=4990, n=3000, p_wr=0.7, p_rd=0.9, seed=2)


@cocotb.test()
async def fifo_near_equal(dut):
    await run(dut, wper=8000, rper=8002, n=3000, p_wr=0.95, p_rd=0.95, seed=3)
