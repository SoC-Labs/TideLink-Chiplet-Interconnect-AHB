# FC2 GDSII build log — tidelink-gpio-phy integration

Worktree: `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-fc2/`
Branch  : `feat/td-gpio-phy-fc2-build` (from `feat/td-gpio-phy-integration` @ cbcba54)
Target  : TSMC65 LP, tcbn65lp_220a 9-track, rf_16k macro
Top     : `tidelink_top` (MODULE = `tidelink_top_full`)
Tooling : FC2 FS-COMPILER_2022.12 at `/eda/synopsys/2022-23/RHELx86/FS-COMPILER_2022.12/bin`
Started : 2026-05-28 23:17 (handed off after eye-toolkit-web lease)

The existing FC2 flow under `syn/asic/fusion-compiler/` is the production
reference (PG, LEC-known-good on the pre-gpio-phy base). This log captures
the deltas required to compile the new lane-checker stack
(`deps/tidelink-gpio-phy/rtl/`) and the v2 eye-regs shim that arrived on
the same branch.

---

## Iteration 1 — ASIC flist alignment (RTL elaborate)

### Symptom

`flist/tidelink_top_full_asic.flist` still points at
`src/rtl/tidelink_lane_checker.sv` which was DELETED in commit `d043909`
when the lane-checker became a submodule. The FPGA flist already points
at the four submodule files; the ASIC flist was not updated.

In addition, `tidelink_top.sv` now instantiates `tidelink_eye_regs` (v2
eye-visibility APB Region 10 shim) which is in the FPGA flist but not
the ASIC flist.

### Fix

Mirror the FPGA flist's `+incdir+` + four submodule files into the ASIC
flist where the old file used to live, and add `tidelink_eye_regs.sv`
alongside.

### Reproduction

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-fc2
source set_env.sh
# (edit flist/tidelink_top_full_asic.flist)
make -C syn/asic/fusion-compiler fc_init MODULE=tidelink_top_full
```

### Outcome

Elaboration broke on a SECOND issue — see iteration 2.

---

## Iteration 2 — tidelink_idelay_rx `parameter real REFCLK_MHZ`

### Symptom

```
Error:  /home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-fc2/src/rtl/tidelink_idelay_rx.sv:100: real declarations are not supported by synthesis. (VER-177)
Error:  Cannot recover from previous errors. (VER-518)
Error: Presto analyze failed
```

### Mechanism

`tidelink_idelay_rx.sv` is in the ASIC flist as a passthrough (per the
existing flist comment: "ASIC build → USE_IDELAY=0 → pure passthrough;
the Xilinx IDELAYE2/IDELAYCTRL primitive text is never seen by the ASIC
elaborator"). That's true for the IDELAYE2 primitive body inside the
`ifndef TIDELINK_IDELAY_NO_PRIMITIVE` arm — but the module's parameter
list itself is always analysed, and one of those parameters
(`REFCLK_MHZ`) is declared as `parameter real`. Presto rejects `real`
at analysis time, before any generate-block filtering.

### Fix

Promote `REFCLK_MHZ` from `real` to `integer`. The only downstream
consumer is `IDELAYE2.REFCLK_FREQUENCY` inside the FPGA-only generate
arm, which accepts `200` exactly as it accepted `200.0`.

Diff:

```diff
-    parameter real         REFCLK_MHZ = 200.0
+    // (long comment explaining the ASIC-vs-FPGA rationale)
+    parameter integer      REFCLK_MHZ = 200
```

### Outcome

Elaboration of `tidelink_top` reaches the 193-module mark with
50,654 instances. Lane checker (PATTERN=16'h12eb / 16'hed14 / etc.,
LOCK_CONSEC=8) elaborates correctly from the
`deps/tidelink-gpio-phy/rtl/` paths the iter-1 flist fix added.
USE_IDELAY=0, USE_T3A=0, AUTOCAL_ENABLE=1, USE_CLKBUF=0 — all ASIC
defaults from `tidelink_top.sv` are honoured.

Warnings observed (non-blocking — all carried by the pre-existing
production build):

| Warning | Source | Disposition |
|---|---|---|
| ELAB-978 latch in always_ff | `tidelink_eye_regs.sv:140` (W1P SWI_EYE_CTRL register pattern) | benign — bits assigned outside the W1P arm retain their reset value via the always_ff feedback path; mirrors the pre-existing tidelink_phy_align_regs pattern |
| ELAB-974 latch in always_comb | `tidelink_autoneg.sv:465` | pre-existing in production build |
| ELAB-311 default-unreachable case | several modules | benign |
| VER-708 ignored initial assignments | i2c / Wlink Wav* | benign — synth-mode strips them |
| VER-318 signed↔unsigned warnings | ptp_servo, fc_adapter | pre-existing |
| VER-26 / VER-64 xhb500 pkg "already analyzed" | xhb500 generated wrapper | benign — slv/mst contain the same generic-cell defs |

