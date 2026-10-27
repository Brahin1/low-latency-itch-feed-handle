# itch-feed-handler

A low-latency Nasdaq TotalView-ITCH 5.0 feed handler in SystemVerilog, built for the Puzhi
PZ7020-StarLite (Zynq-7000 XC7Z020).

Market data packets arrive on the board's FPGA-side gigabit Ethernet port and are decoded
entirely in programmable logic, wire to record. The ARM processor isn't in the data path. It
only configures the parser, reads counters and drains decoded records.

## What it does

```
PL PHY --RGMII--> rgmii_rx -> eth_mac_rx -> async FIFO -> udp_rx -> moldudp64_rx -> itch_decoder -> records
                  |------ rx_clk 125 MHz ------|  (Gray CDC)  |-------------- core_clk 200 MHz --------------|
```

- **Ethernet receive:** RGMII DDR capture, preamble/SFD detection and CRC-32 frame check.
- **Protocol parsing:** Ethernet II → IPv4 → UDP → MoldUDP64 → ITCH 5.0, one byte per clock.
- **Cut-through:** each frame is parsed as it arrives. The frame check at the end commits or
  discards what was produced, so the design never waits for a whole frame.
- **Sequencing:** MoldUDP64 gaps and duplicates are detected and counted. The sequence state
  is speculative and rolls back if a frame fails its CRC.
- **Decoding:** Add (A, F), Execute (E, C), Cancel (X), Delete (D), Replace (U) and Trade (P)
  messages become fixed-format records.
- **Watchlist:** up to four symbols. Their Stock Locate codes are learned from Stock
  Directory (R) messages, so executions and cancels, which carry no symbol, are still
  filtered correctly.
- **Clock-domain crossing:** a hand-written Gray-pointer async FIFO moves bytes from the
  PHY's recovered clock into the 200 MHz core clock.
- **Control plane:** an AXI4-Lite register block exposes configuration, statistics counters
  and a BRAM record queue to the ARM.

## Repository structure

| Path           | Contents                                                                                                                                              |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rtl/`         | SystemVerilog design: RGMII receive, MAC, CDC primitives and async FIFO, protocol parsers, ITCH decoder, record queue, AXI4-Lite registers, top level |
| `tb/`          | cocotb testbenches, unit tests per module plus end-to-end tests through the pin interface                                                             |
| `tools/`       | Python golden model and utilities: ITCH encode/decode, packet framing, synthetic feed generation, Nasdaq historical file tools, ARM-side test scripts |
| `constraints/` | XDC pin and timing constraints for the PZ7020                                                                                                         |
| `vivado/`      | Tcl scripts to build the block design, bitstream and debug cores                                                                                      |
| `docs/`        | Design notes and results                                                                                                                              |

## Tools

- Simulation: Icarus Verilog and cocotb
- Synthesis and implementation: AMD Vivado
- Python 3 (standard library only for the golden model)

## Status

Some files are still in progress and will be pushed soon.
