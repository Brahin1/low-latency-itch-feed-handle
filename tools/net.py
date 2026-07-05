"""
net.py — MoldUDP64 / UDP / IPv4 / Ethernet framing, FCS, and pcap output.

No third-party dependencies (no scapy), so it runs unchanged on the Zynq's ARM.
"""
from __future__ import annotations

import struct
import zlib

MCAST_IP = "233.54.12.111"        # example multicast group
MCAST_PORT = 26477


# ---------------------------------------------------------------- MoldUDP64
def mold_packet(session: bytes, seq: int, msgs: list[bytes]) -> bytes:
    hdr = session.ljust(10, b" ")[:10] + struct.pack(">QH", seq, len(msgs))
    return hdr + b"".join(struct.pack(">H", len(m)) + m for m in msgs)

def mold_heartbeat(session: bytes, next_seq: int) -> bytes:
    return session.ljust(10, b" ")[:10] + struct.pack(">QH", next_seq, 0)


def pack_messages(msgs: list[bytes], first_seq: int, session=b"TESTSESS01",
                  max_payload=1400, max_msgs=None):
    """Greedy-pack messages into MoldUDP64 packets. Yields (seq, [msgs], payload)."""
    seq, batch, size = first_seq, [], 20
    for m in msgs:
        if batch and (size + 2 + len(m) > max_payload or (max_msgs and len(batch) >= max_msgs)):
            yield seq, batch, mold_packet(session, seq, batch)
            seq += len(batch)
            batch, size = [], 20
        batch.append(m)
        size += 2 + len(m)
    if batch:
        yield seq, batch, mold_packet(session, seq, batch)


# ---------------------------------------------------------------- IPv4 / UDP
def ip_bytes(s: str) -> bytes:
    return bytes(int(x) for x in s.split("."))

def mcast_mac(ip: str) -> bytes:
    """RFC 1112: 01:00:5e + low 23 bits of the group address."""
    b = ip_bytes(ip)
    return bytes([0x01, 0x00, 0x5E, b[1] & 0x7F, b[2], b[3]])

def ipv4_checksum(hdr: bytes) -> int:
    s = sum(struct.unpack(f">{len(hdr)//2}H", hdr))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF

def udp_ipv4(payload: bytes, src_ip="10.0.0.1", dst_ip=MCAST_IP, sport=40000,
             dport=MCAST_PORT, ip_options: bytes = b"", proto=17) -> bytes:
    assert len(ip_options) % 4 == 0
    ihl = 5 + len(ip_options) // 4
    udp = struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload  # UDP csum 0 = none
    total = ihl * 4 + len(udp)
    hdr = struct.pack(">BBHHHBBH4s4s", 0x40 | ihl, 0, total, 0, 0x4000, 16, proto, 0,
                      ip_bytes(src_ip), ip_bytes(dst_ip)) + ip_options
    hdr = hdr[:10] + struct.pack(">H", ipv4_checksum(hdr)) + hdr[12:]
    return hdr + udp


# ---------------------------------------------------------------- Ethernet
def fcs(frame: bytes) -> bytes:
    """IEEE 802.3 CRC-32, transmitted least-significant byte first."""
    return struct.pack("<I", zlib.crc32(frame) & 0xFFFFFFFF)

def eth_frame(l3: bytes, dst=None, src=b"\x02\x00\x00\x00\x00\x01", ethertype=0x0800,
              bad_fcs=False) -> bytes:
    """Ethernet II frame (no preamble) padded to 60 bytes, with FCS."""
    dst = dst or mcast_mac(MCAST_IP)
    f = dst + src + struct.pack(">H", ethertype) + l3
    f = f.ljust(60, b"\x00")
    c = fcs(f)
    if bad_fcs:
        c = bytes([c[0] ^ 0x01]) + c[1:]
    return f + c

def wire(frame_with_fcs: bytes, preamble_len=7) -> bytes:
    """What actually crosses RGMII: preamble + SFD + frame + FCS."""
    return b"\x55" * preamble_len + b"\xD5" + frame_with_fcs


def crc_residue_check(frame_with_fcs: bytes) -> int:
    """Bit-serial reflected CRC over frame+FCS, exactly as eth_mac_rx computes it."""
    c = 0xFFFFFFFF
    for byte in frame_with_fcs:
        c ^= byte
        for _ in range(8):
            c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
    return c


def parse_udp(frame_with_fcs: bytes):
    """Inverse of the hardware header parser: returns (dport, payload) or (None, None)."""
    f = frame_with_fcs
    if len(f) < 14 + 20 + 8 or f[12:14] != b"\x08\x00":
        return None, None
    ver, ihl = f[14] >> 4, f[14] & 0xF
    if ver != 4 or ihl < 5 or f[14 + 9] != 17:
        return None, None
    u = 14 + ihl * 4
    dport, ulen = struct.unpack_from(">HH", f, u + 2)
    if ulen <= 8 or ulen >= 1481:
        return dport, None
    return dport, f[u + 8:u + ulen]


# ---------------------------------------------------------------- pcap
def write_pcap(path: str, frames: list[bytes], pps: float = 100_000.0):
    """Write frames (with FCS stripped, as capture tools do) to a classic pcap."""
    with open(path, "wb") as fh:
        fh.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        t = 0.0
        for fr in frames:
            data = fr[:-4]
            sec, usec = int(t), int((t - int(t)) * 1e6)
            fh.write(struct.pack("<IIII", sec, usec, len(data), len(data)) + data)
            t += 1.0 / pps

def read_pcap_udp_payloads(path: str, dport: int):
    """Yield UDP payloads for dport from a classic pcap (Ethernet link type)."""
    with open(path, "rb") as fh:
        gh = fh.read(24)
        endian = "<" if struct.unpack("<I", gh[:4])[0] == 0xA1B2C3D4 else ">"
        while True:
            ph = fh.read(16)
            if len(ph) < 16:
                return
            _, _, incl, _ = struct.unpack(endian + "IIII", ph)
            data = fh.read(incl)
            dp, payload = parse_udp(data + b"\0\0\0\0")
            if dp == dport and payload is not None:
                yield payload
