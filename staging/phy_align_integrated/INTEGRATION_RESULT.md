# §9 PHY-Align Integration Result

Worktree: `/home/dam1n19/SoCLabs/tidelink/.claude/worktrees/agent-acec76b893b90a1e4`
Branch: `worktree-agent-acec76b893b90a1e4`
Plan: `docs/PHY_ALIGN_INTEGRATION_PLAN.md`
Status: **Steps 1-6 COMPLETE, all gates PASS. Step 7 = hand-off (not executed).**

## Sources

| Source | Path | Role |
|---|---|---|
| Trunk (BASE) | `/home/dam1n19/SoCLabs/tidelink` | HEAD `86ce6fa` + uncommitted §9 |
| Agent #6 | `.claude/worktrees/agent-a37f8bff7dea74917` | regmap redesign, RDL Region 8 |
| Agent #4 | `.claude/worktrees/agent-afcda9e78c3a14573` | I²C training + fifo fix |
| Agent #5 | `.claude/worktrees/agent-aed9e63bc196f8aec` | BD mask_hs_bypass un-tie |

## Environment finding (Step 1)

The integration worktree was created from `c3b8d4e`, **13 commits behind trunk
HEAD `86ce6fa`** (`feat/fpga-flow`). Trunk's `flist/tidelink_fpga.flist` §9
entries were committed in `674715d` (in trunk history, not in the worktree
base). Worktree was fast-forwarded to `86ce6fa`, then trunk's uncommitted §9
working changes applied. Submodule `deps/axi-chiplet-controller` and the
generated `deps/xhb500` tree were uninitialized; both initialized/mirrored
from trunk. Result: **0 tracked-file mismatches vs trunk** (parent + submodule
§9 RTL). The only deferred item is the `soctools_flow` nested-submodule
gitlink bump (`b5af174`→`0784ddc`, build-tooling only) — left to the
hand-carried submodule patch.

## Per-step status & gates

### STEP 1 — Base = trunk  ✅  (tag `integ-step1-base`)
Baseline cocotb: apb_regs 49/49, autoneg 7/7, wlink_pair 9/9,
phy_align test_pair_align PASS, test_autocal_integrated PASS,
staggered reproduces (PASS).

### STEP 2 — #6 regmap redesign + #4 fifo fix  ✅  (tag `integ-step2`)
RDL Region 8 (#6 verbatim), apb_regs Region 8 carve (#6), fifo
ctrl_reg_addr 3→4 (#4), top.sv union (4-bit + AUTOCAL_ENABLE),
REGISTER_MAP/wlink_probe (#6). **Gate: apb_regs 49/49, autoneg 7/7,
wlink_pair 9/9 — PASS.**

### STEP 3 — interim 0x1000 shim → Region 8  ✅  (tag `integ-step3`)
Deleted `tidelink_phy_align_regs` instance + `wl_apb_paddr[12]` split +
`pa_apb_*` mux; Wlink owns full APB region. Region 8 reg block added
with the **critical rewire**. Shim removed from both flists. tb_top
ctrl_reg_addr 3→4; test_autocal_integrated migrated to Region 8.
**Gate: wlink_pair 9/9, test_pair_align PASS, test_autocal_integrated
PASS (R8 cal_done read OK). Staggered: see Step 5.**

### STEP 4 — #4 ST_TRAIN_* FSM + Region 8 I²C wiring  ✅  (tag `integ-step4`)
tidelink_autoneg.sv #4-verbatim (ST_TRAIN states 12-17); 21 training
ports connected to u_autoneg; nego_driving OR train_in_progress_w; UVM
env unioned + 6 #4 train tests + force-targets retargeted. **Gate:
autoneg 7/7, apb_regs 49/49, wlink_pair 9/9 PASS; UVM compiles (valid
1.05MB simv ELF, clean compile.log); `test_top_train_base` UVM run =
`TEST PASSED` (FCSM advances 4→5→6, 6 UVM_ERRORs all demoted+caught =
the known/expected SHORTCOMINGS-14a I²C-path errors the scaffold
tolerates). End-to-end I²C ST_TRAIN remains blocked by SHORTCOMINGS-14a
(pre-existing, parallel agent owns the fix).**

### STEP 5 — staggered test  ✅  (tag `integ-step5`)
**NOT flipped to success.** The Step-3 "both converged" signal was a
FALSE POSITIVE: the test read status via `apb_read` at the deleted
0x4403_1000 shim, which (shim gone) returned Wlink-register garbage
that masked the slave's lane_fault. After correcting the read to
Region 8 SWI_LANE_STATUS via ctrl_reg, the FPGA staggered failure
STILL reproduces in sim:
  - master: lane_fault=0x00 cal_done=1 FSM=4 → CONVERGED
  - slave : lane_fault=0xFF cal_done=1 FSM=4 → FPGA FAILURE MODE
Per plan Step 5 ("if blocked in sim, leave asserting the failure mode
with a clear TODO referencing SHORTCOMINGS-14a"): assertion kept as
failure-mode reproducer + explicit `TODO(SHORTCOMINGS-14a)` to flip
once the I²C-coordinated path works end-to-end. **Gate: test PASSES
(correctly asserts the reproduction).**

### STEP 6 — #5 BD mask_hs_bypass 1→0  ✅  (tag `integ-step6`)
#5 verbatim in both pair targets; pair-flip-all comment strengthened
with explicit physical-I²C-jumper + PHYSICAL_WIRING.md +
SHORTCOMINGS-14a inline note (plan: "do not silently enable").

### STEP 7 — FPGA build/deploy  ⏸  HAND-OFF (per plan, not executed)
FPGA-build inputs verified consistent: both pair targets use
`fpga/filelist.tcl` → `flist/tidelink_fpga.flist` (shim removed,
lane_checker+calibrator present, `${CMSDK_FPGA_SRAM_V}` shim in base).
A later `make build_design` for either target will pick up the
integrated §9 RTL + #5 mask_hs_bypass=0 BD consistently.

## The `axi_chiplet_controller.sv` resolution (the hardest merge)

Base = my trunk-§9 controller (calibrator/lane_checker instances + interim
shim). Applied #4's structure on top, then surgically:

1. **Port widen**: `ctrl_reg_addr [2:0]→[3:0]` (#4).
2. **Read-mux split**: `region4_rdata` / `region8_rdata`, selected by
   `ctrl_reg_addr[3]` (#4 structure).
3. **Region 8 block** added (SWI_TRAINING_MODE/BIT_SLIP_LO/LANE_STATUS/
   NEGO_TRAIN_*) — #4's, **MINUS its placeholder regs**.
4. **CRITICAL REWIRE**: #4's CDC synchroniser (sync_lane_locked_1 /
   sync_lane_fault_1 / sync_cal_done_1) now samples the REAL trunk nets,
   replacing #4's placeholder reg-init constants:
     - `swi_lane_locked_in     = 8'hFF`  →  `lane_locked_w`
       (driven by `tidelink_lane_checker.lane_locked`)
     - `swi_lane_fault_in      = 8'h00`  →  `cal_lane_fault_w`
       (driven by `tidelink_phy_align_calibrator.lane_fault`)
     - `swi_calibration_done_in= 1'b1`   →  `cal_calibration_done_w`
       (driven by `tidelink_phy_align_calibrator.calibration_done`)
   `sync_lane_*_1`/`sync_cal_done_1` feed BOTH the Region 8
   SWI_LANE_STATUS readout AND the autoneg FSM's
   `local_swi_lane_locked_i`/`local_swi_lane_fault_i`/
   `local_calibration_done_i` — so the I²C-coordinated FSM polls genuine
   calibrator state.
5. **Net-decl hoist**: `cal_*_w` / `lane_locked_w` declarations moved
   above the Region 8 block (`default_nettype none` ⇒ no forward refs).
6. **Shim delete**: removed `tidelink_phy_align_regs u_phy_align`,
   `pa_apb_*`, `wl_apb_psel_gt`, `sel_pa`, the `wl_apb_paddr[12]`
   split, and the response mux; Wlink gets `wl_apb_psel` directly;
   `apb_prdata/pready/pslverr` pass straight from Wlink.
7. **SW-override OR-mux** now: `cal_bit_slip_w | swi_bit_slip_lo_r` and
   `cal_training_mode_w | swi_training_mode_r` (Region 8 regs). The
   autoneg FSM's `local_training_mode_set/clr` strobes OR into
   `swi_training_mode_r` — so calibrator + SW-override + I²C-FSM all
   merge into Wlink `swi_training_mode_in`.
8. **autoneg instance**: 21 #4 training ports connected; `nego_driving`
   OR `train_in_progress_w` so the FSM keeps the I²C AXIL bus through
   ST_TRAIN_*.
9. **UVM top.sv**: #4's force-injection retargeted identically
   (swi_lane_locked_in→lane_locked_w etc.); train-status mirrors +
   b_i2c_slv_disable kept.

## Merge decisions (judgement calls)

- **`tidelink_apb_regs.sv` → take #6's, NOT #4's.** Plan conflict TABLE
  says "Use #4's"; plan CRITICAL RULE says "pick the one whose paddr[8]
  decode matches the RDL in #6". Rules conflict → CRITICAL RULE is
  authoritative. #6's RDL documents `paddr[8:5]=4'b1000` 4-bit region
  select; #6's apb_regs implements exactly that (`apb_region=paddr[8:5]`).
  #4's uses `apb_region==3'b000 && paddr[8]` — functionally equivalent
  (`ctrl_reg_addr={paddr[8],paddr[4:2]}` either way, submodule sees the
  same encoding) but NOT RDL-structural. #4's `tidelink_fifo.sv` fix
  taken independently (different file #6 missed).
- **flists**: trunk-HEAD base already had the §9 entries (ordering
  differs from #6); kept trunk ordering, removed only the
  `tidelink_phy_align_regs.sv` line in Step 3 (when the shim .sv is also
  removed from RTL — avoids a broken intermediate).
- **`tidelink_top.sv`**: trunk base already had AUTOCAL_ENABLE=1 +
  ahb_mng_hready dir fix; applied only #6's ctrl_reg_addr 3→4 widen on
  top (union preserved).
- **UVM env (pkg/if/top.sv)**: NOT in the plan's conflict table. Trunk's
  uncommitted §9 align-test plumbing overlaps #4's Phase-3 additions.
  Resolved as a **union** (additive; different signal/test names) with
  #4's force-targets retargeted to the real calibrator nets (mandated by
  the critical-rule rewire).
- **Step 5 flip**: plan Step 3 said "staggered still fails — that's
  correct pre-I²C" but expected a possible Step-5 flip. The corrected
  Region 8 read shows the failure DOES still reproduce → kept the
  failure-mode assertion with the SHORTCOMINGS-14a TODO (honest gating;
  did NOT flip on the false Step-3 garbage-read signal).

## Residual issues / notes

- **SHORTCOMINGS-14a (critical path, NOT owned here):** end-to-end
  I²C-coordinated training (and therefore the staggered-bringup fix on
  silicon, and `test_top_peer_mask_auto`-class UVM end-to-end) is
  blocked by the pre-existing autoneg I²C wedge. The §9 ST_TRAIN_* FSM
  is structurally in place and wired. FPGA hardware bring-up blocker is
  NOT closed until 14a lands + on-board CURRENT_CREDITS ≠ 4096.
- **Orphaned `src/rtl/tidelink_phy_align_regs.sv`**: kept on disk
  (unreferenced by main flists). `uvm/tidelink_ptp_chain/Makefile:209`
  and the `uvm/tidelink_top_system` Makefile still hard-reference the
  file via VCS_FLAGS/`-y`; deleting it would break those compiles, so
  the file is retained as a dead (uninstantiated) module. Recommend a
  follow-up to scrub those Makefile refs then delete the file.
- **Stray `cocotb/test_autocal_integrated.py` /
  `cocotb/test_pair_align_staggered_bringup.py`** (cocotb root, tracked
  trunk dupes) still reference the deleted 0x1000 shim. NOT in any test
  Makefile path → don't affect gates. Recommend deleting these dupes
  (canonical copies live in `cocotb/phy_align/`).
- **`hsel` multiple-driver Warning-[ICPSD_W]** in UVM (top.sv:823, VC-VIP
  AHB slave-if) is **pre-existing trunk** align-test plumbing, a
  warning ("upgraded to error in future releases"), not from this
  integration. UVM still compiles + `test_top_train_base` PASSES.
- **`soctools_flow` nested-submodule gitlink** bump deferred to the
  hand-carried submodule patch (build-tooling only).

## cocotb regression (final, post Step-6)

| Suite | Result |
|---|---|
| `cocotb/tidelink_apb_regs` | 49/49 PASS |
| `cocotb/tidelink_autoneg` | 7/7 PASS |
| `cocotb/wlink_pair` | 9/9 PASS |
| `phy_align/test_pair_align` (SKID_BITS=3) | PASS |
| `phy_align/test_autocal_integrated` | PASS |
| `phy_align/test_pair_align_asymmetric` | PASS |
| `phy_align/test_pair_align_retraining` | PASS |
| `phy_align/test_pair_align_partial_failure` (STUCK_LANES_MASK=16) | PASS |
| `phy_align/test_pair_align_staggered_bringup` | PASS (asserts FPGA-failure reproduction + 14a TODO) |
| UVM `tidelink_top_system` compile | PASS (valid simv) |
| UVM `test_top_train_base` | TEST PASSED (6 UVM_ERROR demoted+caught = expected 14a) |

Methodology note: each phy_align test must run with a **clean
`../wlink_pair/sim_build`** (`SKID_BITS` is a compile-time
`+define+TB_TOP_SKID_BITS`; sharing a stale sim_build causes spurious
`tb_top reports 0` failures — not a code defect).

## Tags

`integ-step1-base` … `integ-step6` on the parent worktree branch;
parallel `integ/phy-align-base` + per-step commits on the
`deps/axi-chiplet-controller` submodule (substantial — user hand-carries
the submodule patch).

## FPGA-build readiness

**READY.** Filelists/IP-package inputs consistent: both pair targets →
`fpga/filelist.tcl` → `flist/tidelink_fpga.flist` (shim removed,
calibrator+lane_checker present, `${CMSDK_FPGA_SRAM_V}` shim in base).
BD `.tcl` ×2 carry #5's mask_hs_bypass=0 with the jumper note. A later
`make build_design` will work — but the resulting bitstreams are NOT
bring-up-ready on silicon until physical I²C jumpers are wired AND
SHORTCOMINGS-14a is fixed (documented in the BD comments + this file).
