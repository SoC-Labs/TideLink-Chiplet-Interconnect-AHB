# Cadence HAL Lint Report — TideLink RTL (sign-off grade)

Snapshot taken on `feat/td-combined` at tip **`ac579cf`** after the
post-refactor hygiene pass (commits `6e4265a`, `ce91961`, `de30044`,
`091fd3c`, `8c63e1f`, `35e9adc`, `3f02334`, `ac579cf`). HAL is the
Cadence sign-off-grade lint flow used by the ASIC backend; the
companion `RTL_LINT_REPORT.md` is the (faster but non-sign-off)
Verilator pass.

The TideLink RTL surface is presented separately from vendor IP
(`deps/axi-chiplet-controller/...`, XHB500, CMSDK BP210) — vendor noise
is flagged but is out-of-scope for this report.

## Tool / environment

```
hal(64) 22.03-s005    (/eda/cadence/xcelium/tools/bin/hal)
TIDELINK_HOME         = /home/dam1n19/td_idelay_wt
ARM_IP_LIBRARY_PATH   = /research/AAA/ip_library
CMSDK_DIR             = $ARM_IP_LIBRARY_PATH/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0
CMSDK_FPGA_SRAM_V     = $ARM_IP_LIBRARY_PATH/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v
```

Waiver rule file: `lint/hal.tcl` (AMBA/AHB/APB naming + style + the
small list of structural waivers documented inline at the top of the
file). No changes to the waiver file were made by this run.

## How to reproduce

```sh
cd $TIDELINK_HOME/lint

# Per-module suite (default Makefile matrix — top = each module in isolation)
make clean
make lint-each

# Full ASIC top elaboration (the sign-off-relevant view)
hal -64bit -sv -top tidelink_top -check ALL_RTL                                    \
    -logfile tidelink_top_full_asic_hal.log -xmlfile tidelink_top_full_asic_hal.xml \
    -messages -stats -lintpragma                                                   \
    -file $TIDELINK_HOME/lint/hal.tcl                                              \
    -irunargs "-allowredefinition -timescale 1ns/1ps"                              \
    -f $TIDELINK_HOME/flist/tidelink_top_full_asic.flist
```

Two upstream-vendor blockers required `-irunargs` overrides on the full
elaboration:

1. **`xhb500_*` duplicate units** — the XHB500 vendor IP ships the same
   `xhb500_flop`/`_or`/`_sync`/`_xor`/`xhb500_bypass_regd_slice` etc.
   module names under BOTH the `xhb_chiplet_mst` and `xhb_chiplet_slv`
   generated directories (the flist needs both so the AHB-master and
   AHB-slave bridge directions are present). xrun's `-allowredefinition`
   makes the second compile silently take precedence. Verilator
   (`RTL_LINT_REPORT.md`) hits the same duplication but tolerates it by
   default.
2. **Missing `\`timescale` directives in vendor IP** — `i2c_master.v`,
   `axis_fifo.v`, etc. in `deps/axi-chiplet-controller/logical/i2c/rtl/`
   have no `\`timescale`. xrun escalates this to `*F,CUMSTS` when any
   other module in the design DOES carry a timescale. Forcing
   `-timescale 1ns/1ps` at the elaborator gives every unit the same
   default and elaboration completes.

Neither workaround masks any of the lint findings below — they just let
the compile-and-elaborate phase reach the lint stage.

## Headline counts

### Per-module matrix (`make lint-each`)

| Module                | Top (elaborated)        | Errors | Warnings |
|-----------------------|-------------------------|-------:|---------:|
| `tidelink_fifo_ctrl`  | `tidelink_fifo_ctrl`    |      0 |        5 |
| `tidelink_returner`   | `tidelink_returner`     |      0 |        0 |
| `tidelink_apb_regs`   | `tidelink_apb_regs`     |      0 |        4 |
| `tidelink_fifo`       | `tidelink_fifo_mem`     |      0 |       13 |
| `tidelink`            | `tidelink_fifo` (FPGA)  |      0 |       10 |

Each row is a stand-alone elaboration via the matching `flist/*.flist`
under the Makefile-baked module-to-top mapping. The FIFO subsystem
modules (`tidelink_fifo_ctrl`, `tidelink_returner`, `tidelink_apb_regs`,
`tidelink_fifo`) are sign-off-clean (0 errors). Their warnings are
style-class (post-existing-waiver residue) and are itemised below.

### Full ASIC elaboration (`tidelink_top_full_asic.flist`, top = `tidelink_top`)

| Engine     | Errors | Warnings |
|------------|-------:|---------:|
| `halcheck` |    112 |     ~8 k |
| `halsynth` |     11 |       —  |
| `halstruct`|      5 |    3,734 |

Of the `halcheck`/`halsynth`/`halstruct` errors, only **5 originate in
TideLink RTL (`src/rtl/`)**. The remaining 123 errors live in
`deps/axi-chiplet-controller/logical/i2c/` (107) and a handful of other
vendor files. **The 5 TideLink RTL errors are the only sign-off
blockers within scope of this report.**

For reference, `tidelink_top_asic.flist` (TideLink RTL only, no Wlink
chiplet controller IP) gives 15 errors / 35 warnings — 4 TideLink RTL
(`VERCAS`+`CLKDMN`x3) plus 12 `UNCONI` artefacts from the FC adapter /
PTP / perf input ports that ARE driven once the Wlink IP is added back
in. The 12 `UNCONI`s are NOT real findings, just consequences of
manually deleting the chiplet-controller block from the flist for the
RTL-only view.

### TideLink RTL warning breakdown (full elaboration, `src/rtl/` only)

| Class      | Count | Likely cause |
|------------|------:|--------------|
| `RSTDMN`   |   152 | reset-domain crossings (PHY-align/calibrator cross hclk↔core resets) |
| `ASNRST`   |    72 | active-high async resets in §9 PHY-align modules (lane_checker, calibrator) |
| `BITUNS`   |    36 | unsized constants like `3'b0` (no explicit MSB bit) in top tie-offs |
| `UNCONN`   |    32 | unconnected output ports on XHB500 super-set (qos/region/nsaid debug) |
| `RSTDAT`   |    18 | data sampled at a reset-domain boundary (CDC by design) |
| `REVROP`   |    14 | reversed-range operators (cosmetic; widths still match) |
| `ULCMPE`   |    10 | unsigned/literal comparison expressions (calibrator counters) |
| `MXUANS`   |    10 | mixed unsigned/signed in arithmetic (calibrator sweep maths) |
| `IPSFOU`   |    10 | input port sourcing fan-out warning (multiplexed input nets) |
| `IOCOMB`   |    10 | combinational output at top level (AHB/APB protocol-by-design) |
| ...        |   ... | (full per-file breakdown in `tidelink_top_full_asic_hal.log`) |

Per-file TideLink RTL warning concentration:

| File                                       | Warnings |
|--------------------------------------------|---------:|
| `src/rtl/tidelink_phy_align_calibrator.sv` |      136 |
| `src/rtl/tidelink_top.sv`                  |       76 |
| `src/rtl/tidelink_ptp_servo.sv`            |       60 |
| `src/rtl/tidelink_perf.sv`                 |       55 |
| `src/rtl/tidelink_lane_checker.sv`         |       20 |
| `src/rtl/tidelink_ptp.sv`                  |       18 |
| `src/rtl/tidelink_phc_cdc.sv`              |       18 |
| `src/rtl/tidelink_fc_adapter.sv`           |       18 |
| `src/rtl/tl_addr_trans_regs.sv`            |       14 |
| `src/rtl/tidelink_addr_translator.sv`      |        9 |
| (12 other files, ≤8 warnings each)         |        … |

## Sign-off blockers — full listing (5)

These are the ERROR-class messages inside TideLink RTL. They are the
items that gate ASIC sign-off; nothing else in `src/rtl/` is currently
escalated above warning.

### 1. `VERCAS` — case-only identifier collision

```
*E,VERCAS (../src/rtl/tidelink_perf.sv,38|0):
   Identifier 'LOCAL_LINK_STATE_W' reused with a case difference.
```

`tidelink_perf.sv:38` declares `parameter LOCAL_LINK_STATE_W = 5`; the
same file (line 338) and downstream wires (`local_link_state_w`,
`local_link_state_o`, `local_link_state_prev_r`) use the lowercase form
as a real signal name. Case-only differences are unsafe under
case-insensitive flows (some legacy VHDL tooling). Suggested cause:
parameter naming; safest fix is to rename the parameter to e.g.
`LOCAL_LINK_STATE_WIDTH` or `LL_STATE_W`. Pre-existing — `tidelink_perf.sv`
was not modified by any of the listed refactor commits.

### 2. `RTLINI` — variable initialised in declaration

```
*E,RTLINI (../src/rtl/tidelink_phy_align_calibrator.sv,279|0):
   A variable/signal 'tb_early_exit_force_q' in an RTL description is
   initialized in its declaration.
```

This is the testbench-force hook documented in the calibrator comment
(`reg tb_early_exit_force_q = 1'b0;`) — initialised to `0` so RTL elab is
unambiguous; cocotb hierarchical-force lifts it before `role_locked`
rises. The `= 1'b0` initialisation is not synthesisable on all flows;
either drop the initialiser and rely on default-zero, or move the
override into a proper APB-visible register. The comment-block
(lines 270-280) explicitly explains the pattern. The
`verilator lint_off UNDRIVEN` wrapper is already present (because
nothing drives it in RTL); HAL is more strict.

### 3-5. `CLKDMN` — CDC findings (3)

```
*E,CLKDMN (../src/rtl/tidelink_phc_cdc.sv,494|0):
   Signal from clock domain 'tidelink_top.hclk' is crossing into domain
   of clock 'tidelink_top.phc_clk' at flip-flop
   'tidelink_top.u_phc_cdc.p_hw_adj_ns_incr_frac' without proper
   synchronization.

*E,CLKDMN (../src/rtl/tidelink_phc_cdc.sv,432|0):  (p_hw_set_nanoseconds)
*E,CLKDMN (../src/rtl/tidelink_phc_cdc.sv,431|0):  (p_hw_set_seconds)
```

These are the data-payload registers in three `hclk → phc_clk`
handshake-CDC paths (Path-4 set-time, Path-6 freq-adjust). The req/ack
toggles ARE correctly 2-flop synchronised and tagged
`(* cdc_sync = "true" *)`, but the data is held stable while the
synchroniser settles, then registered on the destination side when the
req edge passes the second flop. HAL does not recognise the toggle-
handshake pattern, so it sees a multi-bit unsynced data path and
flags it.

**Suggested action:** add a HAL waiver targeted at these three
registers, citing the toggle-handshake construct (already documented
in `tidelink_phc_cdc.sv` headers for Path 4 and Path 6). The waiver
should be local (per signal name) — NOT a blanket `-nocheck CLKDMN`,
which would mask any real CDC bug introduced later.

## Vendor / out-of-scope errors (informational)

The remaining 118 errors in the full elaboration are all in vendor IP:

| Source                                            | Errors | Note |
|---------------------------------------------------|-------:|------|
| `deps/axi-chiplet-controller/logical/i2c/`        |    107 | `RTLINI`/`SIZMIS` style — Alex Forencich opencores I2C; not on the silicon-critical TX/RX path |
| `deps/axi-chiplet-controller/logical/top/`        |      5 | `RTLINI`+`GLTASR`+`TERMST` on `tidelink_autoneg.sv` and `axi_chiplet_controller.sv` (controller wrapper, vendor-side) |
| `deps/axi-chiplet-controller/logical/wlink/`      |      3 | `GLTASR`+`OUTRNG` in `WavAnd.v` and `WavD2DGpio.v` |
| Other                                             |      3 |   |

These are flagged here but **not in scope to fix in this branch**.
They are upstream of the TideLink integration (chiplet controller is
Chisel-generated; XHB500 is Cadence-generated; CMSDK is ARM). The path
forward is either an upstream patch or an Avery/Cadence waiver bundle
that the ASIC backend team supplies as part of the IP-handoff.

## New since refactor — delta analysis

Comparing the post-refactor (tip `ac579cf`) lint output to the listed
refactor commits:

- The five sign-off blockers above (`VERCAS`, `RTLINI`,
  `CLKDMN`x3) all live in files that the listed refactor commits
  **did not modify**. The only commit touching `tidelink_phy_align_calibrator.sv`
  is `8c63e1f`, which is a header-banner-only doc-drift fix
  (`wlink_*.sv` → `tidelink_*.sv` filename and inline comment edits, 8
  lines net). It does not affect `tb_early_exit_force_q` at line 279.
  → **No new errors introduced by the refactor.**

- The refactor deleted `tidelink_phy_align_regs.sv`, the flat
  `tidelink_fifo.sv`, the flat `tidelink_fifo_ctrl.sv`,
  `tidelink_addr_translation.sv`, and `tidelink_apb_addr_ctrl.sv`. None
  were on any flist, so deleting them changed disk only — HAL output
  is identical to a hypothetical pre-refactor run on the same flists.

- `ce91961` (USE_CLKBUF in-PHY removal in `WavD2DGpioRx.v`) is inside
  `deps/axi-chiplet-controller/`. HAL's vendor-side warnings on that
  file are unchanged in class — only the in-PHY BUFG cell text is gone.
  → **No regression in the TideLink RTL surface.**

## Open items / waivers needed

Categorised by who should act:

| ID | Class    | File / line                                    | Action                                                                                                   |
|----|----------|------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| H1 | `VERCAS` | `src/rtl/tidelink_perf.sv:38`                  | Rename `LOCAL_LINK_STATE_W` → `LOCAL_LINK_STATE_WIDTH` (or similar) — RTL fix, not a waiver candidate    |
| H2 | `RTLINI` | `src/rtl/tidelink_phy_align_calibrator.sv:279` | Remove `= 1'b0` initialiser or promote to a register — RTL fix preferred; otherwise targeted waiver      |
| H3 | `CLKDMN` | `src/rtl/tidelink_phc_cdc.sv:431, 432, 494`    | Per-signal HAL waiver citing the toggle-handshake construct (already RTL-correct; documented in headers) |
| V1 | various  | `deps/axi-chiplet-controller/logical/i2c/`     | Upstream patch OR waiver bundle from chiplet-controller team — out of scope for this branch              |
| V2 | various  | `deps/xhb500/...` (duplicate units)            | `-irunargs -allowredefinition` accepted; XHB500-team aware                                               |

Style/class warnings inside `tidelink_phy_align_calibrator.sv` (the
136-warning bucket) are pre-existing and have been quarantined in the
hal.tcl `-nocheck` block where the class is universally style. The
remaining mix (`RSTDMN`, `ASNRST`, `BITUNS`, `RSTDAT`) deserves a
post-tapeout cleanup pass but does NOT gate sign-off — none promote
to ERROR.

## Files produced

All logs and XML reports are in `lint/`:

- `tidelink_fifo_ctrl_hal.log / .xml`
- `tidelink_returner_hal.log / .xml`
- `tidelink_apb_regs_hal.log / .xml`
- `tidelink_fifo_hal.log / .xml`
- `tidelink_hal.log / .xml`
- `tidelink_top_asic_hal.log / .xml`           (RTL-only view, no Wlink IP)
- `tidelink_top_full_asic_hal.log / .xml`      (full ASIC sign-off elaboration)
- `hal.design_facts`                            (most recent module's design facts)

The XML reports can be loaded in the Cadence Ncbrowse GUI via
`make gui MODULE=tidelink_top_full_asic` (after the same `-irunargs`
override).

## Commit

This report was generated at `feat/td-combined` tip **`ac579cf`**.
