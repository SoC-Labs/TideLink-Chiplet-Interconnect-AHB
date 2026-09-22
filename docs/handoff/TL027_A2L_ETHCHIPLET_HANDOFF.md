# Handoff — TL-027 a2l CDC self-latch → eth-chiplet FPGA agent (2026-08-10)

## What this is
The a2l replay-FIFO **ACK-lap-ahead false-FULL self-latch** fix, made durable and ready for you
(the eth-chiplet FPGA owner) to build + **hardware-validate** on the eth-chiplet pair — the only
vehicle that actually delivers cross-die data (the standalone bare-link pair is still all-zeros,
blocked on a separate root cause).

## Status of the fix (be precise on the disposition)
- **RTL fix:** DONE + committed. `WlinkGenericFCReplayV2_{1,3,5}.v` (AW/W/B write-path nodes) carry
  the 3-part fix (ACK-window guard + continuous `w_inc` + gated latch). Committed at `9210dc5`.
- **The load-bearing re-point:** the flists were pointing `_1/_3/_5` at the **unfixed `deps/`** copies,
  so the fix was a **silent no-op**. Now re-pointed deps → `src/rtl/local_overrides` on BOTH
  `flists/tidelink_fpga_v2.flist` and `flists/tidelink_top_full_asic_v2.flist`.
  **Committed as `1037a63`** on `integ/tidelink-consolidated-2026-08-07` (tidelink-consolidated).
  Portable patch: `docs/handoff/0001-fix-TL-027-wire-a2l-_1-_3-_5-replay-nodes-to-fixed-l.patch`.
- **Sim:** proven non-vacuous — pristine deps FAIL (`a2l_full=1`/`app_ready=0`) → override PASS
  (`a2l_full=0`/`app_ready=1`) on all 3 nodes; gated (`sim_gate_a2l_replay_cdc_{1,3,5}` PASS);
  batch `make sim_gate` green with the re-point (`asic_v2_elab` PASS, no regression).
- **Silicon:** DEV-REPORTED clean for sustained traffic (T3 128/128 writes + T10 128/128 reads
  byte-exact, no wedge) — **NOT independently HW-validated by us.** ← this handoff is to close that.

## Cross-repo state (why this needed untangling)
- Your eth-chiplet tidelink checkout (`nanosoc-ethernet-chiplet/tidelink`) is at `28409f5` and its
  flist **already shows `local_overrides` for `_1`** — i.e. the re-point exists there **uncommitted**
  (the dev's local work), and the recorded submodule pin does not capture it → it would be **lost on a
  clean checkout / in CI**. `28409f5` already has the override files (`9210dc5` is an ancestor).
- So the fix is functionally present in your working build, but not durable. `1037a63` is the
  canonical, committed version of exactly that re-point.

## Your steps (durable + build + HW-validate)

### 1. Make it durable (commit hygiene)
- In your `nanosoc-ethernet-chiplet/tidelink` submodule, commit the re-point so it is not lost.
  Either: `git am ../<path>/0001-fix-TL-027-*.patch` (apply the canonical patch), **or** cherry-pick
  `1037a63` if your remotes are linked, **or** commit your existing local re-point with the same message.
- Confirm your build flist (the one your FPGA build actually consumes) points `_1/_3/_5` at
  `local_overrides` — grep it; do not assume the tidelink flist propagates if your build wraps its own.
- **Bump the eth-chiplet parent's recorded tidelink pin** to that commit so a clean checkout keeps the fix.

### 2. Rebuild the eth-chiplet pair bitstreams
- Targets: `kr260-eth-chiplet` + `kr260-eth-chiplet-flip`. `make -C fpga TARGET=<t> all`.
- Structural check: confirm the packaged/elaborated design pulls
  `src/rtl/local_overrides/WlinkGenericFCReplayV2_{1,3,5}.v` (grep the run dir), not `deps/`.

### 3. HARDWARE VALIDATE (the point of the handoff) — supervised, on the kr260 eth-chiplet pair
Rig: kr260-01 = 10.22.24.159 (die_a), kr260-02 = 10.22.24.153 (die_b). Creds ubuntu/<board-password>.
POR = `ssh mapstone-dev '~/bin/kpor kr260-01|02 --wait'`. **Lease first (standalone), never chain acquire
with board ops.** eth-chiplet deploy REQUIRES `KR260_AFI_NO_CANARY=1` (canaries hang die_a otherwise);
deploy AFTER uptime≥115s (bootpy reloads base.bit ~85s); never TL-APB-poke a die on base.bit.
- Bring up: `kr260_eth_bringup_pair.sh` (retry until both dies deliver — delivery is itself eye-lottery
  gated on this rig; you need a wedge-free window).
- **a2l self-latch validation (the A/B):** sustained cross-die write soak WELL BEYOND ~6 words:
  - FIXED build → must **sustain byte-exact, no ~6-word wedge** (reproduce the dev's 128/128).
  - (Optional strong proof) a build with `_1/_3/_5` reverted to `deps/` → must **wedge at ~6 words**
    = the on-silicon non-vacuity. (`03_ahb_sub_e2e.sh`, `05_ahb_tx_storm.sh`, `13_long_soak.sh`.)
- **Residual R1 (separate, expected):** run the error-inject sweep (`kr260_eth_ecc_hwverify.sh`).
  die_a is expected to still wedge on the FIRST AW error-inject (silicon-only, not the self-latch).
  Capture the **die_b AW-FCSM state** during the wedge — that ILA data is what TL-035 Part-B needs.

## Caveats to carry forward
- **ASIC/tapeout:** the `tidelink_top_full_asic_v2.flist` re-point is inert until the **tapeout owner
  regenerates** the derived flist the tapeout consumes. FPGA picks it up directly.
- **R1** is a distinct failure mode (error-inject wedge), NOT the self-latch — don't let it block the
  self-latch sign-off; characterize it and hand its ILA to TL-035.
- **TL-035** (state-7 NACK watchdog dead after first CRC) is registered in `docs/BUG_REGISTRY.yaml`:
  Part-A diff ready, Part-B (§6 state-7-exit) must NOT ship without the die_b AW-FCSM ILA from step 3.

## Sign-off criterion for "a2l self-latch HW-validated"
Sustained cross-die write/read on the eth-chiplet FIXED build is **byte-exact with no ~6-word wedge**
(and, ideally, the deps-reverted build wedges at ~6 words). R1 characterized + TL-035 ILA captured.
