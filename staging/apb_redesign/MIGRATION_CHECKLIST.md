# APB Redesign — Migration Checklist

**Goal:** Replace the interim §9 PHY-alignment shim at MMIO `0x4403_1000+` with
the long-term Region 8 register block at MMIO `0x4403_2100+`, and prepare the
register map to absorb the I²C-coordinated training-mode protocol.

**Strategy:** **additive-first, delete-last.** New Region 8 lands in parallel
with the interim shim; SW + tests migrate to new offsets; once verified, the
interim shim is deleted and the autoneg I²C-train extension lands on the
known-good Region 8 layout.

**Owners:**
- RTL: dam1n19
- SW (PYNQ host): dam1n19
- UVM: dam1n19 + i2c_train_protocol agent
- Cocotb: dam1n19 + phy_align agent
- Docs: dam1n19

---

## Phase 1 — Pre-flight

1. **Read these three docs front to back before touching code:**
   - `staging/apb_redesign/PROPOSAL.md` (this redesign)
   - `staging/i2c_train/I2C_TRAIN_PROTOCOL.md` (I²C-train spec; offsets in §3.1 are SUPERSEDED by this redesign — apply the address map in PROPOSAL.md §5)
   - `docs/PHY_ALIGN_NEXT_STEPS.md` §2.1 + §2.3

2. **Confirm baseline:** the interim shim at MMIO `0x4403_1000+` is currently
   passing the FPGA bring-up (per `BRINGUP_REPORT.md` §9 closure when it
   completes). **Do not start migration until the interim shim is proven
   green on the FPGA pair.** If the interim shim itself fails, fix that
   first; the migration assumes a working baseline.

3. **Snapshot regression status:**
   - Run `make` in `cocotb/wlink_pair/` → record PASS count baseline.
   - Run `make` in `uvm/tidelink_top_system/` → record PASS count baseline.
   - Capture FPGA pair-board state: log `wlink_probe.sh` output to a
     timestamped file under `staging/apb_redesign/baseline/`.

---

## Phase 2 — RDL first (no RTL changes yet)

4. **Apply `tidelink_regs.rdl.diff` to `src/rdl/tidelink_regs.rdl`.**
   - This declares NEGO_* registers (which were live in
     `axi_chiplet_controller.sv` but not previously in RDL — RDL parity
     fix) and the new Region 8 registers.
   - **No RTL impact yet.** RDL is documentation-grade unless regenerated.
   - **Test:** RDL lint (`peakrdl regblock --dry-run` or equivalent) passes.
   - **Test:** `peakrdl-html` rendering matches the expected layout (eye
     check the Region 8 table).

5. **Commit Phase 2.**

---

## Phase 3 — Add Region 8 RTL alongside the interim shim

6. **Apply `apb_regs.sv.diff` to `src/rtl/fifo/tidelink_apb_regs.sv`.**
   - Widens region select from `paddr[7:5]` (3-bit) to `paddr[8:5]` (4-bit).
   - Adds Region 8 decode + read-mux arm.
   - Widens `ctrl_reg_addr` output from 3 bits to 4 bits.

7. **Update `tidelink_top.sv` ctrl_reg_addr wiring (one-line tweak).**
   - The `tidelink_apb_regs` instance's `.ctrl_reg_addr` connection becomes
     a 4-bit wire. The receiving end (`axi_chiplet_controller`) must
     accept a 4-bit input — see step 8.

8. **Apply `chiplet_controller.sv.diff` to
   `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv`.**
   - Widens `ctrl_reg_addr` input port from 3 to 4 bits.
   - Adds Region 8 register POR-only declarations and write/read logic.
   - **Keep the interim shim in place** for now (do NOT yet delete
     `tidelink_phy_align_regs` instance). Both blocks share the
     same `swi_bit_slip_w` / `swi_training_mode_w` net via OR-merge.

9. **Apply the OR-merge tweak to `axi_chiplet_controller.sv`:**

   ```verilog
   // Temporary OR-merge during migration. Once interim shim deletion
   // (Phase 5) is complete, replace with direct assignment to Region 8 regs.
   wire [23:0] swi_bit_slip_w_combined     = swi_bit_slip_lo_reg     | swi_bit_slip_w_interim;
   wire        swi_training_mode_w_combined = swi_training_mode_reg   | swi_training_mode_w_interim;
   ```

   Wire `_combined` versions into Wlink. The interim shim's outputs become
   the `_interim` halves of the OR.

10. **Regression after Phase 3:**
    - Cocotb `wlink_pair/`: must still PASS at the recorded baseline. The
      interim shim is still active; the new Region 8 regs are present but
      tied to zero by default (writes through OR-merge are no-ops until
      SW starts writing them).
    - UVM `tidelink_top_system/`: same.
    - Lint `tidelink_apb_regs.sv` and `axi_chiplet_controller.sv` (verilator
      `--lint-only -Wall`). No new warnings.
    - **Do NOT yet build FPGA.** Save the bitstream rebuild for Phase 5
      where we delete the interim shim — combining the two changes saves
      one 62-minute build cycle.

11. **Commit Phase 3.**

---

## Phase 4 — SW migration (PYNQ host + cocotb + UVM)

12. **Update `pynq_host/scripts/wlink_probe.sh`:**
    - Add a `region8_probe()` function that reads `0x4403_2100..0x4403_211C`.
    - Keep the existing `0x4403_1000` / `0x4403_1004` probes labelled
      `[LEGACY-INTERIM-SHIM]`.
    - Format: print both new and legacy addresses side-by-side; values
      must match for the migration to be considered safe.

13. **Update `pynq_host/scripts/deploy_pair.sh`:**
    - Add a feature flag `USE_REGION8=1` (default ON in this branch).
    - When set, target `swi_*` writes to Region 8 offsets. When unset,
      preserve legacy `0x4403_1000+` paths.
    - **Verify on FPGA pair-board** (this is the gating check):
      - `USE_REGION8=0`: bring-up still works (sanity check that interim
        shim path is unaffected).
      - `USE_REGION8=1`: bring-up works via Region 8.
      - Both `wlink_probe.sh` invocations report identical `swi_bit_slip`
        and `swi_training_mode` values.
    - **Acceptance:** FPGA pair-board bidirectional bring-up via Region 8.

14. **Update cocotb tests:**
    - `cocotb/phy_align/test_apb_drive.py` (new — written for interim
      shim) needs forking. Create `test_apb_drive_region8.py` that uses
      the new offsets.
    - Existing hierarchical-ref tests (`test_pair_align*.py`) are
      unaffected — they bypass APB entirely.

15. **Update UVM tests:**
    - Address constants in `uvm/tidelink_top_system/tests/*.sv` that
      currently target the interim shim need updating to Region 8 offsets.
    - Run UVM regression. **Acceptance:** all PASS at baseline.

16. **Commit Phase 4.**

---

## Phase 5 — Delete the interim shim

**Only proceed if Phase 4 passes both cocotb AND UVM AND FPGA pair-board with
`USE_REGION8=1`.**

17. **Apply the deletion portions of `chiplet_controller.sv.diff`:**
    - Remove the `tidelink_phy_align_regs u_phy_align (...)` instantiation
      at lines 895-926.
    - Remove the `paddr[12]` mux at lines 928-934.
    - Remove `pa_apb_*` wires.
    - Restore `apbport_0_psel = wl_apb_psel` (full 8KB Wlink range).
    - Remove the `_combined` OR-merge from step 9 — replace with direct
      assignment from Region 8 regs.

18. **Delete the interim shim source file:**
    - `rm src/rtl/tidelink_phy_align_regs.sv`
    - Remove entry from `flist/tidelink_top_full_asic.flist`.
    - Check no other flists reference it (`grep -r tidelink_phy_align_regs
      flist/`).

19. **Cleanup deploy_pair.sh:**
    - Remove `USE_REGION8=0` path (legacy support no longer needed).
    - Remove `[LEGACY-INTERIM-SHIM]` probes from `wlink_probe.sh`.

20. **Regression after Phase 5:**
    - Cocotb full regression → PASS at baseline.
    - UVM full regression → PASS at baseline.
    - **FPGA build:** both `pynq-z2-pair-all` and `pynq-z2-pair-flip-all`
      bitstreams. Expect ~62 minutes total. Verify timing met (positive
      WHS), no opt_design/impl errors.
    - **FPGA deploy:** run `deploy_pair.sh` on the pair-board. Verify:
      - Both boards report `swi_lane_locked == 0xFF`.
      - FCSM state = 4 on both boards.
      - Doorbell traffic from master ticks `DOORBELL_RESP_ACC` on slave.
      - `wlink_probe.sh` Region 8 dump matches expected layout (e.g.
        `0x4403_211C` reads `0x5041_0100`).

21. **Commit Phase 5.** Tag this commit as `apb-redesign-cutover`.

---

## Phase 6 — Layer 2: integrate I²C-train autoneg extension

**Pre-condition:** Phase 5 complete; baseline FPGA bring-up working through
Region 8.

22. **Apply the updates to `staging/i2c_train/tidelink_autoneg_train_states.sv`**
    per PROPOSAL.md §6 (the address-localparams change). Refresh the
    in-tree sketch first; integrators will pick it up.

23. **Update `staging/i2c_train/I2C_TRAIN_PROTOCOL.md`:**
    - §3.1 register-offset table: replace `0x090..0x0A8` with
      `0x100..0x114` per PROPOSAL.md §5.
    - §3.3 dual-port discussion: note that SWI_TRAINING_MODE is now
      register-clear-source = both local APB and I²C-AXIL.
    - Add a back-reference: "See `staging/apb_redesign/PROPOSAL.md` for
      the authoritative register-map design."

24. **Hand the autoneg-FSM extension** (`staging/i2c_train/`) **off to the
    integrator** with:
    - Updated address localparams.
    - The PROPOSAL.md §3.3.3 packed-register note (`SWI_LANE_STATUS`
      replaces the split `SWI_LANE_LOCKED + SWI_LANE_FAULT`).
    - The updated `all_locked_w` comparator including
      `calibration_done` term (PROPOSAL.md §6).

25. **Verify the slave-side AXIL-to-APB bridge** can address the full
    TideLink chiplet APB (0x4403_2000+ range) and not just the Wlink
    range (0x4403_0000-0x4403_1FFF). PROPOSAL.md §11.3 note 3. If
    needed, widen at the bridge — small route change.

26. **Acceptance for Phase 6:**
    - UVM `test_autoneg_train_happy_path` PASS.
    - UVM `test_autoneg_train_peer_nack` PASS.
    - UVM `test_autoneg_train_retrain` PASS.
    - Once I²C jumpers are wired physically (per
      `docs/I2C_TRAIN_PROTOCOL.md §7`), FPGA pair-board passes with
      `mask_hs_bypass_i = 0` and `NEGO_TRAIN_CFG.train_auto_en = 1`.

---

## Phase 7 — Documentation cleanup

27. **Update `docs/REGISTER_MAP.md`:**
    - Add Region 8 section per PROPOSAL.md §10.
    - Remove any reference to MMIO `0x4403_1000+` (interim shim).
    - Update §1 introduction to note the 4-bit region select.

28. **Update `docs/PHY_ALIGN_NEXT_STEPS.md` §2.1:**
    - Acceptance criteria: replace MMIO `0x4403_1000+` with `0x4403_2100+`.
    - Add "as-built" note pointing at PROPOSAL.md.

29. **Update `BRINGUP_REPORT.md` §9.8:**
    - Replace the interim "shim at 0x4403_1000" comment with the
      Region 8 final-state location.
    - Add a short "register map redesign" subsection summarising the
      §9 + I²C-train consolidation.

30. **Write a memory note** at
    `~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_tidelink_apb_redesign.md`
    capturing:
    - Why Region 8 was added (perf-profiling was full).
    - The interim-shim → Region 8 migration timeline.
    - Cross-link to PROPOSAL.md.

31. **Final commit. Squash if requested, otherwise leave as a clean
    Phase 1..7 history.**

---

## Acceptance gates summary

| Phase | Gate test | Expected result |
|---|---|---|
| 2 | RDL lint + render | Clean |
| 3 | Cocotb + UVM regression (interim shim still active) | All PASS at baseline |
| 4 | Cocotb + UVM regression (SW retargeted to Region 8); FPGA `wlink_probe.sh` cross-check | All PASS; values identical |
| 5 | Cocotb + UVM + FPGA build + FPGA deploy | All PASS; pair bidirectional |
| 6 | UVM autoneg-train suite + FPGA I²C-coordinated bring-up | All PASS; `mask_hs_bypass_i=0` |
| 7 | Doc lint / review | PROPOSAL.md, REGISTER_MAP.md, PHY_ALIGN_NEXT_STEPS.md consistent |

## Failure rollback

- **Phase 2 failure** (RDL lint fails): fix RDL syntax; retry. Low-risk.
- **Phase 3 failure** (cocotb/UVM regression breaks): revert
  `tidelink_apb_regs.sv` / `axi_chiplet_controller.sv` diffs.
  Region 8 not yet exercised by SW so no SW rollback needed.
- **Phase 4 failure** (FPGA Region 8 read/write mismatch): revert
  `deploy_pair.sh` to interim-shim paths (`USE_REGION8=0`). RTL remains;
  fix the RTL pass-through and retest.
- **Phase 5 failure** (FPGA bring-up regression after deleting shim):
  this is the riskiest step. Roll back the deletion (cherry-pick revert
  of Phase 5 commit) — the OR-merge from Phase 3 step 9 should still
  work. Re-validate via Phase 4 acceptance gate before retrying Phase 5.
- **Phase 6 failure**: this is the I²C-train integration; failure here
  does NOT roll back Phase 5 — Region 8 works without the I²C-train
  FSM. Defer Phase 6 until the autoneg-extension is debugged.

## Build/deploy quick-reference

- FPGA build: `make -C imp/fpga pynq-z2-pair-all pynq-z2-pair-flip-all`
- FPGA deploy (pair): `pynq_host/scripts/deploy_pair.sh`
- FPGA probe: `pynq_host/scripts/wlink_probe.sh <board_ip>`
- Cocotb regression: `make -C cocotb/wlink_pair regress` (or
  `pytest cocotb/wlink_pair/`)
- UVM regression: `make -C uvm/tidelink_top_system regress`
