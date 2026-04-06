# TideLink Auto-Negotiation Verification Plan

## 1. Overview

This document describes the verification plan for the TideLink auto-negotiation feature, which allows two chiplet controllers to dynamically resolve their master/slave roles via an I2C-based SDA arbitration protocol, replacing the static strap-based role assignment.

### 1.1 Scope

The auto-negotiation subsystem resides within each `tidelink_top` instance and includes:
- `nego_fsm`: Arbitration state machine (IDLE -> WAIT_LOCK -> NEGOTIATE -> DONE/ERROR)
- Priority register (`NEGO_PRIORITY`) used for SDA line arbitration
- Timeout mechanism (`NEGO_TIMEOUT`) with configurable fallback role
- I2C prescale configuration for bus timing
- Status and error reporting via `NEGO_STATUS` register and `nego_error_irq`
- Integration with role lock logic (sets `role_cfg` and optionally `role_locked`)

### 1.2 Out of Scope

- I2C electrical-level verification (using behavioural model)
- PUF hardware internals (PUF seed treated as a register input)
- SerDes PHY behaviour

## 2. Feature List

| ID  | Feature | Priority | Description |
|-----|---------|----------|-------------|
| F50 | Bypass mode (nego_en=0) | P0 | Existing boot flow unaffected when auto-negotiation is disabled |
| F51 | Normal negotiation | P0 | Two sides with different priorities negotiate; correct role resolution (lower priority wins master) |
| F52 | SDA early-exit | P1 | Peer claiming detected on SDA; local side yields and becomes slave |
| F53 | Timeout with fallback | P0 | Both sides timeout; fallback role applied per NEGO_CFG.fallback |
| F54 | PUF priority source | P2 | puf_seed used as priority when pri_sel=2 |
| F55 | Force lock disabled | P1 | FSM sets role but does not assert role_locked when force_lock=0 |
| F56 | NEGO_STATUS register | P0 | Register reflects correct FSM state (nego_done, nego_error, nego_won, nego_lost) |
| F57 | nego_error_irq assertion | P1 | Interrupt fires on negotiation error or timeout |
| F58 | Full boot with autoneg | P0 | Negotiate -> lock -> Wlink train -> TideLink init -> packet transfer |
| F59 | Role persistence after warm reset | P1 | Negotiated role survives hresetn; re-negotiation not required |

## 3. Test Plan

| Test | Features | Description |
|------|----------|-------------|
| test_top_autoneg_basic | F51, F56, F58 | Side A priority=0x0001 (wins master), Side B priority=0x1000 (becomes slave); negotiate, init, send packet A->B |
| test_top_autoneg_bypass | F50 | Neither side enables autoneg; static role lock via init_wlink(); verify packets flow normally |
| test_top_autoneg_timeout | F53, F56, F57 | Both sides same priority, very short timeout; both see NEGO_ERROR; fallback role applied |
| test_top_autoneg_force_lock_off | F55, F56 | Run negotiation with force_lock=0; verify role is set but role_locked remains 0 |
| test_top_autoneg_warm_reset | F59 | Negotiate, lock, send packet, assert hresetn, verify role persists, re-send packet |
| test_top_autoneg_puf_priority | F54, F51 | Set pri_sel=2, provide different puf_seed values; verify correct role resolution |
| test_top_autoneg_early_exit | F52, F56 | Stagger negotiation start; late side detects peer claiming, yields to slave |

## 4. Coverage Goals

### 4.1 Functional Coverage

| Covergroup | Bins | Target |
|------------|------|--------|
| cg_nego_outcome | won, lost, timeout, bypass | 100% |
| cg_nego_priority_src | register(0), strap(1), puf(2) | 100% |
| cg_nego_fallback | fallback_master(0), fallback_slave(1) | 100% |
| cg_nego_force_lock | enabled(1), disabled(0) | 100% |
| cg_nego_status_bits | done, error, won, lost | 100% |
| cg_nego_irq | error_irq_asserted, error_irq_not_asserted | 100% |

### 4.2 Code Coverage

| Metric | Target |
|--------|--------|
| Line coverage (nego_fsm) | >95% |
| FSM state coverage | 100% (all states and transitions) |
| Condition coverage | >90% |
| Toggle coverage | >85% |

### 4.3 Key Coverage Holes to Close

- Negotiation FSM: all state transitions including error recovery paths
- Priority comparison: equal priority (timeout path), priority inversion
- Timeout counter: exact boundary (timeout-1 vs timeout cycle)
- Force lock interaction with warm reset
- I2C bus contention during SDA arbitration phase
