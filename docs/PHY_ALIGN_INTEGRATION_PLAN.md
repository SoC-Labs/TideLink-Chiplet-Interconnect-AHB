# §9 PHY-Align — Integration Plan (2026-05-14)

Consolidates four parallel agent worktrees + trunk's autocal RTL into one
mergeable result that closes the FPGA bring-up blocker.

## Sources

| Source | Contents | Register home |
|---|---|---|
| **Trunk** (uncommitted) | Autocal calibrator (`src/rtl/tidelink_phy_align_calibrator.sv`), lane checker (`tidelink_lane_checker.sv`), `tidelink_phy_align_regs.sv`; WavD2DGpio slip+training+clk_en fix; `axi_chiplet_controller.sv` autocal integration; cocotb tests incl. `test_pair_align_staggered_bringup.py` | interim MMIO `0x4403_1000` |
| **Agent #6** `agent-a37f8bff7dea74917` | Register-map redesign: RDL Region 8 + NEGO_* parity, `tidelink_apb_regs.sv` Region 8 carve, `ctrl_reg_addr` 3→4, flists, `wlink_probe.sh`, docs | canonical MMIO `0x4403_2100` |
| **Agent #4** `agent-afcda9e78c3a14573` | I²C-coordinated training: `tidelink_autoneg.sv` ST_TRAIN_* states, Region 8 reg block in `axi_chiplet_controller.sv`, **`tidelink_fifo.sv` ctrl_reg_addr truncation fix**, UVM tests | canonical MMIO `0x4403_2100` (placeholder status inputs) |
| **Agent #5** `agent-aed9e63bc196f8aec` | `mask_hs_bypass_i` un-tie — 2 BD `.tcl` files | n/a |

## Target architecture

```
tidelink_phy_align_calibrator (trunk)  ──drives──┐
tidelink_lane_checker (trunk)          ──────────┤
                                                 ├─→ Region 8 SWI_LANE_STATUS
tidelink_autoneg ST_TRAIN_* FSM (#4)   ──I²C────→┤   @ MMIO 0x4403_2108
                                                 │   (replaces #4's placeholders
                                                 │    with real calibrator wires)
SW override regs (trunk phy_align_regs) ──OR-mux─┘
```

All §9 registers live in **Region 8 @ MMIO 0x4403_2100..0x4403_211F** (paddr[8]
carve). The interim shim at `0x4403_1000` is **deleted**.

## Conflict surface (files touched by ≥2 sources)

| File | Trunk | #6 | #4 | Resolution |
|---|---|---|---|---|
| `axi_chiplet_controller.sv` | autocal instances, phy_align_regs@0x1000 | Region 8 + shim delete | Region 8 + I²C FSM ports | **Hardest.** Take #4's Region 8 + I²C FSM as base; wire trunk's calibrator/lane_checker outputs into #4's SWI_LANE_STATUS inputs (replacing #4 placeholders); delete interim 0x1000 shim per #6 |
| `tidelink_apb_regs.sv` | — | Region 8 carve | Region 8 carve | Use #4's (it has the matching `tidelink_fifo.sv` fix); cross-check against #6's RDL |
| `tidelink_top.sv` | — | ctrl_reg_addr 3→4 | ctrl_reg_addr 3→4 + AUTOCAL_ENABLE | Union — both widen the same wire; keep AUTOCAL_ENABLE=1 |
| `tidelink_fifo.sv` | — | (missed) | ctrl_reg_addr 3→4 truncation fix | **Take #4's** — #6 missed this; without it Region 8 writes alias to Region 4 |
| `tidelink_autoneg.sv` | — | — | ST_TRAIN_* states | Take #4's verbatim |
| `tidelink_regs.rdl` | — | Region 8 + NEGO_* | — | Take #6's |
| flists, `wlink_probe.sh`, docs | — | Region 8 updates | — | Take #6's |
| BD `.tcl` ×2 | — | — | — (#5 only) | Take #5's, gated behind physical-jumper note |

## Integration order (validation-gated)

1. **Base = trunk** (autocal calibrator working at interim 0x1000, cocotb 14/14 + staggered reproducer).
2. **Apply #6 register-map redesign**: RDL, apb_regs Region 8, ctrl_reg_addr widen, flists, docs, wlink_probe. **Plus** the `tidelink_fifo.sv` truncation fix from #4 (critical — #6 missed it).
   - Gate: `cocotb/tidelink_apb_regs` 49/49, `cocotb/tidelink_autoneg` 7/7, `cocotb/wlink_pair` 9/9.
3. **Move calibrator/lane_checker/SW-override regs from interim 0x1000 → Region 8 0x2100**. Delete the interim shim instantiation + `tidelink_phy_align_regs.sv` paddr[12] mux in `axi_chiplet_controller.sv`. The SW-override + RO status now live in the Region 8 block.
   - Gate: cocotb `test_pair_align*` + `test_autocal_integrated` + `test_pair_align_staggered_bringup` still reproduce/pass as expected (staggered still fails — that's correct pre-I²C).
4. **Apply #4 I²C autoneg ST_TRAIN_* states** + Region 8 I²C FSM ports. Wire trunk's calibrator `lane_locked`/`lane_fault`/`calibration_done` into the Region 8 `SWI_LANE_STATUS` (replacing #4's placeholder reg-init constants). Wire the I²C FSM's `training_mode` request into the OR-mux alongside the calibrator + SW-override.
   - Gate: cocotb regression intact; new UVM ST_TRAIN_* tests walk correctly (end-to-end still blocked on autoneg I²C wedge SHORTCOMINGS-14a — that's pre-existing, document it).
5. **Flip `test_pair_align_staggered_bringup`** to assert SUCCESS once the I²C-coordinated path holds training_mode until both sides lock. (If the autoneg I²C wedge blocks this in sim, leave the test asserting the failure mode with a clear TODO referencing SHORTCOMINGS-14a.)
6. **Apply #5 BD un-tie** — `mask_hs_bypass_i` CONST_VAL 1→0 in both pair targets. Mark with a comment that this requires physical I²C jumpers between the boards (PHYSICAL_WIRING.md) or a runtime-switchable bypass; do NOT enable by default until jumpers verified.
7. **FPGA build** both pair targets, deploy, hardware test:
   - role_lock → autoneg mask-handshake → ST_TRAIN_ENTER (master tells slave training over I²C) → both sweep with training_mode held HIGH → both lock → ST_TRAIN_EXIT → cr_pkt handshake → FCSM state=4 → CURRENT_CREDITS ≠ 4096.

## Known pre-existing blocker on the critical path

The autoneg I²C path has a documented wedge (SHORTCOMINGS-14a): master's I²C
"claim" write succeeds but follow-on multi-byte transactions NACK/wedge. This
blocks `test_top_peer_mask_auto` today and will block the I²C-coordinated
training end-to-end until fixed. The ST_TRAIN_* FSM is structurally correct
(walks ST_TRAIN_ENTER→…→ST_TRAIN_FAIL with correct `train_peer_nack`
semantics). **Fixing SHORTCOMINGS-14a is a prerequisite for I²C-coordinated
training to actually work — it must be on the critical path.**

## Acceptance

- cocotb full regression green (wlink_pair 9 + phy_align suite + apb_regs 49 + autoneg 7)
- `test_pair_align_staggered_bringup` reflects the correct expected state for
  the integrated design (pass if I²C path works in sim; documented-fail if
  blocked by SHORTCOMINGS-14a)
- UVM compiles; ST_TRAIN_* tests walk correctly
- FPGA: both bitstreams build clean
- FPGA hardware: link comes up bidirectionally, CURRENT_CREDITS ≠ 4096,
  doorbell ticks — **bring-up blocker closed**
