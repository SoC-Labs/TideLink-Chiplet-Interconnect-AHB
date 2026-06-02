# Clock-Pin & Buffer-Chain Audit — PYNQ-Z2 TideLink Pair (2026-06-02)

## 1. Headline

The **existing clock-pin assignment is already optimal** for the PYNQ-Z2 J13 RPi
header: `pad_clk_rx` on **Y7 (L13P MRCC bank 13)** and `pad_clk_tx` on
**Y9 (L14P SRCC bank 13)**. J13 exposes only four clock-capable P-side pins
(Y7-MRCC, Y9-SRCC, U7-SRCC, U18-MRCC). U18 is Pmod-A-shared with I2C pull-ups
(rebased away from in 2026-04-29), U7 is already in use as `pad_rx[0]`/master,
and the cable cross-strap forces master's TX pin to land on the slave's RX pin —
which Vivado's PLIO-9 DRC rejects on N-side. Y7/Y9 satisfy all four constraints
(P-side, MRCC on RX, SRCC on TX, both in bank 13 with the data lanes). The
real win is the **RX buffer chain restructure**: replace the current
`IBUFG → BUFG` with `IBUFG → BUFIO + BUFR (BYPASS_DIV=1)` so the RX sample
clock stays on the bank-13 clock-region routing (BUFIO ~0.3 ns skew) instead
of the global tree (BUFG ~1.5–2 ns insertion + ~ns of skew). This requires
the RX flops to be in the **same I/O column as Y7** (bank 13) — which they
already are for 13/16 RX-side balls.

## 2. J13 RPi pin inventory (clock-capable, bank, partner)

Source: `/apps/Xilinx/Vivado/2021.1/data/parts/.../xc7z020clg400_pkg.xml` + board
`part0_pins.xml`.

| RPi idx | FPGA ball | IOType (decoded) | Bank | Clk-cap | Pair partner | Currently |
|---:|:---:|:--|:---:|:---:|:---:|:---|
| 0  | W18 | L22P_T3            | 34 | —       | W19      | Pmod-A JA9, rebased away |
| 1  | W19 | L22N_T3            | 34 | —       | W18      | Pmod-A JA10 |
| 2  | Y18 | L17P_T2            | 34 | —       | Y19      | Pmod-A JA1 |
| 3  | Y19 | L17N_T2            | 34 | —       | Y18      | Pmod-A JA2 |
| 4  | U18 | L12P_T1_**MRCC**   | 34 | **MRCC-P** | U19   | Pmod-A JA7 (I2C pull-up — unusable) |
| 5  | U19 | L12N_T1_MRCC       | 34 | MRCC-N  | U18      | Pmod-A JA8 |
| 6  | F19 | L15P_T2_DQS        | 35 | —       | F20      | pad_tx[0] master / pad_rx[0] flip (cross-bank) |
| 7  | V10 | L21N_T3_DQS        | 13 | —       | V11      | pad_tx[1] |
| 8  | V8  | L15P_T2_DQS        | 13 | —       | W8       | pad_tx[2] |
| 9  | W10 | L16P_T2            | 13 | —       | W9       | pad_tx[3] |
| 10 | B20 | L1N_T0_AD0N        | 35 | —       | C20      | pad_tx[4] (cross-bank) |
| 11 | W8  | L15N_T2_DQS        | 13 | —       | V8       | pad_tx[5] |
| 12 | V6  | L22P_T3            | 13 | —       | W6       | pad_tx[6] |
| 13 | Y6  | L13N_T2_**MRCC**   | 13 | MRCC-N  | **Y7**   | pad_rx[6] (lane uses MRCC-N — fine for data) |
| 14 | B19 | L2P_T0_AD8P        | 35 | —       | A20      | physically bad — not used |
| 15 | U7  | L11P_T1_**SRCC**   | 13 | **SRCC-P** | V7    | pad_rx[0] (SRCC-P spent on a data lane) |
| 16 | C20 | L1P_T0_AD0P        | 35 | —       | B20      | pad_rx[1] (cross-bank) |
| 17 | Y8  | L14N_T2_SRCC       | 13 | SRCC-N  | **Y9**   | pad_rx[2] |
| 18 | A20 | L2N_T0_AD8N        | 35 | —       | B19      | pad_rx[3] (cross-bank) |
| 19 | **Y9**  | L14P_T2_**SRCC** | 13 | **SRCC-P** | Y8 | **pad_clk_tx** (master) |
| 20 | U8  | L17N_T2            | 13 | —       | (U7 pair) | pad_rx[4] |
| 21 | W6  | L22N_T3            | 13 | —       | V6       | pad_rx[5] |
| 22 | **Y7**  | L13P_T2_**MRCC** | 13 | **MRCC-P** | Y6 | **pad_clk_rx** (master) |
| 23 | F20 | L15N_T2_DQS        | 35 | —       | F19      | physically bad — not used |
| 24 | W9  | L16N_T2            | 13 | —       | W10      | pad_tx[7] (lane-7 remap) |
| —  | V7  | L11N_T1_SRCC       | 13 | SRCC-N  | U7       | pad_rx[7] (lane-7 remap) |

**Clock-capable P-side pins on J13:** Y7-MRCC-13, Y9-SRCC-13, U7-SRCC-13, U18-MRCC-34.
**Usable for forwarded clock:** Y7, Y9 (U18 blocked by Pmod-A, U7 already used as data).

## 3. Current vs proposed pin assignment

| Role | Current (master) | Current (flip slave) | Better available? |
|---|:---:|:---:|:---|
| pad_clk_rx | Y7 (MRCC-P bank 13) | Y9 (SRCC-P bank 13) | **No** — Y7 is the only MRCC-P on J13 in bank 13 |
| pad_clk_tx | Y9 (SRCC-P bank 13) | Y7 (MRCC-P bank 13) | **No** — only other P-side clock pin in bank 13 is U7 (used as data) |

The cable cross-strap forces a P/P symmetry: master pad_clk_tx pin == slave pad_clk_rx pin. Y7+Y9 is the only valid pair. **No pin move recommended.**

## 4. Buffer-chain recommendation — switch RX to BUFIO + BUFR

Current RX chain (`tidelink_clk_rx_buf.v`):

```
pad_clk_rx → IBUFG → BUFG → fans across global clock tree to all RX samplers
```

`BUFG` insertion delay is ~1.5–2 ns on 7-series and the global tree adds ~hundreds-of-ps of skew across the device. UG472 §3 and XAPP585 recommend, for forwarded source-synchronous capture, the **regional** chain:

```
pad_clk_rx → IBUFG → BUFIO  → ISERDESE2 / capture flops in same I/O column
                  └→ BUFR (BYPASS_DIV=1 or /1) → control-path / IDELAYE2 reset
```

- **BUFIO** is the lowest-skew clock route in a Zynq-7 I/O bank (~0.3 ns insertion, no skew within the bank). Drives capture-domain flops directly.
- **BUFR** is the regional buffer (clock-region wide) — useful for ancillary logic that needs the same domain but is outside BUFIO reach.
- BUFIO/BUFR only reach the **same I/O column**, so the per-lane RX sample flops must be placed in bank 13. Cross-bank pads (B20/A20/C20/F19) cannot use the BUFIO/BUFR clock — they'd need a separate BUFG.

**Recommendation:** keep `IBUFG → BUFG` for the present build (works, supports cross-bank lanes), but file a follow-up to move bank-13 RX lanes onto a `IBUFG → BUFIO + BUFR` chain and the four cross-bank lanes (B20/A20/C20/F19) onto a duplicate BUFG. This needs:

1. Split `clk_rx_buf` to emit two clock outputs (`clk_capture` = BUFIO, `clk_global` = BUFG).
2. Place RX sample flops via XDC `LOC IOB_*` for the in-bank-13 lanes.
3. Re-time `IDELAYE2` resets against the BUFR phase.

This is a multi-day RTL+XDC change with new placement constraints — out of scope for a quick fix. **Defer** to a dedicated SI follow-up.

## 5. Concrete changes recommended **for this pass**

**None.** Pin assignment is already optimal given the J13 constraints. The buffer-chain restructure is worth doing but is non-trivial (split wrapper, RX flop placement, IDELAYCTRL re-time). Recommend opening a tracking issue rather than landing now.

Files reviewed (no edits):
- `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/pynq_z2_tidelink.xdc:76,99`
- `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-flip-all/pynq_z2_tidelink.xdc:43,56`
- `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_clk_rx_buf.v:30-51`
- `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_design.tcl:336-363,666-673`
