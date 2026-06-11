# Archived documents

Point-in-time investigation, audit, bring-up, and planning notes produced during
the TideLink project. They are retained for **historical reference only** and are
**not maintained** — their durable conclusions (silicon status, known issues,
design decisions) have been folded into the active product docs one level up
([../README.md](../README.md)).

> Note: links and `file:line` references inside these documents are relative to
> their original `docs/` location and may not resolve from `docs/archive/`.

## Canonical sources folded into the product set

These were the primary inputs to the five active docs and are the best place to
go for depth:

| Archived doc | Folded into |
|---|---|
| `TIDELINK_SPECIFICATION.md`, `PHY_ARCHITECTURE_REFERENCE.md`, `DEPENDENCIES.md`, `FC_NODE_REGISTRY.md`, `ASIC_TIMING_CONSTRAINTS.md`, `CDC_AUDIT_REPORT.md` | [ARCHITECTURE.md](../ARCHITECTURE.md) |
| `TIDELINK_BRINGUP_USER_GUIDE.md`, `AUTONEG_PROTOCOL.md`, `PTP_PROTOCOL.md`, `i2c_train/I2C_TRAIN_PROTOCOL.md`, `PHY_LANE_DESKEW_DESIGN_2026_06_03.md`, `HW_TEST_SUITE.md` | [IMPLEMENTATION.md](../IMPLEMENTATION.md) |
| `HW_VALIDATION_RUNBOOK_GPIO_PHY_INTEG.md` + bring-up wiring | [INTEGRATION_GUIDE.md](../INTEGRATION_GUIDE.md) |
| `VPLAN.md`, `SHORTCOMINGS.md`, `HW_TEST_SUITE.md` | [VERIFICATION_PLAN.md](../VERIFICATION_PLAN.md) |

## By theme

- **Silicon / status milestones** — `AUTOCAL_CLOSURE_2026_06_10.md`,
  `V4_ZERO_POKE_FIRST_SILICON_2026_06_11.md`, `V1_RELEASE_TDIF13.md`,
  `SIGN_OFF_STATUS.md`, `IMPLEMENTATION_STATUS.md`, `OUTSTANDING_WORK_REPORT.md`,
  `RTL_FREEZE_CHECKLIST.md`, `HANDOVER_2026_06_01.md`, `BUG_TRACKER.md`.
- **Build validation logs** — `BUILD{1,3,5,6,9}_*`,
  `FC2_BUILD_LOG.md`, `DETERMINISM_VALIDATION.md`.
- **Bug A (FCSM / credit / data path)** — `BUG_A_*`, `DEBUG_PLAN_CREDIT_RETURN_DATA_TRANSFER.md`,
  `CREDIT_PATH_DEBUG_PLAN.md`, `FCSM_L7_WEDGE_FIX_PROPOSAL_2026_05_29.md`,
  `L7_WEDGE_SIM_REPRO_2026_05_29.md`, `F1P5_*`, `DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md`,
  `LINK_DECAY_BISECT.md`, `ILA_PLAN_S2M_ACK_PATH.md`.
- **Bug B / Bug C / Bug N** — `BUG_B_BD_FIX_DESIGN_2026_05_31.md`, `BUGC_*`,
  `BUG_N2_DIAGNOSIS.md`, `BUG_DIAGNOSES_2026_05_29.md`.
- **Calibrator / PHY align** — `CALIBRATOR_9_11*`, `CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md`,
  `LANE_LOCK_ROOT_CAUSE.md`, `PER_LANE_PHASE_CAPABILITY_AUDIT_2026_05_29.md`,
  `agent_a_…`–`agent_o_…` (the multi-agent root-cause working session).
- **Autonomy / auto-negotiation / I²C training** — `AUTONOMY_PHASE0_AUDIT.md`,
  `AUTONOMY_PHASE0C_SIM_TRACE.md`, `AUTONEG_HW_FAILURE_DIAGNOSIS.md`,
  `I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md`, `I2C_WIRING_AUDIT_2026_05_28.md`,
  `I2C_TO_PHY_REFACTOR_PLAN_2026_06_03.md`, `BRINGUP_DETERMINISM_I2C_PLAN_2026_05_28.md`,
  `i2c_train/`.
- **PHC / PTP Phase-1** — `PHC_*`, `PTP_HW_TEST_PLAN.md`,
  `uvm_addr_translator_{README,vplan}_2026_05.md`.
- **Clocking / timing / SI / CDC** — `ASIC_TIMING_CONSTRAINTS.md`,
  `CLOCK_FORWARDING_REFERENCE_RESEARCH_2026_05_28.md`, `UG903_FORWARDED_CLOCKS_AUDIT_2026_05_28.md`,
  `ZYNQ7_IO_TIMING_SPEC_2026_05_28.md`, `TARGET_A_MMCM_BYPASS_DRAFT_2026_05_28.md`,
  `SCOPE_SIGNAL_INTEGRITY_2026_06_02.md`, `RESET_DISTRIBUTION_PLAN.md`,
  `SPYGLASS_CDC_*`, `RF16K_OVER_MACRO_ROUTING_REPORT_2026_05_29.md`.
- **Sim / test infrastructure** — `SIM_HW_GAP_ANALYSIS.md`, `SIM_GUARD_FEASIBILITY.md`,
  `SIM_REPRO_RESULTS_2026_05_29.md`, `MINIMAL_LOOPBACK_TEST_PLAN_2026_05_28.md`,
  `HW_TEST_SUITE_DEV_LOG.md`, `ILA_PLACEMENT_AUDIT_2026_05_29.md`,
  `ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md`, `DFT_PLAN_2026_05_28.md`,
  `HAL_LINT_REPORT.md`, `RTL_OPTIMISATION_ANALYSIS.md`.
- **Studies / surveys / prior cleanup** — `UCIE_VS_WLINK_ANALYSIS_2026_06_09.md`,
  `PHY_OPEN_SOURCE_SURVEY.md`, `PHY_LAYER_ABSTRACTION{,_IMPACT}.md`,
  `REPO_SIMPLIFICATION_{ASSESSMENT,IMPACT}.md` (a prior doc-cleanup pass),
  `TIDELINK_PHASE0_OBS_20260524_2109.md`, `USER_GUIDE.md` (superseded by the
  bring-up guide).
- **proposals/** — exploratory `phy_align` calibrator proposal + harness.
