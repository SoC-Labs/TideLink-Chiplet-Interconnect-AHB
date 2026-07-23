# P1 — `SWI_FORCE_RECAL` W1P: APPLIED

**Date:** 2026-07-19 · **Lane:** B1 · **Status:** APPLIED (not committed — David commits)
**Closes:** `docs/LINK_RECOVERY_MECHANISM.md` §4 / §6.1 P1 — *"there is no
firmware-reachable PHY retrain in this design at all."*

---

## 1. The defect

`calibrated_once_q` latches on the calibrator's FIRST `S_DONE` and from then on
gates off BOTH re-trigger edges. Only POR clears it. So `SWI_RECAL` (R8 slot0
bit[1]) is a **no-op after first lock**, and there was no firmware-reachable PHY
retrain at all — in the FPGA image **and the ASIC path**. Measured in
`LINK_RECOVERY_MECHANISM.md` §4 (FSM sampled 60x on both dies, never left
`S_DONE`) and reproduced here end-to-end (`test_01`, states = `[4]` only).

## 2. What `calibrated_once_q` protects — and how it is preserved

It is the **Bug-A** fix (2026-06-28). In autonomous I2C bring-up the winner's
autoneg `ST_TRAIN_EXIT` pulses `SWI_RECAL` 0→1→0 **while the calibrator is
already in S_DONE**. That falling edge re-asserted `training_mode` and squelched
the master's CR/CRACK framing exactly during FCSM credit-init → `crack_pkt_seen_rx`
stayed 0 → master FCSM wedged at state 2 with **zero TX credit**. Proof-of-fix:
`test_36`.

So the sticky exists to reject an **implicit, machine-generated** re-trigger on a
converged eye. The fix therefore **adds a new explicit door instead of widening
the existing one**:

* `calibrated_once_q` is **not modified, not cleared, not qualified**.
* Both implicit edges keep their `& ~calibrated_once_q` term **verbatim**.
* `force_recal_rise` is ungated — safe because, unlike `swreset`, **nothing in
  the autoneg FSM or any other RTL drives `SWI_FORCE_RECAL`**; only a deliberate
  APB write reaches it.
* The sticky **stays set** through and after a forced recal, so steady-state
  gating is identical before, during and after. A one-arming bypass, not a mode
  change. `test_4` (unit) and `test_01` (pair) are that regression.

Rejected alternative **P2** ("qualify the sticky with `cr_pkt_seen_i`"): it
changes existing behaviour rather than adding a door, so it re-opens the Bug-A
question. Not taken.

## 3. The change

### 3a. Calibrator (both copies — they carry the same sticky)

New `input logic force_recal_i = 1'b0`, given the **identical** 3-FF
synchroniser + edge-detect treatment as the two pre-existing async trigger
inputs, then:

```systemverilog
assign trigger_now = role_locked_rise_eff                    // gated (Bug-A)
                   | (swreset_fall_eff  & role_locked_sync)  // gated (Bug-A)
                   | (force_recal_rise  & role_locked_sync); // NEW explicit door
```

The **`= 1'b0` default port value is load-bearing**, not cosmetic: pre-P1
instantiators (e.g. `cocotb/tidelink_phy_align_calibrator/tb_calibrator.sv`)
leave the port unconnected; without the default it floats to `'z`, `force_recal_*`
go X, and X leaks into `trigger_now` and corrupts the FSM. Verified: that bench
is 7/7 + 3/3 green.

### 3b. acc — `axi_chiplet_controller.sv`

R8 slot0 **bit[6]** (`SWI_FORCE_RECAL`), a **W1P**, POR default 0, connected to
`.force_recal_i` on **both** `u_calibrator` instantiations (V2 and V1/trunk).
Readback of bit[6] returns the **stretcher busy status** so SW can poll handoff.

**Pulse stretcher (`FORCE_RECAL_STRETCH = 1024`) is required, not decoration.**
The W1P is set in `apb_clk` (~100 MHz) but the calibrator lives in `rx_link_clk`
(~1.5–6.25 MHz on FPGA, pad/16). A single `apb_clk`-wide pulse would be **missed
entirely** by the destination's 2-FF synchroniser — the classic slow-destination
CDC trap. 1024 apb cycles ≈ 15 rx_link_clk cycles at the worst 100:1.5 ratio.
The calibrator edge-detects the synced level, so a wide assertion still produces
exactly **one** re-arm. Bounded and self-clearing — no handshake, so no deadlock
if the calibrator never responds.

### 3c. Flists — all four families

| flist | calibrator | change |
|---|---|---|
| `tidelink_fpga_v2.flist` | → `src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv` | **repointed** |
| `tidelink_top_full_asic_v2.flist` | → same override | **repointed (TAPEOUT)** |
| `tidelink_fpga.flist` | `src/rtl/tidelink_phy_align_calibrator.sv` | none needed — edited in place |
| `tidelink_top_full_asic.flist` | same | none needed — edited in place |

`deps/tidelink-phy` stays **pristine** (submodule); `flists/tidelink_phy_v2.flist`
still builds the untouched deps copy for `tidelink_phy_bist_core`.

Verified **structurally**, not by md5: `asic_v2_elab.log` references the override
once and the deps copy **zero** times.

## 4. Evidence

**Unit** (`cocotb/tidelink_force_recal`, 6/6 on **both** V2 and V1):

| test | claim |
|---|---|
| 1 | baseline: `swreset`/SWI_RECAL after lock = NO-OP (defect + Bug-A guard) |
| 2 | baseline: `role_locked` re-pulse after lock = NO-OP |
| 3 | **fix**: `force_recal_i` → leaves S_DONE, re-sweeps, re-converges |
| 4 | **load-bearing**: after a forced recal, SWI_RECAL is *still* a no-op |
| 5 | default-off: port held 0 never re-arms |
| 6 | qualified: ignored while `role_locked=0` |

Recorded FSM trace for the forced recal (V2):
`[4,4,4, 1, 7,7,7,7,7,7,7,7, 3, 6,6,…]` = `S_DONE → S_ARM → S_PROBE(8=DWELL) →
S_FINISH → S_HOLD` — a genuine re-calibration.

**Full stack** (`make -C cocotb/tidelink_force_recal pair`, 3/3) — real APB
writes on the paired-die TB:

* `test_01` SWI_RECAL on a live link → cal states `[4]` only (**defect
  reproduced end-to-end**).
* `test_02` SWI_FORCE_RECAL → cal states `[1,2,4,7]` (**the W1P, stretcher and
  CDC all work**).
* `test_03` bilateral SWI_FORCE_RECAL → both dies `[1,3,4,7]`, both re-converge,
  and data is **byte-exact in BOTH directions afterwards**.

## 5. FIRMWARE-VISIBLE FINDING — a forced recal is a BILATERAL operation

A **unilateral** forced recal fires correctly but **does not re-converge**: the
peer is in data mode and is not emitting the training pattern, so the retraining
die's lane_checker never locks and it re-sweeps (`MAX_RESWEEPS=0` = T3
continuous re-sweep). This is correct behaviour, not a defect — and it is the
same bilateral requirement the SWI_RECAL bring-up recipe always had ("holds the
training pattern on BOTH boards"). `test_02` documents it; `test_03` shows the
bilateral form recovers the link byte-exact.

**Also**: R8 slot0 is a **packed** register — the write decode assigns
`training_mode`, `SWI_RECAL` and the three SYNC bits from the same wdata. Firmware
must **read-modify-write** to set bit[6], or it will clear the others on a live
link.

## 6. Regressions run (individually, never `make -n`)

ALL GREEN:

| suite | result |
|---|---|
| `v2_pair_data` | 3/3 |
| `v2_autonomous_sync_detect` | 4/4 |
| `v2_winscan_fsm` | 3/3 |
| `zeropoke_por` | 1/1 |
| `retire_en_plumb` (test_31) | 1/1 |
| `asic_v2_elab` | PASS |
| `v1_elab` | PASS |
| existing calibrator unit env (`tb_top` + `tb_calibrator`) | 7/7 + 3/3 |
| **this lane**: unit V2 / unit V1 / full-stack pair | 6/6 · 6/6 · 3/3 |

⚠ The shared `imp/sim_gate` build dirs collided with another lane mid-run
(SIGTERM, exit 144, plus a `t31` log this lane never started). Re-running the
same suite with a **private `SIM_BUILD`** passed cleanly. Prefer private
`SIM_BUILD`s while lanes are concurrent.

## 7. Risk that stays open

Unchanged from §6.1 of the recovery doc, and it must not be oversold: **nobody
has shown a forced recal recovers the W2 clock-dropout wedge.** This lane proved
the *lever now exists and re-trains the PHY for real*, and that the link survives
it byte-exact. Whether it clears W2 is the first thing to measure now that the
mechanism exists — that measurement was impossible before this change.

Second: the V2 override is a **fork of a 2367-line submodule file**. Future
`deps/tidelink-phy` calibrator fixes will not reach the V2/tapeout build until
re-merged. Re-diff against the submodule before any PHY uplift.

---

## 8. Adversarial review (2026-07-19) — five findings, all resolved

**F1 (CRITICAL) — SV default port value removed.** `input logic force_recal_i =
1'b0` had **zero precedent** anywhere in src/, deps/ or fpga/, and
`fpga/filelist.tcl:43` feeds this file to **Vivado OOC synthesis**, whose SV
subset is not reliably known to accept default port values. VCS accepting it in
sim proved nothing. It was also **never load-bearing on any path that reaches
silicon** — both shipping instantiators connect the port; only unit TBs dangled
it. The default is gone from both calibrators and the port is now tied off
explicitly at all 11 pre-existing unit-TB instantiations (8 files). Verified with
the actual tool: all 8 elaborate under VCS with no port diagnostics (the two
`URMI` results are a missing `tidelink_eye_regs`, unrelated), the two `*_deps`
TBs that compile the pristine submodule are correctly left alone, and the
existing envs still run 7/7 + 3/3 + 4/4. **This was my error: I wrote
"load-bearing, not cosmetic" into shared RTL without testing a single tool** —
exactly the failure the repo's own rule warns about.

**F2 (HIGH) — bit[6] is now write-only, reads 0.** Chosen over gating the write
strobe with `!swi_force_recal_r`, which is **incomplete**: it only covers an RMW
whose *write* lands inside the window, not one that *sampled* bit[6]=1 inside the
window and wrote back after expiry. Reading 0 covers both and matches the slot-0
bit[5] `SWI_SYNC_OBS_CLR` precedent beside it.

> **OPEN — the negative control did NOT reproduce the hazard.** With the buggy
> stretcher-readback deliberately restored, the new `test_04` **still passed**.
> Measured at the same instant: `swi_force_recal_r`=1 with the counter mid-window
> (1024 -> 462), yet the APB read of slot 0 returned bit[6]=0 anyway. The V2
> readback branch was confirmed live (bit[2] round-trips) and no mask was found
> on `region8_rdata -> ctrl_reg_rdata -> prdata`. **The mechanism is
> unexplained.** So: the fix is correct and free, but F2's hazard may not be
> reachable through this read path in this build, and `test_04` locks the
> *contract* rather than being a proven regression detector for the mux. It is
> labelled as such in the test docstring. Do not cite it as proof the hazard is
> gated in hardware.

**F3 (MEDIUM) — "consumed" claim removed.** The stretcher is an open-loop timer
with no calibrator feedback; expiry means "presented for 1024 apb_clk cycles",
not "consumed". Both the RTL comment and the readback now say so, and point SW at
the calibrator FSM state (Region C OBS_CAL) as the only authoritative evidence a
retrain happened.

**F4 (MEDIUM) — gated.** New `sim_gate_force_recal` -> suite `force_recal_w1p`,
added to `SIM_GATE_ALL_SUITES` **and** dispatched explicitly in the aggregate
(list-only would yield a MISS). Three arms: V2 override, V1 src, full-stack pair.
Verified end-to-end — the target runs, all three arms execute (6+6+4), and it
writes the `.status` name the summary expects. `docs/SIM_GATE_COVERAGE.md` updated
(21 -> 22 suites).

**F5 (MEDIUM) — left UNGATED by FCSM state, deliberately.** Full analysis in the
RTL. Both proposals fail for the same reason: the Bug-A wedge signature **is**
FCSM=2, a credit-init state, so "data-mode only" *and* "block credit-init" each
disable the lever precisely where it is wanted. Hardware cannot distinguish
"transiting credit-init" from "wedged in credit-init" — the difference is time,
not state. Deciding argument: the defect this change closes **is** "a firmware
control that silently does nothing"; adding a silent state-dependent gate to its
replacement would re-introduce that exact failure class, and with bit[6]
write-only there would be no way to tell a gated write from an ignored one.
Residual risk accepted and documented: firmware **can** wedge a link by firing
this during credit-init; the window is transient and firmware's to avoid, unlike
Bug-A which was automatic and unavoidable.
