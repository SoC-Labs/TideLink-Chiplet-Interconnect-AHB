# TideLink TESTING runbook (V2 / zero-poke era)

One page: how to run the sim gate, what each suite proves, the tb hook
glossary, the HW regression flow, and the canonical pass criteria. This
codifies the procedure every 2026-06/07 debug loop re-derived by hand.

---

## 1. Sim gate — `make sim_gate`

```sh
source ./set_env.sh          # VCS + cocotb env (SIM=vcs)
make sim_gate                # all 8 suites, ~25-40 min (fresh compiles)
make sim_gate_quick          # smoke: skips t31/t32/t33 (the slowest)
```

Behaviour: fail-fast per suite, all suites always run, per-suite log in
`imp/sim_gate/<suite>.log` (+ `<suite>.status`), final PASS/FAIL table,
non-zero exit if anything failed. The gate **deletes its sim_build dirs
first** — the cocotb Makefiles do not track RTL as compile deps, so a cached
`simv` silently tests stale RTL (observed 2026-07-03).

| Suite | Where / module | Proves |
|---|---|---|
| `t31_autonomous_training_exit` | `tidelink_top_pair` `test_31` (V2 flist, `BYPASS_AUTONEG=0`, `SHORT_CAL_HOLD=64`, `sim_build_l4`) | full zero-poke chain a–h: training-exit rendezvous, SYNC, winscan, real fch bootstrap (`0x27f09/01/07`, bit0=swi_enable), bilateral data cross |
| `t32_die_a_first_zombie_retry` | `tidelink_top_pair` `test_32` (**`BYPASS_AUTONEG=1`**, own `sim_build_l5`) | die_a-first arm order + zombie-peer trap auto-retry (R5). The test arms autoneg itself and asserts the FSM parks in ST_BYPASS pre-arm — do not run it on a `=0` build |
| `t33_arm_stagger_episode_bind` | `tidelink_top_pair` `test_33` (**`BYPASS_AUTONEG=1`**, shares `sim_build_l5`) | FIX-1/2/3 (2026-07-03) arm-stagger episode binding: (a) seconds-stagger private-episode rebind (stale `winscan_done` rebound; final episode `0x21B8[2]=0`, rea=1, credit>0, data both ways), (b) mid-scan kick-loss → abort-restart fires (`0x21B8[7:4]`>0), (c) zero-stagger symmetric regression — all under the D2 permanent idle-gated beacons |
| `t30_autonomous_fc_handoff` | `tidelink_top_pair` `test_30` (shares `sim_build_l4`) | autoneg FSM drives the FC data-mode handoff the manual recipe does |
| `v2_pair_data` | `tidelink_top_pair_v2` `EPOCH_PROFILE=zero` | bilateral V2 link-up + M↔S packet delivery |
| `v2_autonomous_sync_detect` | `tidelink_top_pair_v2` `EPOCH_PROFILE=zero` | autoneg drives the full SYNC-detect config (R8/SYNCTOL/LANEMASK/lock-thresh) + manual path bit-identical at `nego_en=0` |
| `v2_winscan_fsm` | `tidelink_top_pair_v2` `EPOCH_PROFILE=zero` | on-chip IDELAY WINSCAN FSM centres, re-anchors, gates the handoff, stays dormant unarmed |
| `v1_elab` | `tidelink_top_pair` build-only, `TIDELINK_PHY_V2=0`, fresh `sim_build_v1elab` | V1 flist still compiles + elaborates clean (catches V2-only \`ifdef breakage of the V1 arm) — no test is run |

The exact proven incantation the tp suites wrap (for hand-runs):

```sh
cd cocotb/tidelink_top_pair
TIDELINK_PHY_V2=1 BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" SIM_BUILD=sim_build_l4 \
COCOTB_RESOLVE_X=ZEROS make MODULE=test_31_autonomous_training_exit
# test_32: BYPASS_AUTONEG=1 SIM_BUILD=sim_build_l5, otherwise identical
```

Policy (MEMORY: sim-gate every HW deploy): **`make sim_gate` must be green
before any farm build kicks.**

## 2. TB hook glossary

Silicon dwells are ~0.25–0.5 s; sims force the short arm. Two kinds of hook:

**Compile-time defines** (pass via `EXTRA_DEFINES`):

| Hook | What it shrinks / forces | Safe value |
|---|---|---|
| `TB_TOP_SHORT_CAL_HOLD` | calibrator `HOLD_CYCLES` defparam on both dies (lock-hold before cal_done) | `64` (the gate's proven value) |
| `TB_TOP_SHORT_CAL_DWELL` | calibrator `DWELL_CYCLES` defparam (per-tap dwell) | leave unset unless a test demands it |

**Runtime deposit hooks** (`reg ... = 1'b0` in the RTL, cocotb deposits 1;
RTL-constant 0 on silicon, so they synthesize away):

| Hook (hierarchical reg) | What it selects when 1 | SIM / silicon value |
|---|---|---|
| `tb_fch_dwell_short_q` (axi_chiplet_controller) | `FCH_SWRESET_DWELL_SIM` — fch bootstrap swreset dwell | 4095 / 12.5e6 (~0.25 s) |
| `tb_winscan_dwell_short_q` (axi_chiplet_controller) | `WINSCAN_DWELL_SIM`/`SAMP_SPACE_SIM`/`FIN_WAIT_SIM`/`WS_CLR_HOLD_SIM` — per-tap winscan dwell + F3b FINALIZE rendezvous + FIX-3 retry clear-low hold | 32 & 100k & 512 / 25e6 (~0.5 s) |
| `tb_ws_anchor_short_q` (axi_chiplet_controller) | `WS_ANCHOR_TIMEOUT_SIM` — F4 FINALIZE anchor-gate timeout (FIX-3: ×4 waits worst-case — 3 clear-retries then fail-open) | 50k / 15e6 (~0.3 s) |
| `tb_retry_backoff_short_q` (tidelink_autoneg) | `T_RETRY_BACKOFF_SIM` — R5 zombie-retry backoff | 20k / 15e6 (~0.3 s) |
| `tb_early_exit_force_q` (tidelink_phy_align_calibrator) | forces `EARLY_EXIT_ON_ALL_LOCKED` — lanes freeze on first lock instead of the full scan | 0/1, sim-only |

Set them per-die from cocotb, e.g.
`dut.u_master.u_chiplet_controller.tb_fch_dwell_short_q.value = 1`.

## 3. HW flow (bridge1, PYNQ pair via mapstone-dev)

1. **Sim gate first** — `make sim_gate` green (policy).
2. **Build** the pair (`make build_pair_farmed`, ~hrs) with **`TIDELINK_PHY_V2=1`
   in the environment**.
3. **Provenance checks** (each has burned a debug day):
   - *V2 banner*: build log must show
     `TIDELINK_PHY_V2: -verilog_define injected into run ...`
     (`fpga/build_design.tcl:293`). Missing ⇒ silent V1 fallback ⇒ dead link.
   - *WINSCAN_CELLS > 0*: the winscan FSM must survive synthesis — count
     `ws_*`/winscan cells in the routed design (known-good ≈ 210; 0 = the
     "optimised out" failure, TIDELINK_PHY_V2 not propagated to package_ip).
   - *bit2bin stale-.bin gotcha*: boards flash the **.bin**, not the .bit.
     A rebuilt .bit with a stale .bin deploys yesterday's image —
     always re-run the conversion (stage_v24 does) and verify the md5 you
     flash matches the manifest of the .bit you just built.
4. **Stage**: `bash pynq_host/scripts/stage_v24.sh` (bit→bin + manifests +
   ship to mapstone-dev).
5. **Lease etiquette**: `fpgahub pair lease acquire bridge1 --ttl <s>` and
   verify the answer says **granted**, not queued; release with the token
   when idle; never leave a keepalive running. (The regression scripts do
   this themselves unless `--no-lease`.)
6. **Run the regression scripts** (`fpga/hw_regression/`, on the lab host):
   - `./zeropoke_proof.sh a|b|both [--stagger SEC]` — one fresh-POR zero-poke
     bring-up, machine-parseable a–h scorecard, exit 0 iff (h) data passed.
   - `./zeropoke_soak.sh N` — N fresh-POR cycles, arm order alternating
     a,b,... with the last cycle `both`; per-cycle scorecard + N/M summary.
   - `./snapshot.sh <tag>` — full standard debug-register dump from BOTH dies
     to a timestamped file; run it at every interesting failure point.
   - `./linkhold_soak.sh MIN --manual|--autonomous` — held-link time
     stability: a txburst every 30 s for MIN minutes, per-burst byte-exact
     score (the V1 saga died time-correlated at ~20 min — this is the test
     for that class).
   - `./td_v2_regress.sh` — the manual-recipe A→B suite (link/eye/deskew/data).
   - Safety: reads are throttled (PS wedges under dense mmap); **never write
     `0x21B0`/`0x21B4`** once the on-chip winscan FSM owns them; die_b
     sending without credit can wedge die_b's PS.

## 4. Canonical pass criteria

- **Sim**: `make sim_gate` exits 0 (8/8 PASS in the summary table).
- **Zero-poke silicon** (`zeropoke_proof.sh`, both arm orders + `both`):
  every step a–h PASS within the ~4 min budget; (h) = 3/3 A→B bursts AND the
  B→A burst byte-exact; post-burst: no underrun/overrun, `long=0`,
  credit_max still sane.
- **Manual recipe never regresses**: `td_v2_regress.sh` all 4 tests PASS on
  every new build (eye-intact check).
- **Time stability**: `linkhold_soak.sh 30` 100% byte-exact (target; never
  yet run on silicon).

## 5. Known-good register values (V2, zero-poke era, mask 0xE4)

| Register | Addr | Known-good | Notes |
|---|---|---|---|
| NEGO_CFG | `0x44032090` | `0x61` | arm value AND POR default (nego_en+force_lock+mask_hs) |
| NEGO_TRAIN_CFG | `0x4403210C` | `0x0001` | arm value: train_auto_en (write NOTHING else) |
| ROLE_STATUS | `0x44032084` | bit1=1 both | role_locked (W1S, POR-only clear) |
| R8 SWI_TRAINING_MODE | `0x44032100` | `0x1D` in SYNC phase → `0x15` in data mode | [0]train [1]recal [2]insert [3]force [4]robust; D2 (2026-07-03): insert+robust STAY 1 permanently on the autonomous path (never-blind-OFF) — only force drops. Manual recipe still writes `0x10` at enter_data_mode (unchanged) |
| SYNCTOL | `0x44032128` | `0x000005e4` | tol=5, lane mask 0xe4 |
| LANEMASK | `0x44030214` | `0x0000e4e4` | rx/tx lane mask |
| lock-thresh | `0x44032160` | `0x55555555` | per-lane Hamming thresh 5 |
| SWI_LANE_STATUS | `0x44032108` | lk⊇0xe4, cal=1, fcsm=4, cr=1, crack=1 | fcsm[19:17]=4 bilateral = link-data |
| OBSCAL cstate | `0x44032198` | `[3:0]=4` | training-exit walks 6→4 |
| sync_seen | `0x4403215C` | `[7:0]=0xe4`, marker 0x5F | all 4 active lanes armed |
| SWI_EPOCH_STATUS | `0x44032140` | bit0=1 | reanchored (deskew anchor engaged) |
| WINSCAN_OBS | `0x440321B8` | `0x570000n1` (n = abort count ≥0) | [0]done=1 [1]degenerate=0 [2]anchor-timeout=0 [3]anchored-late (diag) [7:4]abort-restart count (FIX-1; >0 = a training fall was consumed mid-scan), marker 0x57. **Stagger discriminator**: poll [0] on BOTH dies during bring-up — the die whose done rises SECOND is the (formerly) starved one |
| OBS_FC_CREDIT | `0x4403219C` | marker 0xFC, credit_max ≈ 0x1f, ≠0 | credit by VALUE — `0x2108[31]` only catches ==0 |
| FCCTRL | `0x44030208` | `0x00027f07` | bootstrap walk `0x27f09→0x27f01→0x27f07`, bit0=swi_enable |
| RX slices (force-SYNC) | `0x4403212C..38` | L2=`0x5B4C` L5=`0xB5A6` L6=`0xD3C4` L7=`0xF1E2` | byte-exact ⇒ eye/PHY good |
| A→B test packet | GP1 `0x84010000..` | `0x00240000 0xcafe0001 0xcafe0002` | GP1 aperture pops on read — read each word ONCE |

Data apertures: TX `0x84000000`, RX `0x84010000` (GP1 split — GP0
`0x44xxxxxx` data accesses hang the PS). `0x440320D4` RXW is the FC-REPLAY
pointer, **not** delivered app data.
