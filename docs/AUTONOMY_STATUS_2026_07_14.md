# TideLink Autonomy — Status & Analysis Brief (2026-07-14, RESOLVED 2026-07-16)

**Read `docs/AUTONOMOUS_BRINGUP.md` first** (the mechanism). This doc is the state of
play, the measured numbers, what is REFUTED, and the open question.

---

## 0. ✅ RESOLVED (2026-07-16) — ZERO-POKE AUTONOMY DELIVERED ON SILICON

**The autonomy channel gap is CLOSED.** Branch `wip/b2a-fix` @ `cd2db38`
(worktree `td-bisect/b2a-fix`, off `0044bef`), netlist-verified, zero-poke autonomous soak:

| channel | drain-guard baseline (0044bef) | **b2a-fix (cd2db38)** |
|---|---|---|
| link / anchor | 10/10 | **10/10** |
| A→B data (byte-exact) | 7/10 | **10/10** |
| B→A data (byte-exact) | **0/10 HARD-DEAD** | **10/10** ✅ |
| doorbell | 4/10 | **10/10** |
| both dies anchored | — | **rea_a=rea_b=1 every cycle (no peer-starvation)** |

**N=40 CERTIFIED (2026-07-16): 39/39 valid cycles, 100% ALL channels, CP 95% CI
[91.0%, 100%]** — link 39/39, A→B 39/39, B→A 39/39, doorbell 39/39, ALL-4 39/39.
(40 cycles run; cycle 2 = `POR-FAIL (a board did not return)` — a power-cycle
INFRASTRUCTURE flake, excluded as a non-test, not a link/data failure.)
Earlier N=10/10 (CP [69.2%,100%]) reproduced. The lower bound now clears 90%.

**Root cause (silicon-confirmed, clean exclusively-leased bench, reproduced ×2):** NOT the
FSM anchor-lottery (§3), NOT the eye. The master die_a's **winscan FSM LIVELOCKS** in data
mode — it reaches a good anchor (fcsm=4, rea=1) then advances SETTLE→FINALIZE and **tears
down its own FC** (fcsm 4→0), repeating, which perpetually disrupts its RX-commit so it
never commits incoming B→A data. `winscan_done` never stably sets (only blips at fail-open).
The `0x210C=0` disarm parks the churning FSM (→WS_IDLE) and B→A recovers byte-exact.

**Fix = event-gated RETIRE-AUTONOMY:** a sticky one-shot latches on `reanchored && fcsm==4`
(held ~160 ms « the ~2.8 s churn onset), drops the effective `autonomy_armed` term, and
DISARM-PARKs the FSM — autonomously replicating the proven `0x210C=0` escape hatch. Keeps
the anchor (sticky), per-episode re-arm on training rise (avoids the ws_kicked_q trap),
`RETIRE_EN=1` (F4 tapeout param; NOT yet plumbed to `tidelink_top` — ASIC to-do).
BUILD KNOB: **must `export TIDELINK_PHY_V2=1`** or the build silently falls back to the V1
flist and ships a fix-less bitstream (retire block is inside `ifdef TIDELINK_PHY_V2`).

Everything below (§1–§7) is the pre-resolution analysis, kept for provenance. §3's
"physical placement lottery" was the ANCHOR story; the delivered blocker was the CHANNEL
(RX-commit) livelock above. §5's "untested lever" and the WS_ANCHOR_EXTEND lever are moot.

---

## 1. The bottom line (pre-resolution; superseded by §0)

| | Status |
|---|---|
| **Manual recipe bring-up** (`rcp()`, autonomy OFF) | **Works, deterministic.** N=40 fresh-POR: link + A→B + B→A + doorbell. Zero failures. |
| **Autonomous zero-poke bring-up** | ~~**NOT reliable. ~25–35% both-dies-OK.**~~ → **RESOLVED, see §0: 10/10 all channels.** |

**A manual recipe is not the deliverable.** Hardware autonomy is a hard requirement —
now met on silicon (§0).

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

## 4b. ⚠️ THE BIGGEST LEAD — `set_bus_skew` was SILENTLY DEAD in every build

Found 2026-07-14. **The one constraint that bounds inter-lane RX skew has never been
applied.** In every build, both dies:

```
CRITICAL WARNING [Constraints 18-611/612] set_bus_skew: list of objects specified for
option 'from' contains '8' objects of types '(port)' other than the types
'(pin,cell,clock)' supported by the constraint.  The constraint will not be applied.
    die_a  pynq_z2_tidelink_timing.xdc:220
    die_b  pynq_z2_tidelink_timing.xdc:232
```

`set_bus_skew` accepts only **(pin,cell,clock)** — it was written
`-from [get_ports {pad_rx[*]}]`, matched nothing, and was discarded. Vivado emits a
*CRITICAL WARNING*, not an error, and ships a bitstream without it.

**Why nobody noticed:** the `set_max_delay` on the *adjacent line* uses the **identical**
`-from [get_ports {pad_rx[*]}]` and is perfectly legal (`set_max_delay` *does* accept
ports). The two lines look symmetric. They are not.

**Why this is the biggest lead:** the XDC comment directly above it reads —

> *"(3c) **THE key build-to-build determinism constraint.** set_bus_skew forces Vivado to
> EQUALISE the pad_rx[0..7] → capture delays to within 2 ns of each other. **The defect is
> per-lane VARIANCE** (some lanes land in the calibrator window, others don't, **and which
> is which changes every build**)."*

That diagnosis is *correct* — and the constraint written to fix it has been dead the whole
time. **Inter-lane RX skew has been UNBOUNDED in every bitstream ever built.** This is
precisely the mechanism behind the rebuild lottery in §2 (identical RTL, rebuild moved
die_a 15% → 35%).

**Fixed (44b85d4):** sourced from the IBUF output pins (`pad_rx_IBUF[n]_inst/O`) on both
targets, plus `verify_build.sh` check (g), which now FAILS the build gate on any dropped
constraint (proven to have teeth — it fails the current build, 6 dropped lines per target).

**NOT YET PROVEN.** Nobody has built with a *live* skew constraint, let alone measured
autonomy on it. **This is the experiment to run first**, ahead of everything else in §5.

## 5. The other untested lever

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
