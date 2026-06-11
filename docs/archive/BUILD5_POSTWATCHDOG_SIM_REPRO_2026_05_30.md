# Build #5 post-watchdog wedge — cocotb sim reproduction

**Date:** 2026-05-30
**Branch:** `sim/l7-wedge-repro-postwdog` (off `sim/l7-wedge-repro`)
**Commits:**
- `c7f8dc2` — sim test (`test_post_watchdog_doorbell_delivery.py`)
- `218a84b` — F-1 watchdog RTL (cherry-pick of `f5633f1` from `fix/fcsm-l7-wedge-watchdog`)

**Related docs:**
- `docs/BUILD5_HW_VALIDATION_2026_05_29.md` — HW build #5 symptom
- `docs/L7_WEDGE_SIM_REPRO_2026_05_29.md` — original L7 wedge sim repro
- `docs/FCSM_L7_WEDGE_FIX_PROPOSAL_2026_05_29.md` — F-1 proposal
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v` — F-1 RTL

---

## 1. Outcome

**OUTCOME (b): SIM REPRODUCES THE BUILD #5 SECONDARY WEDGE.**

Sim shows: after the F-1 watchdog fires and `send_nack_req` is cleared,
the master FCSM **stays at state 7**, no application traffic flows,
and 0/10 doorbells delivered M→S — matching the build #5 HW symptom.

We have a fast iteration loop for F-1.5.

---

## 2. Test methodology

`cocotb/tidelink_top_pair/test_post_watchdog_doorbell_delivery.py`:

1. Reset + role_lock (skip Phase 1 cal_done, same shortcut as the
   existing repro).
2. `Force()` master FCSM into state 7: `socl_l7_reached_link_data=1`,
   `send_nack_req=1`, `state=7`.
3. Poll `socl_l7_wdog_force_clear` until it asserts (~16384 io_tx_clk
   cycles ≈ +105,000 hclk cy).
4. `Release()` `state` AND `send_nack_req` — FCSM is now free to run
   the next-state mux.
5. Sample 80 points over 8000 hclk cy: state histogram, send_nack_req,
   wdog_force_clear, `auto_tx_out_advance`, `ack_nack_fifo_valid`,
   `ack_nack_fifo_io_rinc`, `pkt_is_cr_pkt`, `pkt_is_crack_pkt`.
6. Read APB REG_STATUS (0x2010 inside TideLink region) for
   `returner_busy` bit 0.
7. Ring 10 doorbells on master (`APB_DOORBELL = 0x2014`) and read
   slave `APB_DOORBELL_RESP_ACC = 0x2024`.

The test always passes (it characterises rather than gates); the
verdict is in the `[VERDICT]` log line.

---

## 3. Measured sim output

Run on `sim/l7-wedge-repro-postwdog` (test + F-1 RTL), VCS 2022.06-SP2,
cocotb 2.0.1, `SIM_BUILD=sim_build_postwdog`, ~156 s wall:

```
+105,000 hclk cy : socl_l7_wdog_force_clear asserted (wdog_cnt = 0x4000)
+50 cy after Release(state, send_nack_req) :
        state = 7, send_nack_req = 0

post-release 8000 hclk cy sweep (80 samples @ /100 cy):
  state histogram     : {0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 80}
  send_nack_req high  : 0/80
  wdog_force_clear hi : 80/80   <-- watchdog stays asserted (counter saturated)
  auto_tx_out_advance : 0/80    <-- KEY: never fires
  ack_nack_fifo_valid : 0/80
  ack_nack_fifo_rinc  : 0/80
  pkt_is_cr_pkt       : 0/80
  pkt_is_crack_pkt    : 0/80

final state = 7, send_nack_req = 0
master REG_STATUS = 0x00000000 (returner_busy bit 0 = 0)
slave  DOORBELL_RESP_ACC: pre=0 post=0 delivered=0/10
master DOORBELL_RESP_ACC: pre=0 post=0
```

**Bottom line:** F-1 successfully drains `send_nack_req` to 0, but the
FCSM never leaves state 7. Zero doorbells deliver.

(Note: `returner_busy = 0` in sim because we skip the Phase 1 PHY
bringup that would normally populate the FIFO — the bringup-shortcut
documented in `L7_WEDGE_SIM_REPRO_2026_05_29.md`. In HW, build #5
shows `returner_busy = 1` because there is real upstream FIFO content
that the FCSM can't drain. The mechanism is the same — state 7 latched
prevents any TX packet from being committed.)

---

## 4. Root cause confirmed in RTL

Per `src/rtl/local_overrides/WlinkGenericFCSM_6.v`:

```verilog
wire [2:0] _GEN_115 = auto_tx_out_advance ? 3'h4 : state;  // FC.scala 575
...
state[7] -> _GEN_150 = state == 3'h7 ? _GEN_115 : _GEN_146;
```

The state-7 → state-4 transition is **gated solely on
`auto_tx_out_advance`** — an LLTX-side input port to the FCSM
indicating the NACK packet has been emitted from the TX serialiser and
the LL is ready for the next packet.

F-1 watchdog touches:
- `send_nack_req`  ← cleared synchronously

F-1 watchdog does NOT touch:
- `auto_tx_out_advance` (LLTX input)
- `state` register (still depends on `auto_tx_out_advance` for state-7
  exit)

So when LLTX is stuck — e.g. because the NACK packet was already
latched into the TX skid but the peer's RX is silent / unresponsive
and the LL hand-shake can't complete — the FCSM is structurally
unable to leave state 7 even with `send_nack_req` forced low. The
watchdog clears the SYMPTOM (`send_nack_req`) but not the CAUSE (the
LL TX pipeline is wedged on the in-flight NACK).

This is consistent with what cocotb shows: `auto_tx_out_advance = 0`
for all 80 samples after Force release, `ack_nack_fifo_valid = 0`,
`pkt_is_cr_pkt = 0`, `pkt_is_crack_pkt = 0`. The FCSM sits idle in
state 7, waiting for an `auto_tx_out_advance` pulse that never comes
because LLTX has no peer hand-shake.

---

## 5. F-1.5 fix design — recommended

The F-1 watchdog needs to ALSO synthesize a state-7 → state-4 escape
that does not depend on `auto_tx_out_advance`. Two candidate sketches:

### Option A — Watchdog-driven `state` force-clear (preferred)

Add a parallel always-block that forces `state <= 3'h4` when
`socl_l7_wdog_force_clear` is asserted. This is symmetric with the
existing `send_nack_req` AND-clear and uses the same gate so no new
logic is needed beyond a small reset arc on `state`.

```verilog
// SoC Labs F-1.5: also force state out of 7 when the watchdog fires.
// auto_tx_out_advance may be wedged when the LL TX pipeline can't
// complete the in-flight NACK (peer unresponsive / pkt latched into
// skid).  Without this, the state-7 register holds even with
// send_nack_req cleared, and the FCSM cannot resume normal LINK_IDLE.
always @(posedge io_tx_clk or posedge io_tx_reset) begin
  if (io_tx_reset) begin
    /* state already covered by upstream reset */
  end else if (socl_l7_wdog_force_clear && state == 3'h7) begin
    state <= 3'h4;   // LINK_IDLE; resume normal arbitration
  end
end
```

Caveats:
- `state` is currently driven by a CASE/MUX upstream — we may need to
  AND-mask `_GEN_150` with `~socl_l7_wdog_force_clear` and OR in a
  3'h4 force path. Concretely, mirror the `send_nack_req` AND-clear
  pattern at the `state` register.
- Risk: if the in-flight NACK eventually does flush after the FCSM
  has moved on, the LL_TX skid may emit a stale NACK packet into a
  link the FCSM thinks is idle. Mitigate by also pulsing an LL_TX
  reset / flush on the same watchdog event (Option C).

### Option B — Force-flush the LL TX pipeline alongside the NACK clear

If the wedge is "LL_TX skid is holding the NACK packet", clearing
the skid valid bit at the same time as `send_nack_req` would let
`auto_tx_out_advance` pulse naturally on the next idle cycle.

Pros: symmetric, no need to override `state`.
Cons: requires reaching into the LL_TX layer (a separate Chisel-
generated module). More surface area.

### Option C — Combine A + B

Force `state <= 3'h4`, AND pulse LL_TX flush. Belt and braces.

### Option D — Treat the state-7 watchdog as a full FCSM reset pulse

On `socl_l7_wdog_force_clear`, assert a localised FCSM soft-reset for
1 cycle that drops state to 0, drains `ack_nack_fifo`, clears
`send_nack_req`, `send_ack_req`, and reasserts `io_tx_reset` for one
cycle to the FCSM's child blocks. Heavier but matches what a SW
recovery would do.

**Recommendation: start with Option A.** It is the smallest delta to
F-1 (one always-block) and the sim test we just wrote will validate
it directly — if state falls from 7 → 4 after the watchdog fires AND
the doorbells then deliver, F-1.5 is done. If doorbells still don't
deliver, escalate to Option C.

---

## 6. What the sim probes confirm

| Probe                       | Value over 80 post-release samples | Interpretation                                            |
|-----------------------------|------------------------------------|-----------------------------------------------------------|
| `state`                     | 7 × 80                             | FCSM stuck — auto_tx_out_advance never fires              |
| `send_nack_req`             | 0 × 80                             | F-1 watchdog working as designed                          |
| `socl_l7_wdog_force_clear`  | 1 × 80                             | Counter saturated; gate held (state hasn't left 7)        |
| `auto_tx_out_advance`       | 0 × 80                             | KEY: LL_TX never reports the in-flight NACK as advanced   |
| `ack_nack_fifo_valid`       | 0 × 80                             | FIFO is empty — no fresh notifiers, nothing to process    |
| `ack_nack_fifo_io_rinc`     | 0 × 80                             | No FIFO dequeues — consistent with valid=0                |
| `pkt_is_cr_pkt`             | 0 × 80                             | No CR packets arriving — RX framer silent (Force scenario)|
| `pkt_is_crack_pkt`          | 0 × 80                             | No CRACK packets arriving — consistent                    |
| `returner_busy` (APB[0])    | 0                                  | Sim baseline only — FIFO unpopulated (Phase 1 skipped)    |
| `s_DOORBELL_RESP_ACC`       | 0 (was 0)                          | 0/10 doorbells delivered                                  |

The signature is unambiguous: `auto_tx_out_advance` is the missing
trigger.

---

## 7. Sim vs HW fidelity

| Observable                          | Build #5 HW              | This sim                |
|-------------------------------------|--------------------------|-------------------------|
| send_nack_req post-watchdog         | clears                   | clears                  |
| FCSM state post-watchdog            | stays at 7               | stays at 7              |
| returner_busy                       | stays 1 (real traffic)   | 0 (no traffic baseline) |
| Doorbell M→S delivery               | blocked                  | blocked                 |
| auto_tx_out_advance ever fires      | (suspected no)           | confirmed no            |

Caveat: `returner_busy` differs because the sim shortcut skips the
Phase 1 PHY bringup that would populate the upstream FIFO. The HW
shows `returner_busy = 1` because real traffic is queued upstream of
the FCSM; the FCSM's inability to issue TX packets backs up the
returner. The mechanism (state-7 latched, no TX issued) is identical;
only the FIFO-fill side-effect differs. We can extend the sim to
populate the FIFO via AHB writes before the wedge if we want to also
exercise `returner_busy`, but the F-1.5 fix doesn't require it — the
state-7 escape is the test gate.

---

## 8. Test invocation

```bash
cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
CMSDK_FPGA_SRAM_V=/research/AAA/ip_library/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v \
PATH=/home/dam1n19/miniconda3/bin:$PATH \
  nice -n 19 make \
    MODULE=test_post_watchdog_doorbell_delivery \
    SIM=vcs \
    TB_TOP_NO_DUMP=1 \
    SIM_BUILD=sim_build_postwdog
```

Wall: ~2 min 36 s on this rig (first-time compile + 2.4 ms sim time).

---

## 9. Next step

1. Patch `src/rtl/local_overrides/WlinkGenericFCSM_6.v` with Option A
   (force `state <= 3'h4` when `socl_l7_wdog_force_clear` asserts).
2. Re-run `test_post_watchdog_doorbell_delivery` — expect VERDICT (a):
   doorbells deliver after watchdog.
3. Re-run the existing `test_l7_wedge_recovers_with_watchdog_fix` —
   expect still PASS (F-1.5 is a superset of F-1).
4. If both pass, queue HW build #6 with F-1.5.

---

**End.**
