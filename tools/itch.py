"""
itch.py — Nasdaq TotalView-ITCH 5.0 encode/decode + the golden reference model.

Everything the RTL does is mirrored here in plain Python, so the testbench (and
the on-board HIL check) can compare hardware output field-for-field against an
independent implementation.

Offsets and lengths follow the Nasdaq TotalView-ITCH 5.0 specification.
All integers are big-endian. Prices are unsigned 4-decimal fixed point
(Price(4)): $187.4200 is sent as 1874200.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field

# message type -> total length in bytes (including the type byte)
MSG_LEN = {
    b"S": 12, b"R": 39, b"H": 25, b"Y": 20, b"L": 26, b"V": 35, b"W": 12,
    b"K": 28, b"J": 35, b"h": 21, b"A": 36, b"F": 40, b"E": 31, b"C": 36,
    b"X": 23, b"D": 19, b"U": 35, b"P": 44, b"Q": 40, b"B": 19, b"I": 50,
    b"N": 20, b"O": 48,
}

RECORD_TYPES = b"AFECXDUP"   # types the hardware turns into records


def _hdr(t: bytes, locate: int, tracking: int, ts_ns: int) -> bytes:
    return t + struct.pack(">HH", locate, tracking) + ts_ns.to_bytes(6, "big")


def sym8(s: str) -> bytes:
    """ITCH stock field: 8 ASCII bytes, left-justified, space padded."""
    return s.encode("ascii").ljust(8, b" ")[:8]


# ---------------------------------------------------------------- encoders
def system_event(ts, code=b"O", locate=0, tracking=0):
    return _hdr(b"S", locate, tracking, ts) + code

def stock_directory(ts, locate, symbol, tracking=0):
    # Stock Directory (R): after the header, Stock(8) then 20 bytes of
    # listing attributes that this design does not use.
    body = (sym8(symbol) + b"Q" + b"N" + struct.pack(">I", 100) + b"N" + b"C"
            + b"  " + b"P" + b"N" + b"N" + b"1" + b"N" + struct.pack(">I", 0) + b"N")
    msg = _hdr(b"R", locate, tracking, ts) + body
    assert len(msg) == 39, len(msg)
    return msg

def add_order(ts, locate, ref, side, shares, symbol, price, tracking=0):
    return _hdr(b"A", locate, tracking, ts) + struct.pack(
        ">Qc I 8s I".replace(" ", ""), ref, side, shares, sym8(symbol), price)

def add_order_mpid(ts, locate, ref, side, shares, symbol, price, mpid=b"GSCO", tracking=0):
    return add_order(ts, locate, ref, side, shares, symbol, price, tracking).replace(
        b"A", b"F", 1) + mpid

def order_executed(ts, locate, ref, shares, match, tracking=0):
    return _hdr(b"E", locate, tracking, ts) + struct.pack(">QIQ", ref, shares, match)

def order_executed_price(ts, locate, ref, shares, match, price, printable=b"Y", tracking=0):
    return _hdr(b"C", locate, tracking, ts) + struct.pack(">QIQcI", ref, shares, match,
                                                         printable, price)

def order_cancel(ts, locate, ref, shares, tracking=0):
    return _hdr(b"X", locate, tracking, ts) + struct.pack(">QI", ref, shares)

def order_delete(ts, locate, ref, tracking=0):
    return _hdr(b"D", locate, tracking, ts) + struct.pack(">Q", ref)

def order_replace(ts, locate, ref, new_ref, shares, price, tracking=0):
    return _hdr(b"U", locate, tracking, ts) + struct.pack(">QQII", ref, new_ref, shares, price)

def trade(ts, locate, ref, side, shares, symbol, price, match, tracking=0):
    return _hdr(b"P", locate, tracking, ts) + struct.pack(">QcI8sIQ", ref, side, shares,
                                                         sym8(symbol), price, match)


# ---------------------------------------------------------------- record
@dataclass(frozen=True)
class Record:
    """One decoded record exactly as the hardware emits it (unused fields = 0)."""
    type: int
    locate: int
    ts: int
    ref: int = 0
    new_ref: int = 0
    side: int = 0
    shares: int = 0
    price: int = 0
    stock: int = 0
    match: int = 0
    seq: int = 0
    sym_idx: int = 0

    def short(self) -> str:
        t = chr(self.type)
        return (f"{t} seq={self.seq} loc={self.locate} ref={self.ref} sh={self.shares} "
                f"px={self.price/1e4:.4f}")


def decode(msg: bytes, seq: int = 0, sym_idx: int = 0) -> Record | None:
    """Decode one ITCH message into a Record (None for non-record types)."""
    t = msg[0:1]
    if t not in RECORD_TYPES:
        return None
    locate, _trk = struct.unpack_from(">HH", msg, 1)
    ts = int.from_bytes(msg[5:11], "big")
    u32 = lambda o: struct.unpack_from(">I", msg, o)[0]
    u64 = lambda o: struct.unpack_from(">Q", msg, o)[0]
    base = dict(type=msg[0], locate=locate, ts=ts, ref=u64(11), seq=seq, sym_idx=sym_idx)
    if t in (b"A", b"F"):
        return Record(**base, side=msg[19], shares=u32(20), stock=u64(24), price=u32(32))
    if t == b"E":
        return Record(**base, shares=u32(19), match=u64(23))
    if t == b"C":
        return Record(**base, shares=u32(19), match=u64(23), price=u32(32))
    if t == b"X":
        return Record(**base, shares=u32(19))
    if t == b"D":
        return Record(**base)
    if t == b"U":
        return Record(**base, new_ref=u64(19), shares=u32(27), price=u32(31))
    if t == b"P":
        return Record(**base, side=msg[19], shares=u32(20), stock=u64(24), price=u32(32),
                      match=u64(36))
    return None


# ---------------------------------------------------------------- golden model
@dataclass
class GoldenFeedHandler:
    """
    Bit-accurate behavioural model of the hardware pipeline from the UDP payload
    down. Feed it frames in wire order with their MAC verdict; it produces the
    records the hardware should *commit*, plus every counter.
    """
    udp_port: int
    watch: list[str] = field(default_factory=list)   # up to 4 symbols
    pass_all: bool = False
    enable: bool = True

    def __post_init__(self):
        self.learned: dict[int, int] = {}              # slot -> locate
        self.exp_seq = 0
        self.seq_ok = False
        self.committed: list[Record] = []
        self.stats = dict(frames=0, fcs_err=0, filtered=0, mold_pkts=0, msgs=0, gaps=0,
                          dup_msgs=0, len_err=0, records=0, heartbeats=0)

    def _slot_for(self, locate: int):
        for slot, loc in sorted(self.learned.items()):
            if loc == locate:
                return slot
        return None

    def frame(self, udp_payload: bytes | None, dport: int | None, frame_ok: bool):
        """
        udp_payload/dport: the UDP payload and destination port, or None when the
        frame is not IPv4/UDP. frame_ok: FCS good, no RX_ER, not a runt.
        """
        self.stats["frames"] += 1
        accepted = (self.enable and udp_payload is not None and dport == self.udp_port
                    and len(udp_payload) > 0)
        if not frame_ok:
            self.stats["fcs_err"] += 1
        elif not accepted:
            self.stats["filtered"] += 1
        if not accepted:
            return

        # Speculative sequence state, rolled back if the frame turns out bad.
        exp_save, ok_save = self.exp_seq, self.seq_ok
        pending: list[Record] = []
        self._mold(udp_payload, pending)
        if frame_ok:
            self.committed.extend(pending)
        else:
            self.exp_seq, self.seq_ok = exp_save, ok_save

    def _mold(self, p: bytes, out: list[Record]):
        if len(p) < 20:
            return
        seq = int.from_bytes(p[10:18], "big")
        count = int.from_bytes(p[18:20], "big")
        if count in (0, 0xFFFF):
            self.stats["heartbeats"] += 1
            return
        self.stats["mold_pkts"] += 1
        if not self.seq_ok:
            self.seq_ok, self.exp_seq, dup_left = True, seq, 0
        elif seq > self.exp_seq:
            self.stats["gaps"] += 1
            self.exp_seq, dup_left = seq, 0
        else:
            diff = self.exp_seq - seq
            dup_left = 0x1FFFF if diff > 0xFFFF else diff
        off, cur = 20, seq
        for _ in range(count):
            if off + 2 > len(p):
                return
            mlen = int.from_bytes(p[off:off + 2], "big")
            off += 2
            if mlen == 0 or off + mlen > len(p):
                return
            msg = p[off:off + mlen]
            off += mlen
            if dup_left:
                self.stats["dup_msgs"] += 1
                if dup_left != 0x1FFFF:
                    dup_left -= 1
            else:
                self._itch(msg, cur, out)
                self.exp_seq = cur + 1
            cur += 1

    def _itch(self, msg: bytes, seq: int, out: list[Record]):
        self.stats["msgs"] += 1
        t = msg[0:1]
        if t in MSG_LEN and len(msg) != MSG_LEN[t] and t in RECORD_TYPES + b"RS":
            self.stats["len_err"] += 1
            return
        locate = int.from_bytes(msg[1:3], "big")
        if t == b"R":
            stock = msg[11:19]
            for slot, s in enumerate(self.watch[:4]):
                if sym8(s) == stock:
                    self.learned[slot] = locate
        if t in RECORD_TYPES and len(t) == 1:
            slot = self._slot_for(locate)
            if self.pass_all or slot is not None:
                out.append(decode(msg, seq, slot or 0))
                self.stats["records"] += 1
