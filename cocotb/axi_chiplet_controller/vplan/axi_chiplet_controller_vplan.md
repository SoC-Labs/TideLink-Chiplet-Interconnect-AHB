# AXI Chiplet Controller Verification Plan

## 1. Overview

This document describes the verification plan for the standalone `axi_chiplet_controller` module, exercised through cocotb adversarial tests.

### 1.1 Scope

The DUT is a single `axi_chiplet_controller` instance containing:
- Role register block (ROLE_CFG, ROLE_STATUS) with W1S lock and dual reset domains
- Wlink POR gating logic (Wlink held in reset until role is locked)
- APB mux: routes external APB or I2C-originated APB to Wlink based on role
- I2C pin mux: selects master or slave I2C core based on role
- I2C master and slave configuration registers (I2C_SLV_ADDR, I2C_PRESCALE)

Tests target adversarial corner cases: rapid register toggling, overlapping resets, simultaneous lock+role writes, and bus contention between APB and I2C paths.

### 1.2 Out of Scope

- Wlink internal behavior (stubbed at AXI interface)
- XHB500 bridges
- TideLink FIFO and FC adapter
- SerDes PHY electrical behavior
- End-to-end data flow (covered by tidelink_top_system vplan)

## 2. Feature List

| ID | Feature | Priority | Description |
|----|---------|----------|-------------|
| F1 | Role register POR default | P0 | After poresetn, ROLE_CFG=0 and ROLE_STATUS reflects strap pin |
| F2 | Role write before lock | P0 | Software can write ROLE_CFG.role when lock=0 |
| F3 | Role lock (W1S) | P0 | Writing 1 to ROLE_CFG.lock sets lock; only POR clears it |
| F4 | Simultaneous role+lock write | P0 | Single write with role=1 and lock=1 captures intended role |
| F5 | Role lock prevents change | P0 | After lock, writes to ROLE_CFG.role are silently ignored |
| F6 | Role strap override | P1 | Software role value overrides strap default before lock |
| F7 | Rapid role toggle before lock | P2 | Multiple role writes before lock, final value captured |
| F8 | Role register read-back | P0 | ROLE_CFG and ROLE_STATUS read back correct values at all times |
| F9 | Warm reset preserves role | P0 | hresetn asserted/released, role_locked and role_cfg survive |
| F10 | POR clears role | P0 | poresetn clears role_locked and role_cfg to defaults |
| F11 | Warm reset during unlocked state | P1 | hresetn while unlocked does not corrupt register state |
| F12 | Overlapping resets | P2 | Simultaneous poresetn+hresetn assertion handled correctly |
| F13 | Wlink POR gating before lock | P0 | Wlink held in reset when role is not locked |
| F14 | Wlink POR release after lock | P0 | Wlink released from reset once role is locked |
| F15 | Master mode APB passthrough | P0 | External APB writes/reads reach Wlink in master mode |
| F16 | Slave mode APB write gating | P0 | External APB writes to Wlink are blocked in slave mode |
| F17 | Slave mode APB read access | P1 | External APB reads from Wlink work in slave mode when I2C idle |
| F18 | I2C pin mux master mode | P1 | I2C master core drives SCL/SDA in master mode |
| F19 | I2C pin mux slave mode | P1 | I2C slave core drives SDA, SCL forced high-Z in slave mode |

## 3. Test Plan

### A. Role Register Tests

| Test | Features | Description |
|------|----------|-------------|
| test_01_role_por_default | F1, F8 | Assert poresetn, release, read ROLE_CFG=0, ROLE_STATUS=strap |
| test_02_role_write_before_lock | F2, F8 | Write role=1 while unlocked, read back, verify role=1 |
| test_03_role_lock | F3, F8 | Write lock=1, read back, verify lock is set |
| test_04_simultaneous_role_lock | F4, F8 | Single write role=1+lock=1, verify role=1 captured (not strap) |
| test_05_lock_prevents_role_change | F5 | Lock role=0, write role=1, read back, verify still role=0 |
| test_06_strap_override | F6 | Strap=0, write role=1 before lock, lock, verify role=1 |
| test_07_rapid_toggle | F7 | Write role=0,1,0,1,0 rapidly, lock, verify final value=0 |
| test_08_lock_w1s_no_clear | F3 | Write lock=1, then write lock=0, verify lock still=1 |

### B. Reset Domain Tests

| Test | Features | Description |
|------|----------|-------------|
| test_09_warm_reset_preserves | F9 | Lock role=1, assert hresetn, release, verify role=1 and locked |
| test_10_por_clears | F10 | Lock role=1, assert poresetn, release, verify role=0 and unlocked |
| test_11_warm_reset_unlocked | F11 | Write role=1 (no lock), assert hresetn, release, verify state clean |
| test_12_overlapping_resets | F12 | Assert both poresetn+hresetn, release poresetn first, verify POR behavior |

### C. Wlink POR Gating Tests

| Test | Features | Description |
|------|----------|-------------|
| test_13_wlink_held_before_lock | F13 | After POR, verify Wlink reset output is asserted (active) |
| test_14_wlink_released_after_lock | F14 | Lock role, verify Wlink reset output is deasserted |

### D. APB Mux Tests

| Test | Features | Description |
|------|----------|-------------|
| test_15_master_apb_passthrough | F15 | Set role=master, lock, APB write to Wlink address, verify reaches Wlink |
| test_16_slave_apb_write_gated | F16 | Set role=slave, lock, APB write to Wlink address, verify blocked |
| test_17_slave_apb_read_idle | F17 | Set role=slave, lock, APB read from Wlink address with I2C idle, verify data |

### E. I2C Pin Mux Tests

| Test | Features | Description |
|------|----------|-------------|
| test_18_i2c_master_pin_mux | F18 | Set role=master, lock, drive I2C master core, verify SCL/SDA outputs |
| test_19_i2c_slave_pin_mux | F19 | Set role=slave, lock, drive I2C slave core, verify SDA output, SCL=high-Z |

### F. I2C Config Tests

| Test | Features | Description |
|------|----------|-------------|
| test_20_i2c_slv_addr_write_unlocked | F8 | Write I2C_SLV_ADDR before lock, read back, verify |
| test_21_i2c_slv_addr_write_locked | F8 | Write I2C_SLV_ADDR after lock, read back, verify still writable |
| test_22_i2c_prescale_write_unlocked | F8 | Write I2C_PRESCALE before lock, read back, verify |
| test_23_i2c_prescale_write_locked | F8 | Write I2C_PRESCALE after lock, read back, verify still writable |

## 4. Coverage Goals

### 4.1 Functional Coverage

| Covergroup | Bins | Target |
|------------|------|--------|
| cg_role_config | master, slave | 100% |
| cg_role_lock | unlocked, locked | 100% |
| cg_role_transitions | strap_default_lock, override_then_lock, rapid_toggle_lock | 100% |
| cg_reset_domain | warm_reset_locked, warm_reset_unlocked, por_clear, overlapping | 100% |
| cg_wlink_por_gate | held_before_lock, released_after_lock | 100% |
| cg_apb_mux_mode | master_write, master_read, slave_write_gated, slave_read_idle, slave_read_i2c_active | 100% |
| cg_i2c_pin_mux | master_scl_drive, master_sda_drive, slave_sda_drive, slave_scl_hiz | 100% |
| cg_i2c_config | slv_addr_unlocked, slv_addr_locked, prescale_unlocked, prescale_locked | 100% |

### 4.2 Code Coverage

| Metric | Target |
|--------|--------|
| Line coverage | >95% |
| Condition coverage | >90% |
| FSM coverage | 100% (all states and transitions) |
| Toggle coverage | >85% |
| Branch coverage | >90% |

### 4.3 Key Coverage Holes to Close

- Role register: write with lock=1 and role changing in same cycle
- Reset domain crossing: poresetn and hresetn edges within one clock cycle
- APB mux: back-to-back write then read in slave mode
- I2C pin mux: role change while I2C transaction in progress (should not occur post-lock, but verify no glitch)

## 5. Risks and Assumptions

### 5.1 Assumptions

- Wlink is stubbed at its AXI/APB boundary; internal Wlink behavior is not tested here
- I2C master and slave cores are pre-verified IP; only pin mux routing is tested
- poresetn and hresetn are asynchronous; tests apply them with sufficient hold time
- cocotb clock generator provides a stable clock throughout the test

### 5.2 Known Risks

| Risk | Mitigation |
|------|------------|
| POR domain vs system reset domain metastability | Tests apply resets with sufficient hold time; RTL uses synchronizers |
| Wlink POR gating race at power-up | test_13 verifies Wlink stays in reset before lock |
| APB mux glitch during role lock | Lock is atomic W1S; mux switches only on lock edge |
| I2C bus hang if role changes mid-transaction | Role is locked before any I2C activity; lock prevents further changes |
| Overlapping reset edge timing | test_12 exercises simultaneous assertion; RTL gives POR priority |

### 5.3 Future Enhancements

- I2C functional transaction tests (byte-level read/write via I2C master and slave)
- APB error response injection (PSLVERR from Wlink stub)
- Clock domain crossing verification with independent POR and system clocks
- Constrained random register write sequences
- Formal verification of lock invariant: once locked, role never changes until POR
