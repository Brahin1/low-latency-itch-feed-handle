#!/usr/bin/env python3
"""
itch_file.py — work with Nasdaq's historical TotalView-ITCH 5.0 files.

Source: https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/  (e.g. 01302019.NASDAQ_ITCH50.gz,
about 4.8 GB compressed). The BX and PSX directories next to it hold smaller
files that are quicker to iterate on.

File format: a flat sequence of [2-byte big-endian length][ITCH message]. There
are no MoldUDP64 headers or sequence numbers in the file; message N of the day
is sequence number N (1-based), which is how the replay tools number them.

Sub-commands
  stats    per-type counts, sizes, busiest second / millisecond (streams the
           whole file; never loads it into memory)
  extract  write a smaller file in the same format: first N messages, and/or
           only the given symbols (R messages are used to map symbol -> locate)
  pcap     pack an extracted file into MoldUDP64 packets and write a pcap plus a
           .mold file (length-prefixed UDP payloads) for the replay tools

Examples
  python3 itch_file.py stats   01302019.NASDAQ_ITCH50.gz
  python3 itch_file.py extract 01302019.NASDAQ_ITCH50.gz -o aapl_open.bin \
          --symbols AAPL MSFT NVDA TSLA --start 09:30 --count 200000
  python3 itch_file.py pcap    aapl_open.bin -o aapl_open.pcap
"""
from __future__ import annotations

import argparse
import collections
import gzip
import struct
import sys

import itch
import net


def open_any(path: str):
    return gzip.open(path, "rb") if path.endswith(".gz") else open(path, "rb")


def iter_messages(path: str):
    """Yield raw ITCH messages from a length-prefixed file (gzipped or not)."""
    with open_any(path) as fh:
        read = fh.read
        while True:
            hdr = read(2)
            if len(hdr) < 2:
                return
            (n,) = struct.unpack(">H", hdr)
            msg = read(n)
            if len(msg) < n:
                return
            yield msg


def write_messages(path: str, msgs):
    with open(path, "wb") as fh:
        for m in msgs:
            fh.write(struct.pack(">H", len(m)) + m)


def hhmm_to_ns(s: str) -> int:
    h, m = s.split(":")
    return (int(h) * 3600 + int(m) * 60) * 1_000_000_000


def cmd_stats(a):
    counts = collections.Counter()
    nbytes = 0
    per_sec = collections.Counter()
    per_ms = collections.Counter()
    first_ts = last_ts = None
    for i, m in enumerate(iter_messages(a.file)):
        counts[m[0:1]] += 1
        nbytes += len(m) + 2
        ts = int.from_bytes(m[5:11], "big")
        first_ts = ts if first_ts is None else first_ts
        last_ts = ts
        per_sec[ts // 1_000_000_000] += 1
        per_ms[ts // 1_000_000] += 1
        if a.limit and i + 1 >= a.limit:
            break
    total = sum(counts.values())
    print(f"messages      {total:,}")
    print(f"bytes         {nbytes:,}  (avg {nbytes/total - 2:.1f} B/msg)")
    print(f"time span     {first_ts/3.6e12:.3f} h .. {last_ts/3.6e12:.3f} h after midnight")
    sec, n = per_sec.most_common(1)[0]
    ms, nm = per_ms.most_common(1)[0]
    print(f"busiest 1 s   {n:,} msgs at {sec//3600:02d}:{sec%3600//60:02d}:{sec%60:02d}")
    print(f"busiest 1 ms  {nm:,} msgs  -> {nm*1000:,.0f} msg/s burst rate")
    print("type  count         share")
    for t, c in counts.most_common():
        print(f"  {t.decode()}   {c:>12,}  {100*c/total:5.1f}%")


def cmd_extract(a):
    want = set(a.symbols or [])
    want_loc: set[int] = set()
    start_ns = hhmm_to_ns(a.start) if a.start else 0
    out, kept = [], 0
    for m in iter_messages(a.file):
        t = m[0:1]
        loc = int.from_bytes(m[1:3], "big")
        if t == b"R":
            sym = m[11:19].decode().strip()
            if not want or sym in want:
                want_loc.add(loc)
                out.append(m)
            continue
        if t == b"S":
            out.append(m)
            continue
        if int.from_bytes(m[5:11], "big") < start_ns:
            continue
        if want and loc not in want_loc:
            continue
        out.append(m)
        kept += 1
        if a.count and kept >= a.count:
            break
    write_messages(a.output, out)
    print(f"wrote {len(out):,} messages ({kept:,} after --start) to {a.output}")


def cmd_pcap(a):
    msgs = list(iter_messages(a.file))
    frames, payloads = [], []
    for seq, batch, payload in net.pack_messages(msgs, first_seq=1, max_payload=a.mtu_payload):
        payloads.append(payload)
        frames.append(net.eth_frame(net.udp_ipv4(payload, dport=a.port)))
    net.write_pcap(a.output, frames)
    with open(a.output.rsplit(".", 1)[0] + ".mold", "wb") as fh:
        for p in payloads:
            fh.write(struct.pack(">H", len(p)) + p)
    print(f"{len(msgs):,} messages -> {len(frames):,} packets -> {a.output}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stats");   s.add_argument("file"); s.add_argument("--limit", type=int)
    e = sub.add_parser("extract"); e.add_argument("file"); e.add_argument("-o", "--output", required=True)
    e.add_argument("--symbols", nargs="*"); e.add_argument("--start"); e.add_argument("--count", type=int)
    p = sub.add_parser("pcap");    p.add_argument("file"); p.add_argument("-o", "--output", required=True)
    p.add_argument("--port", type=int, default=net.MCAST_PORT)
    p.add_argument("--mtu-payload", type=int, default=1400)
    a = ap.parse_args(argv)
    {"stats": cmd_stats, "extract": cmd_extract, "pcap": cmd_pcap}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
