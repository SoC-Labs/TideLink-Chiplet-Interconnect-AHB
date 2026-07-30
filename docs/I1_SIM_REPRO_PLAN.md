# I1 Bring-up Failure — Faithful Sim-Repro Plan (`cr_seen=0`)

Status: **analysis + plan** (branch `analysis/i1-sim-repro`, no push, no HW).
Author lens: verification / repro-environment strategy.
Date: 2026-07-30.

---

## 0. The failure we must reproduce (silicon-established, 07-30)

Re-pointing the five AXI flow-control nodes (`WlinkGenericFCSM{,_1,_2,_3,_4}`, the
`wlink_axi{aw,w,b,ar,r}FC` instances) from the **deps** (recovery-stripped) copies to the
**`src/rtl/local_overrides`** (recovery) copies — commit `b98b944` — **breaks bring-up on the
2-board KR260 eth-chiplet bench**. Both dies read:

```
SWI_LANE_STATUS = 0x00100000
  => cr_seen=0  crack_seen=0  cal_done=0  fcsm=0   (only bit[20]=a2l_app_valid set)
```

`deps/` FCSM brings up (`fcsm=4`). An emit-gate (state-exit) fix was **built, silicon-bench-tested,
and REFUTED** — so the break is **AT or BEFORE the state-1 CR emit**: `cr_seen` never even flickers.

The single highest-leverage deliverable is a **sim that actually reaches `cr_seen=0`** (a RED that
flips GREEN on the deps FCSM), so candidate fixes triage in sim (seconds) instead of ~1.5 h board
cycles. **A sim that GREENs on a fix silicon rejects is worse than no sim.**

---

## 1. Why `cr_seen=0` is hard to reach in sim (the mechanism)

`cr_seen` is the RTL register **`cr_pkt_seen_rx`** in `WlinkGenericFCSM.v` (the **sideband** `tl2wl`
node — `u_wlink.tl2wl.wlink_tidelinktl`, router input `auto_in_6`). It is:

- a **sticky latch**: `cr_pkt_seen_rx <= pkt_is_cr_pkt | cr_pkt_seen_rx;`
  (`local_overrides/WlinkGenericFCSM.v:783`), cleared only by `io_rx_reset` or
  `~en_ff2_rx_demet` (RX app-enable low);
- set by **one** intact peer CR: `pkt_is_cr_pkt = auto_rx_in_sop & auto_rx_in_valid &
  (auto_rx_in_data_id == swi_cr_id)` (`:191,:201`) — **CRC-independent**, off the **broadcast** RX.

Therefore, on any **zero-BER, zero-skew, single-shared-clock** sim wire, an intact CR is never
dropped, so the round-robin **always eventually** delivers one peer CR and `cr_seen` latches to 1.
**No amount of emit-gate tuning can hold `cr_seen` at 0 on a clean synchronous wire** — the emit gate
(`_GEN_34`, `:312`) can only `AND` onto the *already-required* peer-seen term, so it can only *delay a
`state` exit*; it has zero effect on whether a peer CR reaches the RX. This is exactly why the refuted
fix could not move silicon off `cr_seen=0`.

**To hold `cr_seen=0` faithfully, the peer's sideband CR must never reach this die's RX with a valid
SOP.** Only two RTL-visible routes do that:

- **Route A — peer never emits (`fcsm=0`).** The peer sideband FCSM never leaves state 0, so it never
  emits a CR. State 0→1 is gated by `en_ff2_tx_demet` (= `io_app_enable` synced to TX,
  `:688-692`), which is downstream of **cal/link-enable**. This matches the silicon `fcsm=0`.
- **Route B — CR corrupted on the wire.** Real inter-die skew / async clocks / BER corrupt the CR's
  SOP or `data_id` so `pkt_is_cr_pkt` never asserts. Requires a non-ideal wire.

The silicon signature is **`fcsm=0` + `cal_done=0`** ⇒ **Route A** is primary. And there is a proven
coupling that produces it:

### The coupling (evidence-backed)

1. `cal_done` needs the calibrator's `S_VALIDATE` to confirm. Its validation oracle is
   `cr_pkt_seen_i` = **`obs_cr_pkt_seen_rx_w`** = the **sideband** `cr_pkt_seen_rx`
   (`axi_chiplet_controller.sv:5974`, sourced `:6382`).
2. The sideband `cr_pkt_seen_rx` sets only when the **peer's** sideband node wins a grant on the
   **single round-robin `WlinkTxRouter`** (`Wlink.v:1458`; sideband = `auto_in_6`) and emits a CR.
3. The **5 AXI FC nodes are `auto_in_0..4` on that same router**. During cold bring-up (LL enabled,
   no AXI payload needed) **all six FC nodes enter state 1 and emit CR** — state 0→1 is gated on the
   *link* enable, not on AXI data.
4. **deps** AXI nodes are recovery-stripped: they leave state 1 on the *first* peer CR seen (no hold),
   so they stop contending quickly. **local_overrides** AXI nodes carry the **L6 gate**
   `socl_l6_cr_emit_gate_ok = (socl_l6_cr_emit_count >= SOCL_L6_MIN_CR_EMITS=32)` (`:287-288,:312`) —
   they **hold state 1 until they have emitted 32 of their OWN CRs**, and the count **resets to 0 on
   every `state!=1`** (`:817-827`), i.e. on every link re-bring-up. At the ~40 ns silicon link:app
   ratio the count may never reach 32 in a clean window, so the AXI nodes **hold state 1 and keep
   asserting `sop`** on the router far longer than deps.

⇒ **Hypothesis the faithful sim must test:** the local_overrides AXI nodes, holding state 1, **starve
the sideband `auto_in_6` of router grants** (round-robin, request = `sop`), so the sideband CR never
crosses ⇒ peer `cr_pkt_seen_rx=0` ⇒ peer `S_VALIDATE` never confirms ⇒ `cal_done=0` ⇒ `io_app_enable`
never stabilises ⇒ sideband FCSM stuck at state 0 ⇒ mutual `cr_seen=0 crack_seen=0 cal_done=0 fcsm=0`.
`SOCL_L6_MIN_CR_EMITS` is the lever; `deps` removes it (GREEN).

**The two knobs that DEFEAT this in every existing sim:**
- `tb_early_exit_force_q=1` (`force_calibrator_sim_bypass`) forces `cal_done=1` **regardless of
  `cr_pkt_seen`** — severs coupling step (1). The router competition becomes irrelevant to `cal_done`.
- **Shared `hclk`/`ref_clk` + `SKID_BITS=0` + zero BER** means the sideband CR is never dropped and
  the two dies' resets/training never genuinely race — so even a starved sideband eventually lands one
  CR and latches `cr_seen=1`.

---

## 2. Per-environment verdict — can it reach `cr_seen=0`?

| Env | Real 2-die muxed bring-up | Compiles local_overrides FCSM 0-4 | Real round-robin + broadcast RX | Reaches `cr_seen=0`? | Evidence |
|---|---|---|---|---|---|
| **cocotb `tidelink_fcsm_bringup_race`** (branch `fix/i1-fcsm-bringup`) | Yes — 2× real `tidelink_top` | **Yes** (`FCSM_SRC=local\|deps` sed knob) | Yes (real `WlinkTxRouter`) | **No — BLIND** | zero-BER shared-clock wire ⇒ one CR always lands ⇒ `cr_seen` latches 1; "marginal link" only toggles APB LL-enable (never drops wire words); runs a clean bring-up first; **asserts on `state==4`, never on `cr_seen`**. Doc `I1_FCSM_ROOTCAUSE_AND_FIX.md §6` admits `cr_seen=1` in RED. |
| **cocotb `tidelink_fcsm_silicon_ratio`** (in-tree) | Yes — 2× real `tidelink_top` | **Yes** (sed re-point deps→local for 0-4) | Yes | **No — BLIND to `cr_seen`** | `force_calibrator_sim_bypass()` forces `cal_done`; `do_role_lock`+`wait_cal_done`+`do_to_data_mode` do a **clean** bring-up, THEN injects an APB-toggle "marginal link"; observes **state-2 CRACK stall (L7)**, never state-1/`cr_seen` (L6). Its own histogram note: `1 => L6/CR gate binds` — never seen. |
| **UVM `tidelink_top_system`** | Yes (2× `tidelink_top`, PHY-pad crossover) | **No — deps** (`-y $(DEPS_DIR)/logical/wlink`, `Wlink.v` from deps) | Yes (but deps FCSM) | **No — and QUARANTINED** | `Makefile:363-385` "QUARANTINED … DOES NOT ELABORATE" (port drift vs pinned `axi_chiplet_controller`). "RX all-zeros" here is a **gate-level X-init** artifact (`Makefile:170-208`), *not* the FCSM bring-up bug. No local↔deps knob. `deps/` unpopulated in this worktree. |
| **UVM `tidelink_ptp_chain`** | Yes (4-die chain) | **No — deps** | Yes (deps) | **No — QUARANTINED** | `Makefile:783-801` identical quarantine. Same deps sourcing. |
| **UVM `tidelink_system` / `tidelink_integration`** | **No** — FC a2l→l2a behavioural loopback, no Wlink/PHY | No FCSM at all | No | **No — cannot** | `top.sv` headers: "FC TX→RX loopback". No Wlink instantiated. |
| sibling `nanosoc-ethernet-chiplet` `verif/g2_soc_pair` (cocotb) | Yes (2× `tidelink_top` via SoC) | **Partial** — `_6`+RxLinkLayer local, `_0..4` still **deps** | Yes | **No** (deps AXI nodes ⇒ no L6 hold) | `build/elab/tidelink_vcs.f:128-140`. Same partial profile as `tidelink_fpga.flist`. |

**Bottom line:** the *only* envs with the right DUT (real round-robin + broadcast RX + local_overrides
FCSM 0-4) are the two **cocotb pair** envs — and both are blind for the **same two structural reasons**
(forced `cal_done`; clean shared-clock wire; assert on `state`, not `cr_seen`). The UVM 2-die envs have
a real muxed link but compile **deps** FCSM, are **quarantined**, and their "all-zeros" is unrelated
gate X-init. **UVM is not a viable near-term `cr_seen=0` oracle.**

---

## 3. Fidelity-gap table — what a faithful `cr_seen=0` repro MUST model

| # | Fidelity requirement | Why it matters for `cr_seen=0` | `bringup_race` | `silicon_ratio` | UVM `top_system` | **Faithful repro** |
|---|---|---|---|---|---|---|
| F1 | **Real local_overrides FCSM 0-4** on the AXI path | The L6 hold is the RED lever | ✅ (`FCSM_SRC`) | ✅ (sed) | ❌ deps | ✅ (`FCSM_SRC=local`) |
| F2 | **Real `WlinkTxRouter` round-robin**, 6 FC nodes contending (`sop`=request) | Starvation of sideband `auto_in_6` is the coupling | ✅ | ✅ | ✅ (deps) | ✅ |
| F3 | **Real broadcast RX CR-detect** per `data_id` (`pkt_is_cr_pkt`) | The `cr_seen` observable itself | ✅ | ✅ | ✅ | ✅ |
| F4 | **Un-bypassed cal↔cr coupling** — `S_VALIDATE` gated on real `cr_pkt_seen`, `cal_done` NOT forced | Forcing `cal_done` severs coupling ⇒ `cr_seen` always latches | ❌ forces `cal_done` | ❌ forces `cal_done` | ❌ (gate TB) | ✅ **shrink `HOLD_CYCLES` via `defparam`, DO NOT set `tb_early_exit_force_q`** |
| F5 | **Cold bring-up** — observe `cr_seen` from POR, never a clean bring-up first | A prior clean bring-up latches `cr_seen=1` up front | ❌ clean-first | ❌ clean-first | n/a | ✅ POR → LL-enable → watch `cr_seen` |
| F6 | **Async 2-die clocks + reset skew + non-zero wire skew** | Real 2-oscillator race is what starves/corrupts at the 40 ns ratio; shared clock hides it | ❌ shared `hclk`/`ref_clk`, `SKID_BITS=0` | ❌ same | ❌ | ✅ per-die clocks w/ ppm offset; `SKID_BITS>0`; skewed reset deassert |
| F7 | **The ~40 ns silicon link:app ratio**, WITHOUT the APB-toggle "marginal link" crutch | The L6 32-emit window binds only at the slow ratio; the APB toggle is a modelled stand-in, not the real dynamic | ⚠ ratio yes, but via APB toggle | ⚠ same | ❌ | ✅ `REF_PERIOD_NS=40`, let real dynamics decide (no APB toggle) |
| F8 | **Oracle = `cr_seen`/`crack_seen`/`cal_done`/`fcsm`** (the silicon 4-tuple), not `state==4` | Must fail on the bit silicon reports | ❌ asserts `state` only | ❌ asserts `state` only | ❌ | ✅ assert the 4-tuple |
| F9 | **`SOCL_L6_MIN_CR_EMITS` compile-overridable** (currently hardcoded `8'd32`) | The ablation knob for the L6 hypothesis (mirror L7) | ❌ | ❌ | ❌ | ✅ add `\`ifndef SOCL_L6_MIN_CR_EMITS_VAL` |

The DUT rows (F1-F3) are **already satisfied** by the cocotb pair envs. The gap is entirely **F4-F9:
stimulus, clocking, oracle, and the L6 knob.**

---

## 4. The plan — stand up `cocotb/tidelink_fcsm_cr_seen0`

Fork the proven DUT (real 2-die `tidelink_top` pair + `WlinkTxRouter` + local_overrides FCSM), and
**replace the stimulus** with a cold, un-bypassed, async bring-up whose oracle is the silicon 4-tuple.
Scaffolding committed alongside this doc: `cocotb/tidelink_fcsm_cr_seen0/` (Makefile + test skeleton +
README). It reuses `tb_top.sv`/`pad_skid.sv`/`pair_v2_common.py` from `tidelink_fcsm_silicon_ratio`.

### 4.1 Ablation knobs (for triage by other engineers)

| Knob | Values | Purpose |
|---|---|---|
| `FCSM_SRC` | `local` (RED) / `deps` (GREEN) | primary RED↔GREEN switch (sed re-point of FCSM 0-4) |
| `SOCL_L6_MIN_CR_EMITS_VAL` | `32` (silicon) … `1` | sweep the state-1 CR-emit hold (the prime suspect). **Requires the F9 RTL change.** |
| `SOCL_L7_MIN_CRACK_EMITS_VAL` | `8` (default) / `32` | state-2 CRACK hold (already overridable) |
| `SOCL_FCSM_BRINGUP_HOLD_ALWAYS` | set / unset | re-test the **refuted** emit-gate fix against the faithful RED |
| `CAL_HOLD_CYCLES` | small (feasible) | `defparam HOLD_CYCLES` — shrink the S_HOLD dwell **without** forcing early-exit (keeps `S_VALIDATE` gated on real `cr_pkt_seen`) |
| `REF_PERIOD_NS` | `8` (fast) / `40` (silicon) | link:app ratio |
| `DIE_CLK_PPM` | `0` / e.g. `500` | per-die clock frequency offset (async 2-oscillator model) |
| `RESET_SKEW_NS` | `0` / e.g. `37` | inter-die POR deassert skew |
| `TB_TOP_SKID_BITS` | `0` / `1..N` | wire skew (non-ideal serial link) |

### 4.2 Fidelity ladder — climb until `cr_seen=0` appears (RED), keyed on `FCSM_SRC`

Each rung removes one "too clean" crutch. Run **every rung for both `FCSM_SRC=local` and `=deps`**;
the RED is the first rung where **`local` holds `cr_seen=0` for a sustained window while `deps` reaches
`cr_seen=1 & cal_done=1`** within a bound.

- **Rung 0 — GREEN baseline / instrument trust.** Cold bring-up, `FCSM_SRC=deps`, shared clock,
  fast ratio, calibrator bypassed. Assert `cr_seen` **reaches 1** and `cal_done=1`. *If this fails, the
  observable path is broken and every later RED is meaningless.* (See §5.)
- **Rung 1 — un-bypass the calibrator (F4).** Remove `force_calibrator_sim_bypass`; `defparam
  HOLD_CYCLES` small so `S_HOLD` is brief but `S_VALIDATE` still waits on real `cr_pkt_seen`. Cold
  bring-up (F5). Compare `local` vs `deps`. Expect `deps` GREEN; `local` **candidate RED** (if the
  starvation manifests even on a shared clock).
- **Rung 2 — async clocks + reset skew + wire skew (F6).** Per-die `hclk`/`ref_clk` with `DIE_CLK_PPM`
  offset, `RESET_SKEW_NS>0`, `TB_TOP_SKID_BITS>0`. This is the 2-oscillator race that most closely
  models the bench. Re-compare.
- **Rung 3 — silicon ratio, no APB crutch (F7).** `REF_PERIOD_NS=40` with rung-2 clocking, **no**
  periodic APB LL-enable toggle. Let the real L6 32-emit window bind. Re-compare.
- **Rung 4 — L6 sweep (F9).** With the RED established, sweep `SOCL_L6_MIN_CR_EMITS_VAL` 32→1 for
  `FCSM_SRC=local`; expect the RED to clear as the hold shrinks toward the deps behaviour — this
  *localises* the RED onto the L6 gate and gives the fix its target.

The first rung to produce the split is the faithful RED→GREEN oracle. Record which crutch's removal was
load-bearing (that is the fidelity bug the blind sims had).

### 4.3 The oracle (F8)

```python
# RED (FCSM_SRC=local): sustained silicon 4-tuple
assert cr_seen('m')==0 and cr_seen('s')==0
assert cal_done('m')==0 and cal_done('s')==0
assert fcsm_state('m')==0 and fcsm_state('s')==0       # never left state 0
assert (swi_lane_status('m') & 0xFFFFFFFF) == 0x00100000  # exact silicon word
# GREEN (FCSM_SRC=deps): converges within a bound
assert eventually(cr_seen('m')==1 and cr_seen('s')==1 and cal_done both ==1)
```

Read `cr_seen`/`crack_seen` from **both** `SWI_LANE_STATUS[23]/[24]` (APB, the silicon surface) **and**
the hierarchical `wlink_tidelinktl.cr_pkt_seen_rx` — they must agree (guards against an APB-mux bug
masking the RTL truth).

### 4.4 F9 — make `SOCL_L6_MIN_CR_EMITS` compile-overridable (no default change)

Mirror the existing L7 pattern so the ablation knob exists. **Behaviour-preserving** (default stays
`32`). To keep shipping RTL untouched, the env **sed-copies** the five FCSM files into its build dir and
patches only the localparam (see scaffolding Makefile). Patch shape:

```verilog
`ifndef SOCL_L6_MIN_CR_EMITS_VAL
 `define SOCL_L6_MIN_CR_EMITS_VAL 32
`endif
  localparam [7:0] SOCL_L6_MIN_CR_EMITS = `SOCL_L6_MIN_CR_EMITS_VAL;   // was 8'd32
```

---

## 5. Instrument-trust check — do NOT repeat the blind-sim mistake

The blind sims "confirmed" a fix silicon rejected because they never observed the bit that defines the
failure. Every one of these must pass before any RED is trusted:

1. **Positive control (can the TB see `cr_seen=1` at all?).** Rung 0 must show `cr_seen` transitioning
   0→1 and `cal_done` 0→1 in the GREEN case. A TB that can *never* show `cr_seen=1` is blind by
   construction.
2. **The RED is keyed on `FCSM_SRC`, nothing else.** Flip **only** `deps`↔`local`, everything else
   identical (same seed, clocks, ratio, skew); `cr_seen` must flip 1↔0. If the RED persists with
   `deps`, it is a TB artifact, not the FCSM.
3. **The CR actually crosses in GREEN.** Monitor `pkt_is_cr_pkt` (the *detect input*, not the sticky
   latch) **pulsing** on the RX in the GREEN case — proves the broadcast-RX + router path is live and
   the latch isn't stuck by X-init. In the RED case, `pkt_is_cr_pkt` must **never pulse** (peer never
   emitted / never granted) — that distinguishes Route A from a dead observable.
4. **Grant-starvation witness.** Log per-node router grants (`auto_in_N_advance`) during cold bring-up.
   RED must show the sideband `auto_in_6` grant-starved while `auto_in_0..4` hog; GREEN must show the
   sideband getting grants. This is the *mechanism* evidence, not just the symptom.
5. **The refuted fix must STAY RED.** Compile the emit-gate fix (`SOCL_FCSM_BRINGUP_HOLD_ALWAYS`
   unset — the shipping "fixed" default) against the faithful RED. **It must NOT green the RED** —
   because it only relaxes a `state`-exit `AND` term and cannot make a starved/never-emitted CR reach
   the RX. If it *does* green the RED, the sim is still blind (reproducing the emit-gate livelock, not
   `cr_seen=0`) — treat that as a fidelity failure, not a fix.
6. **No X-masking.** `SWI_LANE_STATUS` must read a clean `0x00100000` (not `0xXXXXXXXX`); if bits read
   X, the RED could be X-propagation, not the real deadlock (cf. the UVM gate X-init false lead).

---

## 6. Build / run recipe (once `deps/` is populated)

```bash
# In the worktree root:
git submodule update --init deps/axi-chiplet-controller deps/tidelink-phy deps/tidelink-gpio-phy
source ./set_env.sh
export TIDELINK_PHY_V2=1
export PATH=$VCS_HOME/bin:$PATH
cd cocotb/tidelink_fcsm_cr_seen0
rm -rf sim_build*
make rung0        # GREEN baseline + instrument-trust (must pass)
make green_deps   # FCSM_SRC=deps, cold, un-bypassed  -> EXPECT cr_seen->1
make red_local    # FCSM_SRC=local, cold, un-bypassed  -> TARGET cr_seen=0 sustained
make l6_sweep     # sweep SOCL_L6_MIN_CR_EMITS_VAL 32..1 (localises the RED)
make refuted_fix  # SOCL_FCSM_BRINGUP_HOLD_ALWAYS default -> must STAY RED
```

**This session did NOT close a live RED**: `deps/axi-chiplet-controller` and `deps/tidelink-phy` are
**un-checked-out** in this worktree (`git submodule status` shows `-`), so the flist cannot resolve
`WlinkGenericFCSM_5.v` / the PHY calibrator and VCS cannot elaborate. Populating submodules needs
network + touches shared `.git` state, and a full 2-die cold bring-up × the ladder is many sim-hours —
out of scope for this analysis pass. The scaffolding is written to run as-is once submodules exist.

---

## 7. Honest confidence

- **Diagnosis of the fidelity gap: HIGH.** Three independent RTL/env sweeps agree — `cr_seen` is a
  sticky latch that sets on one intact CR; both blind sims force `cal_done` (severing the cal↔cr
  coupling) and use a clean shared-clock wire; the calibrator `S_VALIDATE` oracle is provably the
  sideband `cr_pkt_seen`; the 5 local_overrides AXI nodes share the round-robin with the sideband and
  the L6 hold makes them contend longer. The reasons the blind sims *cannot* reach `cr_seen=0` are
  structural and certain.
- **That the faithful ladder WILL reach `cr_seen=0`: MEDIUM.** Route A (starvation → cal never
  validates → `fcsm=0`) is the leading, testable mechanism, but whether router starvation actually
  manifests may require the async 2-oscillator race (rung 2/3) — a shared-clock sim might still let one
  CR through. Rungs 2-3 exist precisely to cover that; if even they don't split, that is itself a
  finding.
- **Residual risk — the bug may be below RTL.** The `bringup_race` doc flags a second refutation path:
  the KR260 eth-chiplet packages a **stale IP-XACT copy** with `FPGA_SKIP_IP_VERIFY=1`, so an edited
  `WlinkGenericFCSM*.v` may **never reach the netlist**. If the faithful sim reaches `cr_seen=0` and a
  fix greens it in sim but silicon still fails, **verify the netlist actually contains the edit** before
  trusting the fix. No RTL sim can catch a packaging-path defect.
- **UVM route: LOW near-term value.** De-quarantining `tidelink_top_system` + re-pointing it to
  local_overrides + resolving TB port drift + checking out deps is strictly more work than extending
  the cocotb pair, for the same DUT. Revisit only if the cocotb ladder cannot produce the split.

---

## 8. Key file references

| Thing | Location |
|---|---|
| State-1 CR-emit exit gate (`_GEN_34`, L6) | `src/rtl/local_overrides/WlinkGenericFCSM.v:312-313` |
| `SOCL_L6_MIN_CR_EMITS = 8'd32` (hardcoded — F9 target) | `…/WlinkGenericFCSM.v:64,287-288` |
| `cr_pkt_seen_rx` sticky latch | `…/WlinkGenericFCSM.v:210,777-785` |
| `pkt_is_cr_pkt` broadcast detect | `…/WlinkGenericFCSM.v:191,201` |
| State 0→1 entry (`en_ff2_tx_demet`) | `…/WlinkGenericFCSM.v:688-692` |
| `WlinkTxRouter` round-robin (sideband=`auto_in_6`, AXI=`0..4`) | `deps/axi-chiplet-controller/logical/wlink/WlinkTxRouter.v`; inst `local_overrides/Wlink.v:1458,2101-2127` |
| Calibrator `S_VALIDATE` oracle = sideband `cr_pkt_seen` | `local_overrides/axi_chiplet_controller.sv:5974,6382` |
| `HOLD_CYCLES` param (shrink, don't force early-exit) | `local_overrides/tidelink_phy_align_calibrator_v2.sv:311,1235` |
| `tb_early_exit_force_q` (the knob to AVOID) | `…/tidelink_phy_align_calibrator_v2.sv:220`; `pair_v2_common.py:192` |
| `SWI_LANE_STATUS` bit map (`0x00100000`=bit20 only) | `local_overrides/axi_chiplet_controller.sv:2711-2733` |
| Blind env (state-2 stall) | `cocotb/tidelink_fcsm_silicon_ratio/` (in-tree) |
| Blind env (emit-gate livelock, `FCSM_SRC` knob) | `cocotb/tidelink_fcsm_bringup_race/` (branch `fix/i1-fcsm-bringup`) |
| Refuted emit-gate fix | commit `e79a5b8`; `SOCL_FCSM_BRINGUP_HOLD_ALWAYS` |
| The I1 re-point commit | `b98b944` |
