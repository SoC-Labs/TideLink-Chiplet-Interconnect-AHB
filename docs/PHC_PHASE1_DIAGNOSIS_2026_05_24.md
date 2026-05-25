# PHC Phase-1 — Diagnosis State of Play (2026-05-24)

**Status:** single-source-of-truth diagnosis snapshot at end of 2026-05-24
multi-agent debug session. Synthesises ten builds (#14–#23), six "Agent"
hypotheses (A–J), and the first successful slave-side ILA capture. Use this
doc for *what is the bug today, what's been ruled out, what's the next
experiment*. Use `docs/PHC_PHASE1_HW_REPORT.md` for the per-build raw
evidence chain that this synthesis is built on.

> **Supersedes for diagnosis purposes:** the open *diagnosis* sections of
> `docs/PHC_PHASE1_HW_REPORT.md` (everything below "Phase-1 PHC status —
> autonomous loop exhausted"). The HW report is retained for historical
> evidence and per-build raw output; **for the current working hypothesis,
> read this file**.

---

## 1. The bug, in one paragraph

**bridge1 master fires HW_SYNC packets at ~128 Hz; the slave APB reads
`HW_SYNC_STATUS = 0x0` and `PTP_CTRL[2] rx_valid = 0` indefinitely. No
PHC short-packet has ever been observed accepted by the slave on
silicon (~10 hours of HW soak across 13 build cycles since the IP became
deployable on 2026-05-23).** Sim reproduces the integration end-to-end and
PASSes (including with `USE_FPGA_MODELS=1` elaborating `IDELAYE2` /
`IDELAYCTRL` / `BUFG` primitives). RTL is sim-exonerated. Reset,
configuration, address-map, and board-specific causes have been ruled
out in this 2026-05-24 session by live HW probes. **The remaining live
hypothesis is a synth/placement-induced FF mismatch on the slave's
consumer-side replica of `ptp_enable_r` driving `rx_accept` in
`tidelink_ptp.sv:288`** (Agent J's #1 candidate).

---

## 2. Working hypothesis (post-2026-05-24)

### Statement

In `src/rtl/tidelink_ptp.sv:288`:

```systemverilog
wire rx_accept = ptp_sp_rx_valid & ptp_enable_r;
assign ptp_sp_rx_accept = rx_accept;
```

`ptp_enable_r` is a single FF written by the APB `PTP_CTRL[0]` write. It
fans out to **multiple consumers** in the same module (the TX-gate at
`tidelink_ptp.sv:272`, this `rx_accept` AND, and several status reads).
Synth is free to replicate `ptp_enable_r` per-consumer, and Vivado will
place each replica near its load — meaning the *replica* feeding
`rx_accept` may sit in a fabric region where its capture is broken
(initial value 0, never updated, or its preceding clock-enable path
pruned), while the *replica* whose value is read back over APB sees a
clean 1. **APB readback of 1 does not prove the RX-gate replica reads 1**.

Build #21 attempted to harden `ptp_enable_r` itself with `(* dont_touch *)
(* keep *)`; this prevents the *root* FF from being pruned but does not
prevent synth from inserting a *fresh* replica downstream of it during
placement. Build #23's `(* keep *) (* dont_touch *)` on FSM-state FFs
`hw_sync_trigger`, `tx_state_r`, `tx_pending_r`, `hw_sync_state_r` did not
rescue the path either, because **the bug is consumer-side, not
producer-side, and the consumer is in the RX domain**.

### Proposed fix (b24)

```systemverilog
// tidelink_ptp.sv:288 — decouple RX from enable. Always-on accept on RX side.
// TX gating at line 272 is retained: a disabled instance still must not TX.
wire rx_accept = ptp_sp_rx_valid;
```

Rationale:

1. **Eliminates the replicated consumer.** No FF mismatch can exist if
   the gate isn't there.
2. **Functionally safe.** The slave's classifier upstream
   (`ll_rx → sp2wl → ptp_sp_rx_*`) already filters by `data_id`. A
   stray PTP short-packet on a disabled slave is silently latched into
   `ptp_rx_payload_r` — software just doesn't read it. No bus traffic,
   no state escape, no IRQ until SW explicitly enables.
3. **TX path stays gated.** Even on a disabled slave that receives
   stray PHC packets, no TX response goes out: the gate at line 272
   (`ptp_sp_tx_valid = (tx_state_r == TX_SEND) & ptp_enable_r`) holds.
4. **Smallest possible RTL diff.** 1 line. Mirrors Bug-#3 class fix
   precedent on `feat/i2c-autonomous-lock-integ` (decouple
   `nego_driving`).

### What this hypothesis predicts and how to falsify

- Predicts: after b24 deploy on bridge1 with full provenance check, slave
  `HW_SYNC_STATUS` exits 0x0 within seconds of master HW_SYNC enable.
- Falsifies if: slave still reads 0x0. That would push diagnosis to the
  next-tier RX-physical layer (clock-recovery race on first master edge,
  P&R skew past IDELAY tap range, or `set_bus_skew` constraint margin
  exhaustion — see §6).
- The b22 ILA submodule (already built, see §5) can directly observe
  `sp2wl/rx_pkt_valid` and `ll_rx/decode_state` to discriminate
  between "fix worked" and "physical-layer remains broken".

---

## 3. What's been ruled out (2026-05-24 session)

| Agent | Hypothesis | Status | How ruled out |
|---|---|---|---|
| **A** | Master TX FSM stuck — `hw_sync_trigger` synth-replicated, FSM never advances | **RULED OUT** | Build #23 (`feat/phc-fsm-harden-b23` + `feat/phc-trigger-replicate-b23`) hardened `hw_sync_trigger` + `tx_state_r` + `tx_pending_r` + `hw_sync_state_r` with `(* keep *) (* dont_touch *)`. Bug persisted. Also, ILA on master's `sp2wl/tx_valid` showed master IS transmitting valid SP packets. |
| **B** | BD address-map asymmetry between pair-all and pair-flip-all | **RULED OUT** | Agent E diff: pair-all and pair-flip-all `.bd` files are byte-identical after comment strip; only the pin map mirrors (Y9 ↔ Y7 RX-clk, etc.). No address-decode delta. |
| **C** | Slave reset-race / `rx_link_clk_reset` releases late, missing first packets | **RULED OUT** | Live test: pulsed slave's `swi_swreset` after lane-locked + master HW_SYNC running. Slave `rx_valid` stayed 0; no packets rescued. If the bug were reset-race, the first packet post-reset-deassert would have latched. |
| **D** | Slave missing config write — LLRX `EnableReset` not programmed | **RULED OUT** | Slave's `0x4403_0208 EnableReset` reads `0x00027f07` at reset default already. No config write needed; the value matches the working master. |
| **F** | `cr_seen` asymmetry (master cr_pkt_seen=0, slave cr_pkt_seen=1) | **BENIGN, not the PHC bug** | Boot-race: slave's RX byte-aligner misses the first CR but FCSM advances via the CRACK path; system self-heals. cr_seen state diverges harmlessly. Not correlated with PHC packet drops (PHC packets keep being lost long after CR-seen logic has settled). |
| **G** | Board-specific defect on z2_02 or z2_03 | **RULED OUT** | Agent G's SWAP=1 test: z2_03 acts as master in flipped role, works fine. z2_02 as slave with `tidelink-flip.bin`, broken. Bug is in the *slave role*, not the *physical board*. |
| **H** | Cable/JTAG-induced disturbance | **RULED OUT** | Same SWAP test — physical cabling identical, only role assignment changed. |

### Cross-reference to earlier ruled-out hypotheses (pre-2026-05-24)

| Agent / candidate | Status | Doc |
|---|---|---|
| Agent Q — replica-prune of `ptp_enable_r` root FF | Ruled out by build #13 `(* dont_touch *) (* keep *)` on root FF (slave still 0x0) | PHC_PHASE1_HW_REPORT.md §"Build #13" |
| Agent R — IDELAY/BUFG sim-vs-HW divergence | Ruled out: sim with `USE_FPGA_MODELS=1` PASSES (real unisim primitives elaborated) | SIM_HW_GAP_ANALYSIS.md |
| Agent N — TB-helper write race | Closed in sim by `609482f`; never an HW factor |
| Slave RX_DIAG counter mis-decode | Real (build #11 saw nonsense values), but is itself a separate debug-tool bug — not the PHC RX bug |

---

## 4. Builds #14–#23 verdicts (one line each)

| Build | Branch | Change | HW verdict |
|---|---|---|---|
| #14 | feat/phc-ila-debug | re-enable `mark_debug` across slave RX; submodule bump for ILA | FAIL — slave 0x0; ILA itself unstable (dbg_hub WHS) |
| #15 | feat/phc-ila-debug-b15 | b14 + WHS waiver attempts | FAIL — WHS -7.94 ns, board wedged within 3 min |
| #16 | feat/phc-ila-debug-b16 | b15 + further mark_debug shaping | FAIL — `hw_sync_trigger` provably synth-replicated; plan #17 = register the trigger |
| #17 | feat/phc-trigger-register-b17 | registered `hw_sync_trigger` into a fresh FF | FAIL — identical to #14/#15/#16 (slave 0x0) |
| #18 | feat/phc-handshake-fix-b18 | asymmetric handshake fix + WHS hold fix | FAIL — slave 0x0 |
| #19 | feat/phc-minimal-fix-b19 | minimal handshake variant + DCP+timing preservation | FAIL — slave 0x0 |
| #20 | feat/phc-slave-rx-fix-b20 | slave-side replica defence + b19 handshake + Agent T XDC | FAIL — slave 0x0 |
| #21 | feat/phc-manual-replicate-b21 | **manual per-consumer FF replication** of `ptp_enable_r` (root cause inverse of #14 finding) | FAIL — slave 0x0; proves manual replication producer-side doesn't help when the *consumer-side replica* is what's miscaptured |
| #22 | feat/phc-ila-submodule-b22 | submodule bump (ae2ca38 → 8a4fcf5) to instrument `sp2wl` TX-path with ILA inside `axi_chiplet_controller` | FAIL functionally (slave 0x0), but **ILA PIPELINE WORKING for first time** — first successful ILA trigger on slave `sp2wl/rx_pkt_valid` proves master IS transmitting and slave IS receiving the SP at the Wlink-layer |
| #23 | feat/phc-fsm-harden-b23 | `(* keep *) (* dont_touch *)` on `hw_sync_trigger` + `tx_state_r` + `tx_pending_r` + `hw_sync_state_r` (per Agent A's full recommendation) | FAIL — slave 0x0. **Definitively rules out Agent A** — even when every FSM-state FF is protected, slave never accepts |

**Key inflection points across this band:**

- #16 → #17 transition: confirmed the trigger was being synth-replicated,
  but registering it didn't help (because the bug isn't there).
- #21 → #22 transition: gave up on RTL fixes, moved to instrumentation.
- #22: **ILA pipeline came up for the first time** — see §5.
- #23: definitive disproof of Agent A's hypothesis, which was the strongest
  pre-2026-05-24 candidate.

---

## 5. ILA pipeline came up — operational improvement

**This is the major win of the 2026-05-24 session, independent of the
bug status.** Until b22, slave-side ILA capture was impossible because
of WHS issues with `dbg_hub` and the lack of a stable JTAG path to the
two boards. b22 ships a clean version.

### Components

| Component | Where |
|---|---|
| Vivado 2025.2 | mapstone-dev workstation |
| `hw_server` | `mapstone-dev:3121` (TCP) |
| FT2232H JTAG cables | one per PYNQ board, USB → mapstone-dev |
| Boards reachable via JTAG | z2_01, z2_02, z2_03, z2_04 (4 of 4) |
| ILA wiring in submodule | `axi-chiplet-controller@8a4fcf5` — `sp2wl/tx_valid`, `sp2wl/rx_pkt_valid`, `sp2wl/rx_data_id`, `ll_rx/decode_state`, plus user-extendable list |
| Capture script | `pynq_host/scripts/phc_ila_capture.tcl` (worktree edit in `td-bisect/v1-consolidated/`) |
| Trigger primitive | `TIDELINK_TRIGGER_VALUE` env var for multi-bit FSM triggers (b20 branch added support) |

### First successful capture (2026-05-24)

Trigger: slave `sp2wl/rx_pkt_valid` rising edge. **Fired.** This is the
"smoking gun" datum that excluded Agent A entirely — the Wlink layer on
the slave does see valid SP packets with `dataIdMatch=1`. The packet
reaches `ptp_sp_rx_valid` but is then dropped by the `& ptp_enable_r`
gate (or its consumer-side replica) — exactly as the §2 hypothesis
predicts.

### Operational notes

- Boards must be granted via `fpgahub pair up` (not queued — see
  `feedback_lease_grant_before_deploy` memory).
- A concurrent `srv03335` client may re-grab per-board leases every ~30 s;
  silence it before long captures (see PHC_PHASE1_RAW_OBSERVATIONS.md
  §Coordination notes).
- The `phc_ila_capture.tcl` worktree edit in `td-bisect/v1-consolidated/`
  is uncommitted — preserve before any worktree pruning (see
  `cleanup_proposal.md`).

---

## 6. Next experiments (priority order)

### EXP-1 — b24: drop the RX-side enable gate (Agent J's #1)

- **Branch:** new `feat/phc-rx-decouple-enable-b24`, parented off `main`
  (NOT off any b21/b22/b23 — start clean).
- **RTL diff:** `tidelink_ptp.sv:288` `& ptp_enable_r` → removed.
- **No XDC change. No submodule bump.** Keep b22 submodule (ILA still
  wired) so we can ILA-confirm the fix.
- **Build effort:** ~35 min × 2 targets on farm.
- **Decision criterion:** slave `HW_SYNC_STATUS` non-zero within 5 s of
  master enable. Pass → land via MR. Fail → go to EXP-2.

### EXP-2 — ILA on the `rx_accept` net itself

- With b22 base + add `mark_debug` on `tidelink_ptp/rx_accept` and on the
  consumer-side replica of `ptp_enable_r` (use post-synth checkpoint to
  find the actual replica net name).
- Re-deploy, capture both nets simultaneously. Direct empirical answer:
  is the replica reading 0 while APB reads 1?
- Falsifies §2 hypothesis if both nets read 1 simultaneously.

### EXP-3 — RX-physical hypothesis (only if EXP-1 and EXP-2 fail)

The three remaining HW-only modes per SIM_HW_GAP_ANALYSIS.md §4:

1. **P&R skew on slave's master→slave fan-out past IDELAY tap range.**
   Test: scope on `pad_clk_rx` + one `pad_rx[n]` at the Pi header. Eye
   closed → tighten XDC `max_delay`.
2. **Recovered-RX-clock reset/CDC race on first master TX edge.**
   Test: insert a deliberate post-link-up delay before master enables
   HW_SYNC; if slave starts working, this is it.
3. **`set_bus_skew` constraint margin exhausted on this build.**
   Test: post-route timing summary `report_bus_skew` on the routed DCP
   preserved by b19's build_design improvement.

These require either oscilloscope or post-route analysis, both beyond
the autonomous loop, hence why they're EXP-3.

---

## 7. Quick-reference observability (when you're at the keyboard)

Slave-side reads that distinguish the failure mode:

| Address | Read | Meaning |
|---|---|---|
| `0x4403_2034` PTP_CTRL | `0x1` → enabled but `rx_valid=0`; `0x5` → RX firing | Most diagnostic single read |
| `0x4403_2038` PTP_RX_PAYLOAD | Non-zero seq-num → packet decoded | Read clears `rx_valid` |
| `0x4403_2048` HW_SYNC_STATUS | Non-zero → FSM advancing on slave | Headline pass/fail |
| `0x4403_205C` SERVO_STATUS | `[0]locked` = ultimate pass criterion |
| `0x4403_2068` SERVO_OFFSET | Non-zero → integrator measured at least one delta |

Full observability map: `docs/PHC_PHASE1_OBSERVABILITY_MAP.md`.

---

## 8. Cross-references

- `docs/PHC_PHASE1_HW_REPORT.md` — historical per-build evidence chain.
  **Superseded for the diagnosis section** (read this file for
  diagnosis); retained for raw evidence.
- `docs/PHC_PHASE1_OBSERVABILITY_MAP.md` — every APB-readable obs point.
- `docs/PHC_PHASE1_RAW_OBSERVATIONS.md` — raw build #13 byte-identical
  M/S baseline.
- `docs/PHC_PHASE1_HISTORY_BISECT.md` — bisect proving the path has
  always been broken on HW (no regression).
- `docs/SIM_HW_GAP_ANALYSIS.md` — three HW-only hypotheses.
- `docs/SIGN_OFF_STATUS.md` — gate-level summary.
- `cocotb/phc_pair/test_phc_hw_sync_pair.py` — sim repro (PASS, HW FAIL).
- `cocotb/phc_pair/test_phc_diag.py` — per-cycle slave RX-path probe.
- Memory: `project_phc_phase1_hw_diagnosis_2026_05_24.md` — pre-ILA
  intermediate state (Agent A focus); this doc replaces it as the
  current snapshot.

---

## 9. TL;DR for the next agent

1. **Don't chase Agent A** — definitively ruled out by b23.
2. **Don't chase BD/reset/config/board** — all ruled out by live HW probes.
3. **Build b24** = drop `& ptp_enable_r` on `tidelink_ptp.sv:288`. One
   line. Deploy with provenance check. ILA-confirm with b22 submodule.
4. **If b24 fails**, escalate to ILA on `rx_accept` net (EXP-2) before
   touching XDC or scope.
5. **Don't touch the ILA pipeline** — it took 22 builds to come up.
   The `phc_ila_capture.tcl` edit in `td-bisect/v1-consolidated/` is
   uncommitted; preserve it.
