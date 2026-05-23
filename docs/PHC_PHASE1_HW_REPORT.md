# PHC Phase-1 HW Characterization Report — bridge1

**Date:** 2026-05-23
**Operator:** dam1n19 (agent run)
**Rig:** bridge1 = pynq_z2_02 (master, 192.168.4.101) + pynq_z2_03 (slave, 192.168.6.101)
**Bitstream:** TideLink build #7 (pynq-z2-pair-all + pynq-z2-pair-flip-all), PHC IP wired into production targets
- `tidelink.bin`       md5 `65ad6caf35c31d7e3225a98f009cd32b`
- `tidelink-flip.bin`  md5 `e4f4e48f749070c3cbe8cd19b0b35f8c`
**Repo:** `main` @ `034376f8ef76d3e8a7deeacd6afbb0db81ad4c1f` (mapstone-dev synced, was `8bd7cb1` on `feat/fpga-flow` — pulled clean, no stash needed)
**Lease:** bridge1 token `E9ESO6sw12IiWaIvPyKLAw` (granted 2026-05-23T09:47:54Z, TTL 3600 s)

---

## Executive summary

**Phase-1 verdict: BLOCKED — precondition failure at B1 pre-flight.**

The PHC IP is *present and APB-reachable* on both boards (read of `PHC_BASE+STATUS/CTRL = 0x00000000` succeeds — quiescent, not enabled), but `bringup_ptp_sync.sh` aborts at its mandatory `check_link_up` gate because the TideLink data plane is no longer at 16/16 lanes locked. The build was last verified 16/16 at ~08:08 today; by 10:48 BST the lock had degraded to 14/16 (master 7/8, slave 7/8). Per the operator brief ("If any script fails or PHC isn't ticking, capture the failure mode in the report and stop — don't try to fix in this run") B2–B4 are intentionally **not executed**; they all hard-depend on a converged pair (each tests `link 16/16 + cal_done` and exits 3 on failure) and several additionally require `SERVO_STATUS.locked==1` which B1 establishes.

**No metrics (freq-offset ppm / offset RMS / soak stddev) were obtained — handing off to bring-up agent for lock-stability remediation before PHC characterization can proceed.**

---

## Per-step evidence

### B1 — `bringup_ptp_sync.sh` (initial PHC sync)

| Field | Value |
| --- | --- |
| Timestamp | 2026-05-23 10:48:39 BST |
| Invocation | `ssh mapstone-dev "cd ~/SoCLabs/tidelink && bash pynq_host/scripts/bringup_ptp_sync.sh"` |
| Default env | `MASTER_IP=192.168.4.101 SLAVE_IP=192.168.6.101 DURATION=60 SAMPLE_PERIOD=0.25` |
| Exit code | **3** (link-not-up pre-flight gate, `check_link_up` in `_ptp_common.sh`) |
| Log | `mapstone-dev:/tmp/phc_b1_sync.log` |

**Script output (verbatim trailer):**
```
==============================================================
 TideLink PTP HW sync — initial convergence  Sat May 23 10:48:39 BST 2026
  master=192.168.4.101  slave=192.168.6.101
  PHC_BASE=0x44050000  APB_BASE=0x44030000  PMOD_TRIG_BASE=0x44042000
  duration=60s sample_period=0.25s
==============================================================
  link: master lk=0xf5 cd=1  slave lk=0xef cd=1
ERROR: link is not 16/16 + cal_done both sides — run bringup_pair_converge.sh first
```

**Diagnostic snapshot taken immediately after (read-only via `_ptp_common.sh` helpers, no AHB_TX writes):**

| Board | SWI_LANE_STATUS | locked byte | PHC_BASE+STATUS | PHC_BASE+CTRL |
| --- | --- | --- | --- | --- |
| master 192.168.4.101 | `0x00a500f7` | `0xF7` (7/8 lanes) | `0x00000000` | `0x00000000` |
| slave  192.168.6.101 | `0x002300fe` | `0xFE` (7/8 lanes) | `0x00000000` | `0x00000000` |

`cal_done=1` on both sides (per the sync script's pre-flight read).

**Verdict: FAIL (precondition)** — *not* a PHC failure. The PHC sub-block reads back cleanly on APB at the expected offsets on both boards; nothing on the PHC path was exercised because the link-up gate fired first. Failure mode is consistent with the known build-#7 post-deploy lock drift discussed in `project_tidelink_fpga_bringup` / `project_tidelink_consolidated_bringup_branch` — convergence proven repeatable via `bringup_pair_converge.sh` but not self-sustaining over ~3 h without re-arming.

### B2 — `bringup_ptp_track_freq.sh`

| Field | Value |
| --- | --- |
| Status | **NOT RUN — blocked by B1** |
| Reason | Script explicitly requires `bringup_ptp_sync.sh` to have completed and `SERVO_STATUS.locked==1`; would exit 3/4 immediately. Per brief, no recovery attempted. |
| Metric (freq-offset ppm) | n/a |
| Stability metric | n/a |

**Verdict: BLOCKED**

### B3 — `bringup_ptp_track_offset.sh`

| Field | Value |
| --- | --- |
| Status | **NOT RUN — blocked by B1** |
| Reason | Same as B2 (script gates on `check_link_up` and `SERVO_STATUS.locked`). |
| Metric (offset RMS ns) | n/a |

**Verdict: BLOCKED**

### B4 — `bringup_ptp_soak.sh`

| Field | Value |
| --- | --- |
| Status | **NOT RUN — blocked by B1** |
| Reason | Same. Script header confirms hard pre-flight on link 16/16 + slave servo lock; duration cap via `SOAK_HOURS` env var (default 4 h; would have been overridden to ≈0.25 h for this Phase-1 budget). |
| Metric (mean / 99-%ile offset) | n/a |

**Verdict: BLOCKED**

---

## Final sign-off status

**Phase-1 HW characterization: NOT SIGNED OFF.**

| Step | Verdict |
| --- | --- |
| B1 sync         | **FAIL (precondition: link 14/16, not 16/16)** |
| B2 freq-track   | BLOCKED |
| B3 offset-track | BLOCKED |
| B4 soak         | BLOCKED |

Positive findings (carry-forward for retry):
- Build #7 bitstream md5s match the brief on both targets — no restage needed.
- PHC APB region is mapped and reads cleanly at `0x4405_0000` on both boards (sub-block instantiated correctly in the production pair targets — this was the new-in-#7 risk).
- `_ptp_common.sh` SSH / `/dev/mem` path is operational against both PYNQ-Z2s through mapstone-dev (no SSH/transport issues observed).
- mapstone-dev tidelink repo is now on `main@034376f` (was `feat/fpga-flow@8bd7cb1`) — no future pull skew.

## Anomalies / next-step items

1. **Lock drift between deploy and characterization window.** Build #7 was 16/16 at 08:08; at 10:48 it is 14/16 with no intervening writes. This matches the partially-understood post-deploy stability issue tracked in the bring-up notes — needs the bring-up agent. Suggested next action: `bringup_pair_converge.sh` (parallel recal-cycle loop, does not rebuild) before re-attempting Phase-1.
2. **Per-side asymmetry.** Master lane byte `0xF7` (bit 3 down) vs slave `0xFE` (bit 0 down) — two different lanes dropped, supports the "random per-lane drift" rather than a single-lane systemic failure hypothesis. Worth correlating with calibrator phase logs on the next bring-up cycle.
3. **PHC quiescent state confirmed safe.** `PHC_STATUS=0x0, PHC_CTRL=0x0` on both — no spurious enable, no stale set bits. Re-run can start from a clean PHC state with no reset required.
4. **B4 duration knob.** `SOAK_HOURS` (default 4 h) is the right env var for the planned 15-min cap (`SOAK_HOURS=0.25` — script uses integer arithmetic, will need `SAMPLE_INTERVAL` adjustment or a fractional-hour patch; not applied here, document at re-run time).
5. **No RTL / bitstream changes** were made — strictly per brief.

## Lease

bridge1 lease `E9ESO6sw12IiWaIvPyKLAw` will be released immediately following this report write to free the rig for the bring-up retry.

---

## Build #8 attempt (2026-05-23, post-dbg_hub-waiver attempt)

**Bridge1 lease:** granted (token hH3zjMwR--Tb2-rMKAI_Aw), build #8 bitstreams
(byte-equivalent to build #7 because the dbg_hub waiver did not match — see
`fpga/targets/pynq-z2-pair-*-all/pynq_z2_tidelink_timing.xdc` lines ~310 +
the `Vivado 12-4739 No valid object(s)` warnings in build #8's impl runme.log).

**Convergence run (`bringup_pair_converge.sh STABLE=3`):**
`RESULT: CONVERGED — full 16/16 bidirectional link at iteration 1`.

**Immediate follow-up `bringup_ptp_sync.sh`:**

```
link: master lk=0xf5 cd=1  slave lk=0x7e cd=1
ERROR: link is not 16/16 + cal_done both sides — run bringup_pair_converge.sh first
```

Re-chained `bringup_pair_converge.sh` immediately by another
`bringup_ptp_sync.sh` (single SSH session, no return-trip delay): same
result, `lk=0xf5/0xef` — the link drops from `0xff/0xff` to `~12/16`
within a fraction of a second of the converge script exiting.

### Reading

The link converges to 16/16 transiently but does **not** hold it past the
moment `bringup_pair_converge.sh` declares success. The
`STABLE=3` flag passed in the second attempt should have required 3
consecutive 16/16 reads — verify in the script's loop whether `STABLE` is
honoured for the success path or only for ramp-up.

Two candidate root causes:

1. **Convergence script success-exit is single-read.** A sub-second decay
   would not be observed by the script's last read but would be by the
   next consumer. Cheapest fix: add an explicit `for i in 1..N; do
   read_link; require 16/16; done` post-script hold-loop.
2. **PHC integration regression.** Build #7/#8 are the first with the
   PHC IP wired into the production -all targets. Possible scenarios:
   PHC clock domain (`phc_clk`) interaction with pad_clk_rx, OR PHC IRQ
   line generating an APB read storm that disturbs the calibrator.
   Pre-PHC bitstream (the v1.0-rc1 milestone fold-loop closeout) was
   `mean 16.00, std 0` across 20 deploys (per
   `pynq_host/scripts/bringup_reliability.sh` baseline).

### Decision

Phase-1 PHC characterization **deferred** until the link-decay-after-
converge regression is closed. The PHC IP itself is verified present
and APB-readable on both boards from the first run (`PHC_STATUS=0x0`,
`PHC_CTRL=0x0` at `0x4405_0000`). This is the V1 ASIC sign-off
dependency to track; opening a separate bring-up loop for it is the
right move rather than blocking Block 5 (CI closure) on a multi-hour
HW-debug pass.

### Suggested next-step debug agent brief

1. Run `bringup_reliability.sh N_DEPLOYS=5` on build #8 to confirm the
   regression is reproducible across power-on-equivalent redeploys.
2. Add a `--hold-N` flag to `bringup_pair_converge.sh` that polls
   `lk == 0xff && cd == 1` on both sides every 0.5 s for N seconds
   after the success-exit, and fails if any check drops.
3. Bisect: take the parent commit of `5cbbc0f` (the first PHC -all
   mirror) and re-run reliability — confirms whether PHC integration
   itself or something else introduced the decay.
4. If PHC integration is the cause, candidate fixes: (a) clock-group
   declaration to add `phc_clk` to the existing async group, (b) gate
   PHC IRQ during link initial-lock window, (c) move PHC reset
   release to after `link_active` instead of after `poresetn`.
