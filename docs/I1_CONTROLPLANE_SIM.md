# I1 control-plane bootstrap — UVM `tidelink_top_system` faithful sim-repro

Branch: `sim/i1-controlplane-repro` (from `sim/i1-repro-uvm-topsystem`, itself a
worktree of `main`@18491ef, which carries the I1 override `b98b944`). Sim +
analysis only — no hardware, no FPGA build, no push. VCS 2022.06-SP2,
`TIDELINK_PHY_V2=1`.

## What this attempt tested that the prior ones could not

The silicon ILA (2026-07-30) re-rooted I1: the AXI-FCSM 0-4 override
(`flists/tidelink_fpga_v2.flist` re-point deps→`src/rtl/local_overrides/`) leaves
**`role_locked = 0`** and **`swi_training_mode_r = 0`**, so the calibrator arm

```
nego_en & role_locked & swi_training_mode_r   (axi_chiplet_controller.sv ~1648/2233)
```

never fires and the calibrator never sweeps (`cal_state = 0`, `ever_swept = 0`).
This is a **control-plane** (register/FSM) failure, not the analog forwarded-clock
capture the earlier cocotb/UVM sims could not model. Those earlier sims **forced
`cal_done`** (`tb_early_exit_force_q`) and used the sideband-FCSM CR state as the
oracle — they bypassed exactly the arm logic under suspicion. `role_lock`,
`swi_training_mode_r`, `nego_en`, the autoneg FSM and the calibrator arm are ALL
RTL logic a faithful sim CAN observe, so the deadlock — IF it is a direct RTL
consequence of the FCSM swap — should reproduce with the calibrator NOT bypassed.

## The instrument (what is new here)

Built on the paired-die UVM env (two real `tidelink_top`, GPIO-PHY pad crossover,
I²C cross-connected, APB masters, `FCSM_SRC` compile knob deps|local|fix).

- **Calibrator NOT bypassed** — run with `+NO_CAL_BYPASS`. `cal_state` leaving 0
  is a faithful, FCSM-independent ARM oracle: the calibrator's `S_IDLE(0) →
  S_ARM(1)` transition is `trigger_now = role_locked_rise_eff | …`
  (`tidelink_phy_align_calibrator_v2.sv:840`), i.e. it leaves state 0 the moment
  `role_locked` rises, on the forwarded `rx_link_clk` (which the paired pad
  crossover DOES model — each die's gated `pad_clk_tx` is the peer's
  `pad_clk_rx`).
- **New control-plane observables** mirrored onto `tb_if` from the REAL controller
  nets on both dies (`tb/top.sv`): `role_lock_reg`, `swi_training_mode_r`,
  `nego_en`, `mask_hs_gate_open`, `mask_hs_match`, `calibrator_role_locked`,
  `cal_state_w`, `u_autoneg.state_r`.
- **New test `test_top_i1_controlplane`** drives the real bring-up
  (`kr260_eth_bringup.py` + `verif/g2_soc_pair`): ROLE_CFG=0x02(master)/0x03(slave)
  @0x2080, SWI_TRAINING_MODE @0x2100, and (auto mode) NEGO_CFG=0x61.
    - `+CP_MODE=manual` (nego_en=0): SW ROLE_CFG then R8 training. `mask_hs_bypass`
      is strapped open by `tidelink_top` (mgate=1), so role_lock latches on the SW
      write; the calibrator arms on the role_locked edge. Clean positive control.
    - `+CP_MODE=auto` (`+NEGO_AUTO_STRAP`, nego_en=1, silicon-faithful): the POR
      value NEGO_CFG=0x61 is presented as a strap (force survives the `force_poreset`
      re-arm, since `nego_cfg_reg<=NEGO_CFG_RESET` on POR), autoneg runs over I²C,
      host also writes ROLE_CFG (as the real recipe does).
- Oracle: GREEN iff, on BOTH dies, `role_locked==1` AND `cal_state` ever left 0.
  `[CPSIG]` emits the full arm-chain vector for the external deps-vs-local diff.

## Results — the arm-chain vector, deps vs override

`A[rl tr nego mgate mmatch calRL cal nst]` (rl=role_locked, tr=swi_training_mode_r,
cal=cal_state, nst=autoneg state).

### MANUAL path (nego_en=0) — positive control PASSES, NO SPLIT

| checkpoint | deps | local (override) |
|---|---|---|
| t0-pre        | `rl=0 tr=0 cal=0 nst=6` | `rl=0 tr=0 cal=0 nst=6` |
| post-role-lock| `rl=1 tr=0 calRL=1 cal=7 nst=6` | `rl=1 tr=0 calRL=1 cal=7 nst=6` |
| post-train-on | `rl=1 tr=1 cal=7 nst=6` | `rl=1 tr=1 cal=7 nst=6` |
| final `[CPSIG]` | `rl=1 tr=1 calArmed=1 calMax=7` | `rl=1 tr=1 calArmed=1 calMax=7` |
| verdict | **GREEN** | **GREEN** |

Both dies, both variants: role_lock latches, training sets, and the **un-bypassed**
calibrator genuinely ARMS and runs — `cal_state` leaves S_IDLE(0) on the
role_locked edge, sweeps (S_ARM 1 → S_SWEEP 2), advances to S_PROBE(7) and parks
in **S_HOLD(6) = "locked locally"**. **Byte-identical between deps and override.**
The positive control passes (deps GREEN proves the TB observes a real calibrator
arm+lock, not a forced one), and the override does NOT move any arm-chain signal.

### AUTO path (nego_en=1, silicon-faithful) — NO SPLIT (both RED, env-limited)

| checkpoint | deps | local (override) |
|---|---|---|
| t0-pre         | `rl=0 nego=1 mgate=1 mmatch=0 cal=0 nst=2` | `rl=0 nego=1 mgate=1 mmatch=0 cal=0 nst=2` |
| post-por-rearm | `rl=0 nego=1 mgate=1 mmatch=0 cal=0 nst=0` | `rl=0 nego=1 mgate=1 mmatch=0 cal=0 nst=0` |
| post-role-cfg  | `rl=0 nego=1 mgate=1 mmatch=0 cal=0 nst=0` | `rl=0 nego=1 mgate=1 mmatch=0 cal=0 nst=0` |
| final `[CPSIG]`| `rl=0 tr=0 calArmed=0 calMax=0` | `rl=0 tr=0 calArmed=0 calMax=0` |
| verdict | RED (env-limited) | RED (env-limited) |

Byte-identical between deps and override at every checkpoint. Both RED — but for a
reason **unrelated to the FCSM**: the UVM autoneg does not converge in this env
(`nst` cycles 0→1→2→0; the I²C mask handshake never lands, `mmatch=0`), so the
autoneg never reaches ST_NEGO_DONE to drive role_lock, and — separately — the SW
ROLE_CFG write does not latch role_lock while `nego_en=1` (it does with
`nego_en=0`, see the manual path). Both behaviours are identical across deps and
override. The auto path therefore **corroborates the no-split finding but its
autoneg-driven positive control is not exercised** (its arm never fires even in
the deps baseline).

## Instrument-trust gate

- **(a) deps GREEN under the healthy bring-up** — ✅ manual: role_lock→1,
  calibrator armed (cal_state 0→7) on both dies.
- **(b) override RED under the silicon-like condition** — ❌ **NOT reproduced.**
  The override arm-chain trace is byte-identical to deps in the manual path (and
  identical-RED in the auto path). There is no split.
- **(c) positive control** — ✅ (manual) the TB directly observes `role_locked=1`
  and a calibrator that leaves state 0. Clean binary, no X-pessimism.

## Honest bottom line

**No faithful deps-GREEN / override-RED control-plane split was reproduced.** With
the calibrator NOT bypassed and the real ROLE_CFG/training bring-up driven, the
override arm chain (`role_lock`, `swi_training_mode_r`, `nego_en`,
`calibrator_role_locked`, `cal_state`) is **identical** to the deps baseline. That
is a well-founded RTL result, not a mere miss:

- `role_lock_reg` latches from `nego_lock_pending_reg & mask_hs_gate_open` or a SW
  ROLE_CFG write & `mask_hs_gate_open` (`axi_chiplet_controller.sv:857-863`).
  `mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i`, and
  `mask_hs_match = wlink_mask_hs_result[0] | autoneg_mask_hs_local_match`
  (`:688,706`). The autoneg mask handshake runs entirely over **I²C**
  (`tidelink_autoneg.sv` ST_NEGO_MASK_RES_TX / RD_ADDR / RD_DATA). The Wlink
  `mask_hs_result` port is a **stub tied 0** in deps.
- `swi_training_mode_r` is set by the autoneg's local ENTER pulse or a SW R8 write
  (`:2115-2142`).
- the calibrator leaves `S_IDLE` purely on the `role_locked` rising edge. The AXI
  FCSM DOES feed the calibrator's later `S_VALIDATE` oracle (`cr_pkt_seen_i =
  obs_cr_pkt_seen_rx_w | …`, `:5866`), so it can gate `cal_done` — but that is
  DOWNSTREAM of the arm. The silicon symptom is `cal_state=0` (never armed), which
  the FCSM structurally cannot cause. And in the steady manual bring-up here both
  variants not only arm but progress through validation to S_HOLD identically.

**None of these read the AXI FCSM 0-4 on the arm path.** The FCSM nodes are Wlink flow-control
state machines on the data path; the role-lock / training / calibrator-arm
bootstrap is driven by the APB register file, the I²C autoneg and the
`role_locked` mutual-clock-enable — a disjoint control plane. So the FCSM
deps→override swap has **no RTL-observable path** to the arm chain, and a faithful
zero-BER RTL sim is **necessarily blind** to the silicon `role_locked=0`.

**Therefore the silicon I1 signature (role_locked=0 / cal_state=0 with the override)
is NOT a direct RTL consequence of the FCSM swap.** It must originate above the
synthesisable RTL the sim compiles — the packaged-IP / OOC-synth / build layer
(the same class `verilog_define_never_reaches_ooc_ip` and the prior UVM attempt's
"stale packaged IP" conclusion warn about), or a silicon timing/reset-sequencing
effect the zero-delay sim cannot express. This CONFIRMS, by construction, the
memory's open item "FCSM→role_lock/training path": **there is no such path in
RTL.** The productive next step is a structural / packaged-IP diff of the override
build, NOT a further RTL sim.

### Auto-path caveat (fidelity gap, stated honestly)

In the auto (nego_en=1) path the UVM autoneg does not converge in this env — even
though the TB DOES strap the two dies asymmetrically (die A `role_strap_i=0`
master, die B `role_strap_i=1` slave, `tb/top.sv:598,791`, which should give die A
the lower ST_NEGO_WAIT backoff per `axi_chiplet_controller.sv:753`). `nst` still
cycles 0→1→2→0 on both dies and the I²C mask handshake never lands (`mmatch=0`), so
the autoneg never reaches ST_NEGO_DONE. Separately, a SW ROLE_CFG write does not
latch role_lock while `nego_en=1` (it does with `nego_en=0`). Both are pre-existing
env behaviours, **identical for deps and override**, so the auto path corroborates
the no-split finding without exercising an autoneg-driven positive control. Neither
depends on the AXI FCSM (the autoneg is I²C-driven and FCSM-independent), so fixing
the UVM autoneg convergence — tracked separately, and exercised by the dedicated
cocotb `test_28_autonomous_i2c_bringup_converge` — would not change the conclusion.
The manual path already supplies the passing positive control the trust gate needs.

## Reproduce

```
source ./set_env.sh; export TIDELINK_PHY_V2=1; export PATH=$VCS_HOME/bin:$PATH
export DESIGNWARE_HOME=$VIP_HOME
cd uvm/tidelink_top_system
make compile FCSM_SRC=deps
make compile FCSM_SRC=local
# manual (positive control + no-split):
sim_build_deps/simv  +UVM_TESTNAME=test_top_i1_controlplane +CP_MODE=manual +NO_CAL_BYPASS -l cp_manual.log
sim_build_local/simv +UVM_TESTNAME=test_top_i1_controlplane +CP_MODE=manual +NO_CAL_BYPASS -l cp_manual.log
# auto (silicon-faithful, nego_en=1):
sim_build_deps/simv  +UVM_TESTNAME=test_top_i1_controlplane +CP_MODE=auto +NEGO_AUTO_STRAP +NO_CAL_BYPASS +CP_OBS_CYC=80000 -l cp_auto.log
sim_build_local/simv +UVM_TESTNAME=test_top_i1_controlplane +CP_MODE=auto +NEGO_AUTO_STRAP +NO_CAL_BYPASS +CP_OBS_CYC=80000 -l cp_auto.log
# compare the [CPSIG] lines between deps and local — identical == no split.
```
