# Verilator Lint Report — TideLink RTL

Snapshot taken on `feat/td-combined` after the post-refactor hygiene pass
(commits `de30044`, `091fd3c`, `8c63e1f`). The numbers below describe the
RTL surface only — vendor IP (CMSDK, XHB500, axi-chiplet-controller,
Wlink, WavD2DGpio) is filtered out of every "src/rtl" total.

## How to reproduce

```sh
export TIDELINK_HOME=/home/dam1n19/td_idelay_wt
export ARM_IP_LIBRARY_PATH=/research/AAA/ip_library
export CMSDK_DIR=$ARM_IP_LIBRARY_PATH/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0
export CMSDK_FPGA_SRAM_V=$ARM_IP_LIBRARY_PATH/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v

envsubst < $TIDELINK_HOME/flist/tidelink_fpga.flist \
  | grep -v '^//' | grep -v '^#' | grep -v '^$' > /tmp/fpga.flist.resolved

verilator --lint-only -sv -Wall \
  -Wno-VARHIDDEN -Wno-SYMRSVDWORD \
  -Wno-DECLFILENAME -Wno-PINMISSING -Wno-BLKANDNBLK \
  --top-module tidelink_top \
  $(cat /tmp/fpga.flist.resolved)
```

`VARHIDDEN` and `SYMRSVDWORD` are suppressed because they only fire on
the vendor `deps/` cells (Wlink, XHB500, Corstone CMSDK). `BLKANDNBLK`
is one upstream XHB500 unsupported-mixing case that Verilator promotes
to an error; we whitelist it to let the rest of the elaboration run.
`DECLFILENAME` is suppressed because several modules (e.g. `tidelink`
inside `tidelink.sv`, `tidelink_lane_checker_single` inside
`tidelink_lane_checker.sv`) intentionally share a file with their
top-module name. `PINMISSING` fires inside the vendor IP cells too.

The Verilator version pinned on the build host is `4.028
2020-02-06 rev v4.026-92-g890cecc1`. Note that 4.028 lacks
`-Wno-UNUSEDSIGNAL` granularity (it was split into `UNUSED`/`UNDRIVEN`
in 5.x), so `UNUSED` here lumps both reads-with-no-writer and
writes-with-no-reader.

## Headline counts (post-refactor, `tidelink_fpga` flist, top = `tidelink_top`)

| Scope                  | Errors | Warnings |
|------------------------|-------:|---------:|
| Whole elaboration      | 1*     | 838      |
| `src/rtl/*` only       | 0      | 77       |

`*` The one error is an upstream XHB500 BLKANDNBLK in
`xhb500_axi_to_ahb_bridge_chiplet_mst_core_h_xout.sv:137`. Vendor IP;
out of scope for this report. With `-Wno-BLKANDNBLK` (set in the
reproducer above) elaboration completes cleanly.

### `src/rtl/` warning breakdown

| Class             | Count |
|-------------------|------:|
| `PINCONNECTEMPTY` |    36 |
| `UNUSED`          |    32 |
| `WIDTH`           |     4 |
| `UNOPTFLAT`       |     4 |
| `SYNCASYNCNET`    |     1 |
| `BLKANDNBLK`      |     0 |
| `MULTIDRIVEN`     |     0 |

No `BLKANDNBLK` / `MULTIDRIVEN` are present in `src/rtl/*` — both
classes only originate in vendor `deps/`. The four task-critical
classes that ARE present in our own RTL are itemised below.

## Critical warnings — full listing

### `WIDTH` (4)

- `src/rtl/tidelink_phy_align_calibrator.sv:381` — `GTE` expects 32 bits LHS;
  `resweep_ctr` is 16-bit. Comparison against a 32-bit param literal.
- `src/rtl/tidelink_phy_align_calibrator.sv:457` — same idiom; `hold_ctr` is 17-bit.
- `src/rtl/tidelink_perf.sv:493` — `ASSIGN` 32-bit LHS; RHS replicate produces 33 bits.
- `src/rtl/tidelink_addr_translator.sv:117` — `ASSIGNW` 32-bit LHS;
  `chp_adr_paddr` is 16-bit (APB upper bits zero-extended).

### `UNUSED` (32) — grouped by file

`src/rtl/tidelink_top.sv`
- :427  `m_axi_awaddr[35:32]` (top-level signal wider than internal use)
- :450  `m_axi_araddr[35:32]`
- :553  `phc_hw_cap_sub_nanoseconds_sync`
- :595  `fc_cfg_apb_pslverr`

`src/rtl/tidelink_fc_adapter.sv`
- :52   `ahb_tx_htrans[0]`
- :53   `ahb_tx_hsize`
- :65   `rtn_haddr[31:14]`
- :67   `rtn_htrans[0]`
- :68   `rtn_hsize`
- :93   `fc_rx_cfg_prdata`
- :284  `puf_rdata_r`

`src/rtl/tidelink_addr_translator.sv`
- :45   `chp_adr_pprot`
- :52   `chp1_ahb_haddr_i`

`src/rtl/tidelink_ptp.sv`
- :74   `phc_pps`
- :83   `ahb_ptp_htrans[0]`
- :84   `ahb_ptp_hsize`
- :86   `ahb_ptp_hwdata[31:16]`
- :97   `ptp_reg_wdata[31:30]`

`src/rtl/tidelink_ptp_servo.sv`
- :385  `mul_result[31:0]`
- :387  `mul_busy`

`src/rtl/tidelink_phc_cdc.sv`
- :42   `scan_mode`  (held for DFT, not in v1 flow yet)

`src/rtl/tl_addr_trans_cam.sv`
- :50   `addr_norm[23:0]`

`src/rtl/fifo/tidelink_fifo_mem.sv`
- :78   `fc_translated_addr[1:0]`  (word-address alignment)
- :88   `sram_addr`
- :115  `write_ptr`, :116 `read_ptr`
- :117  `write_target_addr`, :118 `read_target_addr`
- :120  `credit_count`

`src/rtl/fifo/tidelink_returner.sv`
- :49   `hrdata`  (write-only master)

`src/rtl/fifo/tidelink_apb_regs.sv`
- :30   `paddr[11:9,1:0]`  (word-aligned 9-bit decode of 12-bit APB)
- :220  `reset_n_raw_edge`

### `UNOPTFLAT` (4)

- `src/rtl/tidelink_top.sv:691`   — `xhb_sub_hreadyout_raw`
  (combinational HREADYOUT mux back into HSEL/HREADY logic — recognised idiom)
- `src/rtl/tidelink_phy_align_calibrator.sv:331` — `phase`
- `src/rtl/tidelink_phy_align_calibrator.sv:332` — `lane_done`
- `src/rtl/tidelink_phy_align_calibrator.sv:336` — `sweep_phase`
  (Verilator schedule heuristic, not a real loop — DC/Genus does not
   flag these.)

### `SYNCASYNCNET` (1)

- `src/rtl/tidelink_top.sv:83` — `hresetn` is used as both sync and async
  reset. Known and intentional: cross-domain reset bridging at the
  chiplet boundary. Not new in this refactor.

## What's NOT counted

The remaining 761 warnings on the full elaboration come from `deps/`
(Wlink, XHB500, axi-chiplet-controller, Corstone CMSDK FPGA-SRAM model)
and the cmsdk_apb_slave_mux. Per task brief, vendor noise is suppressed
or ignored.

`STMTDLY` (134) is exclusively the `#1 timing` annotations inside
vendor models; will never appear under our `src/rtl/`.

## Comparison vs. pre-refactor

Both the pre-refactor (with `tidelink_phy_align_regs.sv`, flat
`tidelink_fifo.sv`, flat `tidelink_fifo_ctrl.sv` still present) and
post-refactor lints produce identical totals (`838` warnings on the
whole elab, `77` in `src/rtl/*`). This is expected: the three deleted
files were never on any flist, so deleting them changed disk only, not
the elaborated module tree. The post-refactor tree is now consistent
with the lint output (no dead files shadowing live ones).

## Items deferred / non-obvious drift flagged but not changed

1. **Dead modules still on disk** — `src/rtl/tidelink_addr_translation.sv`
   and `src/rtl/tidelink_apb_addr_ctrl.sv` define modules
   (`tidelink_addr_translation`, `tidelink_apb_addr_ctrl`) that have
   zero instantiations and are not referenced from any flist. They
   appear to be an earlier (pre-CAM) address translation scheme that
   was superseded by `tl_addr_trans_regs` / `tl_addr_trans_cam` /
   `tidelink_addr_translator`. Not deleted in this pass because they
   were not in the explicit task scope; flagged for a follow-up
   hygiene commit.

2. **`tidelink_top.sv:1179..1532` PINCONNECTEMPTY (25 hits)** — all
   stem from binding to the AXI/AHB master-port super-set on
   `axi_chiplet_controller` and friends. The empty references are the
   AXI4 / AXI5 fields the current FC adapter does not drive (qos,
   region, nsaid, exokay, awakeup, the Q-Channel `qactive/qaccept/qdeny`
   nibbles). Cosmetic; the synthesis tools tie them off automatically.
   No action.

3. **`UNUSED` on the FIFO control bookkeeping** (`write_ptr`,
   `read_ptr`, `credit_count`, etc. in `tidelink_fifo_mem.sv:115-120`)
   — these are debug observability signals kept on top of the
   `tidelink_fifo_ctrl` instance so ILA / waveform pulls can see them
   without re-elaborating. Intentional; suppress with a targeted
   `/* verilator lint_off UNUSED */` if we want to silence them.

4. **README references to `tidelink_fifo.sv` / `tidelink_fifo_ctrl.sv`**
   — repo-root `README.md` lines 88, 90, 136, 138 talk about these
   modules without qualifying the path. They are still correct (the
   modules exist under `src/rtl/fifo/`); the README does not claim
   `src/rtl/<top-level>/...`. Left as-is per task scope.
