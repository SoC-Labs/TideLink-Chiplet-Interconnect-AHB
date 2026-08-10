# Handover → TideLink agent: link reliability — the wedge is EYE-GATED, here's how to harden it

**From:** nanoSoC eth-chiplet integration (KR260 two-board silicon), 2026-08-08.
**One line:** On a **good-eye** bring-up the pair now works *hard* — I ran **2576 cross-die writes
(64 + 256 + 256 + 2000) byte-exact, zero drops, zero wedge, across two bring-ups**. So FIX 1/D/2
turned the data-path good; the remaining reliability problem is that **whether a bring-up lands a
good eye is a lottery**, and a bad eye still drops (TL-001) and wedges die_a (TL-009). This doc is
about converting that lottery into **reliable** operation. Everything below is a **suggestion for
your independent evaluation.**

Companion docs (all in tidelink/docs/): `HANDOVER_HW_RESULTS_FRAMING_WEDGE_2026-08-07.md`,
`HANDOVER_A2L_CDC_PORT_WEDGE_FIX_2026-08-07.md` (the a2l port — still the top item). System-wide test
holes: `nanosoc-ethernet-chiplet/docs/SYSTEM_VALIDATION_HOLES_REPORT_2026-08-08.md`. Memories:
`peerwrite-drop-is-phy-framing` (updated with the 08-08 eye-gated result),
`tl009-wedge-is-a2l-cdc-selflatch`, `d2d-rx-word-clock-unconstrained`.

## 0. Test-harness changes that would PROTECT this reliability work
Reliability fixes are worthless if a regression can land green. The system-validation report found
three reliability-relevant false-greens — please fix these alongside the RTL:
- **The durable HW regression is data-plane-OFF by default** (`kr260_eth_regress.py:277-282`) — a
  data-drop regression passes without moving a byte. Invert to data-plane-ON.
- **No recovery-after-wedge gate** — nothing asserts "wedge → recover → data plane works again"; add
  one (it also gives us mean-writes-to-wedge, the reliability metric).
- **The tapeout ASIC netlist ships the AXI FC nodes recovery-STRIPPED** (`socl_l7`=0) while sim
  validates the FPGA recovery config — so the a2l port (and every recovery fix) must be proven against
  the ASIC-V2 flist, not just FPGA-V2, or the silicon reliability gain is unverified.

---

## 1. The reliability picture (silicon, 2026-08-08)

| Condition | Behaviour |
|---|---|
| **Good-eye bring-up** (both dies reanchor try 1) | **2576/2576 cross-die writes byte-exact**, die_a alive, `RegionF data_healthy=1`, `wedge-sticky=0x00`, repeatable across 2 bring-ups |
| Witness during those runs | `0x21F8=0xb5000421` — ONE *transient* stall-stuck (bit10) that **self-recovered**; synth-B never fired (bit8=0) |
| **Bad-eye bring-up** (08-07 concurrent bench) | data drops (die_b=0), die_a wedges after ~4–50 writes (`0x21F8=0xb5000521`, synth-B fired) |

**Diagnosis:** the residual is a **physical, per-bring-up die_a RX-eye lottery on the B-return
direction** (die_a WNS −2.862 vs die_b −1.752, STA-invisible). Good eye → B returns → no stall, no
wedge, data lands indefinitely. Bad eye → B lost → replay window fills → wedge. The `0xb5000421`
witness (even on a *good* run, a transient stall-stuck latched once) says the eye is **marginal but
adequate** when it lands well — it is not clean. Reliability = removing the dependence on the eye
lottery.

## 2. Reliability levers, prioritised (suggestions)

**(1) Make a bad eye SURVIVABLE — the a2l CDC port (top priority, already handed over).**
Today a lost-B → permanent a2l self-latch → wedge. Porting the continuous-`w_inc` + ACK-window
guard from `WlinkGenericFCReplayV2_{12,13}` to the AW/W/B nodes `_{1,3,5}` (+ flist repoint) makes a
lost-B **self-heal within ~1 mailbox round-trip** instead of wedging. This is the single highest-
leverage reliability change: it converts the catastrophic failure (PS wedge, JTAG-POR to recover)
into graceful degradation (a retried beat). Full spec in
`HANDOVER_A2L_CDC_PORT_WEDGE_FIX_2026-08-07.md`. With it in, a bad-eye bring-up degrades instead of
dying — which also makes it *measurable* (a soak can run to completion and report a land-rate).

**(2) Make the eye/framing DETERMINISTIC — remove the lottery.**
- **RX word clock is unconstrained** (`d2d-rx-word-clock-unconstrained`): the /16 recovered RX clock
  fans out to ~16.5k flops with **no CTS clock tree / no skew target** — a physical hazard directly
  on the B-return capture path. Add the eight `create_generated_clock`s (draft in that memory) and
  re-close; this is the most likely deterministic-eye win and it's an ASIC-flow (SDC) fix, not RTL.
- **die_a RX pin/eye** is the physical asymmetry. If a board re-pin or capture-clock phase trim is
  feasible, it directly attacks the −2.862 outlier. (Bench-side, not yours — flagging for the owner.)
- The calibrator work (peer-aware S_HOLD, centering-on, Hamming 5→6) already improved the *data*
  direction markedly; the residual is the *B-return* capture, which the calibrator's winscan may not
  be optimising (winscan `best_run` reads 0 even on landing runs — an obs artefact per your commit).
  Worth checking whether the calibrator centres the B-return (l2a on die_a's RX) eye, not just a2l.

**(3) Bring-up-time eye QUALIFICATION (turn lottery → bounded retry).**
Reliability doesn't strictly require a deterministic eye if bring-up can **detect a bad eye and
retry until good**, bounded. Today there's no *predictive* eye metric — `reanchored=1` + `FCSM=4`
do NOT imply a good eye (08-07 wedged with both set). Suggest a **SW-readable per-lane eye/BER
margin** (e.g., a short built-in B-return loopback or a lane-error counter sampled over N cycles at
the end of bring-up) so the turnkey orchestrator can reject a marginal eye and re-winscan before
handing the link to the app. This makes the demo/product reliable even while the eye stays marginal.

**(4) Explain the transient stall-stuck (bit10) on good runs.**
Even the 2576-write clean session latched `xhb_stall_stuck_sticky` once. Worth understanding: is it
a single startup transient (harmless) or evidence the B-return occasionally stalls ≥2¹² and recovers
(a reliability margin eater under temperature/aging)? A non-sticky *count* (how many ≥2¹² stalls per
run) instead of a sticky bit would quantify the margin. Cheap obs change, high diagnostic value.

## 3. Observability asks (small, high-value)
- A **per-run stall COUNT** (not just the sticky bit) at `0x21F8` or a sibling word.
- A **B-return-specific** health/error counter (the wedge is B-return; today `0x21F8` is near-side
  XHB500-centric). A lost-B counter would directly track the eye lottery.
- A **predictive eye-margin** readout at end-of-bring-up (see lever 3).
- Fix the stale deployed `kr260_eth_soak_fwd.py` (its `verify` mode prints nothing on the board — I
  had to read die_b SRAM directly) so soak results are trustworthy in CI.

## 4. What I'll do on the eth-chiplet / bench side
- Bench the a2l CDC port once it lands (success = a bad-eye bring-up degrades instead of wedging).
- Run a **multi-bring-up eye-lottery sweep** to quantify the good-eye hit-rate (needs the a2l port so
  bad-eye runs don't wedge every few writes).
- Add the RX-word-clock `create_generated_clock`s on the ASIC side and re-measure (coordinating with
  the ASIC session).

## 5. Provenance
- HW: 2576/2576 byte-exact across 2 bring-ups, 2026-08-08, tidelink `2c249ec` bits (FPGA-equivalent
  to `1febd59` for the data/wedge path). Witness `0x21F8=0xb5000421`. Rig left clean.
- Bug status: `docs/BUG_REGISTRY.yaml` — TL-001 and TL-009 both `root_caused` (eye-gated).

**Ask:** land the a2l CDC port (lever 1) so a bad eye degrades instead of wedging; then the
RX-word-clock constraint (lever 2) for a deterministic eye; and consider the eye-qualification
metric (lever 3) so bring-up can guarantee a good link before handing it to the app.
