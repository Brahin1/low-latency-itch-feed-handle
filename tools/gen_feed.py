"""
gen_feed.py — synthetic but self-consistent ITCH 5.0 order flow.

Why synthetic in addition to the real NASDAQ file: the real file is 4-5 GB and
only exercises what happened that day. The generator lets a test ask for a
specific mix (every record type, replaces of replaced orders, partial fills,
multiple symbols interleaved) in a few thousand messages, deterministically
from a seed.

The book is kept consistent: executions, cancels, replaces and deletes only
reference live orders, and share counts never go negative.
"""
from __future__ import annotations

import random

import itch

DEFAULT_SYMBOLS = ["AAPL", "MSFT", "NVDA", "TSLA", "AMZN", "META", "GOOGL", "AMD"]


def generate(n_msgs: int, symbols=DEFAULT_SYMBOLS, seed: int = 1,
             start_ns: int = 34_200_000_000_000) -> list[bytes]:
    """Return a list of ITCH messages: system event, stock directory, then flow."""
    rng = random.Random(seed)
    ts = start_ns                                   # 09:30:00.000000000
    msgs: list[bytes] = [itch.system_event(ts - 1_000_000, b"Q")]
    locate = {s: 100 + i * 7 for i, s in enumerate(symbols)}
    for s in symbols:
        msgs.append(itch.stock_directory(ts - 500_000, locate[s], s))

    live: dict[int, tuple[str, bytes, int, int]] = {}   # ref -> (sym, side, shares, price)
    next_ref, next_match = 1_000_000, 5_000_000
    mid = {s: rng.randint(50_0000, 500_0000) for s in symbols}   # Price(4)

    while len(msgs) < n_msgs:
        ts += rng.randint(50, 20_000)
        s = rng.choice(symbols)
        mine = [r for r, o in live.items() if o[0] == s]
        roll = rng.random()

        if not mine or roll < 0.40:                              # add
            side = rng.choice([b"B", b"S"])
            px = mid[s] + rng.randint(-500, 500) * (1 if side == b"S" else -1)
            sh = rng.choice([100, 200, 300, 500, 1000, 37])
            ref = next_ref; next_ref += 1
            live[ref] = (s, side, sh, px)
            if rng.random() < 0.15:
                msgs.append(itch.add_order_mpid(ts, locate[s], ref, side, sh, s, px))
            else:
                msgs.append(itch.add_order(ts, locate[s], ref, side, sh, s, px))
            continue

        ref = rng.choice(mine)
        sym, side, sh, px = live[ref]
        if roll < 0.55:                                          # execute (maybe partial)
            q = rng.randint(1, sh)
            if rng.random() < 0.2:
                msgs.append(itch.order_executed_price(ts, locate[s], ref, q, next_match, px + 1))
            else:
                msgs.append(itch.order_executed(ts, locate[s], ref, q, next_match))
            next_match += 1
            sh -= q
        elif roll < 0.70:                                        # partial cancel
            q = rng.randint(1, sh)
            msgs.append(itch.order_cancel(ts, locate[s], ref, q))
            sh -= q
        elif roll < 0.82:                                        # replace
            new = next_ref; next_ref += 1
            nsh, npx = rng.choice([100, 200, 400]), px + rng.randint(-100, 100)
            msgs.append(itch.order_replace(ts, locate[s], ref, new, nsh, npx))
            del live[ref]
            live[new] = (sym, side, nsh, npx)
            continue
        elif roll < 0.92:                                        # delete
            msgs.append(itch.order_delete(ts, locate[s], ref))
            sh = 0
        else:                                                    # non-displayed trade
            msgs.append(itch.trade(ts, locate[s], 0, side, rng.randint(1, 500), s, px,
                                   next_match))
            next_match += 1
            continue

        if sh <= 0:
            live.pop(ref, None)
        else:
            live[ref] = (sym, side, sh, px)

    return msgs[:n_msgs]
