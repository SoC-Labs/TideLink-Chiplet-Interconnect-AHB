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

## 2026-08-05 — HW obs read, root cause CORRECTED, quiesce-and-burst = widen the window

The `200bce5` build was benched. `0x21F4` read **`dwell_max=256, pulsed_ever=1,
done=1, reanchored=0` on BOTH dies** — the third verdict-table row
(`pulsed_ever=1 & reanchored=0`). That row was labelled "peer needs a *contiguous*
SYNC run", but the corrected reading is sharper:

**The burst was ALREADY contiguous; it was too SHORT and not bilaterally
time-overlapped.** `app_valid` is `io_app_a2l_valid` — the *application*-layer
valid (`WlinkGenericFCSM_6.v:1121`), NOT link-layer keepalive. Through bring-up the
app port is idle (eth-chiplet ships `TXGEN_PRESENT=0`, and no D2D write is issued
until after the anchor check), so `tx_idle` held high and the FSM emitted the full
4096-cycle window with **no pause** — `done=1` confirms it ran to completion. The
"FC-keepalive fragments the burst" suspicion does not apply on this path (keepalive
raises `link_valid`, not `app_valid`). What the 4096-cycle (~164 µs) window lacked
is **bilateral time-overlap**: the proven manual recipe forces SYNC on *both* dies
for ~0.4 s *simultaneously* (`R8=0x1C` each, wait 0.4 s, `R8=0x00`), whereas each
die's auto-burst fires at its *own* link-up instant. `bringup_pair_release.sh`
releases both dies from a mutual S_HOLD barrier, so they reach `fcsm=4` within a
**ms-scale** skew — which still dwarfs a 164 µs window. The two per-die bursts never
overlapped, so neither RX ever saw the peer's SYNC run → `reanchored` stayed 0.

### Fix (this change) — widen the burst to mirror the manual pulse
`axi_chiplet_controller.sv`: `ANCHOR_LEN` 4096 → **10,000,000 cycles** (~0.4 s @25 MHz
/ ~0.2 s @50 MHz), covering the ms-scale barrier skew with >100× margin. The FSM is
otherwise **unchanged**: it keeps the TX-idle gate (Defect-A: never straddles a live
word) and the early-terminate on `ws_anchor_q`, so on a quiet link it forces SYNC for
the full window then releases — the manual pulse, automated — and stops early if the
re-anchor latches sooner. Sim keeps the short 4096 window via `` `ifdef
TB_TOP_AUTO_ANCHOR_EN `` (defined only by the cocotb auto-anchor build); silicon gets
the long one. `test_v2_auto_anchor` deliver/negctl/raceguard all PASS. A pre-existing
`SIM_BUILD`-key collision (the key omitted `AUTO_ANCHOR`, so deliver+negctl shared one
build dir and the negctl silently re-ran the beacon-ON binary → false FAIL) is fixed
in the same change.

### Next HW cycle — expected outcome
Rebuild both dies (`AUTO_ANCHOR_EN=1`), bring up, wait for the ~0.4 s burst, read
`anchorobs`:
- `pulsed_ever=1 & done=1 & reanchored=1` → the widen closed R1 autonomously (no host
  pulse). Then a sustained + reverse soak should run clean (W byte-0 stays separate —
  ILA-class).
- `done=1 & reanchored=0` → even a manual-equivalent duration via RTL doesn't latch →
  investigate the auto vs manual PHY-force path difference (the manual pulse also sets
  `swi_sync_*_r` shadows through the reg-write path; the auto burst OR-drives the same
  three PHY inputs, so this would be unexpected).
- `done=0` when read → the ~0.4 s burst is still running; re-read after ~1 s.
