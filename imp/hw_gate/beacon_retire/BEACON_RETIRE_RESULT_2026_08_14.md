# Unilateral beacon-retire hypothesis — **REFUTED** (outcome 2)

Date: 2026-08-14
Tree: `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink`
Branch: `integ/tidelink-consolidated-2026-08-07`, HEAD `7701335`
Method: adversarial static RTL read against `HEAD` + paired-die cocotb simulation.
**No hardware was touched. Nothing was committed. No file outside
`imp/hw_gate/beacon_retire/` and the one new test file was modified.**

New files:
- `imp/hw_gate/beacon_retire/BEACON_RETIRE_RESULT_2026_08_14.md` (this)
- `cocotb/tidelink_top_pair_v2/test_v2_beacon_retire_starve.py` (new test, untracked)

> **Line-number convention.** The working tree differs from `HEAD` by exactly one
> 68-line insertion at `axi_chiplet_controller.sv:2099` (the 2026-08-12 ILA
> `mark_debug` alias block; `git diff -U0` shows the single hunk
> `@@ -2098,0 +2099,68 @@`). **Every `axi_chiplet_controller.sv:NNNN` citation below
> is a `HEAD` line number.** Worktree = HEAD + 68 for any line > 2098. The
> hypothesis document's `:4931` is a worktree number; the same statement is
> `HEAD :4862-4866` / `:4878-4882`.

---

## Verdict

**Outcome 2 — REFUTED, with a mechanism.**

The hypothesis has three clauses. Clause 1 is **correct**. Clause 2 is **false**,
and it is false in a way that kills the whole chain. Clause 3 is **false** for a
second, independent reason. The back half of the causal story (beacon absence →
peer never anchors → all-zeros) is **CONFIRMED in simulation** and reproduces the
measured hardware signature exactly — but the retire is not what removes the
beacon, and on the campaign vehicle it cannot fire at all.

| Clause | Status |
|---|---|
| Branch 2 has no peer-**anchored** term | **TRUE** (verified `HEAD :4862-4866`) |
| Branch 2 is the path taken in the shipping configuration | **FALSE** — `nego_en = 0` on the eth-chiplet vehicle, so the retire is unreachable |
| Retiring drops the beacon the peer's re-anchor needs | **FALSE** on this vehicle — the only live beacon limb is `auto_anchor_pulse_q`, which is not gated by the retire; the two limbs the retire *does* drop are never asserted here |
| Beacon absence starves the peer and produces all-zeros | **TRUE — reproduced in sim, byte-for-byte the HW signature** |
| The retire path explains the *directionality* (YES/NO fails, NO/YES passes) | **NO** — the path is role-symmetric |

---

## 1. Adversarial RTL verification

### 1.1 The block, quoted from `HEAD`

`src/rtl/local_overrides/axi_chiplet_controller.sv:4836-4884` (the whole
`autonomy_retire_q` always_ff). Dwells at `:4831-4832`:

```systemverilog
localparam [15:0] RETIRE_DWELL    = 16'd4096;      // branch 1 (sim mutual gate)
localparam [23:0] RETIRE_DWELL_SI = 24'd8_000_000; // branch 2 (silicon, ~160 ms @50MHz)
```

Branch 1 (`:4855-4859`):
```systemverilog
if (winscan_done && ws_anchor_q && (sync_obs_fcsm_state_1 == 3'd4))
    fc_stable_cnt_q <= (fc_stable_cnt_q == RETIRE_DWELL) ? RETIRE_DWELL : fc_stable_cnt_q + 16'd1;
else fc_stable_cnt_q <= 16'd0;
```

Branch 2 (`:4862-4866`):
```systemverilog
if (ws_anchor_q && (sync_obs_fcsm_state_1 == 3'd4))
    rea_up_cnt_q <= (rea_up_cnt_q == RETIRE_DWELL_SI) ? RETIRE_DWELL_SI : rea_up_cnt_q + 24'd1;
else rea_up_cnt_q <= 24'd0;
```

The SET (`:4878-4882`):
```systemverilog
if (RETIRE_EN && (nego_en & role_locked & nego_train_cfg_r[0])
    && mask_hs_verified_reg
    && ((fc_stable_cnt_q == RETIRE_DWELL) || (rea_up_cnt_q == RETIRE_DWELL_SI)))
    autonomy_retire_q <= 1'b1;
```

### 1.2 Clause 1 — "branch 2 lacks a peer-anchored term": **CONFIRMED**

`ws_anchor_q` is this die's own CDC of the deskew `reanchored` latch
(`:4696-4704`). There is no peer-anchor input anywhere in `:4862-4866`.

**One refinement the hypothesis document does not make, and should.**
`sync_obs_fcsm_state_1 == 3'd4` is **not** a purely local term. FCSM state 4 is
`LINK_IDLE` (`deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala:38-47`),
and reaching it requires a *completed bidirectional* CR/CRACK exchange:
`SEND_CREDITS1 → SEND_CREDITS2` needs a CR **or** CRACK received from the peer
(`src/rtl/local_overrides/WlinkGenericFCSM_6.v:719-720`) and
`SEND_CREDITS2 → LINK_EN_WAIT` needs a **CRACK** received from the peer
(`WlinkGenericFCSM_6.v:621,732`). So branch 2 does carry a genuine **peer-liveness
and peer-RX-integrity** term — it simply does not carry a peer-**anchored** term.
The distinction matters because it is the reason the original author believed
branch 2 was "starvation-safe" (commit `cd2db38`: *"die_b already up ⇒
starvation-safe"*). The n=20 cross-tab falsifies that belief — die_b can be *up*
(fcsm 4) and *un-anchored* simultaneously; that is precisely the failing cell.
**That is a real, if narrow, defect in the branch-2 rationale, and it is worth
recording independently of everything below.**

### 1.3 Clause 2 — "it is the path taken in the shipping configuration": **FALSE**

The SET requires `(nego_en & role_locked & nego_train_cfg_r[0])`. On the
`kr260-eth-chiplet` vehicle that produced the n=20 campaign, **`nego_en` is 0 and
nothing ever raises it**:

| Fact | Citation |
|---|---|
| `nego_en = nego_cfg_reg[0]` | `axi_chiplet_controller.sv:674` |
| `nego_cfg_reg <= NEGO_CFG_RESET` at POR | `axi_chiplet_controller.sv:781` |
| `NEGO_CFG_RESET` default `7'h00` | `axi_chiplet_controller.sv:84`, `src/rtl/tidelink_top.sv:141` |
| The eth-chiplet instantiation sets **only** `SELF_ARM_TRAIN_EN`, `AUTO_ANCHOR_EN`, `TXGEN_PRESENT`, `NUM_PHY_LANES` — **no `NEGO_CFG_RESET`** | `imp/fpga/eth_chiplet_ip/src/nanosoc_eth_chiplet.sv:760` |
| Same line in the **as-built project source** for the campaign bitstream | `imp/fpga/project/kr260-eth-chiplet/tidelink_project.gen/sources_1/bd/tidelink_design/ipshared/d73b/src/nanosoc_eth_chiplet.sv:760`; and `.../src/tidelink_top.sv:144` = `7'h00`, `.../src/axi_chiplet_controller.sv:87` = `7'h00` |
| No BD-level override: `fpga/targets/kr260-eth-chiplet/tidelink_design.tcl` sets no `CONFIG.NEGO_CFG_RESET`; `fpga/vivado_ip/nanosoc_eth_chiplet_vivado_wrapper.v:167` passes none | greps in §4 |
| The bring-up script never writes NEGO_CFG (Region 4 slot `3'h4`, `:929/:943`) and **says so** | `pynq_host/scripts/kr260_eth_bringup.py:193` — *"On this chiplet nego_en=0 (NEGO_CFG_RESET=7'h00), so the autoneg never raises training — the PS must."* |
| The campaign scripts issue no NEGO_CFG write either | `imp/hw_gate/tl035_ab.sh` (register set is `0x2080/0x2084/0x2100/0x2108/0x2140/0x21E4/0x21E0/0x0208`) |

**Contrast with the standalone kr260-pair vehicle**, which *does* bake
`NEGO_CFG_RESET=7'h61` (`fpga/vivado_ip/tidelink_vivado_wrapper.v:147`,
`fpga/targets/kr260-pair-nptp/tidelink_design.tcl:433,454`). The retire is live
*there*. It is not live on the eth-chiplet. **The two vehicles must not be
conflated when reasoning about this bug** — the n=20 campaign is explicitly
`kr260-eth-chiplet` baseline (`imp/hw_gate/overnight/RELIABILITY_CAMPAIGN_2026_08_13.md:72-73`).

`RETIRE_EN` is indeed `1'b1` (`tidelink_top.sv:205`, `axi_chiplet_controller.sv:150`,
un-overridden in the built source), and `nego_train_cfg_r[0]` is indeed 1
(`NEGO_TRAIN_CFG_RESET = 16'h0001`, `:65`), and `role_locked` is 1 after the
ROLE_CFG write. Those three are satisfied. `nego_en` is the one that is not — and
`mask_hs_verified_reg` is a second lock (it is only set on the autoneg path,
`:820`; the `nego_en=0` comment at `:909` notes it is *not* set on the honest
bypass).

### 1.4 Clause 3 — "retiring drops the beacon the peer needs": **FALSE here**

`autonomy_retire_q` has exactly **one** consumer in the whole file — `autonomy_armed`
(`:1427-1429`):
```systemverilog
wire autonomy_armed = nego_en & role_locked & nego_train_cfg_r[0] & ~autonomy_retire_q;
```
With `nego_en = 0`, `autonomy_armed` is identically 0 **regardless of the retire**,
so `autonomy_retire_q` is a structural no-op on this vehicle.

More importantly, the forced-SYNC chain is a **four**-limb OR at the Wlink ports
(`:6656`, `:6662`, `:6671`):
```systemverilog
.swi_sync_insert_en_in      (swi_sync_insert_en_r | winscan_force_sync | ws_serve_active_r | auto_anchor_pulse_q),
.swi_sync_force_always_in   (swi_sync_force_always_r | winscan_force_sync | ws_serve_active_r | auto_anchor_pulse_q),
.swi_sync_robust_detect_in  (swi_sync_robust_detect_r | winscan_force_sync | ws_serve_active_r | auto_anchor_pulse_q),
```
The retire (via `autonomy_armed`) can remove `winscan_force_sync` and
`ws_serve_active_r`. It **cannot** touch `auto_anchor_pulse_q`, whose always_ff
(`:4926-4978`) is gated only by
`AUTO_ANCHOR_EN && !auto_anchor_done_q && !swi_training_mode_r` (`:4935`) —
no `autonomy_armed`, no `autonomy_retire_q`, no `nego_en`.

And `AUTO_ANCHOR_EN = 1'b1` on this vehicle
(`nanosoc_eth_chiplet.sv:760`, and the same line in the as-built project source).
The auto-anchor block was added on 2026-08-04 — **after** branch 2 (`cd2db38`,
2026-07-15) — and its comment at `:4902-4906` / `:4938-4944` states the exact
concern the hypothesis raises and says it was *already fixed there*:

> *"There is deliberately NO `ws_anchor_q` early-out … stopping on THIS die's own
> reanchor would drop its `force_always` beacon before the peer has latched
> (mutual-anchor starvation) … HW 08-05: die_a reanchored autonomously, its
> early-out stopped its beacon, and die_b was left reanchored=0; a sustained
> die_a beacon then latched die_b."*

**The measured evidence agrees.** In `test_retire_cannot_fire_in_shipping_posture`,
at the moment die_a is anchored and the branch-2 dwell condition is continuously
held, the limb breakdown reads:

```
limbs ws_force=0 ws_serve=0 auto_pulse=1 auto_done=0 insert_r=0 force_r=0
PORT insert=1 force=1 robust=1
```

`auto_anchor_pulse_q` is the **sole** source of the beacon. The two limbs the
retire would drop are already 0.

### 1.5 Timing, even on the vehicle where the retire *is* live

Ratio argument, from the constants: `ANCHOR_LEN = 200_000_000` vs
`RETIRE_DWELL_SI = 8_000_000` (`:4916`, `:4832`) — the beacon window is **25x**
the retire dwell. `rea_up_cnt_q` cannot even start until `ws_anchor_q` is 1, and
`ws_anchor_q` only becomes 1 *because* the beacon has been running. So the beacon
is still live at the retire unless the local anchor itself took > 192 M cycles
(≈ 3.84 s @50 MHz) — beyond the ~3 s the RTL's own HW note cites as the worst
observed (`:4900-4901`). **The beacon outlives the retire by construction.**

What actually ends the beacon is `auto_anchor_link_up && !auto_anchor_tx_idle`
(`:4956-4970`) — the first app-side word — which sets `auto_anchor_done_q`
permanently. That is traffic-driven, not retire-driven.

### 1.6 What the peer's re-anchor genuinely depends on (clause 3, back half)

Confirmed, and it is real:
`reanchored` latches only when `all_sync_seen && sr_rd_safe`
(`deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:1461-1467`), where
`all_sync_seen = &(sync_seen_sync1 | ~lane_mask)` (`:1322`) and each lane's
`sync_seen_l` requires `SYNC_CONFIRM` consecutive *periodic* SYNC matches
(`:585-600`). No beacon ⇒ no `sync_seen` ⇒ no anchor. `reanchored` then selects
the per-lane read pointer (`:1486`) and is exported as `epoch_anchored_o`
(`:1524`) = `EPOCH_STATUS 0x2140` bit0. So the *back half* of the hypothesis's
chain is sound. It is the *front half* (retire ⇒ beacon absent) that fails.

---

## 2. Directionality — the hypothesis does not explain it, and cannot

The measured cross-tab is one-directional: **YES/NO fails 3/3, NO/YES passes 4/4.**

**The retire path is role-symmetric.** `autonomy_retire_q`'s SET (`:4878`) contains
no `role_is_master` term; the dwell counters contain none; `autonomy_armed`
contains none. Both dies run identical logic. A role-symmetric mechanism cannot
produce a strictly one-directional failure. `test_reverse_ordering_dieb_first`
exercises exactly this and behaves identically to the forward case.

There **are** genuinely role-asymmetric anchor→beacon couplings in this file, and
they deserve to be named because they are the strongest version of the
hypothesis — but they all live **inside the winscan FSM**, which is
`autonomy_armed`-gated (`ws_kick_evt = WINSCAN_FSM_EN & autonomy_armed & …`,
`:5103`) and therefore also dead at `nego_en = 0`:

- **`:5600-5622` (WS_FINALIZE release)** — `ws_anchor_q && ws_verify_q` drops
  `winscan_force_sync` on **this die's own** anchor. Same defect shape as branch 2,
  and it fires far earlier.
- **`:5693-5695` (rendezvous entry)** —
  `role_is_master && !ws_anchor_q && !ws_rdv_timeout_q && peer_ready_to_serve_w`.
  **Only an *un-anchored* master enters `WS_FIN_WAITPEER`**, which is what makes the
  slave serve beacons (`ws_serve_active_r`, `:4716`). An anchored master skips the
  rendezvous entirely. That is a genuine `role_is_master`-gated asymmetry with
  exactly the right sign: master-anchored ⇒ slave gets no served beacons.

**If the campaign is ever re-run on a `nego_en=1` vehicle (kr260-pair-*), `:5693`
is the first thing to look at, not branch 2.** On the eth-chiplet it is inert.

### A directional alternative that survives the evidence

Because `reanchored=1` with all-zero `lane_off` is **bit-identical** on the
datapath to `reanchored=0` (`:1486` is a pure mux; nothing else in the deskew
reads `reanchored` — no pointer reset, no bubble, no valid gate, and the module
has no TX ports at all), the anchor is only *load-bearing* when there is real
cross-lane skew to correct. That gives a mechanism which explains all four cells
without any beacon-retire:

1. Delivery is measured **A→B, read back by die_b**. Only **die_b's** `reanchored`
   frames that direction.
2. **NO/NO** — no die measured a skew this power-up; the common pointer is correct;
   delivers. ✓ (8/8)
3. **NO/YES** — die_b corrected the delivery direction; die_a's un-corrected RX only
   affects B→A credit/CRACK traffic, and FCSM still reached 4; delivers. ✓ (4/4)
4. **YES/YES** — both corrected; delivers. ✓ (5/5)
5. **YES/NO** — die_a's anchor is a **witness that measurable skew exists this
   power-up**, and die_b failed to correct it ⇒ die_b mis-frames A→B ⇒ all-zeros. ✗ (0/3)

On this reading die_a's anchor bit is not *causal*; it is the only available
**proxy for "skew is present"**. That is consistent with everything measured and
requires no unilateral-retire defect.

**It is directly testable on hardware with a one-line script change and no rebuild.**
`EPOCH_STATUS 0x2140` bits `[6:1]` carry `sr_span_meas` — the measured cross-lane
SYNC span at engage (`tidelink_lane_deskew.sv:1503-1525`, packing documented at
`:1506-1508`). The bring-up script currently throws it away:
`pynq_host/scripts/kr260_eth_bringup.py:258,261` do `bd.rd(REG_EPOCH_STATUS) & 1`.
**Log the full word.** Prediction: in the YES/NO failures die_a's `sr_span > 0`;
in the NO/NO passes there is no span (nothing engaged) and the link is genuinely
skew-free. If instead die_a's span is 0 in the failures, this alternative dies too.

---

## 3. Simulation — path, assertions, results

Vehicle: `cocotb/tidelink_top_pair_v2` (`tb_top.sv` — two cross-wired V2
`tidelink_top` instances, genuine pair). `cocotb/tidechart_tidelink_pair` was
inspected and rejected: it is a TideChart election/claim harness, not a
deskew/beacon pair.

New file: **`cocotb/tidelink_top_pair_v2/test_v2_beacon_retire_starve.py`**

Build posture (matches the shipping eth-chiplet vehicle where it can):

```
source ./set_env.sh                 # MANDATORY — else every suite dies in ~5 s
cd cocotb/tidelink_top_pair_v2
make AUTO_ANCHOR=1 EPOCH_PROFILE=staircase \
     MODULE=test_v2_beacon_retire_starve TESTCASE=<name> \
     SIM_BUILD=sim_build_beaconretire_aa1
```

- `AUTO_ANCHOR=1` ⇒ `AUTO_ANCHOR_EN=1'b1` on both dies = the shipping posture.
- `EPOCH_PROFILE=staircase` makes the anchor **load-bearing** for delivery; the
  pre-existing `test_v2_auto_anchor.test_auto_anchor_negctl_no_anchor_fails`
  already proves a staircase-skewed packet does not deliver without it.
- `EPOCH_ANCHOR=0` (default) ⇒ `SYNC_REANCHOR_EN=1`, the beacon-dependent
  corrector — the same one the FPGA ships.
- A private `SIM_BUILD` was used so the two other agents in this tree are not
  disturbed. Baseline sanity first: the untouched
  `test_v2_auto_anchor.test_auto_anchor_delivers_under_skew` **PASSes** in this
  build (both directions byte-exact), so the vehicle is good.

### 3.1 Results

| # | Testcase | Result | What it establishes |
|---|---|---|---|
| 1 | `test_retire_cannot_fire_in_shipping_posture` | **PASS** | branch-2 dwell satisfied ⇒ retire still 0 (`nego_en=0`); beacon is `auto_anchor` only |
| 2 | `test_forced_retire_does_not_starve_peer` (steel-man) | **PASS** | retire forced at YES/NO ⇒ beacon **not** dropped; die_b anchors; A→B byte-exact |
| 3 | `test_positive_control_beacon_kill_starves_peer` | **PASS** | beacon genuinely absent ⇒ YES/NO **and all-zeros** — the HW signature reproduced |
| 4 | `test_reverse_ordering_dieb_first` | **PASS** | identical behaviour with roles swapped ⇒ the path is role-symmetric |

All four were run individually against `SIM_BUILD=sim_build_beaconretire_aa1`
(logs retained in the session scratchpad; each run reports `TESTS=1 PASS=1 FAIL=0`).

### 3.2 Test 1 — the shipping vehicle cannot take branch 2 (measured)

Assertions: `nego_en==0` and `autonomy_armed==0` (posture precondition);
the **real** dwell condition `ws_anchor_q && fcsm==4` sampled **every cycle for 200
cycles** and required to hold on all of them (non-vacuity — the counter would
otherwise reset); then `rea_up_cnt_q` presented at `RETIRE_DWELL_SI`; then
`autonomy_retire_q == 0`.

Measured log:
```
[shipping-posture] pre : rea=1 wsq=1 fcsm=4 | retire=0 armed=0 nego_en=0 train_auto=1
                         mask_hs=0 rea_up_cnt=1 fc_stable=0 ws_done=0
                       | limbs ws_force=0 ws_serve=0 auto_pulse=1 auto_done=0
                         insert_r=0 force_r=0 | PORT insert=1 force=1 robust=1
[shipping-posture] (ws_anchor_q && fcsm==4) held on all 200 sampled cycles: True;
                   free-running rea_up_cnt_q=201
[shipping-posture] branch-2 dwell presented as 8000000 (RETIRE_DWELL_SI=8000000)
[shipping-posture] post: ... retire=0 armed=0 nego_en=0 mask_hs=0 rea_up_cnt=8000000 ...
                       | limbs ws_force=0 ws_serve=0 auto_pulse=1 ... | PORT force=1
```

Reading: the branch-2 **dwell is satisfied and the retire still does not fire**
(both `nego_en` and `mask_hs_verified_reg` are 0). And the beacon at the PHY port
is entirely `auto_anchor_pulse_q` — the limbs the retire would drop are already 0.

### 3.3 Test 3 — positive control: a beacon that really stops **does** starve the peer (measured)

`auto_anchor_pulse_q` on die_a is `Force(0)` for the whole run — the state the
hypothesis *claims* the retire produces. die_b's beacon is untouched, so die_a
still anchors.

```
[posctl] die_a: rea=1 ... | limbs auto_pulse=0 auto_done=1 | PORT insert=0 force=0 robust=0
[posctl] die_b: rea=0 ... | PORT insert=0 force=0 robust=0
[posctl_m2s_starved] m->s: PKT_LEN=0x0 hdr=0x00000000 (sent 0x00240000)
                     rx=[0x00000000, 0x00000000, 0x00000000, 0x00000000]
```

**This is the measured hardware signature, reproduced exactly**: die_a
`reanchored=1`, die_b `reanchored=0`, A→B **all-zeros**. So:
- the TB is *sensitive* to beacon starvation — tests 1/2 passing is not a blind spot;
- the hypothesis's **back half is correct**;
- what is refuted is specifically **"the retire is what removes the beacon."**

### 3.4 Test 2 — steel-man: the retire fires at exactly the hypothesised moment (measured)

The hypothesised ordering is constructed genuinely, then the RETIRED state is
applied, and the beacon is watched across it:

```
[steelman] die_b lane0 sync_seen_l FORCED 0 (die_b cannot anchor)
[steelman] die_a pre-retire : rea=1 wsq=1 fcsm=4 | ... | limbs ws_force=0 ws_serve=0
                              auto_pulse=1 auto_done=0 | PORT insert=1 force=1 robust=1
[steelman] die_b pre-retire : rea=0 wsq=0 fcsm=4 | ...
[steelman] branch-2 dwell presented as 8000000 (RETIRE_DWELL_SI=8000000);
           winscan_done=0, fc_stable_cnt_q=0 (branch 1 NOT satisfied)
[steelman] die_a AT-RETIRE   : rea=1 ... retire=1 armed=0 rea_up_cnt=8000000 ...
                              | auto_pulse=1 | PORT insert=1 force=1 robust=1
[steelman] die_b AT-RETIRE   : rea=0 ...
[steelman] beacon at the port across the retire: force 1 -> 1, insert 1 -> 1, robust 1 -> 1
[steelman] die_b lane0 sync_seen_l RELEASED
[steelman] die_b post        : rea=1 ...
[steelman_m2s_after_retire] m->s: rx=[0x00240000, 0x00000000, 0xa11c0000, 0xc0ffee01]  (byte-exact)
```

Assertion (a) non-vacuity: `die_a rea=1` / `die_b rea=0` at the firing instant;
`auto_pulse=1, auto_done=0` (beacon window open); `PORT_force=1` pre-retire;
branch 1's dwell **not** satisfied. Assertion (b): **beacon not dropped**
(`force 1 → 1`). Assertion (c): **die_b anchors anyway** once released.
Assertion (d) end-to-end: **A→B byte-exact under load-bearing staircase skew**.

### 3.5 Test 4 — reverse ordering (measured)

```
[reverse] die_a lane0 sync_seen_l FORCED 0 (die_a cannot anchor)
[reverse] die_b pre-retire : rea=1 ... | [reverse] die_a pre-retire : rea=0 ...
[reverse] die_b AT-RETIRE  : retire=1 armed=0 rea_up_cnt=8000000 | auto_pulse=1
                             | PORT insert=1 force=1 robust=1
[reverse] die_a post       : rea=1 ...
[reverse_m2s_after_retire] m->s: rx=[0x00240000, 0x00000000, 0x5a1ead00, 0xbeefcafe]  (byte-exact)
```

Identical to test 2 with the roles swapped — as expected from a retire path with
no `role_is_master` term anywhere. **A role-symmetric mechanism cannot produce the
one-directional hardware cross-tab.**

### 3.6 How the ordering was constructed, and the two honest limitations

Tests 2 and 4 construct the ordering by forcing **one lane's** sticky `sync_seen_l` low on
the die that must stay un-anchored
(`tidelink_lane_deskew.sv:536`, inside `g_lane_write[gi].g_sync_capture`), which
holds `all_sync_seen` (`:1322`) low without touching that die's TX beacon or its
per-lane `sync_idx` capture. On `Release` the lane must win a **fresh periodic SYNC
confirm run** (`:585-600`), so the die genuinely needs a **live** peer beacon to
anchor afterwards — which is what makes assertion (c) meaningful rather than
automatic.

**Two honest limitations, recorded rather than papered over:**

1. **The natural arming route is self-defeating in this TB.** Depositing
   `nego_cfg_reg[0]=1` to satisfy `(nego_en & role_locked & nego_train_cfg_r[0])`
   also arms the winscan FSM (`ws_kick_evt`, `:5103`); the FSM advances to
   FINALIZE and **tears down the FC** — measured here as `fcsm: 4 → 0` within
   ~90 µs, with `winscan_done=1`. That is exactly the silicon winscan livelock
   commit `cd2db38` describes (*"advancing to FINALIZE TEARS DOWN the FC
   (fcsm 4→0)"*). With `fcsm != 4` the branch-2 counter resets every cycle
   (`:4862-4866`) and the retire can never latch. **Reproducing that livelock was
   not the goal, but it is a real corroboration of `cd2db38`'s silicon diagnosis
   and is recorded here.** The tests therefore reconstruct the RETIRED state at
   its strongest — `Force(autonomy_retire_q = 1)` — which is *strictly more*
   favourable to the hypothesis than reality.
2. **A plain deposit of `rea_up_cnt_q` does not stick** (the always_ff's
   non-blocking update, computed from the pre-deposit value, lands after it;
   measured free-running counts of 201/401/601 across attempts). The dwell is
   therefore presented with a held `Force`, and the tests **separately** sample the
   real dwell condition every cycle to show it was legitimately accumulating.

`ANCHOR_LEN` is 4096 in sim vs 200 M on silicon (`:4913-4917`), so the sim ratio
between beacon window and retire dwell is *inverted* relative to hardware. Every
retire in these tests therefore lands **early inside** the beacon window — a
stricter test than silicon, where it lands 25x before the window ends.

---

## 4. No patch

**No fix is proposed and no patch file was generated.** The working tree is
unchanged apart from the two new files listed at the top; `git diff --stat` shows
only the pre-existing modifications belonging to the other two agents in this tree
(verified in §5).

Adding a peer-anchored term to branch 2 would be **the wrong fix**:

- It would not change the campaign vehicle at all (`nego_en=0` — the branch is
  unreachable).
- `cd2db38` shows branch 2 exists precisely *because* the mutual signal
  (`winscan_done`) is **dead on silicon**: *"die_a churns ws_state 3↔7;
  winscan_done NEVER holds 1 … so a winscan_done-gated retire is INERT on
  silicon."* There is **no** peer-anchored signal available to this die — the
  peer's anchor is not in any register this die can read on the FC path. Adding
  a term that can never assert converts branch 2 into branch 1, i.e. deletes the
  retire, and re-opens the B→A corruption `4f5223f`/`cd2db38` closed
  (`:4760-4772`, with the `td_b2a_diag2.log` silicon proof).
- The one *available* peer signal is `SWI_LANE_STATUS[27]` (`peer_ready_to_serve_w`,
  packed at `:2820`), and it advertises `autonomy_armed & winscan_done`, **not**
  the peer's anchor. Using it would be the same substitution with the same flaw.

### What is worth doing instead

1. **Log the full `EPOCH_STATUS 0x2140` word** in
   `pynq_host/scripts/kr260_eth_bringup.py:258,261` (currently `& 1`). Bits `[6:1]`
   = `sr_span_meas`. This is the single cheapest discriminator between the
   surviving alternative (§2) and any remaining beacon story, costs one line, and
   needs no rebuild.
2. **Open a registry entry against branch 2's *rationale*, not its wiring** — the
   comment at `:4801-4810` ("die_b is already up so it is starvation-safe") is
   falsified by the cross-tab: fcsm=4 does not imply anchored. It is latent on
   `kr260-pair-*` (`NEGO_CFG_RESET=0x61`), inert on `kr260-eth-chiplet`.
3. **If a `nego_en=1` vehicle is ever used for this measurement**, audit
   `:5600-5622` (WS_FINALIZE drops force-SYNC on the local anchor) and
   `:5693-5695` (only an un-anchored master enters the serve rendezvous) — those
   are the genuinely role-asymmetric versions of this defect and they fire far
   earlier than branch 2's 160 ms.
4. **Do not add a hardware A/B for beacon-retire.** It would be an A/A on this
   vehicle.

---

## 5. What was simulated vs. what was inferred

**Simulated (measured in `cocotb/tidelink_top_pair_v2`, VCS 2022.06-SP2, cocotb 2.0.1):**
- die_a anchored, `fcsm==4` held continuously, `rea_up_cnt_q` free-running and then
  presented at `RETIRE_DWELL_SI`, `autonomy_retire_q` staying 0 (test 1).
- The forced-SYNC beacon at the Wlink ports being supplied **solely** by
  `auto_anchor_pulse_q` in the shipping posture (test 1 limb breakdown).
- A genuinely absent die_a beacon producing die_a=YES / die_b=NO and **all-zeros**
  A→B delivery (test 3) — the hardware signature, reproduced.
- The winscan-FSM FC teardown (`fcsm 4→0`) triggered by raising `nego_en` (§3.4).
- Baseline vehicle health: the untouched `test_v2_auto_anchor` deliver test passes.

**Inferred from RTL / build artefacts, not simulated:**
- That the *campaign bitstream* was built from the sources inspected. The strongest
  available evidence is the as-built project source
  (`imp/fpga/project/kr260-eth-chiplet/.../ipshared/d73b/src/`, mtime
  2026-08-13 22:12) carrying `NEGO_CFG_RESET=7'h00` and `AUTO_ANCHOR_EN(1'b1)`.
  The `.bin` md5s in `RELIABILITY_CAMPAIGN_2026_08_13.md:7-8` were **not**
  independently traced to that project.
- The silicon timing margin of §1.5 (the 25x ratio) — arithmetic on the two
  localparams, not a simulated multi-second run.
- The `sr_span` alternative in §2 — an RTL-supported hypothesis, **explicitly not
  yet tested**, with a named cheap experiment.
- Nothing here re-measures the n=20 campaign; the cross-tab is taken as given.

---

## Appendix — file:line index

| Item | Path:line (HEAD unless noted) |
|---|---|
| `autonomy_retire_q` always_ff | `src/rtl/local_overrides/axi_chiplet_controller.sv:4836-4884` |
| Dwell localparams | `:4831-4832` |
| Branch 1 counter | `:4855-4859` |
| Branch 2 counter (no peer-anchored term) | `:4862-4866` |
| Retire SET / arming conjunction | `:4878-4882` |
| Re-arm comment "the peer's re-anchor needs it" | `:4843-4844` |
| `autonomy_armed` (sole consumer of the retire) | `:1427-1429` |
| Forced-SYNC 4-limb OR at the Wlink ports | `:6656`, `:6662`, `:6671` |
| `auto_anchor_pulse_q` always_ff (no autonomy term) | `:4926-4978`, gate at `:4935` |
| "NO `ws_anchor_q` early-out … mutual-anchor starvation" | `:4902-4906`, `:4938-4944` |
| `ANCHOR_LEN` sim/silicon split | `:4913-4917` |
| `nego_en = nego_cfg_reg[0]` | `:674` |
| `nego_cfg_reg <= NEGO_CFG_RESET` | `:781` |
| `NEGO_CFG_RESET = 7'h00` | `:84`; `src/rtl/tidelink_top.sv:141` |
| `NEGO_TRAIN_CFG_RESET = 16'h0001` | `:65` |
| `RETIRE_EN = 1'b1` | `:150`; `src/rtl/tidelink_top.sv:205` |
| `mask_hs_verified_reg` set (autoneg path only) | `:820`, note at `:909` |
| NEGO_CFG write decode (Region 4 slot `3'h4`) | `:929`, `:943` |
| `ws_anchor_q` CDC of deskew `reanchored` | `:4696-4704` |
| `ws_kick_evt` gated on `autonomy_armed` | `:5103` |
| WS_FINALIZE drops force-SYNC on local anchor | `:5600-5622` |
| Serve rendezvous entry needs `role_is_master && !ws_anchor_q` | `:5693-5695` |
| Slave serve engine (`ws_serve_active_r`) | `:4716` |
| `SWI_LANE_STATUS[27]` = `peer_ready_to_serve` packing | `:2820` |
| eth-chiplet `tidelink_top` instantiation (AUTO_ANCHOR_EN=1, no NEGO_CFG_RESET) | `imp/fpga/eth_chiplet_ip/src/nanosoc_eth_chiplet.sv:760` |
| Same, in the as-built campaign project | `imp/fpga/project/kr260-eth-chiplet/tidelink_project.gen/sources_1/bd/tidelink_design/ipshared/d73b/src/nanosoc_eth_chiplet.sv:760` |
| Bring-up script states `nego_en=0` | `pynq_host/scripts/kr260_eth_bringup.py:193` |
| Bring-up script masks `EPOCH_STATUS` to bit0 | `pynq_host/scripts/kr260_eth_bringup.py:258,261` |
| kr260-**pair** vehicle bakes `NEGO_CFG_RESET=0x61` (contrast) | `fpga/vivado_ip/tidelink_vivado_wrapper.v:147`; `fpga/targets/kr260-pair-nptp/tidelink_design.tcl:433,454` |
| Campaign vehicle = kr260-eth-chiplet baseline | `imp/hw_gate/overnight/RELIABILITY_CAMPAIGN_2026_08_13.md:72-73` |
| `reanchored` latch condition | `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:1461-1467` |
| `all_sync_seen` | `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:1322` |
| Per-lane sticky `sync_seen_l` + periodic confirm | `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:536`, `:585-600` |
| `reanchored` sole datapath use (read-pointer mux) | `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:1486` |
| `epoch_anchored_o` / `epoch_span_o` (0x2140 bit0 / bits[6:1]) | `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:1503-1525` |
| FCSM state enum (4 = LINK_IDLE) | `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala:38-47` |
| FCSM 1→2 needs peer CR/CRACK | `src/rtl/local_overrides/WlinkGenericFCSM_6.v:719-720` |
| FCSM 2→3 needs peer CRACK | `src/rtl/local_overrides/WlinkGenericFCSM_6.v:621,732` |
| Commit that introduced branch 2 | `cd2db38` (2026-07-15) |
| The new test | `cocotb/tidelink_top_pair_v2/test_v2_beacon_retire_starve.py` |
