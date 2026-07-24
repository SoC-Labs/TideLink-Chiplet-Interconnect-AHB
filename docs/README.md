# TideLink — Documentation

The documentation set for the **TideLink** chiplet-interconnect subsystem
(Wlink link layer + XHB500 + FIFO + a dedicated flow-control node + the GPIO
PHY consumed from `deps/tidelink-phy`).

**New here?** Read [ARCHITECTURE.md](ARCHITECTURE.md), then
[INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md).
**Bringing up hardware?** Start at
[reference/TIDELINK_BRINGUP_USER_GUIDE.md](reference/TIDELINK_BRINGUP_USER_GUIDE.md)
— and on a KR260, read [KR260_AFI_CHECK.md](KR260_AFI_CHECK.md) **first**.

## Design and integration

| Document | Covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Component/module map and hierarchy, the four AHB ports + APB, clock/reset/CDC structure, data widths, the GPIO PHY's role |
| [ARCHITECTURE_PHY_LINK.md](ARCHITECTURE_PHY_LINK.md) | As-implemented PHY + link-layer architecture |
| [IMPLEMENTATION.md](IMPLEMENTATION.md) | Functional spec — data path, credit/doorbell flow control, auto-negotiation & role arbitration, the I²C training handshake, cross-lane deskew + lane masking, single-phase PTP |
| [REGISTER_MAP.md](REGISTER_MAP.md) | The unified APB register address space |
| [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) | Consuming the subsystem — environment/submodules, flists & build targets, host-SoC wiring, FPGA and ASIC flows, APB bring-up sequence |
| [ETHERNET_CHIPLET_INTEGRATION.md](ETHERNET_CHIPLET_INTEGRATION.md) | Integrating the Ethernet chiplet across the link |
| [TIDECHART_G1_SEQUENCING_CONTRACT.md](TIDECHART_G1_SEQUENCING_CONTRACT.md) | Inter-IP sequencing contract |

## Hardware bring-up and operation

| Document | Covers |
|---|---|
| [reference/TIDELINK_BRINGUP_USER_GUIDE.md](reference/TIDELINK_BRINGUP_USER_GUIDE.md) | The bring-up user guide |
| [AUTONOMOUS_BRINGUP.md](AUTONOMOUS_BRINGUP.md) | How zero-poke autonomous bring-up works |
| [BOARD_DEPLOY_RUNBOOK.md](BOARD_DEPLOY_RUNBOOK.md) | Deploying to a board pair |
| [KR260_AFI_CHECK.md](KR260_AFI_CHECK.md) | The PS↔PL AFI width check — the #1 KR260 landmine |
| [KR260_BOARD_ENV.md](KR260_BOARD_ENV.md) | KR260 board environment and survival notes |
| [KR260_FIRST_SESSION_RUNBOOK.md](KR260_FIRST_SESSION_RUNBOOK.md) | Register-by-register KR260 first session |
| [PTP_DEMO_RUNBOOK.md](PTP_DEMO_RUNBOOK.md) | Running the PTP time-sync demo |
| [LINK_RECOVERY_MECHANISM.md](LINK_RECOVERY_MECHANISM.md) | `SWI_FORCE_RECAL` and in-field link recovery |

## Verification

| Document | Covers |
|---|---|
| [VERIFICATION_PLAN.md](VERIFICATION_PLAN.md) | cocotb + UVM test matrices, HW bring-up suite, safety gates, sign-off criteria |
| [TIDELINK_FPGA_VERIFICATION_PLAN.md](TIDELINK_FPGA_VERIFICATION_PLAN.md) | F01–F20 hardware verification matrix and exit checklist |
| [SIM_GATE_COVERAGE.md](SIM_GATE_COVERAGE.md) | What each `make sim_gate` suite protects |
| [TESTING.md](TESTING.md) | Testing runbook — the proven incantations |
| [ERROR_INJECTION_FINDINGS.md](ERROR_INJECTION_FINDINGS.md) | Error-injection results; basis for the gate's XFAIL sentinel |

## Why a shipped setting is the way it is

Read the relevant note before changing the corresponding default or constraint.

| Document | Explains |
|---|---|
| [CRC_ROOTCAUSE.md](CRC_ROOTCAUSE.md) | The link CRC power-on default |
| [RXFIFO_TWIN2_DISPOSITION.md](RXFIFO_TWIN2_DISPOSITION.md) | Why `ENABLE_AHB_WRITE` is tied off in silicon |
| [R6_HARDEN_SWI_OPTIONS.md](R6_HARDEN_SWI_OPTIONS.md) | Why `HARDEN_SWI_ENABLE=0` on the shipped targets |
| [XHB_WINDOW_SKEW_ROOTCAUSE.md](XHB_WINDOW_SKEW_ROOTCAUSE.md) | Why a particular bench stall is not a bug |
| [WAIVER_F14B_DATAMODE_WEDGE.md](WAIVER_F14B_DATAMODE_WEDGE.md) | A **known limitation** shipped under waiver |
| [ETHERNET_PTP_CHAIN_GAP.md](ETHERNET_PTP_CHAIN_GAP.md) | The Ethernet→PHC→PTP contract and its open gap |

## `reference/` — specifications and long-form references

| Document | Covers |
|---|---|
| [TIDELINK_SPECIFICATION.md](reference/TIDELINK_SPECIFICATION.md) | The canonical subsystem specification and design justification |
| [PHY_ARCHITECTURE_REFERENCE.md](reference/PHY_ARCHITECTURE_REFERENCE.md) | GPIO PHY internals, calibrator and lane mechanics |
| [AUTONEG_PROTOCOL.md](reference/AUTONEG_PROTOCOL.md) | Auto-negotiation protocol specification |
| [PTP_PROTOCOL.md](reference/PTP_PROTOCOL.md) | PTP-over-link protocol specification |
| [i2c_train/I2C_TRAIN_PROTOCOL.md](reference/i2c_train/I2C_TRAIN_PROTOCOL.md) | I²C sideband training protocol |
| [i2c_train/PHYSICAL_WIRING.md](reference/i2c_train/PHYSICAL_WIRING.md) | I²C sideband physical wiring |
| [ASIC_TIMING_CONSTRAINTS.md](reference/ASIC_TIMING_CONSTRAINTS.md) | Source-sync timing rationale — **cited by the shipped constraint files** |
| [FC_NODE_REGISTRY.md](reference/FC_NODE_REGISTRY.md) | Wlink `data_id` allocation registry |
| [DEPENDENCIES.md](reference/DEPENDENCIES.md) | Submodules, vendor IP, and edit policy |
| [SPYGLASS_CDC_SIGNOFF.md](reference/SPYGLASS_CDC_SIGNOFF.md) | CDC sign-off record |
| [DETERMINISM_VALIDATION.md](reference/DETERMINISM_VALIDATION.md) | Determinism metric and validation procedure |
| [SHORTCOMINGS.md](reference/SHORTCOMINGS.md) | Known-limitations register |
| [HW_TEST_SUITE.md](reference/HW_TEST_SUITE.md) | Design of the numbered hardware test suite |
| [DFT_PLAN_2026_05_28.md](reference/DFT_PLAN_2026_05_28.md) | DFT scan/MBIST insertion flow |
| [LANE_LOCK_ROOT_CAUSE.md](reference/LANE_LOCK_ROOT_CAUSE.md) | Lane-lock analysis and the known-good-builds table |

## A note on history

This repository previously carried a large `docs/archive/` tree of dated
investigation notes, bring-up session logs, bug forensics and programme plans.
Those were removed in the 2026-07 cleanup — they were point-in-time working
records, not maintained documentation, and their durable conclusions are folded
into the documents above. **Nothing was lost: they remain in the git history.**
The specifications and long-form references that had been living under
`archive/` were *promoted* into [`reference/`](reference/) rather than deleted.
