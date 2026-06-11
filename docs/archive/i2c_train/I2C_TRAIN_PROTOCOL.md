# I²C-Coordinated Training-Mode Protocol — Specification

**Status:** Design-only. Not integrated. See report-back at end of this directory's README pending integration.
**Branch (intended target):** `feat/fpga-flow`
**Layer:** Layer 2 of the TideLink bring-up alignment fix (see [`docs/TIDELINK_SPECIFICATION.md §9.10`](../../docs/TIDELINK_SPECIFICATION.md) for the as-built integration; the §2.3 gap from the historical plan is captured in §9.10.1 sub-step ordering. Also [`~/.claude/plans/tidelink-bit-slip-i2c-coordination.md`](../../../.claude/plans/tidelink-bit-slip-i2c-coordination.md) §4 — this document refines those).
**Author:** Claude Code working under dam1n19's design brief.

This document is the contract between:

- The **autonomous calibration FSM** (separate agent's deliverable, gates LL TX/RX enable on `swi_calibration_done`).
- The **APB register block extensions** (user's deliverable — adds `SWI_TRAINING_MODE`, `SWI_LANE_LOCKED`, `SWI_LANE_FAULT`, `SWI_BIT_SLIP_LANE_*`, `SWI_CALIBRATION_DONE` at concrete offsets — see §3 below for the offsets this protocol requires).
- The **I²C-coordinated entry/exit FSM** in `tidelink_autoneg` (this document's primary subject — the `ST_TRAIN_*` states sketched in `tidelink_autoneg_train_states.sv`).

## 1. Why I²C coordination is required

Per [`BRINGUP_REPORT.md`](../../BRINGUP_REPORT.md) §9.8, asserting `swi_training_mode = 1` before `role_lock` blocks LL_RX clock-domain spin-up; assert it too late and the FCSM has already given up on RX. The bring-up sequencing requirement is:

1. Strap, `apb_debug_unlock`, `swi_phase_offset` (existing).
2. `role_lock = 1` (gates Wlink POR release).
3. `swreset + lltx` toggle (starts cr_pkt generation; LL_RX clock recovers from the cr_pkt stream).
4. **Hold off FCSM credit advance** while both sides assert `swi_training_mode = 1`.
5. Autonomous cal FSM sweeps `swi_bit_slip[lane]` per-lane.
6. Both sides see `swi_calibration_done = 1` and `swi_lane_locked = 0xFF`.
7. Drop `swi_training_mode = 0`.
8. Re-toggle `swreset` to re-init FCSM; cr_pkt exchange now works; FCSM → state 4.

Steps 4 and 7 must happen **on both peers within a bounded skew**. The autonomous cal FSM (`docs/TIDELINK_SPECIFICATION.md §9.10.1` sub-step 5) handles the per-side timing internally, but it does *not* synchronise entry/exit across the link. The high-speed link itself is not aligned at this point — it cannot be used to coordinate alignment (chicken-and-egg). I²C, the existing sideband, is the natural carrier.

The autoneg FSM at `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` already provides the I²C transaction primitives (`ST_NEGO_MASK_RD_ADDR`, `ST_NEGO_MASK_RD_DATA`, `ST_NEGO_MASK_RES_TX`). The new `ST_TRAIN_*` states reuse the same AXI-Lite sub-state-machine pattern.

## 2. Bring-up sequence — state by state

This section is the canonical reference. Where a step says "I²C", that means the **master** drives the bus; the slave responds passively via its I²C slave core. Where a step says "local APB", that means a same-die write from the autoneg FSM through the chiplet controller's APB bridge to the Wlink register block.

### 2.1 Pre-conditions

- Both peers are powered, strap pins are wired, `apb_debug_unlock_i` has been asserted on both peers.
- The existing autoneg FSM has run through `ST_IDLE → ST_NEGO_INIT → ST_NEGO_WAIT → ST_NEGO_CLAIM → ST_NEGO_POLL → ST_NEGO_MASK_RD_ADDR → ST_NEGO_MASK_RD_DATA → ST_NEGO_MASK_RES_TX → ST_NEGO_DONE` and resolved `nego_won = 1` on the **master** (the side with the lower-priority value or the side that won the SDA race). The slave side is in `ST_NEGO_DONE` with `nego_lost = 1`.
- `mask_hs_auto_en = 1` was set in `NEGO_CFG`, so the master's `mask_hs_local_match_r` and the slave's `mask_hs_peer_match` (latched from the master's I²C write to the slave's `link_lane_mask_hs_result @ 0x21C`) are both asserted.
- `role_lock_reg` is auto-set by `nego_force_lock` (the `nego_set_role_lock` pulse from autoneg fires on entry to `ST_NEGO_DONE`).
- Wlink POR is released; `swi_lltx_enable` and `swi_llrx_enable` default to 1. The LL TX is generating cr_pkts; the LL RX is waiting on cr_pkts from peer.

At this point on a misaligned link (the FPGA pair condition this protocol exists to fix), the FCSM is stuck at `state = 1` (SEND_CREDITS1). The protocol fires from here.

### 2.2 Trigger condition for entering the training sequence

The new training-mode block runs **only when the autoneg FSM just left `ST_NEGO_DONE` after `mask_hs_local_match = 1`**, and a configurable enable (`train_auto_en` from `NEGO_CFG[7]`) is set. If `train_auto_en = 0`, the FSM transitions directly from the existing flow to terminal-DONE — preserving the legacy bring-up path for the case where Layer 1's autonomous calibration FSM is sufficient and I²C coordination is not needed (e.g. cocotb simulation backdoors).

This means **the existing `ST_NEGO_DONE` state is no longer terminal** when `train_auto_en = 1`. Implementation requirement (passed to integrator):

- Either extend the existing `ST_NEGO_DONE` to gate on `train_auto_en` and branch to `ST_TRAIN_ENTER`, or
- Introduce a new intermediate state `ST_NEGO_DONE_PRE` that branches to `ST_TRAIN_ENTER` (preferred — keeps `ST_NEGO_DONE` semantics unchanged and lets observers continue to use it as the "autoneg complete" signal).

The reference RTL sketch (`tidelink_autoneg_train_states.sv`) uses the second approach.

### 2.3 State-by-state walk

Each row is a state in the extended FSM. The "Who drives" column distinguishes master-side action (M) from slave-side action (S). The slave's autoneg FSM stays in `ST_NEGO_DONE` (or `ST_NEGO_DONE_PRE` if the pre-state approach is used); only the master walks the `ST_TRAIN_*` states.

| State | Who drives | Action |
|---|---|---|
| `ST_TRAIN_ENTER` | M | I²C write 5 bytes (2 addr + 1 data + 2 pad) to peer's `SWI_TRAINING_MODE @ tidelink_base + 0x098` setting bit[0] = 1. Then local APB write to own `SWI_TRAINING_MODE` bit[0] = 1. |
| `ST_TRAIN_RUN`   | both | Both autonomous cal FSMs (Layer 1) sweep `swi_bit_slip[lane]` per-lane locally. Master holds for `T_TRAIN_FSM = 4096 apb_clk cycles` (~41 µs @ 100 MHz; covers worst-case 256 link-clk cycles × 8 lanes + slack). |
| `ST_TRAIN_POLL_PEER` | M | I²C read 4 bytes from peer's `SWI_LANE_LOCKED @ tidelink_base + 0x0A0`. Local APB read of own `SWI_LANE_LOCKED`. AND the two bytes; if result `== 0xFF`, advance to `ST_TRAIN_EXIT`. If timeout `T_POLL_TIMEOUT = 16 polls` elapses without success, advance to `ST_TRAIN_FAIL`. |
| `ST_TRAIN_EXIT` | M | I²C write peer's `SWI_TRAINING_MODE` bit[0] = 0. Local APB write own `SWI_TRAINING_MODE` bit[0] = 0. Issue local `swi_swreset` pulse via a back-channel (see §2.4) to re-init FCSM. Advance to `ST_TRAIN_DONE`. |
| `ST_TRAIN_DONE` | M | Terminal-OK. Sets sticky `train_ok = 1`. FSM stays here until POR. |
| `ST_TRAIN_FAIL` | M | I²C read peer's `SWI_LANE_FAULT @ tidelink_base + 0x0A4` (4 bytes). Local APB read own `SWI_LANE_FAULT`. Latch both into FSM-visible status registers (see §3). Assert `train_fail = 1` (sticky) and an interrupt to firmware (`train_fail_irq`). Terminal-FAIL. |

The slave's autoneg FSM observes its own `SWI_TRAINING_MODE` register being written by the I²C bridge and uses that signal to gate its own LL TX (the same gate as the master uses locally). The slave's calibration FSM runs on the wire pattern from the master.

### 2.4 The post-exit swreset back-channel

After exit, the master needs the FCSM on both sides to reset and re-initialise so cr_pkts can flow with the now-aligned RX. Two paths:

1. **Local**: master pulses its own `Wlink.EnableReset.swreset @ wlink_base + 0x08` (this is the existing register, see `Wlink.scala:314`).
2. **Peer**: master writes the peer's `Wlink.EnableReset.swreset @ wlink_base + 0x08` over I²C.

Both writes are part of `ST_TRAIN_EXIT`. The peer-write is 5 bytes (2 addr + 3 data with bit[3] of byte 0 = swreset bit; the byte indexing follows the existing AXI-Lite-to-APB bridge convention). The local write is one APB transaction.

The swreset is a level-write-then-clear pattern: write 1 to the swreset bit, hold for `T_SWRESET_HOLD = 128 apb_clk cycles`, write 0. The reference RTL sketches both bytes-out sequences.

### 2.5 Re-train trigger (post-bring-up link drop)

If the link drops after initial bring-up (e.g. EMI event, cable disturbance), the autonomous cal FSM may signal `swi_lane_locked → 0` while the link is "up" per FCSM state. In this case:

- A new top-level signal `train_retrain_req` is asserted (either from the cal FSM detecting persistent unlock, or from a SW write to a new `NEGO_CFG.train_retrain` field).
- The autoneg FSM transitions from `ST_TRAIN_DONE → ST_TRAIN_ENTER` and walks the sequence again.
- `train_ok_r` is cleared; `train_fail_r` is cleared on entry to `ST_TRAIN_ENTER` (so a previous failure does not stick across a retrain).

Re-train preserves `role_lock` and `nego_won`. The autoneg FSM does *not* re-walk `ST_NEGO_INIT` etc. — only the training sub-flow re-runs.

### 2.6 SW-driven manual override

To support debug, the FSM gates each state advance on a configuration bit `NEGO_CFG.train_sw_step`. When `train_sw_step = 1`, the FSM advances one state per write to `NEGO_TRAIN_STEP` (a new W1S register, see §3). This is for bench debug — production firmware leaves `train_sw_step = 0`.

## 3. Register additions

All offsets are relative to the **TideLink top-level APB base** unless noted otherwise. They sit in the existing chiplet controller register region (`tidelink_regs.rdl`), adjacent to the existing autoneg/i2c registers at `0x080..0x08C`.

### 3.1 New TideLink-level registers (chiplet controller block)

| Offset | Name | Width | Type | Reset | Purpose |
|---|---|---|---|---|---|
| `0x090` | `NEGO_TRAIN_CFG` | 32 | RW | `0x0000_0000` | Training-mode config. bit[0] = `train_auto_en` (overrides `NEGO_CFG[7]`; allowed to live there too). bit[1] = `train_sw_step`. bit[2] = `train_retrain` (W1P, self-clearing). bits[7:4] = `train_poll_timeout` (4-bit, max 15 polls). bits[15:8] = `train_fsm_wait_hi` (high 8 bits of `T_TRAIN_FSM`; low 4 bits hard-fixed to 0 → granularity 4096 cycles). |
| `0x094` | `NEGO_TRAIN_STATUS` | 32 | RO | `0x0000_0000` | bit[0] = `train_ok`. bit[1] = `train_fail`. bit[2] = `train_in_progress`. bits[7:4] = `train_state` (mirror of `ST_TRAIN_*` encoding). bits[15:8] = `train_peer_lane_locked` (last value read from peer's `SWI_LANE_LOCKED`). bits[23:16] = `train_peer_lane_fault` (last value read from peer's `SWI_LANE_FAULT`). bits[31:24] = `train_local_lane_fault` (snapshot taken on entry to `ST_TRAIN_FAIL`). |
| `0x098` | `SWI_TRAINING_MODE` | 32 | RW | `0x0000_0000` | bit[0] = `swi_training_mode` (drives the Wlink GPIO PHY's training pattern + checker enable). Writable from both local APB and I²C slave path. |
| `0x09C` | `NEGO_TRAIN_STEP` | 32 | RW | `0x0000_0000` | bit[0] = step pulse, W1P, self-clearing. Only effective when `NEGO_TRAIN_CFG.train_sw_step = 1`. |
| `0x0A0` | `SWI_LANE_LOCKED` | 32 | RO | `0x0000_0000` | bits[7:0] = `swi_lane_locked` from Wlink GPIO PHY checker (per-lane lock status). bits[31:8] = reserved (`0`). Readable from both local APB and I²C slave path. |
| `0x0A4` | `SWI_LANE_FAULT` | 32 | RO | `0x0000_0000` | bits[7:0] = `swi_lane_fault` from Wlink GPIO PHY (sticky after cal abandons). bit[8] = `swi_calibration_done`. |
| `0x0A8` | `SWI_BIT_SLIP_LO` | 32 | RW | `0x0000_0000` | bits[23:0] = `swi_bit_slip[7:0]` (8 × 3-bit, packed: lane K at bits `[3K+2 : 3K]`). Reads back the latched-by-cal-FSM value; writes override. bits[31:24] = reserved. |

### 3.2 Why these offsets

- `0x090..0x0A8` is the next available 32-byte block above the existing `i2c_prescale @ 0x08C`. The register-map document at [`docs/REGISTER_MAP.md`](../../docs/REGISTER_MAP.md) shows `0x090..0x0FF` unused.
- Keeping `SWI_*` registers at `0x098, 0x0A0, 0x0A4, 0x0A8` clusters them at addresses that are I²C-friendly: the slave's address pointer auto-increments by 1 byte per cycle and the read-phase pattern from the autoneg FSM is `MASK_RD_ADDR_MSB = 0x00, MASK_RD_ADDR_LSB = 0x?0` followed by 4 byte reads (see existing pattern in `tidelink_autoneg.sv:746`). Aligned to 4-byte boundaries so a single AXIL transaction maps cleanly.
- `NEGO_TRAIN_CFG` and `NEGO_TRAIN_STATUS` are paired at `0x090, 0x094`, matching the existing `NEGO_CFG / NEGO_PRIORITY / NEGO_TIMEOUT / NEGO_STATUS` style (those live elsewhere in the autoneg block — search for their offsets in `tidelink_regs.rdl` after the integrator adds them; this protocol does not depend on their precise offsets).

### 3.3 Wlink-internal register additions (PHY block, separate from TideLink-level)

These belong to the **Wlink GPIO PHY register block** (where `swi_phase_offset` lives) and are added by the autonomous-cal-FSM agent's work. This protocol document references them by name and assumes they appear at offsets the integrator chooses. The TideLink-level wrappers at `0x098, 0x0A0, 0x0A4, 0x0A8` above are **mirrors** that the chiplet controller exposes for I²C-from-peer access. The implementation question is whether the registers are dual-ported (writable from both APB paths) or whether the wrappers fan out — both work; reference RTL assumes dual-ported with priority-resolved writes (local APB wins on conflict). The "from-peer-I²C" path is the AXI-Lite-to-APB bridge that already exists for the slave's I²C slave core — see `tidelink_top.sv:308-352`.

### 3.4 Bit-field encoding for `train_state`

| Encoding | State | Comment |
|---|---|---|
| `4'd0` | `ST_TRAIN_IDLE` | Pre-trigger or post-DONE if not entered |
| `4'd1` | `ST_TRAIN_ENTER` | Master writing peer's `SWI_TRAINING_MODE := 1` |
| `4'd2` | `ST_TRAIN_RUN` | Waiting `T_TRAIN_FSM` cycles |
| `4'd3` | `ST_TRAIN_POLL_PEER` | Reading peer's `SWI_LANE_LOCKED` |
| `4'd4` | `ST_TRAIN_EXIT` | Writing peer's `SWI_TRAINING_MODE := 0` + swreset |
| `4'd5` | `ST_TRAIN_DONE` | Terminal-OK |
| `4'd6` | `ST_TRAIN_FAIL` | Terminal-FAIL; lane-fault registers loaded |

Re-uses bit-encoding space free above `ST_NEGO_MASK_RD_DATA = 4'd10`, so the existing 4-bit `state_r` width is sufficient. The integrator may renumber to keep `ST_NEGO_*` and `ST_TRAIN_*` non-adjacent if waveform readability matters.

## 4. Failure modes and recovery

### 4.1 Peer non-response (I²C ACK timeout)

**Symptom:** Master's `ST_TRAIN_ENTER` issues the I²C write, polls master's I²C controller status, sees `I2C_STS_BUSY = 0` after some cycles, but `I2C_STS_MISS_ACK = 1`.

**Cause:** Peer board is not running the bitstream, jumper wire is loose, peer's I²C slave core is misconfigured (wrong slave address), peer's APB clock has not started.

**Recovery:**
- Master transitions to `ST_TRAIN_FAIL`.
- `train_local_lane_fault` is loaded with `swi_lane_fault` from local Wlink (may be `0x00` if the FSM never asserted training).
- `train_peer_lane_fault` is loaded with `0xFF` (a poison sentinel: "could not read peer at all"). The reference RTL uses a separate status bit `train_peer_nack_r` to disambiguate "peer NACK'd" from "peer lane fault `0xFF`".
- `train_fail_irq` fires.

**SW recovery path:** firmware reads `NEGO_TRAIN_STATUS`, sees `train_peer_nack`, and may:
- Re-attempt by writing `NEGO_TRAIN_CFG.train_retrain = 1`.
- Bypass training entirely by clearing `NEGO_TRAIN_CFG.train_auto_en = 0` and proceeding with the legacy bypass-mode bring-up (still useful if e.g. only one direction is misaligned).

### 4.2 Peer lane fault (peer's `swi_lane_fault != 0` after training)

**Symptom:** `ST_TRAIN_POLL_PEER` reads peer's `SWI_LANE_LOCKED` and finds bits cleared after `T_POLL_TIMEOUT` polls.

**Recovery:**
- Master transitions to `ST_TRAIN_FAIL`.
- Master reads peer's `SWI_LANE_FAULT` via one more I²C read transaction.
- `train_peer_lane_fault` is loaded with that byte.
- `train_local_lane_fault` is loaded with master's own `swi_lane_fault`.
- `train_fail_irq` fires.

**SW recovery path:** firmware now has concrete diagnostics — e.g. `train_peer_lane_fault = 0x10` means lane 4 on the peer's RX could not lock, indicating an issue with master's TX lane 4 (the cross-link runs master.TX → peer.RX). The firmware may attempt a recovery via lane masking: write to the existing `LaneMask @ wlink_base + 0x14` to exclude the bad lane, then re-trigger the full autoneg + training flow.

### 4.3 Local lane fault

**Symptom:** Master's own `SWI_LANE_FAULT` is non-zero before the `T_POLL_TIMEOUT` runs out.

**Behaviour:** Master proceeds with `ST_TRAIN_POLL_PEER` until timeout; on `ST_TRAIN_FAIL` entry both local and peer fault bits are captured for diagnostics. The autonomous cal FSM has already exhausted retries for the failing lane.

### 4.4 Both sides successful but FCSM still won't advance

**Symptom:** Master reads `SWI_LANE_LOCKED = 0xFF` on both sides; transitions to `ST_TRAIN_EXIT`; pulses swreset; but FCSM stays at `state = 1` (SEND_CREDITS1).

**Cause:** Handshake bug **downstream** of alignment — could be a corrupted cr_pkt that flows but doesn't reach the FCSM's expected sequence, a `swi_lltx_enable / swi_llrx_enable` gating issue (e.g. the autonomous cal FSM did not release its enable-hold), or a Wlink-internal credit accounting bug independent of this protocol.

**Detection:** The training FSM does **not** observe FCSM state itself — it only confirms `swi_lane_locked` and exits. This is by design: separating alignment from credit handshake means a downstream bug does not loop the training FSM. The detection of the "FCSM-still-stuck" condition is done by:

- The deploy script (`pynq_host/scripts/deploy_pair.sh`) — reads `wlink_link_status @ wlink_base + 0x34` and FCSM state after the training FSM signals `train_ok = 1`. If FCSM is not at state 4, the script reports a downstream failure and dumps the FCSM + cr_pkt counters.
- A future status counter the FSM could add (`train_done_but_fcsm_stuck_count`) — not in v1 of this protocol; defer to firmware-side detection.

**Recovery:** This is outside the training FSM's purview. The firmware can issue a fresh `swreset` cycle (clearing `swi_calibration_done` and re-asserting it via retrain), or invoke a more aggressive recovery (full `nego_force_lock` reset cycle). Document this clearly in the firmware-side runbook (see [`pynq_host/scripts/`](../../pynq_host/scripts/)).

## 5. Timing budget

**Reference values used here:**

- `apb_clk = 100 MHz` (TideLink top-level)
- `i2c_prescale_reg = 250` → I²C SCL = `100 MHz / (4 × 250) = 100 kHz` (standard mode)
- 1 I²C byte = 9 SCL cycles (8 data + 1 ACK) = 90 µs @ 100 kHz
- 1 I²C 5-byte write = `START + addr + 5 data + STOP` ≈ 7 bytes overhead = 7 × 90 µs = 630 µs ≈ **0.63 ms**
- 1 I²C 4-byte read = `START + addr-W + 2 byte (addr ptr) + repeated START + addr-R + 4 byte + STOP` ≈ 10 bytes = 10 × 90 µs = 900 µs ≈ **0.9 ms**
- `T_TRAIN_FSM = 4096 apb_clk = 41 µs` (negligible)
- `T_SWRESET_HOLD = 128 apb_clk = 1.3 µs` (negligible)

| Step | Transactions | Time | Cumulative |
|---|---|---|---|
| Pre-conditions (autoneg complete) | — | — | (existing budget) |
| `ST_TRAIN_ENTER`: I²C write peer + local APB | 1 × write-5B + 1 × local | 0.63 + 0.001 ms | 0.63 ms |
| `ST_TRAIN_RUN`: wait | — | 0.041 ms | 0.67 ms |
| `ST_TRAIN_POLL_PEER`: I²C read peer + local APB | 1 × read-4B + 1 × local | 0.9 + 0.001 ms | 1.57 ms |
| `ST_TRAIN_EXIT`: I²C write peer + local APB + swreset hold | 1 × write-5B + 1 × local + 1 × write-5B (peer swreset) + 1 × local pulse | 0.63 + 0.001 + 0.63 + 0.0013 ms | 2.83 ms |
| **Total end-to-end (happy path, single poll)** | | | **~2.83 ms** |
| Plus `T_POLL_TIMEOUT × 0.9 ms` worst-case extra polls | up to 16 polls | up to 14 ms | up to 17 ms |

**Conclusion:** end-to-end bring-up of the I²C-coordinated path is **~3 ms typical, ~17 ms worst-case**. Both are well below the firmware-side timeout in `deploy_pair.sh` (currently 5 s for `role_lock` assertion).

**Optimisation knob:** raising `i2c_prescale_reg` to 25 (→ 1 MHz I²C, fast-mode-plus) reduces the typical time to **~0.3 ms**. Wlink's I²C IP supports this; the slave's hold-time spec is the limiting factor. The Pynq-Z2 wiring has no termination — at 1 MHz the eye is still well open over ≤10 cm but ringing rises. Recommendation: **start at 100 kHz** (the existing default `nego` configuration), bump to 400 kHz (`i2c_prescale = 62`) once hardware confirms reliable operation.

## 6. SW-debug fallback

For bench debug before the autoneg FSM extension is integrated, or as a recovery path when the FSM is in `ST_TRAIN_FAIL` and SW wants to retry differently, the same registers can be driven entirely from PYNQ-host Python over a working APB path.

### 6.1 Mechanism

The PYNQ host already has an APB-write path to both peers via SSH-to-PYNQ + mmap of the chiplet controller AXI-MM region (see `pynq_host/scripts/deploy_pair.sh` and `pynq_host/scripts/wlink_probe.sh`). The SW-driven sequence is:

```python
# Master side (deploy from srv03335)
master_apb.write(SWI_TRAINING_MODE, 1)
slave_ssh.apb_write(SWI_TRAINING_MODE, 1)    # over SSH, master srv → slave PYNQ → slave APB

time.sleep(0.001)                             # 1 ms covers the autonomous per-lane FSM

# Poll for lock on both sides
for retry in range(16):
    lk_m = master_apb.read(SWI_LANE_LOCKED) & 0xff
    lk_s = slave_ssh.apb_read(SWI_LANE_LOCKED) & 0xff
    if lk_m == 0xff and lk_s == 0xff:
        break
    time.sleep(0.001)
else:
    # Both have not locked — dump faults and abort
    f_m = master_apb.read(SWI_LANE_FAULT)
    f_s = slave_ssh.apb_read(SWI_LANE_FAULT)
    print(f"Lane fault: master={f_m:#x}, slave={f_s:#x}")
    sys.exit(1)

# Exit training on both
master_apb.write(SWI_TRAINING_MODE, 0)
slave_ssh.apb_write(SWI_TRAINING_MODE, 0)

# Re-toggle swreset to re-init FCSM
master_apb.write(WLINK_ENABLE_RESET, 0x09)   # swreset=1
slave_ssh.apb_write(WLINK_ENABLE_RESET, 0x09)
time.sleep(0.001)
master_apb.write(WLINK_ENABLE_RESET, 0x07)   # swreset=0
slave_ssh.apb_write(WLINK_ENABLE_RESET, 0x07)
```

### 6.2 Honest timing characterisation

The above code is **not** ~1 ms total. Each `slave_ssh.apb_*` call is a full SSH round-trip through the `srv03335 → mapstone-dev.ecs → z2_0X` ProxyJump chain:

- SSH session reuse via `ControlMaster` cuts new-connection cost (typically ~200 ms cold) down to ~10-30 ms per call on a warm channel.
- Linux scheduler jitter on the PYNQ side adds ~1-5 ms per call.
- Each `mmap`-and-read or `mmap`-and-write is one syscall (~50 µs) once the SSH transport is open.

**Practical wall-clock per `slave_ssh.apb_*` call: ~30-50 ms typical, ~200 ms p99.**

For a single-poll happy-path sequence: ~7 SSH calls × 50 ms = **~350 ms**, vs the hardware FSM path's ~3 ms. For the 16-retry pessimistic case: ~40 SSH calls × 50 ms = **~2 seconds**.

**When to use SW fallback:**

- The hardware FSM is not yet integrated (this is the current state, hence this design document existing as a spec rather than a deployed feature).
- Debugging a hardware FSM hang — SW can step through individual states by reading `NEGO_TRAIN_STATUS.train_state` and manually advancing.
- Recovering from a `ST_TRAIN_FAIL` terminal state when SW wants to try a different lane mask or i2c prescale value before retrying.

**When not to:** production bring-up, automated regression. The 200 ms typical / 2 s pessimistic latency is well outside the cocotb/UVM test budget and adds variance that masks real issues.

### 6.3 Slave side: direct connection vs I²C

The SW fallback can drive the slave **either** via SSH-to-slave-PYNQ (current `deploy_pair.sh` approach — uses the slave board's own ARM CPU + APB), **or** via I²C-from-master (using master's I²C master core to write the slave's APB via its I²C slave + AXIL-to-APB bridge). The latter is exactly what the hardware FSM does, but driven manually from Python. The Python access is `master_apb.write(I2C_MASTER_CMD, ...)` repeated for each byte — cumbersome, ~10x slower than direct-SSH for SW use, but valuable for sandbox-bringing-up the I²C path itself.

For initial bring-up, **prefer SSH-to-slave**. Once the I²C jumper wiring is verified (with a logic analyser or by exercising the existing lane-mask autoneg I²C path), switch to using the on-card I²C path for cross-checks.

## 7. Pin assignment guidance (Pynq-Z2 RPi GPIO)

The TideLink data link uses RPi indices 0..17 on the J13 header. The current `pynq-z2-pair-all` XDC explicitly moves all 18 lanes to indices 6..23 to avoid the 6 Pmod-A-shared balls. That leaves indices 0..5 (the Pmod-A-shared balls W18, W19, Y18, Y19, U18, U19) and indices 24..27 (W14, V17, V18, U10) currently unused.

**Recommendation: use BCM2 / BCM3 = Vivado idx 0 / idx 1 = FPGA pins W18 / W19 = J13 pins 3 / 5.**

| Signal | Vivado idx | FPGA pin | BCM GPIO | J13 phys pin | Standard RPi alt-function |
|---|:---:|:---:|:---:|:---:|---|
| `i2c_scl` | 0 | W18 | 2 | **3** | Pi I²C1 SCL |
| `i2c_sda` | 1 | W19 | 3 | **5** | Pi I²C1 SDA |

### 7.1 Rationale

1. **External pull-ups already present.** The Pynq-Z2 reference manual (and verified against `boards/Pynq-Z2/base/vivado/constraints/base.xdc`) confirms that J13 pins 3 and 5 have on-board 1.8 kΩ pull-ups to 3V3, intended for Pi I²C1. These are already in the right value range for 100 kHz I²C with the Pynq-Z2 trace lengths (the 1.8 kΩ is on the low side of typical 2.2-10 kΩ, fine for short ribbons).
2. **No competing function on the FPGA.** The pair-all XDC explicitly excluded these pins from the data link — they are otherwise unused in the current build.
3. **Pi-compatible if a debug Pi is ever inserted between boards.** Standard alternative function mapping means an external SBC could observe the bus with no special wiring.
4. **Both pins are P-side LVCMOS33.** No clock-capable / single-region constraints to worry about for I²C's slow edges.

### 7.2 Why not idx 24..27 (W14, V17, V18, U10)

These are perfectly serviceable inputs but lack external pull-ups. Would require either internal pull-ups (Vivado `PULLUP TRUE` — works but weak ≈10-50 kΩ, marginal for noisy ribbon environments) or external 4.7 kΩ pull-up resistors on a separate solder tab. Avoidable extra hardware.

### 7.3 Why not extend the 40-pin ribbon

Splicing 2 more wires into the existing ribbon at indices 0/1 means changing the ribbon cable mapping, which was deliberately fixed at "indices 6..23 only" in the §1.3 of `ribbon_wiring.md` to avoid the Pmod-A-shared pin issue. The wiring chart (which is the bench artefact pinned for every cable-soldering session) would need re-issuing. See `PHYSICAL_WIRING.md` for the recommended approach.

### 7.4 XDC additions

For each pair target (`pynq-z2-pair-all/pynq_z2_tidelink.xdc` and `pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc`):

```tcl
# I²C SCL — Vivado RPi idx 0, FPGA pin W18, J13 pin 3 (BCM GPIO 2 = Pi I²C1 SCL).
# On-board 1.8 kΩ pull-up to 3V3 (Pynq-Z2 PCB). PULLUP TRUE retained as belt-and-braces.
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33 PULLUP TRUE SLEW SLOW DRIVE 8} [get_ports i2c_scl]

# I²C SDA — Vivado RPi idx 1, FPGA pin W19, J13 pin 5 (BCM GPIO 3 = Pi I²C1 SDA).
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33 PULLUP TRUE SLEW SLOW DRIVE 8} [get_ports i2c_sda]
```

Note `SLEW SLOW` (not `SLEW FAST` used by the data link) — I²C edges are intentionally slow to limit bus reflections on the unimpedance-matched ribbon. `DRIVE 8` mA is sufficient for open-drain with the on-board pull-ups.

### 7.5 Timing constraint

I²C is asynchronous to the link clock domain. The existing autoneg FSM samples `i2c_sda_i` and `i2c_scl_i` in the `apb_clk` domain (see `tidelink_autoneg.sv:249-254`). Add to the timing XDC:

```tcl
# I²C sideband — asynchronous, no timing path
set_false_path -from [get_ports {i2c_scl i2c_sda}] -to [all_registers]
set_false_path -from [all_registers] -to [get_ports {i2c_scl i2c_sda}]
```

### 7.6 Mirroring on `pynq-z2-pair-flip-all`

The flip target's XDC must use the **same** physical pins for `i2c_scl` / `i2c_sda` (W18 / W19). I²C is symmetric — both boards drive open-drain — so unlike the data-link's TX/RX cross, the I²C wires are not crossed. Same pin assignment, same pull-up, same XDC line.

## 8. Open items deferred to the integrator

These need a concrete decision **before** the design is merged into trunk; they were marked "open" in the original plan and are not finalised here:

1. **Exact placement of `train_auto_en` and `train_sw_step` bits.** Either in `NEGO_CFG` (alongside `nego_en, mask_hs_auto_en`) or in a new `NEGO_TRAIN_CFG @ 0x090`. This document proposes `NEGO_TRAIN_CFG`; the integrator may consolidate into `NEGO_CFG` with renumbering. Either is acceptable.
2. **Whether `swi_lane_locked` is dual-ported with a local-APB-wins priority, or single-ported via a mux selected by `role_is_master_o`.** Dual-port is cleaner; mux saves a write port. Mux is acceptable as long as the read path is dual-ported.
3. **Timeout for `T_POLL_TIMEOUT`.** This document proposes 16 polls × 0.9 ms = ~15 ms. The integrator may shorten to 8 (`~7 ms`) or extend to 32 (`~30 ms`) depending on observed lock-time variance on the FPGA pair.
4. **Whether the swreset-via-I²C path uses `cmd_write_multiple` like the existing mask-result write, or a sequence of `cmd_write` transactions.** `cmd_write_multiple` is shorter; the integrator should reuse the existing pattern from `tidelink_autoneg.sv:633-679`.
5. **Whether `train_retrain_req` is debounced.** If a noisy environment causes intermittent unlocks, the FSM could thrash. Recommend a 64-cycle debounce on the trigger; defer concrete value to integrator.

## 9. Verification surface

This protocol is exercised by:

- **UVM tests** specified in [`UVM_TEST_PLAN.md`](UVM_TEST_PLAN.md). Five scenarios covering happy path, lane fault, peer non-response, async retrain, and SW override.
- **Cocotb tests** — existing `cocotb/wlink_pair/` sandbox could be extended with an I²C model (a wired-OR connection + pull-ups + a simple slave model that mirrors APB writes from I²C). Lower priority than UVM because the protocol fundamentally exercises two-die coordination, which UVM models more cleanly.
- **FPGA bring-up** — the `pynq-z2-pair-all` + `pynq-z2-pair-flip-all` pair, once the I²C jumpers are physically wired per [`PHYSICAL_WIRING.md`](PHYSICAL_WIRING.md). Final acceptance is `deploy_pair.sh` running with `mask_hs_bypass_i = 0` and observing FCSM = state 4 on both peers.

## 10. References

- [`tidelink_autoneg.sv`](../../deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv) — existing FSM, lines 132-186 + 633-735 are the I²C transaction primitives this design extends.
- [`Wlink.scala`](../../deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/Wlink.scala) lines 162-168 + 329-333 — existing I²C-mediated peer-write pattern for lane mask.
- [`tidelink_regs.rdl`](../../src/rdl/tidelink_regs.rdl) lines 240-320 — existing register block this design extends.
- [`tidelink_top.sv`](../../src/rtl/tidelink_top.sv) lines 288-352 — I²C ports + AXI-slave port.
- [`docs/TIDELINK_SPECIFICATION.md §9.10`](../../docs/TIDELINK_SPECIFICATION.md) — as-built PHY-Align integration; the historical §2.3 gap is captured under sub-step ordering (§9.10.1).
- [`BRINGUP_REPORT.md`](../../BRINGUP_REPORT.md) §9.8 — sequencing requirement motivating the design.
- [`~/.claude/plans/tidelink-bit-slip-i2c-coordination.md`](../../../.claude/plans/tidelink-bit-slip-i2c-coordination.md) §4 — original plan; this document refines.
