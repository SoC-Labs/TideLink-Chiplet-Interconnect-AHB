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

---

## Build #8 re-run, post-provenance-fix (2026-05-23 11:56-11:58)

Following `docs/LINK_DECAY_BISECT.md`'s finding (link decay was a stale
bin in `/tmp/tidelink_deploy/`), regenerated build-#8 manifests with
`pynq_host/scripts/make_bitstream_manifest.sh` and restaged. Verified
that the deployed bin sha256 now matches build #8 (`a25534…` /
`5951958…`, both 2c9a1a5/main HEAD).

### Re-measured outcomes

| Step | Result | Evidence |
|---|---|---|
| **B0** Converge (manifest provenance enforced) | **PASS** | `RESULT: CONVERGED — full 16/16 bidirectional link at iteration 1` at 11:56:54 |
| **Link stability** | **PASS — no decay** | Per docs/LINK_DECAY_BISECT.md hold-poll, link held `0xff/0xff` across the entire 60 s `bringup_ptp_sync.sh` convergence loop. The earlier "decay" observation was the rc2 bin mis-deployment. |
| **B1** PHC sync | **FAIL — but NOT a link issue** | locked_streak=0 / required 10. Master TX'ing sync (HW_SYNC_STATUS=0x3), slave NOT receiving (HW_SYNC_STATUS=0x0), servo not running (SERVO_STATUS=0x0). |

### Real Phase-1 gap

```
HW_SYNC_STATUS (master): 0x00000003   (= sync_active | sync_initiator)
HW_SYNC_STATUS (slave):  0x00000000   (= idle — NOT receiving sync)
SERVO_STATUS   (slave):  0x00000000   (= no measurements feeding servo)
```

The link (data plane) is 16/16. The PHC IP on both boards is wired and
APB-readable. The master correctly enters HW_SYNC initiator mode.
**The slave never sees the master's sync packets** — its
`HW_SYNC_STATUS` stays at 0x0 for the full 60 s window.

Candidate root causes, ranked by likelihood:
1. **PTP packet routing not configured.** The HW_SYNC packets ride the
   FIFO/FC adapter path; the slave's FIFO RX may not be accepting them
   (FIFO disabled, packet type filter, addr-trans not set up).
2. **Master-side sync address wrong.** `bringup_ptp_sync.sh` sets
   PTP_SYNC_DEST_ADDR but the slave's PTP_SYNC_RX_ADDR may not match.
3. **PHC `hw_capture` not seeing the sync packet's RX timestamp** even
   when the packet arrives — `tidelink_phc_cdc.sv`'s hw-capture inputs
   not connected to the right RX-side hook.
4. **HW_SYNC interval set too fast** (128 Hz default) for the link's
   actual round-trip time — slave drops every packet because the
   previous one hasn't finished.

B2 (freq track) / B3 (offset track) / B4 (soak) were gated on B1 PASS
and so did not run. They will all hit the same servo-not-locked gate
until B1 closes.

### Decision — Phase-1 status update

PHC Phase-1 is **architecturally validated** (PHC IP present + APB-
readable + master initiator wiring correct + link stable) but **does
NOT functionally close** because the master→slave HW_SYNC packet path
does not deliver. This is a real software / register-program /
configuration gap, NOT a HW or RTL regression.

Recommended next-step debug agent: trace the HW_SYNC packet path end-
to-end through master TX → FC adapter TX → link → slave FC adapter
RX → slave HW_SYNC RX, with an instrumented packet count at each
hop. The right tool for this is `pynq_host/scripts/hwtest/` cat-5
(servo) which exercises the same path with logging.

### Build #8 final HW-validation summary

|  | Result |
|---|---|
| Build #8 farm-build (pair-all + pair-flip-all -all) | PASS (43m50s) |
| Bridge1 lane lock (16/16) | PASS iter 1 |
| Link stability (no decay) | PASS (per LINK_DECAY_BISECT.md) |
| PHC IP wired + APB-readable | PASS (PHC_STATUS = 0x0 reads cleanly) |
| PHC sync convergence | FAIL — Phase-1 gap (master TX OK / slave RX 0) |

---

## Build #9 attempt (2026-05-23 ~16:00, post b61c84a PHC fix)

**Build verdict:** PASS. Both targets built clean in 39m24s on
commit `4e693b5` (= `b61c84a` PHC fix + post-fix doc/CI commits).

  - `tidelink.bin` md5 `1feb92375b3ea3d131267aaefc4e60d6`
  - `tidelink-flip.bin` md5 `27d4b5271d0706908763117312f5eb1c`
  - sha256 in `~/td_milestone_stage/*.manifest.json`
    (`a7f52bc4…` / `ee125ee6e5…`)
  - bitstreams + manifests staged on `mapstone-dev:~/td_milestone_stage/`

**HW validation: BLOCKED** — master board (z2_02 / 192.168.4.101) is
hardware-unresponsive:
  - 100% ping packet loss from mapstone-dev
  - SSH connect timeout
  - `fpgahub board reset pynq_z2_02_pl --list` shows ZERO reset methods
    configured (no remote power-cycle path)
  - Slave (z2_03 / 192.168.6.101) responds normally

The bridge1 pair lease was granted (`Q5bfNuTY1UwDX1eN_Gdh2g`,
2026-05-23 16:02 → 17:02 UTC) and released cleanly. The chain ran
B0-B4 in ~12 s total because every step ssh-failed at `check_link_up`
on the unreachable master.

### Next-step recipe

When the master board is physically power-cycled (lab attendant / user):

```sh
fpgahub pair lease acquire bridge1 --ttl 3600   # verify GRANTED
ssh mapstone-dev "ping -c 2 -W 2 192.168.4.101"   # confirm reachable
ssh mapstone-dev "cd ~/SoCLabs/tidelink && \
    bash pynq_host/scripts/bringup_pair_converge.sh STABLE=3 MAX_RETRIES=15 && \
    bash pynq_host/scripts/bringup_ptp_sync.sh"
```

Acceptance criterion for closing Phase-1: `RESULT: PASS` from B1
(`locked_streak >= 10` within the 60 s window) — at that point B2-B4
unblock and produce freq / offset / soak metrics.

### What this proves about build #9

The Vivado build itself, the bitstream provenance flow (manifest sha
matches and was verified at deploy time per the 7e6aac6 hard-abort
guard), and the staging pipeline (rsync-free cat-over-ssh transfer to
mapstone-dev) all work end-to-end. The only outstanding gate is the
physical board state, and that is independent of any commit on `main`.

---

## Build #9 retry (2026-05-23 18:08, z2_02 recovered)

After the master board (z2_02) was physically power-cycled, ran the
full B0-B4 chain against build #9's bitstream (md5 `1feb92375b3e…` /
`27d4b5271d07…`, commit `4e693b5` = `b61c84a` PHC fix + post-fix docs).

### Results

| Step | Verdict | Evidence |
|---|---|---|
| **B0** Converge | **PASS** | 16/16 iter 1 at 18:08:30 |
| **B1** PHC sync | **FAIL (closer)** | `locked_streak=0/10` over 60 s window. **Master HW_SYNC_STATUS = 0x4815 (was 0x0003)** — bits 4, 11, 14 now also set, meaning the master FSM advances past the `tx_router_idle` gate (Agent F's `force_en` fix is working as intended). **Slave HW_SYNC_STATUS = 0x0 (unchanged)**. Offset stays at ~+97.9 s baseline, fluctuates ±2 s RTT, never converges. |
| **B2** freq-track | **BLOCKED** | precondition fail (slave SERVO_STATUS=0x0) |
| **B3** offset-track | **BLOCKED** | same |
| **B4** soak | **BLOCKED** | same |

### Diagnosis update — what `b61c84a` fixed, what's still open

**Before `b61c84a` (build #8):**
  - Master HW_SYNC_STATUS = 0x0003 — stuck in `TX_WAIT_IDLE`,
    `tx_router_idle` never asserts because Wlink LL inserts LP
    frames at delay_cycles=1700.
  - Slave HW_SYNC_STATUS = 0x0.
  - **Master FSM never advances → no sync packets ever generated.**

**After `b61c84a` (build #9):**
  - Master HW_SYNC_STATUS = 0x4815 — FSM is advancing through sync
    states. The `force_en | enable = 0x5` register write in
    `bringup_ptp_sync.sh` is wired through to bypass the
    `tx_router_idle` gate as the commit intended.
  - Slave HW_SYNC_STATUS = 0x0 — **slave RX path still not seeing
    the packets.** This is the next layer of the same gap.

### What still needs investigating

Master is generating + queueing sync packets but the slave's
`HW_SYNC` RX path never observes them. Candidate causes (narrowed
from the original four after this retry):

1. **(MOST LIKELY)** The PHC sync packet is going out on the wrong
   FC node, OR the slave's FC adapter doesn't have a configured RX
   filter for the PHC sync `data_id` (0xa2 per
   `docs/FC_NODE_REGISTRY.md`).
2. The slave's `tidelink_phc_cdc.sv` `hw_capture` input is not
   connected to whatever the FC adapter emits when an
   incoming packet's `data_id` matches PHC.
3. `bringup_ptp_sync.sh` step [4] sets up the master's PTP_SYNC
   path but does NOT set up the corresponding slave-side RX
   configuration (e.g. enable the PHC's hw_capture, route the
   incoming FC node to the slave PHC's RX timestamping).

Recommended next debug agent task:
  - Diff master vs slave APB register state immediately before
    `bringup_ptp_sync.sh` step [5] (the HW_SYNC start). Slave should
    have the PHC-RX path armed; if it doesn't, the script needs a
    new step. If it does, the gap is RTL (FC-adapter → PHC `hw_capture`
    wiring or the PHC's RX `data_id` filter).
  - Look at `src/rtl/tidelink_fc_adapter.sv` for the FC-RX-side
    `data_id` match logic + which output port goes to PHC. The
    `tidelink_ptp.sv` TX FSM was the master-side fix; the
    corresponding slave-side path likely needs analogous attention.

### Status

PHC Phase-1 is now **half-closed** — link is healthy, master TX is
advancing, but slave RX is not. The remaining work is the slave-side
RX-config-or-RTL-wiring gap which is independent of `b61c84a` (that
fix only addressed the master-TX `tx_router_idle` deadlock and
provably did so).

---

## Build #9 retry #2 (2026-05-23 18:21, handoff brief)

Acquired bridge1 lease (`XDYpIjMhwuVphA1ddRJnPQ`, released cleanly).
Restaged build #9 bitstreams (md5 `1feb92375b3e…` / `27d4b5271d07…`)
from `~/td_milestone_stage/` into `/tmp/tidelink_deploy/` — the stale
older bins (`65ad6caf…` / `e4f4e48f…`) that were already there would
have produced wrong-build results.

### Results
| Step | Verdict | Evidence |
|---|---|---|
| **B0** Converge | **PASS** iter 1 (16/16 both sides) | `die_a/die_b lk=0xff cd=1` |
| **B1** PHC sync | **FAIL** | `locked_streak=0`, slave RX captures 0 packets after 30 s |
| B2–B4 | BLOCKED | precondition fail |

### Diagnostic data captured

| Probe | Master | Slave |
|---|---|---|
| `HW_SYNC_STATUS` after 30 s | `0x00002be1` (seq≈2752) | `0x00000000` |
| `HW_SYNC_STATUS` 3 s sample | `0x00019dc5` (seq≈26225) | n/a |
| Sustained seq rate | ~870/s (much higher than 128 Hz interval) | — |
| `PTP_CTRL` (immediately after step [4]) | `0x1` (enabled) | `0x1` (enabled, readback confirmed) |
| `PTP_RX_PAYLOAD` (post-test) | — | `0x0` (no PTP RX packet ever latched) |
| `LinkInterrupts` (cleared then re-read after 3 s) | `0x00020202` — `ecc_corrected` bit[8] set (slave→master RX is alive) | `0x00000000` — no RX-side activity at all |
| Wlink `EnableReset` (cfg `0x44030208`) | `0x00027f07` (enable + lltx_en + llrx_en + spmax=0x7f + preq=0x2) | same `0x00027f07` |

### Root-cause analysis

Master is generating + presenting short packets (data_id `0x50`) to
its TX router at high rate. Master's RX path is logging
`ecc_corrected` events from slave-originated traffic — so the
slave→master link direction works, the lower lanes/ECC machinery is
sound, and the slave's TX router is alive.

The **slave never logs a single PTP RX packet**: slave's
`LinkInterrupts.crc_errors / ecc_corrupted / ecc_corrected` all stay
at zero AND `PTP_RX_PAYLOAD` stays at zero AND the servo's WAIT_SYNC
state never advances. The asymmetry is unambiguous: master→slave
short-packet traffic is being dropped *somewhere on the slave* before
it reaches the slave's `ShortPacketToWlink` adapter's RX FIFO.

Candidate failure points (ranked by likelihood after this session):

1. **Slave's short-packet RX path is silently dropping the packet
    at the link layer.** `WlinkRxLinkLayer.is_short_pkt` requires
    `corrected_ph(7,0) <= swi_short_packet_max && != 0 && ~corrupted`.
    `swi_short_packet_max` reads `0x7f` on both sides; `0x50 < 0x7f`
    passes. ECC check is per-packet — the ECC byte for SYNC short
    packets is computed by `lltx` from the data_id and 16-bit payload.
    Possible RTL gap: slave's `WlinkRxLinkLayer` saw the packet but
    `is_short_pkt_prev` debounce or the active-lanes counter
    misclassified it. **No observability today** — no APB register
    surfaces `WlinkRxLinkLayer` packet counters or per-data-id RX
    counts, which is exactly what we need.
2. **Slave's `ShortPacketToWlink.rx_pkt_valid` is firing but the
    async FIFO read pointer never advances** because `rx_accept` (=
    `ptp_sp_rx_valid & ptp_enable_r`) is held low. We *did* set
    `PTP_CTRL=1` and read it back as 1 in the test window — but post-
    test the slave wedged and we lost the live-test confirmation.
3. **Slave board wedge under APB-burst load** — the slave (z2_03)
    became fully unresponsive (`No route to host`, no SSH, no ping)
    midway through our diagnostic probes. `fpgahub board reset
    pynq_z2_03_pl --list` shows **zero configured reset methods** —
    same pattern that blocked the first build #9 attempt on z2_02.
    This board state alone explains the post-test "PTP_CTRL reads 0"
    readings; do NOT take those as evidence of an RTL latch bug
    (initial post-step-[4] readback DID show 1).

### What the next session needs

1. **Restore slave board (z2_03) to ping-able state** — physical
    power-cycle. There is no remote recovery path; the previous
    z2_02 recovery required the same.
2. **Instrument the short-packet RX path** before re-running. Useful
    observability that does NOT exist today:
    - Wlink RX short-packet count (per data_id, or just total) at an
      APB-readable register.
    - `ShortPacketToWlink.rx_fifo.wfull / rempty` flags exposed.
    - A "last-received data_id" sticky register.
    Without these, every retry is blind. The minimal RTL add is a
    16-bit RX counter in `ShortPacketToWlink` (rx_link_clk domain) +
    a 2-FF synchronizer to an APB-readable slot in TideLink Region 3.
    That's a single-file Scala change + a 1-reg add in
    `tidelink_apb_regs.sv` + a wire pass-through in `tidelink_top.sv`.
3. **Alternatively** — try the **smallest possible script-only
    workaround first** before any rebuild: re-issue `PTP_CTRL=1` on
    the slave *during* the convergence loop (every iteration) to
    rule out the slave's `ptp_enable_r` getting silently cleared
    between step [4] and the actual SYNC arrival window. ETA 5 min,
    no rebuild needed; if it works we've isolated to a sticky-bit
    issue and a 1-line script fix is the close-out.
4. **Provisionally** — apply Bug-#3-style `(* keep *) (* dont_touch *)`
    annotation to `ptp_enable_r`'s declaration in `tidelink_ptp.sv` —
    if synth pruned the FF the same way it pruned `mask_hs_auto_en`,
    that would explain a non-sticky CTRL write. Speculative — needs
    re-test on a recovered slave to confirm.

### Process notes for the next agent

- The `_ptp_common.sh` `apb_w` helper sends one SSH per write. The
  `bringup_ptp_sync.sh` step [4] alone fires ≥8 SSH bursts in <2 s on
  the slave; the convergence loop adds ~4 reads per 250 ms sample.
  Empirically this is enough to wedge a z2 PYNQ board under
  marginal conditions. Coalescing multiple register writes into one
  SSH session (single sudo python multiplexed mmap) would
  meaningfully reduce wedge-rate. Defer if not critical.
- Suggested debug recipe (post-power-cycle):
  ```sh
  fpgahub pair lease acquire bridge1 --ttl 3600
  ssh mapstone-dev "cp ~/td_milestone_stage/tidelink*.bin* \
                       /tmp/tidelink_deploy/"
  ssh mapstone-dev "cd ~/SoCLabs/tidelink && \
      bash pynq_host/scripts/bringup_pair_converge.sh \
           STABLE=3 MAX_RETRIES=15"
  # before bringup_ptp_sync.sh: prove slave PTP_CTRL is sticky
  ssh mapstone-dev "ssh xilinx@192.168.6.101 \
      'echo xilinx|sudo -S devmem 0x44032034 32 1; \
       echo xilinx|sudo -S devmem 0x44032034'"
  # expected: 0x00000001
  bash pynq_host/scripts/bringup_ptp_sync.sh
  ```

### Verdict — what `b61c84a` + this session collectively prove

- Master TX FSM advances and emits short packets. ✓
- Link is bidirectionally healthy at the byte/lane layer. ✓
- Master→slave short-packet delivery is **non-functional** at the
  slave end. No observability today distinguishes "link layer drops
  ECC-fail" from "RX FIFO write blocked" from "FSM disabled". RTL
  observability needs to be added before any more bisects.
- Time budget exhausted (~90 min of the 120-min cap) **before**
  applying any code fix, because slave HW recovery + observability-
  add are blocking. Releasing bridge1 lease (`XDYpIjMhwuVphA1ddRJnPQ`)
  to free the rig.

---

## Sim reproduction (2026-05-23)

The HW slave-RX gap reproduces in pure simulation, breaking the
hardware-loop dependency. A new cocotb env was added so iteration
on the slave-RX fix no longer requires a bridge1 lease.

**Env:** `cocotb/phc_pair/`
  - `tb_top.sv` — two `axi_chiplet_controller` (Wlink) instances
    cross-wired through GPIO PHY pads (same topology as
    `cocotb/wlink_pair/`), with a `tidelink_ptp` on each side wired to
    that Wlink's `ptp_in`/`ptp_out` short-packet interface.
  - `test_phc_hw_sync_pair.py` — programs master Region 2 HW_SYNC
    initiator (INTERVAL + EN|FORCE_EN = `0x5`, identical to
    `pynq_host/scripts/bringup_ptp_sync.sh` step [5]) and polls slave
    `sync_rx_done` + `PTP_CTRL[2]` (rx_valid) over ~1 ms sim time.

**Verdict:** `cocotb.test(expect_fail=True)` — reproduces the HW bug
exactly:
  - Master HW_SYNC fires cleanly: `HW_SYNC_STATUS = 0x000407d9`
    (seq_num=502 after the poll window, FSM is firing once per
    interval just like build #9 on silicon).
  - Slave never sees the packets: `sync_rx_done` pulses = 0,
    `PTP_CTRL[2]` rx_valid never latches, slave `PTP_CTRL = 0x0`.
  - Test reports `PASS` (failed-as-expected) and the regression
    summary line is:
    `test_phc_hw_sync_pair.test_phc_hw_sync_pair   PASS  …  RATIO  49320 ns/s`

**Why this is the right repro:** master's TX path is the same RTL
that runs on silicon (`tidelink_ptp` + Wlink `ptp_in`), the cross-
wiring through the Wlink GPIO PHY is the same RTL that the wlink_pair
suite already certifies (`test_link_bringup` PASS, 6/6), and the
slave's RX glue (`Wlink.ptp_out` → `tidelink_ptp.ptp_sp_rx_*`) is the
exact code path that fails on the bench. The sim therefore exonerates
every other layer (master TX, PHY transport, Wlink autoneg) and
narrows the bug to the Wlink-`ptp_out` / `tidelink_ptp.ptp_sp_rx`
boundary on the slave side.

**Run it:**
```sh
cd cocotb/phc_pair
make
# completes in ~20 s wall-clock; xfails as expected
```

**How to flip xfail → xpass once the bug is fixed:**

1. Apply the slave-RX fix (most likely a one-bit wiring repair in
   Wlink `ptp_out` decode or a missing enable in `tidelink_ptp`'s RX
   accept logic — diagnose by waveform on `cocotb/phc_pair/waves.vcd`,
   probing `u_slave.u_wlink.…ptp_out` vs `s_ptp_sp_rx_valid`).
2. Re-run `make` in `cocotb/phc_pair/` — the test will switch from
   `failed as expected` to a real `FAIL` (because `expect_fail=True`
   inverts an actual pass into a regression failure).
3. Remove `expect_fail=True` from the `@cocotb.test()` decorator in
   `test_phc_hw_sync_pair.py`. The test becomes a positive assertion
   that the slave observes at least one SYNC short packet per
   master HW_SYNC interval.
4. Add the test to the CI matrix for `cocotb/phc_pair`.

---

## Sim root-cause closure (2026-05-23, post-c8f418c)

### Diagnostic

Added `cocotb/phc_pair/test_phc_diag.py` to instrument the slave RX path
per-cycle over 50 000 slave_clk cycles. The probes walked the candidate
boundaries from the §"Build #9 retry #2" handoff:

| Probe (slave hierarchy)                              | Count   | Verdict |
|------------------------------------------------------|---------|---------|
| master `sp2wl ll_tx.sop && data_id=0x50`             |  7984   | TX OK   |
| slave  `sp2wl ll_rx.valid && sop`                    |  8183   | RX seen |
| slave  `llrx.is_short_pkt`                           |  8176   | classifier OK (Candidate 1 ruled out) |
| slave  `llrx.is_long_pkt`                            |     0   | no misclassification |
| slave  `sp2wl.dataIdMatch`                           | 49785   | data_id 0x50 matches |
| slave  `sp2wl.rx_pkt_valid` (sop&&valid&&match)      |  7968   | adapter OK |
| slave  `sp2wl.rx_fifo.winc`                          |    64   | **DROP — FIFO blocked** |
| slave  `sp2wl.rx_fifo.wfull`                         | 49481   | FIFO full almost always |
| slave  `tidelink_ptp.ptp_enable_r`                   |     0   | **gate held low** |
| master `tidelink_ptp.ptp_enable_r`                   |     1   | (control: same helper) |

The 7968→64 drop at `rx_fifo.winc` is caused by `rx_accept =
ptp_sp_rx_valid & ptp_enable_r` being held low — so the RX FIFO fills
up and ~99 % of incoming SYNC packets are dropped on the floor at the
slave adapter's FIFO write-enable.

This rules out **Candidate 1** (link-layer classifier — 8176/8183 = OK)
and **Candidate 2** (FIFO blocked downstream — it's blocked upstream
of the FIFO read side, by the write-enable gate not by the read pointer).
It is **Candidate 3 in spirit** — `ptp_enable_r` not being 1 — though the
underlying cause is *not* synth pruning. It's a cocotb scheduling race in
the test bench's register-write helper: master succeeded with a single-
edge pulse but slave silently failed with identical helper code, because
when both clocks edge at the same instant cocotb's queued value-writes
can land after the FF has already evaluated the older value.

### Fix

`cocotb/phc_pair/test_phc_hw_sync_pair.py` — `ptp_reg_write` helper
now aligns to a fresh rising edge before driving and holds the write
pulse for two rising edges (belt-and-braces). With this in place the
slave's `ptp_enable_r` reliably latches to 1 and the RX FIFO drains.

Post-fix run:
```
slave  PTP_CTRL       = 0x00000005 (rx_valid=1, enable=1)
slave  sync_rx_done pulses observed = 3
slave  PTP_CTRL[2] rx_valid latched = True
slave  sp2wl.rx_fifo.winc           = 7968  (matches rx_pkt_valid)
slave  sp2wl.rx_fifo.wfull          = 0
test_phc_hw_sync_pair.test_phc_hw_sync_pair   PASS
```

`expect_fail=True` removed; the test is now a positive end-to-end
assertion that the slave receives ≥ 1 SYNC per master HW_SYNC interval.

### HW implication (still pending board recovery)

The sim and HW fail with the *same external signature* (slave never
latches RX) but the sim root cause is a TB-helper race, not an RTL bug.
The HW path uses APB→`tidelink_apb_regs.ptp_reg_write` rather than the
backdoor `ptp_reg_*` ports, so this exact race cannot manifest on
silicon. Still, two things to verify when z2_03 returns:

1. Re-confirm slave `PTP_CTRL=0x1` via devmem *during the active SYNC
   window* (not only immediately after step [4]), to rule out a
   sticky-bit pruning issue on the APB write path itself. This is
   exactly the §"Build #9 retry #2 → What the next session needs (3)"
   workaround.
2. If (1) shows `PTP_CTRL=0x0` mid-test, then Candidate 3 (Bug-#3-class
   synth pruning of the slave-side `ptp_enable_r` FF) IS the real HW
   root cause and needs the `(* keep *) (* dont_touch *)` annotation
   on the FF declaration in `tidelink_ptp.sv`.

The sim now provides the diagnostic harness (test_phc_diag.py) to
prove the slave RX path is RTL-clean from `ll_rx` through `rx_fifo`
end-to-end — that exonerates Candidates 1 and 2 on HW as well.

---

## Build #9 retry #3 (2026-05-23 19:17, post z2_03 recovery + diagnostic)

After z2_03 recovered, ran B0 + B1 with the new PTP_CTRL discriminator
log (commit `4367a71`) — designed per the §"Sim root-cause closure"
recipe to discriminate (a) APB-write-doesn't-reach vs (b) Bug-#3
synth-pruning of slave `ptp_enable_r`.

### Verdict — both prior HW candidates RULED OUT

```
PTP_CTRL       (master): 0x00000001
PTP_CTRL       (slave):  0x00000001   ← APB write OK, ptp_enable_r IS 1
HW_SYNC_STATUS (master): 0x00004831   ← master TX FSM advancing
HW_SYNC_STATUS (slave):  0x00000000   ← slave RX path silent
SERVO_STATUS   (slave):  0x00000000
```

Slave reads `PTP_CTRL=0x1` mid-test, so:
  - **(a) APB write reaches slave**: confirmed (otherwise readback would
    show 0x0).
  - **(b) Bug-#3 synth pruning of slave `ptp_enable_r`**: ruled out
    (FF is holding the written value per readback).

The `feat/keep-ptp-enable-r` speculative fix branch (commit `344b7e8`)
is therefore NOT the right fix. Parking it indefinitely — keep around
for cross-reference but it is not the closeout candidate.

### New theory — gap is between master TX and slave's `ll_rx`

Sim (cocotb/phc_pair) showed slave's `ll_rx.valid && sop` = 8183 hits
when master fired 7984 short pkts. Sim used the same Wlink + GPIO PHY
cross-wire topology as HW. In HW, with the link at 16/16 lock and
master HW_SYNC_STATUS advancing through 0x4831 (FSM in sync transmit),
slave should see SOMETHING at `ll_rx`. But slave HW_SYNC_STATUS stays
0x0 and `PTP_RX_PAYLOAD` stays 0 (per Agent J's retry #2 observation).

Suspect candidates, ranked:
  1. **Master HW_SYNC TX path not actually pushing short pkts onto
     the link.** Master FSM advancing (0x4831 = bits 0,4,5,11,14 set)
     proves the FSM is running, but doesn't prove it's getting through
     the chiplet controller's TX arbiter onto Wlink TX → GPIO PHY. The
     `tx_router_idle` bypass landed (b61c84a) but maybe a secondary
     gate (FC-adapter priority, TX path enable, etc.) is silently
     blocking.
  2. **Slave's link-layer decode of the incoming PHC sync data_id
     differs from sim.** Sim used `data_id=0x50` (per Agent N's
     diagnostic). HW might be using a different ID, or the slave's
     decode threshold differs.
  3. **Slave RX FIFO clock-domain / reset state**: maybe FIFO has
     never come out of reset on slave side after deploy.

### Next debug steps (when a fresh session is run)

The right diagnostic is an APB-readable RX-side packet counter
(per Agent J's recommendation in §"Build #9 retry #2"). That requires
RTL plus a rebuild. Without it, every retry is blind.

For now: **Phase-1 partial closeout** — link healthy, PHC IP wired,
APB working both sides, master TX FSM advancing, but the master→slave
PHC sync packet drop is somewhere between master's TX and slave's
`ll_rx`. Three candidate fixes remain (none speculative-buildable).

### Status after this retry

- `feat/keep-ptp-enable-r` parent branch: superseded (incorrect
  candidate per the discriminator), but retained on remote as historical
  reference.
- All other branches (mark_debug, tidelink-integration, cdc-fix-wip)
  unaffected.
- Bridge1 lease (`HXBRPeDCXDjomL9R9iI8UQ`) released cleanly.

---

## Build #11 (2026-05-23 20:08, feat/phc-rx-counters)

### Build verdict

PASS both targets (35m50s) after the build #10 fix `154e298` (drop the
vestigial `dbg_int + dbg_hub` stanzas from both -all DRC XDCs — they
were probing the `mark_debug` nets that Agent M's
`feat/remove-mark-debug` disabled, so the probes had no valid endpoints
and impl errored on `Chipscope 16-213 unconnected channels`).

Bitstreams:
  - `tidelink.bin` md5 `ec48010ff90de9c6ab38cf8d7928eadd`
  - `tidelink-flip.bin` md5 `453ab6e861e7e66dffd78ec16e9da7cd`
  - manifests: `commit=154e298…`, label `build11-…`

### B0 converge: PASS (16/16 iter 1)

### B1 PHC sync: STILL FAIL — slave HW_SYNC_STATUS=0x0

```
HW_SYNC_STATUS (master): 0x000047f5      (TX FSM advancing through sync)
HW_SYNC_STATUS (slave):  0x00000000      (silent)
SERVO_STATUS   (slave):  0x00000000
PTP_CTRL       (master): 0x00000001
PTP_CTRL       (slave):  0x00000001
```

### RX_DIAG counter read — slave-side observability is BROKEN

Read Region 3 counters at the new offsets (0x44032074 / 0x44032078 /
0x4403207C):

| Side    | LL_VALID_CNT      | SHORT_PKT_CNT  | PHC_ACCEPT_CNT |
|---------|-------------------|----------------|----------------|
| master  | 19660 (0x4ccc)    | 1000 (0x3e8)   | 2 (0x2)        |
| slave   | 8388608 (0x800000)| 1000000 (0xf4240) | 0 (0x0)     |

Master's values are within 16-bit range and look plausible (master's
TX self-loopback would explain some count). **Slave's values are
nonsense:** 8388608 = 2²³ exact, 1000000 = exact decimal — both well
beyond 16-bit saturation, AND they do not clear on a write to the
clear-register address. Either:

1. The slave bitstream's Region 3 address decode points at a different
   register than the counter, OR
2. The counter saturation logic is broken on the slave-side hierarchy
   (synth optimised it differently from master), OR
3. The clear-on-write path is not wired on slave

The slave-side counter is therefore not a usable diagnostic on this
build. **`feat/phc-rx-counters` is NOT merged to main** — until the
slave-side observability also works, the branch provides no actionable
data over the existing per-cycle sim instrumentation (`cocotb/phc_pair/
test_phc_diag.py`).

### Phase-1 PHC status — autonomous loop exhausted

Three HW retry cycles + sim repro + RTL counter add + four candidate
fixes attempted (Bug-#3 ruled out, APB-write ruled out, TB-helper
race fixed in sim, RX counter add inconclusive). The closeout
genuinely needs the next-tier debug primitive — an oscilloscope on
the GPIO pad_rx_* signals or a working ChipScope on the slave's
ll_rx boundary — and ideally a focused human review of the chiplet
controller's RX FSM. Documented for the next session.

### Build #11 bridge1 lease

Acquired `0P-Gm2FHP0Bc49JCane_bw` 2026-05-23 19:44 → released cleanly
20:50.

---

## Build #13 + Proposal #3 — Agent Q's RCA disproven, Agent R's confirmed

### Build #13 — feat/phc-slave-rx-fix (`167923a`)

Agent Q's RCA proposed `(* dont_touch *) (* keep *)` on slave's
`ptp_enable_r` FF (Bug-#3-class on the replica feeding `rx_accept`).
Build PASS, deployed cleanly with verified build-#13 provenance
(bin sha256 `9c7eadcfcd89…` / `865a0f66b1f7…`).

**HW verdict: FAIL** — slave `HW_SYNC_STATUS=0x0` unchanged, `locked_streak=0/10`.
The replica-prune theory is **disproven**: the `dont_touch` would prevent
any replica from being pruned, yet slave still sees nothing. The RX path is
not gated by `ptp_enable_r` on HW the way Agent Q hypothesised.

### Proposal #3 — PTP_CTRL toggle workaround

Wrote `PTP_CTRL=0`, sleep 100ms, `PTP_CTRL=1` on both sides before
starting HW_SYNC manually. Brief post-write snapshot showed
`HW_SYNC_STATUS slave=0x1, SERVO_STATUS slave=0x1` — looked
promising, but re-running the full `bringup_ptp_sync.sh` chain
(which does its own quiesce-then-enable in steps [1] and [4]) gives
back the original FAIL with `HW_SYNC_STATUS slave=0x0`. The earlier
0x1 was the **PTP-enabled bit reflected**, not actual sync packet
reception (no offset convergence, no `ns_frac` update, no servo lock).

### Final Phase-1 closeout — autonomous loop genuinely exhausted

After 13 build cycles, 6 HW retries (B1 chain), and three diagnostic
agents (Q RCA, R sim/HW gap, N earlier), the bug is now narrowed to
the **physical/timing realm** that the autonomous loop cannot address:

  - Agent R's `cocotb/phc_pair/` extended with `USE_FPGA_MODELS=1`
    (`feat/phc-pair-fpga-models`, merged as `a9b1f21`) elaborates
    IDELAYE2 / IDELAYCTRL / BUFG unisim primitives on the slave path
    — and STILL passes the test cleanly. The §9 cells are functional
    no-ops in sim; their entire HW value is **structural** (Vivado
    P&R placement targeting), not behavioural.
  - The classifier + dataIdMatch + RX FIFO write side all exonerated
    by `cocotb/phc_pair/test_phc_diag.py` (per-cycle counter table).
  - APB write reaches slave `PTP_CTRL` (`PTP_CTRL=0x1` mid-test) and
    `ptp_enable_r` synthesises correctly with `dont_touch+keep`
    (build #13 disproved replica-prune).

The remaining HW-only failure modes per `docs/SIM_HW_GAP_ANALYSIS.md`:

  1. **(Most likely)** Vivado P&R skew on slave's master→slave fan-out
     lands past IDELAY tap range — calibrator's 16/16 threshold
     passes but ≥1 lane's eye sits at UI boundary; ECC silently
     drops every short packet. Consistent with master seeing
     `ecc_corrected` (slave→master traffic alive) + slave seeing
     ZERO RX activity.
  2. Recovered-RX-clock reset/CDC race on first master-TX edge
     (sim has perfectly synchronous t=0 clocks).
  3. `set_bus_skew` constraint margin exhaustion.

### REQUIRED next step (USER ACTION)

**Oscilloscope on slave `pad_clk_rx` + one `pad_rx[n]`** at the
Raspberry Pi header, while master is firing HW_SYNC (after running
this report's standard `bringup_pair_converge.sh` + master HW_SYNC_CTRL=0x5
sequence). This **discriminates clock-recovery failure from
data-eye-crush failure** — the two hypotheses lead to different
fixes:

  - If the scope shows clean RX clock + clean RX data eye but ECC
    fails: the bug is in slave's ECC decode or RX-bank routing —
    needs a chiplet controller logic-analyser session OR adding
    APB-readable ECC-error counters.
  - If the scope shows a closed eye (data edges aligned with clock):
    the bug is P&R skew past IDELAY range — needs an XDC
    `max_delay` tightening + rebuild, OR moving the slave-side
    capture to an `IODELAY_GROUP` with longer taps.

### What landed during this exhaustion

| Item | Status |
|---|---|
| `b61c84a` master-TX `tx_router_idle` bypass | **MERGED on main** (HW-validated by `HW_SYNC_STATUS master 0x3→0x48xx` advance) |
| `cocotb/phc_pair/test_phc_hw_sync_pair` sim repro | **MERGED on main** (commits `86e45bb` + `609482f`) — sim env that exonerates the RTL slave-RX path |
| `bringup_ptp_sync.sh` mid-test PTP_CTRL diagnostic | **MERGED on main** (commit `4367a71`) |
| `deploy_pair.sh` UNVERIFIED-DEPLOY hard-abort | **MERGED on main** (commit `7e6aac6`) — closes Bug-#32 class permanently |
| `docs/SIM_HW_GAP_ANALYSIS.md` | **MERGED on main** (commit `a9b1f21`) |
| `docs/PHC_PHASE1_RCA_PROPOSAL.md` | On `feat/phc-slave-rx-fix` (unmerged — RCA disproven) |
| `feat/phc-rx-counters` (RX_DIAG counters) | Parked — slave-side wiring broken; not merged |
| `feat/phc-slave-rx-fix` (Agent Q's `dont_touch+keep`) | Parked — disproven; not merged |
| `feat/keep-ptp-enable-r` (earlier speculative Bug-#3) | Deleted — also disproven |

PHC Phase-1 is genuinely **CONDITIONAL** until the scope diagnostic
discriminates the two HW-only hypotheses. All sim and RTL
hypotheses are exhausted. Lease released.
