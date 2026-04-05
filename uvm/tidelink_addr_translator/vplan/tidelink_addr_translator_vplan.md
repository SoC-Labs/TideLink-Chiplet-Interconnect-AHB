# TideLink Address Translator Verification Plan

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

### 4.2 Code Coverage

| Metric | Target |
|--------|--------|
| Line coverage | >95% |
| Condition coverage | >90% |
| Toggle coverage | >85% |
| Branch coverage | >90% |

### 4.3 Key Coverage Holes to Close

- All 256 segment table entries programmed and exercised in translation for both channels
- Base offset values causing segment index wrap-around (unsigned underflow)
- Concurrent access patterns: programming one channel while the other is actively translating
- All disabled APB mux ports (2-15) accessed to confirm PSLVERR
- Big-endian path exercised with all three HSIZE values (byte, halfword, word)
- PID/CID register read-back for both channels

## 5. Scoreboard Strategy

The scoreboard maintains two independent reference models, one per translation channel:

1. **Register model**: Shadow copy of base_offset and all 256 segment entries per channel, updated on every AHB write. Compared against AHB read-back values.

2. **Translation model**: For each input address applied to a channel, the scoreboard computes the expected output: `expected_addr_o = {seg_table[(addr_i - base_offset)[31:24]], addr_i[23:0]}` and compares against the DUT output.

3. **APB error model**: Tracks which APB mux port is selected based on address decode; asserts PSLVERR expected for disabled ports 2-15.

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

## 7. Risks and Assumptions

### 7.1 Assumptions

- `cmsdk_ahb_to_apb` and `cmsdk_apb_slave_mux` are pre-verified Arm CMSDK IP
- `apb_control` and `address_translation` modules from axi-chiplet-controller are compiled on the file list
- AHB VIP correctly implements AHB-Lite protocol
- Single clock domain (CLK drives both AHB and APB sides)
- The `apb4_if` SystemVerilog interface is available and correctly defined

### 7.2 Known Risks

| Risk | Mitigation |
|------|------------|
| Segment table reset values may differ across synthesis tools due to parameterized expressions | Verify identity mapping explicitly in test_reset_state |
| address_translation uses a for-loop with priority encoding rather than a case statement | Verify all 256 segment indices produce correct output, not just lower entries |
| Dual-drive on CHP_ADR_APB_x.pwdata (assigned twice in RTL) | Confirm simulator handles this gracefully; flag for RTL cleanup |
| Big-endian path (BE!=0) is rarely instantiated | Dedicated test_big_endian_swap with separate DUT parameter override |
| AHB-to-APB bridge registered read data adds one cycle latency to reads | Test sequences must account for read latency in protocol timing |

### 7.3 Future Enhancements

- Formal verification of translation function correctness across all 2^32 input addresses
- Constrained-random segment table programming with coverage-driven closure
- Integration-level tests exercising address translation within full `tidelink_top` system
- Performance benchmarking of back-to-back AHB config accesses
