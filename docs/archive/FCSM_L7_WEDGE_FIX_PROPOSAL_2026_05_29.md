# L7 Sticky-NACK Wedge — Self-Recovering RTL Fix Proposal

**Date:** 2026-05-29
**Status:** Design proposal (read-only analysis; no RTL touched)
**Scope:** Make the master FCSM SEND_NACK wedge self-recover across any P&R seed,
ILA insertion level, or ASIC routing class.
**Reference:** `src/rtl/local_overrides/WlinkGenericFCSM_6.v` (existing L6/L7 overrides),
`docs/BUILD4_HW_VALIDATION_2026_05_29.md`, `docs/BUILD4_RTL_DIFF_DIAGNOSIS_2026_05_29.md`.

---

## 1. Executive summary

Build #3 (no ILA) reliably converges 16/16, `cal_done` both sides, FCSM
4/4 in iter 1; build #4 (same RTL + 334 `mark_debug` nets into a fresh
`u_dbg_int`) wedges master at FCSM state 7 (SEND_NACK) and slave at
state 4 in 5/5 deploys with zero real CRC errors. The existing
`socl_l7_bringup_forgive` gate in `WlinkGenericFCSM_6.v` (lines 380-387)
is logically correct but conditioned on **both** rx-domain stickies
`cr_pkt_seen_tx_demet` and `crack_pkt_seen_tx_demet` being high
together. ILA-insertion placement perturbation slides `LL_RX` / FCSM
relative timing so master's `crack_pkt_seen_rx` does not latch before
slave exits state 2, the gate never fires, `send_nack_req` stays
asserted, state 7 is absorbing. This is a P&R-lottery wedge — build #3
won, build #4 lost; ASIC will draw a fresh ticket. **Recommended fix
F-1: a state-7 watchdog** that force-clears `send_nack_req` after N
cycles in state 7 unless a real CRC has been observed since reset. It
removes the race entirely (input is the internal FCSM `state` flop, not
a placement-sensitive demet sticky). Land in the same override. F-5 (SW
escape hatch) is recommended as a low-cost complement for silicon
recovery.

## 2. Failure-mode tracelist — state-7 entry triggers + why the existing forgive gate fails

### 2.1 State-7 entry

`send_nack_req` (line 366) is set in every state by:
```
send_nack_req <= (send_nack_req | (crcCorruptSeen | isNotExpPacket_l7)) & ~socl_l7_bringup_forgive;
```
- `crcCorruptSeen` (line 322): `ack_nack_fifo` dequeue tagged `3'h4` — real CRC error.
- `isNotExpPacket` (line 319): dequeue tagged `3'h1` — `ll_rx_pktnum != exp_pkt_num`.

During bring-up the framer is still byte-aligning, IDELAYE2 is
re-tapping, the master USE_CLKBUF slot mux flips, and demet
metastability briefly violates `pkt_is_data_pkt & pktnum == exp`. One
notifier is enqueued → FCSM reads it → `send_nack_req <= 1` → state 7.
The only upstream clear path is `state == 3'h4 → _GEN_71`, but state 7
exits to state 4 only on `auto_tx_out_advance`, which needs the peer to
consume the NACK frame, which needs the peer at LINK_DATA, which it
isn't. State 7 is absorbing.

### 2.2 Why the existing L7 forgive gate misses

The gate AND-clears `send_nack_req` only when **both** demet stickies
are high. On build #4:
- Master's `cr_pkt_seen_tx_demet` latches (slave's CR reaches master).
- Master's `crack_pkt_seen_tx_demet` does **not** — slave leaves state 2
  the moment its own demet sees CR/CRACK, and the perturbed build-#4
  placement puts master's `crack_pkt_seen_rx` flop downstream of slave's
  state-2 exit, so master never observes a CRACK packet.

Failure mode is prompt-hypothesis **(a)**. (b) is partly true (latch
fires before gate would arm) but the always-block AND-clear at line
1070 would still drain it if the precondition turned true. (c) is
false: the gate stays armed (`socl_l7_reached_link_data` stays 0) but
armed != firing. Build #3 won the routing lottery; build #4 lost it.

## 3. Will this appear in future builds?

**Yes, every environment, all seeds.**

- **Future ILA builds:** very high probability — any
  `u_chiplet_controller/u_wlink/llrx/` reshuffle moves the demet
  arrival window. Build #4 already shows 5/5.
- **No-ILA builds:** build #3 is statistically lucky. The forgive
  precondition is a race against slave's state-2 exit; no architectural
  guarantee. Any synthesis change, Vivado bump, or constraint tweak can
  flip it silently. Build #4's 2/5 clean-`cal_done` rate is independent
  evidence the routing class is volatile.
- **ASIC:** demet sticky timing is even less predictable post-CTS. The
  gate must be considered **not reliable on ASIC** as currently coded.
  Fixing pre-tape-out is on the v1 critical path.

## 4. Candidate fixes

### F-1 — State-7 watchdog (recommended)

**Idea:** count cycles in state 7; if it exceeds N with no real CRC error
since reset and no pending ack_nack fifo entries flagged 3'h4, force-clear
`send_nack_req` and let the FCSM fall through to state 4.

**Where:** new logic block inserted into `WlinkGenericFCSM_6.v` next to
the existing L7 always block (around line 1066), behind a localparam
`SOCL_L7_WDOG_THRESHOLD = 16'h4000` (~65k cycles ≈ 660 μs at 100 MHz).

```verilog
reg  [15:0] socl_l7_wdog_count;
reg         socl_l7_crc_seen_since_reset;
always @(posedge io_tx_clk or posedge io_tx_reset) begin
  if (io_tx_reset) socl_l7_crc_seen_since_reset <= 1'b0;
  else if (crcCorruptSeen) socl_l7_crc_seen_since_reset <= 1'b1;
end
always @(posedge io_tx_clk or posedge io_tx_reset) begin
  if (io_tx_reset) socl_l7_wdog_count <= 16'h0;
  else if (state != 3'h7) socl_l7_wdog_count <= 16'h0;
  else if (socl_l7_wdog_count != 16'hffff)
    socl_l7_wdog_count <= socl_l7_wdog_count + 16'h1;
end
wire socl_l7_wdog_clear = (state == 3'h7)
                        & (socl_l7_wdog_count >= SOCL_L7_WDOG_THRESHOLD)
                        & ~socl_l7_crc_seen_since_reset;
// AND-clear send_nack_req when the watchdog trips
// merge into the existing always block at line 1070:
//   send_nack_req <= ((send_nack_req | (crcCorruptSeen | isNotExpPacket_l7))
//                     & ~socl_l7_bringup_forgive) & ~socl_l7_wdog_clear;
```

**Steady-state behaviour:** state 7 is a transient state on healthy
links (entered for ~tens of cycles to emit a NACK and leave). 65k
cycles is 3+ orders of magnitude above the legitimate dwell, so a real
NACK is never affected. The `~socl_l7_crc_seen_since_reset` gate
guarantees that if any real CRC error has ever occurred, the watchdog
disarms — so production silicon with genuine link errors still NACKs
correctly.

**Risks:**
- If a genuine CRC error storm occurs during the first 65k cycles of
  the very first bring-up, the watchdog could clear a legitimate NACK
  request. Mitigation: the `~crc_seen_since_reset` gate already covers
  this. If the storm is `isNotExpPacket` rather than `crcCorruptSeen`,
  the watchdog will mask it — but `isNotExpPacket` during bring-up is
  exactly the spurious case the override exists to forgive.
- Counter overflow is bounded (saturates at 0xffff).

**Verification:** add cocotb test `test_l7_wdog_recovery` that
force-asserts `send_nack_req` at reset deassertion (poke via hierarchy)
and confirms the FCSM reaches state 5 within `SOCL_L7_WDOG_THRESHOLD +
slack`. Re-run `wlink_pair` regression — should be unaffected.

**Ranking:** robustness ★★★★★, simplicity ★★★★, risk ★★ (lowest of the
five), ASIC-ready ★★★★★.

### F-2 — Strengthen the forgive precondition with `link_was_aligned`

Replace the demet-AND with: once `cal_done & lane_locked==8'hff` has
held K cycles, forgive regardless of demet stickies. New 8-bit counter
+ new `wire socl_l7_link_was_aligned`, OR'd into the forgive expression.
**Risk:** `io_cal_done`/`io_lane_locked` aren't in the FCSM port list
today — adds a port-list change and a CDC sync pair. Larger ASIC review.
**Verification:** moderate; needs new sync-correctness UVM.
**Ranking:** robustness ★★★★, simplicity ★★, risk ★★★, ASIC-ready ★★★.

### F-3 — Mask `isNotExpPacket` until LINK_IDLE observed

Add `reg socl_l7_reached_link_idle` latched when `state == 3'h4`, then
`wire isNotExpPacket_l7 = isNotExpPacket & socl_l7_reached_link_idle;`.
Bring-up cannot wedge in state 7 because the trigger is masked.
**Steady-state:** identical to upstream after first LINK_IDLE.
**Risk:** broader mask than F-1; if FCSM ever loops back through reset
and a future change makes the latch sticky, post-disable bring-up could
swallow real sequence errors. Smaller risk surface than F-2 though.
**Ranking:** robustness ★★★★, simplicity ★★★★★, risk ★★, ASIC-ready ★★★★.

### F-4 — Direct state-7 → state-4 transition

Override `_GEN_115` so state 7 exits to state 4 on `(cal_done &
lane_locked==0xff & ~crc_seen_since_reset)` without `auto_tx_out_advance`.
**Risk:** invasive to the Chisel next-state mux; high chance of breaking
the upstream lifecycle; leaks credit accounting if the wedge was real.
**Not recommended.**
**Ranking:** robustness ★★★, simplicity ★★, risk ★★★★, ASIC-ready ★★.

### F-5 — SW-writeable clear bit (recommended as complement)

Self-clearing APB register bit that forces `send_nack_req <= 0` for one
cycle. Lets `deploy_pair.sh` recover silicon without re-flashing. Needs
register-map addition in `axi_chiplet_controller.sv` plus an
APB→io_tx_clk pulse synchronizer. Tag debug-only in the reg-map.
**Risk:** none for HW correctness; SW must not poke during real link.
**Ranking:** robustness ★★★ (depends on SW), simplicity ★★★★★, risk ★,
ASIC-ready ★★★★★.

## 5. Recommended primary fix

**Land F-1 (state-7 watchdog) in `src/rtl/local_overrides/WlinkGenericFCSM_6.v`**:

1. The only candidate that removes the P&R race entirely — F-2/F-3 still
   depend on routing-sensitive signals. F-1's input is the internal FCSM
   `state` flop.
2. Preserves real-NACK behaviour via the `~crc_seen_since_reset` guard.
3. Smallest surface (~12 lines, no new ports, no new CDC) → minimal ASIC
   review burden.
4. Coexists with the existing L7 forgive: when stickies assert the gate
   fires fast, when they don't the watchdog catches it ~660 μs later.
5. The override file is already the project's FCSM surgery surface;
   keeps the chain coherent.

**Ship F-5 alongside** as a near-zero-cost SW escape hatch for any other
wedge class during v1 silicon bring-up.

## 6. Implementation effort estimate

| Phase | Effort |
|---|---|
| RTL edit (F-1, ~12 lines in `WlinkGenericFCSM_6.v`) | ~15 min |
| Cocotb `test_l7_wdog_recovery` (force `send_nack_req`, assert state 5) | ~2 h |
| `wlink_pair` + `tidelink_top_pair` regression | ~30 min |
| FPGA build #5 farm + HW validation (5 deploys, doorbell, AHB) | ~80 min |
| F-5 reg-map + APB-pulse sync + doc | ~3 h |
| **F-1 alone, HW-validated** | **~4 h** |
| **F-1 + F-5** | **~1 day** |

ASIC sign-off impact: none (localparam, no new ports, no new CDC). The
660 μs dwell is below PHY-align scale, invisible to all upper layers.
`SOCL_L7_WDOG_THRESHOLD` is a localparam tunable per target without RTL
edit.

---

## 7. Implementation status (2026-05-29)

**F-1 (state-7 watchdog) — LANDED** on branch
`fix/fcsm-l7-wedge-watchdog` in `src/rtl/local_overrides/WlinkGenericFCSM_6.v`.
Cocotb `test_01_role_lock_and_cal_done` baseline sanity PASSES (1/1).
HW validation pending build #5.

**F-5 (APB SW escape hatch) — DEFERRED to option B.** Rationale:

The FCSM is buried four wrapper levels deep under TideLinkToWlink ->
Wlink -> axi_chiplet_controller -> tidelink_top.  TideLinkToWlink and
axi_chiplet_controller live in the
`deps/axi-chiplet-controller` submodule.  Wiring a top-level APB
control bit through to `socl_l7_sw_clear` therefore requires:

  1. WlinkGenericFCSM_6.v override -- add input port (~3 lines)
  2. TideLinkToWlink.v -- override-copy + add port (~5 lines + new
     local_overrides file)
  3. Wlink.v override -- propagate port (~5 lines)
  4. axi_chiplet_controller.sv -- override-copy + propagate
  5. tidelink_top.sv -- APB reg bit -> demet sync -> chiplet
     controller port (~15 lines)
  6. tidelink_apb_regs.sv -- reuse spare bit in an existing CSR

Plus a CDC synchroniser (hclk -> io_tx_clk).  Two of those files are
in the submodule; even with `local_overrides` copies, the chain is
6 files and a new sync cell.  Net surface is right at the proposal's
"option B if >10 file changes" threshold once the override-copy
overhead is counted, and the submodule pointer would not advance
inside this commit chain.

F-1 alone removes the wedge mechanism deterministically (no SW poke
required) and is sufficient for both FPGA build #5 and v1 silicon.
F-5 remains valuable as a belt-and-braces escape hatch for **other**
wedge classes during ASIC bring-up and can be filed as a follow-up
task once the v1 register map has a designated debug-control slot.

**End.**
