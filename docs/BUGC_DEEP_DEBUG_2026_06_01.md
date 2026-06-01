# Bug C Deep-Debug — cycle-by-cycle slave RX probe (2026-06-01)

Branch: `sim/bugc-deep-debug`
Probe test: `cocotb/tidelink_top_pair/test_bugc_link_layer_probe.py`
Sim build: `cocotb/tidelink_top_pair/sim_build_bugc_probe/`
Repro: `make MODULE=test_bugc_link_layer_probe TESTCASE=test_bugc_link_layer_probe SIM_BUILD=sim_build_bugc_probe TB_TOP_NO_DUMP=1`
Sim runtime: 8.8 ms simulated / 212 s wall.

## §1 — Symptom classification: **B (FCSM consumer-side)**

The probe captures hierarchical slave-side signals on every `hclk` edge
for the entire 100-doorbell M→S window. The end-of-run summary:

```
s_auto_rx_in_valid          = 14948    -- LL_RX delivers packets cleanly
s_auto_rx_in_sop            = 14948    -- (sop is an alias for valid in WlinkRxLinkLayer.v:933)
s_pkt_is_data_pkt           = 14020    -- 93% classified as DATA (data_id==swi_data_id_1==0xa1)
s_crc_corrupt               =     0    -- zero CRC errors -> PHY is clean
s_l2a_fc_replay_app_valid   =     0    -- *** NEVER FIRES ***
s_tl_fc_l2a_valid           =     0    -- (downstream confirmation)
s_send_nack_req_rises       =  1135    -- NACK storm
s_send_ack_req_rises        =     0    -- *** NEVER ACKs A DATA PKT ***
s_resync_now_pulses         =     0    -- L9 NEVER fires post-bringup
m_pkt_is_nack               =  7292    -- master receives the NACK storm
post-traffic: m_state=5 s_state=4 m_exp_pktnum=0 s_exp_pktnum=0
              m_first_seen=1 s_first_seen=1 s_send_nack_req=1
```

Classification per the agent-task taxonomy: PHY delivers (`pkt_is_data_pkt`
fires 14020× cleanly, `crc_corrupt=0`), but `l2a_fc_replay_app_valid`
NEVER asserts. This is **case B** — FCSM consumer-side.

## §2 — Root cause: L9 is a strict one-shot; `exp_pkt_num` is permanently
stuck at 0 after the first data-pkt that L9 fires on.

### §2.1 — `l2a_fc_replay_app_valid` gating

`src/rtl/local_overrides/WlinkGenericFCSM_6.v:810-811`:

```verilog
assign l2a_fc_replay_app_valid = (pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num)
                                | socl_l9_resync_now;
```

This is high only when:
- (a) the incoming pktnum matches the locally-expected pktnum, OR
- (b) the L9 resync pulse is firing.

### §2.2 — `exp_pkt_num` always-block (`...L9_6.v:980-998`)

```verilog
always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
        exp_pkt_num <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin       // <-- ~en_ff2_rx_demet_io_out
        exp_pkt_num <= 8'h0;                          //     (sync-de-asserted app_enable)
    end else if (socl_l9_resync_now) begin           // <-- L9 fast-forward
        if (ll_rx_pktnum == fe_tx_credit_max) ...
        else exp_pkt_num <= ll_rx_pktnum + 8'h1;
    end else if (exp_pkt_seen) begin                 // <-- normal advance
        ...
    end
end
```

### §2.3 — `socl_l9_first_data_seen_rx` is sticky-POR-only
(`...L9_6.v:1003-1009`)

```verilog
always @(posedge io_rx_clk or posedge reset) begin    // <-- reset = POR
    if (reset) begin
        socl_l9_first_data_seen_rx <= 1'h0;
    end else begin
        socl_l9_first_data_seen_rx <= pkt_is_data_pkt | socl_l9_first_data_seen_rx;
    end
end
```

Note the reset domain: `reset` (POR) vs `io_rx_reset` (LL-swreset bootstrap).
**These are different resets.** During bringup, `to_data_mode()` pulses
`io_rx_reset` (via the `0x208` swreset bit) BUT does not pulse the POR
`reset`. Result: `socl_l9_first_data_seen_rx` can be left high while
`exp_pkt_num` gets re-zeroed by the bootstrap swreset window. L9 is now
permanently disarmed.

### §2.4 — The exact sequence that wedges

1. POR de-asserted. `first_data_seen_rx=0`, `exp_pkt_num=0`.
2. Bringup: CR/CRACK exchange, `state → 4` (LINK_DATA).
3. First data pkt observed (say pktnum=0): `socl_l9_resync_now=1`,
   `l2a_fc_replay_app_valid=1` (one cycle), `exp_pkt_num <= 1`,
   `first_data_seen_rx <= 1`.
4. Bootstrap window: `to_data_mode()` writes `0x208 = 0x...f08` (swreset
   pulse) somewhere in the bringup sequence. `io_rx_reset` fires →
   `exp_pkt_num <= 0`. BUT `first_data_seen_rx` (POR-domain) stays 1.
5. Post-bringup doorbell traffic: master sends pktnums 1, 2, 3, ...
   slave's `exp_pkt_num=0` permanently. `exp_pkt_seen` NEVER true.
   Every data pkt classifies as `exp_pkt_not_seen` → NACK.
6. Master receives NACK, replays from `link_revert_addr` → same pktnums
   come back → slave NACKs again → death spiral.

The probe shows pktnum cycling 1, 2, 3, 4 repeatedly (~13 replays of each
in the 5000-cycle settle window). Consistent with NACK replay loop.

### §2.5 — Why L9 (commit 6df28e2) did not fix this

L9's design (per `docs/BUG_A_L9_FIX_DESIGN_2026_05_31.md` §2) was correct
for the case where the FIRST data pkt arrives with a non-zero pktnum
because the peer's TX-side pktnum counter was already advanced. L9
correctly handles that case ONCE.

What L9 missed: the trigger isn't "have we ever seen a data pkt" — it's
"is exp_pkt_num currently desynchronised from the peer's TX counter."
After ANY post-bringup event that zeroes exp_pkt_num (notably an
`io_rx_reset` swreset pulse), L9's sticky correctly fires once and stays
locked, leaving exp_pkt_num at 0 forever.

The probe data confirms this: `socl_l9_first_data_seen_rx=1` at probe
start (before any doorbell traffic), `socl_l9_resync_now_pulses=0` over
the entire 8.8 ms run. L9 is dormant when it would actually help.

## §3 — Patch design (minimal, sim-ready)

**Locus**: `src/rtl/local_overrides/WlinkGenericFCSM_6.v` lines 1003-1009
(`socl_l9_first_data_seen_rx` always block) AND lines 980-998
(`exp_pkt_num` always block).

**Goal**: make L9 RE-ARM whenever `exp_pkt_num` gets reset, so the next
observed data pkt fast-forwards exp_pkt_num to its correct value.

### §3.1 — Patch A (RECOMMENDED): change `first_data_seen_rx` reset domain
to match `exp_pkt_num` (so the two regs are guaranteed to clear together)

**Before** (`WlinkGenericFCSM_6.v:1003-1009`):

```verilog
always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
        socl_l9_first_data_seen_rx <= 1'h0;
    end else begin
        socl_l9_first_data_seen_rx <= pkt_is_data_pkt | socl_l9_first_data_seen_rx;
    end
end
```

**After**:

```verilog
// SoC Labs L9b (2026-06-01): bind first_data_seen_rx reset domain to
// io_rx_reset (matching the exp_pkt_num always block at L980).  Without
// this, an LL-swreset pulse during bringup re-zeros exp_pkt_num while
// leaving the POR-domain sticky high -> L9 is permanently disarmed at
// exactly the moment it's needed.  Also re-arm on the sync app-enable
// demet de-assertion, which is the other path that re-zeros exp_pkt_num.
// See docs/BUGC_DEEP_DEBUG_2026_06_01.md §2.
always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
        socl_l9_first_data_seen_rx <= 1'h0;
    end else if (_fe_tx_credit_max_in_T) begin
        // exp_pkt_num is being re-zeroed sync (app-enable demet low) --
        // also re-arm L9 so the next observed data pkt fast-forwards.
        socl_l9_first_data_seen_rx <= 1'h0;
    end else begin
        socl_l9_first_data_seen_rx <= pkt_is_data_pkt | socl_l9_first_data_seen_rx;
    end
end
```

Both reset sources used here exactly match the two zero-paths in the
exp_pkt_num always block at L980-984 (io_rx_reset, _fe_tx_credit_max_in_T),
guaranteeing the two regs clear together.  POR is still implicit via the
io_rx_reset wiring (TideLinkToWlink.v:168 routes Wlink's io_rx_reset which
includes POR + swreset).

### §3.1.1 — Patch A-minimal alternative

If the reset-domain change is considered too invasive, the smaller change
is to add only the synchronous re-arm term (keeping POR reset):

```verilog
always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
        socl_l9_first_data_seen_rx <= 1'h0;
    end else if (_fe_tx_credit_max_in_T) begin
        socl_l9_first_data_seen_rx <= 1'h0;       // NEW: sync re-arm
    end else begin
        socl_l9_first_data_seen_rx <= pkt_is_data_pkt | socl_l9_first_data_seen_rx;
    end
end
```

This handles only the `_fe_tx_credit_max_in_T` path. If the bringup-time
zeroing is actually triggered by `io_rx_reset` (swreset pulse) rather than
`_fe_tx_credit_max_in_T`, this alternative is INSUFFICIENT.  Recommend
Patch A (full) over Patch A-minimal until §3.2 step 3 confirms which path
is the culprit.

### §3.2 — Sim verification plan

1. Apply Patch A (single-term `_fe_tx_credit_max_in_T` variant) to
   `src/rtl/local_overrides/WlinkGenericFCSM_6.v:1003-1009`.
2. Re-run `make MODULE=test_bugc_link_layer_probe TESTCASE=test_bugc_link_layer_probe`.
3. Expected post-patch stats:
   - `s_l2a_fc_replay_app_valid > 0`
   - `s_resync_now_pulses >= 1` (one resync per app_enable cycle)
   - `s_send_nack_req_rises` drops dramatically (target: < 10)
   - `m_pkt_is_ack > 0`, `m_pkt_is_nack` drops dramatically
4. Re-run `test_bug_c_doorbell_asymmetry.py::test_bugc_01_master_to_slave_100`:
   `s_db_after > s_db_before` should now hold (slave DOORBELL_RESP_ACC ticks).
5. Re-run `test_bug_a_master_tx_wedge.py` to ensure no regression on the
   L11 watchdog test (which already passes — should still pass).

## §4 — L9 disposition recommendation

**MODIFY**, do not revert.

L9's `socl_l9_resync_now` + `l2a_fc_replay_app_valid` OR-term + the
`exp_pkt_num` fast-forward branch are all CORRECT and necessary. The
only defect is the strict one-shot semantics of `first_data_seen_rx`.
The minimal fix is the re-arm patch above (one `else if` branch),
which preserves all of L9's existing behaviour for the post-POR-first-
data case and additionally handles the post-bringup-swreset case.

Reverting L9 would re-open Bug A on the FIRST-data-pkt case (where the
peer's TX pktnum had already advanced past 0).

## §5 — Open questions (NOT addressed here — for follow-up)

- The probe shows `pkt_is_data_pkt` firing for multiple consecutive
  cycles per packet body (`auto_rx_in_sop=auto_rx_in_valid` are
  asserted together for entire packet body length per
  `WlinkRxLinkLayer.v:933`). After the post-patch fix, exp_pkt_num will
  advance on the FIRST body cycle, then the next body cycles will still
  have `pkt_is_data_pkt=1` with the OLD pktnum -> `exp_pkt_seen=0`,
  `exp_pkt_not_seen=1`. This is the same shape as the current bug but
  one cycle later. Need to verify whether this triggers spurious NACKs
  too. If so, the additional fix is to OR-mask `exp_pkt_not_seen` with a
  "this is the same pkt I just consumed" sticky.
  → Verify in §3.2 step 3 (s_send_nack_req_rises count). If it's
  non-trivial post-patch, add Patch B: gate `exp_pkt_not_seen_l9b` with
  `~(exp_pkt_num == ll_rx_pktnum + 1)` (same-pkt-replay guard).

- The probe's pre-traffic snapshot shows `s_first_seen=1` already at
  the start. This means a pkt was observed during `_ensure_training_off`
  or `run_bringup_full`. Trace which exact event sets it (likely the CR
  pkt during cr-handshake -- but CR is not classified as data_pkt per
  `pkt_is_cr_pkt` vs `pkt_is_data_pkt` taxonomy). Add explicit
  early-window probe for completeness.

## §6 — File pointer summary

- Probe test: `/home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair/test_bugc_link_layer_probe.py`
- Probe sim build: `/home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair/sim_build_bugc_probe/`
- Patch file (target): `/home/dam1n19/SoCLabs/tidelink/src/rtl/local_overrides/WlinkGenericFCSM_6.v`
  lines 1003-1009 — add `else if (_fe_tx_credit_max_in_T)` re-arm branch.
- Existing L9 patch: commit `6df28e2` (keep, modify as above)
- Existing L11 watchdog: commit `78d4b7f` (keep, do not touch)
- Existing F-1 watchdog: commit `f5633f1` (keep, do not touch)
