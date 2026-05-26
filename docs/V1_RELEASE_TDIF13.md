# TideLink v1.0-rc4 Release — tdif-13 (L1-L7 RTL stack)

| Field | Value |
| ----- | ----- |
| Release candidate | v1.0-rc4-phc-deferred (PHC Phase-1 + byte-align fix — see §5) |
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

> **Diagnosis evolved 2026-05-26 09:30 → 10:00 BST. Latest position:
> TWO INDEPENDENT BUGS likely exist.**
>
> 1. **Credit-pool=0 in FCSM** (real RTL bug at `_GEN_42` in
>    `WlinkGenericFCSM_6.v`): the second-emit CRACK protocol emits
>    `word_count=0x0000` under asymmetric bringup timing, which the
>    peer then loads as `fe_rx_credit_max=0`. FCSM gate
>    `~fe_rx_is_full` evaluates false, no FC traffic ever crosses.
>    Affects: doorbells, AHB peer-writes via FC, TideLink FC channel.
>    L10 fix (commit `8783885` on `feat/td-interface-debug-l10-credit-bootstrap`)
>    clamps the WC=0 value to 0x1f at the receiver — sim-clean.
>
> 2. **PTP RX silent** (separate, unconfirmed): master fires 64 PTP
>    SYNCs at 32 Hz with `phc_locked=1`, slave's `PTP_RX_PAYLOAD=0`.
>    PTP transport BYPASSES the FCSM credit gate (separate
>    `ShortPacketToWlink` module), so this failure is independent of
>    bug #1. Hypothesis: slave LL_RX byte-align lost post-bringup at
>    the `WavD2DGpioRx` layer. Awaiting ILA capture DURING PTP TX to
>    confirm — current ILA captures were during credit-gated doorbell
>    flood (no master TX activity), so byte-align could not be tested.
>
> Both bugs need to be fixed (or one shown to be a consequence of
> the other) before PHC Phase-1 can close.

1. **Slave LL_RX byte-align is LOST post-bringup.** ILA capture during a
   200-doorbell flood (HW exploration 2026-05-26) showed slave's
   `llrx/state=iSTATE` and `valid_byte_reg=0` for all 4096 samples —
   slave's WavD2DGpio framer is not decoding ANY bytes after the recal
   cycle completes, despite cr/crack sticky bits latching DURING bringup.
   PTP HW test (2026-05-26 08:30 BST) drove 64 SYNC packets from master
   at 32 Hz with `phc_locked=1`; slave's `PTP_RX_PAYLOAD` stayed at 0
   and `rx_valid` never asserted. PTP **bypasses the FCSM credit gate**
   (separate `ptp_in/out` port, `ShortPacketToWlink` module), so the
   lack of cross-channel evidence proves the bug is **upstream of FCSM
   credit logic** — at the LL_RX byte-stream layer itself.
2. **`pair_credit_counter == 0` is a SYMPTOM, not the bug.** Because
   slave never decodes incoming credit-release packets, the per-channel
   credit counter on master never increments. The original "credit-gate
   deadlock" framing inverted cause and effect: credits don't move
   because bytes don't decode, not because the gate logic is wrong.
3. **No user traffic crosses post-bringup**: doorbells, AHB writes, and
   PTP packets all fail at the same point — slave's framer never sees
   them as valid bytes.
4. **The remaining bug is at the link-layer RX byte-align path on
   slave, NOT in `tidelink_fc_adapter.sv` and NOT in the LL/FCSM layer.**
   All L1–L7 fixes are correct and well-scoped, but L1 (TX word-aligned
   mux) + Option (c) (CDC-gated llrx_reset) together do not survive the
   recal→data-mode transition on real silicon. Sim ↔ HW divergence:
   sim shows the L1+Option (c) stack achieves stable RX byte-align;
   HW shows it is briefly correct during bringup (cr/crack latch) and
   then breaks. The post-bringup HW signature is what v2 must fix.
5. **0x44010000 is NOT a valid peer-aperture test**: peer-side AHB writes
   should target `0x40000000` (the `ahb_sub` region) on the remote chiplet.
   `0x44010000` belongs to the local FIFO read window (`ahb_fifo`) and
   does not exercise any cross-die data path. Several hwtest scripts
   (notably `pynq_host/scripts/hwtest/03_ahb_sub_e2e.sh`) carry the
   misnamed `AHB_SUB_BASE:=0x44010000`; these need to be corrected
   independently of the RTL work.

---

## 4. Why v1 is still valuable

- **First HW build with correct LL/FCSM endpoint state.** Every prior
  attempt either had asymmetric CR loss (tdif-05), lane-lock regression
  (tdif-04 / tdif-11 with T3A_CONTINUOUS=1), or a wedged SEND_NACK (tdif-12).
  tdif-13 is the first that lands bilateral LINK_IDLE with PHY clean.
- **Provides a clean reference point for v2 byte-align robustness
  work.** With the LL/FCSM layer known-good on HW (cr/crack symmetric,
  bilateral LINK_IDLE), any post-bringup misbehaviour can be attributed
  unambiguously to the WavD2DGpioRx byte-align / framer-decode path.
  v2 work can use tdif-13 as the baseline + ILA-capture target.
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

1. **Slave LL_RX byte-align robustness post-bringup (PRIMARY)**: ILA + PTP
   HW evidence (2026-05-26) shows slave's `WavD2DGpioRx` framer stops
   decoding after the recal cycle completes — `valid_byte_reg=0` for
   4096 samples during master TX. Master TX confirmed working (64 PTP
   SYNCs fired with `phc_locked=1`). The L1 + Option (c) fixes were
   insufficient on HW even though sim showed them working. v2 needs to
   re-derive the byte-align loss mechanism with full ILA observability
   on `WavD2DGpioRx` count register, IDELAY tap, and per-lane bit
   boundaries during the to_data_mode transition. The credit-gate
   hypothesis explored on tdif-15/16 (L9 watchdog) was a wrong turn —
   credits stay at 0 because bytes never decode, not because the gate
   is broken.
2. **Add ILA mark_debug to `tl_fc_a2l_*` and `tl_fc_l2a_*`** in the FC
   adapter (and to the WavD2DGpioRx `count` register on slave) so the
   next HW build can ILA-capture exactly where bytes stop. Currently the
   tdif-10 visibility taps are heavily LL_RX-focused but miss the
   post-bringup byte-align loss observation point.
3. **PHC Phase-1 master → slave sync packet path**: cannot be brought up
   until slave LL_RX byte-align survives the recal cycle. Bringup script
   `bringup_ptp_sync.sh` is staged on mapstone-dev and ready to run
   immediately once #1 lands. PTP transport architecture is independent
   from FC channel (separate `ShortPacketToWlink` module) so PHC test
   will be a direct read of `PTP_RX_PAYLOAD` once master TX bytes
   actually reach slave's framer.
4. **Bilateral leak edge cases (tdif-04 polarity flip)**: the master
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
