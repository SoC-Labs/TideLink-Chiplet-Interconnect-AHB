# `cocotb/phy_align/` — PHY-layer alignment tests

These tests exercise the per-lane bit-slip + training-pattern alignment
mechanism (BRINGUP_REPORT.md §9). They are physically separated from the
`cocotb/wlink_pair/` integration tests so the alignment work is *extraction-
ready* — see [`deps/axi-chiplet-controller/logical/phy-align/README.md`](../../deps/axi-chiplet-controller/logical/phy-align/README.md)
for the future repo split.

## Contents

| File | Purpose |
|---|---|
| `wlink_lane_checker.sv` | Per-lane training-pattern lock detector (8-lane wrapper + single-lane core). Inputs `lane_data[127:0]` (8 × 16-bit per-lane words from the deserialiser); outputs `lane_locked[7:0]`. Compares each lane against a period-8 byte pattern; asserts the lane's `locked` after 16 consecutive matches. Used by `tb_top.sv` to expose per-lane alignment status to the cocotb test. |
| `test_pair_align.py` | The §9 calibration test. Sweeps per-lane bit_slip 0..7 looking for `lane_locked` on each side, applies the calibrated slips, exits training mode, asserts FCSM advances to state=4 with cr_pkt_seen_rx on both sides. |
| `Makefile` | Delegates to `../wlink_pair/Makefile` (which owns the testbench top compile) with the correct `MODULE` + `PYTHONPATH`. |

## Run

```sh
cd cocotb/phy_align
make SKID_BITS=3         # default test, skid amount 3 — the FPGA-observed shift
make SKID_BITS=5 MODULE=test_pair_align
```

Tested SKID_BITS values: 0, 1, 3, 5, 7 — all PASS (calibration converges, link
comes up with FCSM advancing to state=4).

## How this relates to the §9 RTL changes

`wlink_lane_checker.sv` here is **the receive-side checker** — a wrapper module
that watches the deserialiser's output. It works alongside the in-place edits to
`WavD2DGpio.v`, `WavD2DGpioRx.v`, `WavD2DGpioTx.v` in the Wavious Wlink generated
Verilog tree. Those edits add:

- `swi_bit_slip[23:0]` — 8 lanes × 3 bits, per-lane right-rotation amount.
- `swi_training_mode` — when high, TX serialiser sources fixed per-lane training
  bytes instead of LL data.
- Per-lane training byte selection (period-8 bytes, see `wlink_lane_checker.sv`
  inline comments for the rationale on rotational-period choice).

The current `cocotb/phy_align/` test reaches into the DUT hierarchy via cocotb
to drive `swi_bit_slip` and `swi_training_mode` directly; the production version
would drive these from APB. See BRINGUP_REPORT.md §9 for the full design.

## Extraction plan

When the PHY moves to its own repo (`wlink-phy-align/` or similar) this
directory becomes the PHY repo's cocotb entry point. The current
`test_pair_align.py` is a *pair-level* test (master+slave Wlink full stack) and
would live in the TideLink-side repo; PHY-only tests (drive pad bundle on one
side, observe Link2PHY bundle on the other) would be added here. The
`wlink_lane_checker.sv` module is fully self-contained and moves cleanly.
