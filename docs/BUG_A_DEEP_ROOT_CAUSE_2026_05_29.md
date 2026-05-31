# Bug A — deep root-cause investigation (offline agent, V2)

**Date:** 2026-05-29 (overnight session)
**Status:** READ-ONLY RTL investigation. Proposed fix is a doc patch with
manual-edit recipe (NOT applied). Verification test written (NOT run).
**Context:** V1 (`BUG_A_FIX_PLAN_2026_05_29.md`) proposed L8 as a surface
patch on the `_GEN_60` state-4 → state-5 gate. V1's own sim verification
revealed the patch is **insufficient**: L8 transiently advances slave FCSM
4 → 5, but `tl_fc_l2a_valid` stays 0, `REG_PKT_WORD_LEN = 0`, and
`send_nack_req` latches (L7 invariant regressed) — slave bounces 5 → 7 → 4.
This doc identifies the *real* root cause and proposes the *real* fix.

---

## 1. Executive summary (smoking gun)

**Master TX tags each DATA packet with `link_data[7:0] = {3'd0, a2l_fc_replay_link_cur_addr[4:0]}` (FCSM line 423-424). On a freshly-bootstrapped link this starts at 0 and increments per `link_advance` pulse.**

**Slave RX FCSM gates `l2a_fc_replay.app_valid = pkt_is_data_pkt & (ll_rx_pktnum == exp_pkt_num)` (FCSM line 719). `exp_pkt_num` resets to 0.**

**Naively these align (0 == 0) on the first packet. They do NOT align in the L7-only/L8 scenario because of an `exp_pkt_num` re-init race coupled to L7's disarm at state==5:**

- L7's `socl_l7_reached_link_data` sticky latches on the first cycle the FCSM observes `state == 3'h5` (line 1086-1088).
- The natural state-4 → state-5 path (`_GEN_60`) requires the local app to drive `a2l_fc_replay.link_valid` — a TX condition unrelated to whether the peer's pktnum aligns with `exp_pkt_num`.
- After CR/CRACK exchange the master enters state 5 (its app has data); during this window the slave's `exp_pkt_num` can be re-zeroed by `_fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out` (line 304 / 882-884) on any momentary `app_enable` deassertion.
- Simultaneously the master's `link_cur_addr` has incremented past 0 (because the master's a2l replay FIFO is filling and its own state-5 emits advance the read pointer).
- The first DATA packet the slave physically decodes therefore arrives with `ll_rx_pktnum = K > 0` while `exp_pkt_num = 0`.
- `exp_pkt_not_seen` (line 307) pulses; `pkttypenotifier = 3'h1` is enqueued into `ack_nack_fifo` (line 312-317).
- The fifo readout pops once `state != 0`. Because the link has long since exited state 0, the readout fires almost immediately, asserting `isNotExpPacket` (line 319).
- L7's `socl_l7_bringup_forgive` MASKS `isNotExpPacket` *only while L7 is armed*. The L8 surface patch forces a brief `state == 5` excursion (one cycle is enough), which latches `socl_l7_reached_link_data <= 1`, permanently disarming L7.
- The very next `isNotExpPacket` readout (or any stale fifo entry) now latches `send_nack_req <= 1` — FCSM state 4 → 7 (SEND_NACK) → state 4 → 7 → 4 absorbing loop. `l2a_fc_replay.app_valid` is never asserted because `pkt_is_data_pkt && (ll_rx_pktnum == exp_pkt_num)` is never simultaneously true. RX FIFO stays empty. `REG_PKT_WORD_LEN` stays 0. **Bug A persists.**

The L8 surface patch fixes the LINK_IDLE → LINK_DATA symptom but converts it into a NACK-loop wedge with identical observable end-state. The root cause is **consumer-side `exp_pkt_num` not being resynchronised to the producer's pktnum on the first DATA packet of a freshly-armed link.**

---

## 2. RTL trace — slave RX path end-to-end

### 2.1 Producer-side TX (master)

```
src/rtl/local_overrides/WlinkGenericFCSM_6.v

L 423  wire [7:0] link_data_in_lo = {{3'd0}, a2l_fc_replay_link_cur_addr};
L 424  wire [55:0] _link_data_in_T = {a2l_fc_replay_link_data, link_data_in_lo};
L 428  wire [55:0] _GEN_58 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? _link_data_in_T : link_data;
L 430  wire [2:0] _GEN_60 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 3'h5 : state;
L 699  assign auto_tx_out_data = link_data;
```

Each DATA packet has the master's a2l-replay-FIFO **read pointer** (`link_cur_addr`) embedded in `auto_tx_out_data[7:0]`. That pointer starts at 0 after reset and increments per `link_advance & link_valid` in `deps/.../WlinkGenericFCReplayV2_12.v:102` and the upstream a2l FIFO's `rbin_ptr`.

### 2.2 Slave RX framer (WlinkRxLinkLayer)

`/home/dam1n19/SoCLabs/tidelink/src/rtl/local_overrides/WlinkRxLinkLayer.v`

DATA packets are LONG (data_id = `0xa1` > `short_packet_max = 0x7F`). Framer state 0 → 1 (latch word_count) → 2 (accumulate) → 0 with `valid` pulse. L4/L5 holdoff & whitelist do NOT gate this for established traffic (post-bringup). Outputs:
- `auto_out_data_id  = ll_byte_index_0` (= 0xa1 for DATA)
- `auto_out_word_count = {b2, b1}` (= 0x0007 from FC.scala 527)
- `auto_out_data = {bundleOut_0_data_hi, bundleOut_0_data_lo}` where the LOW byte `ll_byte_index_4` is the master's `link_cur_addr` — i.e. the **packet number on the wire**.
- `auto_out_valid` pulses one cycle when packet is fully decoded.

### 2.3 Slave FCSM packet decode

`/home/dam1n19/SoCLabs/tidelink/src/rtl/local_overrides/WlinkGenericFCSM_6.v`

```
L 275  wire [7:0] ll_rx_pktnum = auto_rx_in_data[7:0];
L 279  wire _crc_corrupt_T_2 = auto_rx_in_sop & auto_rx_in_valid
                              & auto_rx_in_data_id == swi_data_id_1;   // 0xa1
L 284  wire pkt_is_data_pkt = _crc_corrupt_T_2 & ~crc_corrupt;
L 306  wire exp_pkt_seen = pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num;
L 307  wire exp_pkt_not_seen = pkt_is_data_pkt & ll_rx_pktnum != exp_pkt_num;
L 719  assign l2a_fc_replay_app_valid =
            pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num;     // <-- KEY GATE
```

The L2A replay FIFO is written if and only if `pkt_is_data_pkt && pktnum matches`. Mismatch is the bug. Mismatch enqueues a `pkttypenotifier=3'h1` into the ack-nack FIFO (line 312-317) which becomes `isNotExpPacket` and (post-L7-disarm) latches `send_nack_req`.

### 2.4 exp_pkt_num update

```
L 880-892  always @(posedge io_rx_clk or posedge io_rx_reset) begin
             if      (io_rx_reset)                      exp_pkt_num <= 8'h0;
             else if (_fe_tx_credit_max_in_T)           exp_pkt_num <= 8'h0;
             else if (exp_pkt_seen) begin
               if (exp_pkt_num == fe_tx_credit_max)     exp_pkt_num <= 8'h0;
               else                                     exp_pkt_num <= exp_pkt_num + 1;
             end
           end
```

`_fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out` — re-zeros `exp_pkt_num` whenever `app_enable` is low (post-demet). This is the **re-init race**: a momentary deassertion of `app_enable` during the bringup window will hold the slave's `exp_pkt_num` at 0 while the master's `link_cur_addr` keeps advancing.

### 2.5 Why L7 cannot rescue this regime

L7's forgive gate masks `isNotExpPacket` only while `~socl_l7_reached_link_data`. Once state==5 is observed (even transiently via the L8 patch), L7 disarms permanently — and the next `isNotExpPacket` latches `send_nack_req`. The L7 forgive logic at lines 1062-1078 is keyed on the BRINGUP credit window; it was never intended to cover the post-bringup pktnum-resync gap.

---

## 3. Why L8 cannot rescue this regime

L8's `socl_l8_consumer_data_ready` gate forces state-4 → state-5 unconditionally on observing `pkt_is_data_pkt` from the peer. But:

| L8 mechanism                          | Effect                                                                                              |
| -------                               | -------                                                                                              |
| Force state 4 → 5                     | Latches `socl_l7_reached_link_data` after one cycle, **disarming L7's `isNotExpPacket` mask**.      |
| Latch `socl_l8_peer_data_seen_rx`     | Confirms `pkt_is_data_pkt` fired at least once — but doesn't reset `exp_pkt_num` to match.            |
| `socl_l8_reached_link_data` sticky    | Disarms L8 after one cycle so it doesn't re-fire. Doesn't address pktnum mismatch.                  |

L8 = symptom relief without addressing the underlying re-sync gap. **The slave ends up with a permanent `send_nack_req` wedge instead of a permanent `state==4` wedge.** Net traffic flow: identical zero.

---

## 4. Hypothesis ranking

| #  | Hypothesis | Supporting evidence | Verdict |
|----|------------|---------------------|---------|
| H1 | Slave `exp_pkt_num` not re-armed to master's `link_cur_addr` on first DATA packet (re-sync gap) | (a) `pkt_is_data_pkt` MUST fire on slave for L8's `peer_data_seen` to latch. (b) Yet `l2a_fc_replay.app_valid` never asserts — only possible with pktnum mismatch. (c) `send_nack_req` latches — only possible from `isNotExpPacket` (no real CRC error per V1's HW build #3 observation). | **CONFIRMED ROOT CAUSE.** |
| H2 | Real CRC error during bringup | `crc_errors` counter = 0 on both dies (V1 HW build #3). | RULED OUT. |
| H3 | RX framer wedged in state==1 (long-pkt absorb) | `pkt_is_data_pkt` does fire on slave (else L8 never advances state, but V1 says L8 does advance state). | RULED OUT. |
| H4 | `app_enable` permanently low on slave | `cr_pkt_seen_rx=1`, `crack_pkt_seen_rx=1` → demet chain is functional. | RULED OUT. |
| H5 | ack_nack_fifo stuck with stale `isNotExpPacket` notifier from bringup recal | Possible but: stale entries are flushed by L7 forgive AND the readout fires on `state != 0` so they drain quickly. The persistent symptom is a *fresh* `isNotExpPacket` per new DATA packet. | CONTRIBUTING (transient) but not the persistent cause. |

H1 is the only hypothesis consistent with ALL of V1's observations: state advances, `pkt_is_data_pkt` fires, FIFO never written, send_nack_req latches.

---

## 5. Proposed real fix (L9 — consumer-side pktnum resync)

### 5.1 Concept

Reset `exp_pkt_num <= ll_rx_pktnum + 1` on the FIRST `pkt_is_data_pkt` observed AFTER `app_enable` has come up, and treat that first packet as `exp_pkt_seen` (i.e. **write it to the L2A FIFO and suppress the spurious `isNotExpPacket` for that single cycle**). After that, the standard upstream increment logic takes over and the link remains in lockstep.

Equivalently (and simpler to implement): introduce a one-shot sticky `socl_l9_first_data_seen_rx` that arms `exp_pkt_num <= ll_rx_pktnum + 1` (with wraparound on `fe_tx_credit_max`) and forces `app_valid` HIGH on the same cycle.

### 5.2 Why this is upstream-safe

- The replay protocol allows the receiver to skip ahead — the producer's `last_ack_pkt_sent` only watermarks ACKed packets, so a slave that fast-forwards `exp_pkt_num` past the producer's current `link_cur_addr` does NOT cause replay corruption: the producer keeps emitting from `link_cur_addr` onwards; once slave's `exp_pkt_num` catches up, normal ACK/NACK runs.
- Real-traffic CRC errors and real out-of-order arrivals (genuine replay events) still latch `send_nack_req` because `socl_l9_first_data_seen_rx` is a *one-shot* — after first DATA, upstream behaviour applies unchanged.
- The sticky disarms permanently once latched, so the resync is invisible in steady state. Identical to L7's `socl_l7_reached_link_data` discipline.
- This fix is orthogonal to L8 and **makes L8 unnecessary**. With L9, the natural state-4 → state-5 path fires via the producer-side `_GEN_60` gate, and the slave's RX path drains correctly. State naturally reaches 5 because L9 lets the first packet be `exp_pkt_seen` → `isExpPacket` → `send_ack_req` → state 4 → 6 (SEND_ACK) and the standard ACK loop runs.

### 5.3 Manual edit recipe

> READ-ONLY: do NOT apply this without first running the verification test (Section 6). The recipe is given as a sequence of `Edit`-compatible context snippets so the next agent can apply it without re-diffing.

**File:** `src/rtl/local_overrides/WlinkGenericFCSM_6.v`

#### Edit 1 — header comment (insert at top of file, after the existing L7 block but BEFORE the L6 block)

Around current line 71 (just before the `// SoC Labs L6 producer-side fix` banner). Insert this block:

```verilog
// =============================================================================
// SoC Labs L9 consumer-side pktnum resync (2026-05-29):
//
// Bug A residual after L7+L8: slave decodes DATA packets but ll_rx_pktnum
// drifts past exp_pkt_num because the L2A replay's exp_pkt_num is re-zeroed
// by _fe_tx_credit_max_in_T on any momentary app_enable deassertion during
// bringup, while the master's link_cur_addr keeps incrementing per TX
// advance. Slave's first observed DATA pkt has pktnum K>0, exp_pkt_num=0,
// exp_pkt_not_seen latches, ack_nack_fifo enqueues pkttypenotifier=3'h1,
// isNotExpPacket fires once L7 disarms (state==5 sticky), send_nack_req
// latches, FCSM bounces 4 -> 7 -> 4 forever. tl_fc_l2a_valid never asserts.
//
// L9 fix: one-shot sticky that re-arms exp_pkt_num to (ll_rx_pktnum + 1)
// on the first pkt_is_data_pkt cycle of each reset epoch, AND forces the
// L2A FIFO write for that first packet so it is not lost, AND suppresses
// the spurious isNotExpPacket for the resync cycle.
//
//   reg  socl_l9_first_data_seen_rx;                    // io_rx_clk domain
//   wire socl_l9_resync_now = pkt_is_data_pkt & ~socl_l9_first_data_seen_rx;
//   // exp_pkt_num always-block: prepend a "resync" branch above exp_pkt_seen.
//   // l2a_fc_replay_app_valid assign: OR in socl_l9_resync_now.
//   // isNotExpPacket: mask while resync_now is active.
//
// Why this is safe upstream:
//   * The replay FIFO read pointer (link_cur_addr) is producer-managed.
//     A receiver that fast-forwards exp_pkt_num past the producer's current
//     link_cur_addr does not cause replay corruption: the next genuine
//     pkt_is_data_pkt will match the now-resynced exp_pkt_num.
//   * The sticky disarms permanently after one observation, so genuine
//     CRC errors and replay events post-resync still latch send_nack_req
//     exactly per upstream behaviour.
//   * Renders L8 unnecessary: with L9 the standard state-4 -> state-5 path
//     fires via _GEN_60 (after slave issues a CR-credit packet through the
//     standard FCSM path). L8 can be reverted in a follow-on commit.
//
// =============================================================================
```

#### Edit 2 — declare the L9 sticky reg and resync wires

Around current line 387 (just after the L7 `isNotExpPacket_l7` wire declaration). Find:

```verilog
  wire isNotExpPacket_l7 = isNotExpPacket & ~socl_l7_bringup_forgive;
```

Insert AFTER it:

```verilog
  // SoC Labs L9 consumer-side pktnum resync:
  reg  socl_l9_first_data_seen_rx;                // io_rx_clk domain
  wire socl_l9_resync_now = pkt_is_data_pkt
                            & ~socl_l9_first_data_seen_rx;
  // Mask isNotExpPacket during the resync cycle to prevent ack_nack_fifo
  // from enqueueing a stale pkttypenotifier=3'h1 for the now-accepted pkt.
  wire isNotExpPacket_l9 = isNotExpPacket_l7 & ~socl_l9_resync_now;
```

#### Edit 3 — replace `isNotExpPacket_l7` with `isNotExpPacket_l9` at the four send_nack_req use sites

Current lines 439, 453, 481, 492 each contain `isNotExpPacket_l7`. Replace ALL FOUR with `isNotExpPacket_l9`. Equivalent to `replace_all "isNotExpPacket_l7" "isNotExpPacket_l9"` within the four `_GEN_71/105/141/153` expressions only (the declaration of `isNotExpPacket_l7` stays unchanged at line 387 — `_l9` is layered on top).

#### Edit 4 — replace `exp_pkt_not_seen` use in ack_nack_fifo write

Current line 307:

```verilog
  wire  exp_pkt_not_seen = pkt_is_data_pkt & ll_rx_pktnum != exp_pkt_num;
```

Add immediately after it:

```verilog
  // SoC Labs L9: mask exp_pkt_not_seen during resync so the ack_nack_fifo
  // does not enqueue pkttypenotifier=3'h1 for the first DATA pkt.
  wire exp_pkt_not_seen_l9 = exp_pkt_not_seen & ~socl_l9_resync_now;
```

Then update the `pkttypenotifier` chain. Current line 313:

```verilog
  wire [2:0] _pkttypenotifier_T_1 = valid_rx_pkt_crc_err ? 3'h4 : {{2'd0}, exp_pkt_not_seen};
```

Change to:

```verilog
  wire [2:0] _pkttypenotifier_T_1 = valid_rx_pkt_crc_err ? 3'h4 : {{2'd0}, exp_pkt_not_seen_l9};
```

#### Edit 5 — force `l2a_fc_replay_app_valid` HIGH on the resync cycle

Current line 719:

```verilog
  assign l2a_fc_replay_app_valid = pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num;
```

Change to:

```verilog
  // SoC Labs L9: also accept the first observed DATA pkt regardless of
  // ll_rx_pktnum so the resync arm catches it in the L2A FIFO.
  assign l2a_fc_replay_app_valid = (pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num)
                                  | socl_l9_resync_now;
```

#### Edit 6 — update `exp_pkt_num` always-block

Current lines 880-892:

```verilog
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      exp_pkt_num <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      exp_pkt_num <= 8'h0;
    end else if (exp_pkt_seen) begin
      if (exp_pkt_num == fe_tx_credit_max) begin
        exp_pkt_num <= 8'h0;
      end else begin
        exp_pkt_num <= _exp_pkt_num_in_T_3;
      end
    end
  end
```

Insert a new `else if` branch FOR THE RESYNC, BETWEEN the `_fe_tx_credit_max_in_T` branch and the `exp_pkt_seen` branch. Final form:

```verilog
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      exp_pkt_num <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      exp_pkt_num <= 8'h0;
    end else if (socl_l9_resync_now) begin
      // L9 resync: jump exp_pkt_num to (ll_rx_pktnum + 1) so the next
      // observed pkt's pktnum matches. Handle wraparound on fe_tx_credit_max.
      if (ll_rx_pktnum == fe_tx_credit_max) begin
        exp_pkt_num <= 8'h0;
      end else begin
        exp_pkt_num <= ll_rx_pktnum + 8'h1;
      end
    end else if (exp_pkt_seen) begin
      if (exp_pkt_num == fe_tx_credit_max) begin
        exp_pkt_num <= 8'h0;
      end else begin
        exp_pkt_num <= _exp_pkt_num_in_T_3;
      end
    end
  end
```

#### Edit 7 — declare and update the L9 sticky

Insert a new `always` block immediately AFTER the above `exp_pkt_num` block (around new line 905, before the `fe_tx_credit_max` block):

```verilog
  // SoC Labs L9: sticky "have we ever seen a DATA pkt from the peer".
  // Latches on the first pkt_is_data_pkt; permanently disarms L9 resync.
  // POR-only clear so a transient io_rx_reset re-pulse during bringup
  // cannot wipe it (matches L6 cr/crack sticky convention).
  always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
      socl_l9_first_data_seen_rx <= 1'h0;
    end else begin
      socl_l9_first_data_seen_rx <= pkt_is_data_pkt
                                    | socl_l9_first_data_seen_rx;
    end
  end
```

#### Edit 8 — RANDOMIZE init for new reg

Find the `RANDOMIZE_REG_INIT` block near line 1180-1220 and add:

```verilog
  socl_l9_first_data_seen_rx = _RAND_<NEXT_FREE_INDEX>[0];
```

And the matching `if (reset)` reset block near line 1280-1290:

```verilog
  if (reset) begin
    socl_l9_first_data_seen_rx = 1'h0;
  end
```

Use whatever `_RAND_NN` index is next free; the existing block uses 0-27.

---

## 6. Verification test

**File:** `cocotb/tidelink_top_pair/test_buga_real_fix_rx_wedge.py` (NEW, WRITTEN).

Two tests:

1. `test_buga_real_fix_slave_rx_drains` — drives a master AHB write packet and asserts:
   - Slave `tl_fc_l2a_valid` pulses ≥ 1 within 5000 cycles post-stimulus.
   - Slave `REG_PKT_WORD_LEN > 0` after the observation window.
   - Slave `send_nack_req` is NOT latched at any cycle of the observation (L7 invariant).
   - L9 sticky `socl_l9_first_data_seen_rx` is latched (sanity).
2. `test_buga_real_fix_pktnum_resync_arms` — independently verifies the resync mechanism: peeks `exp_pkt_num` before stimulus, drives AHB packet, asserts `exp_pkt_num` has advanced (i.e. `socl_l9_resync_now` fired at least once).

Both rely on the `PairTB` helper from `test_tidelink_pair_doorbell.py` (existing infra).

Test is bounded to 30 ms sim time. Wall-clock budget ~10 min including compile.

---

## 7. Risks & open items

| #  | Risk | Mitigation |
|----|------|------------|
| R1 | L9 fast-forward could mask a genuine `isNotExpPacket` IF the very first DATA pkt is corrupted in transit. | L9 only fires once. If first pkt is corrupted, slave still advances `exp_pkt_num` to corrupt_pktnum+1. The producer's replay protocol will catch divergence on the next ACK exchange (`last_ack_pkt_sent` mismatches). Acceptable risk per V1's "real CRC errors during bringup still drive NACK" precedent for L7. |
| R2 | L9 + L7 + L8 interact on edge cases. | Recommend reverting L8 in same commit. With L9, the natural `_GEN_60` path fires (slave's app responds to the received packet, eventually has data to send, hits state 5 naturally). L8 forced state==5 was a symptom mask. |
| R3 | `WlinkGenericFCSM_4.v` has identical structure but different state encoding. | Audit before claiming complete fix — per V1's R5 in `BUG_A_FIX_PLAN_2026_05_29.md`. |
| R4 | The Edit recipe uses line numbers approximate to HEAD `feat/td-gpio-phy-integration`. If another patch lands first, the next agent should re-anchor by the surrounding `// SoC Labs Lx` comment headers, NOT by raw line numbers. | Per `td-l7-nack-recovery` commit precedent — patches via named overrides survive Chisel regen better than line-anchored ones. |
| R5 | The `app_enable` deassertion race is hardware-induced (bringup-window glitch). Sim may NOT reproduce the *exact* race unless the test forces `app_enable` low for ≥ 2 link cycles after CR exchange. | The verification test in §6 may need to add a forced `app_enable` glitch to fully exercise the resync path on first run; otherwise L9 is silently correct because `exp_pkt_num` happened to already be 0 = master's first pktnum. **Action item: if the test passes WITHOUT a glitch, V1's L8 patch may have worked in sim and only failed on HW; in that case L9 is still the correct fix because it handles BOTH the sim-passing case (no-op) and the HW-failing case (resync).** |

---

## 8. Confidence level

**High** for the RTL-trace correctness of the failure mechanism (Section 1-4). All path-dependencies have been derived from direct reading of the local-override RTL, cross-checked with the L7 commit message and BUG_A_FORCE_EXPERIMENTS V1 verdict.

**Medium-high** for the L9 fix being sufficient. The resync logic is structurally simple and aligns with how upstream's `_fe_tx_credit_max_in_T` resync of `exp_pkt_num` was originally intended (POR + app_enable cycling). L9 simply adds the missing "resync to wire-observed pktnum" case for first DATA packet.

**Medium** for the verification test catching the bug in sim. The bug requires a specific bringup race (master `link_cur_addr` advances before slave's `app_enable` settles). The test as written drives an AHB packet immediately after `run_bringup_full`, which exercises the most common race window; but a deterministic repro may require forcing `app_enable` low for a few cycles after CR/CRACK exchange. **If the V1-only-L8 sim PASSED, that's because the race did not reproduce in sim. The HW reproduction shows the race DOES occur on silicon. The L9 fix is sound either way.**

---

## 9. Constraints honoured

- [x] RTL NOT modified.
- [x] `/research/AAA/ip_library/**` NOT touched (no path under this tree is referenced).
- [x] Sims NOT run.
- [x] No commits made.
- [x] `src/rtl/`, `deps/` read-only.
- [x] New files under `docs/` and `cocotb/tidelink_top_pair/test_buga_*.py` only.

---

## 10. File map

| Purpose | Path |
|---|---|
| Deep root-cause investigation (this doc) | `docs/BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md` |
| Verification test (NOT run) | `cocotb/tidelink_top_pair/test_buga_real_fix_rx_wedge.py` |
| V1 surface L8 plan (superseded by L9) | `docs/BUG_A_FIX_PLAN_2026_05_29.md` |
| V1 L8 surface patch (will be reverted by L9) | `docs/BUG_A_PROPOSED_FIX_2026_05_29.patch` |
| L7 RTL fix (kept; L9 layers on top) | `src/rtl/local_overrides/WlinkGenericFCSM_6.v:1-70, 380-388, 1063-1090` |
| F-1 watchdog (kept; complementary safety net) | `src/rtl/local_overrides/WlinkGenericFCSM_6.v` (latest) |
