# TideLink Pair — Raspberry Pi Ribbon Wire Chart

> **Status (2026-04-29):** FPGA-pin and physical-J13-pin columns both verified
> against the official Xilinx PYNQ Z2 base.xdc (`Xilinx/PYNQ` repo,
> `boards/Pynq-Z2/base/vivado/constraints/base.xdc`). The Vivado pynq-z2 A.0
> board file (`raspberry_pi_tri_i_<n>` indices) cross-checks cleanly.

The same bitstream is loaded onto both boards. The ribbon cable physically swaps TX↔RX between the two RPi headers so that **Board-A's `pad_tx[n]` arrives at Board-B's `pad_rx[n]`** (and vice versa). Each board's own XDC maps the bitstream's pad pins to the Vivado-named `raspberry_pi_tri_i_<n>` index — both boards run the same XDC.

## Verified pin map

All 18 lanes are on bank 35 (LVCMOS33). The 6 lanes marked **PA** are
*physically wired to both Pmod A and J13* on Pynq-Z2 v1.0 (per base.xdc:
"RPi GPIO 7-0 are shared with pmoda_rpi_gpio_tri_io[7:0]"). When the
ribbon is in use, **leave Pmod A unplugged** — anything connected to JA
loads these FPGA balls and corrupts the link.

| Lane | Vivado idx | FPGA pin | BCM GPIO | J13 pin | Pmod-A label |
|---|:---:|:---:|:---:|:---:|:---:|
| `pad_clk_tx` | 0  | W18 | 2  | **3**  | JA4_P (PA) |
| `pad_tx[0]`  | 1  | W19 | 3  | **5**  | JA4_N (PA) |
| `pad_tx[1]`  | 2  | Y18 | 4  | **7**  | JA1_P (PA) |
| `pad_tx[2]`  | 3  | Y19 | 5  | **29** | JA1_N (PA) |
| `pad_tx[3]`  | 4  | U18 | 6  | **31** | JA3_P (PA) |
| `pad_tx[4]`  | 5  | U19 | 7  | **26** | JA3_N (PA) |
| `pad_tx[5]`  | 6  | F19 | 8  | **24** | — |
| `pad_tx[6]`  | 7  | V10 | 9  | **21** | — |
| `pad_tx[7]`  | 8  | V8  | 10 | **19** | — |
| `pad_clk_rx` | 9  | W10 | 11 | **23** | — |
| `pad_rx[0]`  | 10 | B20 | 12 | **32** | — |
| `pad_rx[1]`  | 11 | W8  | 13 | **33** | — |
| `pad_rx[2]`  | 12 | V6  | 14 | **8**  | — |
| `pad_rx[3]`  | 13 | Y6  | 15 | **10** | — |
| `pad_rx[4]`  | 14 | B19 | 16 | **36** | — |
| `pad_rx[5]`  | 15 | U7  | 17 | **11** | — |
| `pad_rx[6]`  | 16 | C20 | 18 | **12** | — |
| `pad_rx[7]`  | 17 | Y8  | 19 | **35** | — |

## Ribbon cable wire chart

For a **cross-strap** cable (one bitstream both sides — `pynq-z2-pair`):

| Board A J13 pin | Lane (TX) | ↔ | Lane (RX) | Board B J13 pin |
|:---:|:---|:---:|:---|:---:|
| **3**  | `pad_clk_tx` | ↔ | `pad_clk_rx` | **23** |
| **5**  | `pad_tx[0]`  | ↔ | `pad_rx[0]`  | **32** |
| **7**  | `pad_tx[1]`  | ↔ | `pad_rx[1]`  | **33** |
| **29** | `pad_tx[2]`  | ↔ | `pad_rx[2]`  | **8**  |
| **31** | `pad_tx[3]`  | ↔ | `pad_rx[3]`  | **10** |
| **26** | `pad_tx[4]`  | ↔ | `pad_rx[4]`  | **36** |
| **24** | `pad_tx[5]`  | ↔ | `pad_rx[5]`  | **11** |
| **21** | `pad_tx[6]`  | ↔ | `pad_rx[6]`  | **12** |
| **19** | `pad_tx[7]`  | ↔ | `pad_rx[7]`  | **35** |

Cable does the cross — same wiring on both ends. Note the lanes are
*not* contiguous on the J13 connector: TX clock (pin 3) and TX data lane 4
(pin 26) are 23 pins apart, which adds skew on the forwarded clock.

For a **straight-through** cable (Pi Hut 1:1 ribbon), use `pynq-z2-pair`
on die_a and `pynq-z2-pair-flip` on die_b — the flip XDC mirrors the pad
direction so a 1:1 cable correctly delivers TX→RX. See the flip target's
README for that scheme.

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
