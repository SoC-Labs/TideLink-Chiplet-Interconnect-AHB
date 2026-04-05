# Servo Optimisation Verification Plan

## Changes Summary

| Area | Before | After |
|------|--------|-------|
| Multiply-by-1e9 | Dedicated multiplier | Conditional add/subtract |
| Sub-nanosecond fields | Present (110-bit timestamps) | Removed (78-bit timestamps) |
| PI controller | Combinational multiplier | Iterative shared multiplier |
| Integral accumulator | 64-bit | 32-bit |
| GM SIDEBAND | 4 words per timestamp | 3 words per timestamp |
| Area (servo) | 67K gates | Flattened into top-level module |
| Area (total design) | 444K gates | 347K gates |

## Multiplier Unit Tests (tidelink_mul_iter)

| ID | Test | Description | Pass Criteria | Status |
|----|------|-------------|---------------|--------|
| MUL-001 | Reset defaults | Assert reset, check outputs idle | `result_valid`=0, `busy`=0, `result`=0 after reset | New |
| MUL-002 | Zero times zero | Multiply 0 x 0 | `result`=0, `result_valid` pulses | New |
| MUL-003 | Identity multiply | Multiply N x 1 and 1 x N for several N | `result`=N in both cases | New |
| MUL-004 | Small positive multiply | Multiply small known values (e.g. 7 x 13) | `result`=91, matches reference | New |
| MUL-005 | Large operand multiply | Multiply values near 2^31 | `result` matches Python reference product | New |
| MUL-006 | Signed negative operands | Multiply negative x positive and negative x negative | `result` sign and magnitude correct | New |
| MUL-007 | Maximum negative value | Multiply -2^31 x -1 and -2^31 x 1 | `result` correct for both, no overflow anomaly | New |
| MUL-008 | Back-to-back operations | Issue second multiply immediately after `result_valid` | Second result correct, no stale data | New |
| MUL-009 | Busy flag behaviour | Assert `start` and monitor `busy` | `busy`=1 during iteration, deasserts with `result_valid` | New |
| MUL-010 | Randomised stress | 100 random signed operand pairs | All results match Python `a * b` reference | New |

## Servo Updated Tests (tidelink_ptp_servo)

These tests existed previously and have been updated to reflect the optimised servo.

| ID | Test | Description | Pass Criteria | Status |
|----|------|-------------|---------------|--------|
| SRV-001 | Reset defaults | Check all servo registers after reset | All fields zero; `servo_busy`=0; PI state cleared | Updated |
| SRV-002 | Offset calculation (positive) | Load t1 < t2 < t3 < t4 timestamps, trigger servo | `offset` = ((t2-t1) - (t4-t3)) / 2; 78-bit timestamp math; no sub-ns fields | Updated |
| SRV-003 | Offset calculation (negative) | Load timestamps producing negative offset | `offset` correctly sign-extended; adjustment is negative | Updated |
| SRV-004 | PI proportional term | Set Kp, Ki=0, trigger with known offset | `adjustment` = Kp * offset (via iterative multiplier) | Updated |
| SRV-005 | PI integral term | Set Kp=0, Ki, trigger twice with same offset | `integral` accumulates (32-bit); `adjustment` = Ki * integral | Updated |
| SRV-006 | PI combined | Set both Kp and Ki, trigger | `adjustment` = Kp*offset + Ki*integral, both via shared multiplier | Updated |
| SRV-007 | Servo busy duration | Trigger servo and measure cycles until done | Busy duration reflects iterative multiplier latency (~64 cycles per multiply) | Updated |

## Servo New Tests (tidelink_ptp_servo)

| ID | Test | Description | Pass Criteria | Status |
|----|------|-------------|---------------|--------|
| SRV-008 | 78-bit timestamp round-trip | Write 78-bit timestamps (46-bit sec + 32-bit ns), read back | No sub-nanosecond bits; readback matches written values exactly | New |
| SRV-009 | GM SIDEBAND 3-word format | Trigger GM sideband TX after servo | Exactly 3 words transmitted (was 4); no sub-ns word present | New |
| SRV-010 | Integral saturation at 32-bit | Drive offset to force integral toward 2^31-1 | Integral saturates or wraps at 32-bit boundary; no 64-bit overflow | New |
| SRV-011 | Phase step on large sec_diff | Load timestamps with abs(sec_diff) > 1 | Servo forces phase step (direct PHC set) instead of PI adjustment | New |
| SRV-012 | Phase step on sec_diff = 1 | Load timestamps with sec_diff exactly 1 | Servo still uses PI adjustment (boundary case, not forced step) | New |
| SRV-013 | Conditional add/subtract replaces multiply | Trigger offset calculation with known ns values | Offset computed without dedicated multiplier; result matches reference | New |
| SRV-014 | Shared multiplier arbitration | Trigger servo so Kp and Ki multiplies are sequential | Both multiplies complete; no deadlock; results correct | New |
| SRV-015 | Iterative multiply latency | Measure clock cycles for full servo computation | Total latency is previous + ~64 cycles (2 iterative multiplies); within budget | New |

## UVM System-Level Regression (tidelink_ptp_chain)

| ID | Test | Description | Pass Criteria | Status |
|----|------|-------------|---------------|--------|
| UVM-SYNC-001 | Single-hop sync convergence | Two-node PTP chain, run 50 exchanges | Offset converges below 100 ns threshold | Existing (re-validate) |
| UVM-SYNC-002 | Multi-hop sync convergence | Three-node PTP chain, run 100 exchanges | All slave offsets converge; no divergence after settling | Existing (re-validate) |
| UVM-SYNC-003 | Sync after phase step | Inject large initial offset (> 1 s), run exchanges | Phase step occurs on first exchange; subsequent exchanges converge via PI | New |
| UVM-SYNC-004 | Reduced-area gate-level smoke | Run UVM-SYNC-001 on post-synthesis netlist | Functional equivalence with RTL; sync converges | New |

## Coverage Goals

| Coverpoint | Target | Notes |
|------------|--------|-------|
| `tidelink_mul_iter` line coverage | >= 95% | All datapath lines exercised by MUL-001..010 |
| `tidelink_mul_iter` condition coverage | >= 90% | Signed/unsigned corner cases |
| `tidelink_ptp_servo` line coverage | >= 95% | Updated servo logic fully exercised |
| `tidelink_ptp_servo` FSM coverage | 100% | All states and transitions hit including iterative wait states |
| `tidelink_ptp_servo` toggle coverage | >= 80% | 78-bit timestamp fields, 32-bit integral, PI outputs |
| PI controller shared multiplier arbitration | 100% arcs | Kp-first and Ki-first scheduling both observed |
| Phase step vs PI adjustment decision | Both branches | Exercised by SRV-011, SRV-012 |
| GM SIDEBAND word count | 3 words only | No 4-word legacy format emitted (SRV-009) |
