# What to do on Pynq-Z2 before moving to Kria KR260

> **Status:** scoping study — 2026-07-21. READ-ONLY analysis; nothing built, nothing committed by this study.
> **Question:** the Z2 pair is the proven, well-understood platform (chiplet link works, certified
> N=40 bring-up recipe, full tooling, JTAG/ILA on all four boards). The KR260 is newer, higher-capacity,
> and only just came up (first link 2026-07-17). The end goal on KR260 is the *full SoCs*
> (nanoSoC multicore + TideLink + ethernet chiplet). **What should be de-risked, characterized, or
> proven on Z2 first — where Z2 is the cheaper/faster/more-trustworthy place to do it?**
>
> **Grounding:** `docs/STATUS_LIVE.md`, `docs/MONDAY_HANDOVER.md`, `docs/TIDELINK_FPGA_VERIFICATION_PLAN.md`
> (F01–F20 inventory), `docs/ERROR_INJECTION_FINDINGS.md`, memory files
> `project_kr260_pair_onchip_plan_2026_07_09`, `project_kr260_port_2026_07_09`,
> `project_kr260_readiness_audit_2026_07_09`, `reference_pynq_boards`, plus the four Phase-B fixes
> (B1/B2/B3/C, sim-proven, none hardware-confirmed).

---

## TL;DR — one-screen sequenced recommendation

| # | Do on Z2 first | Why Z2 | Unblocks | Effort |
|---|---|---|---|---|
| 1 | **Re-enable the link-layer CRC at runtime and soak byte-exact data both directions** (F14-A / CRC) | The June "header-CRC on good traffic" bug that caused the disable happened *on Z2*. Z2 is the only platform with certified byte-exact A→B/B→A (N=40). Only Z2 can prove whether the CRC was lying or telling the truth. | The single biggest open tapeout decision (revert `disable_crc` default or ship "no integrity" contract) | M |
| 2 | **Prove the firmware PHY-retrain (B1 `SWI_FORCE_RECAL`) actually recovers a wedged link** | Z2 has JTAG/ILA on all 4 boards + the power-cycle rig to *create* a real clock-dropout wedge and watch recovery. "Now measurable, unmeasured." | Closes the "unfixable-after-tapeout" retrain finding; the recovery path is currently untested silicon | M |
| 3 | **Bring-up-lottery statistic + capture-clock BUFG fix, hardware soak** (F01/F02, N≥40 Clopper-Pearson) | Z2 is where the lottery was characterized and where the pblock/BUFG fix targets live; the certified soak harness runs here. KR260's `set_bus_skew` is a no-op and it has no IDELAY, so the *statistic* must be taken on Z2. | Autonomy zero-poke (the #1 MANDATORY gap, ~25–35% today); confirms the lottery fix on a real link, not just static timing | L |
| 4 | **Two-board PTP convergence** (F13, `\|offset\|≤12000 ns`) on the Z2 pair | Both Z2 boards have working PHC channels; KR260 `-ptp` builds but *fails MMCM timing* (R1). Prove the servo loop converges on the mature platform before fighting KR260 clocking. | The PTP demo; validates the Phase-C PHC-binding fix's intent before it hits capacity-limited KR260 | M |
| 5 | **Deploy the standalone PHY-BIST once for a real eye/BER number** (F19) | The `pynq-z2-phy-bist-pair` bitstream is built, on the shelf, and *never deployed*. Z2-only toolkit. We have **zero** BER data today. | De-risks chip-killer #3 (the eye / matched-routing); gives the ASIC PHY a real characterization number | S |

**Capacity verdict:** a **single Z2 (xc7z020, 53,200 LUT) cannot host even two TideLink dies** —
the measured on-chip pair is **~63,000 LUT** (54% of KR260's 117,120), already larger than a whole Z2.
The proven Z2 config is **one die per board** (~22,857 LUT ≈ 43% + PS infra). The **full SoC per die**
(nanoSoC multicore + TideLink ~24k + ethernet chiplet MAC/HA1588) does **not fit a Z2** and never will —
that integration is intrinsically KR260-only. A **reduced** SoC (single nanoSoC-M0 core + TideLink, no
ethernet) is the *one* integration shape plausibly Z2-fittable and worth checking (item 8).

**Explicitly do NOT do on Z2** (diminishing returns — see §6): re-run the throughput/rate ladder
(solved, structurally confounded); hardware-confirm the RX-FIFO twin2 fix (latent unsupported path,
default-preserving fix with a sim negative control); tune IDELAY winscan or `set_bus_skew` *for KR260
benefit* (KR260 has neither — HDIO bank 44, no IDELAY; `set_bus_skew` measured 0.2% of UI and is a no-op).

---

## 1. Validation that belongs on Z2 (sim-only findings → hardware confirmation)

The theme: **five tapeout-class findings are sim-proven and hardware-blind, and the Z2 pair is the
proven platform to confirm them cheaply before they ride to KR260 and the ASIC.** KR260 is a bad place
to first-confirm a *logic/protocol* finding because it simultaneously carries new-platform confounders
(AFI width, no IDELAY, MMCM floor, deploy plumbing, first-silicon lottery).

### 1a. CRC re-enable + byte-exact soak — HIGHEST (item 1)
- **Finding:** the link-layer CRC is disabled by reset default on *both* dies, in *both* ASIC flists
  (`src/rtl/local_overrides/WlinkGenericFCSM_6.v:1159-1167`, `disable_crc=1`;
  `docs/ERROR_INJECTION_FINDINGS.md` §1; memory `project_link_crc_disabled_by_default_2026_07_18`).
  48/48 injection cells raised **zero** error indications; corrupted packets on two lanes commit
  silently (F14-A). The override's own comment records the motive: a real header-CRC failure on
  *good* traffic was worked around by turning the check off (`ERROR_INJECTION_FINDINGS.md` §4.6).
- **Why Z2 first:** the June failure that triggered the disable was **observed on Z2 silicon**. Z2 is
  the only platform with certified byte-exact data both directions (F06/F07, N=40). An ideal-pad sim
  *cannot* prove the June errors were false — `MONDAY_HANDOVER.md` decision 000 is explicit: "clear
  bit[16] at **runtime** on silicon, check byte-exactness *alongside* `crc_corrupt`, and soak." That is
  a Z2 experiment by construction.
- **What it takes:** runtime clear of the control bit[16] on both Z2 dies (keep POR default), run
  `td_v2_channels.sh gate_data` + `linkhold_soak.sh` with byte-exact scoreboarding while watching
  `crc_errors`. Note the re-enable is not free: a CRC error latches a NACK and `socl_l7_real_crc_seen`
  is sticky (one real error permanently disarms the state-7 watchdog).
- **De-risks for KR260/ASIC:** resolves the single largest open silicon decision before it is baked into
  the tapeout netlist. If the CRC is clean on Z2, the default revert lands; if it re-exposes the framing
  bug, we root-cause it on the mature platform instead of on brand-new KR260 silicon.

### 1b. Firmware PHY-retrain recovers a wedge — HIGH (item 2)
- **Finding:** `calibrated_once_q` (`tidelink_phy_align_calibrator.sv:606-618`) latches on first lock and
  gates off both calibrator re-trigger edges forever ⇒ **no firmware-reachable PHY retrain existed**
  (memory `project_no_firmware_phy_retrain_calibrated_once_2026_07_18`). Phase-B **B1** (`ec924db`,
  `SWI_FORCE_RECAL` W1P) adds the door, but `MONDAY_HANDOVER.md` B1 is blunt: *"nobody has shown a
  forced recal recovers the clock-dropout wedge — now measurable, unmeasured."*
- **Why Z2 first:** only a link-clock dropout truly wedges (most disturbances self-heal). Creating that
  wedge and observing recovery needs the **power-cycle rig + JTAG/ILA on all four Z2 boards**
  (`reference_pynq_boards` Channel 2) — mature Z2-only debug infrastructure. The only trustworthy
  liveness check is a moving tagged-data canary (every status register reads identical healthy-vs-wedged),
  which the Z2 channel harness already implements.
- **What it takes:** wedge one direction (link-clock disturbance), fire `SWI_FORCE_RECAL`, confirm the
  tagged canary crosses again. F14-C companion: never POR one die alone.
- **De-risks:** proves the one-bit-fix door works *in field* before it is the only recovery path on a
  taped-out chip.

### 1c. Dual-root election / `tl_data_mode_o` (B3) observable — MEDIUM
- **Finding:** G1 dual-root — link_active precedes data-mode, silent multi-die dual-root at bring-up
  (respin-class); Phase-B **B3** (`b038df8`) exports `tl_data_mode_o` and gates the election on data-mode
  (`docs/TIDECHART_G1_SEQUENCING_CONTRACT.md`; `STATUS_LIVE.md` G1). **TideChart has NEVER run on hardware**
  (F18 — "entire IP unproven on hardware").
- **Why Z2 *conditionally* first:** a two-die TideChart-over-TideLink smoke needs a pair; the Z2 pair is
  the proven pair. But this is gated on the cocotb integration smoke (verification-plan §5 P7) landing
  first, and on TideChart+TideLink fitting one Z2 board (TideChart controller is small — likely fine).
  Lower priority than 1a/1b because the fix is a sequencing gate, not a data-integrity or recovery risk.
- **De-risks:** first on-silicon proof that root election is single-root in data-mode, before the ASIC
  inherits it (`nanosoc_eth_chiplet.sv` one-net swap).

### 1d. RX-FIFO write-side twin2 (B2) — LOW / do NOT hardware-confirm (see §6)
- Real+live latent chip-killer, but AHB-write-to-RX is proven unsupported everywhere, and B2 (`628167b`)
  is a default-preserving tie with a **sim negative control** in the gate. Hardware confirmation adds no
  information a bench night's worth of value. Flagged as diminishing returns.

---

## 2. Characterization cheaper on Z2 (statistics that inform KR260 + ASIC)

### 2a. Bring-up-lottery statistic + capture-clock fix soak — (item 3)
- The lottery is real and measured on Z2 (die_a 1/4 vs die_b 4/4, *same image*;
  `TIDELINK_FPGA_VERIFICATION_PLAN.md` §3). The capture-clock BUFG hoist (2c32c2b) is proven to tighten
  per-lane spread 9.8× and to be **build-to-build stable** — but that is **static timing only**
  (memory `project_pb_lottery_killed_rebuild_variance_2026_07_18`: "does NOT prove skew was the SOLE
  lottery driver; a hardware soak is still required"). The Z2 `pynq-z2-pair-mmcmbypass-*` targets carry
  the clean-clock-tree lever; the certified `allchan_recipe_soak.sh` computes the Clopper-Pearson CI.
- **Autonomy zero-poke (F02)** is the **#1 MANDATORY gap** (~25–35% today, target ≥95% CI-lower ≥90%,
  N≥40 per bitstream). It has *never* been measured on a live-`set_bus_skew` bitstream. This statistic is
  a Z2 job because KR260's `set_bus_skew` is a no-op and KR260 has no IDELAY (the two knobs that most
  plausibly move autonomy don't exist there). **Take the number on Z2.**
- **Why not KR260:** on KR260 the bring-up statistic is confounded by first-silicon per-lane lock
  debugging (`USE_IDELAY=0` ⇒ `phase_offset` is a deserialiser bit-select with build-to-build
  nondeterminism; `project_kr260_readiness_audit`), so an early KR260 rate would measure new-platform
  noise, not the fix.

### 2b. PHY BIST — real eye/BER — (item 5)
- Deployed silicon exposes only binary `lane_locked` + Hamming-noise + EPOCH — **no BER, no eye-width**
  (`TIDELINK_FPGA_VERIFICATION_PLAN.md` §4). The standalone `pynq-z2-phy-bist-pair` (`0x44060000`,
  `bringup_phy_bist_eyescan.sh`) is **built and never deployed**. One bench slot + lease gives the first
  real eye/BER for the v1 PHY. Effort **S**, high leverage; directly feeds the ASIC PHY sign-off.

### 2c. PTP two-board convergence — (item 4)
- F13: two-PHC convergence is sim-proven (UVM servo PI) but **never end-to-end on hardware**. Z2 has the
  opt-in PTP channel on both boards; KR260 `-ptp` builds but *fails MMCM timing* (R1). Prove convergence
  on Z2 first; it also exercises the Phase-C PHC-binding fix's *intent* (the servo/live-time interface)
  on a platform where the clocking already works. Never gate on `phc_locked 0x2048[18]` (tied 0).

### 2d. Sustained/long-soak stability (F12) — partial value
- `linkhold_soak.sh` has **never run on silicon** (100% byte-exact for a long duration is RED). Worth a
  Z2 long-soak because it stacks onto item 1 (CRC-on byte-exact). *Not* a reason to re-run the throughput
  ladder (see §6).

---

## 3. Capacity reality — numbers

| Device | LUT | FF | BRAM | Notes |
|---|---|---|---|---|
| **xc7z020 (Pynq-Z2)** | 53,200 | 106,400 | 140 | one board |
| **xck26 (KR260)** | 117,120 | 234,240 | 144 | 2.2× the Z2 LUTs |
| one TideLink die (`tidelink_0`) | 22,857 (Z2) / 24,181 (xck26) | 28,193 | 4 | ≈43% of a Z2 |
| full 1-instance TideLink design (xck26) | 34,424 (29.4%) | 39,550 | 6 | + PS infra |
| **two dies on-chip (measured, built)** | **~63,000 (54% xck26)** | ~30% | 12 | `kr260-pair-onchip`, eb3a6fd |

Source: `project_kr260_pair_onchip_plan_2026_07_09` (routed, measured).

**What fits where:**
- **Z2 pair (proven):** one TideLink die per board (~43% LUT) + Zynq-7000 PS infra. This is the entire
  proven campaign. ✅
- **Two TideLink dies on one chip:** **63k LUT > 53.2k Z2** ⇒ **physically cannot fit a Z2**. This is why
  `kr260-pair-onchip` (the ribbon-free, pin-lottery-free A/B vehicle) is **KR260-only** and there is no
  Z2 equivalent. The old `pynq-z2-loopback` is a *structural* smoke only — a die can't negotiate with
  itself (I2C engines mutually-exclusive-reset), never passed data (`project_kr260_pair_onchip_plan`).
- **Full SoC per die** (nanoSoC multicore + TideLink 24k + ethernet chiplet MAC/HA1588): a multicore
  nanoSoC alone plus a 24k TideLink plus a MAC blows well past 53k. **Does not fit a Z2.** The ethernet
  chiplet integration (`nanosoc-ethernet-chiplet`) is ASIC-leaning and has **no Z2 target and no KR260
  target yet** (`STATUS_LIVE.md` W4). This is intrinsically KR260-first.

**Is there a reduced SoC that fits Z2 and still de-risks integration?** (item 8, MEDIUM)
- Plausibly: **single nanoSoC-M0 core + TideLink, no ethernet chiplet, no multicore.** A single Cortex-M0
  subsystem is small; + TideLink ~24k could land under 53k with PS infra on one Z2 board, and a **Z2 pair
  would then de-risk the CPU↔TideLink AHB/APB integration** (bus fabric, address map, the doorbell/RX-FIFO
  software contract) *before* adding the capacity-heavy multicore + MAC on KR260. This is a genuine
  Z2-first opportunity — but it needs a utilization estimate first (no nanoSoC FPGA LUT number exists in
  the tidelink docs; check the nanoSoC project). **Recommend: get the nanoSoC-M0 util number, and if it
  fits, build a reduced Z2-pair SoC-integration smoke.** If it doesn't fit even reduced, skip straight to
  KR260.

---

## 4. What must skip Z2 and go straight to KR260

| Item | Why KR260-only |
|---|---|
| **`kr260-pair-onchip`** (two dies, one bitstream, no ribbon, no pin lottery) | 63k LUT > 53.2k Z2 — capacity. This is the *cleanest* lottery-isolation vehicle and has no Z2 analogue. |
| **Full SoC integration** (nanoSoC multicore + TideLink + ethernet chiplet) | Capacity — see §3. The end goal; intrinsically KR260. |
| **AFI port-width (D-class) behaviors** | KR260 stock firmware leaves AFI at 128-bit vs 32-bit BD (dropped 3/4 of every APB access for months); Z2's PS7 init runs and is *immune* (`project_kr260_link_up_image_swap_2026_07_17`). Nothing to reproduce on Z2. |
| **KR260 deploy plumbing** (fpgautil, `.bit→.bin` = strip 127 B header **no byte-swap**, `reboot` WEDGES, AFI persistence, `cma=512M`) | Zynq-**MP** vs Zynq-7000; Z2 uses the fpga_manager/bit2bin path. Different by construction. |
| **`USE_IDELAY=0` first-silicon lock debugging** | KR260 RPi header is all HDIO bank 44 — physically cannot host IDELAY (`project_kr260_port`). No per-lane trim; per-lane lock is a KR260-specific first-silicon task. Z2 IDELAY winscan does **not** transfer. |
| **25 MHz / MPSoC MMCM-floor clocking, `-ptp` MMCM timing (R1)** | KR260-specific clock tree (Z2 runs 4.687 MHz, below the MPSoC MMCME4 floor). |

---

## 5. Sequencing (concrete ordered list)

```
Z2, mature platform, do first:
  1. CRC re-enable (runtime bit[16] clear) + byte-exact both-direction soak      ── unblocks: CRC default decision
  2. B1 SWI_FORCE_RECAL: wedge a real clock-dropout, prove recovery (ILA)        ── unblocks: retrain finding closure
  3. Bring-up-lottery + autonomy zero-poke statistic (N≥40 CP) on BUFG-fix build ── unblocks: F02 MANDATORY gap; lottery-fix HW confirm
  4. Two-board PTP convergence (|offset|≤12000 ns)                               ── unblocks: PTP demo; Phase-C intent
  5. Deploy standalone PHY-BIST once → real eye/BER                              ── unblocks: chip-killer #3 / ASIC PHY number
  8. (if nanoSoC-M0 util fits) reduced SoC (M0+TideLink) Z2-pair integ smoke     ── unblocks: CPU↔TideLink bus contract before KR260

Then KR260 (capacity / platform-specific), in parallel where possible:
  - kr260-pair-onchip BUFG build: lottery A/B with ribbon+pins removed (N≥8)     ── complements Z2 item 3
  - KR260 pair first data A→B/B→A/doorbell at N≥8 (R6 HARDEN_SWI applied)
  - KR260 -ptp MMCM timing fix (R1) → PTP on KR260 (after Z2 item 4 proves the loop)
  - Full SoC bring-up: nanoSoC multicore + TideLink + ethernet chiplet           ── the destination
```

**Dependency notes:** items 1–5 are independent of each other and can be interleaved across bench
nights. Item 1 (CRC) gates the tapeout netlist decision, so it is first. Item 3 needs the BUFG-fix Z2
build (`pynq-z2-pair-mmcmbypass-*` or a rebuilt `-all` on the recovery-branch RTL — note the Z2 pair
still runs the June-18 build per `MONDAY_HANDOVER.md` loose ends, so a Z2 rebuild is a prerequisite and
will *inherit* the capture-clock RTL). Item 8 is gated on a nanoSoC utilization estimate.

---

## 6. Diminishing returns — do NOT do these on Z2

- **Re-run the throughput / rate ladder.** Solved and closed: the cost is a ~96 PL-cycle PS→PL store
  round trip, not the link (memory `project_throughput_is_ps_bus_roundtrip_not_the_link_2026_07_17`);
  the ladder is *structurally confounded* (clk_out1 drives every bus block *and* phy_clk_div, so no rate
  ladder can separate link from bus). Packing depth N is worth ~nothing on throughput. Re-measuring adds
  nothing.
- **Hardware-confirm the RX-FIFO twin2 fix (B2).** Latent path, AHB-write-to-RX proven unsupported,
  fix is default-preserving with a sim negative control in the gate. Not worth a bench night.
- **Tune IDELAY winscan or `set_bus_skew` expecting KR260 benefit.** KR260 has no IDELAY (HDIO) and
  `set_bus_skew` is measured at 0.2% of UI and is a no-op / impossible on KR260
  (`project_set_bus_skew_unfixable_and_noop_on_kr260_2026_07_14`). Z2-specific tuning does not transfer.
- **Re-derive the capture-clock lottery root cause.** Already root-caused and the fix static-timing-proven
  6 ways; Z2's remaining job is the *soak statistic* (item 3), not another investigation.
- **Chase the 0xFF 8-lane 2× lever on Z2 as a tapeout item.** The mask is latched at bring-up; a runtime
  poke does not rewire the datapath (needs a rebuild), and the prize is ~+25% not 2×
  (`project_lane_census_0xE4_never_measured_2026_07_16`). Out of tapeout scope; a separate campaign.

---

## 7. Honest caveats

- The four Phase-B fixes (B1/B2/B3/C) live on `wip/kr260-recovery-2026-07`, are sim-gate-green, and
  **none are hardware-confirmed**. Items 1–4 above are the hardware confirmations for three of them
  (B1→item 2, B3→item 1c, C→item 4); B2 is deliberately not hardware-confirmed (§6).
- The Z2 pair still runs the **June-18 bitstream** (`MONDAY_HANDOVER.md` loose ends). Every Z2-first
  item that needs the capture-clock fix (2, 3) requires a Z2 **rebuild** on the recovery-branch RTL
  first — budget that as a prerequisite, and re-certify with the N=40 soak.
- "Proven on Z2" for a *link* feature means proven **as a statistic** (N≥8 to distinguish a lottery from
  a dead build; N≥40 for a rate claim), never n=1 — the lottery makes single runs meaningless.
- Instrument-first discipline applies to all of it: verify the instrument (AFI canary on KR, RW-scratch
  litmus, ctypes single-u32 access, trust-allow-list) before trusting any register reading. Fifteen
  logged instrument failures are why (`TIDELINK_FPGA_VERIFICATION_PLAN.md` §0).
