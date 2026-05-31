# Bug A — L9 RX-correctness fix design (NO RTL APPLY)

**Date:** 2026-05-31  •  **Branch:** `sim/bug-a-wedge-test`  •  **Status:** Design only

L9 attacks the **upstream** cause of the Bug A wedge: WHY does the slave
RX framer drop the master's first DATA packet? L11 (already landed in
`src/rtl/tidelink_fc_adapter.sv:181-240`) handles the *consequence* —
master PS-bus liveness when slave wedges — and is fully sim-verified
in `cocotb/tidelink_top_pair/test_bug_a_master_tx_wedge.py`. L9 prevents
the wedge from ever happening.

See companion: V1 root-cause investigation @ Q5 (offline-agent doc
`BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md`, summarised below in §1).

---

## 1. Bug class confirmed by RTL trace

**Producer-side (master):**
`src/rtl/local_overrides/WlinkGenericFCSM_6.v:495-502` —
each DATA pkt is tagged with `link_data[7:0] = {3'd0,
a2l_fc_replay_link_cur_addr[4:0]}`. The master's a2l replay FIFO read
pointer (`link_cur_addr`) starts at 0 after reset and increments on every
`link_advance & link_valid` cycle.

**Consumer-side (slave):**
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v:369` —
  `exp_pkt_seen = pkt_is_data_pkt & (ll_rx_pktnum == exp_pkt_num)`
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v:791` —
  `l2a_fc_replay_app_valid = pkt_is_data_pkt & (ll_rx_pktnum == exp_pkt_num)`
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v:960-972` — `exp_pkt_num`
  re-zeroed every cycle `_fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out`,
  i.e. whenever the demet'd `app_enable` is low. Only advances on
  `exp_pkt_seen`.

**Failure mode (re-sync gap during bringup):**
A short `app_enable` glitch on the slave (POR vs. swreset bootstrap
timing) holds `exp_pkt_num = 0` while the master's `link_cur_addr`
keeps incrementing through legitimate `link_valid` pulses. The first
DATA packet the slave physically decodes therefore arrives with
`ll_rx_pktnum = K > 0` against `exp_pkt_num = 0`. The decode triggers
`exp_pkt_not_seen` (line 370) → `pkttypenotifier = 3'h1`
(line 376) → ack_nack_fifo enqueue → `isNotExpPacket` (line 382)
→ once L7's `socl_l7_reached_link_data` sticky has latched (first
state==5 observation), L7 stops masking → `send_nack_req <= 1` →
slave parks in `state==4 ↔ 7 ↔ 4` NACK loop.

`l2a_fc_replay_app_valid` never asserts, slave's L2A FIFO stays empty,
slave never ACKs the master, master's `a2l_fc_replay` window stays
occupied, `a2l_full` latches in
`deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v:94`,
master's `tl_fc_a2l_ready` deasserts forever — wedge primitive armed
(L11 territory takes over to keep PS alive).

---

## 2. Fix concept — one-shot consumer pktnum resync

After reset, the FIRST `pkt_is_data_pkt` observed on the slave is
*always* the legitimate next packet from the producer (no replay can
have happened yet — there's no peer ACK history). Fast-forward
`exp_pkt_num` to `ll_rx_pktnum + 1` AND accept that packet into the
L2A FIFO AND mask the spurious `isNotExpPacket` for that single cycle.
After this one-shot, standard upstream behaviour resumes.

Why this is upstream-safe:
- The replay protocol does **not** require strict order at the consumer
  for the first packet; it only requires consumer/producer to agree on
  the next-expected number after that point. Fast-forwarding past the
  producer's `link_cur_addr` cannot corrupt replay because the producer
  doesn't reset `link_cur_addr` on consumer's behalf.
- The one-shot disarms permanently on first observation, so post-resync
  the slave behaves identically to upstream — genuine CRC errors and
  real out-of-order arrivals (legitimate replay events) still latch
  `send_nack_req`.
- Identical sticky discipline to existing L7 `socl_l7_reached_link_data`
  and L6 `socl_l6_cr_emit_count`.

---

## 3. RTL patch (Edit-tool ready, NOT applied)

**File:** `src/rtl/local_overrides/WlinkGenericFCSM_6.v` (verified line
numbers against current HEAD `bc52f88` post L11-restore).

### Edit 1 — declare L9 sticky + resync wire

Find at **line 450** (immediately after the `isNotExpPacket_l7` wire
declaration):

```verilog
  wire isNotExpPacket_l7 = isNotExpPacket & ~socl_l7_bringup_forgive;
```

Insert AFTER it (new lines 451-455):

```verilog
  // SoC Labs L9 consumer-side pktnum resync (2026-05-31):
  //   One-shot fast-forward of exp_pkt_num to the first observed
  //   ll_rx_pktnum + 1. Closes the exp_pkt_num re-zero-vs-link_cur_addr
  //   race that latches send_nack_req post L7 disarm. See
  //   docs/BUG_A_L9_FIX_DESIGN_2026_05_31.md §2 + §4.
  reg  socl_l9_first_data_seen_rx;
  wire socl_l9_resync_now = pkt_is_data_pkt & ~socl_l9_first_data_seen_rx;
  wire isNotExpPacket_l9  = isNotExpPacket_l7 & ~socl_l9_resync_now;
```

### Edit 2 — mask the ack_nack_fifo write of the spurious 3'h1 notifier

Find at **line 370**:

```verilog
  wire  exp_pkt_not_seen = pkt_is_data_pkt & ll_rx_pktnum != exp_pkt_num; // @[FC.scala 211:54]
```

Insert AFTER it:

```verilog
  // SoC Labs L9: suppress the spurious mismatch enqueue on the resync cycle
  // so the ack_nack_fifo does not carry a stale isNotExpPacket entry forward.
  wire exp_pkt_not_seen_l9 = exp_pkt_not_seen & ~socl_l9_resync_now;
```

Find at **line 376**:

```verilog
  wire [2:0] _pkttypenotifier_T_1 = valid_rx_pkt_crc_err ? 3'h4 : {{2'd0}, exp_pkt_not_seen}; // @[FC.scala 276:42]
```

Change `exp_pkt_not_seen` → `exp_pkt_not_seen_l9` (single-token replace
on this exact line). Final line:

```verilog
  wire [2:0] _pkttypenotifier_T_1 = valid_rx_pkt_crc_err ? 3'h4 : {{2'd0}, exp_pkt_not_seen_l9}; // SoC Labs L9 masked mismatch
```

### Edit 3 — replace `isNotExpPacket_l7` with `isNotExpPacket_l9` at the four send_nack_req use sites

Find every occurrence of `isNotExpPacket_l7` BELOW line 450 (i.e. NOT the
declaration). Per `grep -n isNotExpPacket_l7 src/rtl/local_overrides/WlinkGenericFCSM_6.v`
there are exactly four — in the `_GEN_71`, `_GEN_105` etc. expressions
(currently lines 511, 525, plus two in their `_GEN_141`/`_GEN_153`
analogues — verify with grep before replace). Use Edit tool
`replace_all: false` four times, OR (safer) declare `isNotExpPacket_l9`
as the masked variant and do a region-bounded `replace_all`.

Idiomatic single-pass Edit:

```python
Edit(file=".../WlinkGenericFCSM_6.v",
     old_string="isNotExpPacket_l7",
     new_string="isNotExpPacket_l9",
     replace_all=True)
```

— BUT this will also rename the declaration line 450. To keep the L7
declaration intact, the recipe is: declare `isNotExpPacket_l9` per
Edit 1 ABOVE, then `replace_all` `isNotExpPacket_l7` → `isNotExpPacket_l9`,
then `Edit` the line 450 declaration back to its original form. Or use
4 individual Edits.

### Edit 4 — force `l2a_fc_replay_app_valid` HIGH on the resync cycle

Find at **line 791**:

```verilog
  assign l2a_fc_replay_app_valid = pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num; // @[FC.scala 210:54]
```

Replace with:

```verilog
  // SoC Labs L9: accept the FIRST observed DATA pkt regardless of pktnum
  // alignment so the resync write lands in the L2A FIFO.
  assign l2a_fc_replay_app_valid = (pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num)
                                  | socl_l9_resync_now;
```

### Edit 5 — update `exp_pkt_num` always-block

Find at **lines 960-972**:

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

Replace with (new `else if` branch inserted between `_fe_tx_credit_max_in_T`
and `exp_pkt_seen`):

```verilog
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      exp_pkt_num <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      exp_pkt_num <= 8'h0;
    end else if (socl_l9_resync_now) begin
      // SoC Labs L9: jump exp_pkt_num to ll_rx_pktnum + 1 (wrap on fe_tx_credit_max).
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

### Edit 6 — declare and update the L9 sticky

Insert a new `always` block IMMEDIATELY AFTER the above `exp_pkt_num`
block (before the `fe_tx_credit_max` always-block at line 973):

```verilog
  // SoC Labs L9: sticky "have we ever seen a DATA pkt from the peer".
  // POR-only clear matches the L6 cr/crack sticky convention; a
  // transient io_rx_reset re-pulse during bringup cannot wipe it.
  always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
      socl_l9_first_data_seen_rx <= 1'h0;
    end else begin
      socl_l9_first_data_seen_rx <= pkt_is_data_pkt
                                    | socl_l9_first_data_seen_rx;
    end
  end
```

### Edit 7 — RANDOMIZE init for new reg (synth-clean, sim-clean)

Find the `RANDOMIZE_REG_INIT` block and add a `_RAND_NN` entry +
matching reset block. Pattern matches the existing convention for
`socl_l7_reached_link_data` — the next agent should follow the same
indexing.

---

## 4. Sim verification recipe

**Existing test ready to run:**
`cocotb/tidelink_top_pair/test_buga_real_fix_rx_wedge.py` (already
present in tree as a result of the V1 offline-agent docs work). It
already includes:
- `test_buga_real_fix_slave_rx_drains` — drives an AHB packet,
  asserts slave `tl_fc_l2a_valid` pulses ≥1 within 5000cy, and asserts
  `send_nack_req` is NOT latched at any cycle.
- `test_buga_real_fix_pktnum_resync_arms` — verifies `exp_pkt_num`
  advances on first DATA pkt, i.e. `socl_l9_resync_now` fired.

**Run command:**

```bash
source /home/dam1n19/SoCLabs/tidelink/set_env.sh
cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
timeout 1500 make MODULE=test_buga_real_fix_rx_wedge \
    SIM_BUILD=sim_build_l9_verify TB_TOP_NO_DUMP=1
```

**Expected outcomes:**
- WITHOUT L9 applied: tests FAIL (slave `tl_fc_l2a_valid` never pulses,
  `send_nack_req` latches, or `exp_pkt_num` never advances).
- WITH L9 applied: tests PASS (slave drains, exp_pkt_num resyncs).

**Layered regression bar (must stay green):**
`test_bug_a_master_tx_wedge.py` (this branch) — both tests must
continue to PASS regardless of L9 status, proving L11 is unaffected.

---

## 5. Layering with L7 / L11

| Layer | Lives in | Fixes | Status |
|-------|---------|-------|--------|
| L7    | `WlinkGenericFCSM_6.v:443-450, 1062-1090` | Sticky-NACK during bringup credit window | Landed |
| L9    | `WlinkGenericFCSM_6.v` (this design)      | RX consumer pktnum resync to producer    | **Designed, NOT applied** |
| L11   | `tidelink_fc_adapter.sv:181-240`          | Master AHB liveness watchdog (drop+count) | Landed (commit bc52f88 working tree) |

L9 is the *correctness* fix; L11 is the *liveness* fix. They are
independent — L11 must stay in tree even after L9 lands, as a belt-and-
braces against any edge case L9 doesn't cover (e.g. ASIC post-CTS
hold race that re-pulses `io_rx_reset`).

---

## 6. Sim run log — wedge primitive test (THIS DELIVERABLE)

### WITH L11 (current Build #8 RTL)

```
0.00ns INFO  cocotb.regression  running test_wedge_primitive_appears_and_l11_recovers (1/2)
6600.00ns INFO  cocotb.tb_top   Phase 0 role_locked: master=1 slave=1  (PASS)
8512580.00ns INFO  cocotb.tb_top   L11 PASS: wedge primitive appeared (17cy low),
                                   L11 recovered, dropped_cnt incremented 0->2.
8512580.00ns INFO  cocotb.regression  test_wedge_primitive_appears_and_l11_recovers passed
8512580.00ns INFO  cocotb.regression  running test_wedge_primitive_recovers_for_multiple_drops (2/2)
17022440.00ns INFO  cocotb.tb_top   PRE  M.tx_dropped_cnt_r=0
17023780.00ns INFO  cocotb.tb_top   after write #1 M.tx_dropped_cnt_r=2
17025380.00ns INFO  cocotb.tb_top   after write #2 M.tx_dropped_cnt_r=4
17026980.00ns INFO  cocotb.tb_top   after write #3 M.tx_dropped_cnt_r=6
17026980.00ns INFO  cocotb.tb_top   Multi-write L11 PASS: 6 drops over 3 writes (>= 3 ok).
17026980.00ns INFO  cocotb.regression  test_wedge_primitive_recovers_for_multiple_drops passed
** TESTS=2 PASS=2 FAIL=0 SKIP=0  17026980.00ns  727.48s  23405.40 ns/s **
```

### WITHOUT L11 (fc_adapter restored to git HEAD bc52f88 + 0 working-tree changes)

```
0.00ns INFO  cocotb.regression  running test_wedge_primitive_appears_and_l11_recovers (1/2)
8509840.00ns WARNING  AssertionError: Build #8 L11 RTL not present in tree.
  Missing signals: tx_dropped_cnt_r, wedge_cnt_r, wedge_force_ready_cnt_r.
  Verify src/rtl/tidelink_fc_adapter.sv lines 191-240 are intact (commit bc52f88).
8509840.00ns WARNING  test_wedge_primitive_appears_and_l11_recovers failed
8509840.00ns INFO  cocotb.regression  running test_wedge_primitive_recovers_for_multiple_drops (2/2)
17019700.00ns WARNING  AssertionError: Build #8 L11 RTL not present in tree.
17019700.00ns WARNING  test_wedge_primitive_recovers_for_multiple_drops failed
** TESTS=2 PASS=0 FAIL=2 SKIP=0  17019700.00ns  563.14s  30222.87 ns/s **
```

Both sub-tests guard on `_require_build8_l11(m_fc)` — the gating
assertion that fails immediately if `tx_dropped_cnt_r` /
`wedge_cnt_r` / `wedge_force_ready_cnt_r` are missing from the
hierarchy. This is the desired loud-failure mode: a future agent who
accidentally reverts L11 will get a clear pointer to commit bc52f88
and the file:line that needs restoring.

---

## 7. Risks and open items

| # | Risk | Mitigation |
|---|------|------------|
| R1 | L9 fast-forward could mask a real CRC error on the very first DATA pkt | L9 fires only once. If first pkt is corrupted, slave still advances `exp_pkt_num` to corrupt_pktnum+1, and the producer's replay protocol catches divergence on next ACK exchange. Acceptable risk; matches the L7 precedent. |
| R2 | `WlinkGenericFCSM_4.v` has identical structure but different state encoding | Audit before claiming full fix. The same `exp_pkt_num` race exists structurally; mirror the L9 patch into `_4.v` once `_6.v` is verified. |
| R3 | Build #6 erratum precedent: F-1.5 force-state synthesized into HREADYOUT-low pegging | L9 only touches `app_valid` / `exp_pkt_num` / `isNotExpPacket` — does NOT modify FCSM `state` directly. Different code locus, different failure mode. |
| R4 | Sim may not deterministically reproduce the race | The `app_enable` glitch is bringup-timing-dependent. The existing test_buga_real_fix_rx_wedge.py exercises the common case. For a deterministic test, force-deposit `io_app_enable=0` for 2 cycles immediately after CR/CRACK exchange to widen the race window. |

---

## 8. Constraints honoured

- [x] No RTL modified (this branch contains only the L11-restore from
      the on-branch stash and the new sim test; the L9 fix is design
      only).
- [x] `/research/AAA/ip_library/**` not touched.
- [x] `src/rtl/local_overrides/WlinkGenericFCSM_6.v` not touched
      (concurrent Bug C session may be editing it).
- [x] `src/rtl/tidelink_fc_adapter.sv` not touched in a behaviour-
      changing way — the L11 watchdog is preserved as the consumer
      agent shipped it.
- [x] No commits on `fix/bug-c-tx-starvation` (sibling work).
