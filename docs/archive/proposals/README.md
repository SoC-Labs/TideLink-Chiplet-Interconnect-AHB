# Historical Design Proposals

This directory archives historical design proposals from the TideLink
development. Each subdirectory captures the original specification, supporting
documentation, and (where applicable) reference RTL or sim collateral that
informed an eventual implementation. The contents are preserved for design
rationale and traceability — the *integrated* RTL/UVM/scripts that supersede
these proposals live in the active source tree (`src/rtl/`, `uvm/`,
`pynq_host/`, and the `deps/axi-chiplet-controller` submodule).

## Subdirectories

- **`phy_align/`** — Original §9 PHY-align proposal plus a self-contained
  cocotb sim environment (Makefile, `tb_autocal.sv`, `test_autocal.py`,
  `wlink_phy_align_calibrator.sv`, plus `README.md` and
  `INTEGRATION_REPORT.md`). The integrated calibrator now lives at
  `src/rtl/tidelink_phy_align_calibrator.sv`; the design intent and original
  validation harness are retained here.

- **`i2c_train/`** — I²C-coordinated training protocol design docs
  (`I2C_TRAIN_PROTOCOL.md`, `PHYSICAL_WIRING.md`, `UVM_TEST_PLAN.md`) and a
  reference state-machine skeleton (`tidelink_autoneg_train_states.sv`). The
  production integration lives in
  `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv`; the protocol
  spec and UVM plan here remain the canonical design rationale.

## Provenance

These trees were moved from the top-level `staging/` directory on 2026-05-29
as part of the post-bring-up repo cleanup. Sim build artefacts (`sim_build/`,
`__pycache__/`, `*.vcd`, `results.xml`, `ucli.key`) were removed in the same
operation — those are reproducible from the Makefile and never belonged in
git.
