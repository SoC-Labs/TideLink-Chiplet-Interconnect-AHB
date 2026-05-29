> **ARCHIVED 2026-05-29** — Companion to `uvm_addr_translator_vplan_2026_05.md`.
> Describes a UVM testbench architecture for the **legacy segment-table design**
> that no longer exists in RTL. The current CAM-based RTL is verified via
> cocotb at `cocotb/tidelink_addr_translator/`. Preserved here for design-intent
> reference (architecture diagram, scoreboard structure, coverage groups).

---

# TideLink Address Translator UVM Verification Plan (legacy segment-table design)

## 1. Overview

This document describes the UVM testbench architecture and test strategy for the
`tidelink_addr_translator` module, a standalone block-level verification
environment. The DUT provides two independent, APB-configurable address
translation channels, each backed by a 256-entry segment table and a
base-offset register. A single AHB subordinate config interface is bridged
internally to APB via `cmsdk_ahb_to_apb`, then fanned out through
`cmsdk_apb_slave_mux` to two `apb_control` register banks (slots 0 and 1).
Each slot drives a combinational `address_translation` block.

### 1.1 Translation Formula

The actual translation performed by `address_translation` is:

```
addr_i_norm = addr_i - base_offset
addr_o[23:0] = addr_i[23:0]
addr_o[31:24] = seg_addr[addr_i_norm[31:24]]
```

Key observations from the RTL:
- The base offset is subtracted from the input address to form `addr_i_norm`.
- Only the upper 8 bits of `addr_i_norm` are used to index the segment table.
- The lower 24 bits pass through from `addr_i` (NOT from `addr_i_norm`).
- Translation is purely combinational (zero clock-cycle latency).

### 1.2 Register Map (per channel)

Each `apb_control` instance occupies a 4 KB APB slot selected by
`paddr[15:12]` (slot 0 = `0x0xxx`, slot 1 = `0x1xxx`).

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | `BASE_OFFSET` | 32-bit base offset register (RW) |
| `0x004` | `SEG_REG[0]` | Segments 0-3 packed {seg3, seg2, seg1, seg0} (RW) |
| `0x008` | `SEG_REG[1]` | Segments 4-7 packed (RW) |
| ... | ... | ... |
| `0x100` | `SEG_REG[63]` | Segments 252-255 packed (RW) |
| `0xFD0` | `PIDR4` | Peripheral ID 4 (RO, `0x00`) |
| `0xFE0` | `PIDR0` | Peripheral ID 0 (RO, `0x59`) |
| `0xFE4` | `PIDR1` | Peripheral ID 1 (RO, `0x16`) |
| `0xFE8` | `PIDR2` | Peripheral ID 2 (RO, `0x15`) |
| `0xFEC` | `PIDR3` | Peripheral ID 3 (RO, `0x00`) |
| `0xFF0` | `CIDR0` | Component ID 0 (RO, `0x50`) |
| `0xFF4` | `CIDR1` | Component ID 1 (RO, `0x51`) |
| `0xFF8` | `CIDR2` | Component ID 2 (RO, `0x4C`) |
| `0xFFC` | `CIDR3` | Component ID 3 (RO, `0x54`) |

Reset defaults: `BASE_OFFSET = 0`, segment table = identity map
(`seg_addr[n] = n`).

### 1.3 Big-Endian Byte Swap

When parameter `BE != 0`, AHB write/read data passes through a byte-swap
block keyed on `hsize`. This is a secondary verification target
(parameterized build).

### 1.4 Scope

- Full register read/write path via AHB config interface
- Both address translation channels (ch0, ch1) independently
- Combinational translation correctness
- Register reset defaults
- PID/CID read-back
- Optional BE parameter variant

### 1.5 Out of Scope

- CMSDK bridge internals (pre-verified ARM IP)
- Integration with Wlink / XHB500 / FIFO (covered by `tidelink_top_system`)

## 2. Testbench Architecture

### 2.1 Block Diagram

```
+-------------------------------------------------------------------+
|  tidelink_addr_translator_env                                     |
|                                                                   |
|  +---------------------+                                          |
|  | ahb_cfg_sys_env     |  SVT AHB system env (active master,     |
|  | (svt_ahb_system_env)|  passive slave) for config interface     |
|  +----------+----------+                                          |
|             |                                                     |
|             |  analysis port                                      |
|             v                                                     |
|  +---------------------+    +-------------------------------+     |
|  | addr_translator_    |    | addr_translator_coverage      |     |
|  | scoreboard          |    +-------------------------------+     |
|  +---------------------+                                          |
|       ^          ^                                                |
|       |          |       virtual interface probes                  |
|  +----+----+ +---+----+                                           |
|  | ch0_mon | | ch1_mon|  Passive monitors sampling addr_i/addr_o  |
|  +---------+ +--------+                                           |
|                                                                   |
|  +--------------------------+                                     |
|  | addr_translator_ref_model|  Golden model: replicates seg       |
|  |                          |  table + base_offset state,         |
|  |                          |  computes expected addr_o            |
|  +--------------------------+                                     |
|                                                                   |
|  +--------------------------+                                     |
|  | addr_translator_vseq     |  Virtual sequencer: coordinates     |
|  |                          |  config + stimulus sequences        |
|  +--------------------------+                                     |
+-------------------------------------------------------------------+
                           |
                    +------+------+
                    |    DUT      |
                    | tidelink_   |
                    | addr_       |
                    | translator  |
                    +-------------+
```

### 2.2 Component Summary

| Component | Type | Role |
|-----------|------|------|
| `ahb_cfg_sys_env` | `svt_ahb_system_env` | Active AHB-Lite master to drive config reads/writes; passive slave to capture responses |
| `ch0_mon` | `addr_ch_monitor` | Passive monitor on `chp0_ahb_haddr_i` / `chp0_ahb_haddr_o` via virtual interface |
| `ch1_mon` | `addr_ch_monitor` | Passive monitor on `chp1_ahb_haddr_i` / `chp1_ahb_haddr_o` via virtual interface |
| `ref_model` | `addr_translator_ref_model` | Software golden model; shadows register writes, predicts addr_o |
| `sb` | `addr_translator_scoreboard` | Compares DUT output vs ref model for every address stimulus event |
| `cov` | `addr_translator_coverage` | Functional covergroups |
| `vseqr` | `addr_translator_vseq` | Virtual sequencer coordinating config + stimulus |

### 2.3 Interfaces

The testbench top (`top.sv`) instantiates a `tidelink_addr_translator_if`
SystemVerilog interface containing:

- AHB config signals (directly connected to SVT AHB VIP)
- `chp0_ahb_haddr_i`, `chp0_ahb_haddr_o` (exposed for ch0 monitor + driver)
- `chp1_ahb_haddr_i`, `chp1_ahb_haddr_o` (exposed for ch1 monitor + driver)
- Clock and reset

Address stimulus is driven combinationally from test sequences via
`force`/`release` or through a simple driver that sets `chpN_ahb_haddr_i`
on the virtual interface.

## 3. Agent Descriptions

### 3.1 AHB Config Agent (`ahb_cfg_sys_env`)

Reuses the project's standard `svt_ahb_system_env` with `ahb_lite = 1`,
one active master, one passive slave. Configuration class follows the
`top_sys_ahb_master_config` pattern from `tidelink_top_system_env`.

Responsibilities:
- Drive AHB-Lite single-word writes to program segment table and base offset
  registers (slot 0 at `0x0xxx`, slot 1 at `0x1xxx`)
- Drive AHB-Lite reads for register read-back verification
- Support byte-lane strobing (all `hsize` values: byte, halfword, word)
- Provide monitor analysis port to scoreboard and coverage

### 3.2 Address Channel Monitors (`ch0_mon`, `ch1_mon`)

Lightweight custom UVM monitors (not SVT -- simple virtual-interface samplers).

Each monitor:
- Samples `chpN_ahb_haddr_i` and `chpN_ahb_haddr_o` every clock edge
- On any change to `haddr_i`, captures a transaction object
  `addr_ch_transaction {addr_i, addr_o, channel_id, timestamp}`
- Sends transaction via `uvm_analysis_port` to scoreboard and coverage

### 3.3 Address Stimulus Drivers

Thin driver components (one per channel) that set `chpN_ahb_haddr_i` via the
virtual interface. Driven from sequences on the virtual sequencer. Since the
translation is combinational, no handshake protocol is required -- the driver
simply assigns the address and waits one clock cycle for the monitor to sample.

## 4. Reference Model

### 4.1 `addr_translator_ref_model`

A UVM component that maintains a software copy of the DUT register state:

```
bit [31:0] base_offset[2];       // per channel
bit [7:0]  seg_table[2][256];    // per channel, 256 entries
```

Initialization: mirrors reset defaults (`base_offset = 0`,
`seg_table[ch][n] = n` for all `n`).

The reference model connects to the AHB config monitor analysis port. On every
observed AHB write transaction, it updates its internal state:
- Decode `haddr[15:12]` to select channel (0 or 1)
- Decode `haddr[11:0]` to select register (base_offset at `0x000`, seg
  registers at `0x004`-`0x100`)
- Apply byte-lane masks from `hsize`

Prediction function:

```
function bit [31:0] predict(int channel, bit [31:0] addr_i);
  bit [31:0] addr_i_norm = addr_i - base_offset[channel];
  bit [7:0]  seg_val     = seg_table[channel][addr_i_norm[31:24]];
  return {seg_val, addr_i[23:0]};
endfunction
```

## 5. Scoreboard

### 5.1 `addr_translator_scoreboard`

Uses `uvm_analysis_imp_decl` for three streams (following the project
convention from `tidelink_top_system_scoreboard`):

| Stream | Source | Purpose |
|--------|--------|---------|
| `cfg_export` | AHB config monitor | Feed register writes to ref model |
| `ch0_export` | `ch0_mon` | Compare ch0 addr_o vs ref model prediction |
| `ch1_export` | `ch1_mon` | Compare ch1 addr_o vs ref model prediction |

On each address channel transaction:
1. Call `ref_model.predict(channel, addr_i)`
2. Compare predicted `addr_o` against observed `addr_o`
3. Report `uvm_error` on mismatch
4. Increment match/mismatch counters

In `report_phase`, print summary (matching the project's existing scoreboard
report format) and flag any mismatches as errors.

## 6. Sequences

All sequences target the virtual sequencer (`addr_translator_vseq`) which
holds handles to the AHB config sequencer and the two address stimulus
drivers.

### 6.1 Reset Sequence

- Assert reset for N cycles, release, wait for stabilization
- Verify segment table and base_offset return to identity/zero defaults
  via AHB read-back

### 6.2 Segment Table Programming Sequences

| Sequence | Description |
|----------|-------------|
| `seg_program_full_seq` | Write all 64 segment registers (256 entries) for one channel with known pattern |
| `seg_program_partial_seq` | Write a random subset of segment registers, leaving others at default |
| `seg_program_random_seq` | Randomize all 256 segment values and base_offset |
| `seg_program_identity_seq` | Explicitly write identity mapping (seg[n]=n, offset=0) |
| `seg_program_constant_seq` | Set all 256 entries to the same value (e.g., `0x42`) |
| `seg_readback_seq` | Write then read-back every register, checking data integrity |

### 6.3 Address Translation Sequences

| Sequence | Description |
|----------|-------------|
| `addr_random_seq` | Drive N random 32-bit addresses on one channel |
| `addr_sweep_upper_seq` | Sweep `addr_i[31:24]` through all 256 values with fixed lower 24 bits |
| `addr_sweep_lower_seq` | Sweep lower 24 bits with fixed upper 8 bits |
| `addr_boundary_seq` | Boundary addresses: `0x00000000`, `0xFF000000`, `0xFFFFFFFF`, `0x00FFFFFF`, `0x80000000` |
| `addr_base_offset_edge_seq` | Test with `base_offset` values causing `addr_i_norm[31:24]` to wrap (e.g., `addr_i = 0x01000000`, `base_offset = 0x02000000` => `addr_i_norm = 0xFF000000`) |

### 6.4 Directed Corner Case Sequences

| Sequence | Description |
|----------|-------------|
| `corner_identity_map_seq` | Default identity map, verify `addr_o == {addr_i[31:24], addr_i[23:0]}` when `base_offset=0` |
| `corner_all_same_seg_seq` | All segments map to `0xAA`, verify `addr_o[31:24]` always `0xAA` |
| `corner_zero_base_offset_seq` | `base_offset = 0`, verify `addr_i_norm == addr_i` |
| `corner_max_base_offset_seq` | `base_offset = 0xFFFFFFFF`, verify wrapping arithmetic |
| `corner_base_offset_only_seq` | Identity seg map + non-zero base_offset: the seg lookup index shifts but lower bits unchanged |

### 6.5 Stress Sequences

| Sequence | Description |
|----------|-------------|
| `stress_reprogram_translate_seq` | Interleave register writes with address translations: program a few entries, translate, reprogram, translate again -- ensures no stale state |
| `stress_rapid_addr_seq` | Drive addresses back-to-back every clock cycle for 1000+ cycles |
| `stress_both_channels_seq` | Simultaneous address stimulus on both channels while programming both |

### 6.6 Cross-Channel Independence Sequence

| Sequence | Description |
|----------|-------------|
| `cross_channel_independence_seq` | Program ch0 with pattern A and ch1 with pattern B; drive same addresses on both channels; verify ch0 output matches pattern A prediction and ch1 matches pattern B |
| `cross_channel_reprogram_seq` | Reprogram ch0 while ch1 is translating; verify ch1 output is unaffected |

### 6.7 PID/CID Read-Back Sequence

| Sequence | Description |
|----------|-------------|
| `pid_cid_readback_seq` | Read all 8 PID and 4 CID registers from both channels; compare against expected constants |

### 6.8 Big-Endian Sequence (BE != 0 build only)

| Sequence | Description |
|----------|-------------|
| `be_byte_swap_seq` | Program registers with known data using byte/halfword/word `hsize`; read back and verify byte ordering matches the swap logic |

## 7. Functional Coverage

### 7.1 `cg_seg_table_programming`

```
covergroup cg_seg_table_programming;
  // Which channel was programmed
  cp_channel: coverpoint channel_id { bins ch0 = {0}; bins ch1 = {1}; }

  // Which segment register index was written (0-63, each holding 4 entries)
  cp_seg_reg_idx: coverpoint seg_reg_idx {
    bins low    = {[0:15]};
    bins mid    = {[16:47]};
    bins high   = {[48:63]};
  }

  // Segment entry value
  cp_seg_value: coverpoint seg_value {
    bins zero    = {0};
    bins low     = {[1:63]};
    bins mid     = {[64:191]};
    bins high    = {[192:254]};
    bins max     = {255};
  }

  // Cross: channel x register index
  cx_ch_reg: cross cp_channel, cp_seg_reg_idx;
endgroup
```

### 7.2 `cg_addr_input`

```
covergroup cg_addr_input;
  // Upper 8 bits of input address (before base_offset subtraction)
  cp_addr_upper: coverpoint addr_i[31:24] {
    bins all_values[] = {[0:255]};
  }

  // Lower 24 bits interesting ranges
  cp_addr_lower: coverpoint addr_i[23:0] {
    bins zero     = {24'h000000};
    bins low      = {[24'h000001:24'h0000FF]};
    bins mid      = {[24'h000100:24'hFFFEFF]};
    bins high     = {[24'hFFFF00:24'hFFFFFE]};
    bins max      = {24'hFFFFFF};
  }

  // Channel
  cp_channel: coverpoint channel_id { bins ch0 = {0}; bins ch1 = {1}; }

  // Cross: all 256 upper values x channel
  cx_upper_ch: cross cp_addr_upper, cp_channel;
endgroup
```

### 7.3 `cg_base_offset`

```
covergroup cg_base_offset;
  cp_channel: coverpoint channel_id { bins ch0 = {0}; bins ch1 = {1}; }

  cp_base_offset: coverpoint base_offset {
    bins zero    = {32'h00000000};
    bins small   = {[32'h00000001:32'h000000FF]};
    bins medium  = {[32'h00000100:32'h00FFFFFF]};
    bins large   = {[32'h01000000:32'hFFFFFFFE]};
    bins max     = {32'hFFFFFFFF};
  }

  cx_offset_ch: cross cp_channel, cp_base_offset;
endgroup
```

### 7.4 `cg_translation_result`

```
covergroup cg_translation_result;
  // Input normalized segment index
  cp_input_seg: coverpoint addr_i_norm[31:24] {
    bins all_values[] = {[0:255]};
  }

  // Output segment value
  cp_output_seg: coverpoint addr_o[31:24] {
    bins all_values[] = {[0:255]};
  }

  // Cross: input segment index x output segment value
  cx_in_out_seg: cross cp_input_seg, cp_output_seg {
    option.cross_auto_bin_max = 65536;
  }
endgroup
```

### 7.5 `cg_config_interface`

```
covergroup cg_config_interface;
  // Read vs write
  cp_xact_type: coverpoint xact_type { bins READ = {0}; bins WRITE = {1}; }

  // APB slot (channel)
  cp_slot: coverpoint haddr[15:12] { bins slot0 = {0}; bins slot1 = {1}; }

  // Register address class
  cp_reg_class: coverpoint haddr[11:0] {
    bins base_offset = {12'h000};
    bins seg_regs    = {[12'h004:12'h100]};
    bins pid_regs    = {[12'hFD0:12'hFEC]};
    bins cid_regs    = {[12'hFF0:12'hFFC]};
    bins unmapped    = default;
  }

  cx_type_slot: cross cp_xact_type, cp_slot;
  cx_type_reg:  cross cp_xact_type, cp_reg_class;
endgroup
```

### 7.6 Coverage Targets

| Covergroup | Target |
|------------|--------|
| `cg_seg_table_programming` | 100% of `cx_ch_reg` bins |
| `cg_addr_input.cp_addr_upper` | 100% (all 256 values per channel) |
| `cg_base_offset` | 100% of all bins |
| `cg_translation_result.cx_in_out_seg` | >80% (not all 64K combinations needed) |
| `cg_config_interface` | 100% of all cross bins |

### 7.7 Code Coverage Targets

| Metric | Target |
|--------|--------|
| Line coverage | >95% |
| Condition coverage | >90% |
| Toggle coverage | >85% |
| Branch coverage | >90% |

## 8. Assertions and Checks

### 8.1 SVA: Combinational Latency

Placed in the testbench interface or a bind module:

```systemverilog
// Translation output must update in the same cycle as input change
property p_zero_latency_ch0;
  @(posedge CLK) disable iff (!RESETn)
    $changed(chp0_ahb_haddr_i) |-> ##0 (chp0_ahb_haddr_o === expected_ch0);
endproperty
a_zero_latency_ch0: assert property (p_zero_latency_ch0);
```

Repeat for ch1. The `expected_ch0` signal is driven by an RTL-level
reference (e.g., a bind-module that replicates the translation formula
using the DUT's internal `seg_addr_0` and `base_offset_0` signals).

### 8.2 SVA: Lower 24 Bits Pass-Through

```systemverilog
property p_lower_passthrough_ch0;
  @(posedge CLK) disable iff (!RESETn)
    chp0_ahb_haddr_o[23:0] === chp0_ahb_haddr_i[23:0];
endproperty
a_lower_passthrough_ch0: assert property (p_lower_passthrough_ch0);
```

### 8.3 SVA: AHB Protocol Compliance

Handled automatically by SVT AHB VIP protocol checks. Enable via:
```
master_cfg[0].protocol_checks_enable = 1;
```

Specifically verified:
- `HTRANS` encoding correctness
- `HREADY`/`HREADYOUT` handshake
- `HRESP` single-cycle OK or two-cycle ERROR
- No undefined `HRDATA` during valid read phase

### 8.4 SVA: Reset Defaults

```systemverilog
property p_reset_base_offset_ch0;
  @(posedge CLK)
    !RESETn |=> (DUT.base_offset_0 === 32'h0);
endproperty

property p_reset_seg_identity;
  @(posedge CLK)
    !RESETn |=> (DUT.seg_addr_0[0] === 8'h00) &&
                (DUT.seg_addr_0[1] === 8'h01) &&
                // ... (spot-check representative entries)
                (DUT.seg_addr_0[255] === 8'hFF);
endproperty
```

### 8.5 Scoreboard End-of-Test Checks

- All address stimulus transactions have been compared (no orphans)
- Match count > 0 (test actually exercised translation)
- Mismatch count == 0

## 9. Test List

| Test Name | Priority | Sequences Used | Coverage Targets | Description |
|-----------|----------|----------------|------------------|-------------|
| `test_reset_defaults` | P0 | Reset, PID/CID read-back, seg read-back | `cg_config_interface`, reset SVA | Verify all registers at reset defaults, read PID/CID |
| `test_reg_write_readback` | P0 | `seg_program_full_seq`, `seg_readback_seq` | `cg_seg_table_programming`, `cg_config_interface` | Write all 64 seg registers + base_offset for both channels, read back every value |
| `test_identity_translation` | P0 | `corner_identity_map_seq`, `addr_sweep_upper_seq` | `cg_addr_input`, `cg_translation_result` | Default identity map, sweep all 256 upper-byte values, verify output == input |
| `test_constant_segment_map` | P0 | `seg_program_constant_seq`, `addr_random_seq` | `cg_translation_result` | All segments to same value, verify all outputs have that upper byte |
| `test_random_translation_ch0` | P0 | `seg_program_random_seq`, `addr_random_seq` | `cg_addr_input`, `cg_translation_result`, `cg_base_offset` | Random seg table and base_offset on ch0, 1000 random addresses |
| `test_random_translation_ch1` | P0 | `seg_program_random_seq`, `addr_random_seq` | `cg_addr_input`, `cg_translation_result`, `cg_base_offset` | Same as above but targeting ch1 |
| `test_base_offset_zero` | P0 | `corner_zero_base_offset_seq`, `addr_random_seq` | `cg_base_offset` | base_offset=0 with random seg table |
| `test_base_offset_nonzero` | P0 | `corner_base_offset_only_seq`, `addr_sweep_upper_seq` | `cg_base_offset`, `cg_translation_result` | Identity seg map + non-zero base_offset; seg lookup index shifts |
| `test_base_offset_max` | P1 | `corner_max_base_offset_seq`, `addr_boundary_seq` | `cg_base_offset` | base_offset=0xFFFFFFFF, verify wrapping arithmetic in normalization |
| `test_base_offset_wrap` | P1 | `addr_base_offset_edge_seq` | `cg_base_offset`, `cg_translation_result` | addr_i < base_offset causing unsigned wrap of addr_i_norm |
| `test_boundary_addresses` | P1 | `addr_boundary_seq` | `cg_addr_input` | Drive 0x00000000, 0xFF000000, 0xFFFFFFFF, 0x00FFFFFF, 0x80000000 |
| `test_cross_channel_independence` | P0 | `cross_channel_independence_seq` | `cg_addr_input.cx_upper_ch` | Different seg maps on ch0/ch1, same input addresses, verify independent outputs |
| `test_cross_channel_reprogram` | P1 | `cross_channel_reprogram_seq` | `cg_seg_table_programming` | Reprogram ch0 while ch1 is actively translating; verify ch1 unaffected |
| `test_stress_reprogram` | P1 | `stress_reprogram_translate_seq` | `cg_seg_table_programming`, `cg_translation_result` | Interleave programming and translation rapidly |
| `test_stress_rapid_translate` | P1 | `stress_rapid_addr_seq` | `cg_addr_input` | Back-to-back address changes every cycle for 1000+ cycles |
| `test_stress_both_channels` | P1 | `stress_both_channels_seq` | `cg_addr_input.cx_upper_ch` | Simultaneous random addresses on both channels + random programming |
| `test_partial_program` | P1 | `seg_program_partial_seq`, `addr_random_seq` | `cg_seg_table_programming` | Only modify a subset of entries, verify unmodified entries retain defaults |
| `test_pid_cid_readback` | P0 | `pid_cid_readback_seq` | `cg_config_interface` | Read all PID/CID registers from both channels, compare to expected constants |
| `test_unmapped_reg_read` | P2 | Directed AHB reads to unmapped offsets | `cg_config_interface` | Read addresses outside defined register space, verify `0xCAFECAFE` default response |
| `test_byte_lane_strobe` | P1 | Directed byte/halfword writes | `cg_config_interface` | Write sub-word to seg registers, verify only targeted bytes update |
| `test_be_byte_swap` | P2 | `be_byte_swap_seq` (BE=1 build only) | Line coverage of `gen_be_swap` | Parameterized build with BE=1, verify byte-swap logic on config path |

## 10. Risks and Assumptions

### 10.1 Assumptions

- CMSDK `cmsdk_ahb_to_apb` and `cmsdk_apb_slave_mux` are pre-verified ARM IP
- `apb_control` and `address_translation` modules from `axi-chiplet-controller`
  are being verified indirectly through this testbench (not pre-verified)
- SVT AHB VIP correctly implements AHB-Lite protocol
- Single clock domain (no CDC)

### 10.2 Known Risks

| Risk | Mitigation |
|------|------------|
| `address_translation` uses `for` loop for 256-way mux; synthesis tools may infer latch | SVA checks that output is always driven; toggle coverage on `addr_o[31:24]` |
| Register byte-lane strobing may interact with endian swap | `test_byte_lane_strobe` and `test_be_byte_swap` sequences |
| `addr_i_norm` unsigned subtraction wrap may cause unexpected segment lookup | `test_base_offset_wrap` and `test_base_offset_max` specifically target this |
| Two channels share the same APB bus; concurrent config may cause contention | AHB-to-APB bridge serializes; verified by stress sequences |

### 10.3 Future Enhancements

- Formal verification of translation correctness (bounded model checking)
- Integration-level tests with `tidelink_top_system` exercising address
  translation on live Wlink traffic
- Power-aware verification (retention of seg table across power modes)
- Performance measurement: config write throughput through AHB-APB bridge
