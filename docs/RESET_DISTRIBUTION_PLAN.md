# TideLink Reset Distribution Analysis and Plan

**Date:** 2026-05-23  
**Author:** Analysis of main HEAD (c71ff33)  
**Target:** TSMC 65 nm, 100 MHz

---

## Executive summary

The TideLink top-level reset distribution is **functionally correct** for the
current FPGA and simulation targets. The design follows the standard asynchronous-
assert / synchronous-deassert (AASD) pattern, relying on the SoC PMU above
`tidelink_top.sv` to provide synchronized reset signals. The Wlink IP handles its
own internal clock-domain reset crossings via `WavResetSync`.

Before ASIC tapeout, two items require formal closure:

1. **Reset tree depth / fan-out** — the design has not been analysed for reset
   insertion delay on the ASIC target. A large fan-out tree without balancing
   can produce reset skew comparable to clock skew, which affects DFT scan
   fill and can cause functional issues in multi-clock designs.

2. **Integration contract documentation** — `tidelink_top.sv` does not explicitly
   state that `hresetn` and `poresetn` must be externally synchronized before
   being driven in. This is an invisible contract that can be broken by a new
   integrator.

Neither finding blocks current FPGA validation work.

---

## 1. Reset inputs and their distribution

### 1.1 `hresetn` — AHB system reset (active-low)

Enters `tidelink_top.sv` at line 80. Distributed to:

| Recipient | Usage |
|---|---|
| `always_ff @(posedge hclk or negedge hresetn)` blocks | Async reset for all hclk-domain state in tidelink_top |
| `axi_chiplet_controller.hresetn` | Controller APB/AHB reset |
| `tidelink_fifo.hresetn` (×2) | TX/RX FIFO AHB-side reset |
| `tidelink_apb_regs.hresetn` | APB register block reset |
| `tidelink_addr_translator.RESETn` | Address translator reset |
| `tidelink_ptp.hresetn` | PTP module AHB-side reset |

In `axi_chiplet_controller.sv`: `wire apb_reset = ~hresetn` — combinational
inversion used as active-high reset internally within the controller. No additional
synchronizer is inserted.

### 1.2 `poresetn` — Power-on reset (active-low)

Enters `tidelink_top.sv` at line 81. Distributed to:

| Recipient | Usage |
|---|---|
| `axi_chiplet_controller.poresetn` | Role FSM, POR-preserved state |
| `tidelink_top` local POR blocks | ptp_clk domain reset, ref_clk logic |
| `idelay_rst = ~poresetn` | IDELAYE2 active-high reset (FPGA only) |
| `wlink_por_reset = ~poresetn \| ~role_locked` | Wlink reset gate |

### 1.3 Wlink internal reset crossings

Wlink.v instantiates three `WavResetSync` cells for its own internal clock domain
crossings — these are correct and require no action:

```
tx_link_clk_reset_wrs   — apb_clk → tx_link_clk
rx_link_clk_reset_wrs   — apb_clk → rx_link_clk
app_clk_reset_scan_wrs  — apb_clk → app_clk
```

`WavResetSync` implements proper AASD using two back-to-back `WavDemetSet` cells
with scan bypass.

---

## 2. Analysis — Is the current approach correct?

### 2.1 AASD pattern (correct for FPGA + simulation)

All `always_ff` blocks in the TideLink custom RTL use the AASD pattern:

```systemverilog
always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn) /* async reset */
    else          /* synchronous operation */
end
```

This is correct **provided `hresetn` has already been synchronized to `hclk`
before arriving at `tidelink_top`**. In the nanosoc integration, the CMSDK PMU
or reset manager is expected to provide properly synchronized resets. On FPGA,
the block design provides synchronous resets from the PS. The current design is
therefore correct for its intended integration contexts.

### 2.2 What would break without external synchronization

If an integrator were to drive `hresetn` directly from a raw POR signal (e.g. a
filtered power-on pin with no clock synchronization):

- Reset deassertion could be metastable on any FF that captures it
- In a multi-clock design (hclk + pad_clk_rx + phc_clk), different flops could
  see deassertion on different `hclk` edges, corrupting initialization state
- SpyGlass CDC / reset analysis tools would flag this

### 2.3 ASIC reset tree fan-out

In the synthesized ASIC netlist, `hresetn` fans out to all FF async-reset pins.
For a design of this size (~50,000 FFs estimated), without a balanced reset
buffer tree the worst-case reset deassertion skew can be 200–500 ps. At 100 MHz
(10 ns clock period), this skew is not enough to cause functional failures, but:

- It can cause scan capture failures if scan clock and reset deassert times are
  not aligned
- It appears as a large fan-out violation in DRC checks (TSMC 65G standard-cell
  rule: max fan-out for reset = 50 cells; above that, insert buffer)

The synthesis flow (DC/Fusion) normally inserts a balanced reset buffer tree
automatically during `compile_ultra`, but only if the `set_max_fanout` constraint
is applied. This must be verified in the synthesis script.

---

## 3. Does this work still need doing?

**Partially.** The functional correctness is fine as-is. Two concrete items need
closing before tapeout:

| Item | Status | Required for tapeout? |
|---|---|---|
| Add integration contract to `tidelink_top.sv` port comment | Not done | Strongly recommended |
| Verify `set_max_fanout` in DC synthesis script | Not verified | Yes |
| Run SpyGlass reset analysis | Not done | Yes |
| Add internal 2-FF synchronizer inside `tidelink_top` | Not required if integration contract is met | No (optional) |

---

## 4. Recommended actions

### 4.1 Document the integration contract (30 minutes)

Add a comment block to `tidelink_top.sv` at the reset input ports stating the
synchronization contract:

```systemverilog
// Reset inputs — integration contract
// Both hresetn and poresetn MUST be provided pre-synchronized to hclk by
// the SoC reset controller (PMU) before being driven into this module.
// These signals are distributed directly to async-reset flip-flop inputs.
// Failure to synchronize externally will cause metastability on deassertion.
//
// The Wlink IP handles its own internal clock-domain reset crossings (hclk →
// tx_link_clk, rx_link_clk, app_clk) via WavResetSync cells inside Wlink.v.
input  wire  hresetn,      // Active-low AHB system reset (pre-synchronized to hclk)
input  wire  poresetn,     // Active-low power-on reset (pre-synchronized to hclk)
```

### 4.2 Verify synthesis fan-out constraint (1 hour)

Check the DC synthesis script for:

```tcl
set_max_fanout 50 [get_nets *resetn*]
set_max_fanout 50 [get_nets *poresetn*]
```

If absent, add it. Confirm that `compile_ultra` correctly inserts a reset buffer
tree in the post-synthesis netlist by checking the reset net fan-out in the timing
report (`report_fanout -net hresetn -significant_digits 4`).

### 4.3 Optional — add internal synchronizer at tidelink_top boundary

If integration with an unsynchronized reset source must be supported (e.g. a GPIO
POR input), add a 2-FF AASD synchronizer at the `tidelink_top` boundary:

```systemverilog
// Internal reset synchronizer (optional — only needed if hresetn_i is raw/unsynchronized)
logic hresetn_sync_1, hresetn_sync;
always_ff @(posedge hclk or negedge hresetn_i) begin
    if (!hresetn_i) {hresetn_sync, hresetn_sync_1} <= 2'b00;
    else            {hresetn_sync, hresetn_sync_1} <= {hresetn_sync_1, 1'b1};
end
// Use hresetn_sync internally; hresetn_i exposed only to the synchronizer chain
```

This trades a small amount of area (~10 cells) for independence from the
integration reset quality. For a fully custom ASIC SoC where the PMU is
in-house, this is unnecessary. For a hard IP deliverable intended for
third-party integration, it is recommended.

**Current recommendation:** Keep the existing approach (external synchronization
contract) and document it clearly (§4.1). Defer the internal synchronizer to
a future revision if required by an integrator.

### 4.4 DFT / ICG cell audit (separate work stream)

The four `wav_latch_model.sv` ICG cells inside Wlink.v may not have DFT-compliant
test-enable ports. This is a separate concern from reset distribution but falls
under the same pre-tapeout audit. Confirm with the foundry PDK that the ICG cells
used map to TSMC RTLICG or equivalent cells with test-enable.

---

## 5. Summary

| Finding | Severity | Action | Effort |
|---|---|---|---|
| Reset integration contract not documented | Medium | Add port comment to tidelink_top.sv | 30 min |
| reset fan-out constraint not verified in DC script | High | Check/add `set_max_fanout` | 1 hour |
| SpyGlass reset analysis not run | High | Run and close violations | 1 day |
| ICG DFT test-enable audit | High | Confirm with PDK library cells | 2 hours |
| Internal synchronizer (optional) | Low | Not required given integration contract | — |
