#!/usr/bin/env python3
"""
ps_replay.py — replay MoldUDP64 packets as UDP multicast out of the PS Ethernet
port. Runs on the Zynq's ARM (PetaLinux / PYNQ image) or any Linux host.

Bench wiring: a patch cable from the board's PS Ethernet jack to its PL Ethernet
jack. Packets leave through the ARM's hardened GEM MAC, cross a real copper
link, and arrive at the fabric parser. Gigabit PHYs almost always do auto-MDIX, so a
straight cable should link at 1000 Mb/s (check the PHY datasheet).

One-time setup on the ARM:
  ip addr add 10.0.0.1/24 dev eth0 && ip link set eth0 up
  ip route add 224.0.0.0/4 dev eth0
  ethtool eth0            # confirm "Speed: 1000Mb/s" — the PL MAC is gigabit-only

Examples
  python3 ps_replay.py aapl_open.mold --pps 20000
  python3 ps_replay.py --synthetic 50000 --pps 50000

Python's socket loop tops out around 50-100k packets/s on a Cortex-A9. That is
fine for correctness; for true line-rate stress, replay the .pcap from a PC
with `tcpreplay --topspeed` into the PL port instead.
"""
from __future__ import annotations

import argparse
import socket
import struct
import time

import gen_feed
import net


def load_mold(path: str) -> list[bytes]:
    out = []
    with open(path, "rb") as fh:
        while hdr := fh.read(2):
            (n,) = struct.unpack(">H", hdr)
            out.append(fh.read(n))
    return out


def sender(group=net.MCAST_IP, iface_ip="10.0.0.1"):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface_ip))
    return s


def replay(payloads: list[bytes], pps: float, port=net.MCAST_PORT, group=net.MCAST_IP,
           iface_ip="10.0.0.1"):
    s = sender(group, iface_ip)
    gap = 1.0 / pps if pps else 0.0
    t_next = time.perf_counter()
    for p in payloads:
        if gap:
            while time.perf_counter() < t_next:
                pass
            t_next += gap
        s.sendto(p, (group, port))
    return len(payloads)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mold", nargs="?", help=".mold file from itch_file.py pcap")
    ap.add_argument("--synthetic", type=int, help="generate N synthetic messages instead")
    ap.add_argument("--pps", type=float, default=10_000)
    ap.add_argument("--port", type=int, default=net.MCAST_PORT)
    ap.add_argument("--iface-ip", default="10.0.0.1")
    a = ap.parse_args()
    if a.synthetic:
        payloads = [p for _, _, p in net.pack_messages(gen_feed.generate(a.synthetic), 1)]
    else:
        payloads = load_mold(a.mold)
    t0 = time.perf_counter()
    n = replay(payloads, a.pps, a.port, iface_ip=a.iface_ip)
    dt = time.perf_counter() - t0
    print(f"sent {n} packets in {dt:.3f} s ({n/dt:,.0f} pkt/s)")


if __name__ == "__main__":
    main()
