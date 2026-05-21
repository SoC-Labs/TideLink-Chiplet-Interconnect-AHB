# TideLink chiplet — ASIC partition drop

This directory is the canonical chip-top hand-off location for the
`tidelink_top` partition as a hard macro. `make asic_stage` (or the
top-level `make asic_stage`) populates `<MODULE>/` with everything a
chip-top integrator needs to consume the partition.

## Layout

```
imp/ASIC/
├── Makefile                     # staging entry point
└── tidelink_top_full/           # default partition cut (override MODULE=…)
    ├── tidelink_top.gds.gz      # GDSII hard macro (the deliverable)
    ├── tidelink_top.v           # gate netlist (logic only)
    ├── tidelink_top.pg.v        #   …with PG (VDD/VSS) pins — for LVS
    ├── tidelink_top.sdc         # boundary timing constraints
    ├── tidelink_top.def         # placement DEF
    ├── tidelink_top.lef         # physical abstract (for chip-top PnR)
    ├── tidelink_top.upf         # power intent (single PD_TOP domain)
    ├── tidelink_top.sdf         # slow-corner SDF alias
    ├── tidelink_top.scen_slow.sdf       # per-scenario back-annotation
    ├── tidelink_top.scen_fast.sdf
    ├── tidelink_top.scen_*.spef.rc{best,worst}_{-40,125}.spef  # × 8
    ├── tidelink_top.scen_*.spef.spef_scenario                   # corner index
    ├── etm/                     # PrimeTime boundary timing models
    │   ├── tidelink_top_slow.{lib,db} + _constr.pt
    │   └── tidelink_top_fast.{lib,db} + _constr.pt
    ├── svf/                     # Formality LEC guidance (per stage)
    └── reports/                 # signoff + DRC + PG-deepdive reports
```

## What this drop contains, role-by-role

| File | Role |
|---|---|
| `.gds.gz` | Stream-out for chip-finish DRC / LVS / GDS merge at top |
| `.v` | Logic netlist for chip-top HDL integration / LEC impl |
| `.pg.v` | Power-aware variant for LVS source / power-aware gate-sim |
| `.sdc` | Boundary timing constraints to propagate at chip-top STA |
| `.sdf` | Slow-corner back-annotation alias (legacy un-suffixed name) |
| `.scen_slow.sdf` | Slow / max-delay back-annotation per scenario |
| `.scen_fast.sdf` | Fast / min-delay back-annotation per scenario |
| `.scen_*.spef.*.spef` | Per-RC-corner extracted parasitics for chip-top hierarchical STA |
| `.def` | Floorplan + placement DEF — place the partition as a hard macro |
| `.lef` | LEF physical abstract — boundary / pin locations / blockage |
| `.upf` | Boundary power intent — chip-top supply-set wiring |
| `etm/*_slow.{lib,db}` | PrimeTime ETM, slow @ rcworst @ 125 °C (max-delay) |
| `etm/*_fast.{lib,db}` | PrimeTime ETM, fast @ rcbest @ -40 °C (min-delay) |
| `svf/*.svf` | Per-stage Formality SVF guidance for chip-top re-LEC |

## Build / rebuild

From project root:
```bash
make gdsii              # FC PnR through fc_abstract
make asic_stage         # stage the drop into imp/ASIC/$(MODULE)/
make fc_all             # gdsii + Formality LEC (CI / tape-in)
make fc_etm             # PrimeTime boundary ETM (separate; needs fc_abstract)
```

From the FC tree directly (more granular):
```bash
make -C syn/asic/fusion-compiler help    # full target list
```

Override the partition cut: `make asic_stage MODULE=tidelink_top`.

## Verifying a received drop

If you receive this drop from someone else:
```bash
syn/asic/scripts/verify_partition_handoff.sh
```
checks the SHA256 manifest from `reports/06_abstract_manifest.txt`
against the bytes on disk. Exit 0 = clean.

## Chip-top integration — what you need to know

1. **Single power domain** — `VDD` = 1.08 V core, `VSS` = 0 V (see `.upf`).
   Tie both at the chip-top supply set. No isolation / level-shift /
   retention strategy needed at the boundary.
2. **Required clocks (5)** — `hclk` (primary, 4 ns), `phc_clk`,
   `user_ref_clk`, `scan_clk`, `pad_clk_rx`. All declared as
   asynchronous clock groups in the `.sdc`.
3. **Required resets (3, all async, all set_false_path’d)** — `hresetn`,
   `phc_resetn`, `poresetn`. Treated as async false-path from the SDC.
4. **AHB bus direction note** — `ahb_mng_hready` is an INPUT (slave →
   manager). This was a bug in earlier RTL and is corrected here.
   Verify your chip-top side connects it the right way.
5. **NDM block alternative** — instead of reading `.lef`+`.def`+`.sdc`
   into chip-top FC, you can open the partition's NDM block directly
   from `<repo>/syn/asic/fusion-compiler/work/<MODULE>.dlib/` at
   `${TOP}/signoff.design` for NDM-based hierarchical PnR.
6. **Sign-off status** — see `reports/07_summary.rep`. As of this
   drop the partition is PnR-clean (timing closed, LEC PASS, ETM
   produced) with two characterised dispositions:
   - `check_pg_connectivity` shows ~4.6k floating reports —
     **PASS\*** in `reports/07_summary.rep`; the wire-stub-fragment
     artefact is independently audited in `reports/08_pg_deepdive.rep`
     and is NOT a real disconnect (0 logical floats).
   - `check_routes` reports ~9 End-Of-Line spacing DRCs clustered in
     the std-cell band shadowing the rf_16k macro (bottom-right corner).
     Down from 99 via the in-block 3-pass route_eco loop; the residuals
     are structural at this util / floorplan. **Chip-top ECO required**
     OR negotiate a foundry waiver.
7. **LEC residuals** — 256 Wlink Chisel auto-gen DFF rewrites are
   iteratively don't-verified during LEC. All downstream cones verify
   equivalent; external behaviour is provably equivalent. Same pattern
   as the ahb_qspi reference partition.
8. **NOT YET RUN, for tape-out** — foundry sign-off DRC (via ICV),
   LVS, IR-drop / EM analysis, full SI delta-delay. These need the
   cln65lp deck + RedHawk / Voltus setup the partition flow doesn't
   ship with.

## Provenance

Each build's `MANIFEST.md` carries:
- The exact FC block source (`signoff.design`)
- Timestamp + commit (see `git log -1 -- <file>`)
- Per-file SHA256 + size
- Scenario coverage (was scen_fast available, was hold characterised)

To re-derive the build:
```bash
make fc FC_CORE_UTILIZATION=0.70
```
(or whatever knobs the MANIFEST records in the "Reproducing this build"
section)
