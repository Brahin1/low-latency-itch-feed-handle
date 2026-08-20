"""
regmap.py — AXI4-Lite register map of feed_handler_top, shared by the cocotb
testbench and the scripts that run on the Zynq's ARM, so both decode records
the same way.
"""
from itch import Record, sym8

ID, CTRL, UDP_PORT, WATCH_EN = 0x000, 0x004, 0x008, 0x00C
EXP_SEQ_LO, EXP_SEQ_HI, FIFO_MAX = 0x070, 0x074, 0x078
REC_COUNT, REC_POP, REC_W0 = 0x080, 0x084, 0x0C0
ID_VALUE = 0x49544348  # "ITCH"

CTRL_ENABLE, CTRL_PASS_ALL, CTRL_CLEAR, CTRL_RELEARN = 0x1, 0x2, 0x4, 0x8

STATS = ["frames", "fcs_err", "filtered", "mold_pkts", "msgs", "gaps", "dup_msgs",
         "len_err", "fifo_ovf", "records", "rec_drop", "heartbeats"]


def WATCH_HI(i): return 0x010 + 8 * i
def WATCH_LO(i): return 0x014 + 8 * i
def LEARNED(i):  return 0x030 + 4 * i
def STAT(name):  return 0x040 + 4 * STATS.index(name)


def sym_words(symbol: str):
    b = sym8(symbol)
    return int.from_bytes(b[:4], "big"), int.from_bytes(b[4:], "big")


def unpack_record(w: list[int]):
    """16 words from REC_W0.. -> ('rec', Record, cycle) or ('marker', ok, cycle)."""
    typ, side, loc = w[0] >> 24, (w[0] >> 16) & 0xFF, w[0] & 0xFFFF
    if typ == 0xFF:
        return "marker", bool(side & 1), w[15]
    q = lambda hi, lo: (w[hi] << 32) | w[lo]
    rec = Record(type=typ, locate=loc, ts=((w[1] & 0xFFFF) << 32) | w[2],
                 ref=q(3, 4), new_ref=q(5, 6), side=side, shares=w[7], price=w[8],
                 stock=q(9, 10), match=q(11, 12), seq=q(13, 14), sym_idx=(w[1] >> 16) & 3)
    return "rec", rec, w[15]
