# TideLink RTL Optimisation Analysis

**Date:** 2026-05-22  
**Primary target:** ASIC, TSMC 65 nm, 100 MHz GPIO PHY clock  
**FPGA reference build:** Vivado 2024.1, `pynq-z2-pair-all` impl\_1, xc7z020clg400-1 at 25 MHz

The FPGA build is used as a reference to validate RTL correctness and measure relative logic depth.
Optimisation priorities are ordered by ASIC impact. FPGA-only observations are called out as such
and carry low priority.

---

## 1. ASIC timing context

At 100 MHz (10 ns period) on TSMC 65 nm with typical process/voltage/temperature:

- A 2-input NAND gate propagates in ~40–50 ps
- Wire delay on a 100-gate net is roughly 100–200 ps
- A realistic budget for a combinational stage between two flip-flops, accounting for clock skew,
  hold margin, and interconnect, is **~7 ns of data path**
- This gives a practical combinational depth budget of approximately **12–15 standard cell gate
  stages** (not LUT equivalents) per clock cycle

On FPGA a LUT6 corresponds to roughly 4–6 standard-cell gate equivalents in combinational depth.
Where logic level counts are given below in LUT terms, multiply by ~5 for a gate-stage estimate.

The FPGA build shows timing **passing with WNS = +0.409 ns** on the tightest path. This tells us
the RTL is structurally sound at 25 MHz. The ASIC concerns are about paths that would not meet
100 MHz, not paths that are currently failing.

---

## 2. RTL quality metrics (FPGA reference)

The following resource counts are informative of RTL structure — they are not FPGA optimisation
targets in their own right.

| Resource | Count | ASIC relevance |
|---|---|---|
| Logic LUTs (combinational) | 25,087 | Area proxy — each LUT ≈ 6 standard cells |
| Flip-flops | 25,713 | Sequential budget |
| BRAM tiles | 16 | Maps to SRAM macros on ASIC (see §3-E) |
| F7/F8 Muxes | 764 / 86 | Indicates wide mux trees — relevant to ASIC cell depth |
| DSP48E1 | 1 | Maps to a combinational multiplier on ASIC standard cell |
| 4 latches (Wlink IP) | — | Intentional ICG cells in third-party IP — DFT flag |

The 764 F7 muxes are largely from the AXI SmartConnect and Wlink IP. Custom TideLink RTL is
not the source of wide mux trees with the exception of the CAM address translation (§3-C) and
the calibrator output (§3-B).

---

## 3. Optimisation findings

### 3-A. Async reset fan-out and reset tree — ASIC critical path risk

**Severity: HIGH for ASIC (reset tree insertion delay, DFT)**

All custom TideLink RTL uses `posedge clk or negedge resetn` (active-low asynchronous reset).
For ASIC this has two implications:

**Reset tree insertion delay.** If `resetn` fans out directly to 25,000+ flip-flops without a
balanced reset tree, the reset assertion/deassertion skew across the design can be hundreds of
picoseconds — comparable to clock skew. This does not affect functional timing (async reset is
latency-insensitive) but it affects deassertion: if reset deasserts at different times in
different parts of the chip, logic using the deasserted reset in a combinational path can produce
glitches. Standard ASIC practice is to buffer the reset tree to match clock tree depth, or to use
synchronous reset for the majority of flip-flops (reserving async reset for clock domain crossing
synchronizers and critical initialisation cells only).

**DFT / scan chain.** Async resets with clock enable (the dominant FF type in this design) are
scan-compatible in TSMC standard cells, but the **4 latches** in the Wlink `wav_latch_model.sv`
(integrated clock-gating cells) require a `test_enable` bypass input for scan. If these ICG cells
do not have a test port exposed to the top-level scan infrastructure, they will block the scan
chain and require a DFT workaround (replacement with TSMC RTLICG cells or equivalent).

**Recommendation:** Audit `tidelink_top.sv` for a reset synchronizer on the top-level `resetn`
input. If one is absent, add a 2-FF asynchronous assert / synchronous deassert synchronizer
before the reset tree fans out. This prevents metastability on reset deassertion in multi-clock
designs. For the Wlink ICG latches, confirm they use a foundry-qualified ICG cell with test
enable before tape-out.

---

### 3-B. Calibrator `phase_offset` output — unnecessary two-level mux chain

**Severity: MEDIUM (gate depth on delay-element control path)**  
**File:** `src/rtl/tidelink_phy_align_calibrator.sv`, lines 710–742

`phase_offset[31:0]` (8 lanes × 4 bits) drives the per-lane delay element calibration word. It
is computed through two sequential combinational always\_comb blocks:

```systemverilog
// Level 1 (line 710): lane_done mux — registered sources, 1 gate stage
always_comb begin
    for (int i = 0; i < 8; i++) begin
        if (lane_done[i])
            phase_offset_internal[4*i +: 4] = phase[i];    // FF output
        else
            phase_offset_internal[4*i +: 4] = sweep_phase; // FF output
    end
end

// Level 2 (line 729): APB override mux — adds a second gate stage
always_comb begin
    if (apb_override_enable)
        phase_offset = 32'h0;
    else
        phase_offset = phase_offset_internal;
end
```

On ASIC, each level maps to one gate stage (a 2:1 mux cell). The `phase_offset` output loads
into the delay element count register across a CDC boundary (hclk → pad\_clk domain). The CDC
synchronizer adds further latency. While 2 gate stages is not a critical path issue at 100 MHz,
keeping the combinational depth minimal on any path crossing a clock domain is good practice.

**Recommended fix:** Merge into a single 3-input select, mapping to one MUX2 + one AND on ASIC:

```systemverilog
always_comb begin
    for (int i = 0; i < 8; i++) begin
        if (apb_override_enable)
            phase_offset[4*i +: 4] = 4'h0;
        else if (lane_done[i])
            phase_offset[4*i +: 4] = phase[i];
        else
            phase_offset[4*i +: 4] = sweep_phase;
    end
end
```

**Impact:** One less gate stage per bit on this path (~32 cells freed). More importantly, removes
the intermediate `phase_offset_internal` wire which can cause a CDC tool to flag two separate
crossing points for the same logical signal.

---

### 3-C. Address translation CAM — cascading priority encoder creates serial gate chain

**Severity: MEDIUM (combinational depth, latch risk)**  
**File:** `src/rtl/tl_addr_trans_cam.sv`, lines 82–93

The address translation module provides **essential functionality** — it remaps chiplet address
ranges as packets traverse the interconnect. The CAM-based implementation (`tl_addr_trans_cam.sv`,
8 programmable rules) is the correct choice for ASIC: far more area-efficient than a 256-entry
lookup table at the cost of limiting the number of simultaneously active address ranges to 8.

The current priority encoder implementation has a gate-depth problem:

```systemverilog
// found = 1'b0 set at top; the !found guard creates a serial chain
for (i = 0; i < NUM_RULES; i = i + 1) begin
    if (match[i] && !found) begin
        addr_o_upper = rule_replace[i];
        found = 1'b1;
    end
end
```

The `!found` condition gates each iteration on the result of the previous one. For 8 rules the
dependency chain is:

```
match[0] → found_1 → match[1] && !found_1 → found_2 → ... → match[7] && !found_7 → output
```

This synthesises as a serial chain of ~8 AND/OR gates plus the 8-bit comparator on `match[i]`,
totalling ~10 gate stages. On TSMC 65 nm at 100 MHz that is roughly 0.5–1.0 ns — not critical
in isolation but this path sits between an address register (FF output) and the translated address
register (FF input), so the full budget is already pre-consumed by the subtractor and comparator
before the priority chain.

**Also:** the `found` variable is a `reg` that some synthesis tools (particularly Synopsys DC)
will infer as a latch despite the default assignment, depending on `always @(*)` vs `always_comb`
elaboration. On ASIC, a synthesised latch in the address path is a correctness risk.

**Recommended fix — descending overwrite, no `found` variable:**

```systemverilog
always @(*) begin
    addr_o_upper = addr_upper;          // identity passthrough (default)
    if (global_enable) begin
        for (i = NUM_RULES-1; i >= 0; i = i - 1) begin
            if (match[i])
                addr_o_upper = rule_replace[i];  // lowest index wins (overwrites last)
        end
    end
end
```

Synthesis sees all `if (match[i])` branches as independent; it builds a parallel mux tree
reducing to log₂(8) = 3 gate stages. No `found` register, no latch risk.

**Impact:** ~7 gate stages saved on the address translation critical path; latch eliminated.

---

### 3-D. `tidelink_addr_translation.sv` — unused alternative implementation

**File:** `src/rtl/tidelink_addr_translation.sv`

**Important clarification:** Address translation is a required function. The current design uses
`tidelink_addr_translator.sv` → `tl_addr_trans_cam.sv` (8-rule CAM, instantiated at
`tidelink_top.sv:1350`). The file `tidelink_addr_translation.sv` is a **separate, alternative
implementation** using a fully-populated 256-entry lookup table — it is not connected anywhere in
the current design.

**Design choice between the two implementations:**

| Implementation | Entries | ASIC area | Combinational depth | Best for |
|---|---|---|---|---|
| `tl_addr_trans_cam.sv` | 8 rules (CAM) | ~100 cells | ~4 gate stages | Sparse mapping — typical chiplet use |
| `tidelink_addr_translation.sv` | 256 entries (table) | ~1,500 cells | ~8 gate stages | Dense segment tables, full 8-bit remapping |

The 256-entry version synthesises as an 8-bit subtractor feeding a 256-to-1 mux tree. At 100 MHz
ASIC this path would be approximately 8 gate stages just for the mux, plus 3 stages for the
subtractor — total ~11 gate stages, consuming most of the 10 ns period. **It should not be used
for the 100 MHz ASIC target as written.** If a system genuinely needs more than 8 address rules,
a better approach is a pipelined registered lookup or a larger CAM with the same descending-
overwrite pattern.

**Action:** Keep `tidelink_addr_translation.sv` in the repository as a documented reference, but:
1. Add a header comment explicitly marking it as an **alternative/reference implementation,
   not synthesised in the active design**
2. Document why the CAM is preferred for ASIC
3. Remove it from `cocotb/lint/Makefile.synth` to prevent accidental inclusion in synthesis

---

### 3-E. SRAM instantiation for ASIC — verify macro usage

**Severity: HIGH for ASIC correctness (area and functionality)**  
**File:** `src/rtl/fifo/asic/tidelink_sram.sv`

The FPGA build uses inferred BRAM (16× RAMB36E1). For ASIC, `tidelink_sram.sv` in the
`fifo/asic/` directory must instantiate a **foundry SRAM macro** from the TSMC 65 nm memory
compiler, not inferred flip-flop arrays. Synthesising the FIFO backing store as flip-flops would
consume ~50× the area of an equivalent memory macro, would likely not meet 100 MHz timing, and
would have much higher dynamic power.

Verify that `src/rtl/fifo/asic/tidelink_sram.sv` contains a proper macro instantiation (e.g.
`TSMC65_SRAM_SP_1024x32` or equivalent from the memory characterisation set at
`/research/precompiled_mems/TSMC65/rf_01k`). If it currently contains a behavioural model or
inferred registers, this must be replaced before ASIC synthesis.

---

### 3-F. CDC path completeness — `phase_offset` and autoneg control signals

**Severity: HIGH for ASIC (functional correctness)**

Vivado's `check_timing` reports the `swi_phase_offset_r` registers and several autoneg control
signals as having "no\_clock" — meaning they are not analysed by static timing analysis as CDC
paths. On FPGA this manifests as missing constraints; on ASIC the equivalent is that the CDC
tool (e.g. SpyGlass CDC) will flag these as unverified crossings that can cause metastability in
silicon.

Paths identified from the timing report:
- `swi_phase_offset_r[31:0]` — driven from APB registers in `hclk` domain, consumed in
  `pad_clk_rx` domain by `WavD2DGpioRx`. The IDELAYE2 count load is a multi-bit value that
  must be Gray-coded or transferred via a handshake to avoid partial updates.
- Autoneg state (`nego_*` registers) — control registers written from `hclk`, read in link
  clock domain. Similar concern.

**Recommendation:** Audit the CDC paths between `hclk` and `pad_clk_rx` for:
1. Multi-bit signals that must arrive coherently (use Gray code + synchronizer, or a
   qualified-handshake transfer)
2. Single-bit control signals (2-FF synchronizer is sufficient)

The CDC SpyGlass run in `cdc/tidelink_top/` addresses structural CDC but the "no\_clock"
paths above indicate some were not constrained in the SpyGlass run. These must be resolved
before tape-out.

---

### 3-G. PTP servo 48-bit comparators — already correctly structured

**File:** `src/rtl/tidelink_ptp_servo.sv`, lines 502–521

The three-way 48-bit seconds comparison synthesises to ~11 gate stages (8-bit ripple + OR tree)
plus a CARRY4-equivalent adder chain. However, each comparison is contained within its own
registered FSM state (`SUB_COMPUTE_1`, `SUB_COMPUTE_2`), giving the full clock period as budget.
At 100 MHz this is fine. No change needed.

---

### 3-H. Iterative multiplier — area-optimal for ASIC

**File:** `src/rtl/tidelink_mul_iter.sv`

On FPGA this maps to 1 DSP48E1. On ASIC it will synthesise as a 32-stage shift-register +
accumulator using standard cells — substantially smaller than a fully parallel combinational
multiplier. The iterative design is correct for ASIC where the PTP servo path runs infrequently
and area matters more than throughput. The `MULTIPLIER_MODE=1` combinational option must never
be used in synthesis on either FPGA or ASIC.

---

### 3-I. PTP hardware capture ports — unconnected in FPGA block diagram (correctness)

**Severity: MEDIUM (FPGA validation gap — will affect ASIC bring-up if not tested first)**

The ports `phc_hw_capture`, `phc_hw_set_time`, `phc_hw_set_seconds`, `phc_hw_set_nanoseconds`,
`phc_hw_adj_valid`, and `phc_hw_adj_ns_incr_frac` are all tied to zero in the current Vivado
block diagram. These are the hardware timestamp capture and PHC adjustment signals required for
the PTP hardware servo to function. Without them connected, the servo will silently compute
offsets from zero timestamps.

These must be wired before any PTP hardware validation — on FPGA first, then ASIC.

---

## 4. ASIC readiness summary

| Item | Risk at 100 MHz ASIC | Action |
|---|---|---|
| Async reset tree fan-out | HIGH — reset skew and DFT scan chain | Add reset synchronizer; audit ICG test enable |
| SRAM macro instantiation in `fifo/asic/` | HIGH — area/power/timing if using flip-flops | Verify foundry macro is instantiated |
| CDC `swi_phase_offset` and autoneg paths | HIGH — metastability in silicon | Add missing 2-FF synchronizers; constrain in CDC tool |
| CAM priority encoder serial chain (~10 gate stages) | MEDIUM — close to budget | Apply descending-overwrite fix (§3-C) |
| `phase_offset` double-mux (2 gate stages) | LOW-MEDIUM | Merge to single 3-input mux (§3-B) |
| `tidelink_addr_translation.sv` 256-entry table | MEDIUM if accidentally included | Mark clearly, remove from lint Makefile |
| PTP HW capture ports unconnected | MEDIUM — untested path | Wire in FPGA BD and validate before ASIC |
| Wlink ICG latches (DFT) | LOW-MEDIUM — scan chain integrity | Confirm TSMC RTLICG cells with test enable |
| 48-bit PTP comparators (pipelined) | LOW | No change needed |
| Iterative multiplier | LOW | No change needed |

---

## 5. Items that are FPGA-specific and do not require action for ASIC

The following observations from the Vivado build are relevant only to the 7-series FPGA target
and should not drive RTL changes:

- **FF packing / control set fragmentation** — the 70.8% slice occupancy and 4,175 wasted FF
  slots result from mixed FDCE/FDRE types in Wlink IP. On ASIC every flip-flop is individually
  placed; there is no concept of slice sharing or control set conflict.
- **F7/F8 mux counts** — Xilinx-specific routing resources. On ASIC, wide muxes synthesise
  as balanced standard-cell mux trees.
- **RAMB36E1 inference warnings** — Vivado-specific BRAM pipeline advisory. Irrelevant to ASIC
  where SRAM macros are explicitly instantiated.
- **AXI SmartConnect singleton control sets** — IP-generated FPGA timing concern only.

---

## 6. Priority action list (ASIC-ordered)

| # | Action | File | Severity | Effort |
|---|---|---|---|---|
| 1 | Verify `fifo/asic/tidelink_sram.sv` instantiates a TSMC macro, not inferred registers | `src/rtl/fifo/asic/tidelink_sram.sv` | HIGH | Small |
| 2 | Add reset synchronizer at top-level `resetn` input; audit Wlink ICG test enable | `src/rtl/tidelink_top.sv` | HIGH | Medium |
| 3 | Audit CDC paths for `swi_phase_offset` and autoneg signals; add missing 2-FF synchronizers | `src/rtl/tidelink_top.sv`, `tidelink_phy_align_regs.sv` | HIGH | Medium |
| 4 | Replace CAM serial priority chain with descending overwrite; remove `found` variable | `src/rtl/tl_addr_trans_cam.sv:82` | MEDIUM | Small |
| 5 | Merge calibrator `phase_offset` to single 3-input mux | `src/rtl/tidelink_phy_align_calibrator.sv:710` | MEDIUM | Small |
| 6 | Mark `tidelink_addr_translation.sv` as reference/unused; remove from lint Makefile | `src/rtl/tidelink_addr_translation.sv`, `cocotb/lint/Makefile.synth` | MEDIUM | Trivial |
| 7 | Wire PTP HW capture ports in FPGA BD and validate before ASIC | Vivado BD | MEDIUM | Medium |
