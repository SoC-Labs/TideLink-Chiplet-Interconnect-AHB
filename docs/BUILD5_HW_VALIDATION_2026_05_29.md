# Build #5 (F-1 watchdog fix) HW validation — PARTIAL SUCCESS

**Date:** 2026-05-30 00:45-00:50 BST
**Build:** #5 (ILA-instrumented, `FPGA_INSERT_DEBUG_CORE=1`, **plus F-1 watchdog fix**)
**Build SHAs:** master sha256 `e4783985…bb757c` md5 `3b6baa99…`; slave sha256 `f77a36ac…6d06` md5 `1ac98c32…`
**Branch:** `fix/fcsm-l7-wedge-watchdog-build5-hw` (off `fix/fcsm-l7-wedge-watchdog` @ `f10e6fe`)
**Wall:** 102m58s (master local, slave srv04936, concurrent)
**Lease:** held during validation, released 00:50

## Headline

**F-1 watchdog successfully unwedges the FCSM** (0/5 deploys reach the master state-7 trap that 5/5 build #4 deploys did), **but doorbell delivery is still broken** (5/5 deploys: `slave DB_RESP=0`, `master returner_busy=1` stuck after 100 master rings). The wedge mechanism has at least one more layer.

This confirms the caveat raised independently by **Agent B (sim repro doc §7)** and **Agent D (independent diagnosis §H2)**:

> "F-1 watchdog only clears `send_nack_req` — it does NOT independently unwedge state 7. The state-7 → state-4 transition requires `auto_tx_out_advance` (LLTX-side). If HW debug shows the FCSM stuck at state 7 even after `send_nack_req` clears, the F-1 fix needs an `auto_tx_out_advance` escape hatch."

What actually happened on HW is more nuanced: the FCSM DID exit state 7 (most deploys reach state 4 = LINK_IDLE), but the downstream returner/credit machinery is still trapped in a broken state inherited from the transient state-7 visit.

## Multi-deploy results (5 fresh deploys)

| Deploy | Master LANE_STATUS | Master FCSM state | Slave LANE_STATUS | Slave state | cal_done both | After ring: master RB | After ring: slave DB_RESP |
|---|---|---|---|---|---|---|---|
| 1 | 0x008500ff | **2** (SEND_CREDITS2?) | 0x008500ff | 2 | 1/1 | **1** | **0** |
| 2 | 0x018900ff | **4** (LINK_IDLE) | 0x018900ff | 4 | 1/1 | **1** | **0** |
| 3 | 0x018900ff | **4** (LINK_IDLE) | 0x018900ff | 4 | 1/1 | **1** | **0** |
| 4 | 0x018900ff | **4** (LINK_IDLE) | 0x018800ff | 4 | 1/0 (asym) | **1** | **0** |
| 5 | 0x000200ff | **1** (SEND_CREDITS1?) | 0x000200ff | 1 | 0/0 | **1** | **0** |

**Compared to build #4** (no watchdog):
- Build #4: 5/5 deploys had master FCSM = 7 (SEND_NACK wedge). Slave at state 4.
- Build #5: 0/5 deploys at state 7. Mostly state 4 (LINK_IDLE) — the **watchdog evidently fired** and unwedged the FCSM.

**Compared to build #3** (original working, no ILA):
- Build #3: master + slave both at state 4, doorbells deliver, slave resp_acc bumps by 4096 per 100 rings.
- Build #5 deploy 2/3: master + slave both at state 4 (same as build #3), **but doorbells still don't deliver**.

So FCSM state is now nominal in build #5 (sometimes) but the downstream FC application path is broken.

## Comparison summary

| Symptom | Build #3 (no ILA, no fix) | Build #4 (ILA, no fix) | Build #5 (ILA + F-1 watchdog) |
|---|---|---|---|
| Clean PHY convergence | 5/5 | 2/5 | 3/5 |
| Master FCSM at state 7 (wedge) | 0/5 | **5/5** | **0/5** ✓ |
| Master returner_busy stuck after ring | 0/5 | 5/5 | **5/5** ❌ |
| Slave DB_RESP bumps after ring | 5/5 | 0/5 | **0/5** ❌ |

## What this means

1. **The watchdog works as designed.** FCSM no longer wedges at state 7. This part of the L7 problem is solved.

2. **There's a downstream wedge** that the watchdog doesn't address. Possibilities:
   - The slave's receiver state machine is in a different broken state (e.g. waiting for the NACK that was never actually delivered).
   - Returner FSM state is sticky based on something other than FCSM state.
   - Credit-handshake state machine carries forward a broken state from the brief state-7 visit.
   - The L7 mode was masking a separate ILA-placement issue that affects the returner/credit path directly.

3. **F-1 alone is necessary but not sufficient** for HW recovery.

## Recommended next step — F-1.5

The fix needs to be augmented. Two design directions:

### F-1.5a — force state transition out of state 7

In addition to clearing `send_nack_req`, when the watchdog fires:
- Force `state` to 4 (LINK_IDLE) via a synchronous state-override
- This bypasses the `auto_tx_out_advance` dependency
- Risk: if the FCSM is in state 7 for a legitimate reason mid-data (post-bringup), forcing to state 4 could break a real recovery cycle. Mitigation: only allow the force-transition before `socl_l7_reached_link_data` latches (so it only acts during bringup, like the existing forgive gate).

### F-1.5b — reset the returner sticky state when watchdog fires

If the returner has its own sticky-busy bit triggered by the transient state-7 visit, expose a clear-on-watchdog signal that propagates up to the returner. Requires plumbing across the override boundary.

### F-5 (postponed earlier) — SW escape hatch

This is now MORE valuable. An APB-writable bit that resets the returner FSM + send_nack_req would let `deploy_pair.sh` recover any wedge via SW poke, regardless of which sticky bit caused it.

## Lease released. Build artefacts preserved on mapstone-dev:

- Build #5 active at `/tmp/tidelink_deploy/{tidelink,tidelink-flip}.bin`
- Build #4 backed up at `*.build4-bak`
- Build #3 backed up at `*.build3-bak`

## Recommended next session

1. Dispatch an agent to scope F-1.5a + F-1.5b on the existing fix branch (or a new branch off it).
2. Implement, sim-test against the existing wedge-repro test (which now reliably reproduces the failure).
3. Build #6 with both F-1 and F-1.5, re-validate.
