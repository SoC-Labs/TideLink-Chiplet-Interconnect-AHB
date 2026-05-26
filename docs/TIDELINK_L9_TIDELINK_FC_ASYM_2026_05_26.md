# TideLink FC Channel Master-Only Asymmetry — L9 Investigation

**Date:** 2026-05-26
**Branch:** `feat/td-interface-debug-l9-tidelink-fc-asym` (from `feat/td-interface-debug-l8v2-narrow-ack-mask` @ `177988f`)
**Predecessor:** L8 v2 (build #15) — narrow send_ack_req mask
**Status:** investigation + hypotheses + SW-only repro/test scripts. NO RTL CHANGE PROPOSED YET.

---

## 1. Inputs from the operator

After 12 hours and 15 farm builds:
- Bilateral LINK_IDLE reached on HW (cr_pkt_seen=1 AND crack_pkt_seen=1 symmetric)
- PHY clean (16/16 lanes locked, cal_done=1 on both sides)
- FCSM never advances to LINK_DATA (state 5)
- All 7 FC channels probed via APB `[0x08]` field:

| data_id | channel | M[0x08] | S[0x08] | symmetric? |
|---------|---------|---------|---------|------------|
| 0x80 | AXI AR | 1 | 1 | yes |
| 0x81 | AXI AW | 1 | 1 | yes |
| 0x82 | AXI R  | 1 | 1 | yes |
| 0x83 | AXI W  | 1 | 1 | yes |
| 0x84 | AXI B  | 1 | 1 | yes |
| 0xa0 | GenBus | 1 | 1 | yes |
| **0xa1** | **TideLink FC** | **0** | **1** | **NO** |

Doorbells + AHB peer-writes to `0x44010000` don't cross.

---

## 2. What [0x08] actually reads — a CRITICAL re-interpretation

**The `wlink_probe.sh` header comment is misleading.** It says
"activity bit (1 if traffic has been seen on this channel)". The RTL says
otherwise:

`deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v:431`

```verilog
wire readval = a2l_fc_replay_link_empty;
```

and at line 459 the mux selects `_out_T` at `out_oindex==4'h2` (paddr=0x08).
The actual data muxed in for the 32-bit read of offset 0x08 is line 463:

```verilog
wire [18:0] _GEN_310 = _out_out_bits_data_T_2 ? {{18'd0}, readval} : _GEN_309;
```

so `[0x08]` returns `{31'h0, a2l_fc_replay.fifo.rempty}`.

**Therefore:**
- `[0x08] = 1` → FIFO is **empty** (channel has nothing pending to TX). "Idle" — NOT
  "active".
- `[0x08] = 0` → FIFO has **pending TX data not yet drained**. The channel
  has been written to but the FCSM hasn't shipped the packet.

Re-reading the user's observation with the corrected semantic:

| channel | M | S | meaning |
|---------|---|---|---------|
| 0x80..0x84 AXI | 1 | 1 | both a2l FIFOs empty (no AXI traffic queued either side) |
| 0xa0 GenBus | 1 | 1 | tied off both sides — expected |
| 0xa1 TideLink | **0** | 1 | **master has pending app data**, slave has nothing |

This is **consistent with the symptom**: the operator pushed doorbells / returner sideband traffic into master's TideLink FC TX path, the FCSM is stuck below LINK_DATA, the master a2l_fc_replay FIFO accumulated the pending packets, `link_empty` reads 0. Slave's a2l FIFO stays empty because no SW pushed any TX traffic on the slave side (slave is the read target, not the writer).

The 6 other channels show empty because:
- AXI peer-write attempts (`0x44010000` through XHB500 AHB→AXI) get blocked
  **upstream** of the FCSM (XHB500 or chiplet_controller stalls on
  link-not-ready), so the AXI a2l FIFOs never see data.
- GenBus is tied off (`generalbus_in=32'h0` at `tidelink_top.sv:1770`).

The asymmetry the operator observed is **real and load-bearing**, but the
narrative needs to flip: "M_active=0" actually means "master IS the side
with stuck queued traffic", not "master is inactive".

---

## 3. Why ONLY the TideLink FC channel queues TX during bringup

Inspect the 7 FC TX feeders (`src/rtl/tidelink_fc_adapter.sv:367-372`):

| FC channel | Producer feeding a2l |
|-----------|----------------------|
| 0x80..0x84 AXI | XHB500 AHB→AXI → chiplet_controller s_axi |
| 0xa0 GenBus | tied to `32'h0` (FC node exists, never written) |
| 0xa1 TideLink | tidelink_fc_adapter: returner / TX aperture / servo / TideChart |

The returner fires on `released_credits_irq`, `doorbell_irq`, or
`packet_committed_irq`. These three IRQs are driven by APB writes to the
TideLink FIFO ctrl regs (`src/rtl/fifo/tidelink_apb_regs.sv:280`):

```verilog
assign released_credits_irq = (released_credits_acc != '0);
```

So the moment SW writes a doorbell on master, the returner fires a single
write, the FC adapter packs it as a SIDEBAND packet and pushes it into the
TideLink FCSM_6's app-to-link FIFO. If FCSM_6 is stuck pre-LINK_DATA, the
FIFO never drains and `link_empty` stays at 0.

The other channels can't queue this way because their producers are gated
(XHB500 stalls upstream on link-not-up, GenBus tied off).

**This means the TideLink FC asymmetry the operator observed is the SAME
class of bug as "FCSM never reaches LINK_DATA" — there's only one bug,
not two.** The TideLink channel is just the only channel where the bug
becomes visible at the APB layer, because it's the only channel that
accepts producer writes without an upstream interlock.

---

## 4. Why FCSM_6 might not advance even with valid app data on master

FCSM state-5 entry gate (FC.scala, encoded in
`src/rtl/local_overrides/WlinkGenericFCSM_6.v:479`):

```verilog
wire [2:0] _GEN_60 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 3'h5 : state;
```

For master at state 4 with one queued packet:
- `a2l_fc_replay_link_valid = enable_link_clk_demet & ~link_empty` (FCReplayV2_13.v:97) — should be 1 (swi_enable=1, FIFO non-empty)
- `~fe_rx_is_full` — depends on slave's CR-packet-carried credit count

If `_GEN_60` is firing every cycle and state still not transitioning, the
dispatch order pre-empts it. Per the state-4 next-state mux:

```
state == 4 → _GEN_76 = send_nack_req ? 3'h7 :
                       send_ack_req & (count==0) ? 3'h6 :
                       _GEN_60   // state 5 or stay
```

So **send_ack_req=1 with count==0 always wins over LINK_DATA**. If
`send_ack_req` is constantly re-armed before each ACK emit completes,
FCSM oscillates 4↔6 and never visits 5.

### What can re-arm send_ack_req

`send_ack_req <= send_ack_req | (isExpPacket | l2a_raddr_update_gated)`
applied in every state from 0..3 and (via _GEN_178) in 4..7.

- **isExpPacket** — pulses when ack_nack_fifo drains an `exp_pkt_seen`
  notifier. Loaded when master RX decodes a normal data packet. During the
  bringup-only phase (no SW data writes yet) no data packets fly, so this
  source SHOULD be quiet.
- **l2a_raddr_update_gated** — pulses when the l2a TX FIFO read-address
  CDC shows a different value than last cycle. **L8 v2 GATES this with
  `~socl_l7_bringup_forgive`** so during bringup it's masked.

`socl_l7_bringup_forgive = !reached_link_data & cr_seen & crack_seen`.
Once `reached_link_data` latches (state==5 ever observed), forgive
deasserts forever.

### Deadlock candidate (most likely root cause)

> Master observes its OWN ACK emit (state 6 outbound TX) loop back as
> `isExpPacket` due to LL_TX→LL_RX bleed-through or a stale RX path
> sticky from an earlier deploy iteration. send_ack_req re-arms before
> state 4 can take the `_GEN_60` branch. FCSM oscillates 4↔6 forever.

Counter-evidence: `pkt_is_ack_pkt = … & data_id == swi_ack_id (0x46)`
should NOT raise `isExpPacket` (which requires `pkttypenotifier == 3'h0`,
i.e. a normal-not-ack-not-nack packet). So self-ACK shouldn't trigger it.

### Alternative root cause (second most likely)

> Slave is healthy and is emitting periodic ACKs of its own. Master's RX
> decodes them as `pkt_is_ack_pkt` → ack_nack_fifo loaded with
> `{3'h2, ...}` → on readout `isAckPacket=1`, `isExpPacket=0`. This
> should NOT re-arm send_ack_req. **But** — `last_good_pkt_from_rx_in`
> updates on `isExpPacket` only. If the slave's first data-like packet
> (whatever it is) ever decodes as a `pkttypenotifier==0` notifier, the
> single isExpPacket pulse re-arms send_ack_req, which then loops as
> above.

### Why the OTHER FCSMs (AXI, GenBus) don't show this even though they
share the same RTL

Because they have NO L6/L7/L8 patches. The L8 v2 patch is applied **only
to FCSM_6** in `src/rtl/local_overrides/WlinkGenericFCSM_6.v`. FCSMs 0–5
use the upstream `deps/axi-chiplet-controller/.../WlinkGenericFCSM*.v`,
which has the original (unmasked) `l2a_fifo_raddr_txclk_update`
behaviour. That OR-with-l2a-raddr is what the L8 v2 mask was added to
suppress to ALLOW FCSM advance.

So the L8 v2 patch is doing its job for one path (suppressing the spurious
ack re-trigger) but may have a residual hole on a different path
(isExpPacket re-trigger).

---

## 5. Hypotheses (ranked)

**H-1 (most likely)**. The master's FCSM_6 is oscillating between state 4
(LINK_IDLE) and state 6 (ACK emit) because some signal keeps re-arming
`send_ack_req`. The state 5 (LINK_DATA) transition can't fire because the
state 4 dispatch always picks state 6 first when `send_ack_req=1`. The
gating signal is one of `isExpPacket` (L8 v2 leaves untouched), some
unobserved RX-side glitch, or a CDC artifact at the ack_nack_fifo. RTL
fix path: extend L8 v2 mask to ALSO gate `isExpPacket` until
`reached_link_data` latches (with the same one-shot disarm). This is
risky — it could regress what L8 v2 fixed.

**H-2**. The `socl_l7_reached_link_data` latch can never set because
state 5 is never observed, so `socl_l7_bringup_forgive` stays at 1
forever, the gates stay closed forever, and the FCSM can never escape
LINK_IDLE-with-pending-ACK. **Deadlock by design.** This is the same
self-defeating-gate class of bug that L8 v1 had on tdif-14 ({M=2, S=1}).

**H-3** (low likelihood but easy to disprove). `fe_rx_credit_max` on
master was loaded as 0 from the slave's CR packet (word_count[15:8]==0).
Then `fe_rx_is_full=1` per the credit-arithmetic, gating
`_GEN_60`. Master never advances. Per `wlink_probe.sh:81-83` the
operator already reads `[0x10]` (FC config, expected `0x00020601`) and
`[0x14]` (FC params, expected `0x00000708`). If both match, the
upstream-coded credit window is 7 (params[19:16]) and credit max is 6.
Slave's CR should advertise word_count = `0x06xx`. **First action:
verify the slave's TideLink FC `[0x14]` matches master's** — Phase-5A
TideChart introduced asymmetric credit programming once before, and the
TideLink FC node was the only channel with asymmetric config under that
class of bug.

**H-4** (per task hypothesis #1, low likelihood given other channels are
symmetric). TideLink FC channel disabled on master. `[0x10]` register
should read `0x00020601` (matches FC.scala `swi_link_en=1`). Easy to
verify, very unlikely to be the answer because `swi_link_en` is
hard-wired to `swi_enable` (the link-wide enable) for all FCSMs (see
`Wlink.v:2041-2099`), and AXI channels are symmetric → swi_enable is 1.

**H-5** (per task hypothesis #4). `fe_rx_credit_max` initialization race
specific to TideLink. The TideLink FCSM_6 cr_id=0x44 vs AXI cr_id=0x08…
0x40 — both decode in their respective FCSMs and write `fe_rx_credit_max`.
Same upstream RTL path. Unlikely to differ across channels.

**H-6** (sw-orchestration). `bringup_pair_converge.sh` doesn't leave the
TideLink FC channel in a state where SW data can flow. Re-checked
`deploy_pair.sh:355-360` and `sw_coord_autocal_region8_FIX.sh:97-101` —
both use the FIXED swreset sequence (`0x27f09 → 0x27f01 → 0x27f07`)
keeping `swi_enable=1` throughout. So the May-24 `swi_enable=0` artifact
is gone. Bringup is leaving the FCSMs in a sane post-handshake state.
**Hypothesis falsified.**

---

## 6. SW-only first-touch tests (NO RTL change, NO rebuild)

The three tests below can run on the deployed bridge1 board state
immediately after `bringup_pair_converge.sh` reports converged. They
discriminate between H-1, H-2, H-3.

`pynq_host/scripts/td_l9_probe_fcsm_credit_asym.sh` (new) reads the FCSM_6
`[0x10]`, `[0x14]`, FCSM state, and the related credit-path-status fields
on both sides and emits a single line per side suitable for log
diffing. It does NOT touch AHB_TX. It only does the same read-only APB
probes `wlink_probe.sh` already issues.

`pynq_host/scripts/td_l9_force_reached_link_data.sh` (new) is a
NO-OP-VALIDATED stub: it documents the APB read that would PROVE H-1
once a debug write port is exposed for `socl_l7_reached_link_data`. The
register doesn't exist today, so the stub just prints a TODO.

`pynq_host/scripts/td_l9_drain_doorbell_at_t0.sh` (new) does the doorbell
ring, polls `[0x08]` (a2l link_empty) for 5 seconds, and reports the
elapsed time before FIFO drains. Pass: drains within 100ms. Fail (the
expected outcome on tdif-15): never drains.

All three stubs are inert (read-only) until manually invoked against a
known-bringup-converged board. They are NOT run by this investigation.

---

## 7. Proposed L9 RTL change (do NOT apply yet — needs sim regression)

If H-1 / H-2 is the cause, the minimum-risk fix is to time-bound the
forgive gate independently of `reached_link_data`. Currently:

```verilog
// src/rtl/local_overrides/WlinkGenericFCSM_6.v:413
wire socl_l7_bringup_forgive = (~socl_l7_reached_link_data)
                               & cr_pkt_seen_tx_demet_io_out
                               & crack_pkt_seen_tx_demet_io_out;
```

If FCSM never reaches state 5, forgive=1 forever and the state-4→5 gate
oscillates against state-4→6. Proposed L9 change: add a fallback
time-out so forgive deasserts after N cycles of being held, INDEPENDENT
of `reached_link_data`. This breaks the deadlock if FCSM is stuck at 4.

```verilog
// L9 proposal: time-bound forgive even if state 5 never seen
reg [11:0] socl_l9_forgive_age;
always_ff @(posedge io_tx_clk or posedge io_tx_reset) begin
  if (io_tx_reset)               socl_l9_forgive_age <= 12'h0;
  else if (~socl_l7_bringup_forgive) socl_l9_forgive_age <= 12'h0;
  else if (socl_l9_forgive_age != 12'hfff)
                                 socl_l9_forgive_age <= socl_l9_forgive_age + 12'h1;
end
wire socl_l9_forgive_timeout = (socl_l9_forgive_age == 12'hfff);

// Replace line 413's forgive with:
wire socl_l7_bringup_forgive = (~socl_l7_reached_link_data)
                               & cr_pkt_seen_tx_demet_io_out
                               & crack_pkt_seen_tx_demet_io_out
                               & ~socl_l9_forgive_timeout;
```

This is a **time-bounded forgive** — if `reached_link_data` doesn't
latch within 4096 io_tx_clk cycles (~160us @25MHz / ~40us @100MHz), the
forgive disarms and the upstream `l2a_fifo_raddr_txclk_update` path
re-arms `send_ack_req` only via valid l2a CDC updates, breaking any
deadlock between forgive and reached_link_data.

**This is HYPOTHETICAL.** A sim regression that REPRODUCES the deadlock
must be built BEFORE applying this. See §8.

---

## 8. Sim test that would catch this (regression for L9+)

The existing `cocotb/wlink_pair/test_link_idle_advance_with_payload.py`
test_01 already covers "force app_packet on master, expect state 5
within 4000 cycles". It PASSES on main without a recal_cycle. The
delta between sim-pass and HW-fail is presumed to be the recal_cycle
perturbing some signal.

Proposed new test `cocotb/wlink_pair/test_l9_post_bringup_drain.py`:

```python
# Test: after a FULL bringup_pair_converge replay (including recal +
# swreset cycle), assert that a single returner-side doorbell write
# results in master FCSM_6 transitioning to state 5 within 4000 cycles
# and the a2l FIFO draining.
#
# Why it would catch L9:
#  - replays the EXACT bringup pattern that includes the recal cycle
#  - injects a single doorbell write (the smallest realistic app TX)
#  - asserts state 5 reached AND a2l_fc_replay.fifo.rempty returns to 1
#  - guards against any pre-state-5 deadlock
#
# Compared with test_paired_recal_to_link_data:
#  - that test doesn't inject any app TX, so it can't reveal a deadlock
#    that needs an app packet to surface (master with empty FIFO
#    naturally sits at state 4, indistinguishable from "stuck")
```

This is the next test to write. The structure follows
`test_paired_recal_to_link_data.py` (replays the bringup sequence) plus
a final block that drives the master's returner doorbell stub and
polls FCSM state + link_empty.

---

## 9. What's KNOWN vs HYPOTHESIZED

**KNOWN (RTL evidence):**

- `[0x08]` in every FCSM reads `a2l_fc_replay.fifo.rempty`, NOT
  "channel active". `wlink_probe.sh:24` comment is wrong/misleading.
- M[0x08]=0 means **master has pending app TX queued**. S[0x08]=1
  means slave has nothing queued. The asymmetry is consistent with
  "doorbell pushed on master, no doorbell pushed on slave".
- Only FCSM_6 (TideLink, data_id=0xa1) carries the L6/L7/L8
  modifications; FCSM_0..5 use upstream code.
- State 4 dispatch always prefers state 6 (ACK emit) over state 5
  (LINK_DATA) when send_ack_req=1 AND count==0.
- The L8 v2 mask gates `l2a_fifo_raddr_txclk_update` but leaves
  `isExpPacket` untouched.
- The L7 `socl_l7_bringup_forgive` is dependent on
  `socl_l7_reached_link_data` which can ONLY set in state 5 — if
  state 5 is unreachable, forgive is permanently asserted.
- `bringup_pair_converge.sh` does NOT touch the buggy 2026-05-24
  `swi_enable=0` swreset sequence; that class of bug is gone.

**HYPOTHESIZED (no direct evidence yet):**

- H-1: master FCSM_6 is oscillating between states 4 and 6 due to a
  re-arming `send_ack_req`. (NEEDS HW probe of `send_ack_req` to
  confirm — not exposed via any APB reg today.)
- H-2: deadlock between `socl_l7_reached_link_data` (requires state 5)
  and `socl_l7_bringup_forgive` (blocks state 5). Needs sim
  reproduction.
- H-3: `fe_rx_credit_max` is 0 on master. SW-checkable via reading
  the slave's FCSM config registers; the operator's iteration tdif-15
  data should ALREADY include the answer in `[0x10]`/`[0x14]` per-side.
  **Send first.**

**LIKELY-FALSE:**

- TideLink FC channel disabled on master (H-4): all channels share
  `swi_enable` from `Wlink.v`. If TideLink were disabled, AXI would be
  too — but AXI channels are symmetric.
- TideLink FC has a different bringup (task H-2): the bringup script
  treats TideLink the same as every other FCSM. The only difference
  is the local override of FCSM_6 (L6/L7/L8 patches).
- bringup script leaves something untriggered (task H-5): the SW
  orchestration leaves swi_enable=1 + lltx_enable=1 in the final state;
  no separate "TideLink TX enable" exists.

---

## 10. Recommended next action (no time budget remaining)

1. **Verify H-3 first** (5 min). Have the operator print the full
   FCSM_6 `[0x00..0x1F]` snapshot per side from the tdif-15 run. If
   master `[0x14]` differs from slave `[0x14]` in the credit-relevant
   bits, H-3 is confirmed and the fix is SW (re-program the credit
   regs) — no RTL change needed.

2. **If H-3 is falsified**, write the L9 sim test
   (`test_l9_post_bringup_drain.py`) and run it against the L8 v2
   simulation. If it FAILS, that's the deadlock, and the L9 RTL change
   (§7 time-bounded forgive) is justified. If it PASSES, the bug is
   HW-specific (recal artifact, RX path, or clk dom issue) — escalate
   to a paired ILA capture of `send_ack_req`, `send_nack_req`, and
   `socl_l7_reached_link_data` directly.

3. **DO NOT apply the L9 RTL change without §2 above.** L8 v1 already
   showed that broad masks regress prior fixes; a forgive-timeout
   could re-introduce the L7-original spurious NACK class.

---

## 11. Files of interest

- `src/rtl/local_overrides/WlinkGenericFCSM_6.v` — L6/L7/L8 patches
- `src/rtl/tidelink_fc_adapter.sv` — returner+TX path producer
- `src/rtl/tidelink_top.sv:1773-1775` — tidelink FC port hookup
- `pynq_host/scripts/wlink_probe.sh:24` — incorrect [0x08] comment
- `pynq_host/scripts/bringup_pair_converge.sh` — bring-up driver
- `pynq_host/scripts/deploy_pair.sh:355-360` — swreset sequence
- `cocotb/wlink_pair/test_link_idle_advance_with_payload.py` — exists,
  passes on main without recal
- `cocotb/wlink_pair/test_paired_recal_to_link_data.py` — replays
  bringup recal sequence (no doorbell injection)
- `docs/FC_NODE_REGISTRY.md` — canonical data_id table

---

**Constraints honored:**
- No submodule changes
- No FPGA build kicked
- No git push
- New scripts are stubs only, not invoked against bridge1
- Total investigation time: ~55 min
