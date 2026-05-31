# Build #4 — Independent FCSM-Wedge Diagnosis (2026-05-29)

Author: Claude, independent blind triage. No BUILD4_* / FCSM_L7_* prior docs
were read. Sources consulted: `src/rtl/**`, `deps/axi-chiplet-controller/**`,
`fpga/insert_debug_core.tcl`. RTL is read-only — no edits made.

## 1. Summary of root-cause hypothesis (one paragraph)

Build #4 wedges because the master FCSM enters `SEND_NACK` (state 7) on a
transient `isNotExpPacket` notifier sourced from `ack_nack_fifo` during the
FC-bringup window, and cannot exit because the in-tree L7 "bringup forgive"
gate in `src/rtl/local_overrides/WlinkGenericFCSM_6.v` is structurally
conjunctive on `~reached_link_data` and never drains stale fifo entries.
Build B added `mark_debug` to `auto_tx_out_advance` (an input port of
`ShortPacketToWlink.v:11`) and to `auto_tx_out_sop` (line 6) — these are on
the TX-arbiter grant fan-out shared with the FCSM's own `ll_tx.advance` path.
`connect_debug_port` forces `DONT_TOUCH` on the marked nets, breaking the
fan-out sharing Vivado would otherwise have done across the 8 `txrouter`
ports. The resulting skew between FCSM-state register clocking and
`ll_tx.advance` fanout marginally re-orders the SEND_NACK→LINK_IDLE
transition relative to the `reached_link_data` latch, leaving forgive
permanently disarmed before `send_nack_req` has drained. The slave sits at
LINK_IDLE (4) because the master never transmits the NACK packet on the
link (it is wedged before `ll_tx.advance` fires).

## 2. RTL trace — FCSM state-7 entry/exit, send_nack_req lifecycle

**FCSM source of truth:** `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala`
(states defined at lines 38–46) and the elaborated/locally-patched Verilog
`src/rtl/local_overrides/WlinkGenericFCSM_6.v`. State encoding:
0=IDLE, 1=SEND_CREDITS1, 2=SEND_CREDITS2, 3=LINK_EN_WAIT, 4=LINK_IDLE,
5=LINK_DATA, 6=SEND_ACK, **7=SEND_NACK**. Observed HW: master FCSM = 7
(SEND_NACK), slave FCSM = 4 (LINK_IDLE).

**Entry to state 7** (FC.scala 505, 538, 586; Verilog `_GEN_76`, `_GEN_100`,
`_GEN_127`): from LINK_IDLE (4), LINK_DATA (5), or SEND_ACK (6), if
`send_nack_req` is high AND `auto_tx_out_advance` fires, nstate := SEND_NACK
and the packet is loaded with `swi_nack_id` as data_id.

**Exit from state 7** (FC.scala 571–575): the ONLY exit is
```
when(ll_tx.advance) { nstate := LINK_IDLE }
```
i.e. SEND_NACK is held until the TX link layer (`WlinkTxArbiter` → `WlinkLLTx`)
grants `auto_tx_out_advance` back to this FCSM port. There is no timeout, no
RX-side escape. **If the arbiter never grants advance, the FCSM is wedged
forever.**

**`send_nack_req` lifecycle** (FC.scala 408–409, 439; FCSM_6.v 1066–1080):
- Default set: `send_nack_req_in := Mux(send_nack_req, true, crcCorruptSeen | isNotExpPacket)` — sticky-high until LINK_IDLE.
- Cleared synchronously only on `state == LINK_IDLE` when the SEND_NACK packet has been emitted (FC.scala 507 `send_nack_req_in := false`).
- Sources of `isNotExpPacket`: `pkt_is_data_pkt && (ll_rx_pktnum =/= exp_pkt_num)` (FC.scala 211) — a single RX-pktnum hiccup during the bringup framing window enqueues a 3'h1 notifier in `ack_nack_fifo`, which fires `isNotExpPacket` for one cycle on rinc and latches `send_nack_req`.
- `crcCorruptSeen` is gated by `valid_rx_pkt_crc_err = valid_rx_pkt & (data_id == swi_data_id) & crc_corrupt` (FC.scala 167) — observed 0 in the wedge, so the latch source is `isNotExpPacket`.

**L7 forgive gate** (FCSM_6.v 380–387, 1066–1080):
```
socl_l7_bringup_forgive = (~reached_link_data) & cr_pkt_seen_tx_demet & crack_pkt_seen_tx_demet
isNotExpPacket_l7 = isNotExpPacket & ~bringup_forgive
send_nack_req <= (send_nack_req | (crcCorruptSeen | isNotExpPacket_l7)) & ~bringup_forgive
```
Mechanism intent: while bringup_forgive is high, both mask the source AND
AND-clear the latched bit every cycle. Disarms permanently once state==5
(LINK_DATA) is observed.

**Why this can still wedge:** the gate is conjunctive on `reached_link_data==0`.
If a brief RX byte-align glitch enqueues a 3'h1 notifier *and* the FCSM has,
even for one cycle, latched `reached_link_data` (e.g., during a transient
state==5 visit before falling back to SEND_NACK), the forgive gate disarms
permanently and the FCSM cannot drain. The wedge needs no actual corruption —
just a write into `ack_nack_fifo` that is rinc'd while `state != 0`
(rinc is `ack_nack_fifo_valid & state != 3'h0`, FCSM_6.v:736).

## 3. Ranked hypothesis bank

### H1 (highest, ~50%) — Stale ack_nack_fifo entry latching send_nack_req AFTER the L7 forgive gate has disarmed

**Mechanism:** during the initial credit handshake the RX framer can decode
one or two spurious data packets (PHY just locked, idelay tap settling).
`pkttypenotifier=3'h1` entries are pushed into `ack_nack_fifo`. Forgive
masks them while `reached_link_data==0`. But the FIFO is drained by
`rinc = ack_nack_fifo_valid & state != IDLE`. If state has progressed to
LINK_DATA at least once (latching `reached_link_data`) before the FIFO is
fully drained, the next rinc reads a stale 3'h1 entry, `isNotExpPacket_l7
= isNotExpPacket & ~bringup_forgive` is now `isNotExpPacket & 1` = full
strength, `send_nack_req` latches high, and no escape exists.

**Predicted signature on ILA:** `ack_nack_fifo` not-empty at the moment of
`send_nack_req` rising; `reached_link_data` is already 1; `state==5` briefly
visited before SEND_NACK; `isNotExpPacket` pulses one cycle exactly when
`send_nack_req` rises.

**Cheapest experiment:** flash the master with a hand-patched FCSM_6 where
the rinc gate also drops fifo entries during forgive
(`rinc = valid & state != IDLE & ~bringup_forgive`). Re-deploy. If the wedge
disappears, H1 confirmed.

### H2 (~25%) — mark_debug on auto_tx_out_advance + _sop in ShortPacketToWlink.v widens SEND_NACK→advance timing

**Mechanism:** `ShortPacketToWlink.v:11 auto_tx_out_advance` is a module
**input port** marked debug. `connect_debug_port` blocks the legal fan-out
merging Vivado would have done across `txrouter`'s 8-port grant fan-out
(`txrouter_auto_in_<n>_advance`). The FCSM-port `advance` no longer shares
routing/buffering with the ShortPacket-port `advance`, increasing skew
between FCSM `ll_tx.advance` rising and FCSM state-register clocking. On
SEND_NACK→LINK_IDLE this can race the next cycle's `send_nack_req` always
block. `ShortPacketToWlink.v:6 auto_tx_out_sop` is also marked debug.

**Cheapest experiment:** rebuild B with mark_debug removed from lines 6+11
of `ShortPacketToWlink.v`, keep the other 22 marks. If wedge clears, H2 holds.

### H3 (~15%) — dbg_hub BRAM-induced supply droop near tx_link_clk

Build B inserts `u_dbg_int` with `C_DATA_DEPTH=4096` and ~190 probes.
BRAM capture-side activity in the same clock region as
`phy_link_tx_tx_link_clk` can shrink the FCSM register setup margin during
the first ~100 µs post-PHY-lock window. Wedge probability correlates with
capture-arm timing vs PHY lock. **Experiment:** rebuild with
`C_DATA_DEPTH=1024` and half the probes. If 3/5 wedge rate → 0/5, H3 holds.

### H4 (~7%) — Returner_busy is a separate bug, not the FCSM wedge cause

`returner_busy = (state_r != ST_IDLE)` (`fifo/tidelink_returner.sv:96`)
sticks high if an inbound AHB write hangs (no hready). Independent of the
FCSM wedge but explains why `REG_STATUS bit 0` stays 1.
**Experiment:** ILA-probe returner `state_r` to disambiguate.

### H5 (~3%) — mark_debug on tx_fifo_io_wfull/rempty propagates DONT_TOUCH into shared WavFIFO_21 dedup, corrupting ack_nack_fifo
Low probability — wrong FIFO instance, but worth checking since both share
the parameterised module.

## 4. Proposed RTL fix(es)

I am read-only on RTL per the task brief. The following are *proposed* fixes,
not applied.

**Fix A (preferred — addresses H1 directly, low blast radius):** add a
synchronous drain of `ack_nack_fifo` while forgive is active. In
`src/rtl/local_overrides/WlinkGenericFCSM_6.v` line 736:
```
- assign ack_nack_fifo_io_rinc = ack_nack_fifo_valid & state != 3'h0;
+ assign ack_nack_fifo_io_rinc = ack_nack_fifo_valid & (state != 3'h0 | socl_l7_bringup_forgive);
```
plus mask the wdata side from latching `send_nack_req` while forgive holds.
This guarantees no stale fifo entry can survive past `reached_link_data` rising.

**Fix B (defensive — addresses H1+H2 by making SEND_NACK self-recovering):**
add a SEND_NACK timeout in FCSM_6.v's state-7 branch. After N (e.g. 1024)
cycles in state==7 with `ll_tx.advance==0`, force `nstate := LINK_IDLE`
and `send_nack_req <= 0` regardless of forgive. Treat it as a recovery
escape rather than relying on the txrouter granting advance.

**Fix C (orthogonal — kill H4):** make `returner_busy` clear on master_error
latching so SW doesn't see a permanently stuck busy bit when AHB
back-pressure persists.

Independently of the RTL fix, the **immediate operational mitigation** for
Build #4 is to revert the 4 `mark_debug`s on `ShortPacketToWlink.v` TX-side
nets (lines 6, 11, 34, 35) — these touch the FCSM-adjacent TX arbiter
fan-out and are the most causally adjacent to the wedge. The 20 other
`mark_debug`s on observation-only signals can stay.

## 5. What evidence would change my mind?

- **Falsifies H1:** ILA shows `ack_nack_fifo_io_rempty` is high (not-empty
  count = 0) at the moment `send_nack_req` rises. If the FIFO is empty,
  the latch came from a live `isNotExpPacket` pulse, not a stale entry,
  and the gate weakness is timing-only (shifts probability to H2).

- **Falsifies H2:** rebuilding B with the 4 TX-side marks removed still
  produces the wedge at the same 3/5 rate. Then the wedge is not synth-input
  sensitive in that specific way; H1 or H3 jumps to top rank.

- **Falsifies L7-gate frame entirely:** ILA shows `forgive==1` and
  `send_nack_req==1` simultaneously in steady state — gate is armed but
  not draining, indicating a synth bug in the override, not gate logic.

- **Promotes H3:** Vivado util report shows `u_dbg_int` BRAM placed in
  the same clock region as `phy_link_tx_tx_link_clk`, and reducing ILA
  depth eliminates the wedge.

- **Totally different cause:** rerunning Build A (dda0a0e, no ILA) today
  also wedges — then the bug is not synth-input-sensitive (env drift,
  PHY temperature, etc.) and the A/B comparison is misleading.

---

**Follow-up step request:** I'd like to compare this independent diagnosis
against any prior analyses (BUILD4_* / FCSM_L7_* docs) once handed off, to
calibrate which of H1/H2/H3 the prior team converged on and what mitigation
they actually shipped. The current-tree comment at
`src/rtl/fifo/tidelink_apb_regs.sv:317` ("BUILD #5: mark_debug REMOVED …")
strongly suggests at least one prior diagnosis pointed at mark_debug-induced
synth-fold loss on the `pclk`-domain APB-regs side — a class adjacent to H2
above but on a different module. Cross-referencing would clarify whether
my mark_debug-on-tx-advance hypothesis (H2) was considered and ruled out,
or simply not yet examined.
