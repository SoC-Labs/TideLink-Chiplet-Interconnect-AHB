# TideLink v1.0-rc4 Release — tdif-13 (L1-L7 RTL stack)

| Field | Value |
| ----- | ----- |
| Release candidate | v1.0-rc4-phc-deferred |
| RTL commit | `07af0c1` ("td-l7-nack-recovery: forgive send_nack_req during bringup credit window") |
| RTL branch | `feat/td-interface-debug-l7-nack-recovery` (in `td-bisect/td-l4-option-c` worktree) |
| Bitstream | `/tmp/tidelink_deploy/tdif-13/tidelink.bin` (mapstone-dev), `.hwh`, `.ltx`, plus `tidelink-flip.{bin,hwh,ltx}` polarity counterpart |
| HW platform | PYNQ-Z2 pair: bridge1 = z2_02 (master) + z2_03 (slave), 25 MHz GPIO PHY |
| Status | Bilateral LINK_IDLE achieved; PHY clean; PHC Phase-1 deferred |

This document describes the **tdif-13 / L7-only** RTL state as the v1 release
candidate (a.k.a. v1.0-rc4). It captures everything the L1–L7 override stack
buys on real silicon, and what is intentionally **deferred to v2** because the
remaining bug lives in the FC-credit-bootstrap layer rather than in LL/FCSM.

The follow-on work that motivated tdif-14/15/16 and the L8/L8v2/L9 series did
**not** improve the observable HW endpoint state vs tdif-13. L7 alone matches
the best HW result and is therefore the cleanest stop-line for a release.

---

## 1. What v1 (tdif-13) achieves

The release ships the following RTL override stack against upstream Wlink,
all carried as `src/rtl/local_overrides/*.v` files (Verilog mirror of the
generated Wlink RTL, picked up by the flist ahead of vendor sources).

### L1 — TX word-aligned mux latch (per-lane)
- File: `src/rtl/local_overrides/WavD2DGpioTx.v`
- Key block: lines 110–141 (`io_training_mode_q` register, `WORD_ALIGN_MUX`
  parameter, `io_training_mode_mux` and `_link_data_eff` muxes).
- Effect: training-mode → FC-data transitions only occur on word boundaries
  (`count == 4'hf` → `count == 4'h0`), eliminating the mid-word mux flip
  that previously broke slave LL_RX byte-align.

### L2 — PstateCtrl swi_delay_cycles default 1700 → 0
- File: `src/rtl/local_overrides/Wlink.v`
- Key block: lines 2244–2246 (synth always) and 2401–2471 (sim init).
  POR/apb_reset value forced to `16'h0` (vs upstream `16'h6a4`).
- Effect: PSTATE FSM never enters the spurious power-state-change branch
  while the link is bringing up, so swi_training_mode is not yanked low
  during the LL byte-align window.

### L3 = 0 — T3A_CONTINUOUS reverted to baseline
- File: `src/rtl/local_overrides/WavD2DGpioRx.v`, line 69
  (`parameter T3A_CONTINUOUS = 1'b0`).
- Effect: keeps the upstream re-arm behaviour. The tdif-11 experiment
  (T3A_CONTINUOUS=1, see commit `1353f83`) caused a HW lane-lock regression
  and was reverted as part of the tdif-12 RTL line that L7 stacks on top of.

### L4 v3 — `first_short_pkt_seen` framer gate
- File: `src/rtl/local_overrides/WlinkRxLinkLayer.v`
- Key block: line 162 (sticky `first_short_pkt_seen` debug-marked register),
  line 166 (`long_pkt_gate = first_short_pkt_seen`).
- Effect: blocks LL_RX long-packet entry until a short-packet boundary has
  been observed at least once, so a stray long-packet phase cannot wedge
  the framer mid-bringup.

### L5 whitelist — data_id whitelist on the framer gate
- File: `src/rtl/local_overrides/WlinkRxLinkLayer.v`
- Key block: lines 1056–1079, `whitelisted_short_data_id` matches
  `{cr_id=0x44, crack_id=0x45, ack_id=0x46, nack_id=0x47}`.
- Effect: `first_short_pkt_seen` only latches when the corrected packet
  header matches a real bringup short-packet data_id, so noise from the
  training-mode tail cannot pre-bootstrap the framer.

### Option (c) — CDC-synced training_mode → llrx_reset gate
- File: `src/rtl/local_overrides/Wlink.v`
- Key block: lines 1827–1875 (header comment) and surrounding 2-flop CDC
  sync of `swi_training_mode_in` into `phy_link_rx_rx_link_clk`, OR'd into
  `llrx_reset`.
- Effect: producer-side gate holds llrx_reset HIGH for the entire window
  that the master is emitting training-mode filler. The framer therefore
  cannot latch state==1 until the link is in FC-data mode, eliminating the
  asymmetric byte-align loss that L4 was trying to recover from on the
  consumer side.

### L6 — ≥32 CR emissions in FCSM state == 1
- File: `src/rtl/local_overrides/WlinkGenericFCSM_6.v`
- Key block: line 374 (`socl_l6_cr_emit_gate_ok = (count >= SOCL_L6_MIN_CR_EMITS)`),
  lines 905–913 (counter update), line 945 (used in `_GEN_34` exit gate
  out of state 1).
- Effect: producer holds the FCSM in state 1 (`CR_EMIT`) long enough that
  the peer sees ≥32 CR shorts before the local FSM can advance, fixing the
  asymmetric CR-loss class on the slave RX.

### L7 — forgive `send_nack_req` during the bringup credit window
- File: `src/rtl/local_overrides/WlinkGenericFCSM_6.v`
- Key block: lines 373–393 (forgive-gate definitions), lines 1070–1078
  (`send_nack_req` AND-cleared by `~socl_l7_bringup_forgive` in every
  state), lines 1086–1088 (`socl_l7_reached_link_data` sticky latch on
  observing state == 5).
- Effect: once both peers have seen CR + CRACK (sticky), but the FCSM has
  not yet reached LINK_DATA, a transient `isNotExpPacket` from the
  bringup recal cannot latch `send_nack_req` and wedge the FSM at
  SEND_NACK (state 7). The gate disarms permanently the first time the
  FCSM ever observes state 5, so steady-state error handling reverts to
  upstream behaviour. A genuine CRC error during bringup still drives
  NACK (`crcCorruptSeen` is NOT masked).

---

## 2. HW-verified outcomes on bridge1 (z2_02 master + z2_03 slave)

Measured against tdif-13 bitstream `/tmp/tidelink_deploy/tdif-13/tidelink.bin`
deployed via the standard PYNQ host loader + `bringup_pair_converge.sh`:

| Metric | Master (z2_02) | Slave (z2_03) |
| ------ | -------------- | ------------- |
| Lane lock | **8/8** | **8/8** |
| `cr_pkt_seen` (sticky) | 1 | 1 |
| `crack_pkt_seen` (sticky) | 1 | 1 |
| FCSM state | **4 (LINK_IDLE)** | **4 (LINK_IDLE)** |
| ECC error counter | 0 | 0 |
| CRC error counter | 0 | 0 |
| `send_nack_req` latched | 0 | 0 |
| `pair_credit_counter` | 0 | 0 |

**Bilateral LINK_IDLE with CR/CRACK symmetric and zero PHY errors** is the
correct exit state of the LL/FCSM bringup sequence. This is the first
TideLink build that achieves bilateral state 4 on HW with all PHY counters
clean.

### Pre-tdif-13 baseline for comparison (tdif-05)

| Metric | Master (z2_02) | Slave (z2_03) |
| ------ | -------------- | ------------- |
| Lane lock | 8/8 | 8/8 |
| `cr_pkt_seen` (sticky) | 1 | **0** |
| `crack_pkt_seen` (sticky) | 1 | **0** |
| FCSM state | 1 (CR_EMIT) | **7 (SEND_NACK)** |

The asymmetric CR-loss class that wedged tdif-05 is gone in tdif-13.

---

## 3. Known limitations (the bug v1 does NOT fix)

1. **`pair_credit_counter == 0` post-bringup**: although the LL/FCSM layer
   has reached bilateral LINK_IDLE, the FC-credit handshake at the
   `tidelink_fc_adapter.sv` boundary never produces a non-zero credit
   counter. The credit-gate consequently holds TX gated and no FC data
   packets ever cross the link in steady state.
2. **No user traffic crosses post-bringup**: doorbells, AHB writes, and
   any other FC-mediated transactions stay buffered behind the credit gate.
3. **The remaining bug is in `tidelink_fc_adapter.sv` or the upstream
   credit-handshake logic, NOT in the LL/FCSM layer.** All L1–L7 fixes are
   correct and well-scoped to LL/FCSM; chasing the credit issue inside
   FCSM (which is what L8/L8v2/L9 tried) only widens the forgive gate
   without addressing the actual credit bootstrap.
4. **0x44010000 is NOT a valid peer-aperture test**: peer-side AHB writes
   should target `0x40000000` (the `ahb_sub` region) on the remote chiplet.
   `0x44010000` belongs to the local APB controller window and does not
   exercise the FC data path.

---

## 4. Why v1 is still valuable

- **First HW build with correct LL/FCSM endpoint state.** Every prior
  attempt either had asymmetric CR loss (tdif-05), lane-lock regression
  (tdif-04 / tdif-11 with T3A_CONTINUOUS=1), or a wedged SEND_NACK (tdif-12).
  tdif-13 is the first that lands bilateral LINK_IDLE with PHY clean.
- **Provides a clean reference point for v2 credit-gate work.** With the
  LL/FCSM layer known-good on HW, any post-bringup misbehaviour can be
  attributed unambiguously to the FC adapter / credit logic.
- **Ships the full sim infrastructure** that grew alongside the L1–L7
  investigation: 50+ cocotb tests covering paired-die bringup, asymmetric
  failure fuzz, HW regression gates, TX gated by training, LINK_IDLE →
  LINK_DATA progression, paired recal-to-link-data, and credit handshake
  end-to-end (the last being a pre-existing fail that documents the v2
  gap).
- **All L1–L7 fixes are sim-regression-clean** (see L7 commit message for
  the matrix: every existing test that passed before L7 still passes
  after L7).

---

## 5. v2 scope — deferred items

1. **Credit-gate bootstrap (L10 in flight)**: investigate why
   `pair_credit_counter` never increments after bilateral LINK_IDLE. This
   is the actual root cause of the remaining HW symptom. Branch
   `feat/td-interface-debug-l10-credit-bootstrap` is live; if it produces
   an HW-validatable fix it lands as v1.1 or v2.0 depending on scope.
2. **PHC Phase-1 master → slave sync packet path**: cannot be brought up
   until the credit gate is open in steady state. Defers behind v2 credit
   work. See `docs/PHC_PHASE1_HW_REPORT.md` and
   `docs/PHC_PHASE1_HISTORY_BISECT.md` for the existing state.
3. **Bilateral leak edge cases (tdif-04 polarity flip)**: the master
   vs slave wedge polarity flipped between tdif-04 and tdif-12. With L7
   in place this is masked, but the underlying race may resurface under
   different timing (different boards, different IDELAY taps). v2 should
   add an HW-replayable test that confirms the L7 forgive gate disarms
   correctly on both polarities once LINK_DATA is reached.

---

## 6. How to adopt this release

1. **Push the local tag** (created by the release-doc session):
   ```bash
   git -C /home/dam1n19/SoCLabs/td-bisect/td-l4-option-c \
       push origin v1.0-rc4-phc-deferred
   ```
2. **Merge the release-doc branch** `feat/v1-tdif13-release-doc` into
   `main` via the standard MR flow.
3. **Bring `07af0c1`'s override-file content onto main**: the
   `src/rtl/local_overrides/` files at commit `07af0c1` in the
   `td-bisect/td-l4-option-c` worktree are the canonical L1–L7 stack.
   These are NOT yet on `main`; either cherry-pick the L1→L7 commit chain
   or land them as a single squash to keep main's RTL history readable.
4. **Stage the v1 bitstream** to a permanent location (currently
   ephemeral under `/tmp/tidelink_deploy/tdif-13/` on mapstone-dev).

---

## 7. References

- LL/FCSM debug session log: `docs/TIDELINK_PHASE0_OBS_20260524_2109.md` §11
- Interface FCSM root-cause writeup: `docs/TIDELINK_HANDOFF_2026_05_25.md`
- Credit path debug plan: `docs/CREDIT_PATH_DEBUG_PLAN.md`
- ILA capture pipeline: `pynq_host/scripts/phc_ila_capture.{sh,tcl}`
- v2 deferral master list: `docs/V2_DEFERRALS.md`
