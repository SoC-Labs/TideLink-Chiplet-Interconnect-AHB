# TideLink CDC Audit Report

**Date:** 2026-05-23  
**Author:** Analysis of main HEAD (c71ff33)  
**Target:** TSMC 65 nm, 100 MHz GPIO PHY

---

## Executive summary

Two real CDC violations are present in the TideLink design. Both involve the
`swi_phase_offset` calibration word crossing from slow control-plane clocks into
the fast `pad_clk_rx` domain without synchronization. Both are **quasi-static**
(the value is only written during link bring-up and then held stable), which
means metastability risk is very low in practice. However a commercial CDC tool
(SpyGlass, Meridian, 0-In) will flag both as errors and they must be formally
closed before tapeout. The Wlink IP's own internal crossings (hclk → tx_link_clk,
hclk → rx_link_clk) are handled correctly by WavResetSync/WavDemetReset inside
Wlink.v.

---

## 1. Clock domains

| Clock | Source | Nominal freq (ASIC v1) | Notes |
|---|---|---|---|
| `hclk` | SoC AHB bus clock | TBD (SoC-dependent) | APB/AHB clk for all config |
| `pad_clk_rx` | Received RX pad clock | ~100 MHz | Recovered from chiplet link |
| `link_clk` | `~adj_count[3]` (BUFG-divided) | ~6.25 MHz | pad_clk_rx ÷ 16 |
| `phc_clk` | PTP hardware clock | TBD | PTP servo only |

---

## 2. CDC finding #1 — `swi_phase_offset_r` (hclk → pad_clk_rx)

### Signal path

```
axi_chiplet_controller.sv:564  reg [31:0] swi_phase_offset_r;          // hclk domain
axi_chiplet_controller.sv:706      swi_phase_offset_r <= ctrl_reg_wdata[31:0];  // written on APB write
tidelink_top.sv:1371           wire [31:0] swi_phase_offset_w = cal_phase_offset_w | swi_phase_offset_r;
tidelink_top.sv:1613               .swi_phase_offset_in(swi_phase_offset_w),     // Wlink port
Wlink.v:363                    effective_phase_offset[4*gl +: 4] =
                                    io_swi_phase_offset_in[4*gl +: 4] | swi_phase_offset;
WavD2DGpioRx.v:112             wire [3:0] adj_count = count + io_phase_offset;  // count ∈ pad_clk_rx
```

### Analysis

`swi_phase_offset_r` is a 32-bit register written via APB (`hclk` domain). It is
OR-combined with the calibrator output and driven directly into `WavD2DGpioRx`,
where `io_phase_offset` is used combinationally with `count`, a register clocked
by `w_cnt_clk` (derived from `io_pad_clk`, i.e. pad_clk_rx). There is no
synchronizer on this path.

**Risk:** Low in practice. `swi_phase_offset_r` is written once during link
calibration and never again once the link is locked. A transient metastability
event during the write would momentarily corrupt the `adj_count` selector and
mis-capture one or a few RX bits, which may cause a link blip. The calibrator FSM
tolerates this because it evaluates alignment score across many cycles.

**SpyGlass classification:** Will report as `cdc_signal_synch` violation (multi-bit
bus crossing without synchronization). Requires formal waiver or structural fix
before tapeout sign-off.

### Recommended fix

Add a WavMultibitSync (or equivalent TSMC qualified multi-bit synchronizer) at
the output of `axi_chiplet_controller.sv`, synchronized to `pad_clk_rx`. Since
the signal is quasi-static, a simple 2-FF synchronizer is acceptable for each
4-bit nibble, or the full 32-bit word can use a handshake (request/acknowledge)
protocol.

**Option A — 2-FF per-nibble synchronizer (simpler, fits quasi-static assumption):**

```systemverilog
// In tidelink_top.sv, after swi_phase_offset_w is formed:
// Synchronize each lane's 4-bit phase nibble from hclk to pad_clk_rx.
// Quasi-static: only written during calibration; RTL assumes no in-flight change
// once link is locked (link_active high).
genvar gi;
generate
    for (gi = 0; gi < 8; gi++) begin : gen_phase_sync
        // Replace direct wire with synchronized output
        // wav_multibit_sync or equivalent 2-FF cell per lane nibble
        wav_multibit_sync #(.WIDTH(4)) u_ph_sync (
            .clk     (pad_clk_rx),
            .rst_n   (poresetn),
            .d       (swi_phase_offset_w[4*gi +: 4]),
            .q       (swi_phase_offset_sync[4*gi +: 4])
        );
    end
endgenerate
// Drive Wlink with synchronized value:
//   .swi_phase_offset_in(swi_phase_offset_sync)
```

**Option B — set_false_path waiver (acceptable if quasi-static protocol is enforced):**

If the SoC integration contract guarantees that `swi_phase_offset_r` is written
only before `link_active` is asserted and never changed afterwards, add a
`set_false_path` in the SDC/XDC and a corresponding SVA assertion:

```systemverilog
// Assertion: phase_offset must not change while link is active
// Place in a bind block on axi_chiplet_controller
property no_phase_change_while_active;
    @(posedge hclk) disable iff (!hresetn)
    link_active |-> $stable(swi_phase_offset_r);
endproperty
assert property (no_phase_change_while_active);
```

**Recommended choice:** Option B for the near term (waiver + assertion). Add the
SVA assertion in `cocotb/lint/` or a bind file so it fires in simulation. Reserve
Option A for a future revision if the link needs hot-recalibration support.

---

## 3. CDC finding #2 — `cal_phase_offset_w` (link_clk → pad_clk_rx)

### Signal path

```
tidelink_phy_align_calibrator.sv:220    output logic [31:0] phase_offset,       // link_clk domain
tidelink_top.sv:1350                        .phase_offset(cal_phase_offset_w),  // calibrator output
tidelink_top.sv:1371                    wire [31:0] swi_phase_offset_w = cal_phase_offset_w | swi_phase_offset_r;
tidelink_top.sv:1613                        .swi_phase_offset_in(swi_phase_offset_w),
WavD2DGpioRx.v:112                     wire [3:0] adj_count = count + io_phase_offset; // pad_clk_rx
```

### Analysis

The calibrator is clocked by `link_clk` (pad_clk_rx / 16). Its `phase_offset`
output is driven combinationally into the OR merge at `swi_phase_offset_w`, which
then enters `WavD2DGpioRx` (pad_clk_rx domain). This is a slow-to-fast crossing:
link_clk ÷ 16 → pad_clk_rx × 1. The output can change at most once per 16
pad_clk_rx cycles, giving 16 cycles of setup time before the next edge. This
means glitch probability is extremely low, but it is still an unconstrained CDC
crossing.

**SpyGlass classification:** Will report as a multi-bit reconvergence CDC violation.
Each nibble of `phase_offset` changes at most once per calibration sweep step; the
crossing is at most a 1-in-16 probability of hitting a transition.

### Recommended fix

The `phase_offset` output of the calibrator is already registered at the end of
each calibration step (the `phase[i]` registers in the calibrator FSM are only
updated when `lane_done[i]` transitions). The cleanest fix is to move the output
register to a flop clocked by `pad_clk_rx`, or add a 2-FF synchronizer per nibble
between the calibrator output and the OR merge point.

**Preferred approach:** Register `cal_phase_offset_w` in the pad_clk_rx domain
before the OR merge:

```systemverilog
// In tidelink_top.sv
reg [31:0] cal_phase_offset_sync;
always_ff @(posedge pad_clk_rx or posedge por_rst_async) begin
    if (por_rst_async) cal_phase_offset_sync <= 32'h0;
    else               cal_phase_offset_sync <= cal_phase_offset_w; // 1-FF; add second FF for full 2-FF sync
end
wire [31:0] swi_phase_offset_w = cal_phase_offset_sync | swi_phase_offset_r_sync;
```

In practice, since Finding #1 will add synchronization on `swi_phase_offset_r`,
and the overall merged word is then driven into `swi_phase_offset_in`, both
synchronizations should be applied before the OR merge. 

---

## 4. CDC findings already handled correctly

The following potential CDC paths were audited and found to be correctly handled:

| Signal | From | To | Mechanism |
|---|---|---|---|
| tx_link_clk reset | apb_clk | tx_link_clk | WavResetSync (Wlink.v:tx_link_clk_reset_wrs) |
| rx_link_clk reset | apb_clk | rx_link_clk | WavResetSync (Wlink.v:rx_link_clk_reset_wrs) |
| app_clk reset | apb_clk | app_clk | WavResetSync (Wlink.v:app_clk_reset_scan_wrs) |
| role_locked_o | poresetn | hclk | Single-bit; role FSM in hclk domain |
| PTP hw_capture | phc_clk | hclk | Captured and read via APB |
| FIFO AHB↔Wlink | hclk | link_clk | tidelink_fifo_ctrl.sv 2-FF synchronizers |

---

## 5. Autoneg control signals

The autoneg FSM (`axi_chiplet_controller.sv` lines 500–900) runs in `hclk`. Its
outputs (`role_is_master_o`, `role_locked_o`, `nego_done`) are all single-bit
signals that transition once (0→1) during bring-up and then hold. These cross into
`pad_clk_rx` domain only through `wlink_por_reset = ~poresetn | ~role_locked` —
which is a combinational gate, not a registered CDC crossing. The single-bit
`role_locked` is used only in the reset logic; it does not feed into any
time-critical data path in the pad_clk_rx domain. SpyGlass may still flag this as
a quasi-static crossing; a `set_false_path` from `role_locked_o` to the
`wlink_por_reset` combination is the appropriate waiver.

---

## 6. Action plan

| Priority | Action | Effort | Status |
|---|---|---|---|
| 1 | Add SVA assertion `no_phase_change_while_active` (Option B) | 1 hour | TODO |
| 2 | Add `set_false_path` for swi_phase_offset_r in SDC | 30 min | TODO |
| 3 | Add `set_false_path` for cal_phase_offset_w in SDC | 30 min | TODO |
| 4 | Add `set_false_path` for role_locked → wlink_por_reset | 30 min | TODO |
| 5 | Run SpyGlass CDC on the full design and resolve all waivers | 1 day | TODO |
| 6 | (Optional) Replace false_path waivers with structural 2-FF sync (Option A) | 2 days | FUTURE |

The SVA assertion (item 1) is the most valuable near-term action: it makes the
quasi-static assumption machine-checked in simulation and clearly documents the
design intent to anyone who opens the file.

---

## 7. Does this work still need doing?

**Yes.** Neither the false-path constraints nor the SVA assertions are currently in
place. SpyGlass CDC has not been run on the current `main` HEAD. Before ASIC
tapeout these must be resolved or waived. The quasi-static property of
`swi_phase_offset` means structural fixes are not urgently required, but the
formal documentation (SDC waivers + assertions) must be added before a sign-off
CDC run.

Estimated total effort for the waiver approach: **3–4 hours**.  
Estimated total effort for full structural fix: **2–3 days** (including regression
testing).

---

## 8. Resolution (2026-05-23)

**Both Finding #1 and Finding #2 have been resolved with a structural fix.**

A new module `tl_calibration_cdc` (`src/rtl/tl_calibration_cdc.sv`) implements
full structural CDC synchronization for all six affected signal paths before any
pad_clk_rx-domain consumer is reached.

### Architecture

| Path | Signal | Approach |
|---|---|---|
| apb_clk → pad_clk_rx | `swi_phase_offset_r` [31:0] | 8× WavMultibitSync (4-bit handshake per lane nibble) |
| apb_clk → pad_clk_rx | `swi_bit_slip_lo_r` [23:0] | 8× WavMultibitSync_15 (3-bit handshake per lane group) |
| apb_clk → pad_clk_rx | `swi_training_mode_r` [1] | 1× WavDemetReset (2-FF) |
| link_clk → pad_clk_rx | `cal_phase_offset_w` [31:0] | 32× WavDemetReset (slow-to-fast, 16-cycle margin) |
| link_clk → pad_clk_rx | `cal_bit_slip_w` [23:0] | 24× WavDemetReset (slow-to-fast, 16-cycle margin) |
| link_clk → pad_clk_rx | `cal_training_mode_w` [1] | 1× WavDemetReset (slow-to-fast) |

The APB-side paths use WavMultibitSync handshake synchronizers (the same IP
already used inside Wlink for multi-bit bus crossings). The link_clk-side paths
use WavDemetReset per bit, which is legal because link_clk = pad_clk_rx/16
gives 15 cycles of setup margin. SpyGlass recognises WavDemetReset as a
qualified synchronizer cell.

### SDC constraint required for SpyGlass link_clk clearance

```
set_multicycle_path -setup 16 -from [get_clocks link_clk] -to [get_clocks pad_clk_rx]
set_multicycle_path -hold  15 -from [get_clocks link_clk] -to [get_clocks pad_clk_rx]
```

### Changes made

- **Created:** `src/rtl/tl_calibration_cdc.sv` — new synchronizer module
- **Modified:** `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv`:
  - Instantiated `u_cal_cdc` between the OR-mux block and the IDELAYE2 instance
  - Retained `swi_phase_offset_w`, `swi_bit_slip_w`, `swi_training_mode_w` for APB readback (unchanged)
  - Changed `.swi_bit_slip_in`, `.swi_training_mode_in`, `.swi_phase_offset_in` (Wlink ports) to use `_sync` versions
  - Changed `.phase_tap_i` (IDELAYE2 wrapper) to use `swi_phase_offset_sync`
- **Modified:** `flist/tidelink_top.flist`, `flist/tidelink_top_full_asic.flist`, `flist/tidelink_fpga.flist` — added `tl_calibration_cdc.sv`

### Remaining action items

| Priority | Action | Status |
|---|---|---|
| 1 | Add SDC MCP constraints for link_clk→pad_clk_rx in ASIC SDC | TODO |
| 2 | Add `set_false_path` for role_locked → wlink_por_reset (section 5) | TODO |
| 3 | Run SpyGlass CDC on full design to confirm clean | TODO |

---

## 9. Assessment vs. current `main` HEAD (2026-05-23, post-revert b7de2d4)

This section overrides section 8's "Resolution" header. The structural fix
described in section 8 (`tl_calibration_cdc` module + submodule
instantiation) was attempted and **did not pass HW validation**: the build
on top of the structural fix produced WNS = -1.143 ns, WHS = -7.976 ns on
the `pynq-z2-pair-flip-all` target because the synchronizers introduced
unconstrained link_clk → pad_clk_rx paths that the required SDC
`set_multicycle_path` directives (quoted at the end of section 8) were
never actually added for. Per the "validate every fold" rule, the
structural fix has been parked on `feat/cdc-fix-wip` (parent commit
7cb67ee + matching submodule HEAD 0086e1b) with a known-issue note. It
is NOT on `main`.

### What `main` actually does with each finding

| Section | Finding / Action | Handled on `main`? | Mechanism |
|---|---|---|---|
| 2 | Finding #1: `swi_phase_offset_r` hclk → pad_clk_rx | **Yes (Option B / waiver)** | `set_clock_groups -asynchronous pad_clk_rx ↔ hclk` covers the whole APB-control-to-PHY domain crossing in `fpga/targets/pynq-z2-pair*/pynq_z2_tidelink_timing.xdc:245` AND `imp/ASIC/tidelink_top_full/tidelink_top.sdc:46` AND `syn/asic/fusion-compiler/inputs/constraints.sdc:48`. The recommended near-term choice in section 2 was Option B; both flows already do exactly that. |
| 3 | Finding #2: `cal_phase_offset_w` link_clk → pad_clk_rx | **Partially (FPGA = de-facto safe; ASIC = TODO)** | `link_clk` is derived from `pad_clk_rx ÷ 16` via a BUFG divider; physically a slow-to-fast same-tree crossing with 15 cycles of setup margin (per section 3 analysis). Vivado closes timing on this with no explicit waiver. SpyGlass will need an explicit `set_multicycle_path -setup 16 / -hold 15 -from [get_clocks link_clk] -to [get_clocks pad_clk_rx]` (or a false_path if treated as fully async). NOT yet added to either SDC. |
| 5 | role_locked → wlink_por_reset | **Yes (same waiver)** | `wlink_por_reset = ~poresetn \| ~role_locked` lives at the boundary between hclk and pad_clk_rx; covered by the same `set_clock_groups -asynchronous` declaration as Finding #1. |
| 6.1 | SVA `no_phase_change_while_active` | **No** | Recommended in section 2 as the most valuable near-term documentation/sim-check addition. Currently absent. |
| 6.2 | `set_false_path` for swi_phase_offset_r in SDC | **Yes** (subsumed by set_clock_groups) | — |
| 6.3 | `set_false_path` for cal_phase_offset_w in SDC | **No** (item 3 above) | — |
| 6.4 | `set_false_path` for role_locked → wlink_por_reset | **Yes** (subsumed by set_clock_groups) | — |
| 6.5 | Run SpyGlass CDC on full design | **No** | Not yet executed against current `main`. Will surface Finding #2's missing MCP constraint and any genuinely unrecognized synchronizers. |
| 6.6 | Structural fix Option A | **Parked** | `feat/cdc-fix-wip` (broke timing — needs SDC MCP before retry). |

### Outstanding work, in priority order

1. **Add `set_multicycle_path` constraints for the link_clk → pad_clk_rx group** (FPGA + ASIC + Fusion-Compiler SDC). This is the only structurally-relevant CDC waiver still missing from the design. Even though Vivado happens to close timing without it, an ASIC tool / SpyGlass run will flag the crossing without an explicit declaration. Effort: 30 min, three SDC files. Risk: zero (additive constraint).

2. **Add the SVA `no_phase_change_while_active` assertion** to a bind file (`uvm/tidelink_top/tb/cdc_quasi_static_bind.sv` or similar) so the quasi-static contract is sim-checked. Effort: 1 hour. Risk: assertion may fire if the quasi-static assumption is ever violated by future SW (which is the point).

3. **Run SpyGlass CDC on `main` HEAD** and triage anything not already covered. Effort: 1 day to first clean run including any new waivers SpyGlass demands. Risk: may surface additional findings that need either a waiver or a structural fix.

4. **(Deferred)** Re-attempt the structural fix on `feat/cdc-fix-wip` once item 1 is in place. The branch has `tl_calibration_cdc.sv` and the submodule instantiation pre-staged; the only delta needed is the SDC MCP constraints and a successful timing-closing rebuild.

### What does NOT need doing

The original section 8 implication that Findings #1, #2 and section 5
require **structural** changes is over-stated. Section 2 itself recommends
the Option B waiver path as preferred near-term, and the FPGA + ASIC
constraint files already implement it correctly via
`set_clock_groups -asynchronous`. Pursuing the structural module on
`feat/cdc-fix-wip` is justified only if the quasi-static contract becomes
unenforceable (e.g. hot-recalibration requirement) — not as a sign-off
gate for the current ASIC target.
