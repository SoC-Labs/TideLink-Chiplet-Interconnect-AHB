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
