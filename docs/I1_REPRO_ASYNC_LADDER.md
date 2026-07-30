# I1 `cr_seen=0` Sim-Repro — Async Ladder Results & Structural Finding

Status: **runnable env + climbed ladder + honest verdict** (branch `sim/i1-repro-async-ladder`,
no push, no HW). Verification lens. Date: 2026-07-30.

Builds directly on `docs/I1_SIM_REPRO_PLAN.md` (the fidelity-gap table F1-F9, the 5-rung ladder,
the §5 instrument-trust gate). This doc records what the ladder actually produced when driven to
completion in VCS against the real 2-die `tidelink_top` pair.

---

## TL;DR (honest verdict)

- **A faithful, FCSM-keyed `cr_seen=0` RED was NOT achieved.** Across the full explored envelope
  (shared clock → split async clocks + reset skew + clock ppm + wire skew + the 40 ns ratio +
  re-sweep churn + narrow validation windows + **staggered role_lock**), **`cr_seen` behaves
  identically for `FCSM_SRC=deps` and `FCSM_SRC=local`.**
- The env is **real and trustworthy**: the instrument-trust positive controls all pass — the TB can
  and does read `cr_seen=1` in GREEN, un-bypassed, via **real CR-handshake validation** (not the
  calibrator bypass). See §3.
- Where the sim *does* reach a sustained `cr_seen=0`, it is a **calibrator training-mode rendezvous
  failure that is provably FCSM-independent** — `deps` and `local` are **bit-identical**, down to the
  per-router-input grant counts (§4). 
- There is a **structural reason no L6-keyed `cr_seen=0` RED can exist** (§5): `cr_pkt_seen_rx` is a
  *state-independent* broadcast-RX latch; the L6 gate only ANDs a min-emit count onto the *state-1→2
  exit*, which fires only **after** a peer CR is already seen. In the `cr_seen=0` regime (no peer CR
  ever seen) the L6 precondition is never met, so `deps` and `local` are identical **by construction**.
- **Implication:** this refutes "the L6 hold starves the sideband → `cr_seen=0`" as the *cause* of the
  silicon signature, and is consistent with the `e79a5b8` commit's own leading hypothesis — the
  byte-identical I1/v1/v2 silicon signature is the fingerprint of a **stale packaged IP** (the
  eth-chiplet builds from an IP-XACT copy with `FPGA_SKIP_IP_VERIFY=1`), i.e. the RTL under test on
  silicon likely differs from the RTL in the flist. No RTL sim, however faithful, reproduces a
  packaging-path defect.

---

## 1. What was built (the runnable env)

`cocotb/tidelink_fcsm_cr_seen0/` — forked from the proven `tidelink_fcsm_silicon_ratio` DUT (real
2-die `tidelink_top` pair, real `WlinkTxRouter` round-robin, broadcast RX CR-detect, local_overrides
FCSM 0-4). Deltas that make the un-bypassed cold bring-up feasible & observable:

- **Local `tb_top.sv` variant** with hierarchical `defparam` knobs (guarded, default-off):
  - `TB_CAL_HOLD_CYCLES` — shrink the calibrator S_HOLD dwell. **Required**: the default
    `HOLD_CYCLES = 8*128*64 = 65536` link-word-clocks ≈ **8.4 ms** sim (link word clk ≈ 128 ns), far
    past any feasible poll window. S_VALIDATE still gates on the **real** sideband `cr_pkt_seen` — this
    is *not* `tb_early_exit_force_q`, the cal↔cr coupling is intact (F4 done right).
  - `TB_CAL_VAL_TIMEOUT` — S_VALIDATE window width.
  - `TB_CAL_VAL_TIMEOUT_TO_DONE` — override the V2 `VAL_TIMEOUT_TO_DONE=1` give-up-to-S_DONE
    (set 0 to force re-sweep churn, matching the FPGA `else calibrator).
  - `TB_SPLIT_CLK` (F6) — the SLAVE die runs on **independent** `s_hclk`/`s_ref_clk` oscillators.
- **`SplitPairV2TB`** harness (in `test_cr_seen0.py`): drives the slave clocks at a `DIE_CLK_PPM`
  offset, applies `RESET_SKEW_NS` POR skew, and **staggers role_lock** by `ROLE_STAGGER_NS` (the
  calibrator auto-arms on `role_locked`, so this offsets the two dies' whole training timelines — the
  real staggered-deploy condition).
- **Edge-triggered witnesses** (`Witness`): `pkt_is_cr_pkt` pulse counts per die (independent of the
  sticky latch), and **per-router-input grant counts** (`txrouter.auto_in_{0..4,6}_advance`) — the
  starvation witness. Plus X-masking guard on `SWI_LANE_STATUS`, and `cr_pkt_seen_rx` cross-check
  against the APB bit.
- **Oracle on the silicon 4-tuple** (`cr/crack/cal/fcsm`) read from BOTH the APB surface and the
  hierarchical latch, sampled on BOTH dies.

Build recipe (deps must be populated — `git submodule update --init deps/`, or symlink each empty
`deps/<name>` to a populated checkout; then `source ./set_env.sh; export TIDELINK_PHY_V2=1`).

---

## 2. The ladder (every rung run in VCS)

| Rung / config | clock | knobs | `deps` | `local` | note |
|---|---|---|---|---|---|
| **0** bypass baseline | shared | `CAL_BYPASS=1` | cr=1 cal=1 | (n/a) | positive control PASS (cr_pulse=1) |
| **1a** un-bypassed, GREEN | shared | `CAL_HOLD=1024` | **cr=1 cal=1 fcsm=4** (real validate @200µs) | **cr=1 cal=1 fcsm=4** | **no split** |
| **1b** + churn + narrow win | shared | `VAL=512 VAL_TO_DONE=0` | cr=1 (real validate) | cr=1 (real validate) | **no split** |
| **2** split clock, mild | async | `ppm=1000 skew=3µs` | cr=1 cal=1 fcsm=4 | cr=1 cal=1 fcsm=4 | async visible (crpulse m=4 s=3), still GREEN |
| **3** split + churn + narrow | async | `ppm=2000 VAL=32 skew=12µs VAL_TO_DONE=0` | cr=1 (validate @130µs) | cr=1 (validate @130µs) | **no split** — peer-aware S_HOLD + drift re-align |
| **4** staggered role_lock | async | `ROLE_STAGGER=200µs VAL=256 churn` | **cr=0 sustained** | **cr=0 sustained** | cr=0 but **deps==local BIT-IDENTICAL** — invalid RED |
| **4b** stagger=100µs | async | same | cr=0 (churn) | cr=0 (churn) | identical |

The `deps` GREEN converges by **real CR-handshake validation** (calibrator `S_VALIDATE` confirmed by
`cr_pkt_seen`, `fcsm→4`), not the timeout give-up and not the bypass — so rungs 0-3 are a genuine,
un-bypassed GREEN oracle. The split only ever appears as **both dies failing together** (rung 4), never
as `deps`-GREEN/`local`-RED.

---

## 3. Instrument-trust gate (plan §5) — results

| # | Check | Result |
|---|---|---|
| 5.1 | Positive control: TB reads `cr_seen=1`, `cal_done=1` in GREEN | **PASS** (rung 0: cr=1 cal=1; rung 1a un-bypassed: cr=1 cal=1 fcsm=4) |
| 5.2 | RED keyed on `FCSM_SRC` alone | **FAIL to demonstrate** — no config makes `cr_seen` flip with `FCSM_SRC`; every `cr_seen=0` state is `deps`≡`local` |
| 5.3 | `pkt_is_cr_pkt` pulses in GREEN, never in RED | GREEN: **pulses** (cr_pulses ≥ 1). "RED": never pulses — but the RED is FCSM-independent |
| 5.4 | Router grant-starvation witness | Live; sideband **not** starved (fair round-robin; deps==local grant counts to the digit) |
| 5.5 | Refuted emit-gate fix stays RED | **N/A** — no faithful FCSM-keyed RED exists to test (see §5) |
| 5.6 | No X-masking (`SWI_LANE_STATUS` clean) | **PASS** — status reads clean hex (`0x66830000`, `0x05890000`, `0x40020000`), never X |

Trust-gate bottom line: **(a) deps = GREEN: YES. (b) override = RED: NO. (c) refuted fix stays RED:
N/A. (d) positive controls: YES.** A RED that satisfies all four does not exist in this env.

---

## 4. The FCSM-independence evidence

Rung 4 (`ROLE_STAGGER=200µs`, churn, narrow window) drives a **sustained** `cr_seen=0` on both dies.
The `deps` and `local` runs are **bit-identical**, including the per-router-input grant counts:

```
LOCAL  FINAL [m] cr=0 cal=0 fcsm=1 cal_st=SWEEP 0x40020000 cr_pulses=0
              grants[AXI(0-4)=12581 sideband(6)=2516 detail={0:2517,1:2516,2:2516,3:2516,4:2516,6:2516}]
DEPS   FINAL [m] cr=0 cal=0 fcsm=1 cal_st=SWEEP 0x40020000 cr_pulses=0
              grants[AXI(0-4)=12581 sideband(6)=2516 detail={0:2517,1:2516,2:2516,3:2516,4:2516,6:2516}]
```

Identical to the count. The sideband **wins** 2516 grants (it is *not* starved) but `cr_pulses=0` — the
CRs it emits never cross, because both calibrators are perpetually anti-phased in training (PRBS on the
wire, FC data mux-blocked). The FCSM L6 gate has **zero** effect on this.

---

## 5. Why no L6-keyed `cr_seen=0` RED can exist (structural)

`cr_seen` is the register `cr_pkt_seen_rx` in the sideband FCSM:

```verilog
// local_overrides/WlinkGenericFCSM.v
wire pkt_is_cr_pkt   = auto_rx_in_sop & auto_rx_in_valid & (auto_rx_in_data_id == swi_cr_id); // :201
cr_pkt_seen_rx <= pkt_is_cr_pkt | cr_pkt_seen_rx;                                              // :210 (sticky)
```

It is **state-independent**: it latches the instant this die's RX decodes *one* peer CR, no matter what
FCSM state anything is in. It depends **only** on whether a peer CR physically crossed the wire.

The L6 gate is on the **state-1 → state-2 exit**:

```verilog
wire [2:0] _GEN_34 = (crack_pkt_seen_tx_demet | cr_pkt_seen_tx_demet) & socl_l6_cr_emit_gate_ok
                     ? 3'h2 : state;   // :312  — requires peer-CR/CRACK-seen AND count>=32
```

The min-emit count is **ANDed onto the already-required peer-seen term**. Therefore:

- In any `cr_seen=0` state, **no peer CR has been seen**, so the state-1 exit is blocked by the
  *peer-seen term alone* — exactly as in `deps`. The `count>=32` term is irrelevant. `deps` (exit on
  first peer CR) and `local` (exit on first peer CR **and** 32 own emits) are **identical while no peer
  CR exists**.
- The only regime where they diverge is **after** a peer CR is seen — i.e. `cr_seen` is already 1
  (GREEN). There the L6 hold can only **delay** the *state* exit / the *bilateral* completion; it can
  never un-see a CR that already crossed.

So the L6 gate can delay GREEN, never cause a permanent `cr_seen=0`. This matches the `e79a5b8` commit's
own admission ("the gates can only DELAY a state exit … which is why the falsified v1 (ungate) could not
have caused a premature-exit failure").

---

## 6. What the silicon signature really requires (two un-modelled couplings)

The silicon 4-tuple is `cr=0 crack=0 cal=0 fcsm=0` (`SWI_LANE_STATUS=0x00100000`). Two fidelity gaps
remain that this env does **not** close — both are calibrator/bring-up couplings, not the FCSM:

1. **`cal_done=0`.** The V2 calibrator (`ifdef TIDELINK_PHY_V2`, `axi_chiplet_controller.sv:5819`) has
   `VAL_TIMEOUT_TO_DONE=1` — it **gives up to terminal S_DONE on S_VALIDATE timeout**, asserting
   `calibration_done`. So in V2 sim `cal_done` reaches 1 even with no CR. The silicon `cal_done=0`
   matches the **`else` (FPGA) calibrator** (`VAL_TIMEOUT_TO_DONE` default 0, `VALIDATION_TIMEOUT=2e6`)
   — i.e. re-sweep forever. (Modelled here via `TB_CAL_VAL_TIMEOUT_TO_DONE=0`, which reproduces a
   sustained `cal=0` — but still FCSM-independently.)
2. **`fcsm=0`.** The sideband FCSM leaves state 0 only when `en_ff2_tx_demet` (= `io_app_enable`,
   `swi_enable`) is synced. On silicon the bring-up is **autonomous** — `app_enable` is coupled to
   `cal_done` (lltx gated by calibration). This cocotb harness uses the **SW bring-up recipe**
   (`do_to_data_mode` force-asserts `swi_enable` via the LL bootstrap write), which **severs** that
   coupling, so the sideband reaches `fcsm=1` regardless of `cal_done`. Reproducing `fcsm=0` needs the
   autonomous `BYPASS_AUTONEG=0` path (real autoneg/I2C/mask-handshake) — a separate, larger effort,
   and still calibrator/autoneg-driven, **not** the FCSM L6 gate.

---

## 7. Recommendation

- **Do not** triage the I1 `cr_seen=0` blocker as an FCSM-L6 problem on the strength of a sim RED —
  none exists, and the structure of `cr_pkt_seen_rx` says none can. The `e79a5b8` emit-gate fix would
  (correctly) green a *state-stuck* sim livelock but cannot move `cr_seen`.
- **Prioritise the packaging-path check** the fix commit already flags: after
  `make package_eth_chiplet_ip` (`TIDELINK_PHY_V2=1`), confirm the netlist
  `imp/fpga/eth_chiplet_ip/src/WlinkGenericFCSM*.v` byte-matches the edited source. A stale IP-XACT
  copy under `FPGA_SKIP_IP_VERIFY=1` reproduces the byte-identical I1/v1/v2 silicon signature with no
  RTL cause at all.
- If an RTL sim of the silicon failure is still wanted, the tractable next step is the **autonomous
  bring-up** path (`BYPASS_AUTONEG=0`) with the FPGA-flavour calibrator (`VAL_TIMEOUT_TO_DONE=0`,
  large `VALIDATION_TIMEOUT`) — to reproduce the `cal_done=0`/`fcsm=0` *coupled* deadlock — but note in
  advance that it, too, will be calibrator/autoneg-keyed, not FCSM_SRC-keyed.

---

## 8. Reproduce

```bash
# deps populated + source ./set_env.sh; export TIDELINK_PHY_V2=1; export PATH=$VCS_HOME/bin:$PATH
cd cocotb/tidelink_fcsm_cr_seen0
make rung0                                    # bypass positive control (PASS: cr=1)
# un-bypassed GREEN oracle (real validation, fcsm->4):
make FCSM_SRC=deps  CAL_BYPASS=0 CAL_HOLD_CYCLES=1024 TESTCASE=test_cold_bringup_cr_seen \
     MODULE=test_cr_seen0 SIM_BUILD=sim_build_green
# FCSM-independence demo (both cr=0, bit-identical) — run for deps AND local:
make FCSM_SRC=local CAL_BYPASS=0 CAL_HOLD_CYCLES=1024 CAL_VAL_TIMEOUT=256 CAL_VAL_TIMEOUT_TO_DONE=0 \
     SPLIT_CLK=1 DIE_CLK_PPM=1000 ROLE_STAGGER_NS=200000 POLL_CHUNKS=500 \
     TESTCASE=test_diag MODULE=test_cr_seen0 SIM_BUILD=sim_build_stag_local
make FCSM_SRC=deps  ... (same knobs) ... SIM_BUILD=sim_build_stag_deps   # -> identical grant counts
```
