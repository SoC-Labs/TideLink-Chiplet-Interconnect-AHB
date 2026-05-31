# Build #5 Returner / Doorbell M→S Independent RTL Trace

Branch: `fix/fcsm-l7-wedge-watchdog-build5-hw` @ `f10e6fe`
Scope: returner_busy lifecycle, doorbell M→S delivery path, downstream-of-FCSM
back-pressure analysis. Read-only RTL inspection. No prior `docs/FCSM_L7_*`,
`docs/BUILD4_*`, `docs/BUILD5_*` content consulted.

---

## 1. returner_busy lifecycle

File `src/rtl/fifo/tidelink_returner.sv`.

* `busy` is the **state register** itself: `assign busy = (state_r != ST_IDLE);`
  (line 96). There is no separate latch — busy=1 simply means the FSM is in
  `ST_ADDR_PHASE` or `ST_DATA_PHASE`.
* Set path: `state_r <= ST_ADDR_PHASE` when `any_pending` is true while in
  `ST_IDLE` (lines 173-176). `any_pending = pending_0 | pending_1 | pending_2`
  is the OR of the three latched interrupt requests (line 94).
* Clear path: state returns to `ST_IDLE` when in `ST_DATA_PHASE` with `hready`
  high AND either `hresp=0` OR `retry_count_r >= RETRY_COUNT` (lines 181-188).
* **The clear is purely local.** It depends only on the returner's own AHB
  master `hready`/`hresp` lines — no peer ACK, no Wlink credit, no slave APB
  write completion. The returner does not "know" if the sideband actually
  reached the far side.
* Latch-high-forever path: if the upstream consumer of the returner's AHB
  master port never asserts `hready=1` while the FSM is in `ST_DATA_PHASE`,
  the FSM is wedged in `ST_DATA_PHASE` indefinitely with `busy=1`.

Where does the returner's AHB master port go? It is wired to the **FC
adapter's returner-interception slave port** (`tidelink_top.sv:1048-1055` →
`tidelink_fc_adapter.sv:65-72`). The `rtn_hready` returned to the returner is
generated combinationally inside the FC adapter:

```
src/rtl/tidelink_fc_adapter.sv:245
    assign rtn_hready = rtn_pending_r ? skid_can_accept : 1'b1;
```

`skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready;` (line 380). So
**`rtn_hready` is held LOW exactly when the skid buffer is full AND
`tl_fc_a2l_ready` from the Wlink FC node is LOW.**

That is the single signal that can wedge `returner_busy` high indefinitely:
**the Wlink FC node (TideLink data port) not draining the outbound 48-bit
words.**

---

## 2. Doorbell M→S path trace

APB write → returner → FC adapter → Wlink FC node → peer FC adapter → peer
APB regs.

1. **CPU writes APB offset `0x014`** (DOORBELL). Decoded in
   `tidelink_apb_regs.sv:204-213` as `apb_region == 4'b0000 && paddr[4:2] ==
   3'h5`. Asserts a single-cycle `doorbell_trigger` pulse (line 210).
2. `doorbell_trigger` enters the returner as **channel-1**
   (`tidelink_fifo.sv:319`). `PAIR_DOORBELL_RESPONSE_ADDR =
   pair_base_addr + 0x024` is the target (lines 180, 320).
   `credit_count_data` is the payload (`tidelink_fifo.sv:321`).
3. Returner FSM (priority `0>1>2`, `tidelink_returner.sv:124-128`) drives an
   AHB write to `0x24` offset.
4. FC adapter intercepts the AHB write, latches the 14-bit address offset
   (`tidelink_fc_adapter.sv:223-238`), forms a 48-bit FC word
   `{PKT_SIDEBAND, rtn_addr_latched_r, rtn_hwdata}` (line 241),
   asserts `rtn_fc_valid = rtn_pending_r` (line 242).
5. Arbiter (`tidelink_fc_adapter.sv:368-373`) gives the returner sideband
   highest priority. Word lands in a 1-entry skid buffer (lines 376-396) and
   then on the bus `{tl_fc_a2l_valid, tl_fc_a2l_data}` (lines 399-400).
6. Skid buffer drains when `tl_fc_a2l_ready` rises. **`tl_fc_a2l_ready` is
   sourced by the Wlink TideLink FC node** (`tidelink_top.sv:1955-1957`,
   inside `axi_chiplet_controller` / Wlink). The FCSM owns the upper-layer
   pkt-num / CR-credit machinery that governs whether the data port can
   accept a new LL packet.
7. Wlink LL transports the 48-bit beat to the slave. Slave FC adapter
   `tl_fc_l2a_valid/data` → `rx_state_r` FSM
   (`tidelink_fc_adapter.sv:417-508`) decodes `rx_pkt_type == PKT_SIDEBAND`
   (line 433).
8. SIDEBAND drives a single-beat APB write on the local config bus
   (`tidelink_fc_adapter.sv:519-529`), `fc_rx_cfg_paddr = 0x024`,
   `fc_rx_cfg_pwdata = <credit_count payload>`.
9. Slave `tidelink_apb_regs.sv:294-311` decodes `apb_region==4'b0001 &&
   paddr[4:2]==3'h1` (offset 0x024) and adds the payload to
   `doorbell_response_acc[15:0]` (saturating-add).

So **the slave's `DOORBELL_RESP_ACC` will increment IFF the FC word actually
crosses the Wlink data port.** Nothing on the slave side blocks the
APB-side accumulation — `acc1_write` is gated only on `apb_write && region
1 && addr 1`. If `DOORBELL_RESP_ACC == 0` after 100 master rings on healthy
build #3 silicon, **the FC word never left the master**, i.e. step 6 stalled.

That is consistent with the master-side observation
`returner_busy = 1` sticky: returner is parked in `ST_DATA_PHASE` waiting
for `rtn_hready`, which is waiting for `skid_can_accept`, which is waiting
for `tl_fc_a2l_ready`.

---

## 3. Why a state-7 visit could poison downstream LL state

The F-1 watchdog clears `send_nack_req` (the request to *emit* a NACK packet)
after 4096 cycles in state 7. But state 7 has other side-effects on
**upstream-of-FCSM** packet-replay / credit-window machinery that the
watchdog does NOT undo:

* `_GEN_152 = (state == 3'h7) ? last_ack_pkt_sent : ...`
  (`WlinkGenericFCSM_6.v:414`). On entry to state 7 the FCSM rewinds
  `ne_rx_ptr` and related retry pointers to `last_ack_pkt_sent`, repurposing
  the TX side to retransmit from the last good ack. Force-clearing
  `send_nack_req` does NOT roll back these pointer updates.
* `_GEN_153 ... _GEN_158` (lines 492-497) — all the state-7 next-cycle
  outputs for `sop`, `data_id`, `word_count`, `link_data`, `ne_rx_ptr` —
  capture state at the moment of NACK emission. These are committed on the
  cycle of the state-7 transition regardless of whether `send_nack_req` is
  subsequently cleared by the watchdog.
* The result is that after the watchdog releases `send_nack_req`, the FCSM
  resumes from state 4 with TX pointers pointing at a (re)transmit window
  that the peer has no record of. If the peer's `exp_pkt_num` /
  `fe_tx_credit_max` are out of sync, the peer's data-port `ready` will
  stop pulsing for new SIDEBAND packets (the LL layer is busy retrying
  what it thinks are missing packets, never granting new credit slots).
* Critically, `tl_fc_a2l_ready` (the TideLink data port `ready` we depend
  on in §1) is the LL-layer "I have a credit slot free for a new packet"
  line. If the FCSM has consumed all `fe_tx_credit_max` slots and is
  waiting on a CRACK that will never come (because the peer was never
  actually in error), `tl_fc_a2l_ready` stays low → skid full → returner
  wedged.

This explains:
* Build #3 (no `u_dbg_int`, no extra mark_debug fan-out): FCSM never
  visited state 7 long enough for the watchdog to trigger, so pointers were
  never rewound. Returner drains cleanly.
* Build #5 (334 mark_debug nets, fresh `u_dbg_int` core inserted): P&R
  routing of demet/forgive stickies almost certainly extended the bring-up
  window where `isNotExpPacket` can latch `send_nack_req`. Watchdog fires
  on every reset, **rewinds TX pointers**, and the link enters an
  unrecoverable retransmit-stall the moment it tries to flush the next
  outbound packet.

This also matches **fact (5)** in the prompt: state 4/4 + cal_done 1/1 +
lock `0xff/0xff` looks identical to build #3, but the LL credit window is
poisoned. The single-bit difference is `socl_l7_wdog_force_clear`
**having ever fired since reset** — it modifies LL pointer history, not
the externally observable PHY-align state.

---

## 4. Ranked hypotheses

| # | Hypothesis | Confidence | Experiment |
|---|---|---|---|
| H1 | `tl_fc_a2l_ready` stays low because FCSM rewound TX pointers on state-7 entry, peer is not the consumer of the rewound packet number, retransmit stalls. | **High** | Probe `tl_fc_a2l_valid` and `tl_fc_a2l_ready` on master (already mark_debug per `tidelink_top.sv:497`). Trigger on `apb_write && paddr==0x014`. Confirm `valid` is high, `ready` stays low for 100+ kc. Also probe FCSM `state`, `send_nack_req`, `socl_l7_wdog_force_clear`, `fe_tx_credit_max`, `link_ack_addr` — confirm wdog has fired and credit pointers wrap-stuck. |
| H2 | `skid_valid_r` is held high by a stuck `rtn_pending_r` while `tl_fc_a2l_ready=1` (skid never drained because arbiter is starved by a spurious always-asserted higher-priority source). | Low-Med | Probe `skid_valid_r`, `rtn_pending_r`, `servo_fc_valid`, `tc_tx_is_remote`, `sideband_starving`. If `servo_fc_valid` is permanently high (PTP servo stuck in TX) it would not block the returner (returner is highest priority) but could indicate broader FC adapter issue. |
| H3 | Watchdog itself is misbehaving — `socl_l7_real_crc_seen` never latches even on genuine errors, watchdog re-fires on every CR/CRACK boundary post-link-up. | Low | Probe `socl_l7_wdog_cnt` and `socl_l7_real_crc_seen` over a long capture. If `wdog_cnt` repeatedly counts up to threshold in steady state, the watchdog itself is the recurring bug source. |
| H4 | Build #5's `u_dbg_int` core adds enough clock fan-out / fanin to `io_tx_clk` to violate setup on the FCSM's state register, causing state to briefly glitch to 7 even without a NACK request. | Low | Re-run with a stripped ILA (eg only the 8 most-critical probes from `tidelink_top` `mark_debug` set rather than 334 nets). If returner clears, the issue is ILA-induced timing not the watchdog logic. |
| H5 | Slave is consuming the doorbell packet but the slave's APB write to 0x024 silently misroutes (e.g. `apb_region` decode bug after Region 8/10 widening). | Low | Probe `fc_rx_cfg_paddr` and `fc_rx_cfg_pwrite` on slave. If 0x024 is being driven but `doorbell_response_acc` does not increment, look at slave APB regs `acc1_write`/`acc1_read` qualifiers. Note: `acc1_read` clears on any APB read of `0x024` — make sure the host poll loop isn't read-clearing every iteration before observing. |

H1 is the dominant hypothesis. It cleanly explains:
* Both FCSMs end in state 4 (state-7 dwell short → quickly returns to 4).
* Master `returner_busy` sticky (data-port `ready` never re-asserts).
* Slave `DOORBELL_RESP_ACC = 0` (no SIDEBAND word ever crossed).
* Difference vs build #3 (which never tripped the watchdog because routing
  let the forgive AND fire in time).

---

## 5. Recommended next RTL probe / fix

**Probe (cheap, 1 build):** add the following 6 mark_debug nets to a
**minimal** ILA core (drop the 334-net core):
1. `tl_fc_a2l_valid` (master)
2. `tl_fc_a2l_ready` (master)
3. `u_returner.state_r` (2-bit)
4. `WlinkGenericFCSM_6.state` (3-bit, master + slave)
5. `WlinkGenericFCSM_6.socl_l7_wdog_force_clear` (1-bit)
6. `WlinkGenericFCSM_6.fe_tx_credit_max` (8-bit) + `link_ack_addr` (5-bit)

If H1 is right, capture will show `valid=1, ready=0` immediately after the
first doorbell ring, FCSM state oscillates 4 → 7 → 4 once, watchdog pulses,
then credit pointers freeze and `ready` never rises.

**Fix path A (preferred — restores Build #3 behaviour):** on the cycle
`socl_l7_wdog_force_clear` fires, **also rewind the LL TX pointers** that
state 7 entry committed. Specifically, **revert `ne_rx_ptr`,
`last_ack_pkt_sent`-derived retry pointer, and `count`** to the values they
held the cycle before state 7 was entered. This needs ~1 cycle of pre-state-7
shadow registers + a synchronous restore when `wdog_force_clear` fires.
Scope: still localised to `WlinkGenericFCSM_6.v`, no new ports, no CDC.

**Fix path B (defensive — orthogonal to A):** the returner has no upper
bound on time spent in `ST_DATA_PHASE`. Add a **returner-side timeout** —
e.g. after 64k cycles in `ST_DATA_PHASE` with `hready=0`, force-complete
the transaction (mark `master_error_r`, drop `htrans` to IDLE, return to
`ST_IDLE`). This bounds `returner_busy` regardless of downstream wedge and
ensures software can re-probe / re-trigger doorbell after a transient
link stall. Should also gate any new sideband packet on
`!returner_busy` from SW (poll status before re-arming doorbell).

**Fix path C (workaround for v1 silicon if A/B are too invasive):**
bypass the watchdog by tying `SOCL_L7_WDOG_THRESHOLD` to `16'hFFFF` (or
adding `SOCL_L7_WDOG_DISABLE` param) so silicon falls back to the
original forgive gate. Accept that some ILA-extended builds will still
wedge at state 7, but those builds were debug-only — production
synthesis without the 334-net ILA likely wins the routing lottery exactly
like build #3 did. This is a 1-line change and removes the
LL-pointer-poisoning side-effect entirely.

**Strong recommendation:** apply fix B (returner-side timeout) regardless
of A/C — the current returner design has no fault-tolerance against any
downstream wedge, not just the watchdog one. The 3-channel retry counter
only handles `hresp=ERROR`, not `hready` stuck low. This is a generic
robustness bug exposed by the build-#5 routing draw, and a small RTL
addition (~20 lines) makes the returner self-recovering for the next
class of bug.
