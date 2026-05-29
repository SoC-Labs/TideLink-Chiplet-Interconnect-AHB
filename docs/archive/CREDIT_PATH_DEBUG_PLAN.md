# Credit-Path Debug Plan — Wlink LL_RX → cr_pkt → FCSM (2026-05-18)

## Where we are

The PHY per-lane alignment blocker is **solved** and HW-validated:
- RTL: `cab2d8f` (mask_hs gate), `d1351f4` (SWI_RECAL), per-lane-phase
  calibrator (`5633c69`/`cbf8c73`), lane-7 B19/F20→W9/V7 remap (`5d34baf`).
- Result: master and slave each reach up to `0xff` (8/8 lanes) at the
  right global phase (best clean point master_phase=0 / slave_phase=6 or
  3 → both 7/7, fault=0).

**Remaining blocker, now isolated:** in *every* configuration tried —
full 8-lane lock, clean masked common subset (5–6 lanes), training
dropped, LL bootstrapped — `CURRENT_CREDITS` stays `4096`, `CTRL_LOCK=0`,
no doorbell. Lane alignment is demonstrably achievable yet credits never
exchange. The Wlink **link-layer credit path is a second, independent
blocker** (consistent with the original 2026-05-13 LL_RX/ECC finding,
which the per-lane theory had superseded — both were real; the PHY had
to be fixed first to expose this cleanly).

## What the credit path is (signal chain)

```
pad_rx[*] → WavD2DGpioRx (per-lane deser, bit_slip+phase)
          → phy_link_rx_rx_link_data  (recovered RX clock domain)
          → WlinkRxLinkLayer  byte-align FSM (LinkLayer.scala ~611, state[1:0])
              ├ ECC check (ecc_check_corrupted / _corrected / corrected_ph)
              ├ SOP detect → is_short_pkt / is_long_pkt
              └ pkt decode → pkt_is_cr_pkt
          → WlinkGenericFCSM  (FC state machine)
              └ cr_pkt_seen_rx → leaves SEND_CREDITS1 (state 1) → credits
          → TideLink FC node  → CURRENT_CREDITS ≠ 4096, DOORBELL ticks
```
The v5 bitstream was built with `FPGA_INSERT_DEBUG_CORE=1`, so an ILA
already probes the LL_RX internals: `ecc_check_corrupted`,
`ecc_check_corrected`, `corrected_ph[23:0]`, `state[1:0]`, `byte0_reg`,
`byte1_reg`, `ll_byte_index_{0,1,2}`, `bytesPerCycle[8:0]`,
`is_short_pkt`, `is_long_pkt`, `valid` (see
`fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_drc.xdc`).

## Phase 0 — cheap cross-checks first (no ILA, hours)

Run before the heavyweight ILA capture; each can redirect the search.

1. **Lane-mask-as-variable.** Masking to a non-contiguous subset
   reconfigures the LL byte-striping (`rxLanePos`/`bytesPerCycle` from
   `io_lane_mask`). Test the LL with **no mask** (full 8) at a phase
   where one side is `0xff`, vs the masked subset. If FCSM behaves
   differently, the mask byte-striping is implicated; if identical,
   exonerated. Script: `pynq_host/scripts/phase_recal_sweep.sh` to find
   an 8/8 point, then probe without `apply_mask`.
2. **Training-vs-data lock gap.** `SWI_LANE_STATUS.locked` only
   validates the *training pattern*. Confirm whether the calibrated
   `bit_slip`/`phase` still aligns *real LL data* — the ILA `valid` /
   `byte0_reg` toggling is the only true indicator (Phase 1). A
   plausible failure: a lane locks the period-8 training byte but is
   off by a constant byte on live framed data.
3. **`fcsm_glitch_fix.patch`.** An untracked `fpga/fcsm_glitch_fix.patch`
   exists from a prior session — a candidate FCSM fix that may not be in
   the integrated build. Diff it against the current
   `WlinkGenericFCSM*.v`; if it addresses `cr_pkt_seen_rx` re-arm /
   reset, evaluate applying it (note: a *prior* in-session FCSM_6 edit
   was buggy — review carefully against git HEAD before reusing).
4. **One-direction sanity.** Hold only master→slave (or a loopback if
   the PHY supports it) and watch the slave LL_RX ILA — removes the
   bidirectional-coupling variable.

## Phase 1 — ILA capture of WlinkRxLinkLayer (the decisive step)

Bitstream already instrumented; need the `.ltx` + Vivado hardware
manager (the `.ltx` is emitted next to the `.bit` in
`/tmp/phase_sweep_wt/imp/fpga/output/pynq-z2-pair-*/`).

Procedure:
1. Deploy v5, bring lanes up at master_phase=0/slave_phase=6 (use
   `pynq_host/scripts/sw_coord_autocal_region8.sh` then drop training to
   data mode), keep the link held.
2. Open Vivado hw_manager over the JTAG/XVC path to the target FPGA,
   load the matching `.ltx`, arm the ILA on the recovered-RX clock.
3. Trigger on `state != iSTATE0` OR `ecc_check_corrupted` rising. Capture
   on both master and slave LL_RX.

Read the capture against this decision tree:

| ILA observation | Conclusion → next action |
|---|---|
| `state` stuck at `iSTATE0`, `byte*_reg` static/garbage | LL never sees valid bytes → recovered-clock/sampling quality on the in-use lanes, or lane-mask striping mismatch. Revisit per-lane phase margin / mask layout. |
| `byte*_reg` toggling but `ecc_check_corrupted=1` every word | Bit/byte alignment wrong despite training "lock": training-pattern lock ≠ LL-frame lock. Investigate a systematic per-lane offset; sweep `SWI_BIT_SLIP`/`SWI_PHASE_OFFSET` deltas around the calibrated values while watching ECC. |
| ECC clean, SOP (`is_short/long_pkt`) never asserts | Byte-align FSM never frames a packet → `LinkLayer.scala` framing logic / `bytesPerCycle` vs actual lane count mismatch. RTL review of the alignment FSM. |
| SOP seen, `pkt_is_cr_pkt` set, but FCSM stays state 1 | FCSM credit logic — `cr_pkt_seen_rx` not consumed / re-arm bug. This is the `fcsm_glitch_fix.patch` territory. |
| ECC clean, packets decode, FCSM advances on ONE side only | Asymmetry — the non-advancing side's TX (peer's RX) is the problem; focus there. |

## Phase 2 — fix per the diagnosis

- **Alignment/ECC** → the per-lane-phase calibrator's lock criterion may
  be too loose vs the LL framer's; tighten, or add an LL-data-domain
  lock check; possibly a constant per-lane byte-slip correction.
- **Framing/`bytesPerCycle`** → ensure the active-lane mask is set
  *identically and before* LL bring-up on both sides; verify the
  `rxLanePos` mapping for the chosen subset; prefer a contiguous mask
  if non-contiguous striping is the issue.
- **FCSM** → apply/repair the FCSM cr_pkt re-arm fix; add an APB-visible
  FCSM state + `cr_pkt_seen_rx` counter (small RTL) so this is probeable
  without ILA in future.
- Whatever the fix: add it as RTL on `feat/calibrator-phase-sweep`,
  cocotb-cover it (mirror `cocotb/phy_align/test_rtl_fix_coverage.py`),
  keep autoneg 7/7 green, rebuild via
  `fpga/scripts/build_pair_combined.sh`.

## Make it observable (recommended small RTL, parallelisable)

The single biggest accelerator: expose, on the TideLink APB (Region 8
spare slot), a read-only **FCSM state + `cr_pkt_seen_rx` + ECC
corrupt/correct counters**. Today the credit path is a black box
behind ILA-only nets; a few RO registers turn every future iteration
from a Vivado hw_manager session into a 1-second `wlink_probe` read.
This is low-risk additive RTL and should be done first in parallel with
Phase 0.

## Tooling (now version-controlled)

- `pynq_host/scripts/sw_coord_autocal_region8.sh` — SW-coordinated
  per-lane recal (SWI_TRAINING_MODE + SWI_RECAL), drop-to-data.
- `pynq_host/scripts/phase_recal_sweep.sh` — global (mp×sp) phase sweep
  harness; reports per-board locked/fault popcount. `MP_LIST`/`SP_LIST`.
- `pynq_host/scripts/mask_milestone.sh` — deploy@phase, recal-retry,
  mask Wlink `0x214` to the both-locked intersection, LL bootstrap,
  credit check. `MP=`/`SP=` env.
- `fpga/scripts/build_pair_combined.sh` — build both pair targets from
  the combined worktree (`TIDELINK_BUILD_WT` env).
- All board ssh via `SSH_AUTH_SOCK=/tmp/dam1n19-agent.sock` →
  mapstone-dev; scp is broken (remote prints `Agent pid` → corrupts the
  binary channel), use `ssh 'cat > dst' < src`.

## Success criteria

`CURRENT_CREDITS ≠ 4096` and `DOORBELL_RESP_ACC` increments after a
doorbell, on both boards — the original bring-up Definition of Done.
