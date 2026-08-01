# AXI data-node recovery — the amplifier is SOUND in sim; the HW wedge is physical (2026-08-01)

Branch `fix/axi-datanode-recovery`. Follow-on to `docs/AXI_DATANODE_RECOVERY_GAP_2026_07_31.md`
(the on-silicon hard-wedge), Fix G (`WlinkGenericFCSM*.v`, NACK/replay forgive-disarm + CRC-on)
and the I5 ahb_sub outstanding-response backstop (`tidelink_top.sv`).

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
