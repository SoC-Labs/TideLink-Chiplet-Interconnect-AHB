# Handover → TideLink RTL agent: the ASIC-line RTL gaps (everything except the a2l port)

**From:** nanoSoC eth-chiplet integration assessment, 2026-08-07.
**Scope:** RTL and RTL-repo artefacts (flists, tests, gates). Physical/constraint items go to the ASIC
agent — `nanosoc-ethernet-chiplet/docs/tapeout/24-d2d-link-physical-handover.md`.

> **This doc deliberately does NOT cover the a2l CDC port.** That is fully specified in
> `HANDOVER_A2L_CDC_PORT_WEDGE_FIX_2026-08-07.md` (port `w_inc=1` + ACK window guard to
> `WlinkGenericFCReplayV2_{1,3,5}`). Everything here is the *rest* of the ASIC-line RTL surface.
> §2 below is the one place the two docs touch, and it is an **improvement** to that fix, not a rival.

> **These are suggestions for your evaluation** — you own this RTL. I've made each one precise enough
> to accept or reject quickly, and marked what I verified directly vs. what I'm reporting second-hand.

**One line:** the ASIC tapeout flist is five days stale relative to the FPGA-proven one, at exactly the
layer where the link bug lives. It ships **ECC bypassed, CRC on at reset, and recovery-stripped FCSMs**
— the FPGA-proven build has the opposite of all three, and no platform has ever run the combination
that would tape out.

Baseline for this doc: submodule at `2c249ec` (FIX 2, Hamming 5→6). I note where `2c249ec`/`20af2b1`
have already moved TL-001 on.

---

## 1. The ASIC flist divergence — three items, one of which looks accidental

Verified by me by diffing the resolved flists and reading both sources. The divergence is confined to
the **Wlink layer**: everything in `tidelink_top.sv`, `calibrator_v2.sv` and `axi_chiplet_controller.sv`
is shared between the two flists, so wr_hold_r, Fix K, F-1, F-2/I5, synth-B, PTP mailbox-RO, the 0x21F8
witness, the calibrator fixes and SWI_FORCE_RECAL all **do** reach silicon. These three do not.

### 1a. Header ECC is dead in the tapeout netlist — **highest severity, and it has no decision record**

| | source | behaviour |
|---|---|---|
| FPGA `tidelink_fpga_v2.flist:243` | `src/rtl/local_overrides/WlinkEccSyndrome.v` | real SEC decode |
| **ASIC `tidelink_top_full_asic_v2.flist:233`** | `deps/…/wlink/WlinkEccSyndrome.v` | **blanket bypass** |

The deps file carries the 2026-05-05 bring-up patch verbatim:

```verilog
// SoC Labs bring-up patch (2026-05-05): force ECC bypass.
assign corrected_ph = ph_in;
assign corrected    = 1'h0;
assign corrupted    = 1'h0;
```

A single-bit `data_id`/`word_count` header flip is then neither corrected nor dropped — it **mis-routes
the beat between FC nodes**. Unlike the FCSM hold (§1c) there is **no flist comment, no decision record
and no ratification gate** justifying this. Commit `1aaed00`'s body claims "flists re-pointed" (plural);
`git show --stat 1aaed00 -- flists/` shows it touched **one**.

**Ask:** re-point ASIC flist `:233` → `src/rtl/local_overrides/WlinkEccSyndrome.v`. One line. If you
believe the bypass should stay for first silicon, that's defensible — but please record it in the flist
the way the FCSM hold is recorded, so it stops looking like a lag.

### 1b. CRC resets **on** in the tapeout and **off** on FPGA

```
src/rtl/local_overrides/WlinkGenericFCSM.v:713   out_prepend_swi_disable_crc <= 1'h1;  // Bug-C: CRC-off default at GPIO speed
deps/…/wlink/WlinkGenericFCSM.v:636              out_prepend_swi_disable_crc <= 1'h0;
```

Polarity is honest — `crc_corrupt = … & ~out_prepend_swi_disable_crc & (computed != received)`
(local_overrides `:195-196`), so `disable_crc=1` genuinely turns checking off. It is **runtime
overridable** via bit[16] at FC-node offset `0x14` (`FC_DISCRC`, already known to
`pynq_host/scripts/xfer_corners_lib.py:107`), so this is recoverable in software either way.

**Ask:** decide this deliberately rather than inheriting it from a stale freeze, and put the reasoning
in the flist or the FCSM header.

### 1c. FCSM recovery stripped on all five AXI data nodes — **the stated gate expired**

ASIC `:270-274` pulls FCSM 0–4 from `deps/` (`grep -c socl_` = **0**, vs 21 in local_overrides): no
`socl_l7_wdog` (state-7 stuck-NACK watchdog), no `socl_reack` (sustained ACK-loss re-emit), no
`socl_l9b/l9c` gap re-anchor, no forgive-disarm. FPGA re-pointed FCSM 0–4 to local_overrides on
2026-07-29 (`tidelink_fpga_v2.flist:277-304`).

The ASIC flist comment says the hold stands "until a silicon ILA confirms the fix". Reported by the
audit and worth your check: **that ILA never happened** — the only silicon ILA in the repo is the
2026-08-02 I5/AHB backstop capture (`docs/ila_capA_i5_fires_2026_08_02.csv`), which has zero FCSM
state/emit probes, and there is no per-AXI-node emit-count readback in the silicon obs to make it
possible. Meanwhile `docs/I1_RESOLVED_HANDOVER_2026_07_31.md:96` concluded "the deps-revert workaround
is no longer required" — and nobody propagated that to the ASIC flists.

**The counter-argument is real and I'd want your judgement on it:** adopting the local_overrides FCSMs
does not merely *add* recovery, it also adds a **state-2 min-CRACK-emit gate that does not exist in the
deps copies at all**. At the original 32 that gate stalled bring-up on a marginal link, and
`docs/I1_FCSM_BRINGUP_REGRESSION.md:23-25` records it stalling at 8 as well (LINK DOWN both dies, two
builds). On a part you tape out once, refusing to add a novel blocking gate to the link-up path is
defensible. Also note the env the flist cites — `cocotb/tidelink_fcsm_silicon_ratio` — appears never to
have run (no `sim_build`, no `results.xml`, referenced by no Makefile target), and two docs already call
it a proxy only.

**Ask:** re-decide with the 07-31 result in hand, and either re-point or refresh the comment with a gate
that can actually be met.

### 1d. Why all three happened

`tidelink_top_full_asic_v2.flist` last changed at `6e3b25d` (**2026-07-29**);
`tidelink_fpga_v2.flist` at `1aaed00` (**2026-08-03**). Every flist-level fix in that five-day window is
FPGA-only. Worth a standing check that both flists move together.

### 1e. They compound

CRC on → NACKs generated. ECC off → corrupt headers reach the framer. No NACK watchdog → the resulting
state-7 wedge is terminal. **No platform has ever run this combination** — the FPGA runs CRC-off *and*
has the watchdog. That interaction is invisible in either flist read alone, which is why it's called out
separately.

---

## 2. **[complements the a2l doc]** A structurally better fix than continuous `w_inc`

The `w_inc = 1'b1` self-heal is a *statistical* remedy — it re-pushes the correct value each mailbox
round-trip so a tear heals within ~1 round-trip. There is a fix one level up that removes the tear
*source*, and on ASIC it matters more than on FPGA.

At gate level, Genus turns the mailbox's `if (we && ~rptr)` into an **integrated clock gate**, and the
enable contains raw, unsynchronised `rptr` from the other domain:

```
NR2D0 g548089 (.A1(..._we), .A2(..._rptr), .ZN(..._n_23));    → ICG enable
```

`WavMultibitSync_18.v:113,122` uses `rptr` directly for slot select; only `w_ready` uses the
**synchronised** copy (`:100`). A `CKLNQD1` is glitch-free only if its enable meets setup/hold; an async
enable cannot, so a violation emits a **runt clock pulse** → partial multi-bit capture → the torn `0x1f`.
On FPGA the same RTL maps to an `FDRE` **CE pin** (a data input), which cannot produce a partial edge —
so this hazard is ASIC-only and does not exist on the platform where the bug was characterised.

**Ask:** consider driving the mailbox slot-select from the **synchronised** `rptr` so the ICG enable
stops carrying an async signal. This is complementary to the `_1/_3/_5` port, not a substitute — keep
both. (The ASIC agent has an interim synthesis-side mitigation: exclude those banks from clock gating.)

---

## 3. Calibrator — FIX 1 covers one of four give-up paths, and is not the binding constraint

Reported by the RTL audit; I have spot-checked the latch and the `force_recal` plumbing but **not** the
full four-arm analysis — please verify before acting.

**a) `validation_timed_out` is a weaker discriminator than the fix assumes.** `give_up_to_done`
(`tidelink_phy_align_calibrator_v2.sv:1662-1670`) has four arms. The shipping V2 instance overrides only
`VAL_TIMEOUT_TO_DONE(1)` and `HOLD_PEER_AWARE_EN(1)`, so with `MAX_RESWEEPS=0` → `retry_exhausted ≡ 0`
(arms 1–2 dead) and `PRBS_EYESCAN=0`/`LANE_PIN_CONVERGE=0` → `escan_en ≡ 0` (arm 4 dead). **Only arm 3
survives.** Three give-up paths still latch `calibrated_once_q`:

| Line | Path | Why uncovered |
|---|---|---|
| `:1502` | `S_FINISH else → S_DONE` (faulted sweep, role_locked low) | arm needs `retry_exhausted` ≡ 0 |
| `:1524` | `S_HOLD !role_locked_sync → S_DONE` | `S_HOLD` appears in no arm |
| `:1557` | `S_VALIDATE !role_locked_sync → S_DONE` before `val_ctr` saturates | arms need `val_ctr >= VAL_MAX` |

`:1524`/`:1557` are the "transient `role_locked` dip" the registry itself flagged as *"also revisit
:1467"* — never done.

**b) More important: even with the latch correctly held at 0, the die still cannot autonomously re-arm.**
`trigger_now` (`:859-861`) is edge-driven and no edge recurs — `calibrator_role_locked` is a level, and
the only autonomous `swreset` source is masked by `~(cal_eye_converged_r | sync_cal_in_hold_1)`.
`cal_eye_converged_r` is a **second sticky**, latched on `calibration_done` with **no
`validation_timed_out` qualifier** — set by a give-up S_DONE exactly as before, and FIX 1 never touched
it. So FIX 1 removes one of two independent blocks, and not the binding one.

**c) The one free measurement that would settle this.** `validation_timed_out` is readable at
**WINSCAN_STAT `0x21E4` bit[5]** (`tidelink_winscan_obs.sv:184`, decode `axi_chiplet_controller.sv:3030`),
and `0x21E4` is in the FPGA V2 flist. Grepping `HANDOVER_HW_RESULTS_FRAMING_WEDGE_2026-08-07.md` for
`21E4`/`WINSCAN` returns **zero hits** — only `0x2104/0x2108/0x2124/0x21F8` were read. "Genuine S_DONE"
was inferred from FCSM=4, which cannot distinguish a give-up. **Reading `0x21E4[5]` on a dropping
bring-up costs one APB read on the existing bitstream** and tells you whether the give-up path is being
taken at all.

**d) Parameterisation asymmetry worth a look.** The V1 instance overrides `HOLD_CYCLES(32768)` /
`VALIDATION_TIMEOUT(2_000_000)` with comments saying the defaults are far too small at 6.25 MHz. The V2
instance overrides **neither** → `VALIDATION_TIMEOUT = 4096` (`:340`) ≈ 655 µs, ~500× shorter than V1
was tuned to need.

**Note:** `2c249ec` (FIX 2, Hamming 5→6) and `20af2b1` (FIX D) have since moved TL-001 substantially —
per the a2l handover, W-direction now crosses 37–50 consecutive byte-exact. Treat this section as
"residual calibrator hygiene", not as the live TL-001 blocker.

---

## 4. Verification gaps — several "proven" fixes have no standing gate

- **The last four RTL commits add zero tests.** `e5bd29c`, `235d758`, `20af2b1`, `2c249ec` touch RTL
  only. FIX 1 could be reverted tomorrow and every gate stays green.
- **The calibrator cocotb suite compiles files that do not contain FIX 1.**
  `cocotb/tidelink_phy_align_calibrator/Makefile:41/47` compiles
  `deps/tidelink-phy/rtl/tidelink_phy_align_calibrator.sv` or `src/rtl/tidelink_phy_align_calibrator.sv`
  — both still at the unfixed `else if (cur_state == S_DONE)`, vs `local_overrides:793`. The cited
  give-up test asserts only `cal_done==1 && validation_timed_out==1`, an invariant that held *before* the
  fix, and drives `role_locked` directly — manufacturing the edge the integrated design cannot produce.
  **From a clean tree the suite exercises RTL without the fix.** Plumbing the local override into a tb
  (with `force_recal_i`) is the coverage gap the registry itself flagged.
- **The `gaps_ecc` gate wiring is stranded.** `63222b6` ("gate: wire gaps_ecc into blocking
  sim_gate_axi_datanode_gaps (TL-006)") exists **only in the standalone clone** at
  `/home/dam1n19/SoCLabs/tidelink` — verified absent from this submodule and, per the integration audit,
  from both remotes. The six ECC tests pass but the blocking gate runs only `gaps_nodes && gaps_backstop`.
- **CI reachability:** the blocking `sim_gate` runs on GitLab, whose newest ref predates this whole fix
  lineage; the fix branches are GitHub-only. Worth confirming — if it holds, the gate has never executed
  against the code that ships.

---

## 5. Flist hygiene (small, but they bite other consumers)

- **The raw ASIC flist does not elaborate.** `tidelink_winscan_obs` (`axi_chiplet_controller.sv:2987`)
  and `tidelink_fcemit_obs` (`Wlink.v:1554`) are instantiated **unguarded** but are in the FPGA flist
  only (`:378`, `:386`). The eth-chiplet parent patches this at
  `flist/nanosoc_eth_chiplet_asic.flist:81-82` and asks for the upstream fix in as many words — so
  **silicon does get the instruments**, but any other consumer inherits a netlist whose CTS will not run
  (`IMPCCOPT-1349`). **Ask:** add both to the ASIC flist, or gate the instantiations on a parameter the
  ASIC build sets to 0.
- **Duplicate entry:** `tidelink_phy_sync_detect.sv` is listed twice in the ASIC flist (`:190`, `:197`).
  Harmless under VCS, a first-wins hazard elsewhere — exactly what `resolve_tidelink_flist.py:19-32`
  exists to prevent.
- **Dormant landmine:** `wlink_wlink_ptp_tl_a2l_48x4` is undefined repo-wide yet instantiated at
  `deps/…/WavFIFO_23.v:103`, and `WavFIFO_23.v` is in **both** flists. It does not bite today only
  because its parent `WlinkGenericFCReplayV2_15` is not elaborated. It fires the moment the PTP FC node
  is enabled.

---

## 6. Silicon-bring-up RTL asks (cheap, and they decide whether first silicon is debuggable)

Reported by the observability audit; the reasoning is sound and the changes are small.

1. **Widen `slv_apb_ctrl_hit` to Regions D and F.** `axi_chiplet_controller.sv:595-600` admits only
   regions 4/8/C, so the I2C sideband **cannot reach** the RX-framer stickies (`0x21A0-A8`) or the
   `0x21F8` witness — the two most useful diagnostics. A three-line change turns I2C into a real
   out-of-band door.
2. **Gate `i2c_slv_reset` on a debug-override bit instead of raw `role_is_master`.**
   `axi_chiplet_controller.sv:3074` `wire i2c_slv_reset = ~hresetn | role_is_master;` — the die that
   wedges in the known failure is the **master**, and its inbound I2C door is held in reset *by
   construction*. With (1), this is the difference between "the wedged die is reachable only if its own
   CPU is alive" and "always reachable".
3. **Map `ext_stall_err_q` to a spare obs bit.** `tidelink_top.sv:940-942` names the omission and the
   reason ("waveform/ILA-visible; not APB-mapped — no free obs-reg slot"). There is no ILA on silicon.
4. **Consider a small event-ordering trace buffer** — even 32×32-bit of timestamped sticky transitions,
   APB-readable. Every surviving silicon instrument is a sticky or a counter, so you can establish *what*
   state was reached, never *in what order*. That ordering is what the FPGA ILA gave you and is the one
   debug capability with no silicon replacement.

---

## 7. One RTL/verification risk on the ASIC-only path

`src/rtl/fifo/asic/tidelink_sram.sv` wraps the TSMC65 `rf_16k` register file — **on the D2D RX FIFO** —
and appears never to have been functionally simulated: the only env compiling the real model
(`uvm/tidelink_top_system`, `GATE=1`) is quarantined, and everything else uses
`syn/asic/sim_stubs/rf_16k_stub.v` in compile-only gates that never run `simv`. The real macro powers up
**random**; the FPGA model powers up **all-zero**, explicitly. That interacts directly with the
phantom-pop guard at `src/rtl/fifo/tidelink_fifo_ctrl.sv:321` and its documented uncovered second case at
`:400`. Worth a targeted sim with a randomised-init model before tapeout.

---

## 8. Suggested order

| # | Action | Cost |
|---|---|---|
| 1 | Re-point ASIC flist `:233` → local_overrides ECC (§1a) | one line |
| 2 | Read `0x21E4[5]` on a dropping bring-up (§3c) | one APB read, no rebuild |
| 3 | Decide CRC reset value deliberately (§1b) | decision + comment |
| 4 | Re-decide the FCSM hold with the 07-31 result (§1c) | decision |
| 5 | Synchronised `rptr` into the mailbox slot-select (§2) | small RTL, pairs with the a2l port |
| 6 | Add obs modules to the ASIC flist, or gate them (§5) | one line |
| 7 | Regression for FIX 1/D/2 against the file that actually ships (§4) | tb plumbing |
| 8 | Bring-up RTL asks 1–3 (§6) | small RTL, high leverage for first silicon |

## 9. Provenance
- Flists: `flists/tidelink_top_full_asic_v2.flist` (`:233` ECC, `:246/257/259` replay, `:270-274` FCSM,
  `:190/:197` dup), `flists/tidelink_fpga_v2.flist` (`:243`, `:277-304`, `:378`, `:386`).
- ECC: `deps/…/WlinkEccSyndrome.v` (bypass) vs `src/rtl/local_overrides/WlinkEccSyndrome.v` (restore).
- CRC: `src/rtl/local_overrides/WlinkGenericFCSM.v:713,195-196` vs `deps/…/WlinkGenericFCSM.v:636`.
- Calibrator: `src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv:791-793, 798-799, 859-861,
  1502, 1524, 1557, 1662-1670`.
- Mailbox/ICG: `src/rtl/local_overrides/WavMultibitSync_18.v:100,113,122`; gate evidence in
  `ASIC/genus-innovus/runs/*/outputs/nanosoc_eth_chiplet_pads_pnr.v`.
- Companion docs: `HANDOVER_A2L_CDC_PORT_WEDGE_FIX_2026-08-07.md` (the a2l port),
  `nanosoc-ethernet-chiplet/docs/tapeout/24-d2d-link-physical-handover.md` (constraints/DFT/flow).
- Memories: `asic-netlist-diverges-from-fpga-proven`, `tl009-wedge-is-a2l-cdc-selflatch`,
  `d2d-rx-word-clock-unconstrained`.
