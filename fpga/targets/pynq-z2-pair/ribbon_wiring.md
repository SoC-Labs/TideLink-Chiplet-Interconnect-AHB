# TideLink Pair — Raspberry Pi Ribbon Wire Chart

The same bitstream is loaded onto both boards. The ribbon cable physically swaps TX↔RX between the two RPi headers so that **Board-A's `pad_tx[n]` arrives at Board-B's `pad_rx[n]`** (and vice versa).

Both boards expose 18 PHY lanes on the Raspberry Pi header (J13). The XDC pins are identical on both boards; the ribbon does the cross-strap.

## Wire chart

| Lane | Board A RPi pin (BCM GPIO) | Board B RPi pin (BCM GPIO) | Direction |
|---|---|---|---|
| `pad_clk_tx` (A) → `pad_clk_rx` (B) | pin 4 (GPIO 2) | pin 26 (GPIO 7) | A → B |
| `pad_clk_rx` (A) ← `pad_clk_tx` (B) | pin 26 (GPIO 7) | pin 4 (GPIO 2) | A ← B |
| `pad_tx[0]` (A) → `pad_rx[0]` (B) | pin 6 (GPIO 3) | pin 36 (GPIO 16) | A → B |
| `pad_rx[0]` (A) ← `pad_tx[0]` (B) | pin 36 (GPIO 16) | pin 6 (GPIO 3) | A ← B |
| `pad_tx[1]` (A) → `pad_rx[1]` (B) | pin 8 (GPIO 4) | pin 38 (GPIO 20) | A → B |
| `pad_rx[1]` (A) ← `pad_tx[1]` (B) | pin 38 (GPIO 20) | pin 8 (GPIO 4) | A ← B |
| `pad_tx[2]` (A) → `pad_rx[2]` (B) | pin 10 (GPIO 14) | pin 40 (GPIO 21) | A → B |
| `pad_rx[2]` (A) ← `pad_tx[2]` (B) | pin 40 (GPIO 21) | pin 10 (GPIO 14) | A ← B |
| `pad_tx[3]` (A) → `pad_rx[3]` (B) | pin 12 (GPIO 15) | pin 32 (GPIO 12) | A → B |
| `pad_rx[3]` (A) ← `pad_tx[3]` (B) | pin 32 (GPIO 12) | pin 12 (GPIO 15) | A ← B |
| `pad_tx[4]` (A) → `pad_rx[4]` (B) | pin 16 (GPIO 23) | pin 33 (GPIO 13) | A → B |
| `pad_rx[4]` (A) ← `pad_tx[4]` (B) | pin 33 (GPIO 13) | pin 16 (GPIO 23) | A ← B |
| `pad_tx[5]` (A) → `pad_rx[5]` (B) | pin 18 (GPIO 24) | pin 35 (GPIO 19) | A → B |
| `pad_rx[5]` (A) ← `pad_tx[5]` (B) | pin 35 (GPIO 19) | pin 18 (GPIO 24) | A ← B |
| `pad_tx[6]` (A) → `pad_rx[6]` (B) | pin 22 (GPIO 25) | pin 37 (GPIO 26) | A → B |
| `pad_rx[6]` (A) ← `pad_tx[6]` (B) | pin 37 (GPIO 26) | pin 22 (GPIO 25) | A ← B |
| `pad_tx[7]` (A) → `pad_rx[7]` (B) | pin 24 (GPIO 8)  | pin 31 (GPIO 6)  | A → B |
| `pad_rx[7]` (A) ← `pad_tx[7]` (B) | pin 31 (GPIO 6)  | pin 24 (GPIO 8)  | A ← B |

## Ground returns

The Pynq-Z2 RPi header has GNDs on pins 6, 9, 14, 20, 25, 30, 34, 39. Tie at least 4 GNDs through the ribbon between the two boards for signal integrity. Recommended: pin 9 (A) ↔ pin 9 (B), pin 14 ↔ 14, pin 25 ↔ 25, pin 39 ↔ 39.

## Power

**Do NOT** wire the +3V3 or +5V pins through the ribbon. Each board powers itself from its own micro-USB. The Pynq-Z2 RPi header carries 3.3V on pins 1, 17 and 5V on pins 2, 4 (wait — pin 4 is `pad_clk_tx` in our map; double-check before connecting). With the ribbon's twist, pin 4 on board A meets pin 26 on board B, so cross-power isn't a concern, but a striped ribbon should be inspected once before plugging in.

## Cable spec

- Length: ≤10 cm (longer = increased ringing on the unimpedance-matched RPi header).
- Conductor: 28 AWG flat ribbon, 26-way (covers the 18 lanes + GNDs + spare).
- Connector: 40-pin 2x20 IDC matching the RPi-style header on the Pynq-Z2.
- Wiring: explicit point-to-point per the table above. Do **not** use a straight-through ribbon — the cross-strap is the whole point.

## Build / verification recipe

1. Build the cable per the table; print this file for the bench.
2. With both boards powered off, plug the ribbon in.
3. Power on board A, then board B (the order doesn't matter electrically; this is just the order the bringup_order in `[pairs.tidelink_bridge_01]` walks).
4. `fpgahub pair up tidelink_bridge_01 --ttl 7200` — programs both boards.
5. After ~1 second: LD0 (`link_active`) should be solid on both boards. LD1 (`role_is_master_o`) should be on for exactly one board. If not: see the Sanity-checks section in `README.md`.

## Future: PCB carrier

A short rigid carrier PCB with proper LVDS termination would let us push the link clock above 50 MHz. For the v1 bring-up the flat ribbon is fine; future revisions should consider a small PCB cap above the headers.
