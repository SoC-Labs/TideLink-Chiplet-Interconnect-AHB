# TideLink DFT Flow (SCAFFOLD)

This directory holds scaffold scripts for the TideLink + GPIO-PHY ASIC
DFT flow at TSMC 65 nm. **This is scaffolding, not closure.** Real tool
invocations are gated behind licence checks and print clear messages
when the licences are not present.

For strategy, coverage targets and effort estimates, see
[`docs/reference/DFT_PLAN_2026_05_28.md`](../../../docs/reference/DFT_PLAN_2026_05_28.md).

For the gap analysis that motivated this scaffold, see
[`docs/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md`](../../../docs/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md)
§2.5 + CRITICAL #3.

---

## What is here

| File | Purpose |
|---|---|
| `Makefile` | Entry points: `insert_scan`, `insert_mbist`, `run_atpg`, `drc_only` |
| `insert_scan.tcl` | Scan-insertion wrapper (TestMAX / Tessent ScanPro / SpyGlass DFT) |
| `insert_mbist.tcl` | MBIST-controller wrapper for the rf_16k SRAM macro (Tessent MemoryBIST or custom) |
| `README.md` | This file |

## What is not here

The following are explicitly **NOT** delivered by this scaffold; they
are documented in `docs/reference/DFT_PLAN_2026_05_28.md` §7.3 as closure tasks:

- Real scan-inserted netlist
- ATPG pattern sets (`.stil` files)
- BSDL boundary-scan definition (deferred for v1; see DFT_PLAN §5)
- Tessent setup files / dofile sequences
- Custom MBIST RTL (`src/rtl/asic/tidelink_mbist_ctrl.sv`,
  `tidelink_sram_mbist_mux.sv`) — see `insert_mbist.tcl`'s `custom`
  flow path for the authoring task list
- SDC additions for `scan_clk` (must be added to
  `syn/asic/fusion-compiler/inputs/constraints.sdc`)

## How to run

### Survey the scaffold (no licences required)

```bash
make -C syn/asic/dft help
make -C syn/asic/dft show
```

### Try a scan-insertion run (will fail cleanly if no licence)

```bash
# Default tool: TestMAX (Synopsys)
make -C syn/asic/dft insert_scan

# Use Tessent instead
make -C syn/asic/dft insert_scan DFT_TOOL=tessent

# Try SpyGlass DFT for DRC pre-checks (NOT supported for insertion)
make -C syn/asic/dft drc_only
```

Each tool requires its licence in the environment (`SNPSLMD_LICENSE_FILE`,
`MGLS_LICENSE_FILE`, `SPYGLASS_HOME`). If none is set the script will
print a clear ERROR and exit non-zero. This is intended — the scaffold
is meant to make the gates visible, not to silently succeed.

### Try an MBIST-insertion run

```bash
# Default: Tessent MemoryBIST
make -C syn/asic/dft insert_mbist

# Fall back to custom (RTL not yet authored — emits TODO list)
make -C syn/asic/dft insert_mbist MBIST_FLOW=custom
```

### ATPG (full placeholder)

```bash
make -C syn/asic/dft run_atpg
```

Always exits 1 today — see the closure-effort estimate in the plan doc.

## Tunable parameters

All are overridable on the `make` command line:

| Variable | Default | Notes |
|---|---|---|
| `DFT_TOOL` | `testmax` | `tessent` or `spyglass` |
| `MBIST_FLOW` | `tessent` | `custom` falls back to hand-rolled controller |
| `SCAN_STYLE` | `muxd` | `lssd` not yet wired |
| `SCAN_CHAINS` | `8` | 1..16 supported by the chain-spec table |
| `DESIGN` | `tidelink_dft_wrapper` | The test-mode wrapper, not raw `tidelink_top` |
| `NETLIST` | unset | Required for any real insertion run |
| `OUT_DIR` | `./out` | Logs and (eventually) scan-inserted netlist |

## Required reading before running anything for real

1. `docs/reference/DFT_PLAN_2026_05_28.md` — strategy and targets.
2. `src/rtl/asic/tidelink_dft_wrapper.sv` — the test-mode wrapper this
   flow assumes around `tidelink_top`.
3. `src/rtl/asic/tidelink_sram.sv` — the SRAM wrapper that MBIST will
   need to mux into.
4. `syn/asic/fusion-compiler/scripts/setup.tcl` — synth-side library
   variables. The DFT tool needs the same TSMC65 stdcell DBs.
5. `syn/asic/formality/scripts/run_lec.tcl:259-275` — current scan-port
   pin-down. Any scan-insertion run that changes the test-mode protocol
   must be reflected here, or LEC will fail.

## Licence inventory (as of 2026-05-28)

| Tool | Env var | Status in this project |
|---|---|---|
| Synopsys (DC, FC, Formality, TestMAX) | `SNPSLMD_LICENSE_FILE` / `SYNOPSYS_LICENSE_FILE` | Present — used by `syn/asic/fusion-compiler`, `syn/asic/formality` |
| Mentor Tessent | `MGLS_LICENSE_FILE` | UNCONFIRMED — verify with licence admin before MBIST closure starts |
| SpyGlass | `SPYGLASS_HOME` | Present (used for CDC in `cdc/`) |
| Cadence Modus / Encounter Test | `CDS_LIC_FILE` | UNCONFIRMED |

## Read-only paths (CRITICAL)

Do **NOT** modify the following — they are shared lab IP collateral and
other engineers / CI rely on them:

- `/research/AAA/ip_library/**`
- `/research/AAA/phys_ip_library/**`
- `/research/precompiled_mems/TSMC65/**`

The CTL test model at `/research/precompiled_mems/TSMC65/rf_16k/rf_16k.ctl`
is read-only. If the closure phase needs a fix, copy it to
`src/rtl/asic/local_overrides/` and re-point `insert_mbist.tcl`'s
`MEM_CTL_FILE` env var.
