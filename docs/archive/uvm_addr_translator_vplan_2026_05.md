> **ARCHIVED 2026-05-29** — This vplan describes the **legacy 256-entry segment-table**
> design (`address_translation` block, 64 segment registers, 256 entries per channel).
> The RTL was rewritten in commit `04f62c4` ("improving area utilisation by re-writing
> a number of the address translation components") to a **CAM-based 8-rule match/replace**
> design (`tl_addr_trans_cam` + `tl_addr_trans_regs`) for area efficiency
> (~2048 FFs/ch -> ~169 FFs/ch). The associated UVM env was never scaffolded
> (paper-only directory under `uvm/tidelink_addr_translator/` removed).
>
> Equivalent functional verification for the current CAM-based design is
> implemented in cocotb at `cocotb/tidelink_addr_translator/` (34 tests
> covering reset, register RW, single/multi-rule translation, priority,
> global enable, base offset wrap, channel independence, edge cases, rapid
> reconfiguration, and unmapped-register defaults).
>
> Items in this vplan that DO NOT map to current RTL: F3 "64 segment
> registers/256 entries", F4 "identity mapping on reset", F12 "PSLVERR on
> ports 2-15" (lightweight mux now only instantiates `NUM_CHANNELS` ports),
> XF2/XF6 "256:1 for-loop mux xprop". Items still relevant in spirit are
> covered by the cocotb suite.
>
> Preserved here so future engineers can mine design intent (xprop strategy,
> coverage targets, scoreboard 4-state reference model) if a UVM env is
> revived for the CAM design.

---

# TideLink Address Translator Verification Plan (legacy segment-table design)

## 1. Overview

This document describes the verification plan for the `tidelink_addr_translator` module, an APB-configurable segment-based address remapping subsystem used in the TideLink chiplet interconnect.

### 1.1 Scope

The `tidelink_addr_translator` DUT contains:
- `cmsdk_ahb_to_apb`: AHB subordinate to APB bridge (16-bit address, registered read data)
- `cmsdk_apb_slave_mux`: 16-port APB slave multiplexer (ports 0 and 1 active, ports 2-15 disabled)
- `apb_control` (x2): APB register banks for channel 0 and channel 1
- `address_translation` (x2): Combinational address translation logic for channel 0 and channel 1
- Optional big-endian byte swap logic (parameter `BE`, default 0)

Each channel provides:
- A 32-bit `base_offset` register at APB offset 0x000
- 64 segment registers (offsets 0x004-0x100), each packing 4 segment entries (8 bits each), for 256 total segment entries
- PID/CID identification registers at offsets 0xFD0-0xFFF
- Combinational address translation: `addr_o = {seg_addr[(addr_i - base_offset)[31:24]], addr_i[23:0]}`

The APB address space is decoded by `i_paddr[15:12]`:
- 0x0xxx: Channel 0 (`apb_control` instance 0)
- 0x1xxx: Channel 1 (`apb_control` instance 1)
- 0x2xxx-0xFxxx: Disabled ports (return PSLVERR)

### 1.2 Out of Scope

- Internal verification of `cmsdk_ahb_to_apb` (pre-verified Arm IP)
- Internal verification of `cmsdk_apb_slave_mux` (pre-verified Arm IP)
- Power management and scan/DFT chains

## 2. Feature List

| ID | Feature | Priority | Description |
|----|---------|----------|-------------|
| F1 | Reset state | P0 | All registers and translation outputs assume correct default state after reset |
| F2 | Base offset write/read | P0 | base_offset register is writable and readable via AHB config interface |
| F3 | Segment table write/read | P0 | All 64 segment registers (256 entries) writable and readable per channel |
| F4 | Identity mapping on reset | P0 | Default segment table provides identity address mapping (seg[n] = n) |
| F5 | Address translation correctness | P0 | Output address upper byte is remapped via segment table lookup |
| F6 | Base offset subtraction | P0 | Segment index is computed from (addr_i - base_offset)[31:24] |
| F7 | Lower 24 bits passthrough | P0 | addr_o[23:0] always equals addr_i[23:0] regardless of configuration |
| F8 | Channel independence | P0 | Programming channel 0 does not affect channel 1 and vice versa |
| F9 | Combinational translation | P0 | Translation output changes in the same cycle as input address change |
| F10 | APB mux port 0 access | P0 | AHB accesses to 0x0xxx reach channel 0 registers without error |
| F11 | APB mux port 1 access | P0 | AHB accesses to 0x1xxx reach channel 1 registers without error |
| F12 | APB mux disabled ports | P1 | AHB accesses to 0x2xxx-0xFxxx return PSLVERR |
| F13 | PID/CID registers | P1 | Peripheral and component ID registers return correct read-only values |
| F14 | Byte-lane strobes | P1 | Partial writes via PSTRB update only the targeted bytes |
| F15 | Big-endian byte swap | P2 | When BE!=0, AHB data is byte-swapped correctly based on HSIZE |
| F16 | Segment boundary crossing | P1 | Addresses at segment boundaries (0xNN000000, 0xNNFFFFFF) translate correctly |
| F17 | All segments mapped to same target | P1 | Configuring all 256 entries to the same value produces correct flat mapping |
| F18 | Rapid reconfiguration | P1 | Changing segment table entries between address translations yields correct results |
| F19 | Default read for unmapped registers | P2 | Reading undefined APB addresses within a channel returns 0xCAFECAFE |
| F20 | AHB protocol compliance | P0 | HREADYOUT and HRESP behave correctly for all transfer types |

### 2.1 X-Propagation Features

All UVM simulations are compiled with VCS `-xprop=tmerge` to enable accurate X-state tracking. The `tmerge` mode merges simulation semantics with synthesis semantics — assignments that would resolve differently under 2-state vs 4-state simulation are flagged, and X propagates through combinational paths where the output depends on an X-valued select or operand.

**Why xprop matters for this design:**
1. The `address_translation` module uses a for-loop to implement a 256:1 mux. Under default 2-state simulation, an X on `addr_i_norm[31:24]` silently selects an arbitrary entry. Under `-xprop=tmerge`, X correctly propagates to `addr_o[31:24]`.
2. The `base_offset` subtraction can produce X if either operand has X bits. With `tmerge`, this X flows through to the segment index.
3. Register write-enable decode depends on `psel`, `penable`, `pwrite`. An X on any control signal must not corrupt register state.
4. The big-endian byte-swap path (`gen_be_swap`) uses `reg_be_swap_ctrl` derived from `hsize` — an X on `hsize` must not produce incorrect swap logic.

| ID | Feature | Priority | Description |
|----|---------|----------|-------------|
| XF1 | Xprop: reset clears all X | P0 | All DUT outputs (hrdata, hresp, hreadyout, addr_o) are X-free after reset deassertion |
| XF2 | Xprop: translation mux X-sensitivity | P0 | X on addr_i[31:24] propagates to addr_o[31:24] (not silently resolved to an arbitrary entry) |
| XF3 | Xprop: base_offset X-propagation | P0 | X bits in base_offset register propagate through subtraction to segment index and then to addr_o |
| XF4 | Xprop: register write-enable X-guard | P0 | X on psel/penable/pwrite does not corrupt segment table or base_offset state |
| XF5 | Xprop: addr_i lower bits X-isolation | P1 | X in addr_i[23:0] propagates to addr_o[23:0] but does NOT affect addr_o[31:24] |
| XF6 | Xprop: partial X in addr_i upper byte | P1 | Individual X bits in addr_i[31:24] produce X in addr_o[31:24] (mux select is unknown) |
| XF7 | Xprop: segment entry with X value | P1 | If a segment register contains X bits (from X-tainted write data), translation output carries X |
| XF8 | Xprop: AHB control signal X rejection | P0 | X on hsel/htrans does not trigger a spurious APB transaction or register write |
| XF9 | Xprop: big-endian hsize X-handling | P2 | X on hsize with BE!=0 does not produce incorrect byte-swap state in reg_be_swap_ctrl |
| XF10 | Xprop: post-reset addr_i X tolerance | P0 | Before any address is driven (addr_i = X), addr_o does not produce non-X garbage values |

## 3. Test Plan

| Test | Features | Description |
|------|----------|-------------|
| test_reset_state | F1, F4 | Assert reset, verify base_offset reads 0x00000000 and segment table reads back identity mapping for both channels |
| test_base_offset_rw | F2, F10, F11 | Write various base_offset values to channel 0 and channel 1, read back and verify |
| test_segment_table_rw | F3, F10, F11 | Write all 64 segment registers per channel with known patterns, read back and verify all 256 entries |
| test_identity_translation | F4, F5, F7, F9 | After reset (identity mapping), apply addresses across all 256 segments and verify addr_o equals addr_i |
| test_single_segment_remap | F5, F7 | Program one segment entry to a non-identity value, verify only that segment is remapped; lower 24 bits unchanged |
| test_full_remap | F5, F6, F7 | Program all segments to a reversed mapping (seg[n] = 255-n), verify complete address space remapping |
| test_base_offset_translation | F6 | Set base_offset to 0x10000000, apply address 0x20345678, verify segment lookup uses index 0x10 (0x20 - 0x10) |
| test_base_offset_wrap | F6, F16 | Set base_offset to 0xFF000000, apply address 0x01000000, verify segment index wraps correctly (unsigned subtraction) |
| test_lower_bits_passthrough | F7 | Apply addresses with varying lower 24 bits, verify addr_o[23:0] always matches addr_i[23:0] regardless of mapping |
| test_channel_independence | F8 | Program channel 0 with one mapping and channel 1 with a different mapping, verify each channel translates independently |
| test_combinational_latency | F9 | Change addr_i and verify addr_o updates in the same simulation delta (zero-cycle latency) |
| test_apb_mux_disabled_ports | F12 | Issue AHB reads to addresses in ranges 0x2000-0xFFFF, verify HRESP indicates error |
| test_pid_cid_readback | F13 | Read PID registers (0xFD0-0xFEC) and CID registers (0xFF0-0xFFC) for both channels, verify expected values |
| test_byte_lane_strobes | F14 | Write to base_offset and segment registers with partial HSIZE (byte, halfword), verify only targeted bytes updated |
| test_big_endian_swap | F15 | Instantiate DUT with BE=1, perform word/halfword/byte writes and reads, verify byte swap logic |
| test_segment_boundaries | F16 | Apply addresses at exact segment boundaries (e.g., 0xNN000000 and 0xNNFFFFFF), verify correct segment selection |
| test_flat_mapping | F17 | Map all 256 segments to segment 0x42, verify every input address produces 0x42 in upper byte |
| test_rapid_reconfig | F18 | Program a segment, translate an address, reprogram the same segment, translate again, verify both results correct |
| test_undefined_register_read | F19 | Read from APB offsets beyond the segment table range (but within a channel), verify 0xCAFECAFE returned |
| test_ahb_protocol | F20 | Exercise IDLE and BUSY transfer types, verify HREADYOUT behavior and no spurious HRESP errors |

### 3.2 X-Propagation Tests

All xprop tests **require** VCS `-xprop=tmerge` to function correctly. Under default 2-state simulation, these tests would produce false passes. X injection is performed via `force`/`release` on the DUT virtual interface (with `$deposit` as fallback if `force` interacts with the xprop engine).

| Test | Features | Description |
|------|----------|-------------|
| test_xprop_reset_clears_x | XF1, XF10 | Before reset, force `addr_i` to `32'hxxxxxxxx` on both channels. Assert reset for 10 cycles. After reset deassertion, verify all DUT outputs (`chp_adr_hrdata`, `chp_adr_hresp`, `chp_adr_hreadyout`) are X-free. Verify `addr_o` reflects identity mapping of the X input (under tmerge, addr_o[31:24] will be X since addr_i is X, but control outputs must be clean). |
| test_xprop_addr_upper_x | XF2, XF6 | After reset, program a non-identity segment map on ch0. Drive `addr_i` with X in specific bits of [31:24] (e.g., `8'b1010_xxxx`). Verify `addr_o[31:24]` contains X (mux select is ambiguous). Verify `addr_o[23:0]` remains clean (passes through from non-X `addr_i[23:0]`). Repeat with 1, 2, 4, and 8 X bits in the upper byte. |
| test_xprop_addr_lower_x_isolation | XF5 | Drive `addr_i` with X in [23:0] but clean [31:24]. Verify `addr_o[31:24]` is correct (no X leakage from lower bits to upper byte via subtraction or lookup). Verify `addr_o[23:0]` carries the X from `addr_i[23:0]`. Test with X in individual byte lanes: [7:0], [15:8], [23:16]. |
| test_xprop_base_offset_x | XF3 | Write X-containing data to the `base_offset` register via AHB (force `hwdata` to have X bits during a valid write cycle). The register captures X under tmerge. Then apply a clean `addr_i`. Verify `addr_o[31:24]` contains X (because `addr_i_norm = addr_i - X_base_offset` is X, making the segment index unknown). |
| test_xprop_seg_entry_x | XF7 | Force X bits into a segment register by driving `hwdata` with partial X during a write to `SEG_REG[k]`. Then drive an address that hits that segment entry (upper byte = 4k). Verify `addr_o[31:24]` carries X from the corrupted segment value. Verify adjacent segment entries are unaffected. |
| test_xprop_write_enable_x_guard | XF4, XF8 | After programming known segment values, drive an AHB transaction where `hsel` has X bits (`hsel = 1'bx`). Verify the segment table and base_offset are NOT corrupted (read back all registers and compare against expected). Under tmerge, X on write-enable should cause registers to hold their previous value. |
| test_xprop_htrans_x | XF8 | After programming known values, drive `htrans = 2'bxx` (unknown transfer type) with `hsel = 1`. Verify register state is preserved by reading back all 64 segment registers + base_offset. No spurious writes should have occurred. |
| test_xprop_full_x_addr | XF2, XF10 | Drive `addr_i = 32'hxxxxxxxx` (all X) on ch0. Verify `addr_o` is all-X (both upper and lower bytes). This confirms the for-loop mux does not resolve X to an arbitrary entry. Repeat on ch1. |
| test_xprop_sequential_x_then_valid | XF1, XF2 | Drive `addr_i = X` for 10 cycles, then switch to a valid address `32'h42345678`. Verify `addr_o` transitions from X to the correct translated address within the same cycle (combinational — no pipeline flush needed). Verify no residual X contamination on subsequent valid addresses. |
| test_xprop_be_hsize_x | XF9 | (BE=1 build only) Drive a config write with `hsize = 3'bxxx`. Verify `reg_be_swap_ctrl` does not latch an incorrect value. Read back a known register to confirm the byte-swap path did not corrupt data. Then drive a valid hsize and verify correct operation resumes. |

### 3.3 Combined Functional + Xprop Tests

| Test | Features | Description |
|------|----------|-------------|
| test_xprop_random_translation | F5, F6, XF2, XF5 | Constrained-random test: for each of 1000+ iterations, randomly decide whether individual bits of `addr_i` are valid or X. For each transaction, predict: if upper byte selector contains any X, expect X in `addr_o[31:24]`; if lower bits have X, expect X in `addr_o[23:0]`; if all clean, expect normal translation. Uses 4-state reference model for comparison. |
| test_xprop_stress_reprogram | F18, XF4, XF7 | Stress test: rapidly interleave register writes (some with X-contaminated hwdata) and address translations. Verify the scoreboard correctly predicts X-tainted outputs for entries written with X data, and that valid register writes are not corrupted by adjacent X-tainted transactions. Run 500+ write+translate iterations. |

## 4. Coverage Goals

### 4.1 Functional Coverage

| Covergroup | Bins | Target |
|------------|------|--------|
| cg_segment_index | all 256 segment indices exercised via translation | 100% |
| cg_base_offset | zero, small (1-0xFF), medium (0x100-0xFFFF), large (0x10000000+), max (0xFFFFFFFF) | 100% |
| cg_channel_select | channel_0_only, channel_1_only, both_channels | 100% |
| cg_apb_port_decode | port_0, port_1, port_2_through_15 (disabled) | 100% |
| cg_register_access | base_offset, segment_reg[0:63], pid_regs, cid_regs, undefined | 100% |
| cg_addr_lower_bits | addr_i[23:0] corner values: 0x000000, 0xFFFFFF, random | 100% |
| cg_byte_strobes | full_word, upper_half, lower_half, single_byte[0:3] | 100% |

### 4.2 X-Propagation Coverage

These covergroups track the injection and observation of X states across the DUT. They use `$isunknown()` sampling to classify each transaction's X status.

| Covergroup | Bins | Target |
|------------|------|--------|
| cg_xprop_addr_i | `x_upper_byte` (any X in addr_i[31:24]), `x_lower_24` (any X in addr_i[23:0] only), `x_full` (X in both upper and lower), `x_partial_upper_1bit` (exactly 1 X bit in [31:24]), `x_partial_upper_4bit` (4 X bits in [31:24]), `no_x` (all clean) | 100% |
| cg_xprop_addr_o | `x_upper_byte_out` (X in addr_o[31:24]), `x_lower_24_out` (X in addr_o[23:0] only), `x_full_out` (all X), `clean_output` (no X) | 100% |
| cg_xprop_control | `x_on_hsel`, `x_on_htrans_0`, `x_on_htrans_1`, `x_on_hwrite`, `x_on_hsize_0`, `x_on_hsize_1`, `x_on_hsize_2`, `no_x_control` | 100% |
| cg_xprop_write_data | `x_in_base_offset_write` (X in hwdata during base_offset write), `x_in_seg_write` (X in hwdata during segment write), `clean_write` (no X in write data) | 100% |
| cg_xprop_x_cross | cross(`addr_i_x_state`, `seg_map_x_state`, `base_offset_x_state`) where each factor is {has_x, no_x} | >80% |

### 4.3 Code Coverage

| Metric | Target |
|--------|--------|
| Line coverage | >95% |
| Condition coverage | >90% |
| Toggle coverage | >85% |
| Branch coverage | >90% |

### 4.4 Key Coverage Holes to Close

- All 256 segment table entries programmed and exercised in translation for both channels
- Base offset values causing segment index wrap-around (unsigned underflow)
- Concurrent access patterns: programming one channel while the other is actively translating
- All disabled APB mux ports (2-15) accessed to confirm PSLVERR
- Big-endian path exercised with all three HSIZE values (byte, halfword, word)
- PID/CID register read-back for both channels
- **Xprop**: addr_i with X in exactly 1, 2, 4, and 8 bits of [31:24] (partial X granularity)
- **Xprop**: X on each individual AHB control signal (hsel, htrans[0], htrans[1], hwrite, hsize[0], hsize[1], hsize[2])
- **Xprop**: addr_o transition from X to valid within a single cycle (combinational check)
- **Xprop**: X in write data during base_offset write vs segment table write (separate coverage bins)
- **Xprop**: Cross-coverage of X presence in addr_i, segment map state, and base_offset state

## 5. Scoreboard Strategy

The scoreboard maintains two independent reference models, one per translation channel. All internal types **must** use `logic` (4-state) rather than `bit` (2-state) to correctly track X propagation under `-xprop=tmerge`.

1. **Register model**: Shadow copy of base_offset and all 256 segment entries per channel, updated on every AHB write. Compared against AHB read-back values. Under xprop, if write data contains X bits, the shadow register stores X in those positions.

2. **Translation model**: For each input address applied to a channel, the scoreboard computes the expected output using 4-state arithmetic:

   ```systemverilog
   function logic [31:0] predict(int channel, logic [31:0] addr_i);
     logic [31:0] addr_i_norm = addr_i - base_offset[channel];
     logic [7:0]  idx = addr_i_norm[31:24];
     logic [7:0]  seg_val;
     if ($isunknown(idx))
       seg_val = 8'hxx;  // X index -> X output (mux select unknown)
     else
       seg_val = seg_table[channel][idx];
     return {seg_val, addr_i[23:0]};
   endfunction
   ```

   Comparisons use `===` (4-state identity) rather than `==` to correctly handle X matching.

3. **APB error model**: Tracks which APB mux port is selected based on address decode; asserts PSLVERR expected for disabled ports 2-15.

4. **X-state tracker**: Dedicated analysis component connected to both channel monitors. On every transaction, classifies the X state of addr_i and addr_o and checks consistency:
   - If addr_i and all registers are X-free but addr_o contains X → `UVM_ERROR` (unexpected X)
   - If addr_i[31:24] or segment index contains X but addr_o[31:24] is non-X → `UVM_ERROR` (missing X propagation)
   - Samples `cg_xprop_addr_i`, `cg_xprop_addr_o`, and `cg_xprop_x_cross` covergroups

## 6. Register Map Summary

Each channel occupies a 4 KB APB address window. Channel 0 is at AHB offset 0x0000, channel 1 at 0x1000.

| Offset | Name | Access | Reset Value | Description |
|--------|------|--------|-------------|-------------|
| 0x000 | BASE_OFFSET | RW | 0x00000000 | 32-bit base offset subtracted from input address before segment lookup |
| 0x004 | SEG_REG_0 | RW | 0x03020100 | Segment entries [3:0] (packed 4 x 8-bit) |
| 0x008 | SEG_REG_1 | RW | 0x07060504 | Segment entries [7:4] |
| ... | ... | RW | identity | ... |
| 0x100 | SEG_REG_63 | RW | 0xFFFEFDFC | Segment entries [255:252] |
| 0xFD0 | PIDR4 | RO | 0x00 | Peripheral ID register 4 |
| 0xFD4 | PIDR5 | RO | 0x00 | Peripheral ID register 5 |
| 0xFD8 | PIDR6 | RO | 0x00 | Peripheral ID register 6 |
| 0xFDC | PIDR7 | RO | 0x00 | Peripheral ID register 7 |
| 0xFE0 | PIDR0 | RO | 0x59 | Peripheral ID register 0 |
| 0xFE4 | PIDR1 | RO | 0x16 | Peripheral ID register 1 |
| 0xFE8 | PIDR2 | RO | 0x15 | Peripheral ID register 2 |
| 0xFEC | PIDR3 | RO | 0x00 | Peripheral ID register 3 |
| 0xFF0 | CIDR0 | RO | 0x50 | Component ID register 0 |
| 0xFF4 | CIDR1 | RO | 0x51 | Component ID register 1 |
| 0xFF8 | CIDR2 | RO | 0x4C | Component ID register 2 |
| 0xFFC | CIDR3 | RO | 0x54 | Component ID register 3 |

## 7. SVA Assertions

Assertions are placed in a bind module or within the testbench interface. All assertions use `===` (4-state identity) for xprop compatibility.

### 7.1 Combinational Latency (xprop-aware)

```systemverilog
// Translation output must update in the same cycle as input change
// Under xprop, expected may contain X — use === not == for 4-state compare
property p_zero_latency_ch0;
  @(posedge CLK) disable iff (!RESETn)
    $changed(chp0_ahb_haddr_i) |-> ##0 (chp0_ahb_haddr_o === expected_ch0);
endproperty
a_zero_latency_ch0: assert property (p_zero_latency_ch0);
```

Repeat for ch1. The `expected_ch0` signal is driven by a bind-module that replicates the translation formula using the DUT's internal `seg_addr_0` and `base_offset_0` signals.

### 7.2 Lower 24 Bits Pass-Through (xprop-aware)

```systemverilog
// Lower bits pass through from addr_i, NOT addr_i_norm
// Under xprop, X in lower bits of addr_i should appear in addr_o[23:0]
property p_lower_passthrough_ch0;
  @(posedge CLK) disable iff (!RESETn)
    chp0_ahb_haddr_o[23:0] === chp0_ahb_haddr_i[23:0];
endproperty
a_lower_passthrough_ch0: assert property (p_lower_passthrough_ch0);
```

### 7.3 Xprop: Reset X-Clearing

```systemverilog
// After reset, hreadyout and hresp must be non-X
property p_reset_outputs_clean;
  @(posedge CLK)
    $rose(RESETn) |-> !$isunknown(chp_adr_hreadyout) && !$isunknown(chp_adr_hresp);
endproperty
a_reset_outputs_clean: assert property (p_reset_outputs_clean);
```

### 7.4 Xprop: No X on Register Outputs Post-Reset

```systemverilog
// Segment table and base_offset must be X-free one cycle after reset deassertion
property p_reset_regs_clean;
  @(posedge CLK)
    $rose(RESETn) |=> !$isunknown(u_apb_addr_translator_0.base_offset_reg) &&
                      !$isunknown(u_apb_addr_translator_0.addr_seg_reg[0]);
endproperty
a_reset_regs_clean: assert property (p_reset_regs_clean);
```

### 7.5 Xprop: Write-Enable X-Guard

```systemverilog
// If write-enable is X, register must hold previous value (not latch X)
// This is enforced by tmerge mode but we assert it explicitly
property p_wr_en_x_guard;
  @(posedge CLK) disable iff (!RESETn)
    $isunknown(u_apb_addr_translator_0.reg_write_en) |=>
      $stable(u_apb_addr_translator_0.base_offset_reg);
endproperty
a_wr_en_x_guard: assert property (p_wr_en_x_guard);
```

### 7.6 Xprop: No Unexpected X on Translation Output

```systemverilog
// When addr_i is fully known and all registers are X-free, addr_o must be X-free
property p_no_unexpected_x_ch0;
  @(posedge CLK) disable iff (!RESETn)
    (!$isunknown(chp0_ahb_haddr_i) &&
     !$isunknown(u_apb_addr_translator_0.base_offset_reg) &&
     !$isunknown(u_addr_translator_0.addr_o_latch))
    |-> !$isunknown(chp0_ahb_haddr_o);
endproperty
a_no_unexpected_x_ch0: assert property (p_no_unexpected_x_ch0);
```

### 7.7 AHB Protocol Compliance

Handled automatically by SVT AHB VIP protocol checks. Enable via:
```
master_cfg[0].protocol_checks_enable = 1;
```

## 8. Simulation Configuration

All simulations use VCS with:
```makefile
VCS_FLAGS += -xprop=tmerge          # X-propagation: tmerge mode
VCS_FLAGS += -cm line+cond+tgl+fsm+branch  # Code coverage
VCS_FLAGS += -cm_hier $(TB_DIR)/cov_hier.cfg  # Scope to DUT hierarchy
```

For xprop-specific tests, the testbench uses `force`/`release` via the virtual interface to inject X values onto DUT inputs. If `force` interacts poorly with the xprop engine, `$deposit` is used as a fallback. The `x_state_tracker` component monitors all DUT outputs and samples the `cg_xprop_*` covergroups.

## 9. Risks and Assumptions

### 9.1 Assumptions

- `cmsdk_ahb_to_apb` and `cmsdk_apb_slave_mux` are pre-verified Arm CMSDK IP
- `apb_control` and `address_translation` modules from axi-chiplet-controller are compiled on the file list
- AHB VIP correctly implements AHB-Lite protocol
- Single clock domain (CLK drives both AHB and APB sides)
- The `apb4_if` SystemVerilog interface is available and correctly defined
- VCS `-xprop=tmerge` is available on the project's VCS 2022.06-SP2 installation
- The `$isunknown()` system function is supported in both simulation and assertion contexts

### 9.2 Known Risks

| Risk | Mitigation |
|------|------------|
| Segment table reset values may differ across synthesis tools due to parameterized expressions | Verify identity mapping explicitly in test_reset_state |
| address_translation uses a for-loop with priority encoding rather than a case statement | Verify all 256 segment indices produce correct output, not just lower entries; xprop tests confirm X propagation through the for-loop mux |
| Dual-drive on CHP_ADR_APB_x.pwdata (assigned twice in RTL) | Confirm simulator handles this gracefully; flag for RTL cleanup |
| Big-endian path (BE!=0) is rarely instantiated | Dedicated test_big_endian_swap with separate DUT parameter override |
| AHB-to-APB bridge registered read data adds one cycle latency to reads | Test sequences must account for read latency in protocol timing |
| `-xprop=tmerge` may flag X in pre-verified CMSDK IP internals | Scope xprop assertions to DUT boundary signals only; use `cov_hier.cfg` to exclude CMSDK internals from toggle coverage |
| `force`/`release` for X injection may interact with VCS xprop engine | Validate X injection methodology in a trivial smoke test first; use `$deposit` as fallback if `force` causes unexpected behaviour |
| For-loop mux in `address_translation` may not propagate X correctly under all simulator configurations | test_xprop_full_x_addr and test_xprop_addr_upper_x explicitly verify this; if tmerge doesn't propagate X, escalate as RTL bug |
| 4-state reference model arithmetic may diverge from DUT under edge-case X patterns | Use `===` comparisons throughout; manual review of X prediction logic for subtraction overflow cases |

### 9.3 Future Enhancements

- Formal verification of translation function correctness via VC Formal `check_xprop` (matching the existing `xprop/tidelink/xprop.tcl` pattern)
- Create a dedicated `xprop/tidelink_addr_translator/xprop.tcl` for bounded xprop proof of the address translation block
- Constrained-random segment table programming with coverage-driven closure
- Integration-level xprop tests exercising address translation within full `tidelink_top` system
- Gate-level xprop simulation post-synthesis to verify X-optimism assumptions hold
- Performance benchmarking of back-to-back AHB config accesses
