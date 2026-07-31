# T1 — I1 `SELF_ARM_TRAIN_EN` fix-logic regression

Branch: `test/i1-selfarm-regression` (= `sim/i1-controlplane-repro` harness +
`fix/i1-selfarm-rolelock`@`43b5845` merged). Sim + analysis only — no HW, no FPGA
build, no push. VCS 2022.06-SP2, `TIDELINK_PHY_V2=1` (armed by the flist shims).

## What this gates

The I1 eth-chiplet bring-up fix (`docs/I1_SELFARM_FIX.md`): the default-OFF
`SELF_ARM_TRAIN_EN` parameter on `axi_chiplet_controller` (threaded through
`tidelink_top`) that latches `role_lock_reg = 1` on the SW `ROLE_CFG[1]` write
**without** waiting for the peer mask-handshake gate (`mask_hs_gate_open`) or the
`nego_lost_w` fallback. On the eth-chiplet neither ever fires — its peer-I2C
control plane never completes (`nego_en = 0`, no peer mask verdict) — so pre-fix
`role_lock` stayed 0. `role_locked` is a **mutual clock enable**
(`wlink_por_reset = ~role_locked`), so a stuck 0 held every FCSM and the
forwarded PHY clock in reset and the calibrator could never run (`cal_done = 0`,
`fcsm = 0`). Self-latching on the explicit SW intent honours the design principle
"role-lock must never wait on a protocol event"
(`project_role_lock_is_a_mutual_clock_enable`).

## HONEST scope — a fix-logic unit regression, NOT a silicon repro

This test does **not** reproduce the silicon I1 deadlock. Per the companion
control-plane repro (`docs/I1_CONTROLPLANE_SIM.md`): with the calibrator
un-bypassed and the real `ROLE_CFG`/training bring-up driven, the FCSM
deps→override swap moves **no** arm-chain signal, so a faithful zero-BER RTL sim
is **blind** to the silicon `role_locked = 0` (it originates above the
synthesisable RTL — packaged-IP / OOC-synth / reset-sequencing). The silicon
failure itself is gated **only on KR260 HW** (`kr260_eth_regress`).

What this suite gates is the **fix's RTL logic**: that under the exact
eth-chiplet control-plane condition (mask-handshake gate engaged, `nego_en = 0`),
`SELF_ARM_TRAIN_EN` changes `role_lock` from *never latches* to *latches on the
SW write* — and that it stays default-OFF (byte-identical legacy behaviour) so an
accidental default flip or a regression of the latch logic is caught.

## The test — single-sim self-checking discrimination

`uvm/tidelink_top_system/tests/test_top_i1_selfarm.sv`, on the paired-die
`tidelink_top_system` harness. `tb/top.sv` parameterises the two real
`tidelink_top` DUTs asymmetrically at **compile** time (default OFF on both, so
every other test in the harness is byte-identical):

| die | `SELF_ARM_TRAIN_EN` | role |
|-----|---------------------|------|
| A   | `1` (with `+define+TL_SELF_ARM_A_ON`) | the FIX under test |
| B   | `0` (shipping default) | built-in NEGATIVE CONTROL |

Both dies are driven with **identical** stimulus under the eth-chiplet condition:
`mask_hs_bypass = 0` (mask gate engaged — a genuine peer verdict never arrives),
`nego_en = 0`, then a SW `ROLE_CFG[1]=1` write (`0x2080`), then a SW
`SWI_TRAINING_MODE=1` write (`0x2100`). All observed nets are **real RTL**,
mirrored onto `tb_if` from `u_chiplet_controller.*` in `top.sv` (no forcing, no
X-masking): `role_lock_reg`, `swi_training_mode_r`, `nego_en`,
`mask_hs_gate_open`, `mask_hs_match`.

### Assertions

- **`FIX_LATCH_A`** (the fix): die A `role_lock` **latches 1** on the `ROLE_CFG[1]`
  write, with no mask gate and no nego verdict.
- **`NEGCTL_B_NOLATCH` / `B_RL_NEVER`** (negative control / instrument-trust): die
  B `role_lock` **stays 0** under the identical stimulus, for the whole run. If it
  latched too, the pass would be the strap/stimulus — not the param — and the test
  fails.
- **`MASKMATCH_A_ZERO` / `A_MMATCH_NEVER`**: die A `mask_hs_match` stays 0 — the
  self-arm does **not** forge the genuine-integrity witness (`mask_hs_verified`
  preserved; RETIRED autonomy still fails closed).
- **`TRAIN_A` / `ARM_PRECOND_A`**: die A `swi_training_mode_r = 1` after the R8
  write, so the calibrator arm precondition `role_locked & swi_training_mode_r` is
  **satisfiable** (was unreachable pre-fix because `role_locked` could never be 1).
- **`HOLD_A`**: die A `role_lock` holds across a 6000-cycle window (POR-clear-only).
- Instrument preconditions (`GATE_ENGAGED_*`, `NEGO_OFF_*`, `PRE_*_UNLOCKED`)
  assert the eth-chiplet condition is genuinely set up before the writes.

**Not asserted:** the calibrator physically *sweeping* (`cal_state` leaving 0). In
this asymmetric config die A's `rx_link_clk` is the peer's (die B's) forwarded
`pad_clk_tx`, which die B — `role_lock = 0` — holds gated (the mutual clock enable
itself), so die A's calibrator cannot advance. The sweep is downstream of, and
independent from, the fix logic (`AUTOCAL_ENABLE` defaults 0; arm =
`role_locked & autocal_enable`). We assert the arm **precondition** the fix
restores, and — per `docs/I1_CONTROLPLANE_SIM.md` — the physical sweep is
peer-clock-coupled and the silicon symptom is above-RTL anyway.

## Evidence

### PASS with the fix (die A `SELF_ARM_TRAIN_EN = 1`)

```
make run TEST=test_top_i1_selfarm FCSM_SRC=local SIM_DIR=sim_build_selfarm \
     EXTRA_VCS_FLAGS="+define+TL_SELF_ARM_A_ON"     # in uvm/tidelink_top_system
```

```
[I1SA_CHK] PASS  FIX_LATCH_A        die A role_lock must LATCH on SW ROLE_CFG[1] via SELF_ARM_TRAIN_EN ...
[I1SA_CHK] PASS  NEGCTL_B_NOLATCH   die B role_lock must STAY 0 (default-OFF: no self-arm) ...
[I1SA_CHK] PASS  MASKMATCH_A_ZERO   die A mask_hs_match must stay 0 ...
[I1SA_CHK] PASS  TRAIN_A            die A swi_training_mode_r must be 1 ...
[I1SA_CHK] PASS  ARM_PRECOND_A      die A calibrator arm precondition (role_locked & swi_training_mode_r) ...
[I1SA_CHK] PASS  B_RL_NEVER         die B role_lock was NEVER observed high (negative control)
[I1_SELFARM_SIG] A[rl_ever=1 tr_ever=1 mmatch_ever=0]  B[rl_ever=0 tr_ever=1]  fails=0
[I1_SELFARM_VERDICT] PASS: SELF_ARM_TRAIN_EN latches role_lock on die A (fix ON) and NOT on die B (default OFF); ...
[I1_SELFARM_DONE]
UVM_ERROR :    0
UVM_FATAL :    0
```

All 14 named checks (+ hold-window samples) PASS. `A[rl_ever=1]` (fix latched),
`B[rl_ever=0]` (negative control never latched), `mmatch_ever=0` (witness not
forged).

### DISCRIMINATION — the negative control, run once (no `+define`)

Recompiling **without** `+define+TL_SELF_ARM_A_ON` makes die A **also**
`SELF_ARM_TRAIN_EN = 0`, so under the identical eth-chiplet condition die A can no
longer latch `role_lock`:

```
make run TEST=test_top_i1_selfarm FCSM_SRC=local SIM_DIR=sim_build_selfarm_negctl   # NO EXTRA_VCS_FLAGS
```

```
[I1SA_CHK] FAIL  FIX_LATCH_A        die A role_lock must LATCH ...   <-- discriminates
[I1SA_CHK] PASS  NEGCTL_B_NOLATCH   die B role_lock must STAY 0 ...
[I1_SELFARM_SIG] A[rl_ever=0 ...]  B[rl_ever=0 ...]  fails>0
[I1_SELFARM_VERDICT] FAIL: ... SELF_ARM discrimination not proven ...
```

The test **FAILS** without the param — proving it is not vacuously green: the PASS
is caused by `SELF_ARM_TRAIN_EN`, not by the strap or the stimulus. (A test that
passed with the param both on and off would be blind — this run shows it is not.)

## Wired into `sim_gate`

Root `Makefile`:

- **Target** `sim_gate_i1_selfarm` → `$(call sim_gate_run,i1_selfarm_rolelock, …)`.
  Fresh `rm -rf sim_build_selfarm` first (never a stale simv), compiles with
  `+define+TL_SELF_ARM_A_ON`, and PASS requires the `[I1_SELFARM_VERDICT] PASS`
  token **and** the `[I1_SELFARM_DONE]` marker **and** the absence of any FAIL
  verdict.
- **Scored** in `SIM_GATE_ALL_SUITES` as `i1_selfarm_rolelock`, **invoked** in the
  `sim_gate` aggregate (`@$(MAKE) … sim_gate_i1_selfarm`), and listed in `.PHONY`
  — so scored ⇔ invoked stays consistent (the invariant `sim_gate_inventory`
  enforces on branches that carry it; this base — main@`18491ef` — predates that
  target, but the invariant is maintained by construction).

## Reproduce

```
source ./set_env.sh; export TIDELINK_PHY_V2=1; export PATH=$VCS_HOME/bin:$PATH
git submodule update --init deps/           # or symlink deps/ from a populated checkout
make sim_gate_i1_selfarm                     # the gated suite (fix ON) -> PASS
```
