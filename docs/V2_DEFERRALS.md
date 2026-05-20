# TideLink v2 Deferrals — Items Knowingly Pushed Out of v1-RC

Author: SoC Labs / dam1n19
Branch: `feat/td-combined` (tip varies, current `~91af70d`+)
Date: 2026-05-20
Audience: anyone planning the v2 cycle; this is the list of "we know this
exists, we chose not to do it in v1, here is why and what to do later".

This document is a complement to `docs/SHORTCOMINGS.md`. SHORTCOMINGS lists
*architectural* limits and FPGA-vs-ASIC differences in the as-built design.
This list is *engineering work knowingly punted*, with concrete unblock
steps.

---

## 1. RTL purification work

### 1.1 USE_CLKBUF in-PHY restructure — move to `fpga/rtl/` thin wrapper

**Status:** retained in vendor file (`deps/.../WavD2DGpioRx.v`) gated by
`USE_CLKBUF` parameter. ASIC build prunes via `USE_CLKBUF=0`.

**Why deferred:** an attempt in this session (commit `ce91961`, since
reverted as `b9b26e2`) to remove the in-PHY BUFG and rely on the boundary
`tidelink_rxclk_buf` alone caused a Vivado clock-tree pathology
(3 BUFGs + LUT-on-clock-tree → TIMING-14 + TIMING-17 ×1000 unclocked cells
including `u_calibrator/FSM_sequential_cur_state_reg[0..2]`) and the
bitstream wedged the FSM at state 0 on silicon. See
`docs/HAL_LINT_REPORT.md` and the netlist diagnosis on
`imp/fpga/project/.../impl_1/tidelink_design_wrapper_clock_utilization_routed.rpt`.

**Unblock recipe (v2):**
1. Create `fpga/rtl/tidelink_in_phy_clkbuf.sv` that instantiates the
   in-PHY BUFG topology *outside* the vendor file. Wire it in via
   `bind` or a `generate if(USE_CLKBUF)` block in the parent.
2. Remove the in-PHY `g_clkbuf` from `WavD2DGpioRx.v` (the
   `ce91961`-style change but with the FPGA fallback in place).
3. Confirm Vivado does NOT auto-insert a LUT2 between the boundary BUFG
   and the per-lane capture — re-check `clock_utilization_routed.rpt`.
4. Run `bringup_reliability.sh` N=30 to confirm reliability ≥ 14/16
   mean.

### 1.2 USE_T3A purification

**Status:** retained in vendor file under `USE_T3A` parameter.

**Why deferred:** a killed-mid-flight refactor in this session (patch
backed up at `.local-staging/refactor_t3a_killed_2026-05-20.patch`) was
in the same class as the USE_CLKBUF refactor — would require parallel
edits to `Wlink.v:1052` (instantiation) and `cocotb/wavd2d_gpiorx_t3a/`
testbench. Not blocking v1-RC.

**Unblock recipe (v2):**
- Same as 1.1 but for the T3a comma-hunt FSM.
- Tests `cocotb/wavd2d_gpiorx_t3a*` must be kept passing — they
  specifically pin `USE_T3A=1` behaviour.

### 1.3 Bug #3 dont_touch → structural fix

**Status (TBD when this doc is written):** Bug #3
(`mask_hs_auto_en`/`NEGO_CFG[6]` synth-pruning blocking mask phase
states 8/9/10) is being addressed in this session via either:
- A `(* keep *) (* dont_touch *)` attribute path on
  `nego_cfg_reg` / `mask_hs_auto_en_kept_r` / `hs_result_*_q`
  (sub branch `fix/bug3-mask-hs-keep`, commit `75bc787`); OR
- A structural missing-default fix in the next-state combinational
  block (sub branch `feat/bug3-structural-fix`, commit TBD).

**Why this may be deferred:** if the dont_touch path ships in v1 and the
structural fix isn't ready, the attribute-based fix carries the risk
that ASIC synth tools handle the attribute differently or ignore it
entirely. A structural fix is mandatory for ASIC port.

**Unblock recipe (v2):**
1. Find the missing `default:` / `else` clause in the autoneg FSM's
   next-state assignment (`nego_state_nxt`) — same class as the
   `be5eed2` `txn_step_nxt` fix.
2. Add the default. Confirm Vivado no longer infers a latch
   (search synth log for `Synth 8-327` on the affected signal).
3. Remove the `(* keep *)` / `(* dont_touch *)` attributes.
4. Re-run HW reliability + autoneg + AHB end-to-end.

---

## 2. CI integration (4 plans landed as docs/ proposals, not yet wired)

See `docs/CI_AUDIT.md`, `docs/CI_FPGA_PLAN.md`, `docs/CI_LINT_PLAN.md`,
`docs/CI_COCOTB_PLAN.md`.

**Status (per CI_AUDIT.md):** last 10 pipelines all red; `fpga-pair` is
rules-gated to `main`/`feat/fpga-flow` only AND `allow_failure: true`;
dashboard ships green because `generate_dashboard.py` only counts 6 of
30+ envs.

**Unblock recipe (v2 OR end of v1):**
1. Remove `allow_failure: true` on `fpga-pair`.
2. Un-gate `fpga-pair` to also run on MR events / `feat/*` branches.
3. Add the new lint jobs (`lint:verilator`, `lint:hal`, `lint:rdl`)
   per `CI_LINT_PLAN.md`. Phase 1 advisory, phase 2 gating.
4. Add the new cocotb fast-lane jobs (12 subdirs, ~10 min) per
   `CI_COCOTB_PLAN.md`. Path-to-suite map fires nightly extras.
5. Fix the dashboard env hard-coding (`generate_dashboard.py:135,166`).

**Why deferred:** integrating into `.gitlab-ci.yml` is high-blast-radius;
needs a controlled rollout (advisory → gating) once a HW-green branch
exists to anchor against.

---

## 3. Recovered-but-unused register fields

Today's RDL preprocessor fix (`7fd12a4`, `scripts/rdl2c.py` regex)
recovered 11 register fields that were silently dropped from
`tidelink_regs.generated.h` because their declarations ended in a
trailing `// [bit-range]` comment.

**Recovered fields (offsets 0x100–0x11C in TIDELINK_REGS_TypeDef):**
SWI_TRAINING_MODE, SWI_BIT_SLIP_LO, SWI_LANE_STATUS, NEGO_TRAIN_CFG,
NEGO_TRAIN_STATUS, ECC_COUNTERS, SWI_PHASE_OFFSET, PHY_ALIGN_ID, plus
3 more in the 0x1XX block.

**Status:** the C driver (`src/sw/tidelink.c`) and host
(`pynq_host/`) currently access these via raw offsets (e.g.
`0x44032108` for SWI_LANE_STATUS). They could now use the typed struct
fields.

**Unblock recipe (v2):** sweep the C/Python code and replace raw
offsets with named-field accesses. Recompile + re-run cocotb
`tidelink_ahb` regression.

---

## 4. Commit-graph cleanup

This session's commit graph on `feat/td-combined` has 3 thin
"re-tag" commits (`4def6e9`, `4d70b74`, `e9c94c2`, `027cc83`) that are
artefacts of concurrent agents writing to the same file during the
parallel docs-agent landings. They are functionally correct but
chronologically confusing.

**Status:** harmless; merge to main as-is would inherit the noise.

**Unblock recipe (v2):** `git rebase -i feat/td-combined~30` and
squash the 4 thin commits into a single
`docs(asic): hard-IP inventory + UPF + DFT` commit before merging
to `main`. NEVER do this once pushed; do it strictly local-only.

---

## 5. Extended reliability characterisation (≥ 50 deploys)

`bringup_reliability.sh` was run with N=30 in this session. The
`docs/SHORTCOMINGS.md` reliability table cites the N=30 numbers.

**Status:** 30 is enough for a coarse mean estimate but noisy on
tail behaviour.

**Unblock recipe (v2):** re-run with N=200 once Bug #3 is closed
and the link is at full 16/16 nominal. Tighten the cited numbers
in SHORTCOMINGS §2.1.

---

## 6. AHB TideLink end-to-end on HW (was wedge-risk in v1)

In v1, we verified autoneg + lane lock + APB-mediated register
read/write. We did NOT push data through `AHB_TX` (the cross-chiplet
data path at `0x4400_0000`) because the wedge-hazard on partial
lane lock was real.

**Unblock recipe (v2):**
1. Confirm Bug #3 fix lands 16/16 lane lock + FCSM advancing to
   state 4 + `cr=1` + `ck=1`.
2. Run `pynq_host/scripts/run_e2e_ahb.sh` (TBD — needs to be
   written). Pattern: master writes a known sequence to
   `0x4400_0000`, slave reads its `AHB_RX` FIFO, verify byte-equal.
3. Add watchdog: 5-second AHB transaction timeout to avoid wedging
   the PYNQ PS if the link fails mid-transfer.

---

## 7. v2 entry checklist

When opening v2:
- [ ] All 6 items above are addressed or formally re-deferred.
- [ ] CI is at least at "phase 1 advisory" for lint + cocotb fast lane.
- [ ] HW-green branch baseline reliability ≥ 14/16 N=200.
- [ ] `docs/SHORTCOMINGS.md` revision history updated.
- [ ] `MEMORY.md` entry for the i2c-autonomous-lock-integ pin closed
  out with Bug #3 status (fixed vs deferred).
