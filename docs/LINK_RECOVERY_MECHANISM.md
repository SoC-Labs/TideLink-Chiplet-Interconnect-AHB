# TideLink — Link Recovery Mechanism: what actually un-wedges a wedged link

**Date:** 2026-07-18 · **Lane:** Z-D (F14-B follow-up)
**Bench:** `cocotb/tidelink_error_injection/` — `recovery_common.py`,
`test_ei_recovery_ladder.py`, `test_ei_beacon_recovery.py`,
`test_ei_beacon_dose.py` (all new, this lane; no shared RTL touched)
**Config:** V2 (`TIDELINK_PHY_V2=1`), `EPOCH_PROFILE=zero`, VCS, SW bring-up
(`BYPASS_AUTONEG=1`)

Follows `docs/ERROR_INJECTION_FINDINGS.md` §F14-B, whose stated limitation was
that its recovery ladder's last rung (full POR of both dies) **also re-runs
autocal**, so it could not separate *"the power/reset domain had to be cycled"*
from *"the PHY merely had to retrain"*.

---

## 1. Headline

**"Any transient data-mode disturbance wedges the link" is too strong. Two of
the three disturbances tested are TRANSIENT and clear themselves with no
intervention at all; one is a genuine hard wedge that nothing below a both-die
POR recovers.**

| Wedge cause | Minimal recovery | Field-recoverable? |
|---|---|---|
| **W4** lane-2 **stuck-1** (silicon-meaningful single-lane fault) | **none — self-heals after ~1 retry round** | yes (nothing to do) |
| **W1** all-lane corruption | **none — self-heals after ~3 retry rounds** | yes (nothing to do) |
| **W2** link-clock dropout | **POR of BOTH dies** | **NO — power cycle** |

And, separately from any wedge: **there is no firmware-reachable PHY retrain in
this design at all.** `SWI_RECAL` is a measured no-op after first lock (§4).
That is the gap that makes W2 unrecoverable, and it is a one-bit RTL fix (§6.1).

**Three of this lane's own intermediate claims were refuted by its own later
controls, and the refutations are the most useful output here** — a beacon-based
"firmware recovery procedure" looked real twice and was wrong both times (§3).

---

## 2. Results

### 2.1 The ladder

Rungs, cheapest first. `firmware-reachable` = a deployed chiplet can do this to
itself over APB, with no operator and no reset line.

| Rung | Action | FW-reachable |
|---|---|---|
| 0 | no action (just re-probe) | — |
| a | `SWI_RECAL` pulse alone (R8[1]) | yes (but a **no-op**, §4) |
| b1/b2/b3 | SYNC beacon burst, R8 = 0x04 / 0x0C / 0x1C | yes |
| b4 | R8=0x1C with `SWI_SYNC_TOL`=5 opened first (0x2128) | yes |
| c/d | LL swreset (0x208[3]) one die / both dies | yes |
| e | full PHY retrain, **no POR** (train → recal → re-enter data) | yes |
| f | POR one die + SW re-bring-up | no |
| g | POR **both** dies + full bring-up (= power cycle) | no |

Measured, all cells using the **drained/tagged** health check (§3.1). `·` = rung
not reached; `✗` = still wedged; `✓` = byte-exact **both** directions.

| Rung | W1 all-lane corruption | W2 clock dropout | W4 lane stuck-1 | W3 lane stuck-X † |
|---|---|---|---|---|
| 0 no action | ✗ | ✗ | ✗ | ✗ |
| a recal-only | ✗ | ✗ | **✓** | ✗ |
| b1 beacon 0x04 | ✗ | ✗ | · | ✗ |
| b2 beacon 0x0C | **✓** | ✗ ⚠ | · | ✗ |
| b3 / b4 | · | ✗ / ✗ | · | ✗ / ✗ |
| c / d LL swreset | · | ✗ / ✗ | · | ✗ / ✗ |
| e PHY retrain, no POR | · | ✗ | · | ✗ |
| f POR one die | · | ✗ | · | ✗ |
| g **POR both dies** | · | **✓** | · | **✓** |

**Read the W1 and W4 "✓" cells as elapsed retry rounds, not as the named
action** — see §3, where both are shown non-causal. W2 is the real result: it
survived ten rungs, each carrying its own probe round, plus the beacon at three
strengths, the tolerance-opened beacon, LL swresets on either and both dies, a
full PHY retrain, and a single-die POR.

† **W3 (lane-2 stuck-X) carries no weight and must not be quoted as a silicon
result.** Stuck-X is a **simulation** fault model — silicon has no X; a real
broken lane sits at a level or is marginal. X propagates into the APB readback,
so every observable reads X (-1) and the wedge cannot clear without a reset that
flushes the X. Its "POR both dies" cell therefore describes VCS X-pessimism, not
the part. It is shown only for completeness against Y-C's S3c. **W4 (stuck-1) is
its silicon-meaningful replacement**, and W4 behaves completely differently —
it self-heals immediately.

### 2.2 ⚠ The beacon can destroy a working direction

In W2, rungs 0/a/b1 show `m2s=True` — the m→s direction was still healthy. From
rung b2 (the first burst with `SWI_SYNC_FORCE_ALWAYS`) onward it reads
`m2s=False` and never returns until the POR. **The forced beacon killed the half
of the link that still worked.** With the idle gate dropped, SYNC beats over
live payload; this is the known word-deleter behaviour and it is why the
inserter is idle-gated by default. Any routine that fires a forced beacon at a
half-wedged link risks converting a one-way failure into a two-way one.

---

## 3. What refuted the beacon story (methodology)

The natural reading of F14-B is: the SYNC beacon is off in data mode, so a
framing slip has no re-anchor; supply a beacon and the link should come back.
Two independent measurements appeared to confirm this. Both were wrong.

**False positive 1 — a stale RX-FIFO word.** The first ladder run reported W1
recovering at rung b2. `errinj_common.link_healthy` sends the *same fixed
payloads* on every call, so a word left in the RX FIFO by an earlier call is
re-read and scored as a fresh delivery — exactly the confound Y-C flagged at
`ERROR_INJECTION_FINDINGS.md` §2.3, here biting a *ladder* rather than a lane
sweep, where it is worse: one stale word stops the walk early and invents a
cheaper minimal recovery than the truth. Fixed by
`recovery_common.link_healthy_tagged` (drain both RX FIFOs, then send a payload
carrying a tag unique to that call). **Every cell in §2.1 uses it.**

**False positive 2 — elapsed retry rounds.** With the tagged check the ladder
*still* reported W1 recovering at b2. But a single 0x0C burst applied to a fresh
wedge did **not** recover it (`test_20`), so b2 could not be sufficient. The
dose/control pair settled it:

| | recovered after |
|---|---|
| `test_30` — repeated 0x0C beacon bursts | **3 bursts** |
| `test_31` — matched dwell + matched probe count, **zero register writes** | **3 waits** |

**Identical count, and the control issued no beacon at all.** The recovery is
elapsed time and the probe traffic itself, not the beacon. `test_31` is written
to fail loudly in exactly this case, and it did.

So the W1 and W4 "✓" cells in §2.1 are the link **self-healing**: W4 after ~1
probe round, W1 after ~3 (≈24k hclk plus three rounds of bidirectional packets).
This is consistent with the FC layer's own recovery machinery — the a2l replay
FIFO and the F-1 NACK watchdog, whose `SOCL_L7_WDOG_THRESHOLD = 16'h4000`
(`WlinkGenericFCSM_6.v:179`) pulls a stuck state-7 back to 4 after 16384 cycles.
The corruption classes are **transient**, not wedges.

**W4's "recovery at rung a" is the cleanest proof of the whole argument.** Rung
a is `SWI_RECAL`, independently measured in §4 to do *nothing* to the
calibrator. An action that provably does nothing cannot be a recovery, so that
cell can only be the probe round — which is precisely how the W1 b2 cell should
be read too.

### 3.1 Consequence for anyone extending this bench

1. Use `link_healthy_tagged`, never `link_healthy`, for any recovery claim.
2. A sequential ladder cannot establish causality. Every "rung X recovered it"
   needs an isolation run (that rung alone) **and** a matched-time control with
   the same probe count and no writes. `test_21` was a weaker control that
   matched only *one* rung's dwell and consequently passed while being unable to
   detect the effect that actually mattered; `test_31` is the honest one.

---

## 4. There is no firmware-reachable PHY retrain

`tidelink_phy_align_calibrator.sv:606-618`:

```systemverilog
reg calibrated_once_q;
always_ff @(posedge clk or posedge rst) begin
    if (rst)                      calibrated_once_q <= 1'b0;
    else if (cur_state == S_DONE) calibrated_once_q <= 1'b1;
end
wire role_locked_rise_eff = role_locked_rise & ~calibrated_once_q;
wire swreset_fall_eff     = swreset_fall     & ~calibrated_once_q;
assign trigger_now = role_locked_rise_eff | (swreset_fall_eff & role_locked_sync);
```

Once the sweep reaches `S_DONE` once, **both** re-trigger edges are gated off
forever and only `rst` (POR) clears the sticky. `SWI_RECAL` (R8[1]) is the only
SW path to that `swreset`.

**Measured, not inferred** (`test_23`, on a healthy link): after the RECAL
falling edge, the calibrator FSM was sampled 60 times across the window in which
`S_DONE → S_ARM` would appear, on both dies. It **never left `S_DONE`**.

This is not a bug — it is a deliberate fix for a real one (the autoneg winner's
spurious training-exit recal pulse re-entered training mid-handshake and wedged
the master FCSM at state 2 with zero TX credit). But it closed the only SW path
to a PHY retrain along with it, and the RTL comment says so out loud: *"if
production SW needs an explicit forced recal of an already-locked link, it should
issue it via a POR or a dedicated W1P"*. **No such W1P exists.** The affected
calibrator is the flist-selected `deps/tidelink-phy` copy — the built FPGA image
**and the ASIC path**.

This is why rung (e) cannot work either: it drives training mode and re-enters
data mode, but the sweep that would re-derive per-lane slip/phase never runs, so
the PHY returns with exactly the alignment it was wedged with.

### 4.1 The beacon reaches the wire and still does not fix W2

Worth recording because it rules out the simplest theory. During the W2 beacon
rungs the transmitting die's `tx_sync_ins_cnt` (0x2120) climbed and the
receiving die's `sync_seen` (0x2124) reached `0x5dff003b` — **all 8 lanes
matching** — with EPOCH (0x2140) showing `reanchored=1`. The PHY re-anchored and
the link still carried no data. Restoring the missing delimiter is **not
sufficient** for a clock dropout.

Two corollaries:
* An RTL proposal to "arm the deskew re-anchor" would be a **no-op**: it is
  already armed. `ERROR_INJECTION_FINDINGS.md` §F14-B cites
  `tidelink_lane_deskew_v2.sv:201` (`SYNC_REANCHOR_EN` default `1'b0`), but that
  is the *module default* — the built PHY overrides it at
  `WavD2DGpio_v2.v:790` with `.SYNC_REANCHOR_EN(1'b1)`, `.SYNC_REANCHOR_TOL(5)`.
* The framer's re-hunt boundary gate (`WlinkRxLinkLayer.v:393`,
  `sync_resync & (state != 2'h1)`) was the obvious suspect and is **measured
  innocent**: `llrx.state` reads **0 (hunt) in all 13 rung samples** of W1 and
  W2, never 1. Do not change it — that would re-open the mid-packet-abort
  silent-corruption class its 2026-07-03 fix closed.

The residual reason a re-anchored receiver still passes no data after a clock
dropout is **not identified by this lane**. It is the open question.

---

## 5. Wedge detection — the liveness recipe

Y-C found `fcsm` reads a healthy `4` on both dies while no data crosses. This
lane sampled every other APB-reachable candidate in the healthy and wedged
states and diffed them (`liveness_snapshot` / `diff_liveness`).

| Observable | APB | Healthy | Wedged | Discriminates? |
|---|---|---|---|---|
| `fcsm` state | (hier) | 4 | **4** | **NO — reads healthy** |
| `cal_done`, `cr`, `crack` | 0x2108 | 1, 1, 1 | **1, 1, 1** | **NO** |
| `llrx` framer state | (hier) | 0 | **0** | **NO** |
| EPOCH (`reanchored`/span) | 0x2140 | 0x00000000 | **0x00000000** | **NO** |
| TX SYNC-insert count | 0x2120 | 0x5c010000 | **0x5c010000** | **NO** (beacon off in data mode ⇒ flat by construction) |
| RX SYNC-detect count | 0x2124 | 0x5d000000 | **0x5d000000** | **NO** (same reason) |
| `crc_errors` / `io_rx_crc_err` | (hier) | 0 | **0** | **NO** (consistent with F14-A) |
| **a2l replay backlog** (`wptr − synced_ack`) | (hier `io_obs_*`) | **1** | **9 … 16** | **YES, while traffic flows** |

**Only the a2l replay backlog moved.** Healthy steady state is `outstanding ==
1` — one emitted-but-unACKed slot is normal, not a stall. (The first version of
this check used `> 0` and false-flagged the healthy die on every line of the
first run; the threshold is quoted from measurement, not chosen.)

**The backlog is necessary but not sufficient.** In `test_20`, after a beacon
burst the pointers re-converged to `out=1` on both dies **while s→m data was
still broken** — a backlog-only detector would have called that link alive. The
backlog fires while the TX is still pushing; once the FC layer quiesces it looks
healthy again.

### 5.1 The recipe (deliverable)

`recovery_common.is_link_alive()` — two stages, **stage 2 is not optional**:

1. **Cheap, non-intrusive:** read the a2l backlog on both dies. `> 2`
   outstanding ⇒ **declare wedged**, no further test needed. Fires early and
   under load.
2. **Definitive:** a **tagged data canary** — drain the RX FIFO, then send a
   packet whose payload carries a value never previously sent, in **each**
   direction, and require byte-exact receipt.

**Do not use** `fcsm`, `cal_done`, `cr`/`crack`, `llrx`, EPOCH, or the SYNC
counters: all measured identical across healthy and wedged. Also excluded:
`0x2144` (live-match) saturates and lies, and `0x215C` `sync_seen` is retired in
V2 and reads 0 by construction.

**For the hardware sessions: the canary IS the check.** There is no register you
can poll instead. Every "the link is up, fcsm=4" report on a V2 build is
unfounded unless a uniquely-tagged packet crossed and was compared.

**Corollary for retry policy:** because W1/W4 self-heal over ~1–3 probe rounds,
a liveness check must **re-probe a few times before declaring a wedge**. A
single failed canary is not a wedge — that is precisely the error that made this
lane's early results look like permanent wedges.

---

## 6. Verdict and tapeout implication

**Per cause:**
* **Transient corruption (single-lane stuck-1, all-lane corruption): the link
  recovers itself.** No firmware action is needed or helps. This materially
  softens F14-B for these classes.
* **Link-clock dropout: NOT field-recoverable. Power cycle only.** Every
  firmware-reachable rung was tried and failed.

**Tapeout implication.** For the clock-dropout class, a deployed chiplet has no
way back. On an FPGA that is a `fpgahub power-cycle`; on a deployed part it is a
truck roll. The reason is not that recovery is impossible — it is that the one
mechanism that would retrain the PHY is gated off by `calibrated_once_q` (§4)
with no alternative entry point. **That is a one-bit fix and it should be made
before tapeout**, because after tapeout it is unfixable forever.

### 6.1 RTL proposals — PROPOSALS ONLY, NOT APPLIED

**P1 — a dedicated forced-recal W1P.** Add a write-1-pulse bit (e.g. R8 slot0
bit[6], `SWI_FORCE_RECAL`) ORing into the calibrator trigger and **bypassing**
`calibrated_once_q`, leaving the level `SWI_RECAL` path gated exactly as today.
This is the remedy the calibrator's own comment proposes. Additive, POR-default
0, bit-identical until written — the safest shape for a pre-tapeout change.
**Caveat, stated plainly: this lane did not demonstrate that a forced recal
recovers W2.** It could not — the mechanism to test it does not exist in the
RTL. P1 buys firmware *a lever it currently does not have*; whether that lever
clears a clock-dropout wedge is the first thing to measure once it exists.

**P2 — qualify the sticky instead** (`calibrated_once_q & (cr_pkt_seen_i |
crack_pkt_seen_i)`, also from the RTL comment). Cheaper in bits, but it changes
existing behaviour rather than adding a new door, so the autoneg-wedge
regression must be re-run.

**P3 — do NOT "arm the re-anchor"** (already armed, §4.1) and **P4 — do NOT
touch the state-1 re-hunt gate** (measured innocent, §4.1).

**P5 — no beacon-based recovery routine should be written.** It was the hoped-for
deliverable and the evidence is against it: the beacon is non-causal for the
classes that recover (§3) and actively **harmful** to a healthy direction (§2.2).

---

## 7. How to re-run

```bash
source ./set_env.sh && export TIDELINK_PHY_V2=1
cd cocotb/tidelink_error_injection
make SIM_BUILD=sim_build_zd MODULE=test_ei_recovery_ladder   # the matrix (§2.1)
make SIM_BUILD=sim_build_zd MODULE=test_ei_beacon_recovery   # isolation + the recal no-op (§4)
make SIM_BUILD=sim_build_zd MODULE=test_ei_beacon_dose       # dose vs time (§3)
```

Use a **private `SIM_BUILD`** — other lanes share this directory and
`sim_build_ei`.

Failure policy differs from Y-C's deliberately: these files **assert their
causal claims**, so if behaviour changes such that a claim here stops holding,
the test goes red with a message naming the paragraph to withdraw. Two tests are
**expected red** against their own assertion text, and that is the finding:
`test_20` ("prove b2 works in isolation" — it does not) and `test_31` ("the
control must not recover" — it did, at the same count as the dose arm). Read the
assertion message, not just the colour.

## 8. Limitations

1. **Sim only.** No silicon confirmation of any rung. One injection point
   (post-skid, pre-RX) modelling a wire/eye fault, not a TX-side logic fault.
2. **`clk_kill` holds the clock low**; no jitter or partial-edge model. The W2
   verdict is for a hard dropout.
3. **W3 (stuck-X) is a sim-only artefact** (§2.1) and its POR-only result is
   X-propagation, not behaviour. W1/W4 stopped early by self-healing, so the
   rungs below their stopping point are unexercised for those causes — the
   matrix does not show, e.g., whether an LL swreset would have helped W1.
4. **n=1 per cell.** Given that this lane's own headline flipped twice on
   controls, the self-healing round counts (~1 for W4, ~3 for W1) should be
   treated as order-of-magnitude, not thresholds. They will also move with
   `EPOCH_PROFILE` and link rate.
5. **`EPOCH_PROFILE=zero` only** — no skew combined with the faults.
6. **The W2 residual mechanism is unidentified** (§4.1) — the re-anchor engages
   and data still does not flow. That is the most valuable thing left to chase.
