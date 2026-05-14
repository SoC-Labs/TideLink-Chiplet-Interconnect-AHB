# PYNQ-Z2 Connector Coexistence — TideLink + SF3 Flash + LAN8720 + J-Link SWD

> **Scope.** How to wire two Pynq-Z2 v1.0 boards together for the TideLink
> chiplet bridge **without giving up** the Pmod SF3 QSPI flash on PMODA,
> the LAN8720 RMII PHY on PMODB+Arduino, or the J-Link SWD probe on the
> 2x3 SPI header — i.e. the same peripheral set as
> [nanosoc-ethernet-flash-system/fpga/targets/pynq-z2](../../../../nanosoc-ethernet-flash-system/fpga/targets/pynq-z2/nanosoc_eth_flash.xdc).
>
> Applies to targets [pynq-z2-pair-all](../targets/pynq-z2-pair-all/) and
> [pynq-z2-pair-flip-all](../targets/pynq-z2-pair-flip-all/).

## 1. The headline: do TideLink and the eth-flash peripherals fight?

**No.** The TideLink "all" XDCs ([pynq_z2_tidelink.xdc](../targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc))
already use only Raspberry-Pi-only J13 pads (Vivado RPi indices 6–23).
Cross-referencing the 18 TideLink lanes against the nanosoc-eth-flash
pin-map turns up **zero overlapping FPGA balls**. Pmod SF3 on PMODA,
LAN8720 on PMODB + Arduino-IO0, J-Link SWD on the SPI header, and the
four status LEDs are all free to plug into a running TideLink-pair board.

## 2. PYNQ-Z2 v1.0 connector pin map (FPGA balls, bank 35/13, LVCMOS33)

Source: [part0_pins.xml](file:///apps/Xilinx/Vivado/2021.1/data/boards/pynq-z2/A.0/part0_pins.xml) and
[base.xdc](https://github.com/Xilinx/PYNQ/blob/master/boards/Pynq-Z2/base/vivado/constraints/base.xdc).

| Connector | Pin → FPGA ball |
|---|---|
| PMODA | JA1=Y18 · JA2=Y19 · JA3=Y16 · JA4=Y17 · JA7=U18 · JA8=U19 · JA9=W18 · JA10=W19 |
| PMODB | JB1=W14 · JB2=Y14 · JB3=T11 · JB4=T10 · JB7=V16 · JB8=W16 · JB9=V12 · JB10=W13 |
| SPI header (J5/J6) | MISO=W15 · MOSI=T12 · SCK=H15 · SS=T16 |
| Arduino IO0 (ar[0]) | T14 |
| Status LEDs | LD0=R14 · LD1=P14 · LD2=N16 · LD3=M14 |

J13 RPi header (`raspberry_pi_tri_i_<idx>`):

| idx | ball | Aliases / notes              | idx | ball | Aliases / notes |
|----:|:----:|:-----------------------------|----:|:----:|:----------------|
| 0   | W18  | **PMODA JA9**                | 12  | V6   | — |
| 1   | W19  | **PMODA JA10**               | 13  | Y6   | — |
| 2   | Y18  | **PMODA JA1**                | 14  | B19  | — |
| 3   | Y19  | **PMODA JA2**                | 15  | U7   | — |
| 4   | U18  | **PMODA JA7**                | 16  | C20  | — |
| 5   | U19  | **PMODA JA8**                | 17  | Y8   | — |
| 6   | F19  | —                            | 18  | A20  | — |
| 7   | V10  | —                            | 19  | Y9   | — |
| 8   | V8   | —                            | 20  | U8   | — |
| 9   | W10  | —                            | 21  | W6   | — |
| 10  | B20  | —                            | 22  | Y7   | — |
| 11  | W8   | —                            | 23  | F20  | — |

Plus: J13 pins 27/28 (ID_SD/ID_SC) = `Y16/Y17` = **PMODA JA3/JA4**.

## 3. Where the conflicts are (and aren't)

- **PMODA fully overlaps J13.** All eight PMODA balls are also on J13
  (indices 0–5 + ID_SD/SC). Plus W18/W19/Y18/Y19 carry external pull-ups
  for the RPi I²C0/I²C1 buses. If PMODA is populated, these eight FPGA
  pads are *physically loaded by both* connectors — at 50 MHz the link
  edges close. TideLink's 2026-04-29 rebase off idx 0–5 was driven by
  exactly this: see [pynq_z2_tidelink.xdc:54-63](../targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc#L54-L63).
- **PMODB has zero overlap with J13, SPI, Arduino, or LEDs.** Safe.
- **SPI header has zero overlap with J13.** `T12` is *also* PMODB JB7,
  but the LAN8720 pin-map doesn't use JB7 — `T12` carries `phc_pps_out`
  to the scope, and `MOSI` on the SPI header sees the same signal, which
  is fine.
- **Arduino IO0 (`T14`)** does not collide with anything else here.
- **LEDs** are dedicated. No collision.

## 4. Wiring two boards together

Today's `pynq-z2-pair-all`/`pynq-z2-pair-flip-all` flow uses a stock
40-way RPi ribbon: same bitstream choice as before (pair-all on board A,
pair-flip-all on board B), 1:1 J13-pin↔J13-pin straight-through cable.
That ribbon ties **every** J13 pin between the two boards, including the
ones we don't want tied. Two ways to fix that:

### 4.1 Option A — keep the ribbon, cut 12 conductors

Pull-and-snip the following 12 wires from one IDC connector of the
40-way ribbon (leave the other end intact so the count can't drift):

**Power rails — 4 wires, MANDATORY:**

| J13 pin | Rail | Why cut |
|:---:|:---|:---|
| 1   | 3V3 | Two boards' regulators back-feed each other; worst case kills one. |
| 2   | 5V  | Same problem, higher current. |
| 4   | 5V  | Same. |
| 17  | 3V3 | Same. |

**PMODA-shared GPIO — 8 wires, MANDATORY if either board populates PMODA:**

| J13 pin | Ball | PMODA | Collides with (nanosoc-eth-flash) |
|:---:|:---:|:---:|:---|
| 3   | W18 | JA9  | SF3 unused (JA9 reserved) |
| 5   | W19 | JA10 | SF3 unused (JA10 reserved) |
| 7   | Y18 | JA1  | SF3 `qspi_ncs` |
| 26  | U19 | JA8  | SF3 `qspi_io[3]` |
| 27  | Y16 | JA3  | SF3 `qspi_io[1]` *(also ID_SD)* |
| 28  | Y17 | JA4  | SF3 `qspi_sclk` *(also ID_SC)* |
| 29  | Y19 | JA2  | SF3 `qspi_io[0]` |
| 31  | U18 | JA7  | SF3 `qspi_io[2]` |

You can technically leave these eight connected *today* — neither
TideLink XDC drives them, so the only fight is between the two boards'
Vivado-default pull-downs (weak, harmless). The moment anyone plugs SF3
into PMODA on either board, the QSPI bus tries to drive 100 MHz edges
into the other board's pulldown plus the ribbon's parasitic capacitance.
Cut them once and stop thinking about it.

**Total cuts: 12. Result: 28-wire effective ribbon** (18 link signals +
8 GNDs + 2 unused GPIO at pins 13 / 37).

### 4.2 Option B — per-signal jumpers (22-wire bundle)

Easier than splicing a ribbon if you want a smaller, neater build.
Wire only the 18 link signals and 4–8 GND returns. All point-to-point,
1:1 (same J13 pin number on each board, because the flip XDC handles
the TX↔RX mirroring in the bitstream).

| Wire | J13 pin | Ball | Board A (pair-all) | Board B (pair-flip-all) |
|:---:|:---:|:---:|:---|:---|
| 1  | 8  | V6  | `pad_tx[6]`  → | → `pad_rx[6]`  |
| 2  | 10 | Y6  | `pad_rx[6]`  ← | ← `pad_tx[6]`  |
| 3  | 11 | U7  | `pad_rx[0]`  ← | ← `pad_tx[0]`  |
| 4  | 12 | C20 | `pad_rx[1]`  ← | ← `pad_tx[1]`  |
| 5  | 15 | U8  | `pad_rx[4]`  ← | ← `pad_tx[4]`  |
| 6  | 16 | W6  | `pad_rx[5]`  ← | ← `pad_tx[5]`  |
| 7  | **18** | **Y7**  | **`pad_clk_rx` ←** | **← `pad_clk_tx`** |
| 8  | 19 | V8  | `pad_tx[2]`  → | → `pad_rx[2]`  |
| 9  | 21 | V10 | `pad_tx[1]`  → | → `pad_rx[1]`  |
| 10 | 22 | F20 | `pad_rx[7]`  ← | ← `pad_tx[7]`  |
| 11 | 23 | W10 | `pad_tx[3]`  → | → `pad_rx[3]`  |
| 12 | 24 | F19 | `pad_tx[0]`  → | → `pad_rx[0]`  |
| 13 | 32 | B20 | `pad_tx[4]`  → | → `pad_rx[4]`  |
| 14 | 33 | W8  | `pad_tx[5]`  → | → `pad_rx[5]`  |
| 15 | 35 | Y8  | `pad_rx[2]`  ← | ← `pad_tx[2]`  |
| 16 | 36 | B19 | `pad_tx[7]`  → | → `pad_rx[7]`  |
| 17 | 38 | A20 | `pad_rx[3]`  ← | ← `pad_tx[3]`  |
| 18 | **40** | **Y9**  | **`pad_clk_tx` →** | **→ `pad_clk_rx`** |
| GND | 9 / 14 / 25 / 39 (min) | — | GND | GND |

**Total: 18 signal + 4 GND = 22 wires.** Add more GNDs (6, 20, 30, 34
are also GND) up to 26 wires if you have spares.

**Leave open in this scheme** — don't run a wire to any of:

- J13 pins **1, 2, 4, 17** (power rails — same reason as Option A).
- J13 pins **3, 5, 7, 26, 27, 28, 29, 31** (PMODA-shared — same reason).
- J13 pins **13, 37** (W9 / unused — neither XDC drives them; leaving
  them disconnected is the easy default).

### 4.3 Signal-integrity notes (both options)

- The two clocks (`pad_clk_tx` on J13 pin 40 / `pad_clk_rx` on pin 18) sit
  at opposite ends of the header. That ~22-pin lateral skew exists today
  with the ribbon and is already absorbed by the source-sync timing
  budget; don't make it worse with a 30 cm clock loop while the data
  jumpers are 5 cm.
- For jumpers, twist each clock with its own GND wire (pin 39 with pin
  40; pin 25 or 20 with pin 18). At 50 MHz with `SLEW FAST DRIVE 8` this
  is enough — without it you'll see ringing on the recovered clock.
- If the link refuses to train (LD0 never lights) after switching cable
  scheme, suspect GND-return contention first — add the remaining GND
  wires before reaching for the ILA. This will look very different from
  the current FCSM bring-up state, which is a layer up from the PHY.

## 5. Things that do *not* need to change

- **XDC pin-maps:** untouched — both options preserve the 1:1 J13-pin
  mapping that pair-all + pair-flip-all already assume.
- **Bitstream rebuild:** not required for either cabling option.
- **Build flow / fpgahub config:** unaffected. `fpgahub pair up
  tidelink_bridge_01` still works the same way; the cabling is purely
  physical-layer.

## 6. Stale doc to retire

[pynq-z2-pair-all/ribbon_wiring.md](../targets/pynq-z2-pair-all/ribbon_wiring.md)
still shows the pre-2026-04-29 W18/Y19/etc. pin-map and the cross-strap
cable scheme. Either delete it or replace its table with the one in §4.2
of this document; the wire chart there will mis-build a cable today.
