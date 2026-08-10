# I1 FCSM bring-up regression — UVM `tidelink_top_system` sim-repro

Branch: `sim/i1-repro-uvm-topsystem` (worktree of `main`@18491ef). Sim + analysis
only — no hardware, no FPGA build, no push. VCS 2022.06-SP2, `TIDELINK_PHY_V2=1`.

## TL;DR

- **The de-quarantined UVM `tidelink_top_system` paired-die env elaborates + runs
  for the first time with the current V2 RTL**, driven from `flists/tidelink_fpga_v2.flist`
  with a compile-time `FCSM_SRC` knob that points the 5 muxed AXI FC nodes
  (`WlinkGenericFCSM{,_1..4}`) at either the pristine `deps` submodule or the
  shipping `local_overrides` I1 override.
- **A faithful, override-SPECIFIC RED is reproduced** — but NOT with a staggered
  reset. The role-lock stagger reproduces a *generic* handshake failure (#14b)
  that `deps` and the override hit **byte-identically**, so it does not
  discriminate I1. The override-specific failure needs the **marginal-link
  retry** condition (periodic re-bring-up), exactly as the dedicated cocotb env
  `tidelink_fcsm_bringup_race` (from the refuted fix branch) found.
- Under periodic re-bring-up the shipping override **livelocks the shared-arbiter
  SIDEBAND node below LINK_IDLE** while `deps` recovers — the panel's
  grant-starvation mechanism, observed directly on the sideband.
- **Instrument-trust gate (c) FAILS**: the refuted emit-gate fix
  (`fix/i1-fcsm-bringup`@e79a5b8) **GREENs** this sim. Per the gate's own rule
  ("if it greens, the sim is blind"), that means this env reproduces the
  emit-gate arbiter-starvation *hypothesis*, which silicon evidence **refutes** —
  it is NOT proof of the true silicon I1 failure (which e79a5b8's own analysis
  attributes to stale packaged IP, above RTL and unreproducible in RTL sim).

## The instrument

- DUT: two `tidelink_top` instances back-to-back through the GPIO-PHY pad
  crossover (the real paired-die stack: FIFO + FC adapter + XHB500 + Wlink + PHY).
- `FCSM_SRC` (Makefile): `deps` = FCSM 0-4 from `deps/axi-chiplet-controller`
  (recovery-stripped baseline); `local` = FCSM 0-4 from `src/rtl/local_overrides`
  (the shipping I1 override, emit-HOLD armed from reset); `fix` = FCSM 0-4 from the
  e79a5b8-patched copies (`uvm/tidelink_top_system/i1fix_fcsm/`, hold open until
  first LINK_IDLE). FCSM_5=deps, FCSM_6=local in **all** variants — the only delta
  is the AXI nodes' recovery/L6-L7 hold footprint. `SOCL_L6_MIN_CR_EMITS` left at
  its shipping `8'd32`.
- Test: `test_top_i1_fcsm_bringup` — V2 bring-up (calibrator sim-bypass →
  role-lock → wait cal_done → LL bootstrap to data-mode), then an observation
  window with optional **periodic re-bring-up** (`+REBRINGUP_HCLK=N`: every N
  hclk drop+restore the LL enable on both dies, resetting the FC nodes to state 0
  — the sim stand-in for a marginal-link retry). Optional `+ROLE_STAGGER_CYC` for
  the reset-stagger lever.
- Oracle: the TideLink-FCSM 4-tuple mirrored onto `tb_if` from
  `…u_wlink.tl2wl.wlink_tidelinktl.{state,cr_pkt_seen_rx,crack_pkt_seen_rx}` and
  the calibrator `cal_calibration_done_w`. **`wlink_tidelinktl` is
  `WlinkGenericFCSM_6` — the SIDEBAND node**, and its `cr_pkt_seen_rx` is the
  exact source of `SWI_LANE_STATUS[23]` (via `obs_cr_pkt_seen_rx_w`) AND the
  calibrator's S_VALIDATE oracle. So the oracle is the register the silicon bench
  reads. Primary GREEN/RED = does the sideband FCSM reach **LINK_IDLE (state≥4)**.
- Calibrator sim-bypass = `tb_early_exit_force_q=1` on both `u_calibrator`s (the
  same bypass `tidelink_top_pair_v2` uses; the S_VALIDATE 2M-cycle timeout is
  unreachable in sim). It does NOT inject CR packets and does NOT touch the FCSM
  CR path, so the FCSM handshake remains a faithful observable. Applied to BOTH
  dies and ALL variants equally; no `COCOTB_RESOLVE_X`, real reset values.

## Results (oracle = sideband FCSM_6 max state; LINK_IDLE = 4)

| Config | benign (no retry) | marginal re-bring-up @800 hclk |
|---|---|---|
| **deps** (baseline) | GREEN — max_fcsm A=6 B=6 | GREEN — max A=6 B=4 (recovers) |
| **override** (shipping I1) | GREEN — max A=5 B=6 | **RED — max A=2 B=2 (STUCK < LINK_IDLE)** |
| **fix** (e79a5b8) | — | GREEN — max A=6 B=4 (recovers) |

Cadence crossover (max_fcsm A,B per die; RED = either die stuck < LINK_IDLE=4):

| re-bring-up period (hclk) | 400 | 800 | 1600 | 3200 | 6400 |
|---|---|---|---|---|---|
| **deps**     | (6,4) G | (6,4) G | (6,6) G | (6,5) G | (6,4) G |
| **override** | (2,5) **RED** | (2,2) **RED** | (5,6) G | (5,5) G | (6,6) G |
| **fix**      | (6,4) G | (6,4) G | — | — | — |

The override livelock is confined to the ~400–800 hclk marginal window (deepest
at 800, both dies stuck at state 2) and clears by ≥1600 — cadence-dependent, i.e.
a real marginal-link livelock, not a mere consequence of compiling the HOLD in.
deps and the fix reach LINK_IDLE at every cadence.

Role-lock stagger lever (for contrast — the WRONG mechanism): at every tested
stagger 500…20000 cyc, **deps and override are byte-identical RED**
(`A[fcsm=1 cr=0] B[fcsm=1 cr=0 cal=1]`) → generic #14b reset-sequencing failure,
NOT override-specific. Stagger=0 → both GREEN.

All tuples are clean binary (cr/crack/cal ∈ {0,1}, state an integer 1/2/4/6) — the
RED is a functional livelock (sideband stuck at state 2), **not** a gate-level
X-init artifact.

## Instrument-trust gate

- **(a) deps under benign reset = GREEN** ✅ — both dies reach LINK_IDLE (6,6).
  The env can bring the link up.
- **(b) override under the silicon-like (marginal) condition = RED** ✅ — the
  sideband livelocks at state 2, never LINK_IDLE, while **deps recovers under the
  identical cadence** (the override-specific contrast). cr_pkt_seen still latches
  in sim (the peer emits under the zero-BER bypass), so the sim RED tuple
  (sideband stuck state 2, cr=1) is *milder* than the silicon tuple (fcsm=0,
  cr=0) — same family (FCSM cannot reach LINK_IDLE ⇒ no data mode ⇒ RX all-zeros),
  fidelity gap noted.
- **(c) refuted emit-gate fix must STAY RED → it GREENs** ❌ — e79a5b8 (open the
  AXI-node emit HOLD until first LINK_IDLE) recovers the sideband to LINK_IDLE
  (A=6 B=4), same as deps. **Per the gate's rule this env is "blind": the RED it
  reproduces is the emit-gate arbiter-starvation livelock, which the fix targets —
  and silicon says that fix does not recover I1.** So this repro corroborates the
  emit-gate *hypothesis* in sim; it is not evidence of the true silicon cause.
- **(d) positive control** ✅ — the env observes `cr_pkt_seen_rx=1` (deps/override
  benign), clean binary, ruling out X-pessimism masking.

## Mechanism (what the RED shows)

The shipping override AXI FCSM 0-4 hold state 1→2→3→4 until they have emitted
`SOCL_L6_MIN_CR_EMITS=32` CR + `SOCL_L7_MIN_CRACK_EMITS=8` CRACK of their **own**
packets. All 7 FC nodes (5 AXI + TideLink + sideband) are time-multiplexed onto
one link by the fair round-robin `WlinkTxRouter`. Under periodic re-bring-up each
drop zeroes the emit counts, so between drops a node cannot accrue 32/8 own emits
→ the AXI nodes never leave the credit-exchange states and **monopolize the
arbiter**, starving the sideband node (`WlinkGenericFCSM_6`) of grants. The
sideband — byte-identical RTL in all three builds — is left stuck at state 2,
never reaching LINK_IDLE, so `SWI_LANE_STATUS` never completes and the link never
enters data mode. `deps` FCSM 0-4 carry no such gate (leave state 1 on the FIRST
peer-seen CR), release the arbiter promptly, and the sideband reaches LINK_IDLE.
The e79a5b8 fix decongests the AXI nodes and reproduces the deps behaviour → the
sideband recovers. This is precisely the panel's "L6 hold starves the sideband
grant on the shared round-robin" mechanism, observed on the sideband itself.

## Workarounds tested vs the RED

- **Revert FCSM 0-4 to deps**: GREEN (max A=6 B=4). Proven.
- **e79a5b8 emit-gate fix** (open AXI-node HOLD until LINK_IDLE): GREEN. Proven —
  decongests the arbiter. *But it GREENs, so it cannot be the discriminating
  workaround the task envisioned (which required the emit-gate fix to stay RED).*
- **Gentler cadence** (larger re-bring-up period): override recovers at large
  periods (see period sweep) — confirms it is the marginal cadence, not a compile
  artifact.

## Honest bottom line

A faithful, override-SPECIFIC RED **was** reproduced in the UVM env (deps GREEN /
override RED / benign both GREEN, under a marginal-link retry), and its mechanism
is exactly the shared-arbiter sideband grant-starvation the panel predicted. **But
the env fails instrument-trust gate (c)**: the refuted emit-gate fix greens it.
So this is a faithful reproduction of the emit-gate arbiter-starvation
*hypothesis* — which silicon refutes — not proof of the true silicon I1 failure.
Consistent with e79a5b8's own conclusion, the true I1 signature is most likely a
stale-packaged-IP / build artifact above the RTL, which no zero-BER RTL sim
(faithful or not) can reproduce. The role-lock reset stagger reproduces only the
unrelated generic #14b failure.

## Reproduce

```
source ./set_env.sh; export TIDELINK_PHY_V2=1; export PATH=$VCS_HOME/bin:$PATH
cd uvm/tidelink_top_system
# baseline (must GREEN):
make compile FCSM_SRC=deps
sim_build_deps/simv +UVM_TESTNAME=test_top_i1_fcsm_bringup +REBRINGUP_HCLK=0
# override marginal (RED):
make compile FCSM_SRC=local
sim_build_local/simv +UVM_TESTNAME=test_top_i1_fcsm_bringup +REBRINGUP_HCLK=800 +OBS_CYC=60000
# deps marginal (recovers, GREEN) — same cadence:
sim_build_deps/simv +UVM_TESTNAME=test_top_i1_fcsm_bringup +REBRINGUP_HCLK=800 +OBS_CYC=60000
# refuted fix (GREENs → trust-gate c fails):
make compile FCSM_SRC=fix
sim_build_fix/simv +UVM_TESTNAME=test_top_i1_fcsm_bringup +REBRINGUP_HCLK=800 +OBS_CYC=60000
```
(runtime needs `export DESIGNWARE_HOME=$VIP_HOME`.)
