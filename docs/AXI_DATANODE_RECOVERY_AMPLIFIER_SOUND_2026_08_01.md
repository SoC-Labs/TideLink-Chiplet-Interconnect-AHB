# AXI data-node recovery — SOUND in sim, but STILL HARD-WEDGES on silicon (2026-08-01)

Branch `fix/axi-datanode-recovery`. Follow-on to `docs/AXI_DATANODE_RECOVERY_GAP_2026_07_31.md`
(the on-silicon hard-wedge), Fix G (`WlinkGenericFCSM*.v`, NACK/replay forgive-disarm + CRC-on)
and the I5 ahb_sub outstanding-response backstop (`tidelink_top.sv`).

> **⚠ CORRECTION (2026-08-01 PM, from a HW run — see "HW RESULT" below).** The sim
> conclusion in this doc ("the amplifier bounds a lost B to HRESP=ERROR; the HW wedge is
> physical eye-margin") is **REFUTED by silicon.** On a **confirmed-good eye** (a clean
> cross-die transfer passed immediately before), an errinject on the B node **hard-wedged
> die_a's entire PS (JTAG-POR), for BOTH byte 4 (header) and byte 5 (CRC-detectable payload),
> with Fix G + I5 + CRC all present and armed.** So the amplifier is sound only against the
> failure mode the sim tb can model (a cleanly-DROPPED response); against a real single-bit
> CORRUPTION that gets accepted/mis-delivered it is NOT sufficient on silicon. The wedge is
> **not** physical eye-margin. Read the "HW RESULT" section as the current truth; the sim
> analysis below is correct *for its model* but does not cover the silicon failure path.

## The question this settles

The 2026-08-01 HW run hard-wedged die_a (JTAG-POR only) on a B-response error **even though
I5 and Fix G were both confirmed present** in the built bitstream. Two hypotheses were open:

- **(H1)** The data-path recovery amplifier (Fix G + I5) has a residual RTL bug — e.g. the I5
  single-bit outstanding tracker (`sub_wr_os_r`) is defeated by streaming / spurious B beats
  ("Fix H", a per-transaction counter, was the candidate).
- **(H2)** The amplifier is sound and the hard-wedge is a **physical eye-margin** failure —
  the frozen one-shot sample point (`calibrated_once_q`) corrupts *every* beat including
  CR/CRACK/credit/ACK, degrading the whole link, which no data-path flow-control can cure.

## The experiment (decisive)

`cocotb/tidelink_axi_datanode_recovery/test_axi_b_persistent_eye_bounded` models the
persistently-marginal eye directly: it **holds the Wlink TX injector's `err_inj_smack` latch
high** (Force), so every B SOP — and every NACK-driven replay — is re-corrupted. Replay can
never converge, exactly as on the frozen HW eye. Fix G on, CRC on.

**Result (non-vacuous at both the 2^13 fast variant and the 2^16 default I5 timeout):**

```
class = ERROR   nack_fired = True   i5_err = True   os_hi = True
```

i.e. the recovery FSM tries (NACK fires), the write stays outstanding (`sub_wr_os_r` high
throughout), and then **I5 fires (`sub_err1_r`) and bounds the never-returning response to a
recoverable `HRESP=ERROR`** — never a silent hard-wedge.

**Conclusion: H1 is refuted, H2 stands.** On the data path, a persistent lost B becomes a
bounded SIGBUS, not a hang. "Fix H" (the per-transaction I5 counter) was therefore **NOT
landed** — it would be a blind fix for a hole the experiment did not demonstrate. The
on-silicon hard-wedge is a **physical eye-margin** failure of the same class as the Z2 saga
(`project_z2_no_data_rootcause_beacon_starves_corrector`), not a recovery-path defect.

Caveat honestly stated: the AHB tb master does not BID-match, so it cannot model the
CRC-OFF wrong-BID silent mis-deliver (the one mechanism I5 structurally cannot catch — it
counts B *arrival*, not BID). With CRC **on** (Fix G) that mechanism is closed at the receiver
(a corrupt B fails CRC → NACK, never egresses a spurious `bvalid`), which the experiment
above exercises. So the residual is purely physical, given Fix G's CRC-enable is applied.

## What is proven / shipped

- Fix G (`WlinkGenericFCSM*.v`) — recovery FSM forgive-disarm on LINK_IDLE + CRC-enable.
- I5 (`tidelink_top.sv`) — ahb_sub outstanding-response backstop; **verified present** in both
  eth-chiplet bitstreams (`imp/fpga/.../ipshared/*/src/tidelink_top.sv`).
- NEW: `test_axi_b_persistent_eye_bounded`, gated in `sim_gate_axi_datanode_recovery`
  (now 5 tests, all PASS). Locks in "a persistent lost B is bounded, never a silent hang".

## The remaining fix targets the PHYSICAL layer — Fix I (autonomous eye re-cal)

Root cause of the physical wedge (per the 4-agent diagnosis): the RX sampling eye is
calibrated **once** at bring-up and then frozen — `calibrated_once_q`
(`tidelink_phy_align_calibrator_v2.sv:771-775`) latches on first `S_DONE` and gates off every
automatic re-trigger; the per-lane `(slip, phase)` sample point is frozen at `S_FINALIZE`.
The V2 `SYNC_REANCHOR` / `EPOCH_ANCHOR` corrector self-heals **word-skew** drift but does
**not** touch the **bit-sampling eye**. The only post-lock eye re-cal is the **manual**
`SWI_FORCE_RECAL` W1P (Region 8 slot 0 bit[6], `0x44032100[6]`), which is ungated by
`calibrated_once_q` by design (`calibrator_v2:790,838`) and drives a proven full re-sweep.

**Fix I = make that re-cal autonomous.** The re-arm machinery already works end-to-end (it is
the P1 fix); the only missing piece is an autonomous driver of `force_recal_i`.

Minimal design (reuses 100% of the proven sweep path):
1. In `axi_chiplet_controller.sv`, add a free-running interval counter (apb_clk domain,
   alongside the `swi_force_recal_r` stretcher at `:1217-1241`) that periodically emits the
   **same** pulse shape into `force_recal_i`.
2. Gate it behind a **new DEFAULT-OFF enable** (a spare Region 8 slot-0 bit or a param), so a
   disabled build is bit-identical / zero-regression — as every other TideLink autonomy knob.
3. **The quiesce gate is the substantive, safety-critical work.** A re-cal re-asserts
   `training_mode` and squelches CR/CRACK for the sweep window — this is exactly **Bug-A**,
   the hazard `calibrated_once_q` was added to prevent (a mid-credit-init recal wedged the
   master at FCSM state 2 with zero TX credit). The autonomous trigger MUST fire only when
   safe: qualify on FCSM data-mode **and not credit-init**, ideally link-idle, or accept a
   bounded per-sweep stall. Get this wrong and Fix I *causes* the wedge it aims to prevent.

**Why Fix I is NOT landed here (deliberately):**
- Its *benefit* cannot be sim-validated — sim does not model eye drift, so "periodic recal
  keeps the eye centred" is unprovable without silicon.
- Its *safety* (the quiesce gate) cannot be HW-validated now — the rig is eye-margin-blocked,
  the exact resource Fix I needs. Landing a live autonomous-recal that reintroduces a known
  chip-wedging hazard, unvalidated, is precisely the blind-fix the project rules forbid.

**Validation plan (for a HW-capable session):**
- Sim (landable now, if desired): prove (a) OFF → zero `force_recal` pulses (inert /
  bit-identical), (b) ON → periodic `force_recal_rise`, calibrator leaves `S_DONE` and
  re-latches `(slip,phase)`, (c) with the idle-gate, data still crosses byte-exact across a
  recal window. This proves inert-when-off + fires-when-on, NOT that it cures drift.
- HW (the real gate): on a rig with a characterised marginal eye, enable Fix I and show the
  link survives where the frozen eye wedges; sweep the interval vs the drift rate.

Until then: the manual `SWI_FORCE_RECAL` poke is the operational mitigation (host polls
Region C `cal_state` / a CRC/FIFO health reg between transfers, re-cals on degradation).

---

## HW RESULT (2026-08-01 PM) — the amplifier does NOT save the initiator on silicon

Ran the finishing errinject round on the KR260 eth-chiplet pair (die_a `kr260_01`
10.22.24.159, die_b `kr260_02` 10.22.24.153), Fix-G bitstreams (the `imp/fpga/output`
build with I5 verified in the synthesized `ipshared/*/src/tidelink_top.sv`).

Sequence (both dies, twice — once per inject byte, each a fresh POR→deploy→bringup cycle):
1. POR both → deploy Fix-G → `bringup_pair_release.sh` → **LINK UP fcsm=4 BOTH DIES**.
2. `kr260_eth_bringup.py --enable-axi-crc` → **CRC ON all 5 nodes both dies** (`0x00010708→0x00000708`).
3. **Eye gate — clean `sender`→`recv` peer-write: byte-exact PASS** (0xC0FFEE01 / 0xC0FFEE02
   crossed to die_b SRAM). Confirms the eye is good *this* calibration window.
4. `kr260_eth_xfer.py --mode errinject --node B --inj-byte {4,5} --inj-bit 0 --seed 0xBEEF`.

| Inject | Eye (clean xfer just before) | Outcome |
|---|---|---|
| B, byte 4 (pktnum/header) | GOOD (byte-exact) | **die_a HARD WEDGE** — PS fully down (100% ping loss + SSH dead), JTAG-POR required |
| B, byte 5 (CRC-detectable payload) | GOOD (byte-exact) | **die_a HARD WEDGE** — identical (PS down, JTAG-POR) |

After the byte-4 wedge, **die_b was polled and stayed completely healthy**: fcsm=4, every FC
node CRC 0→0, `STATUS=0` no sticky faults, `CREDIT_COUNT=4096`, Region F `data_healthy=1`, no
wedge-sticky. So the corrupted B deadlocked **die_a's PS locally**; die_b never saw a fault.

### What this proves (empirical, high confidence)
- The initiator hard-wedge is **NOT** marginal-eye margin — it reproduces on a **confirmed-good
  eye**, twice. (This corrects the 07-31 "restored to working link" and the sim-side
  "physical eye-margin" attribution.)
- **Fix G + I5 + CRC-on are all present and armed and do NOT prevent it**, for two different
  inject bytes. A full-PS death (ping gone) is *worse* than the HRESP=ERROR SIGBUS the sim
  produces — the PS interconnect itself deadlocks, not one erroring transaction.

### What it means (mechanism — stated as the leading hypothesis, NOT verified on the wedged board)
This is precisely the failure path the sim tb **could not model** (flagged at the time): the
AHB master BFM does no BID-matching, so it can only model a *cleanly-dropped* B (→ I5 fires →
HRESP=ERROR). On silicon the corrupted B is very likely **ACCEPTED** (`s_axi_bvalid` pulses
with bad data) → I5 *disarms* (it counts B **arrival**, not BID correctness — Agent-4 "Gap 2")
→ the mis-delivered B propagates **upstream of `tidelink_top`** to the Xilinx
`axi_ahblite_bridge` / PS SmartConnect, which rejects the wrong-BID/protocol-bad beat and
**hard-deadlocks with no backstop** (there is no I5 there). CRC-on *should* have NACK'd the
corrupt B at die_a's B-node receiver before egress — that it wedged anyway means either the
CRC→NACK path does not gate egress on silicon, or the corruption is outside the field the
B-node CRC guards. **Not verifiable from a wedged PS without JTAG/ILA — do not treat the
mechanism as settled.**

### The real fix direction (supersedes "Fix I is the only remaining fix")
Fix I (eye re-cal) is now **secondary** — the eye was good and it still wedged. The primary gap
is the **accepted-corrupt-B / upstream-interconnect deadlock**, which needs one or more of:
1. **A backstop upstream of `tidelink_top`** — an AXI Firewall / AXI Timeout IP in the PL
   between PS HPM0 and the SoC AXI (FPGA-only), so a stuck/rejected B becomes a bus error the
   PS survives instead of a full deadlock. Cheapest path to "no more JTAG-POR".
2. **Make I5 not disarm on a mis-matched B** — track expected BID / don't clear the outstanding
   state on a B whose id/resp is wrong. (I5 lives in `tidelink_top`; needs BID visibility.)
3. **Verify + fix why CRC-on did not prevent the corrupt-B egress on silicon** — the B-node
   CRC→NACK is the first line of defense and it did not hold here.

### The sim task that must precede the next HW round (close the blind spot)
Build Agent-4's "Construction B": a **BID-checking AXI master BFM** on die-m's `s_axi` (replacing
the non-checking AHB master), so a *corrupted-but-accepted* B (wrong BID) reproduces the
**initiator hard-hang in sim** — the current tb cannot. That sim becomes the fast triage loop
for the three fix candidates above; a HW errinject is a ~1.5 h build+bench cycle per hypothesis.

Boards left POR-recovered (die_a un-wedged), leases released.

---

## FIX H HW RESULT (2026-08-02) — sim-proven I5 counter did NOT resolve it; mechanism re-pinned

Root-caused the sim blind spot to **Gap 1 (multi-outstanding I5 masking)**: an XHB500
RTL audit proved the early-write-response path keeps up to **4 writes outstanding** on
s_axi, so I5's single-BIT write tracker mis-counts (a later B clears it while an earlier
write is stuck). Implemented **Fix H** = a saturating outstanding COUNTER (commit
`32d9d5e`), sim-proven (6-test gate GREEN: counter tracks depth-4, byte-exact recovery,
stalled burst -> HRESP=ERROR), rebuilt both eth-chiplet bitstreams (provenance verified:
`sub_wr_os_ctr` in both `ipshared/*/src/tidelink_top.sv`), deployed, brought up fcsm=4,
CRC on, clean eye-gate PASS.

**errinject B byte 4 with Fix H: die_a HARD-WEDGED AGAIN** (100% ping loss, JTAG-POR).
Fix H did NOT resolve it — the THIRD time HW overturned a sim-based conclusion here.

**Decisive diagnostic (`--stream 0` = inject + the SINGLE corrupted beat, NO resume
stream): STILL hard-wedges.** So the culprit is **one** peer write with a corrupted B —
**NOT** the multi-outstanding stream. This conclusively **rules out Gap 1** and Fix H as
the mechanism.

**Mechanism, now pinned (CASE B):** the corrupt B is **EGRESSED** to s_axi (not dropped
by the receiver despite CRC-on), so `sub_b_done` pulses (wrong data/BID), I5 correctly
decrements to 0 ("B returned") and never fires — but the mis-delivered B is **rejected
UPSTREAM of tidelink_top** (the Xilinx axi_ahblite_bridge / PS SmartConnect BID-match),
which hard-deadlocks the whole PS. No I5/tidelink_top backstop can reach upstream, so
Fix G (recovery) and Fix H (I5 counter) both cannot help — confirmed empirically.

**The two remaining fix paths (both a different class than G/H):**
1. **FC-node drop-guarantee (tidelink RTL):** make the B-node DROP a CRC-failed /
   not-expected B so it never egresses -> the B "never returns" -> I5 catches it (single
   write, ctr=1) -> HRESP=ERROR (bounded). Surgical, but developing it needs die_a
   observability (WHY the corrupt B egresses despite CRC-on) — and die_a is exactly what
   wedges, so this needs JTAG/ILA on the PL registers, or a board-persistent trace.
2. **Upstream AXI Firewall / AXI Timeout IP (FPGA block design):** insert between PS HPM0
   and the SoC AXI so ANY stuck/rejected transaction becomes a bus error the PS survives
   (no deadlock, no JTAG-POR). Mechanism-agnostic, guaranteed to kill the total-PS-wedge,
   needs no observability — but it's an eth-chiplet BD change + ~1.5 h rebuild and masks
   rather than fixes the mis-deliver.

Fix H remains a genuine correctness improvement (the single-bit tracker IS wrong for the
depth-4 EWR path) and stays landed + gated — it just is not THIS wedge's cause. Boards
POR-recovered, leases released.
