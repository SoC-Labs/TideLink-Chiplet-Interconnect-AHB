# I1 FCSM cold-start regression — design-intent diagnosis (RTL-architect lens)

Branch: `analysis/i1-design-intent` · Date: 2026-07-30 · Analysis only (no build, no HW).

Scope: the "SoC Labs Fix A–E" recovery override on the five time-muxed AXI flow-control
nodes (`src/rtl/local_overrides/WlinkGenericFCSM.v` + `_1..4`) breaks **cold** bring-up on
the 2-board KR260 eth-chiplet bench (`cr_seen=0 crack_seen=0 cal_done=0 fcsm=0`, both dies),
while the recovery-stripped `deps/` copy brings up (fcsm=4) and the single sideband node
(`WlinkGenericFCSM_6.v`, same recovery gates) also brings up.

Sources read:
- Chisel: `/home/dam1n19/SoCLabs/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala`
  and `LinkLayer.scala` (WlinkTxRouter), `AXI.scala` (the 5 FC instantiations).
- Generated Verilog override: `src/rtl/local_overrides/WlinkGenericFCSM.v` (+`_1..4`, `_6`).
- Pristine reference: `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM.v`.
- Sim: `cocotb/tidelink_fcsm_silicon_ratio/test_fcsm_silicon_ratio.py`.

FCSM state encoding (FC.scala 36–47): 0 IDLE, 1 SEND_CREDITS1 (CR emit → `cr_seen`),
2 SEND_CREDITS2 (CRACK emit → `crack_seen`), 3 LINK_EN_WAIT, 4 LINK_IDLE (healthy fcsm=4),
5 LINK_DATA, 6 SEND_ACK, 7 SEND_NACK.

---

## 0. Headline findings (read this first)

**F0 — The recovery lives ONLY in the netlist, not in the source.** `FC.scala` contains
**zero** `socl_*` / Fix A–E logic (`grep -i socl|reack|forgive|wdog|reached_link_data FC.scala`
→ no hits). Fixes A–E were hand-edited directly into the generated `WlinkGenericFCSM*.v`.
There is therefore *no source-of-truth* for the recovery, it is un-regenerable, and the 5 AXI
copies + the sideband copy are independently hand-maintained. "Redesign at the source" =
implement this in `FC.scala` for the first time, correctly armed.

**F1 — The CR-emit datapath is byte-identical to `deps`.** A full functional diff
(pristine `deps` vs override, `_RAND`/comments stripped) shows the reset → IDLE → state-1
**CR-emit path is unchanged**. The *first* functional divergence is the state-1→2 **exit**
condition (`_GEN_34`), then the state-2→3 exit, then NACK-masking, watchdog, and re-ACK.
Nothing in the override touches the IDLE→SEND_CREDITS1 entry (Verilog `state<=3'h1`,
`WlinkGenericFCSM.v:691-692`) or the CR word the node presents in state 1
(`data_id<=swi_cr_id`, `.v:868`; `sop<=en_ff2_tx|sop`, `.v:843/285`). **So no socl gate
suppresses the CR emit.** Any hypothesis of the form "a recovery gate holds the CR off in
states 0-3" is refuted by the diff itself — this is the single most useful negative result
here, and it explains why the earlier state-**exit** tuning was silicon-refuted.

**F2 — The cold-start-hostile class is the MIN-EMIT credit gates (Fix B + Fix C), by their
ARM CONDITION, not by suppressing the emit.** Both gates require *N of the node's own
credit emits to accumulate while the peer is simultaneously still radiating the matching
credit packet* (`crack_pkt_seen`/`cr_pkt_seen` level-high). That two-sided coincidence is a
race the pristine level-triggered handshake never has to win. Under the 5-way TX-router the
node emits only ~1/5 of link slots, so it cannot rack up N inside the peer's shrinking
window → the credit handshake never completes → LINK_IDLE (fcsm=4) is never reached → the
traffic-gated pad clock never opens → PHY alignment (`cal_done`) never latches and the RX
capture domains go dark → even the state-1 CR beacon stops reaching the wire ⇒ observed
`cr_seen=0` on both dies. The sideband node wins the race trivially because, un-muxed, it
emits every slot.

**F3 — The shipped `tidelink_fcsm_silicon_ratio` regression tests the WRONG failure.** Its
`test_axi_fcsm_clean_bringup_at_silicon_ratio` **passes at gate=32** (test lines 126-140):
in that pure-FCSM model a clean two-die link reaches CRACK-count 32 even muxed. The only
failure it reproduces is a *state-2* wedge under an artificially *marginal* (periodic
re-enable) link — i.e. a link that was already up and keeps retrying. That is why lowering
the state-2 gate 32→8 (`make fixed`) "passed" in sim yet was **silicon-refuted for cold
bring-up**: the sim never modelled the cold traffic-gated-pad-clock coupling, so it gave
false green. The redesign below is deliberately gate-value-independent so it is robust to
whichever coupling term (muxed cadence, marginal link, or pad-clock collapse) dominates on
silicon.

---

## (a) Design-intent map — Fix A–E (purpose · arm · reset · Chisel/Verilog)

All Verilog line refs are `src/rtl/local_overrides/WlinkGenericFCSM.v`. FC.scala refs are the
pristine source the override was grown from (the socl logic has **no** FC.scala origin — that
is F0). "Chisel" column = the nearest pristine construct the feature wraps.

| Fix | Purpose (reconstructed intent) | Arms / fires when | Reset state | Verilog | Wraps Chisel |
|-----|--------------------------------|-------------------|-------------|---------|--------------|
| **A** `socl_l7_bringup_forgive` / `isNotExpPacket_l7` | During bring-up, mask the "unexpected packet-number" NACK trigger so an early/stale RX packet cannot fire a spurious NACK before the sequence numbers are established. | `~reached_link_data & cr_pkt_seen & crack_pkt_seen` (i.e. only after BOTH peer credits seen, and only pre-first-LINK_DATA). | `socl_l7_reached_link_data` → 0 (`.v:1000-1004`, sets on state==5). | decl `.v:293-299`; use in `send_nack_req` `.v:987-995`; masks `_GEN_71/105/141/153`. | `send_nack_req_in := Mux(..., crcCorrupt‖isNotExpPacket)` FC.scala 439. |
| **B** `socl_l6_cr_emit_gate_ok` (min CR emits, state-1 exit) | Hold SEND_CREDITS1 until ≥`SOCL_L6_MIN_CR_EMITS`(=32) CR packets have been *emitted*, so the peer has a long, reliable CR burst to byte-align on before we advance. | state==1 exit gated: `(cr_seen‖crack_seen) & count≥32`. Counter counts `state==1 & advance & sop`. | `socl_l6_cr_emit_count` → 0 (`.v` counter block, zeroes on `state!=1`). | decl `.v:286-288`, `SOCL_L6_MIN_CR_EMITS` `.v:64`; exit `_GEN_34` `.v:312-313`, applied `.v:696`; emit `data_id` `.v:861-869`. | SEND_CREDITS1 exit `when(crack_pkt_seen‖cr_pkt_seen) → SEND_CREDITS2`, FC.scala **457-465** (`_GEN_34 @[FC.scala 460:52 465:39]`). |
| **C** `socl_l7_crack_release` (min CRACK emits, state-2 exit) | Mirror of B for SEND_CREDITS2: hold until ≥`SOCL_L7_MIN_CRACK_EMITS` CRACK emits so the peer byte-aligns on CRACK before LINK_EN_WAIT. | state==2 exit gated: `crack_pkt_seen & count≥N`. **N lowered 32→8** for I1 (`.v:65-78`). | `socl_l7_crack_emit_count` → 0 (zeroes on `state!=2`). | decl `.v:289-292`, `SOCL_L7_MIN_CRACK_EMITS` `.v:75-78`; `_GEN_40/41/42/44/45` `.v:316-321`; state `.v:698-699`. | SEND_CREDITS2 exit `when(crack_pkt_seen) → LINK_EN_WAIT`, FC.scala **473-476**. |
| **D** `socl_l7_wdog_force_clear` (state-7 NACK watchdog) | If stuck in SEND_NACK for `SOCL_L7_WDOG_THRESHOLD`(=0x4000) tx-clocks with no *real* CRC error seen, force-clear the stuck NACK request (routing-insensitive recovery from a phantom NACK). | `wdog_cnt==0x4000 & ~real_crc_seen`; counter only advances **while state==7** (`.v:1018`). | `socl_l7_wdog_cnt`→0, `socl_l7_real_crc_seen`→0 (`.v:1007-1025`). | decl `.v:300-305`; force-clear ANDed into `send_nack_req` `.v:987-995`. | `send_nack_req` clear path (no pristine analogue — purely additive). |
| **E** `socl_reack_*` (periodic cumulative re-ACK) | On a quiet but live link, periodically re-emit the last cumulative ACK so a dropped ACK cannot silently starve the peer's replay buffer (idempotent liveness). | `reack_idle_cnt==0x100 & have_rx & ~fired & state≥4 & ~send_nack_req & ~send_ack_req`. `have_rx = last_good_pkt_from_rx≠0`. | `reack_idle_cnt`→0, `reack_fired`→0 (`.v:1026-1045`). | decl `.v:306-336`; injected into `send_ack_req` default `.v:980`. | `send_ack_req` default (states 4-7) FC.scala 438; additive. |

Also present (not a "Fix"): **Bug-C** CRC-off-by-default (`out_prepend_swi_disable_crc<=1`,
`.v:713`, vs pristine `<=0`). Orthogonal to bring-up.

---

## (b) Ranked cold-start-hostile suspects & the mechanism on the CR emit (states 0–3)

Ranking is by *architectural* cold-start hostility. Note the pivotal fact from F1: none of
these can suppress the state-1 CR **register value** — the emit datapath is identical to
`deps`. The hostility is in **forward progress** out of the credit states (which, via the
pad-clock coupling, is what actually zeroes `cr_seen`).

1. **Fix B — state-1 min-CR-emit gate `socl_l6_cr_emit_gate_ok` (PRIME SUSPECT, still =32).**
   Arm condition is inherently cold-hostile: it demands 32 *self* CR emits accumulate
   *while* `(cr_seen‖crack_seen)` is level-high, i.e. while the peer is still in its own
   credit phase. It is **active from reset** — nothing gates it behind first LINK_DATA
   (contrast Fix A, which is). It is the **first** divergence from `deps` reachable on a cold
   link and it sits exactly at the SEND_CREDITS1 exit (`.v:696`, `_GEN_34`). The earlier
   "exit-gate fix" that was silicon-refuted lowered only the **state-2** gate (Fix C, `.v:65-78`
   comment); the **state-1** gate was left at 32, so the node can still be stranded in
   SEND_CREDITS1 — consistent with "the break is at/before the state-1 CR emit". Mechanism
   on `cr_seen`: node held in state 1 → whole link never reaches data mode → pad clock gates
   → beacon stops reaching the wire ⇒ `cr_seen=0` (see F2 / §c).

2. **Fix C — state-2 min-CRACK-emit gate `socl_l7_crack_release`.** Same class as B, one state
   later, and *strictly worse in form*: its left operand is `crack_pkt_seen` **alone** (not
   `cr‖crack`), so if the peer leaves state 2 (stops radiating CRACK) before this node's count
   reaches N, `crack_pkt_seen` drops and `crack_release` can **never** fire — a hard mutual
   deadlock, no timeout (SEND_CREDITS2 has no timeout, test lines 15-16). This is the one the
   I1 comment documents ("never racks up 32 … no LINK_IDLE => all-zeros both dirs", `.v:65-72`).
   Lowering to 8 narrowed but did not remove the race; still cold-active.

3. **Fix A — `isNotExpPacket_l7` bring-up forgive.** *Correctly* keyed on `~reached_link_data`
   (this is the template the redesign generalises). But note it only masks *once both peer
   credits are seen*; before that it is inert, and it only **reduces** `send_nack_req`
   (`.v:987-995` ANDs in `~forgive`). It cannot *set* a NACK and cannot displace the CR.
   **Not a regression source** — ranked here only because it touches the same `send_nack_req`
   the task flagged. If anything it is protective.

4. **Fix D — state-7 watchdog.** `wdog_cnt` advances **only while state==7** (`.v:1018`); cold
   bring-up never reaches SEND_NACK, so the counter is pinned at 0 and `force_clear` is dead.
   **Inert cold.** (It only ever *clears* `send_nack_req`, never sets state — even if it did
   fire it could not suppress a CR.)

5. **Fix E — periodic re-ACK.** Guarded three ways against cold: `have_rx` (needs
   `last_good_pkt_from_rx≠0`), `state≥4`, and `~send_nack_req&~send_ack_req` (`.v:330-336`).
   All false on a cold link. **Inert cold.**

Net: the task's candidate list (`socl_l7_*`, `socl_reack_*`, `isNotExpPacket_l7`,
`send_nack_req`) is dominated by **Fix B/C (the min-emit gates)**; the NACK/reack terms
(A/D/E) are inert-or-protective on a cold link and are *not* the regressors.

---

## (c) Why the single sideband node survives but the 5 muxed AXI nodes don't

The discriminator is the **WlinkTxRouter** (`LinkLayer.scala:36-135`). Its per-channel grant is

```
tx_ins(i).advance := tx_out.advance && (curr_ch === i.asUInt)     // LinkLayer.scala:78
```

a priority round-robin over channels whose `sop` is asserted. The five AXI FC nodes
(`AXI.scala:300-353`: `awFC/wFC/bFC/arFC/rFC`) all sit under **one** router and all assert
`sop` in state 1 at cold start, so each is granted only ~1/5 of link slots. The socl min-emit
counters advance on `state==N & advance & sop` — so a muxed node needs ≈5×N link slots of
*its own* grants to reach the gate, and must do so **inside the window the peer is still
radiating the matching credit packet**. Both dies are throttled the same 1/5, so the
"my-count-hits-N ∧ peer-still-in-state" coincidence window shrinks toward zero and the gate
never releases on any of the five. The sideband node (`WlinkGenericFCSM_6`, its own
FC path, effectively `numChannels==1`) is granted **every** slot, reaches N in N consecutive
slots while its peer is still in the matching state, and clears — same gate values (`_6` also
defaults 32/32, `WlinkGenericFCSM_6.v:189-192`), opposite outcome. This is a pure
contention×cold-start interaction, exactly as observed.

The step from "credit handshake stalls" to the observed `cr_seen=0 / cal_done=0 / fcsm=0`
(both dies) is the established traffic-gated-pad-clock coupling
(MEMORY: `project_z2_delivery_blocker…`, `project_role_lock_is_a_mutual_clock_enable`): with
no node reaching LINK_IDLE/data mode, the forwarded `pad_clk_tx` (= the peer's `pad_clk_rx`)
never leaves its idle gate, the peer's RX domain stays dark, alignment never completes
(`cal_done=0`), and the CR the FCSM keeps writing into its `sop/data_id` registers is never
clocked onto the wire — so the peer's `cr_seen` reads 0 and never flickers. `deps` avoids the
whole chain because its credit exit is the pristine level-trigger (`_GEN_34 = (cr‖crack) ? 2 :
state`, no count), which releases on the first peer credit and drives straight to fcsm=4.
[Inference — the pad-clock/`cal_done` link is cross-referenced to the established silicon
findings in MEMORY, not re-derived from RTL here; marked as such.]

---

## (d) Redesign at the source + sim experiments

### D.1 The architecturally-correct fix: arm recovery only after first link-up

Recovery is, by definition, for a link that **was already up** — there is nothing to recover
*to* before the first credit handshake completes. Arming a min-emit *hold* during the very
first handshake is a category error. The pristine credit exchange is already correct for cold
start (deps proves it). So make the recovery gates **transparent until the link has reached
LINK_IDLE/LINK_DATA once**, then engage them for the traffic/recovery phase.

Implement in **`FC.scala`** (this is also F0's fix — give the recovery a source of truth):

1. Add a sticky arm latch (the override already has the register — promote it to Chisel and
   *use it as the arm*, not just for Fix A):
   ```
   val recovery_armed = RegInit(false.B)
   when(state === WlinkGenericFCState.LINK_IDLE) { recovery_armed := true.B }  // or ≥ LINK_EN_WAIT
   ```
   (The netlist's `socl_l7_reached_link_data`, set on `state==5`, is the same idea — but it
   arms on first *data*, and it is only wired to Fix A. Arm on first LINK_IDLE so the credit
   phase of any *re-bring-up* is also covered.)

2. Gate every min-emit / recovery term behind it, transparent when disarmed:
   ```
   val l6_gate_ok = !recovery_armed || (socl_l6_cr_emit_count   >= MIN_CR)     // state-1 exit
   val l7_gate_ok = !recovery_armed || (socl_l7_crack_emit_count >= MIN_CRACK) // state-2 exit
   ```
   so the SEND_CREDITS1 exit becomes `(cr‖crack) & l6_gate_ok` and SEND_CREDITS2 becomes
   `crack & l7_gate_ok`. On a cold link `recovery_armed=0` ⇒ both reduce to the **pristine**
   level-trigger ⇒ cold bring-up is **deps-identical by construction**, independent of the
   gate values. After first LINK_IDLE the holds engage for the recovery/traffic phase.
   Fixes A/D/E already self-guard (A on `~reached_link_data`, D on state==7, E on state≥4 &
   have_rx) and need no change beyond being ported to Chisel.

3. Regenerate all six FCSM copies from the one Chisel source (kills the hand-maintained
   netlist drift) with the arm parameterised (`recoveryEnable`, `crEmitGate`, `crackEmitGate`)
   so ASIC/FPGA flists select behaviour without re-editing Verilog.

**Why this addresses the EMIT, not the exit (contrast with the refuted fix).** The refuted
attempt retuned an exit *threshold* (state-2 gate 32→8) while leaving the gate **authoritative
on the cold path** — it only narrowed the coincidence race, and left the state-1 gate at 32
entirely, so the node still strands *before* it can emit-and-progress. This redesign removes
the gates' authority over the **entire cold credit-emit regime** (states 1–2 while
`recovery_armed=0`): the node emits CR and advances on the first peer credit exactly like the
working `deps` node, so the mutual handshake converges, data mode is reached, the pad clock
opens and `cal_done` latches. It restores the cold emit/entry behaviour rather than tuning
when we leave a state we can already never properly reach.

### D.2 Sim experiments to confirm BEFORE any RTL change

Build on `cocotb/tidelink_fcsm_silicon_ratio` (already instruments all 10 AXI nodes' `state`
and emit counts, both dies, at ref≈40 ns). The key gap (F3): its clean-bring-up control
passes at gate=32, so it does **not** currently reproduce the cold silicon failure.

- **E1 — Reproduce cold at the muxed cadence (the missing repro).** New testcase:
  cold power-on bring-up (no periodic re-enable), five AXI nodes through the real
  WlinkTxRouter, ref=40 ns, gate B=32 / C=8 as shipped. **Predict:** at least one die's five
  nodes stall in state 1/2 and never reach state 4 — the coincidence-window stall of §c. If it
  reproduces, the muxed-cadence mechanism is confirmed at the FCSM level; if it *doesn't*
  (nodes reach 4 in pure sim as the clean control does), that isolates the residual to the
  pad-clock/`cal_done` coupling (E4) — either way the result is diagnostic.

- **E2 — Threshold sweep isolates the gate.** Same cold test, sweep
  `SOCL_L6_MIN_CR_EMITS ∈ {1,2,4,8,32}` (add a `+define` for L6 mirroring the existing L7 one).
  **Predict:** state-4 reached at small N, stalls at large N, with the stall boundary rising
  as `numChannels` falls — the fingerprint of the muxed coincidence race.

- **E3 — Arm-after-link-data equivalence (the fix proof).** Apply D.1 (`recovery_armed`) and
  rerun E1/E2 at gate B=32/C=32. **Predict:** cold bring-up reaches state 4 for **all** gate
  values (gate transparent while disarmed) and is cycle-identical to a `deps` run through
  first LINK_IDLE — the by-construction claim. Then confirm recovery still works: drive a
  post-link-up NACK/marginal event and show the (now-armed) holds engage.

- **E4 — Confirm the system coupling.** In the top-pair bench
  (`cocotb/tidelink_top_pair_v2`) run cold bring-up with override vs deps FCSM and log
  `pad_clk` activity + `cal_done` alongside `cr_seen`. **Predict:** override → pad clock stays
  gated, `cal_done=0`, `cr_seen=0`; deps → pad clock opens after the credit exchange. This ties
  the FCSM-level stall to the observed silicon symptom and validates the §c inference.

Gating rule: E1 (repro) + E3 (fix) must both be green — a fix that passes E3 but has no E1 to
regress against would repeat the F3 false-green.

---

## Appendix — file:line index

Chisel `FC.scala`: states 36-47; IDLE emit 444-456 (→CREDITS1 @454); SEND_CREDITS1 457-472
(exit @460-465); SEND_CREDITS2 473-490 (exit @476); `send_nack_req` 439/505-512;
`send_ack_req` default 438. Instantiations `AXI.scala:300-353`. Router `LinkLayer.scala:36-135`
(grant @78).

Override `src/rtl/local_overrides/WlinkGenericFCSM.v`: socl params 64-80; Fix A 293-299 /
987-995; Fix B `_GEN_34` 312-313, applied 696, emit 861-869, param 64; Fix C 316-321 /
65-78 / 698-699; Fix D 300-305 / 1006-1025; Fix E 306-336 / 980 / 1026-1045; arm latch
`socl_l7_reached_link_data` 1000-1004; state FSM 685-703; CR-emit datapath 840-912; CRC-off
default 713. Sideband `WlinkGenericFCSM_6.v:188-192`. Pristine ref
`deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM.v` (state FSM 608-625, no socl).
Sim `cocotb/tidelink_fcsm_silicon_ratio/test_fcsm_silicon_ratio.py` (clean control 126-140,
marginal repro 167+).
