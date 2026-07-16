# TideLink V2 — On-Silicon Regression Suite

Hardware regression tests for the **proven V2 A→B data path** on the PYNQ-Z2
pair. Run these after any RTL / build / recipe change to confirm you have not
regressed link-up, the PHY eye, cross-lane deskew alignment, or A→B data
delivery. Produces a PASS/FAIL report and a CI-friendly exit code (0 = all pass).

This suite encodes the milestone reached **2026-06-26**: the first byte-exact
V2 A→B data crossing on silicon.

## What it tests

The suite runs the real datapath once and asserts each stage:

| # | Test | Asserts | Proves |
|---|------|---------|--------|
| 01 | `link_up` | both dies reach `fcsm=4` (bilateral) | bring-up / link negotiation |
| 02 | `phy_rx_clean` | die_b's post-deskew RAWWORD (`0x212C/30/34/38`) equals the golden per-lane SYNC slice, **byte-exact** | the RX eye / PHY (dist-0 reception) |
| 03 | `deskew_align` | `reanchored (0x44032140 bit0)=1` **and** `sync_seen_vec (0x4403215C)=0xe4` | cross-lane deskew alignment (all 4 active lanes armed) |
| 04 | `data_a2b` | after `txburst`, GP1 RX aperture `0x84010000..` equals the sent header+payload | end-to-end committed A→B data |

### The single most important gotcha

**`RXW` (`0x440320D4`) is the FC-replay pointer, *not* the app RX data counter** —
it reads `0` even when data has been delivered. Committed A→B data lands in the
**GP1 RX aperture `0x84010000`**. Test 04 reads *that*. Do not regress to
checking `RXW`.

Two more reading traps (baked into the lib, noted for anyone extending it):
- The **GP1 RX aperture pops on read** — each read consumes one FIFO word. Read
  every word *exactly once* (don't dump-then-assert the same word twice). Test 04
  asserts the header + the first two payload words (`0x00240000`, `0xcafe0001`,
  `0xcafe0002`) — the byte-exact set the milestone confirmed.
- `tl39.py rd` needs a **hex** address string (`0x84010000`), not a bash-arithmetic
  decimal — see `gp1_rx()`.

## How to run

The tests SSH one hop from a lab host to each board (tl39.py). Run on a host
that can reach the pair directly (e.g. `mapstone-dev`).

```bash
# 1) build + bit2bin + stage the bitstream-under-test on the lab host:
#      tidelink.bin       -> die_a   (pynq-z2-pair-all)
#      tidelink-flip.bin  -> die_b   (pynq-z2-pair-flip-all)
#    into $TD_DEPLOY_DIR (default /tmp/tidelink_deploy_l7)

# 2) from the repo, stage + run on the lab host:
fpga/hw_regression/stage_and_run.sh mapstone-dev

# …or, already on the lab host:
cd fpga/hw_regression && ./td_v2_regress.sh
```

### Options (`td_v2_regress.sh`)

| Flag | Effect |
|------|--------|
| `--no-deploy` | skip re-flashing — use the loaded bitstream. Faster, but a stale GP1 FIFO can false-PASS test 04; **deploy for a trustworthy run**. |
| `--no-lease` | skip `fpgahub` lease acquire/release (caller already holds it). |
| `--keep` | hold the lease after finishing. |
| `--rolls N` | bring-up POR retries for the eye lottery (default 6). |

### Example output

```
======== TideLink V2 HW regression (...) ========
== link_up ==        [PASS] link_up        18s
== phy_rx_clean ==    ok   lane2 rx slice: 0x5B4C   ...   [PASS]
== deskew_align ==    ok   reanchored: 1   ok   sync_seen_vec: 0xe4   [PASS]
== data_a2b ==        ok   GP1 payload[0]: 0xcafe0001   ...   [PASS]
  ✅ ALL TESTS PASS — V2 A->B path intact
```

## The proven recipe (encoded in `td_v2_hwlib.sh`)

```
deploy → rcp (bring-up) → bilateral(fcsm=4) → winscan (IDELAY centre → reanchored=1)
       → handoff → SYNC off (R8=0x10) → FC CTRL 0x00027f07 → txburst → read GP1 0x84010000
```
Key RTL fixes this path depends on (don't revert without re-validating here):
- full-range per-lane IDELAY tap (`tidelink_idelay_rx.sv`: `{nibble,lsb}`) + the
  data-mode SYNC-distance obs used by the winscan;
- the **`reanchored` timeout-veto removal** in `tidelink_lane_deskew.sv` (the
  latch must fire when `all_sync_seen && sr_rd_safe`, however late the eye is
  centred).

## Hardware-safety notes (baked into the lib)

- **Throttle register reads** (`TD_THROTTLE`, default 0.25s). Dense mmap read
  loops wedge the PYNQ PS kernel and require a physical power-cycle.
- Only **A→B** (die_a sends) is exercised — the safe direction. **B→A** (die_b
  sends) risks wedging die_b's PS (`credmax=0`); add it only with that caveat.
- Acquires the `bridge1` lease before and releases on exit (incl. abort).
- Pre-flight pings both boards; aborts cleanly if one needs a power-cycle.

## Extending the suite

- New checks: add a `t_<name>` function in `td_v2_regress.sh` returning 0/1 and a
  `run_test <name> t_<name>` line; use `assert_eq "label" expected actual`.
- Reusable helpers / registers / golden values live in `td_v2_hwlib.sh`.
- Override topology/paths via `TD_*` env vars (see the top of `td_v2_hwlib.sh`):
  `TD_A_IP`, `TD_B_IP`, `TD_DEPLOY_DIR`, `TD_LEASE`, `TD_THROTTLE`, …

## Zero-poke autonomy scripts (added 2026-07-03, L4 training-exit era)

Codify the autonomous bring-up proof loop (see `docs/TESTING.md` §3-4).
All source `td_v2_hwlib.sh`; shellcheck-clean; validated against a board
emulator — **first-use silicon validation pending**.

| Script | Role |
|--------|------|
| `zeropoke_proof.sh <a\|b\|both> [--stagger SEC]` | one fresh-POR zero-poke bring-up (arm = `NEGO_CFG=0x61` + `NEGO_TRAIN_CFG=0x0001`, nothing else), per-step timestamps, machine-parseable a–h `ZP_SCORECARD`; exit 0 iff (h) data (3× A→B + B→A byte-exact) passed |
| `zeropoke_soak.sh N` | N consecutive fresh-POR proofs, arm order alternating a,b,… + a near-simultaneous `both` last cycle; per-cycle one-liner + N/M summary split by order |
| `snapshot.sh <tag>` | one-command FULL debug-register dump from BOTH dies to a timestamped file (read-only, safe anywhere) |
| `linkhold_soak.sh MIN --manual\|--autonomous` | held-link time-stability: txburst every 30 s for MIN minutes, per-burst byte-exact score + link-health fields (hunts the ~20 min time-correlated death class) |

Extra safety rule they enforce: **never write `0x21B0`/`0x21B4`** — the
on-chip winscan FSM owns SYNC_DIST_SEL and SWI_PHASE_LSB now (reads are fine).

## Files

| File | Role |
|------|------|
| `td_v2_hwlib.sh` | sourced library: board access, the proven recipe, property readers, named registers (incl. the zero-poke set), assert framework, lease/health |
| `td_v2_regress.sh` | the manual-recipe suite runner (tests 01–04, report, exit code) |
| `zeropoke_proof.sh` | fresh-POR autonomous bring-up, a–h scorecard |
| `zeropoke_soak.sh` | N-cycle arm-order-swept zero-poke soak |
| `snapshot.sh` | both-die full debug-register evidence capture |
| `linkhold_soak.sh` | held-link time-stability soak |
| `stage_and_run.sh` | rsync the suite to the lab host and run it |
| `README.md` | this file |
