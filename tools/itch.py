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
