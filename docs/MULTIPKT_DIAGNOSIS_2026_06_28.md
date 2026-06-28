# V2 A→B Multi-Packet — Diagnosis & Silicon Verdict (2026-06-28)

## Summary
The V2 A→B "multi-packet 3/16 stall" was traced to a **self-inflicted, never-committed
RTL bug**, not an FC-logic defect. After removing it, **short bursts deliver byte-exact**,
but **sustained back-to-back bursts still wedge on silicon** — the dominant blocker is the
**marginal A→B eye**, not the flow-control logic.

## Root cause (settled, multi-agent + RTL + sim)
- An uncommitted rev-1 "SOP-rising-edge gate" had been added to
  `src/rtl/local_overrides/WlinkGenericFCSM_6.v` (`socl_sop_pulse = _crc_corrupt_T &
  ~socl_sop_level_d1`), gating `pkt_is_data_pkt` / `valid_rx_pkt_crc_err`. The RX framer
  holds `auto_out_sop`/`valid` HIGH across a gapless burst (`WlinkRxLinkLayer.v:1158,1162`),
  so a rising-edge gate fires **once per burst** → only the first packet committed → 3/16.
- This gate was **never committed** (HEAD `04db833` is clean/ungated). It rode only in the
  dirty working tree and into the `2b3de7d`/`357c3d8` build.
- The exotic theories raised during triage (held-level per-beat over-advance, "5×
  over-advance") were **refuted in sim**: the existing in-order match
  (`ll_rx_pktnum == exp_pkt_num`, L478) self-limits constant-pktnum re-presentation; a
  clean burst presents one distinct real packet per beat and delivers all of them.

## Fix
Remove the gate → revert to clean HEAD (already the committed state). **No new RTL needed.**
Sim-gated by `test_v2_multipkt_pktnum`: **16/16 byte-exact both directions, 0 reverts,**
plus transient-NACK recovery — 4/4 PASS (`EPOCH_PROFILE=zero`).

## CRC stays OFF (silicon-refuted recommendation)
A sim-only analysis suggested enabling CRC. **Rejected**: `WlinkGenericFCSM_6.v:1122-1128`
records a silicon-confirmed fact — with `disable_crc=0`, V2 header-CRC saturates →
`SEND_NACK` → no enqueue (zero delivery). `out_prepend_swi_disable_crc` is used in exactly
one functional place (L429, the RX *check*); it does **not** alter TX packet format, so
mixing a CRC-on TX with a CRC-check-off RX is format-compatible.

## Silicon verdict (fast-path: die_b-clean RX + die_a-old TX)
The broken gate sits in the RX consume path, dormant on the A→B *transmitter*, so deploying
only **die_b-clean** as the receiver is a valid test:
- **4-word burst → 4/4 byte-exact** (vs 3/4 with the broken gate — the fix genuinely helps).
- **16-word back-to-back → wedge** (2 then 0; sticky, needs full re-POR to clear).

**Conclusion:** the fundamental sustained-multi-packet limiter is the **marginal A→B eye**
(sustained corruption → NACK → replay storm → credit exhaustion → wedge), not FC logic and
not the (secondary) broken gate. Short/single bursts deliver reliably byte-exact.

## Build note
`die_b` (flip) closes cleanly on the farm. `die_a` (pair-all) repeatedly **diverges in
Phase 7.3 hold-fix** (8-lane hard hold-closure) — an infrastructure/closure issue, not a
logic one. A clean die_a build is **not required** for the A→B test (gate dormant on TX).

## Sim coverage added
- `cocotb/tidelink_top_pair_v2/test_v2_multipkt_pktnum.py` — 16-word multipkt + exactly-once
  oracle (`l2a_wptr_advance==16`) + transient-NACK recovery + framer trace.
- `cocotb/tidelink_top_pair_v2/test_v2_heldvalid_pktnum.py` — boundary-force repro proving
  the in-order match self-limits constant-pktnum re-presentation (refutes held-level theory).
- `cocotb/tidelink_top_pair_v2/test_v2_ackdrain_qa.py` — ACK-drain experiment: bilateral
  ACKs drain the replay (16/16); blocking ACKs only throughput-caps (no storm by itself).

## Open / next
Sustained multi-packet requires **eye work** (the deep, recurring blocker): IDELAY re-tune
against the sustained data pattern, lower link rate, NACK-storm tolerance (re-anchor vs
revert), or chunked delivery with re-arm. See memory `project_live_link_state_2026_06_20_pm`.
