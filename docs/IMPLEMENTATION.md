# TideLink Chiplet Interconnect — Implementation Spec

The functional specification of how the TideLink subsystem's blocks actually
work: the application data path (AHB → FC adapter → Wlink → GPIO PHY → peer), the
credit / doorbell flow-control mechanics, the I²C auto-negotiation and role
arbitration protocol, the I²C-coordinated training handshake, cross-lane deskew
and lane masking inside the PHY, and the single-phase PTP timestamp path.

Companion docs: [REGISTER_MAP.md](REGISTER_MAP.md) (authoritative APB/register
addresses — this doc links, it does not duplicate),
[TIDELINK_BRINGUP_USER_GUIDE.md](TIDELINK_BRINGUP_USER_GUIDE.md) (cold-POR
bring-up procedure and pitfalls), [ASIC_TIMING_CONSTRAINTS.md](ASIC_TIMING_CONSTRAINTS.md)
(sign-off). The GPIO PHY's own training/matcher/calibrator internals are
specified separately in the `tidelink-gpio-phy` repo.

---

## 1. System overview

`tidelink_top` is a top-level chiplet subsystem that moves packets between two
chiplets across a source-synchronous 8-lane GPIO link. It wraps:

| Block | Role |
|---|---|
| `tidelink_fifo_ahb` | Credit-tracked RX FIFO with an AHB read window |
| `tidelink_fc_adapter` | Bridges the TX AHB aperture + local returner to a dedicated 48-bit FC node (`data_id=0xa1`) |
| Two `XHB500` | Generic AHB↔AXI bridges for the regular AXI-bus traffic |
| `tidelink_addr_translator` | Runtime-configurable address remap for the AXI path |
| `axi_chiplet_controller` (`deps/axi-chiplet-controller`) | Wlink (link layer, FC, CRC/ECC, GPIO PHY) + I²C sideband + autoneg FSM |

The two dies are mirror images. One acts as **master** (I²C master, role 0), the
other **slave** (I²C slave, role 1); roles are fixed by strap pin, software, or
I²C auto-negotiation (§4).

### 1.1 The four AHB ports

| Port | Role | Safety |
|---|---|---|
| `ahb_sub_*` | Regular AHB access to the remote side via XHB500 → AXI → Wlink. Address-translated. | **Safe** even with link down (HREADY returned locally). |
| `ahb_tx_*` | Direct TideLink TX aperture into the local FC node (no translation). | **WEDGE HAZARD** — an AHB_TX write with the link down hangs the PS in kernel space; requires power-cycle. Always gate behind a verified-up link. |
| `ahb_fifo_*` | Local RX FIFO read window (drain received packets). | Safe. |
| `ahb_mng_*` | AHB **manager** out of `tidelink_top`; incoming credit-return / doorbell / FC writes from the remote side, routed through XHB500. | Safe — lands in local memory. |

### 1.2 The `data_id` space

TideLink rides on Wlink's FC-node multiplex:

| `data_id` | Channel |
|---|---|
| `0x40`–`0x43` | Reserved Wlink credit-management range (`0x40` Credit-Release, `0x41` Credit-Release-Ack) — internal to Wlink FCSM |
| `0x80`–`0x84` | AXI AW/W/B/AR/R through `XHB500` |
| `0xa1` | TideLink general 48-bit FC node — the `data_id` for AHB_TX, doorbell, credit-release, FIFO data |
| `0xa2` | PTP short-packet sideband (PHC sync); short-packet variant on the wire (see §7) |
| `0xa3` | IRQ controller short-packet notifications (reserved, not yet exercised on HW) |

### 1.3 Block dataflow (master CPU → ribbon → peer)

```
 Master CPU/PS        tidelink_top              Wlink + GPIO PHY        Ribbon
 AHB_TX  ─────────►  fc_adapter (sp/lp tx) ──►  TX FCSM + LL_TX ──► pad_clk_tx
 0x4400_0000                                                         pad_tx[7:0] ──►
 DOORBELL ────────►  APB returner          ──►  (rides FC node 0xa1)
 0x44032014
 AHB_FIFO ◄───────   RX FIFO + credits     ◄──  RX demux + LL_RX ◄── pad_rx[7:0]
 (drain)                                                            pad_clk_rx ◄──
 AHB_MNG ◄────────   xhb500 mgr            ◄──  cr_pkt / crack_pkt ◄──
 APB cfg ◄───────►   regs + autoneg + i2c
 0x44030000 / 0x44032000          (peer is a mirror of the above)
```

### 1.4 ASIC vs FPGA deltas

| Topic | ASIC (v1) | FPGA (PYNQ-Z2) |
|---|---|---|
| Link rate | ~100 MHz pad clock (10 ns UI) | 25 MHz pad clock (40 ns UI) |
| PHY | GPIO PHY (`WavD2DGpio`), source-synchronous | Same GPIO PHY |
| Per-lane skew comp | Programmable delay-cell macro driven by calibrator | `IDELAYE2` per `pad_rx[n]`, gated by `USE_IDELAY=1` |
| Build knobs | `USE_IDELAY`/`USE_CLKBUF`/`USE_T3A` all `1'b0` | FPGA wrapper sets all three `=1` via `component.xml` |

**Do not delete the `USE_*` paths** — they are FPGA-essential and quarantined by
parameter, not by deletion.

---

## 2. Application data path

The application TX path is AHB → FC adapter → Wlink FCSM/LL_TX → GPIO PHY → wire.
On the peer the path mirrors: PHY → LL_RX → FC node demux → RX FIFO (drained via
`ahb_fifo_*`) or AHB MNG manager (credit/doorbell/incoming writes).

Two packet classes ride the link:

- **Long packets (FC, `data_id=0xa1`):** carry AHB_TX payload, credit-release,
  and doorbell traffic. These go through the full Wlink FC state machine (FCSM) —
  credits, replay buffer, CRC/ECC. The FC adapter packs `hwdata` into a 48-bit FC
  word. (Historical bug: a one-cycle data-phase mismatch in the adapter read
  `hwdata` after the bridge released it; the as-built adapter holds a 2-cycle data
  phase.)
- **Short packets (32-bit on wire):** carry PTP SYNC/DELAY_REQ (§7). They bypass
  the FCSM — no credits, replay, or CRC — for low-jitter, low-overhead delivery.

### 2.1 The training→data mux flip (Bug A class)

During link training the per-lane `WavD2DGpioTx` mux substitutes a training
pattern for `link_data`. When `training_mode` falls 1→0 the mux must flip at a
clean **word boundary**: a mid-word flip produces a hybrid 16-bit word (half
training pattern, half FC data) that is not a valid ECC long-packet header, so
the slave's LL_RX SOP-search misses it and byte alignment is lost asymmetrically
(slave LL_RX wedges, master is fine). The fix is a word-aligned mux transition
(local override in `src/rtl/local_overrides/WavD2DGpio.v`) sampling the mode
signal only at the `count==4'hf` word boundary. The standard `to_data_mode()`
bring-up step (drop training, then re-toggle Wlink swreset) re-initialises the
FCSM so credit exchange restarts with the now-aligned RX.

---

## 3. Flow control: credits, doorbells, FIFO

TideLink flow control is credit-based over the FC node. The RX FIFO has a fixed
credit pool; the peer may only transmit while it holds credits, and credits are
returned as the FIFO drains.

### 3.1 Credit handshake bootstrap

At link-up each side's FCSM must exchange an initial **Credit-Release (CR)**
packet (`data_id=0x40`) and its **Credit-Release-Ack (CRACK)** (`data_id=0x41`).
Until that exchange completes the credit window never opens and *all* downstream
traffic stalls — `PAIR_CREDIT_COUNTER` stays 0, doorbells do not cross, peer AHB
writes read back 0, PTP sync never advances. The proof of a healthy handshake is
`cr_pkt_seen_rx = 1` on **both** sides and `PAIR_CREDIT_COUNTER` non-zero on both
(see the bring-up verification table in
[TIDELINK_BRINGUP_USER_GUIDE.md](TIDELINK_BRINGUP_USER_GUIDE.md) §4).

### 3.2 Credit accounting registers

The credit/FIFO observability registers live in the TideLink APB block (Regions
0/1). Key ones — addresses in [REGISTER_MAP.md](REGISTER_MAP.md):

| Mechanism | Behaviour |
|---|---|
| `CURRENT_CREDITS` | Local FIFO free-credit count; near-full (e.g. 4096) at idle |
| `PAIR_CREDIT_COUNTER` | Credits held against the peer; non-zero = handshake complete; **saturates at 0** on consume underflow (guard for Bug #7) |
| `RELEASED_CREDITS_ACC` | Accumulates credits returned to peer as the FIFO drains; clear-on-read |
| `STATUS` | Sticky `fifo_overrun` / `fifo_underrun` / `master_error`; cleared by `CTRL.FLUSH` |

### 3.3 Doorbell mechanism

A **doorbell** is a lightweight peer notification: the master writes any value to
`DOORBELL`, which is carried as an FC write on `data_id=0xa1` and lands on the
peer. The peer accumulates received doorbells in `DOORBELL_RESPONSE_ACC`
(clear-on-read, saturating). A successful doorbell crossing means: master writes
N times → slave reads `DOORBELL_RESPONSE_ACC` in `[1, N]`, then it read-clears to
0. Doorbells use the safe FC path and do not carry a payload beyond the
notification.

---

## 4. I²C auto-negotiation & role arbitration

> Full spec retained in [archive/AUTONEG_PROTOCOL.md](archive/AUTONEG_PROTOCOL.md)
> — that document is the proposal-grade design with hardware-cost analysis and the
> SRAM-PUF priority source. Signal/state names below are taken verbatim from it.

### 4.1 Why it exists

Every `axi_chiplet_controller` needs one side to drive I²C as master and the
other to respond as slave. Statically, `role_effective = role_locked ?
role_cfg_reg : role_strap_i`, requiring physical differentiation of two otherwise
identical dies. Auto-negotiation lets two symmetric dies agree on opposing roles
at power-on over the **existing** I²C sideband — zero new pads.

### 4.2 The I²C-mux constraint

The I²C pin mux and core-reset gating follow `role_is_master` (`= ~role_effective`).
Both sides must therefore start with the **I²C slave active** (neither drives SCL),
and a side must be able to become master *before* `role_lock`. Because
`role_effective` ignores `role_cfg_reg` until lock, a new negotiation-phase
register `nego_role_r` is inserted as a third mux input:

```
role_effective = role_locked  ? role_cfg_reg     // post-lock
               : role_in_nego ? nego_role_r       // negotiation phase, FSM-driven
               :                role_strap_i;      // pre-nego
```

Wlink is held in reset until `role_lock` (`wlink_por_reset = ~poresetn | ~role_locked`),
so negotiation must complete and lock the role before the link can train.

### 4.3 FSM states (`tidelink_autoneg`)

| State | Description |
|---|---|
| `IDLE` | Waiting for negotiation enable |
| `NEGO_INIT` | Both cores up; I²C slave active; timers running |
| `NEGO_WAIT` | Counting down the priority-based backoff; monitoring SDA |
| `NEGO_CLAIM` | Switched to I²C master; issuing the "claim master" I²C write |
| `NEGO_POLL` | Waiting for the I²C transaction; checking ACK/NACK/arbitration |
| `NEGO_DONE` | Role decided; writes `role_cfg_reg` + `role_lock_reg` |
| `NEGO_BYPASS` | Auto-neg disabled; static-assignment path active |
| `NEGO_ERROR` | Timeout / unresolvable; role forced from `NEGO_FALLBACK` |

### 4.4 Priority backoff + tie-break

Each side computes a backoff delay before claiming:
`nego_delay = NEGO_PRIORITY × NEGO_TICK + NEGO_BASE_DELAY`. Lower priority value
= shorter delay = claims first. Priority source is selectable
(`NEGO_CFG[nego_pri_sel]`): software register, external `nego_priority_i` port
(OTP/UID), **SRAM PUF** (die-unique power-on SRAM XOR-folded to 16 bits, reusing
the TideChart PUF sampler), or hardware default `0xFFFF`.

- **Early back-off:** during `NEGO_WAIT`, if SDA goes low (peer issued an I²C
  START) before the local timer expires, the side immediately becomes slave
  (`NEGO_DONE`, `role_cfg_reg=1`).
- **Multi-master tie:** equal priorities collide → standard I²C bit-level
  arbitration on SDA resolves it; the loser releases the bus and becomes slave.
  Depends on the I²C master IP implementing arbitration-loss detection.
- **Fallback = slave** (`nego_fallback=1`, default): a stuck-slave die does not
  drive SCL, so it cannot cause bus contention. Wlink still trains (POR gates only
  on `role_locked`, not the role value).

### 4.5 Software bypass & boot integration

`nego_en=0` (reset default) → `NEGO_BYPASS`, identical to pre-feature behaviour;
firmware writes `ROLE_CFG` directly. With `nego_en=1` the FSM writes `ROLE_CFG`
and locks automatically (if `nego_force_lock=1`). Negotiation runs exactly once
per `poresetn`; renegotiation requires a full power cycle (renegotiating a trained
link would invert roles mid-flight). Register additions (`NEGO_CFG`,
`NEGO_STATUS`, `NEGO_PRIORITY`, `NEGO_TIMEOUT`) extend Region 4 — see
[REGISTER_MAP.md](REGISTER_MAP.md).

---

## 5. I²C-coordinated training handshake

> Full spec retained in [archive/i2c_train/I2C_TRAIN_PROTOCOL.md](archive/i2c_train/I2C_TRAIN_PROTOCOL.md).

Per-lane training must enter and exit on **both peers within a bounded skew**, but
the high-speed link is not yet aligned and cannot coordinate itself
(chicken-and-egg). I²C — the already-present sideband — carries the coordination.
This handshake is a sub-flow of `tidelink_autoneg`: it runs only after autoneg
reaches `NEGO_DONE` with the lane-mask handshake matched and `train_auto_en` set.
The **master** walks the `ST_TRAIN_*` states; the slave stays in `NEGO_DONE` and
reacts to its `SWI_TRAINING_MODE` register being written over I²C.

### 5.1 Sequence

The required ordering is: strap/unlock/phase set → `role_lock` (gates Wlink POR)
→ swreset+lltx toggle (starts CR generation; LL_RX recovers clock from the CR
stream) → **hold off FCSM credit advance while both sides assert training** →
per-lane calibration sweeps → both see lock → drop training → re-toggle swreset so
CR exchange completes and FCSM reaches state 4.

| State | Driver | Action |
|---|---|---|
| `ST_TRAIN_ENTER` | M | I²C-write peer's `SWI_TRAINING_MODE` bit[0]=1; local APB-write own bit[0]=1 |
| `ST_TRAIN_RUN` | both | Both per-lane calibration FSMs sweep `swi_bit_slip[lane]`; master holds `T_TRAIN_FSM` (~4096 apb_clk ≈ 41 µs) |
| `ST_TRAIN_POLL_PEER` | M | I²C-read peer's `SWI_LANE_LOCKED`, AND with own; if `0xFF` → `ST_TRAIN_EXIT`; on `T_POLL_TIMEOUT` (~16 polls) → `ST_TRAIN_FAIL` |
| `ST_TRAIN_EXIT` | M | I²C-write + local-write `SWI_TRAINING_MODE` bit[0]=0; pulse local + peer Wlink swreset to re-init FCSM → `ST_TRAIN_DONE` |
| `ST_TRAIN_DONE` | M | Terminal-OK; sticky `train_ok=1` |
| `ST_TRAIN_FAIL` | M | I²C-read peer's `SWI_LANE_FAULT`, latch local+peer faults, assert `train_fail` + `train_fail_irq` |

The training FSM **only** confirms `swi_lane_locked` and exits — it deliberately
does not watch FCSM state, so a downstream credit bug does not loop it. The deploy
script (or firmware) checks FCSM state after `train_ok` and reports a downstream
failure if it is not at state 4.

### 5.2 Recovery & timing

- **Peer I²C NACK** (peer not running / wrong slave addr): `ST_TRAIN_FAIL`, peer
  fault loaded with `0xFF` sentinel + `train_peer_nack` bit; firmware may retrain
  or fall back to bypass.
- **Peer lane fault** after timeout: master reads peer `SWI_LANE_FAULT` for
  concrete per-lane diagnostics (e.g. `0x10` = peer RX lane 4 failed → master TX
  lane 4 suspect); firmware may mask the lane via Wlink `LaneMask` and retry.
- **Re-train** on post-bring-up link drop: `ST_TRAIN_DONE → ST_TRAIN_ENTER`,
  preserving `role_lock`/`nego_won`; does not re-walk the autoneg states.
- **Timing budget:** ~2.8 ms typical (single poll), ~17 ms worst-case (16 polls) —
  well inside the firmware 5 s `role_lock` timeout. A SW-only fallback (PYNQ host
  over SSH) exists for bench debug but is ~350 ms–2 s per the SSH round-trip cost.

Training-handshake registers (`NEGO_TRAIN_CFG`, `NEGO_TRAIN_STATUS`,
`SWI_TRAINING_MODE`, `SWI_LANE_LOCKED`, `SWI_LANE_FAULT`, `SWI_BIT_SLIP_LO`) — see
[REGISTER_MAP.md](REGISTER_MAP.md) Region 8.

---

## 6. Cross-lane deskew & lane masking

> Full design retained in [archive/PHY_LANE_DESKEW_DESIGN_2026_06_03.md](archive/PHY_LANE_DESKEW_DESIGN_2026_06_03.md).

### 6.1 The problem (Bug A root cause)

`WavD2DGpio` instantiates 8 × `WavD2DGpioRx`. Each lane runs its own mod-16
counter on the shared pad clock and derives its **own** word clock
(`w_lnk_clk = ~adj_count[3]`), starting at whatever pad-clock cycle the lane's
POR/slip left it. The 8 per-lane 16-bit words are flat-concatenated and the framer
samples the 128-bit bus on **lane 0's** clock only. Because lanes start on
different pad-clock cycles, the word clocks carry persistent offsets up to ~7
word-periods, so the framer assembles 128 bits from bytes captured at different
time-points — garbage to the framer, even though the per-lane checker reports
`0xff` (each lane is correct against *its own* clock and cannot see cross-lane
skew).

### 6.2 The fix: per-lane elastic deskew FIFO

`tidelink_lane_deskew` sits between the 8 lane outputs and the assembled 128-bit
bus, inside `WavD2DGpio`. Per lane it has an independent write port on that lane's
word clock; a shared read pointer on the common `out_clk` advances **only when all
8 lanes hold a buffered word** (`all_ready = AND of (wr_ptr_sync != rd_ptr)`),
guaranteeing every output beat carries 8 words from the same time-point.

- **Mechanics:** `DEPTH=8 × WIDTH=16`, per-lane binary `wr_ptr` 2-flop-synced into
  `out_clk`, one shared `rd_ptr`. Alignment is primed once at cold start (read
  begins when the slowest lane's first word appears) and self-maintains because
  writes and reads both advance +1 per word-period at the frequency-locked rate.
- **CDC:** lane clocks and `out_clk` are frequency-locked (same pad ÷16, phase
  only). The 2-flop synchroniser sees a stable binary value; Gray code is not
  needed. (A later analysis notes the 2-flop sync costs ~2 word-periods of
  effective depth, so usable cross-lane skew ≈ `DEPTH − sync_latency − 1`; the ASIC
  ~1-word-period operating point sits well inside it.)
- **Cost:** 8×8×16 = 1024 bits storage + small pointer/control logic — negligible.

### 6.3 Lane masking

Per-lane masking already lives in the PHY: `rx_lane_en_N = rx_lane_mask[N]` zeroes
each disabled lane's word **before** concatenation (and before the deskew FIFO, so
dead lanes inject a guaranteed `0x0000`, not floating output). Deskew is placed
immediately after the mask, keeping the PHY's single responsibility: deliver a
synchronous, lane-masked, byte-aligned 128-bit bus to the link layer. The framer
interface is unchanged; only PHY internals are upgraded.

---

## 7. PTP single-phase timestamp path

> Full spec retained in [archive/PTP_PROTOCOL.md](archive/PTP_PROTOCOL.md).

`tidelink_ptp` implements a simplified IEEE-1588-style two-message sync over the
die-to-die link. A Grandmaster chiplet (typically Ethernet-connected) disciplines
a Subordinate chiplet using **hardware-timestamped** Wlink short packets — no
follow-up messages.

### 7.1 Short-packet format & messages

32 bits on the wire: `[31:24]` ECC (Hamming SEC/DED), `[23:8]` payload (seq num or
0), `[7:0]` `data_id`. The message type is the `data_id` itself:

| `data_id` | Message | Direction |
|---|---|---|
| `0x50` | SYNC | Grandmaster → Subordinate |
| `0x51` | DELAY_REQ | Subordinate → Grandmaster |

Short packets bypass the FC state machine (no credits/replay/CRC) — ~67% less
overhead than long packets, and tighter RX timing.

### 7.2 Timestamp capture

The PHC exposes a `hw_capture` input; one pulse latches the current time into the
HW_CAP register bank (SEC_HI/SEC_LO/NS/NS_FRAC). `tidelink_ptp` pulses
`hw_capture` at the short-packet TX/RX handshake on both paths.

**Idle gating for jitter-free TX timestamps:** the Wlink TX router adds variable
latency. PTP TX is held until `tx_router_idle`, then the short-packet valid is
asserted simultaneously with `hw_capture`, so t1 (GM TX) and t3 (Sub TX) are
captured with deterministic launch latency. RX timestamps (t2, t4) still include
deserialiser/link-layer jitter — a fundamental limit of capturing at the link
interface rather than the PHY.

### 7.3 Exchange & servo

```
GM:  wait tx_idle → hw_capture t1 → send SYNC(0x50) ─────►
Sub:                              hw_capture t2 ◄── receive SYNC
Sub: wait tx_idle → hw_capture t3 → send DELAY_REQ(0x51) ─────►
GM:                              hw_capture t4 ◄── receive DELAY_REQ
GM sends t1 to Sub (mailbox FIFO or AHB bridge)
Sub: offset = ((t2−t1) − (t4−t3)) / 2 ;  delay = ((t2−t1) + (t4−t3)) / 2
```

Clock discipline is a software Tier-1 servo: large offsets → step via SET_TIME;
fine tracking → steer `NS_INCR_FRAC` (PI controller). Steady-state SYNC cadence
~100 ms–1 s.

### 7.4 Hardware sync initiator

An optional FSM (`HW_SYNC_IDLE → ARMED → FIRE → WAIT_TX`) autonomously fires SYNC
at a configured interval without CPU intervention, comparing PHC `{seconds, ns}`
against a target that advances each fire, auto-incrementing a 16-bit seq num.
Software AHB writes have priority on the shared TX path; the initiator retries if
pre-empted. Interval is set in ns via `HW_SYNC_INTERVAL` (default ~1 Hz).

**Limitations:** RX-side jitter is not gated; single HW_CAP bank (a second capture
before SW reads overwrites the first); corrupted short packets are silently
dropped (a missed SYNC just skips one interval); point-to-point single Subordinate
only. PTP registers (`PTP_CTRL`/`PTP_RX_PAYLOAD`/`PTP_STATUS`,
`HW_SYNC_CTRL`/`HW_SYNC_INTERVAL`/`HW_SYNC_STATUS`, PHC HW_CAP) — see
[REGISTER_MAP.md](REGISTER_MAP.md).

---

## 8. Bring-up & verification at a glance

Cold-POR to traffic, in order (full procedure + pitfalls in
[TIDELINK_BRINGUP_USER_GUIDE.md](TIDELINK_BRINGUP_USER_GUIDE.md)):

1. Assign role (strap / SW / I²C autoneg §4) and write `role_lock` → Wlink POR
   deasserts, calibrator sweeps per-lane (slip × phase).
2. Confirm `lane_locked = 0xff` + `cal_done = 1` both sides (`SWI_LANE_STATUS`).
3. **`to_data_mode()`** — drop `SWI_TRAINING_MODE`, then the Wlink swreset
   bootstrap. This is the load-bearing step; skipping it leaves the link emitting
   the training pattern and the CR packet never drains (§2.1, §5.1).
4. Confirm credit handshake: `cr_pkt_seen_rx = 1` + `PAIR_CREDIT_COUNTER` non-zero
   both sides (§3.1).
5. Application checks: AHB SUB peer-visibility, doorbell crossing, PTP HW sync.

The HW test suite (`pynq_host/scripts/hwtest/`) groups these into 13 categories
(Wlink layer, TideLink regs, AHB SUB/MNG/TX/FIFO, address translation, PTP basic +
HW sync, servo/mailbox, perf counters, chiplet-ext, long soak), each gated so a
wedge-class write (AHB_TX) cannot proceed without a verified-up link. Functional
intent of each category is described in
[archive/HW_TEST_SUITE.md](archive/HW_TEST_SUITE.md).

---

## Sources

The following source documents were folded into this spec and moved to
`docs/archive/`. They are **retained for depth, not maintained** — this
IMPLEMENTATION.md (plus [REGISTER_MAP.md](REGISTER_MAP.md) for addresses) is the
living functional reference; consult the archives only for the original
deep-dive detail.

- [archive/TIDELINK_BRINGUP_USER_GUIDE.md](archive/TIDELINK_BRINGUP_USER_GUIDE.md)
  — canonical cold-POR bring-up sequence, the four AHB ports, APB sequences,
  flow-control / doorbell mechanics, pitfalls.
- [archive/AUTONEG_PROTOCOL.md](archive/AUTONEG_PROTOCOL.md) — I²C
  auto-negotiation / role arbitration FSM, priority sources, SRAM-PUF, hardware
  cost analysis.
- [archive/PTP_PROTOCOL.md](archive/PTP_PROTOCOL.md) — single-phase PTP,
  SYNC/DELAY_REQ, hardware timestamp capture, HW sync initiator, servo.
- [archive/i2c_train/I2C_TRAIN_PROTOCOL.md](archive/i2c_train/I2C_TRAIN_PROTOCOL.md)
  — I²C-coordinated training entry/exit handshake, recovery, timing budget.
- [archive/PHY_LANE_DESKEW_DESIGN_2026_06_03.md](archive/PHY_LANE_DESKEW_DESIGN_2026_06_03.md)
  — cross-lane skew root cause + elastic deskew FIFO design.
- [archive/HW_TEST_SUITE.md](archive/HW_TEST_SUITE.md) — HW test orchestrator
  design (referenced here only for the functional description of what the link
  does, not the test infrastructure).
