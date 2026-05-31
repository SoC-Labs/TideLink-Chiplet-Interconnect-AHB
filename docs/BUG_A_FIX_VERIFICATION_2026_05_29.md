# Bug A — L8 RTL Fix Sim Verification (2026-05-29 evening)

**Worktree**: `/home/dam1n19/SoCLabs/tidelink/.claude/worktrees/agent-a4910badfa0d53fd4`
**Branch**: `feat/td-gpio-phy-integration` (offline; main tree is busy with FPGA build)
**Patch under test**: `docs/BUG_A_PROPOSED_FIX_2026_05_29.patch`
**Test**: `cocotb/tidelink_top_pair/test_buga_fix_link_data_consumer.py`

---

## 1. Patch Apply

`git apply --check` against the raw patch file **failed** — the file is not a
pure unified diff; it embeds a ~88-line `// ...` preamble with the design
rationale. I stripped the preamble (kept only the `--- a/ … +++ b/ …` body)
into `/tmp/buga_diff_only.patch` and tried `git apply --check --recount`.

Result with `--recount`: **2 of 4 hunks rejected**, because the patch header
offsets are stale (the comment in the patch already warned: "hunk line numbers
above are approximate"):

| Hunk | Description | Result |
|------|-------------|--------|
| #1 | Declare `reg socl_l8_peer_data_seen_rx;` near other sticky regs | applied @ line 295 (offset -1) |
| #2 | Declare `socl_l8_peer_data_seen_tx_demet_*` demet wires | applied @ line 270 (offset -5) |
| #3 | Override `_GEN_60` to add L8 forgive | **REJECTED** |
| #4 | Sticky rx/tx always blocks + `WavDemetReset` instance | applied @ line 888 (offset -23) |
| #5 | Demet `_clock/_reset/_io_in` assigns | **REJECTED** |

Hunks #3 and #5 were applied manually via `Edit` (file contents match the
patch verbatim; only context-line offsets differed). Final L8 patch is
**in place** at `src/rtl/local_overrides/WlinkGenericFCSM_6.v`:

- `socl_l8_peer_data_seen_rx` reg + sticky RX always block
- `WavDemetReset socl_l8_peer_data_seen_tx_demet` 2-flop demet
- `socl_l8_reached_link_data` sticky in tx domain
- Modified `_GEN_60` consumer-side forgive
- All five demet wire assigns wired up

Test file also patched: `APB_REG_PKT_WORD_LEN` import-fallback was using a
stale `0x064` constant; updated to import `APB_PKT_WORD_LEN` (0x2008) from
the doorbell test helper.

Worktree submodules (`deps/axi-chiplet-controller`, `deps/tidelink-gpio-phy`)
were uninitialised; ran `git submodule update --init --recursive`.
`cocotb/tidelink_top_pair/pad_skid.sv` symlink in this worktree pointed at
`../wlink_pair/pad_skid.sv` (non-existent on this branch); re-pointed to
`../debug/wlink_pair/pad_skid.sv` (which exists and matches main-tree intent).

---

## 2. Test Results

| Test | Result | Sim time | Wallclock |
|------|--------|----------|-----------|
| `test_buga_fix_slave_advances_to_link_data` | **FAIL** | 8 592 300 ns | 447 s |
| `test_buga_fix_l7_send_nack_still_clears` | **FAIL** | 8 592 240 ns | 575 s |

### Main test trace (key signals)

```
[after to_data_mode]   M: fcsm=5  cr=1 crack=1 pcc=0
[after to_data_mode]   S: fcsm=4  cr=1 crack=1 pcc=0
PRE-AHB                M.state=4  S.state=4
                       --> L8 candidate condition: peer is silent. CR/CRACK
                           both true, no NACK yet — L8 *could* fire here but
                           does NOT because socl_l8_peer_data_seen_tx_demet
                           was never high (no data has crossed yet).
[AHB write driven]
+4 cy after AHB         S.state 4 -> 5     <<< L8 GATE FIRES
POST (after 4096 cy)   M.state=5  S.state=4  advanced_at_cy=4  l2a_pulses=0
S.REG_PKT_WORD_LEN     = 0x00000000
```

**ASSERTIONS:**

- (2) slave advanced 4→5: **PASS** — within 4 cy of AHB stim.
- (3) `l2a_pulses >= 1`: **FAIL** — slave `tl_fc_l2a_valid` never asserted.
- (4) `REG_PKT_WORD_LEN != 0`: **FAIL** — slave RX FIFO never received any
  packet.

### L7 non-regression trace

```
m: send_nack_req=0  socl_l7_reached_link_data=1   <-- OK
s: send_nack_req=1  socl_l7_reached_link_data=1   <-- REGRESSION
```

Slave's `send_nack_req` is **latched** at 1 after the test concludes — the
L7 invariant (`send_nack_req == 0` once `reached_link_data` is set) is
broken on the slave with L8 applied.

---

## 3. Critical Analysis

### Does the L8 gate work as designed?

**Yes.** The slave FCSM advances from state 4 to state 5 within 4 cycles of
the master AHB write — exactly the surface behaviour the patch was designed
to deliver. The patch is structurally sound and elaborates cleanly under VCS.

### Why does master reach state 5 in sim?

In this sim the master reaches state 5 **via the original upstream path**,
not via L8: AHB stimulus drives `a2l_fc_replay_link_valid` high on the
master TX side, which trips the upstream `(a2l_fc_replay_link_valid &
~fe_rx_is_full)` term in `_GEN_60`. So the master's state-5 transition is a
direct consequence of the test's AHB stimulus.

**Crucially:** before the AHB stimulus, M.state was already at 5 just after
`to_data_mode`, then fell back to 4 by AHB-time (PRE-AHB M=4 S=4 matches HW
build #3). The natural steady-state of both peers in this sim is **also
state 4**, just like HW build #3. The reason sim "looked different from HW"
in the F1 force experiment doc was that the force experiment also drove the
AHB stim — which kept master at 5. Without the AHB stim, both ends idle at 4
in sim too.

### Is the L8 trigger reproducible in HW?

**The trigger ("peer is sending data") is exactly as reproducible in HW as
in sim — but it requires the master's app to issue an AHB write.** Both in
sim and on HW build #3, when no AHB traffic exists, the L8 gate cannot fire
on either side because neither peer has emitted a data packet. The
PRE-AHB snapshot here (M=4, S=4) corresponds to the HW build #3 baseline.

So: **HW build #3 needs an AHB write driven on bridge1 to trip L8.** The
HW debug runbook needs to be updated to drive an AHB write *immediately
after* link bring-up, not assume the FCSM will move on its own. (This is
also what the existing doorbell test does in sim.)

### But the L8 fix DOESN'T resolve Bug A's real symptom

The Bug A symptom from the F1 force-experiment doc is two-pronged:
`S.tl_fc_l2a_valid = 0` **and** `S.REG_PKT_WORD_LEN = 0`. The L8 patch
addresses the FCSM-state symptom but leaves the data-path symptom
**untouched** — even with L8 firing within 4 cycles and the slave FCSM
reaching state 5, the slave's RX framer never produces an l2a pulse and the
RX FIFO never records the master's packet. The 4096-cy observation window
should have been more than enough for at least one packet to drain (the
doorbell test waits 2000 cy after AHB and reads REG_PKT_WORD_LEN == 2).

Combined with the L7 regression (`send_nack_req` latched on slave), the
most likely interpretation is:

1. L8 forces slave to state 5 at `+4 cy`.
2. Slave then sees an incoming packet whose decode path goes wrong
   (NACK-worthy CRC fail / out-of-sequence pkt num / etc).
3. `send_nack_req` latches.
4. With `send_nack_req=1`, the L8 forgive de-arms (`socl_l8_consumer_data_ready`
   AND-includes `~send_nack_req`), so slave likely fell back to state 4 (as
   observed: POST S.state=4 even though it briefly hit 5).
5. RX path stays wedged because the underlying RX-framer issue is not in
   the FCSM at all.

The Bug A root cause therefore has **at least one additional layer
downstream of the FCSM** that L8 does not address.

### L7 non-regression verdict

**FAILED.** Slave `send_nack_req` latches with L8 applied. This may not be
an L8 *causation* (the L8 gate by construction does not write
`send_nack_req`) but rather an L8 *exposure* — slave reached state 5
briefly and started decoding packets it would not have decoded otherwise,
and the underlying packet decoder produced a NACK-worthy result. Either
way, the L7-invariant on the slave is broken when running the L8 test.

---

## 4. HW vs Sim Concern

Per the prompt's critical question:

> In HW build #3 BOTH master and slave were stuck at state 4 (LINK_IDLE),
> unlike sim where master reaches state 5.

**Confirmed in this sim too — both end at state 4 if no AHB traffic is
driven.** The L8 trigger condition (`pkt_is_data_pkt` seen) requires real
data packets in flight, which requires the *master's app* to issue an AHB
write. On HW build #3, no AHB writes are being driven during the wedge
window, so:

- L8 will **not** unblock HW build #3 on its own.
- HW operators must drive an AHB write into bridge1 after bring-up. If that
  has not been done on the HW rig, the wedge persists.
- Even if AHB stim is added, this sim shows the slave RX path **stays
  wedged** (l2a_valid=0, REG_PKT_WORD_LEN=0), so L8 alone will not bring
  the link up bilaterally on HW either.

---

## 5. Recommendation

**RED-LIGHT — do NOT apply L8 patch to main yet.**

Rationale:

1. The L8 gate works as designed (slave 4→5 within 4 cy of AHB stim), but
   the Bug A surface symptoms `tl_fc_l2a_valid > 0` and `REG_PKT_WORD_LEN
   != 0` are **not resolved**. The patch addresses a symptom (FCSM state),
   not the root cause (RX framer / decode wedge).
2. L8 causes a measurable L7 regression on the slave (`send_nack_req`
   latches). Even if this is exposure rather than causation, it is a real
   change in behaviour that the existing L7 test would not have caught.
3. The HW-vs-sim concern is real and worse than stated: the L8 trigger
   needs AHB stim on master, which HW build #3 may not be driving. Without
   AHB stim, L8 fires on neither peer and the patch is a no-op.

**Next steps before re-attempting:**

- Find where the slave RX framer is rejecting / NACK-ing the master's
  packet. Suggested probes: `pkt_is_data_pkt`, `pkt_is_crack_pkt`,
  `pkt_is_cr_pkt`, `auto_rx_in_data`, `isExpPacket`, `_T_54` on the slave's
  FCSM during the AHB observation window (re-run with VCD enabled or a
  targeted probe test).
- Once the RX framer wedge is understood and patched, re-evaluate whether
  L8 is even needed: if the slave's app naturally drives l2a after fixing
  the RX path, the FCSM may transition via the natural upstream path and
  L8 becomes redundant.
- If L8 is still needed after the RX-path fix, tighten the gate: also
  require `~send_nack_req_pending` (synced from RX domain) before allowing
  the L8 forgive, to prevent the briefly-state-5 → nack → fallback thrash
  observed here.

---

## 6. Artefacts

- Worktree FCSM file (patched): `…/agent-a4910badfa0d53fd4/src/rtl/local_overrides/WlinkGenericFCSM_6.v`
- Stripped patch (only diff): `/tmp/buga_diff_only.patch`
- Main test log: `/tmp/buga_fix_main.log`
- L7 regression log: `/tmp/buga_fix_l7.log`
- Sim builds (in worktree): `sim_build_buga_fix_main`, `sim_build_buga_fix_l7`

No commits, no main-tree mutations beyond writing this report. Worktree
will be collapsed by parent.
