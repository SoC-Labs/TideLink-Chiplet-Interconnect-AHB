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

## Mesochronous (common-clock) builds — `EXTREFCLK=1`

The `-extref` bitstreams change **two** conductors. Everything else above is unchanged.

| BCM | phys | ball | default build | `EXTREFCLK=1` build |
|----:|-----:|------|---------------|---------------------|
|  12 |   32 | AA13 (**HDGC**) | `pad_tx[2]` → `pad_rx[2]` | **`pad_refclk_in` — INPUT on BOTH boards** |
|  20 |   38 | W12 (plain)     | *unused*                  | `pad_tx[2]` → `pad_rx[2]` (relocated) |

Lane 2 moves off the clock-capable ball so the shared reference can land there — a
reference must reach a BUFG, and only HDGC balls can do that. Lane 2 on BCM20 stays
one-driver-against-one-receiver.

**BCM12 becomes the common-clock conductor**, and it is an *input on both boards*:

- **Topology (b) — external generator (use this to prove the hypothesis).** Drive a
  25 MHz clock onto the BCM12 conductor (inject at either end, or via a T). Both
  boards' `pad_refclk_in` sit on it. Neither board is special, and there is no
  source-first dependency. **No contention** — two inputs on one net.
- **Topology (a) — die_a sources it.** Build die_a with `REFCLK_OUT=1` so it drives
  `pad_refclk_out`; die_b takes `EXTREFCLK=1`. Self-contained, no lab gear.

Bridge **BCM20 as well** — 21 signal conductors instead of 20.

Frequency: 25 MHz (period 40 ns). The `/8` divider then gives the same 3.125 MHz link
rate as the default build. Change the generator and you must change `create_clock` in
`kr260_tidelink_extrefclk.xdc` **and** `kr260_tidelink_timing.xdc` together.

> The host is **not** affected: `hclk`/AXI/PHC stay on `pl_clk0`, so a board still boots
> and its registers are still reachable with no reference clock present. Only the PHY
> link domain stalls. Check `pad_refclk_in` is live *before* starting calibrator training.

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

> ### ⚠️ RETRACTED 2026-07-17 — the "26-way cannot reach the link" claim was WRONG
>
> A previous revision of this file (commit `215d10f`) carried a prominent warning that a
> 26-way ribbon could not reach `phys 27` (die_a's forwarded clock) and that this was the
> cause of the dead link. **That claim was an unverified hypothesis presented as if it had
> been measured. It is now REFUTED on hardware and must not be revived.**
>
> **The refuting measurement (2026-07-17):** with both dies beaconing SYNC, die_b read
> `0x2140 SWI_EPOCH_STATUS = anchored=1, span=18` — i.e. die_b had recovered an epoch
> anchor **on die_a's forwarded clock, the very `phys 27` conductor the theory said could
> never cross**. The conductors are fine.
>
> **CORRECTION (also 2026-07-17):** an earlier revision of this retraction went on to claim
> the real fault was that the bitstreams were deployed to the wrong boards. **That is also
> refuted** — reloading the original placement anchors fine. The KR260 epoch anchor is a
> **lottery** (measured: non-flip/die_a 1/4, flip/die_b 4/4 — matching the known
> "die_b 83% vs die_a 8%" asymmetry from the RX capture-clock defect), so single-trial A/B
> comparisons prove nothing. A success is conclusive; a failure is not. Independently
> confirmed since: all 8 balls conduct in both directions, and the ribbon has been
> continuity-tested good at the bench.
>
> **The "measured" failure signature quoted in that revision was itself an instrument
> artefact:** it rested on `sync_seen=0x00`, but `sync_seen` (`0x215C`) lives in Region 10,
> which is **RETIRED under `TIDELINK_PHY_V2` and reads 0 by construction** regardless of
> link health (`REGISTER_MAP.md`). On a V2 build, `sync_seen=0x00` is not evidence of
> anything. Use `0x2140` (epoch), `0x2120` (TX SYNC-obs) and `0x2108` (cal/fcsm) instead.
>
> Lesson worth keeping: that warning was written into the repo on speculation, and was
> then cited back by a later investigation as independent corroboration — circular
> evidence, and it nearly triggered a pointless bench trip for a replacement cable.
>
> The conductor/keep-out guidance below is unaffected and still stands.

> **If you do use a 40-way**, with conductors **1, 2, 4 and 17 removed/stripped** (see the note
> above — a full 40-way would otherwise bridge those, which must not happen). A partial
> loom is fine provided every phys pin in the conductor table is bridged.

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
