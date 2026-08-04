# AUTO_ANCHOR — HW non-fire diagnosis, obs instrument, and pause-accumulate fix (2026-08-04)

Branch: `integ/axirec-on-chiplet` (origin = GitHub `SoC-Labs/TideLink-Chiplet-Interconnect-AHB`)
HEAD at time of writing: `200bce5`.

## Where things stand

The AXI data-node **error-recovery LOGIC is resolved and verified**: header-ECC
restore (`1aaed00`), synth-B OKAY backstop, Fix-G/H, F-1 — with sim tests
`gaps_ecc` 6/6 and the recoverable-wedge suite. That is the deliverable the
eth-chiplet integrators pick up.

Two straggler items are **HW-observability-gated**, not logic bugs:

1. **AUTO_ANCHOR did not latch `reanchored` on HW** (this doc).
2. **W byte-0 intermittent wedge** — characterised as a physical/marginal-eye
   lottery (wedges even with `reanchored` forced to 1); needs an ILA campaign,
   not an AXI-logic change. Auto-anchor is **orthogonal** to it.

## AUTO_ANCHOR: sim-proven, didn't fire on the eth-chiplet HW

The controller AUTO_ANCHOR FSM pulses the SYNC beacon once at link-up so the
shipping SYNC-reanchor deskew corrector arms on the `nego_en=0`/SELF_ARM path.
Sim: 3/3 (`test_v2_auto_anchor`). HW @`1dfa313` (both dies, `AUTO_ANCHOR_EN=1`):
bring-up clean (fcsm=4) but `reanchored` (EPOCH_STATUS 0x2140 bit0) stayed **0**
on both dies, and W byte-0 still wedged 2/10.

### Static diagnosis (this session)

- **REFUTED — the `ws_anchor_q` early-out.** `ws_anchor_q` is the 2-flop CDC
  sync of the deskew `reanchored` latch itself (the *same* net as EPOCH_STATUS
  0x2140 bit0). On HW `reanchored=0`, so `ws_anchor_q=0`, so the FSM's
  `if (ws_anchor_q) done` branch never fires. Not the cause.

- **LEADING SUSPECT — the TX-idle gate starves on a busy link.** The FSM
  required `ANCHOR_DWELL`(256) + `ANCHOR_LEN`(4096) **consecutive** tx-idle
  cycles (`~sync_obs_a2l_app_v_1`), resetting the dwell to 0 on *any*
  app->link-valid blip. `sync_obs_a2l_app_v_1` is the apb_clk sync of Wlink's
  `obs_a2l_replay_app_valid` (the app->link replay-FIFO valid). If FC keepalive/
  sideband toggles that more often than every 256 cycles, `len` can never
  advance and the beacon never emits — `reanchored` stays 0.

## Two things landed to close this out

### 1. Instrument — AUTO_ANCHOR_OBS at 0x4403_21F4 (`90072ba`)

A self-contained Region-F slot-5 obs word so the **next HW cycle is conclusive
in one APB read** instead of another blind rebuild:

| bits    | field         | meaning                                          |
|---------|---------------|--------------------------------------------------|
| [15:0]  | `dwell_max`   | longest tx-idle streak reached                   |
| [16]    | `pulsed_ever` | a SYNC beacon DID emit                            |
| [17]    | `done`        | FSM completed                                     |
| [18]    | `pulse`       | beacon emitting right now (live)                 |
| [19]    | `link_up`     | FCSM in 4..7 (live)                              |
| [20]    | `tx_idle`     | `~a2l_app_v` right now (live)                    |
| [21]    | `reanchored`  | CDC'd deskew re-anchor latch                     |
| [22]    | `training`    | `swi_training_mode_r`                            |
| [23]    | `AUTO_ANCHOR_EN` | build flag (confirms the param reached synth) |

Verdict table (also printed by `eth_tlapb_poke.py anchorobs`):

- `dwell_max << 256` & `pulsed_ever=0` -> keepalive keeps resetting the dwell =
  **gate too strict** (the leading suspect; the pause-accumulate fix targets it).
- `dwell_max=256` but `pulsed_ever=0` -> emit blocked between dwell and burst.
- `pulsed_ever=1` but `reanchored=0` -> beacon emitted, **PHY/peer didn't latch**
  (would mean the peer needs a *contiguous* SYNC run -> a quiesce-and-burst
  approach, not accumulation).
- `pulsed_ever=1` & `reanchored=1` -> auto-anchor worked.

Instrument verified in sim: the delivers test reads 0x21F4 and asserts
`pulsed_ever=1, dwell_max>=256, EN=1` (`raw=0x00bb0100`, bit21 reanchored=1).
`AUTO_ANCHOR_EN=0` folds every field to 0 (0x21F4 read unchanged = 0).

### 2. Fix — pause-accumulate (`200bce5`)

The FSM now, on app-active with the link still UP, **PAUSES** (deasserts the
pulse — never straddles a live word, so Defect-A safety is unchanged) and
**HOLDS** dwell+len so the beacon accumulates to completion across idle windows.
It resets the dwell only on a genuine link-drop. Sim: 3/3 still PASS (safety +
no-regression). This idle-link tb cannot faithfully model a sub-256-cycle
keepalive stream (RX-FIFO overflow), so the busy-link *benefit* is proven on HW
via the obs word, not in sim.

## Next HW cycle (one decision for David)

Rebuild both eth-chiplet dies from `200bce5` (`AUTO_ANCHOR_EN=1`, ~3h) and run
`pynq_host/scripts/kr260_eth_ecc_hwverify.sh` — new step **[0b]** reads
`anchorobs` on both dies right after bring-up. Two outcomes:

- `pulsed_ever=1 & reanchored=1` -> pause-accumulate fixed the starvation; R1/
  deskew closed. (W byte-0 is separate — still needs an ILA campaign.)
- `pulsed_ever=1 & reanchored=0` -> the peer needs a contiguous SYNC run; switch
  to a quiesce-and-burst (hold off app traffic during the 4096-cycle burst).
- `dwell_max` still tiny -> deeper issue (training never drops / obs miswired) —
  the obs word's `training`/`link_up`/`tx_idle` live bits localise it.

Because the diagnostic-only value competes with a contended board + 3h build,
and the fix it validates is orthogonal to the W byte-0 symptom, this rebuild is
best **batched** with the next real RTL change rather than spent standalone.

---

## HW RESULT (2026-08-04, kr260_01/02, both dies @d98b58d)

Ran the full flow: POR both → deploy both `d98b58d` bitstreams → bring up
(FCSM=4 both, on retry — first attempt was a bring-up lottery miss) →
`kr260_eth_ecc_hwverify.sh`. The 0x21F4 obs instrument gave a **decisive**
verdict.

**0x21F4 = 0x009b0100 on BOTH dies** → `AUTO_ANCHOR_EN=1, dwell_max=256,
pulsed_ever=1, done=1, reanchored=0`:

- The **FSM fires and completes on HW** — `dwell_max` reached the full
  ANCHOR_DWELL(256) and a beacon emitted (`pulsed_ever=1`). **Pause-accumulate
  works; the keepalive-starvation theory is REFUTED.**
- But `reanchored=0` → *beacon emitted, peer didn't latch* (the doc's 3rd branch).

**Decisive manual-pulse experiment** (host R8=0x1C held 0.4s, ~2400× the
164 µs auto burst):

| beacon source | peer that should re-anchor | result |
|---------------|----------------------------|--------|
| die_a (0.4s)  | die_b RX (slave)           | **reanchored = 1 (LATCHED)** |
| die_b (0.4s)  | die_a RX (master)          | reanchored = 0 |
| die_b (2.0s)  | die_a RX (master)          | reanchored = 0 (still) |

**Two distinct findings:**

1. **ANCHOR_LEN (4096 ≈ 164 µs) is too short.** The slave RX (die_b) re-anchors
   only on a ~0.4s beacon, so the auto-anchor's 164 µs burst never latches it.
   → **Fix A: raise ANCHOR_LEN substantially** (toward ~0.4s-equivalent, ~10⁴–10⁵
   apb_clk cycles). Cheap RTL change; fixes the a→b direction.
2. **die_a (master) RX won't re-anchor at all — even with a 2s beacon.** This is
   the pre-existing **M-vs-S asymmetry** (see the concurrent-drain notes:
   "bidir mismatches dropped m→s only"; die_a's RX never locks). It is **not**
   fixable by beacon duration — it needs a separate master-side RX / deskew
   root-cause. **This is the real remaining R1/deskew blocker.**

R1 data-delivery FAIL and the AW-inject die_a wedge are both **downstream of
die_a `reanchored=0`** (a mis-framed master RX), not independent AXI-logic
failures. (0x2124 SYNC-detect read count=0 on both dies incl. the reanchored
die_b, so it did not distinguish physical-vs-logic — not over-read.)

**Net:** the auto-anchor + pause-accumulate is validated as *firing correctly*
on silicon; closing R1/deskew now needs **(A)** a longer ANCHOR_LEN **and (B)** a
separate root-cause of the master-side RX re-anchor asymmetry. The AXI
data-node recovery *logic* (ECC restore + synth-B OKAY + Fix-G/H + F-1) remains
resolved and is unaffected by any of this.
