# KR260 ↔ KR260 ribbon wiring (TideLink Pi-header link)

Applies to all four `kr260-pair-*` targets. **die_a** = `kr260-pair-{ptp,nptp}`,
**die_b** = `kr260-pair-flip-{ptp,nptp}`.

## The cable is STRAIGHT-THROUGH

Unlike the Pynq-Z2 pair, there is **no crossover**. The die_b (flip) build swaps
the TX and RX balls in its XDC, so every conductor is `BCM_n ↔ BCM_n` — exactly
one driver against one receiver on each wire. Pin 27 goes to pin 27, and so on.

> If you build both boards with the **same** target you will short two outputs
> together on every lane. Always pair a `die_a` image with a `flip` image, and
> verify with `kr260_smoke.py --expect-role …` (strap reads 0 on die_a, 1 on die_b).

## Conductors to bridge — 20 signals

`phys` = Raspberry-Pi 40-pin header physical pin number (KR260 J21).

| BCM | phys | die_a               | die_b               |
|----:|-----:|---------------------|---------------------|
|   0 |   27 | `pad_clk_tx`  →     | `pad_clk_rx`  ←     |
|   1 |   28 | `pad_tx[0]`   →     | `pad_rx[0]`   ←     |
|   9 |   21 | `pad_tx[1]`   →     | `pad_rx[1]`   ←     |
|  12 |   32 | `pad_tx[2]`   →     | `pad_rx[2]`   ←     |
|  13 |   33 | `pad_tx[3]`   →     | `pad_rx[3]`   ←     |
|   4 |    7 | `pad_tx[4]`   →     | `pad_rx[4]`   ←     |
|   5 |   29 | `pad_tx[5]`   →     | `pad_rx[5]`   ←     |
|   6 |   31 | `pad_tx[6]`   →     | `pad_rx[6]`   ←     |
|   7 |   26 | `pad_tx[7]`   →     | `pad_rx[7]`   ←     |
|   8 |   24 | `pad_clk_rx`  ←     | `pad_clk_tx`  →     |
|  16 |   36 | `pad_rx[0]`   ←     | `pad_tx[0]`   →     |
|  17 |   11 | `pad_rx[1]`   ←     | `pad_tx[1]`   →     |
|  10 |   19 | `pad_rx[2]`   ←     | `pad_tx[2]`   →     |
|  11 |   23 | `pad_rx[3]`   ←     | `pad_tx[3]`   →     |
|  14 |    8 | `pad_rx[4]`   ←     | `pad_tx[4]`   →     |
|  15 |   10 | `pad_rx[5]`   ←     | `pad_tx[5]`   →     |
|  18 |   12 | `pad_rx[6]`   ←     | `pad_tx[6]`   →     |
|  19 |   35 | `pad_rx[7]`   ←     | `pad_tx[7]`   →     |
|   2 |    3 | `i2c_sda_io` ↔      | `i2c_sda_io` ↔      |
|   3 |    5 | `i2c_scl_io` ↔      | `i2c_scl_io` ↔      |

Both forwarded clocks sit on HDGC (global-clock-capable) balls — `BCM0`/`AD15`
and `BCM8`/`AC14` — so the *received* clock lands on a clock-capable pin on both
boards with no `CLOCK_DEDICATED_ROUTE` override. They are physical pins 27 and 24,
only three apart on the header, which keeps clock-vs-data skew small.

## Ground returns

The RPi header GNDs are physical pins **6, 9, 14, 20, 25, 30, 34, 39**. Bridge at
least four (e.g. 9↔9, 14↔14, 25↔25, 39↔39). Interleaved returns matter more than
count — pin 25 sits between the BCM9/BCM11 group and pin 30 near BCM6/BCM12.

## Power — DO NOT BRIDGE

**Never** wire `+3V3` (physical pins **1, 17**) or `+5V` (physical pins **2, 4**)
through the ribbon. Each KR260 powers itself from its own barrel jack; tying two
independently-regulated supplies together can back-feed a regulator and damage
both boards. A full 40-way straight ribbon **would** bridge them — so either use a
partial loom, or physically remove/strip conductors 1, 2, 4 and 17.

Suggested cable: 26-way 28 AWG flat ribbon — covers the 20 signals + 4 GNDs with
spares, and stays narrow enough to keep the clock next to its returns.

## Bring-up order

1. Both boards **powered off**.
2. Plug the ribbon in. Confirm pin 1 orientation on *both* ends (the KR260's J21
   pin 1 is silkscreened; a reversed connector puts 5V onto BCM19).
3. Power on die_a, then die_b.
4. Deploy: `make -C fpga deploy_pair_role ROLE=die_a SOC=kr260 PTP=<0|1> …` and
   the matching `ROLE=die_b`.
5. On **each** board: `sudo TIDELINK_SOC=kr260 python3 pynq_host/scripts/kr260_smoke.py --expect-role <die_a|die_b>`
   before touching the link. It catches a swapped bitstream in one second.

## Known risks on these pins

- **`BCM0`/`BCM1` are `ID_SD`/`ID_SC`** — the Raspberry-Pi HAT-ID EEPROM pins. If
  the KR260 carrier fits pull-ups there (for HAT detection), they add load to the
  forwarded clock (`BCM0`) and lane 0. At the 3.125 MHz link rate this should be
  harmless — a push-pull `DRIVE 8` output swamps a few-kΩ pull-up — but it is the
  first thing to suspect if lane 0 or the clock looks sick while lanes 1–7 are
  clean. The Z2 hit exactly this class of problem (external pull-ups + a shared
  Pmod connector closed the eye) though at 50 MHz, 16× faster.
  **Fallback:** six other HDGC balls are free — `BCM12`(AA13), `BCM13`(AB13),
  `BCM16`(AB15), `BCM17`(AB14), `BCM9`(AC13), `BCM1`(AD14). Moving the clock pair
  to `BCM12`/`BCM16` avoids `ID_SD`/`ID_SC` entirely. It is an XDC-only change on
  both dies, plus a rebuild.
- **`BCM2`/`BCM3` are I2C1** and need pull-ups to work. Confirm the carrier fits
  them (the Pi does, ~1.8 kΩ); if not, add ~2.2 kΩ to 3V3 on one board only.
