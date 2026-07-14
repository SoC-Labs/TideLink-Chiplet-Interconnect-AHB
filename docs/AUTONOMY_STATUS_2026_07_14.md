# TideLink Autonomy — Status & Analysis Brief (2026-07-14)

**Read `docs/AUTONOMOUS_BRINGUP.md` first** (the mechanism). This doc is the state of
play, the measured numbers, what is REFUTED, and the open question.

---

## 1. The bottom line

| | Status |
|---|---|
| **Manual recipe bring-up** (`rcp()`, autonomy OFF) | **Works, deterministic.** Currently certifying at N=40 fresh-POR cycles: link + A→B + B→A data byte-exact + doorbell. **Zero failures so far.** |
| **Autonomous zero-poke bring-up** | **NOT reliable. ~25–35% both-dies-OK.** This is the gap. |

**A manual recipe is not the deliverable.** Hardware autonomy is a hard requirement.
The certification number above is recipe-mode and must not be read as autonomy.

---

## 2. Measured autonomy (all N=20, armed-only denominator)

| Arm | die_a OK | die_b OK | both-OK |
|---|---|---|---|
| iter6 baseline (old build) | 15% | 45% | 11% |
| **control: rebuild only, lever OFF** | **35%** | **65%** | **25%** |
| iter7 = same rebuild + `WS_ANCHOR_EXTEND=7` | 45% | 70% | 35% |

**Read that table carefully.** The headline "3× lift" from the `WS_ANCHOR_EXTEND` lever
was **mostly the REBUILD**. Identical RTL, lever off, only different placement/routing,
moved die_a 15% → 35%. The lever's incremental +10pp is **within noise at n=20**.

**Two conclusions forced by this:**
1. **Autonomy is BUILD/PLACEMENT-dependent.** An autonomy % is only meaningful
   relative to a **fixed bitstream**. A logic threshold cannot move on a rebuild — a
   physical margin can.
2. `WS_ANCHOR_EXTEND` is **UNPROVEN**. Keep it (it is parameterised, `=0` is exact
   baseline, sim-regression-clean) but **do not sell it as the fix**. Resolving a 10pp
   effect needs n≈100+ at a fixed build.

---

## 3. Root cause (best current hypothesis — 4-agent assessment)

**PHYSICAL, not logic.** A residual fabric LUT (`wpa_gap_q[3]_i_2`, fanout 372) sits on
the per-lane RX **capture-clock** tree (inside `WavD2DGpioRx.v`, the WavClockMux) →
**placement-varying inter-lane skew** → a build lottery. This is then **amplified by the
all-lanes-AND commit gate** (`all_sync_seen`, deskew:1350): one marginal lane kills the
whole anchor, and each retry re-pulses the clear so evidence never accumulates.

**Supporting evidence:**
- Rebuild-sensitivity (above) — a logic threshold cannot move on a rebuild.
- `pblock_rx_act` (pins the active-lane capture flops into the pad clock region)
  existed **only in die_b** — and die_b consistently outperformed die_a (65–70% vs
  35–45%). Strongly suggestive.

**The trap that has burned two sessions:** the calibrator eye (`0x2150`) reads **16/16
wide on every active lane of die_a** — yet die_a had the WORST autonomy. That eye
measures **BIT-capture** margin at the settled tap. It does **NOT** capture cross-lane
**SYNC-detect** margin, which is the thing that actually varies with placement. *A wide
eye does not exonerate the lane.*

---

## 4. REFUTED — do not spend time here

- ❌ **"die_a NODONE is a winscan FSM bug."** The FSM **never ran** (`autonomy_armed=0`,
  because `NEGO_CFG` POR was `0x00`). Months of winscan fixes targeted an FSM stuck in
  WS_IDLE. **Always read `NEGO_CFG` back.**
- ❌ **"The slave's lane mask is stuck at 0xFF."** `TD_AUTO_LANE_MASK_E4` sets `0xE4` on
  **both** dies. Verified in RTL.
- ❌ **"winscan-stop is broken."** It works as designed — it cannot lock when a lane is
  physically down.
- ❌ **`WS_ANCHOR_EXTEND` is the fix.** Its own control run killed it (see §2).
- ❌ **The eye is fine, so the failure is logic.** Too hasty — see §3.
- ❌ **`feat/epoch-anchor-ab`** — gates on the *identical* cross-lane AND with **fewer**
  chances. Do not build it.
- ❌ **IDELAY tuning.** IDELAY is instantiated and routed on all 8 lanes, but its range
  (~2.34 ns) is **inert** against a 426 ns UI at div-2. ~Zero expected gain.

---

## 5. The untested lever (this is where I'd start)

The current bitstream (`wip/phase2-pblock`) is the first to carry **every** fix at once,
including the physical one aimed squarely at the lottery:

- **`pblock_rx_act` mirrored into die_a** (it previously existed only in die_b).
  Verified effective in the routed design: the `gpiorx_{2,5,6,7}/link_data_pad_clk_reg`
  capture flops are pinned into `CLOCKREGION_X0Y0`, +0.247 ns slack. Both targets now
  symmetric.
- Plus: XHB comb-loop fix, a2l ACK-ptr, fc_cfg preempt, credit (`fe_tx_credit_max_eff`),
  zero-poke `NEGO_CFG_RESET=0x61`, `WS_ANCHOR_EXTEND` lever.
- Build integrity verified: **0 combinational loops**, `NEGO_CFG_RESET` = `1100001` in
  the packaged IP, V2 flist confirmed, distinct md5s per die.

**AUTONOMY HAS NEVER BEEN MEASURED ON THIS BITSTREAM.** Only recipe mode has. That is
the single most obvious next experiment: run an autonomous soak (arm `NEGO_CFG=0x61`
instead of `rcp()`) on this exact build and compare against the 25–35% baseline. It is a
like-for-like test of whether the die_a pblock moved the physical margin.

---

## 6. Questions I want an analyst to attack

1. **Is the all-lanes-AND the right commit gate at all?** It converts a per-lane marginal
   probability `p` into `p^4` at the link level, with no partial credit and no per-lane
   retry. Is there a defensible design where a lane that has *already* confirmed its
   sticky `sync_seen` is not thrown away when a sibling lane forces a retry? (i.e. make
   the clear **per-lane** rather than global, or make the sticky survive the retry clear.)
2. **Why does each anchor-retry re-pulse the clear?** (`WS_FIN_CLRLOW` path.) That turns a
   retry budget into N independent lotteries instead of one accumulating window. Is
   there a correctness reason (anti-poison?) or is it incidental?
3. **Can the residual LUT be removed from the RX capture-clock tree?** If the capture
   clock rides a fabric LUT, inter-lane skew is at the mercy of placement. What would it
   take to get that net onto a proper clock resource on every lane, both dies?
4. **Is there an instrument that measures cross-lane SYNC-detect margin directly?** We
   have a bit-capture eye (`0x2150`) that demonstrably does not predict autonomy. The
   absence of the right instrument is why this has been guessed at for months.
5. **Reduced-lane fallback:** would dropping to fewer active lanes (relaxing the AND)
   be viable? CAUTION: lane 7 carries the A→B ACK/credit return path — it cannot simply
   be masked out.

---

## 7. Method rules that have repeatedly paid off here

- **Verify the instrument before theorising about the DUT.** Three separate conclusions
  in this campaign were overturned by checking the measuring device (most recently, an
  "all channels fail 0/6" result that was entirely a test-harness bug — the silicon was
  byte-exact).
- **Always run the control.** The lever's "3× lift" evaporated against a rebuild-only
  control.
- **An autonomy % is meaningless without naming the bitstream it was measured on.**
- Cocotb does **not** recompile on an RTL edit (it tracks only `tb_top.sv`). `rm -rf
  sim_build` when A/B-ing RTL, or you will test a stale binary and "prove" the wrong thing.
