# CDC evidence: TL-051 (R1 I2C pad sync) and TL-055 (H30 swreset single flop)

Run 2026-10-16 on main `eb94efac7d91aa55cf6318ffe54ac8cc51220883`. Tool: Synopsys SpyGlass
`vT-2022.06-SP2` (linux64, Nov 29 2022), goal `cdc/cdc_verify_struct`, licence obtained.

## What was run

The existing compute-die CDC harness (off-repo, td-bisect scratch:
`rev2-port-h30-h31-evidence/cdc/{run.sh,run_cdc.sh,classify.py,compare_cdc.py}`), unchanged.
Design = the compute payload snapshot (`scan2_rtl_snapshot.f`, top `cdc_chiplet_top`); ONLY the three
override files (`axi_chiplet_controller.sv`, `tidelink_phy_align_calibrator_v2.sv`,
`WavD2DGpio_v2.v`) come from this main tip. Two runs, otherwise identical (229 s and ~230 s wall):

| run  | controller                                                                                   |
|------|----------------------------------------------------------------------------------------------|
| main | unmodified main `eb94efac`                                                                   |
| mut  | main with BOTH fixes reverted: `i2c_*_i_sync = i2c_*_i` (raw pad) and `.swreset(<comb OR-merge>)` |

## Result

| metric (classify.py / moresimple.rpt)                         | main | mut (fixes reverted) |
|---------------------------------------------------------------|-----:|---------------------:|
| class R1: unsync rows with source `soc_i2c_(scl\|sda)_i_*`     |    0 |                   36 |
| class R2: unsync rows from `swi_training_mode_r`              |    0 |                    0 |
| unsync rows touching an i2c pad or `swreset` (Ac_unsync01/02) |    0 |                   36 |
| `Ac_glitch03` rows naming `swreset`                           |    0 |                    2 |
| `Ac_glitch03` total                                           |   56 |                   58 |
| `Ac_unsync01` / `Ac_unsync02` total                           | 333 / 831 | 361 / 887 |

The mutant has 84 more unsynchronised rows than main: 36 are class R1; the other 48 are
classified W3 (Wlink async-FIFO storage, 528 vs 480). I did not investigate why the W3 count moves
with the reverted controller; it is not an R1/R2/H30 class.

main: R1 = 0, R2 = 0, and no unsynchronised or glitch row names an I2C pad or `swreset`. The
mutant reproduces the original findings (36 R1 rows, 2 `u_calibrator.swreset_s1` can-glitch rows),
so the classifier and report parser demonstrably go red when the fixes are absent.

Not part of these two items, observed in the same run: R3 (`swi_sync_lane_mask_r`, 12 rows; NOT
a defect on the ASIC build per TL-051 text) and 148 rows the classifier does not assign
(`gpio.gpiotx_*.clk_en_qual`, "Qualifier not found"; classifier predates this payload). Neither
changes between main and mut.

## Caveats

* Snapshot payload, not the main tree's own flist: the rest of the die is the compute snapshot
  of 2026-09-23. Only the three override files are main's.
* A CDC tool shows the crossing is synchronised; it is not a silicon metastability proof.
* The classifier harness is not in the repo. What IS in the repo and runs without a licence is
  the structural gate `make cdc_sync_structure` (`scripts/ci/cdc_sync_structure.py`) with its
  must-fail control `scripts/ci/tests/test_cdc_sync_structure.py`, which keeps these two fixes
  from regressing silently.
