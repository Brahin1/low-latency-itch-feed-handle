"""
test_top.py — end-to-end verification of feed_handler_top.

Every test drives real RGMII DDR nibbles into the pins, lets the design parse
Ethernet -> IPv4 -> UDP -> MoldUDP64 -> ITCH, and compares the *committed*
records field-for-field against tools/itch.py's golden model. Counters are
read back over AXI4-Lite and compared too.
"""
from __future__ import annotations

import random
import statistics

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from cocotb.triggers import ReadOnly, RisingEdge
from cocotb.utils import get_sim_time

from fh_tb import (CORE_PS, RXC_PS, Stimulus, compare, configure, drain, retune_core_clock, start)
import gen_feed
import itch
import net
import regmap

WATCH = ["AAPL", "NVDA", "TSLA", "AMD"]


def check_stats(hw: dict, gold: dict, log, keys=None):
    keys = keys or gold.keys()
    bad = {k: (hw[k], gold[k]) for k in keys if hw[k] != gold[k]}
    log.info("counters: %s", {k: hw[k] for k in regmap.STATS})
    assert not bad, f"counter mismatch (hw, gold): {bad}"


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_watchlist_end_to_end(dut):
    """3,000 messages across 8 symbols; hardware learns 4 locates from 'R' and filters."""
    axi, src, mon = await start(dut)
    await configure(axi, watch=WATCH)
    golden = itch.GoldenFeedHandler(udp_port=net.MCAST_PORT, watch=WATCH)
    stim = Stimulus(src, golden)

    rng = random.Random(11)
    msgs = gen_feed.generate(3000, seed=1)
    seq = 1
    while msgs:
        n = rng.randint(1, 25)
        batch, msgs = msgs[:n], msgs[n:]
        await stim.mold(seq, batch)
        seq += len(batch)
    await drain(dut)

    compare(mon.committed, golden.committed, dut._log, "watchlist")
    assert not mon.discarded and all(mon.markers)
    hw = await axi.stats()
    check_stats(hw, golden.stats, dut._log)

    for i, s in enumerate(WATCH):
        v = await axi.read(regmap.LEARNED(i))
        assert v >> 31 == 1 and (v & 0xFFFF) == golden.learned[i], (s, hex(v))
    exp = (await axi.read(regmap.EXP_SEQ_HI)) << 32 | await axi.read(regmap.EXP_SEQ_LO)
    assert exp == golden.exp_seq == seq, (exp, golden.exp_seq, seq)
    types = sorted({chr(r.type) for r in golden.committed})
    dut._log.info("record types covered: %s", "".join(types))
    assert set(types) == set("AFECXDUP")


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_error_injection(dut):
    """Bad FCS, RX_ER, gaps, duplicates, overlaps, filters, IP options, bad lengths."""
    axi, src, mon = await start(dut)
    await configure(axi, pass_all=True)
    golden = itch.GoldenFeedHandler(udp_port=net.MCAST_PORT, pass_all=True)
    stim = Stimulus(src, golden)
    log = dut._log

    flow = gen_feed.generate(400, seed=5)
    pkts, seq = [], 1
    for i in range(0, len(flow), 8):
        pkts.append((seq, flow[i:i + 8]))
        seq += len(flow[i:i + 8])

    await stim.mold(*pkts[0])
    await stim.mold(*pkts[1])
    # 1. corrupt FCS: records come out speculatively, then a BAD marker; sequence
    #    state rolls back, so the retransmission is *not* treated as a duplicate.
    await stim.mold(*pkts[2], bad_fcs=True)
    await stim.mold(*pkts[2])
    # 2. RX_ER asserted in the middle of the payload: same treatment.
    await stim.mold(*pkts[3], er_at=90)
    await stim.mold(*pkts[3])
    # 3. exact duplicate of an already-processed packet (A/B feed style)
    await stim.mold(*pkts[1])
    # 4. partial overlap: starts 3 messages before expected
    s4, m4 = pkts[4]
    await stim.mold(s4, m4)
    await stim.mold(pkts[5][0] - 3, pkts[4][1][-3:] + pkts[5][1])
    # 5. gap: packet 6 is lost on the wire
    await stim.mold(*pkts[7])
    # 6. frames that must be filtered
    await stim.raw(net.eth_frame(b"\x00\x01\x08\x00\x06\x04\x00\x01" + b"\x00" * 20,
                                 ethertype=0x0806), frame_ok=True)            # ARP
    await stim.mold(*pkts[8], dport=12345)                                    # wrong port
    await stim.mold(*pkts[8], proto=6)                                        # TCP
    # 7. IPv4 header with options (IHL = 6) must still parse
    await stim.mold(*pkts[8], ip_options=b"\x94\x04\x00\x00")
    # 8. heartbeat and end-of-session
    await stim.raw(net.eth_frame(net.udp_ipv4(net.mold_heartbeat(b"TESTSESS01", pkts[9][0]))),
                   frame_ok=True)
    # 9. malformed messages: wrong length for its type, unknown type, 50-byte NOII
    bad_len = itch.add_order(1, 100, 9, b"B", 1, "AAPL", 1)[:-1]              # 35 B 'A'
    cross = b"Q" + bytes(39)                                                  # Cross Trade
    noii = b"I" + bytes(49)                                                   # longer than capture buffer
    s9, m9 = pkts[9]
    await stim.mold(s9, [m9[0], bad_len, cross, noii] + m9[1:])
    seq_after = s9 + 4 + len(m9) - 1
    # 10. runt frame (46 bytes, no padding) and preamble without SFD (noise)
    runt = net.eth_frame(b"")[:10] + b"\x08\x06" + bytes(30)
    runt = runt + net.fcs(runt)
    await stim.raw(runt, frame_ok=False)
    await src.send(b"\x55\x55\x55\x12\x34\x56")                              # no SFD
    await src.idle(12)
    # 11. keep going after all that
    await stim.mold(seq_after, flow[80:96])

    await drain(dut)
    compare(mon.committed, golden.committed, log, "errors")
    log.info("discarded speculative records from bad frames: %d", len(mon.discarded))
    assert len(mon.discarded) == 16 and mon.markers.count(False) == 2
    hw = await axi.stats()
    check_stats(hw, golden.stats, log)
    assert hw["gaps"] == 1 and hw["dup_msgs"] == 11 and hw["len_err"] == 1
    assert hw["fcs_err"] == 3 and hw["heartbeats"] == 1


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_line_rate_latency(dut):
    """Back-to-back frames at 1 Gb/s with minimum IFG; measure wire-to-record latency."""
    axi, src, mon = await start(dut)
    await configure(axi, pass_all=True)
    golden = itch.GoldenFeedHandler(udp_port=net.MCAST_PORT, pass_all=True)
    stim = Stimulus(src, golden, ifg=12)

    msgs = gen_feed.generate(3000, seed=9)
    t0 = cocotb.utils.get_sim_time("ns")
    for seq, batch, _ in net.pack_messages(msgs, first_seq=1, max_payload=1400):
        await stim.mold(seq, batch, mark=True)
    t1 = cocotb.utils.get_sim_time("ns")
    await drain(dut)

    compare(mon.committed, golden.committed, dut._log, "line-rate")
    hw = await axi.stats()
    check_stats(hw, golden.stats, dut._log)
    assert hw["fifo_ovf"] == 0
    fifo_max = await axi.read(regmap.FIFO_MAX)

    lat = [mon.out_time[s] - src.byte_times[s] for s in src.byte_times if s in mon.out_time]
    lat_ns = [x / 1000 for x in lat]
    wire_gbps = stim.wire_bytes * 8 / (t1 - t0)
    dut._log.info("=== line-rate results ===")
    dut._log.info("messages %d in %.1f us -> %.2f M msg/s; wire utilisation %.3f Gb/s",
                  stim.sent_msgs, (t1 - t0) / 1e3, stim.sent_msgs / (t1 - t0) * 1e3, wire_gbps)
    dut._log.info("CDC FIFO max occupancy %d / 16, overflow events %d", fifo_max, hw["fifo_ovf"])
    dut._log.info("latency last-byte-on-pins -> record valid (ns): min %.1f  median %.1f  "
                  "max %.1f  mean %.2f  (n=%d)", min(lat_ns), statistics.median(lat_ns),
                  max(lat_ns), statistics.mean(lat_ns), len(lat_ns))
    assert max(lat_ns) < 80


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_cdc_overflow_recovery(dut):
    """Mis-clocked core (115 MHz < 125 MB/s wire rate): the rx FIFO must overflow,
    every damaged frame must be dropped or flagged (never committed), and once the
    clock is fixed the pipeline must resynchronise with no reset."""
    axi, src, mon = await start(dut, core_ps=8696)
    await configure(axi, pass_all=True)
    golden = itch.GoldenFeedHandler(udp_port=net.MCAST_PORT, pass_all=True)
    stim = Stimulus(src, golden, ifg=12)
    log = dut._log

    # Phase 1: small and large frames at line rate into a 60 MHz core.
    flow = gen_feed.generate(1200, seed=3)
    rng = random.Random(3)
    seq = 1
    while flow:
        n = rng.choice([1, 2, 30])
        batch, flow = flow[:n], flow[n:]
        await stim.mold(seq, batch)
        seq += len(batch)
    await drain(dut, 3000)
    hw1 = await axi.stats()
    good = set(golden.committed)
    assert hw1["fifo_ovf"] > 0, "expected overflow at 115 MHz"
    assert all(r in good for r in mon.committed), "a damaged frame produced a committed record"
    assert mon.committed and mon.discarded, "expected both surviving and flagged frames"
    log.info("phase 1 (115 MHz core): overflow events %d of %d frames; committed %d of %d golden "
             "records, all genuine; %d speculative records discarded by BAD markers",
             hw1["fifo_ovf"], hw1["frames"] + 0, len(mon.committed), len(golden.committed),
             len(mon.discarded))

    # Phase 2: clock fixed, no reset. Output must be exact again.
    retune_core_clock(dut, CORE_PS)
    await drain(dut, 100)
    n_before = len(mon.committed)
    golden2 = itch.GoldenFeedHandler(udp_port=net.MCAST_PORT, pass_all=True)
    stim2 = Stimulus(src, golden2, ifg=12)
    for s, batch, _ in net.pack_messages(gen_feed.generate(1500, seed=4), first_seq=100_000):
        await stim2.mold(s, batch)
    await drain(dut)
    compare(mon.committed[n_before:], golden2.committed, log, "recovery")
    hw2 = await axi.stats()
    assert hw2["fifo_ovf"] == hw1["fifo_ovf"], "overflow after the clock was fixed"
    assert hw2["gaps"] == hw1["gaps"] + 1


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_fifo_depth_margin(dut):
    """Elastic-buffer sizing: a core clock only slightly slower than the wire
    (124.5 MHz vs 125 MHz) must survive back-to-back 1,500-byte frames in 16 entries.
    Required depth ~ frame_bytes * (1 - f_core / f_rx) + synchroniser latency."""
    axi, src, mon = await start(dut, core_ps=8032)
    await configure(axi, pass_all=True)
    golden = itch.GoldenFeedHandler(udp_port=net.MCAST_PORT, pass_all=True)
    stim = Stimulus(src, golden, ifg=12)
    for s, batch, _ in net.pack_messages(gen_feed.generate(1200, seed=8), first_seq=1,
                                         max_payload=1472):
        await stim.mold(s, batch)
    await drain(dut)
    compare(mon.committed, golden.committed, dut._log, "124.5 MHz core")
    hw = await axi.stats()
    fifo_max = await axi.read(regmap.FIFO_MAX)
    deficit = 1514 * (1 - 124.5 / 125)
    dut._log.info("core 124.5 MHz: max FIFO occupancy %d / 16 (predicted backlog %.1f bytes "
                  "+ ~3 in the synchronisers), overflow events %d", fifo_max, deficit,
                  hw["fifo_ovf"])
    assert hw["fifo_ovf"] == 0
