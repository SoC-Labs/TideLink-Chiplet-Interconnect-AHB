# DESIGN B — Active data-mode re-anchor / correct-offset SEARCH in the cross-lane deskew

Panel proposal, 2026-07-22. Read-only RTL analysis; NO edits, NO sims performed.
Competes with **Design A** (`LANE_MASK_RESET=0xFF` rebuild) and **Design C**
(`EPOCH_ANCHOR_EN=1`). Every mechanism claim is tagged **[VERIFIED-RTL]**
(traced to file:line in the V2-flist-compiled sources) or **[INFERRED]**.

Sources traced:
`src/rtl/local_overrides/tidelink_lane_deskew_v2.sv`,
`src/rtl/local_overrides/WavD2DGpio_v2.v`,
`src/rtl/local_overrides/WlinkRxLinkLayer.v`,
`docs/DESKEW_ANCHOR_ROOTCAUSE.md`,
`memory/project_kr260_first_data_crossing_2026_07_22.md`.

---

## TL;DR — the honest bottom line up front

I decoded the actual HW ground-truth slice from the 07-22 session
(`[0x00000000, 0x00005b4c, 0xb5a60000, 0xf1e2d3c4]`) lane-by-lane against
`TIDELINK_SYNC_WORD`. **The four ACTIVE lanes {2,5,6,7} are byte-EXACT; the four
zero lanes are exactly the 0xE4-masked lanes {0,1,3,4}, which the PHY TX drives to
0x0000 by design.** See §1.2 for the full decode.

That single fact reorders the panel:

1. **On the probed board state the deskew is NOT mis-assembling — it is CORRECT on
   every active lane.** `reanchored=1 / span=0` is *truthful* here, not vacuous: four
   lanes with zero cross-lane skew. A re-anchor SEARCH that trusts the SYNC
   self-consistency oracle would **immediately validate and lock the offsets it
   already has** — i.e. Design B is a **no-op on this state**. The delivery failure
   here is therefore NOT in the deskew; it is downstream (masked-lane payload loss,
   or the framer/FC layer). **I concede this plainly.**

2. **If the FC needs an 8-lane (128-bit) word, the four masked lanes carry ZERO on
   the wire — there is no data on them to search for. No deskew re-anchor can
   conjure it. Only Design A (`0xFF` + train all 8) recovers those lanes.** If the
   reduced-lane path is genuinely 4-lane-coherent, then the deskew being already
   correct means the intermittency lives in the framer/FC, and Design B still does
   not touch it. **Either branch says Design B is not the fix for the 07-22 state.**

3. **Where Design B is uniquely necessary:** a *different, documented* board state —
   the tol-5 Hamming **wrong-slot** latch (`WavD2DGpio_v2.v:14-18`, the die_b
   byte-lane[23:16] `0x24→0x5c` corruption) — is a genuine deskew mis-anchor that a
   naive re-latch re-lands identically but a **validated offset search would repair**.
   Design B is the only one of the three that fixes *that* class in-field without a
   rebuild, and the only one that defends against **within-data-mode drift**.

**Verdict:** Design B is **strictly subordinate to Design A**. Do Design A first
(unmask+train all 8). Design B is the second-tier hardening that makes whatever
lanes are active *stay* correctly anchored against wrong-slot capture and drift. It
is **not** the standalone answer to the 07-22 lottery, and I will not pretend it is.

---

## 1. What the current anchor does wrong

### 1.1 How one SYNC capture becomes the per-lane offsets [VERIFIED-RTL]

The SYNC re-anchor is the built corrector (`SYNC_REANCHOR_EN=1`,
`EPOCH_ANCHOR_EN=0`; instance `WavD2DGpio_v2.v:837,882`, overrides
`SYNC_REANCHOR_TOL(5)` at `:857`). Offsets are computed **once** from a single
confirmed SYNC capture:

- **Write side, per lane** (`tidelink_lane_deskew_v2.sv:586-800`): each lane
  popcount-compares its incoming word to its own slice
  `TIDELINK_SYNC_WORD[16*gi +: 16]`; `sync_hit = (sync_dist_w <=
  SYNC_REANCHOR_TOL) && (|lane_data)` (`:606-607`), **TOL=5** on the shipped build
  (`:857`) — *not* the module default 4 (`:233`). A self-gating periodic-confirm arm
  (`:609-800`) commits `sync_idx_l <= wr_ptr_l` (`:766`) only after `SYNC_CONFIRM=2`
  (`:272`) matches recurring at a consistent `wr_ptr_l mod SYNC_PERIOD=32` residue
  within a circular `±SYNC_IDX_TOL=2` (`:307`) window.
- **Read side** (`g_reanchor :1341-1553`): `all_sync_seen = &(sync_seen_sync1 |
  ~lane_mask)` (`:1350`); per-lane `sync_dist[di] = sync_idx_sync1[di] - rd_ptr`
  (`:1378`); the cross-lane `max_dist` folds **only unmasked lanes** (`:1379-1388`).
  The one engage branch (`:1479-1508`), gated `advance && !reanchored &&
  !rearm_wait`, on `all_sync_seen && sr_rd_safe` loads:
  ```
  lane_off[lo] <= lane_mask[lo] ? (max_dist - sync_dist[lo]) : '0;   // :1491-1493
  reanchored   <= 1'b1;                                              // :1495
  ```
  Thereafter `rd_ptr_l[gi] = reanchored ? (rd_ptr - lane_off[gi]) : rd_ptr`
  (`:1514`).

**The three ways this single capture lands wrong** (all [VERIFIED-RTL] as
mechanisms; which one occurs is board-state-dependent):

- **Masked lanes never bit-align:** `lane_off = lane_mask ? … : '0` (`:1491-1493`).
  Under 0xE4, lanes {0,1,3,4} are parked at offset 0 and read the raw common
  pointer forever. Combined with the PHY TX zeroing masked lanes
  (`WlinkRxLinkLayer.v:344-347`), those lanes carry and read **0x0000**.
- **Tol-5 wrong-slot capture:** `TOL=5` (`:857`) admits a Hamming-5 word one slot
  off the true beacon beat; that lane commits a `sync_idx` off by a word
  (`WavD2DGpio_v2.v:14-18`). Its `lane_off` is then off by a word ⇒ the assembled
  word shears, while `reanchored=1` still reports "engaged."
- **One-shot sticky, no data-mode re-measure:** the only writers of `reanchored`
  (`:1457-1508`) are POR, the `clr_pulse_o` re-arm (`:1461`), and the single
  `!reanchored` engage (`:1479`). Once set, the offsets are **frozen** for the
  session; the per-lane word-clock phases keep wandering (the reason
  `SYNC_IDX_TOL=2` exists, `:653-666`) with nothing re-measuring them.

### 1.2 The 07-22 HW slice, decoded — the load-bearing correction [INFERRED, high-confidence]

The 07-22 probe read the ground-truth post-deskew word (0x212C–0x2138) as
`[0x00000000, 0x00005b4c, 0xb5a60000, 0xf1e2d3c4]`, **identical across 6 re-SYNC
retries and 3 bring-ups**, `reanchored=1 span=0`, 0/5 delivered.

`TIDELINK_SYNC_WORD = F1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00`
(`WlinkRxLinkLayer.v:341-342`), lane L = bits `[16L +: 16]`. Taking the probe list
as ascending address with 0x212C = word[31:0] (the ordering that makes the memory's
own "correct anchor reads `f1e2d3c4_b5a69788_796a5b4c_3d2e1f00`" reference
self-consistent — `DESKEW_ANCHOR_ROOTCAUSE.md:247`):

| lane | observed | expected slice | verdict |
|---|---|---|---|
| 0 | `0000` | `1F00` | zero (masked) |
| 1 | `0000` | `3D2E` | zero (masked) |
| **2** | **`5B4C`** | `5B4C` | **EXACT ✓** |
| 3 | `0000` | `796A` | zero (masked) |
| 4 | `0000` | `9788` | zero (masked) |
| **5** | **`B5A6`** | `B5A6` | **EXACT ✓** |
| **6** | **`D3C4`** | `D3C4` | **EXACT ✓** |
| **7** | **`F1E2`** | `F1E2` | **EXACT ✓** |

The four exact lanes are **precisely** {2,5,6,7} = the 0xE4 active set; the four
zero lanes are **precisely** the 0xE4 masked set. The four non-zero values are the
exact SYNC slices for those lanes — not a coincidence, and not a shear.

**Conclusion:** on this board state the cross-lane deskew is doing its job
*correctly* on all active lanes; `reanchored=1 span=0` is **truthful** (four lanes,
zero mutual skew). The `DESKEW_ANCHOR_ROOTCAUSE.md`/memory characterisation
"sheared SYNC word ⇒ WRONG cross-lane mis-assembly" is **refuted by the per-lane
decode** — the "shear" is entirely the 0xE4 masked-lane zeroing showing through.
(This is the 4th instance of the standing rule *verify the instrument before
theorising about the DUT*: the aggregate 128-bit read *looked* sheared; the per-lane
decode says the active lanes are perfect.)

The determinism the coordinator flagged (identical across 6 re-SYNC + 3 bring-ups)
is now **fully explained without any deskew bug**: masked lanes are hard-zeroed at
the TX every beat, and the four active lanes capture a clean beacon. Nothing in the
deskew is rolling a dice on this state — so **a re-anchor that re-triggers the same
capture lands the same (already-correct) offsets, exactly as observed.**

---

## 2. The Design B mechanism — a validated per-lane offset SEARCH

The coordinator's constraint is decisive: **a naive re-anchor that re-triggers the
same capture lands the same offsets (proven).** So the design must (a) not trust the
one-shot capture, (b) *validate* an alignment against an in-band oracle, and (c) when
validation fails, **actively perturb** the per-lane offsets and re-validate — a
bounded search, not a re-latch.

### 2.1 The three ingredients already exist in RTL [VERIFIED-RTL]

Design B needs almost no new *primitives* — three load-bearing pieces are already
built and only need to be wired into a search FSM:

1. **A persistent in-band marker in data mode** — `io_swi_sync_force_always_in`
   (`WavD2DGpio_v2.v:230-242`). When 1 it drops the `io_link_tx_tx_idle` gate so the
   SYNC beacon **keeps flowing in DATA mode**. This dissolves the "beacon off in data
   mode" killer constraint *without inventing a new marker* — see §3.
2. **A self-consistency oracle** — `io_anchor_verified` (`WavD2DGpio_v2.v:7-29,
   1254-1268`): a sticky latch that sets **only when, with `reanchored` engaged, the
   post-deskew word matches `TIDELINK_SYNC_WORD` on EVERY active lane simultaneously**
   (per-slice `VERIFY_TOL=3`, `:1230-1254` — tighter than the tol-5 capture, so it
   **rejects a one-slot-off latch**, `:14-18`). This is exactly the "assembled-word
   is self-consistent" check the task asks for — and it validates against the *known*
   SYNC content, which is stronger than a CRC on unknown payload.
3. **A re-arm actuator** — `sync_obs_clr_i`/`clr_pulse_o`
   (`tidelink_lane_deskew_v2.sv:1461`, driven from `WavD2DGpio_v2.v:913`): drops
   `reanchored→0`, `lane_off→0`, re-measures. Today it is a one-shot cold-bring-up
   pulse; the search re-uses it as its retry trigger.

### 2.2 Why a re-arm alone is insufficient, and what the SEARCH adds [INFERRED]

The re-arm (ingredient 3) re-captures — but the HW proof says the capture is
**deterministic** for a given board state (§1.2). So a re-arm loop re-lands
identically and never explores the offset space. **The search must perturb the
per-lane offset between validation-failed retries.** Concretely, a new read-side FSM
(`g_reanchor`, alongside `:1479`):

```
STATE MEASURE : on all_sync_seen && sr_rd_safe, load lane_off = max_dist - sync_dist
                (the existing :1491 math); reanchored<=1; goto VALIDATE.
STATE VALIDATE: wait up to K (=4) SYNC_PERIOD beats for io_anchor_verified.
                if verified   -> goto LOCKED   (never disturbed again).
                if not         -> goto SEARCH.
STATE SEARCH  : pick the next unvalidated active lane whose live sync_dist_w
                (0x21AC obs, :804-808) is MARGINAL (near TOL); nudge THAT lane's
                lane_off by +/-1 word-epoch (a candidate in a bounded +/-W window,
                W = SYNC_IDX_TOL+1 = 3); reanchored stays 1; goto VALIDATE.
                exhaust the +/-W window per lane, then one lane at a time,
                before giving up to a bounded RTO -> pulse clr_pulse_o (full
                re-measure) and restart. Cap total attempts.
STATE LOCKED  : hold lane_off; ignore all_sync_seen; only a POR or an
                FC-failure re-trigger (below) can leave.
```

New state: `srch_state[2:0]`, `srch_lane[2:0]`, `srch_off_delta[LANES]` (signed,
`±W`), `srch_attempts` counter, a `K`-beat validate timer. The datapath change is
minimal: `rd_ptr_l[gi] = reanchored ? (rd_ptr - (lane_off[gi] + srch_off_delta[gi]))
: rd_ptr` (extend `:1514`). Everything else is FSM sequencing over existing signals.

**Validation oracle = `io_anchor_verified`, not CRC.** CRC (task option ii)
validates *payload* against *unknown* data — it can only tell you a packet was bad,
not which lane's offset to nudge, and it is gated off/marginal. `io_anchor_verified`
validates the *assembled word against the known SYNC constant on every active lane
at once* — a direct, per-attempt, lane-diagnostic accept/reject. It already exists
and is already the winscan finalize gate (`axi_chiplet_controller.sv` `ws_verify_q`).

**Re-search trigger (task option iii, folded in):** LOCKED is left only on a real
failure signal — either `io_anchor_verified` de-asserting for M consecutive SYNC
periods (drift detection, since the beacon keeps validating a *good* lock every 32
words under force_always), or an FC-layer delivery-failure strobe if one is exposed.
This respects the `:1426-1430` warning — **a validated/aligned link is never
perturbed**; the search only runs against a demonstrably-failing anchor.

### 2.3 What this fixes and what it does not

- **Fixes** the tol-5 wrong-slot class (§1.1): `io_anchor_verified` fails on the
  one-slot-off latch, SEARCH nudges the offending lane ±1 epoch until the full-word
  match fires. [INFERRED — the oracle provably cannot fire on a mis-anchored link
  (`:14-18`, VERIFIED); that the ±W nudge reaches the correct slot is INFERRED.]
- **Fixes** within-data-mode drift: force_always keeps a live oracle; a drifted lane
  de-asserts verify and is re-searched in the inter-beacon idle gap.
- **Does NOT fix** the 07-22 masked-lane state: on {2,5,6,7} the active lanes are
  already exact, `io_anchor_verified` would **already be set**, SEARCH never runs —
  and the four masked lanes have no data to search for (§0). **Design A is required
  there.**

---

## 3. Beacon dependency — the killer constraint, and why it dissolves

The root-cause doc frames "beacon off in data mode" as the killer. It is **not a
framing necessity — it is a recipe choice**, and the RTL is already built to keep
the beacon on safely:

- **The framer is designed for a data-mode SYNC beacon.** `WlinkRxLinkLayer.v:325-360`:
  the RX detects the SYNC word in DATA mode, **STRIPS it** (substitutes a zero idle
  word so `is_short_pkt=is_long_pkt=0`, `:326-328`) and pulses `sync_resync` to
  re-align to a packet boundary. So a data-mode beacon does not corrupt data.
- **"Data can't alias SYNC" is proven in RTL** (`:333-360`): `SYNC_WORD`'s low byte
  is `0x00` = an invalid Wlink length (no legal header), and the upper 120 bits are a
  descending-nibble ramp the encoder never emits — the mask-aware compare
  (`:361-369`) holds this on the active-lane subset too. **So injecting the beacon in
  data mode cannot collide with a real packet word.** [VERIFIED-RTL]
- **The knob to do it already exists:** `io_swi_sync_force_always_in=1`
  (`WavD2DGpio_v2.v:230-242`) keeps the inserter firing without the idle gate.

**Therefore Design B does NOT need a new marker and does NOT need `EPOCH_ANCHOR_EN`.**
It reuses the existing SYNC beacon (force_always) + the existing framer strip. This
is a genuine advantage over the framing being "closed" in data mode.

Caveat [INFERRED]: force_always was validated as a *bring-up* aid, not soaked as a
*continuous* data-mode beacon. Two things to check on the bench: (a) the 1-in-32
beacon does not starve throughput below the FC credit window (the beacon consumes one
word slot per period — ~3% at SYNC_PERIOD=32); (b) `sync_resync` firing every period
does not itself reset the framer mid-packet — the strip logic `:325-331` claims it
fires "in an idle/gap slot," which must hold under real back-to-back traffic. This is
the one place Design B's premise leans on unproven runtime behaviour.

The alternative marker — the EPOCH training-exit content edge
(`WavD2DGpio_v2.v:857-939`, beacon-independent) — is available but is **one-shot per
training window, not periodic in data mode** (`DESKEW_ANCHOR_ROOTCAUSE.md:218-223`),
so it cannot drive a *continuous* data-mode search. Force_always is the right marker.

---

## 4. Risk / complexity — bounded honestly

**This is the most RTL work of the three.** Design A = one param + rebuild; Design C
= one param + rebuild; Design B = a new read-side FSM plus a datapath tweak, plus a
rebuild, plus new sim coverage.

- **Scope:** `tidelink_lane_deskew_v2.sv` `g_reanchor` block only (the search FSM +
  the `:1514` offset-add). **No change to `WavD2DGpio_v2` datapath** (it already
  exports `io_anchor_verified` and drives `sync_obs_clr`) and **no change to the
  framer** (force_always + strip already exist). So it is a **local_overrides change
  to one file**, plus setting `io_swi_sync_force_always_in=1` in the recipe. That is
  a real advantage — the blast radius is one generate block.
- **What could break:**
  - *Live-link un-shift* (`:1426-1430`): the search MUST perturb only in the
    inter-beacon idle gap and only against a failing anchor. If SEARCH ever nudges a
    LOCKED/validated link it will *cause* drops. Mitigated by the LOCKED state never
    re-entering SEARCH except on a proven verify-loss. **Highest risk item.**
  - *Winscan autonomy:* `io_anchor_verified` is *also* the winscan `WS_FINALIZE`
    release gate (`:26-27`, `axi_chiplet_controller.sv ws_verify_q`). A search FSM
    that toggles `reanchored`/clr in data mode could re-trigger or stall the winscan
    FSM. Must confirm the winscan is quiesced (post-bring-up) before the search runs,
    or gate the search to DATA mode only.
  - *Timing:* the `rd_ptr - (lane_off + srch_off_delta)` add is one extra small adder
    in the per-lane read-pointer path (out_clk = `gpiorx_0_io_link_clk`, the slow
    ÷16 word clock) — negligible. The FSM is slow-clocked. No timing concern
    [INFERRED — the word clock is ~link/16, huge margin].
  - *Search non-termination / thrash:* bounded by `±W` window, one-lane-at-a-time,
    and a hard attempt cap → fall back to plain `reanchored` (today's behaviour). Never
    worse than the status quo.
- **Sim coverage:** none of `cocotb/tidelink_top_pair_wordskew`, `phy_rx_deskew`,
  `tidelink_phy_align_calibrator` drives a *data-mode re-anchor search*
  (`DESKEW_ANCHOR_ROOTCAUSE.md:281-283`). New directed tests required: (a) inject a
  wrong-slot capture, assert SEARCH converges to `io_anchor_verified`; (b) inject a
  mid-session drift, assert re-lock; (c) assert a LOCKED link is never perturbed. This
  is real verification cost the other two designs do not carry.

---

## 5. Predicted hardware outcome + the single confirming measurement

**Predicted outcome [INFERRED]:**

- On a board state that lands in the **wrong-slot** class (die_b `0x24→0x5c`,
  `WavD2DGpio_v2.v:14-18`): Design B **converges the offending lane and delivers**,
  where a naive re-latch re-lands wrong — this is Design B's unique win.
- On the **07-22 masked-lane state** (§1.2): Design B **changes nothing** — the
  active lanes already validate; the four masked lanes stay zero. Delivery stays
  broken until Design A unmasks+trains all 8. **Conceded.**
- Against **within-bring-up drift**: Design B converts "first packet crosses, next
  two don't" into sustained delivery *provided* force_always's continuous-beacon
  behaviour is benign (§3 caveat).

**The single confirming measurement (one bench read, disambiguates everything):**

> With `io_swi_sync_force_always_in=1` in DATA mode, read **`io_anchor_verified`**
> (winscan obs / `axi_chiplet_controller.sv ws_verify_q`, surfaced at the WINSCAN_OBS
> APB slot) **on the non-delivering direction.**
>
> - **`io_anchor_verified == 1` while data does NOT cross** ⇒ the active lanes are
>   correctly assembled (as the 07-22 decode already showed) — **the deskew is not
>   the bug; Design B cannot help; the failure is masked-lane loss (→ Design A) or
>   framer/FC.** This is the *expected* result for the 07-22 state and would **kill
>   Design B as the primary fix.**
> - **`io_anchor_verified == 0` while `reanchored == 1`** ⇒ a genuine mis-anchor
>   (wrong-slot/drift) the current one-shot latch cannot repair — **exactly the class
>   Design B's validated search targets.** This would **justify Design B.**

This read costs nothing (force_always + one APB read) and is the honest gate:
**run it before committing any RTL.** If it reads 1-on-a-dead-link (the 07-22
prediction), Design A is the answer and Design B should be shelved to a
second-phase drift/wrong-slot hardening.

---

## 6. Concession, stated plainly (as the coordinator asked)

The 07-22 ground-truth slice decodes to **four byte-exact active lanes + four
by-design-zero masked lanes** — the 0xE4 mask, not a deskew shear. On that state:

- `reanchored=1 span=0` is **correct, not vacuous**;
- the deskew has **nothing to re-anchor** — its offsets are already right;
- the four masked lanes carry **zero on the wire**, so **no re-anchor search can
  assemble an 8-lane word from four trained lanes**;
- therefore **if the shear is untrained-lanes (which the decode says it is),
  `LANE_MASK=0xFF` (Design A) makes Design B unnecessary for this failure.**

Design B earns its place only for the **separate** wrong-slot / data-mode-drift
classes, and only **after** Design A has trained all 8 lanes — otherwise a validated
search on four lanes still cannot deliver an eight-lane payload. **Do Design A first;
Design B is the durable second-tier hardening, not the headline fix.**
