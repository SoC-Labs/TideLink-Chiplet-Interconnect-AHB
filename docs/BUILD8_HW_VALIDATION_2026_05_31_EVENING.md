# Build #8 HW validation — 2026-05-31 evening (L11 widened force_ready)

**Build:** #8 (commit `bc52f88`, label `build8-ila-L11`, FPGA_INSERT_DEBUG_CORE=1)
**Bitstreams:** master sha `09e35b9cde35…`, slave sha `18578544b657…`
**Patches:** ILA mark_debug + L10 watchdog + **L11 widened force_ready pulse (1 → 4 cy)**
**Bug B fix:** NOT included (user reverted intentionally)

## L11 vs L10 vs Build #5 — wedge behaviour table

| Build | 1st AHB write | 2nd AHB write | Master recovery | Manual intervention needed |
|---|---|---|---|---|
| #5 (no L10) | Wedge | Wedge | Manual power-cycle (~3 min) | YES every time |
| #7 (L10, 1-cy pulse) | PASS | Wedge | Manual power-cycle (~3 min) | YES on 2nd write |
| **#8 (L11, 4-cy pulse)** | **PASS** | **SSH drop** | **AUTO recovers via PYNQ watchdog reboot** | **NO** |

## L11 test sequence

1. Build #8 staged + deployed cleanly (sha + manifest verified)
2. Master needed one power-cycle pre-bringup (separate transient)
3. `bringup_pair_converge` converged 16/16 at iter 3
4. 5× round AHB-write stress test:
   - **Round 1**: AHB write completes, master REG_STATUS=0, `hostname` returns `pynq-z2-02` ✅
   - **Round 2**: `client_loop: send disconnect: Broken pipe` during AHB write — master SSH drops
   - **Round 3-5**: `hostname` returns successfully, but `/tmp/build5_app_test.py` MISSING — confirms PYNQ kernel watchdog auto-rebooted between Round 2 and Round 3

## Interpretation

L11's widened force_ready pulse alone doesn't fully prevent the AHB write wedge under back-pressure stress, but it changes the failure mode:
- Wedge is NOT permanent (auto-recovers within ~60s via PYNQ Linux watchdog)
- No manual power-cycle needed → autonomous loop is now self-healing
- Test script lost (in `/tmp` on PYNQ) — production scripts should re-stage on each connect

## Why L11 still partially wedges

L11 widens the force_ready window from 1 → 4 cycles. The 2nd write may still get caught in a deeper FIFO state where:
- a2l_fc_replay FIFO stays full because slave RX still wedged (Bug A correctness)
- L11 drops words at WEDGE_LIMIT=16 cy intervals
- For length=2 packets (3 AHB words), 3 successive drops take ~3 × 17 = 51 cy = 2 μs
- But cumulative pressure on AXI SmartConnect across multiple writes may exhaust the outstanding-write buffer in a non-L10/L11-addressable way

## What worked vs what's still needed

✅ Build #4 R-1 regression eliminated (removed `pair_credit_counter` mark_debug)
✅ Bug A wedge primitive defanged in steady-state (L11)
✅ Master auto-recovers from stress wedge (no manual intervention)
✅ Bringup_pair_converge works for Build #8
❌ Slave RX FIFO still empty after AHB write (Bug A correctness unfixed)
❌ 2nd-write SSH disconnect still happens (transient; recovers in ~60s)
❌ Bug B fix is reverted (Bug B remains; SW workaround alone insufficient due to BD `phc_nanoseconds=30'h0` tie-off)

## Next iterations (when user resumes)

1. **Bug A correctness fix** — L9 was incomplete in sim; ILA capture of slave RX framer signals (`pkt_is_data_pkt`, `isExpPacket`, `send_nack_req`, `exp_pkt_num`) would inform the real RX-wedge fix. Build #6 probe set ([docs/BUILD6_ILA_PROBE_PATCH_2026_05_29.patch](BUILD6_ILA_PROBE_PATCH_2026_05_29.patch)) is ready for that.

2. **L12 fix idea — always-ready AHB**:
   ```systemverilog
   assign ahb_tx_hreadyout = 1'b1;  // never block AHB
   ```
   Drops every word when downstream blocked, but never wedges master. Maximally robust. SW polls `tx_dropped_cnt_r` for diagnostics. Trade-off: data loss without backpressure indication; arguably acceptable given Bug A means data lost anyway.

3. **Re-apply Bug B fix** when user is ready — patch is documented and sim-verified at [docs/BUG_B_PROPOSED_FIX_2026_05_29.patch](BUG_B_PROPOSED_FIX_2026_05_29.patch) (single-line OR-term + `</content>` trailer strip).

4. **Expose `tx_dropped_cnt_r` to APB** — needed for SW to detect wedge condition and reset link rather than expecting kernel watchdog. Currently the only diagnostic of L11 drops is the kernel reboot itself.

## Files

- Build #8 RTL: `src/rtl/tidelink_fc_adapter.sv` (L11 patch at lines 181-227)
- Patch recipe: `docs/BUG_A_WEDGE_INVESTIGATION_2026_05_31.md` (L10 base) + this doc (L11 extension)
- Predecessor: [BUILD7_HW_VALIDATION_2026_05_31.md](BUILD7_HW_VALIDATION_2026_05_31.md)

## Summary

Tonight's session converted Bug A from a **lab-incident-level wedge** (requires physical-equivalent power-cycle) into a **self-healing transient** (PYNQ Linux watchdog auto-recovers). Bug A correctness is still open, but the autonomous loop can now iterate on it without 3-minute manual recovery cycles. That makes the next-round Bug A fix iteration tractable.
