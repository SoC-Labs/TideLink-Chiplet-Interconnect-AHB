# TideLink Pair — Raspberry Pi Ribbon Wire Chart

> **Status (2026-04-27):** the FPGA-pin column is verified against the Vivado
> pynq-z2 A.0 board file (commit `12a6985`). The **physical RPi pin numbers**
> still need to be looked up from the Digilent Pynq-Z2 v1.0 Reference Manual
> §6.10 before the cable is built — flagged TODO below.

The same bitstream is loaded onto both boards. The ribbon cable physically swaps TX↔RX between the two RPi headers so that **Board-A's `pad_tx[n]` arrives at Board-B's `pad_rx[n]`** (and vice versa). Each board's own XDC maps the bitstream's pad pins to the Vivado-named `raspberry_pi_tri_i_<n>` index — both boards run the same XDC.

## FPGA-pin map (verified)

All 18 lanes are on bank 35 (LVCMOS33). Vivado-side index is the `raspberry_pi_tri_i_<n>` index from `/apps/Xilinx/Vivado/2021.1/data/boards/pynq-z2/A.0/part0_pins.xml`.

| Lane | Vivado RPi index | FPGA pin |
|---|---|---|
| `pad_clk_tx` | 0 | W18 |
| `pad_tx[0]` | 1 | W19 |
| `pad_tx[1]` | 2 | Y18 |
| `pad_tx[2]` | 3 | Y19 |
| `pad_tx[3]` | 4 | U18 |
| `pad_tx[4]` | 5 | U19 |
| `pad_tx[5]` | 6 | F19 |
| `pad_tx[6]` | 7 | V10 |
| `pad_tx[7]` | 8 | V8 |
| `pad_clk_rx` | 9 | W10 |
| `pad_rx[0]` | 10 | B20 |
| `pad_rx[1]` | 11 | W8 |
| `pad_rx[2]` | 12 | V6 |
| `pad_rx[3]` | 13 | Y6 |
| `pad_rx[4]` | 14 | B19 |
| `pad_rx[5]` | 15 | U7 |
| `pad_rx[6]` | 16 | C20 |
| `pad_rx[7]` | 17 | Y8 |

## Ribbon cable wire chart — **TODO**

The cable is built between the two RPi headers (J13 on each Pynq-Z2). For each lane, you need: **Board-A J13 physical pin number** ↔ **Board-B J13 physical pin number**, with the cable physically swapping TX→RX.

The Digilent Pynq-Z2 v1.0 Reference Manual Table 6.10 lists the J13-pin → Vivado-index mapping. **Look this up before cutting cable** — the Vivado index is *not* the same as the physical RPi pin number. (Nor is it the BCM GPIO number — Pynq-Z2 doesn't follow standard Pi-40 conventions exactly on every pin.)

The cable convention:

```
Board A J13 (TX side)               Board B J13 (RX side)
pin for index 0  (pad_clk_tx)  -->  pin for index 9  (pad_clk_rx)
pin for index 1  (pad_tx[0])   -->  pin for index 10 (pad_rx[0])
...                                 ...
pin for index 8  (pad_tx[7])   -->  pin for index 17 (pad_rx[7])

Board A J13 (RX side)               Board B J13 (TX side)
pin for index 9  (pad_clk_rx)  <--  pin for index 0  (pad_clk_tx)
pin for index 10 (pad_rx[0])   <--  pin for index 1  (pad_tx[0])
...                                 ...
pin for index 17 (pad_rx[7])   <--  pin for index 8  (pad_tx[7])
```

In other words, each ribbon strand connects Board-A's "TX index *i*" J13 pin to Board-B's "RX index *(i + 9)*" J13 pin. Same on both sides; the cable does the cross.

## Ground returns

The Pynq-Z2 RPi header has GNDs on physical pins 6, 9, 14, 20, 25, 30, 34, 39. Tie at least 4 GNDs through the ribbon between the two boards for signal integrity (e.g. pin 9↔9, 14↔14, 25↔25, 39↔39).

## Power

**Do NOT** wire +3V3 (J13 pins 1, 17) or +5V (J13 pins 2, 4) through the ribbon. Each board powers itself from its own micro-USB.

## Cable spec

- Length: ≤10 cm (longer = ringing on the unimpedance-matched header).
- Conductor: 28 AWG flat ribbon, 26-way (covers the 18 lanes + GNDs + spare).
- Connector: 2x20 IDC matching J13 on the Pynq-Z2.
- Wiring: explicit point-to-point per the table above. Do **not** use a straight-through ribbon — the cross-strap is the whole point.

## Verification recipe

1. Build the cable per the table; print this file for the bench.
2. With both boards powered off, plug the ribbon in.
3. Power on board A, then board B.
4. `fpgahub pair up tidelink_bridge_01 --ttl 7200` — programs both boards.
5. After ~1 second: LD0 (`link_active`) should be solid on both boards. LD1 (`role_is_master_o`) should be on for exactly one board.

## Future: PCB carrier

A short rigid carrier PCB with proper LVDS termination would let us push the link clock above 50 MHz. For the v1 bring-up the flat ribbon is fine; future revisions should consider a small PCB cap above the headers.
