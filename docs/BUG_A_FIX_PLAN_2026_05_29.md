# Bug A — fix plan (L8 consumer-side LINK_IDLE forgive)

**Date:** 2026-05-29
**Author:** Bug A investigation (RTL audit only; sims NOT run, RTL NOT modified)
**Files written (all docs/test, no RTL):**
- `docs/BUG_A_PROPOSED_FIX_2026_05_29.patch` — proposed unified diff
- `cocotb/tidelink_top_pair/test_buga_fix_link_data_consumer.py` — regression test
- `docs/BUG_A_FIX_PLAN_2026_05_29.md` — this document

---

## 1. Root cause (recap)

From `docs/BUG_A_FORCE_EXPERIMENTS_2026_05_29.md` (T5 verdict) and the build #3 HW datapoint:

| die | FCSM `state` post-bringup |
|---|---|
| master | 5 (`LINK_DATA`) in sim; 4 (`LINK_IDLE`) on HW build #3 |
| slave  | 4 (`LINK_IDLE`) in sim AND on HW |

Master drives `tl_fc_a2l_valid` HIGH for 2126 sustained cycles in T5, but
slave `tl_fc_l2a_valid` stays 0 and slave `REG_PKT_WORD_LEN` reads 0. The
slave's RX framer is structurally healthy (CR/CRACK exchange completed;
`cr_pkt_seen_rx = crack_pkt_seen_rx = 1`); the problem is that the FCSM
itself is stuck at LINK_IDLE.

---

## 2. RTL location of the bug

**File:** `src/rtl/local_overrides/WlinkGenericFCSM_6.v`
**Behaviour origin:** Chisel source
`deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala:501-532`

### The state-machine slice

```
always @(posedge io_tx_clk or posedge io_tx_reset) begin   // line 762
  if (io_tx_reset)        state <= 3'h0;
  else if (_fe_rx_ptr_in_T) state <= 3'h0;
  else if (_ack_seen_before_T) begin
    if (en_ff2_tx_demet_io_out) state <= 3'h1;
  end
  else if (state == 3'h1) ...   // L6 fix lives here
  else if (state == 3'h2) state <= _GEN_51;
  else                  state <= _GEN_181;    // covers states 3,4,5,6,7
end
```

Tracing `_GEN_181 -> _GEN_177 -> _GEN_76 -> _GEN_67 -> _GEN_60`:

```
// line 430
wire [2:0] _GEN_60 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 3'h5 : state;
// line 436
wire [2:0] _GEN_67 = send_ack_req & _T_54 ? 3'h6 : _GEN_60;
// line 444
wire [2:0] _GEN_76 = send_nack_req ? 3'h7 : _GEN_67;
// line 514
wire [2:0] _GEN_177 = state == 3'h4 ? _GEN_76 : _GEN_166;
```

**The LINK_IDLE -> LINK_DATA (4 -> 5) transition fires ONLY on
`a2l_fc_replay_link_valid && ~fe_rx_is_full`.** This is a producer-side
gate: the FCSM moves to LINK_DATA only when *this die's own application*
has FC data ready to send. There is **no consumer-side trigger**: when
the peer is sending data and we are at LINK_IDLE with no TX of our own,
we never advance to LINK_DATA.

Upstream Chisel comment at FC.scala:565-566 confirms this is the natural
fall-back: at the end of state 5, if no TX work remains, `nstate :=
LINK_IDLE` — so state 4 is the "resting" state and state 5 is the "I am
emitting data right now" state.

The bug is that the **RX framer needs the FCSM to be in state 5 (LINK_DATA)
to maintain the SOP/data_id/word_count regs in the configuration the
upstream Wlink expects for ack-with-credit handshakes**. Empirically (T5
and HW build #3) confirms the slave wedges with `tl_fc_l2a_valid = 0` and
`REG_PKT_WORD_LEN = 0` while master pumps 2126 cycles of valid data into
the link.

### Existing L7 fix (producer side, already in tree)

`src/rtl/local_overrides/WlinkGenericFCSM_6.v:380-387,1063-1090` — clears
`send_nack_req` during bringup when CR/CRACK have completed but state 5
has not yet been seen. Identical "structurally healthy" gate condition
to what L8 needs; L8 is the consumer-side analogue on the state-4 branch.

---

## 3. Proposed fix (L8)

**Diff file:** `docs/BUG_A_PROPOSED_FIX_2026_05_29.patch`

In one paragraph: add a sticky bit `socl_l8_peer_data_seen_rx` (set on
`pkt_is_data_pkt`, POR-only clear, mirrors the L6 cr/crack sticky pattern)
and 2-flop sync it into the `io_tx_clk` domain. Compute a forgive gate
`socl_l8_consumer_data_ready = cr_seen & crack_seen & peer_data_seen &
~send_nack_req & ~socl_l7_bringup_forgive & ~socl_l8_reached_link_data`.
Override `_GEN_60` so that when the gate fires, state==4 advances to 5
regardless of `a2l_fc_replay_link_valid`. Latch
`socl_l8_reached_link_data <= 1` on first observation of state==5 to
permanently disarm — steady-state behaviour matches upstream.

The patch adds ~30 lines and modifies one expression (`_GEN_60`). All
other state-4/5/6/7 logic is untouched.

---

## 4. Regression test

**File:** `cocotb/tidelink_top_pair/test_buga_fix_link_data_consumer.py`

Two tests:

1. **`test_buga_fix_slave_advances_to_link_data`** — drive master AHB write,
   assert slave FCSM advances 4 -> 5 within 4096 cycles, slave
   `tl_fc_l2a_valid` asserts >= 1 cycle, slave APB
   `REG_PKT_WORD_LEN != 0`.
2. **`test_buga_fix_l7_send_nack_still_clears`** — sanity that L8 did not
   regress L7: after AHB write, both peers' `send_nack_req == 0` and
   `socl_l7_reached_link_data == 1`.

Run command (NOT executed in this session):

```bash
source /home/dam1n19/SoCLabs/tidelink/set_env.sh
cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
timeout 1200 make MODULE=test_buga_fix_link_data_consumer \
    SIM_BUILD=sim_build_buga_fix TB_TOP_NO_DUMP=1
```

---

## 5. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | L8 sticky `socl_l8_peer_data_seen_rx` latches on a spurious bringup mis-decode (e.g. mid-byte mis-aligned framer decodes a CR as data). | Gated by `cr_pkt_seen_tx_demet_io_out & crack_pkt_seen_tx_demet_io_out` so cannot fire until CR/CRACK have completed. Additionally gated by `~socl_l7_bringup_forgive` so L8 waits until L7 has retired its NACK-clear window. |
| R2 | L8 interferes with the natural state-5 fall-back (line 565 of FC.scala): if FSM thrashes 4 <-> 5 because L8 forces 5 every cycle. | `socl_l8_reached_link_data` sticky disarms the gate after first observation of state==5, so the natural fall-back behaviour resumes and the FSM cannot re-fire via L8. |
| R3 | L8 breaks the L7 fix. | L8 does NOT modify the `send_nack_req` always-block (lines 1066-1080) and AND-clauses `~send_nack_req` into its own condition — the two gates are orthogonal. The companion regression test `test_buga_fix_l7_send_nack_still_clears` catches this. |
| R4 | Startup CR/CRACK exchange itself is broken by L8 (e.g. peer enters state 5 before CRACK fully observed). | L8 is gated on the L6 `crack_pkt_seen_tx_demet_io_out` — same sticky that gates the existing L6 state-1 exit. Cannot fire before CRACK is logically complete. |
| R5 | **`WlinkGenericFCSM_4.v` has similar structure but different state encoding** — if the pair link also instantiates FCSM_4, only patching FCSM_6 leaves a partial fix. | **Action required:** Audit FCSM_4 before claiming the bug is fully fixed. The current handoff says FCSM_6 is the FCSM used in the pair link (confirmed by the hierarchical-ref path `u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl` instantiating FCSM_6). |
| R6 | Upstream patch needed. The local_override file is what the flist sources; upstream `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v` is NOT touched by this patch. | **See recommendation §6.** |
| R7 | The state==4 branch is GENERATED Verilog — node names (`_GEN_60`, `_GEN_177`) are Chisel-emitted and may renumber if FC.scala is regenerated. | Patch uses **named overrides** (declares `socl_l8_*` regs/wires) and overrides only the single `_GEN_60` expression. If upstream regen renames, a small re-targeted edit will be needed; the L7 patch already lives in a state where any FC.scala regen would require manual reconciliation. |

---

## 6. Recommendation

**Apply the patch to `src/rtl/local_overrides/WlinkGenericFCSM_6.v` only.**

Reasoning:
- The local_override file is what the build flist sources for tidelink
  (per the L6/L7 commits already in this file).
- Touching the upstream copy (`deps/axi-chiplet-controller/...`) is more
  invasive, causes a submodule pointer churn, and is unnecessary unless
  we want to land L8 in the upstream wav-wlink-hw repo. Defer that
  upstream PR until L8 is HW-validated.
- Per `feedback_research_ip_library_readonly` memory entry: NEVER touch
  `/research/AAA/ip_library/**` — that path is read-only.

**Next steps after applying the patch:**
1. Run `test_buga_fix_link_data_consumer.py` in sim. Expect both tests
   PASS.
2. Run the existing Bug A force experiments (`test_fc_tx_force_experiments
   .py`) and confirm T3/T5 verdicts now show slave `tl_fc_l2a_valid > 0`.
3. Run the full FCSM regression (`test_fcsm_state_asymmetry.py` and the
   wlink_pair fuzz scenarios) — confirm no regression on L6/L7.
4. Audit `WlinkGenericFCSM_4.v` for the equivalent fix.
5. If sim passes, build for FPGA and re-deploy build #5 with L8 RTL
   only — leave the build #4 ILAs out (per
   `BUILD4_HW_VALIDATION_2026_05_29.md` warning that ILAs regressed
   build #4 to M=7, S=7).
6. On a passing build, write the upstream patch against
   `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala`
   (the Chisel root, not the generated Verilog) for the eventual upstream
   contribution.

---

## 7. File map

| Purpose | Path |
|---|---|
| Proposed RTL patch (NOT applied) | `docs/BUG_A_PROPOSED_FIX_2026_05_29.patch` |
| Regression test (NOT run) | `cocotb/tidelink_top_pair/test_buga_fix_link_data_consumer.py` |
| Fix plan (this doc) | `docs/BUG_A_FIX_PLAN_2026_05_29.md` |
| Background (root-cause) | `docs/BUG_A_FORCE_EXPERIMENTS_2026_05_29.md` |
| Background (sideband-arbiter detour, falsified by T5) | `docs/BUG_A_FINAL_SYNTHESIS_2026_05_29_EVENING.md` |
| L7 fix (in tree, do not regress) | `src/rtl/local_overrides/WlinkGenericFCSM_6.v:1-70, 380-387, 1063-1090` |
| L6 fix (in tree, do not regress) | `src/rtl/local_overrides/WlinkGenericFCSM_6.v:71-111, 373-374, 902-915` |

---

## 8. Constraints honoured

- [x] RTL NOT modified (only a `.patch` doc written).
- [x] `/research/AAA/ip_library/**` NOT touched.
- [x] Sims NOT run.
- [x] No commits made.
- [x] `src/rtl/`, `deps/` read-only.
- [x] New files only under `docs/` and
      `cocotb/tidelink_top_pair/test_buga_fix_*.py`.
