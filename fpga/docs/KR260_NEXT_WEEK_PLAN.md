# KR260 — plan for the week of 2026-07-13

Two questions drove this plan: (1) can we drive both KR260s from a **common clock** to
mimic an ASIC chiplet, and (2) what actually gets us a working link. The answers turned
out to be different things, so read the priority order before the detail.

## TL;DR — priority order

| # | Item | Why | Blocks a working link? |
|---|------|-----|------------------------|
| 1 | **Mirror the RX capture-clock-tree fix into KR260** | KR260 inherits the *unfixed* config: it sets neither `USE_CLKBUF` nor `USE_CAP_CLKBUF`, and has **no pblock**. | **YES — this is the #1 blocker** |
| 2 | KR260 first light (deploy, smoke, manual link-up) | Never run on hardware; no KR260 on the rig | prerequisite |
| 3 | Common clock (mesochronous) | ASIC-fidelity + determinism + isolates ppm | **No** — buys correctness, not link-up |
| 4 | EPOCH anchor A/B | Deskew currently has **no active corrector** | Yes, for data integrity under skew |

**The common clock is worth doing and is ASIC-faithful — but it fixes none of the
current delivery blockers.** Do not sequence it ahead of item 1.

---

## 1. KR260 inherits the bring-up-lottery root cause (NEW, 2026-07-11)

Sibling sessions root-caused the z2 bring-up lottery to **a residual fabric LUT on the
per-lane RX capture-clock tree** (`wpa_gap`, fanout 372) → placement-varying inter-lane
skew, amplified by the all-lanes-AND commit gate. **Physical, not logic** — proven by
rebuild-sensitivity (a rebuild of *identical* RTL moved die_a 15%→35%; no logic
threshold can do that).

**The KR260 build has the identical defect.** From its routed report:
- `u_wlink/phy/g_word_pin_auto.wpa_gap_q[3]_i_2__0/O` — a LUT in the capture-clock path (90 `wpa_gap` refs)
- the **`fo=372`** net at `CLOCK_ROOT` — the same fanout they cite
- `pad_clk_inv_scan_mux_1_io_o_z_BUFG_inst` — a LUT-based mux feeding the capture BUFG

And KR260 is in the **unfixed** configuration:
- `CONFIG.USE_CLKBUF` — **not set** ⇒ inherits the IP wrapper default `1'b1`
  (`fpga/vivado_ip/tidelink_vivado_wrapper.v:77`)
- `CONFIG.USE_CAP_CLKBUF` — **not set** ⇒ IP default
- **no pblock** in any `kr260-pair-*` target (`pblock_rx_act` exists only in z2 die_b)

The Z2 targets that *do* set these (`pynq-z2-pair-mmcmbypass-*`: `USE_CAP_CLKBUF {1'b0}`,
`USE_CLKBUF {1'b0}`) are the experiments probing this exact lever.

> **Methodological warning — I got this wrong once.** I first compared KR260's clock-path
> LUTs and hold slack against the *silicon-proven* `pynq-z2-pair-all` build, saw KR260 was
> no worse, and called it "inherited and tolerated." That is invalid: **`pair-all` is the
> sick patient** — it *has* the lottery. Never benchmark against a known-defective baseline.

**Action:** the fix is owned by the sibling session (clean the clock tree + mirror/tighten
the pblock into `pair-all`, prove by rebuild-variance soak). **Do not re-derive it here** —
when it lands, mirror the parameter set + pblock into the four `kr260-pair-*` targets and
rebuild. This is a rebuild we are doing anyway for items 3/4, so fold it in.

---

## 2. Common clock — assessment

### Is it ASIC-faithful? YES (high confidence)

The PHY is forwarded-clock source-synchronous with **no CDR, no DLL, no phase
interpolator** — `(slip, phase)` is latched once at `S_DONE` and frozen (verified: no
PLL/DLL/CDR/PI anywhere in `deps/tidelink-phy`). **A frozen-phase link with no drift
tracking is only reliable when the two dies are frequency-locked.**

The ASIC SDC (`imp/ASIC/tidelink_top_full/tidelink_top.sdc:39/43/46`) declares
`user_ref_clk` and `pad_clk_rx` *both* at 250 MHz, grouped `-asynchronous` — conservative
timing hygiene over a physically same-frequency link, **not** evidence of independent
references. The repo never states the ASIC package clock tree (the key unconfirmable).
Industry: this is a BoW/AIB forwarded-clock cousin; UCIe adds a DLL/PI precisely to
survive drift, and this PHY has none ⇒ the realistic ASIC condition is a **shared
reference (mesochronous)**.

⇒ **The two-crystal FPGA rig injects a ppm drift the ASIC won't have. That drift is a rig
artifact, not an ASIC condition.**

### Does it improve the odds of a working link? Only narrowly — be honest about this

- The **deskew FIFO is already frequency-locked** (source-sync: write and read pointers
  both run on the recovered `pad_clk_rx`; `tidelink_lane_deskew.sv:6-10`). No drift there
  to fix.
- **The bit eye is ppm-IMMUNE** — the RX samples data on the far transmitter's own
  forwarded clock, so their relative timing is fixed regardless of frequency offset.
  ⇒ the "marginal-eye / N-minutes-then-dead" failure is **V/T thermal or a logic bug, not
  ppm**. A common clock does **not** open the eye.
- Real ppm exposure is narrow: the recovered-RX → core-hclk **credit CDC** (sustained-link
  stability, credit-throttled today).

**What it genuinely buys:**
1. **Makes the one-shot EPOCH anchor architecturally correct.** SYNC re-anchor is
   *periodic* = built to track drift = presupposes plesiochronous. EPOCH is *one-shot* =
   valid only if the offset is static = mesochronous. Since the link is already
   source-synchronous, the residual per-lane skew **is** static ⇒ EPOCH is correct and
   SYNC was fighting a drift a forwarded-clock link doesn't have. FIFO depth math:
   `DEPTH=32`, worst entry age ≈ 5+3+9 = 17 < 32 ⇒ occupancy pins, never walks.
2. **Removes ppm as a variable** — the rig currently conflates ppm / V/T / logic. A common
   clock isolates them: if a sustained failure survives mesochronous, it was never ppm.

**What it does NOT fix:** the capture-clock-tree lottery (item 1), the lane-7 marginal eye,
`fe_tx_credit_max`-class logic bugs, autonomy sequencing, or KR260's missing per-lane trim
(`USE_IDELAY=0` — HDIO cannot host IDELAY).

### Strategic consequence

This forces a decision the campaign has never made explicit: **is the TideLink ASIC
mesochronous (shared ref) or plesiochronous (independent)?**
- If **mesochronous** → the common-clock rig is correct; adopt EPOCH, retire SYNC.
- If **plesiochronous** → the shipped PHY (no CDR/DLL, frozen phase) is **under-designed
  for its own target** and needs drift-tracking before tapeout.

Either way, validating the *current* PHY belongs under a mesochronous rig.

---

## 3. Common clock — how to build it on KR260

**The gotcha:** the RPi header is entirely **HDIO bank 44, which has NO MMCM/PLL sites**.
An HDGC pin drives a BUFG directly but **cannot drive an MMCM** (that needs a BUFGCE hop +
`CLOCK_DEDICATED_ROUTE=FALSE`).

**Why it doesn't bite us:** the design already divides the link clock with a **BUFG-based
`/8`** (`tidelink_phy_clk_div2.v`). Feed the common reference straight into that BUFG and
**never touch an MMCM**.

### Design rules
- **Keep `clk_wiz` on `pl_clk0`** for hclk/AXI/host, so a board **always boots** even when
  its peer's clock is absent. Gating `proc_sys_reset` on the external clock would make a
  board unreachable when its peer is off — the ZynqMP AXI-hang class.
- Bring the common clock in on its **own** path: freed HDGC ball → BUFGCE → `/8` divider,
  feeding **only** the PHY domain (`user_ref_clk` + `scan_clk`).
- Add an **APB clock-presence / frequency counter** on that net so bring-up can confirm the
  common clock before starting calibrator training.
- Free one HDGC ball by relocating a **data lane** to a spare non-HDGC conductor (XDC-only;
  data lanes don't need clock capability). All 8 HDGC balls are currently used (2 forwarded
  clocks + 6 data); the spare BCM20–27 conductors are **not** clock-capable.

**HDGC ball set (verify before building** — DS987 implies fewer GC/bank than this):
`get_package_pins -filter IS_GLOBAL_CLK` → AD15, AD14, AC14, AC13, AA13, AB13, AB15, AB14
(BCM 0, 1, 8, 9, 12, 13, 16, 17).

### Topologies
- **(b) External generator / fanout buffer into both boards' HDGC pins** — symmetric,
  neither board special, no source-first dependency. **Use this to prove the hypothesis.**
  *Needs: a clock generator or a small fanout buffer.*
- **(a) die_a forwards a reference over ONE extra ribbon conductor** into die_b's freed HDGC
  pin — self-contained, no lab gear. **The deployable form.**
- (c) KR260-native shared clock: **none.** No SMA, no SYZYGY; the SFP MGT refclk is
  onboard-generated to the PS-GTR and is not fabric-injectable.

### Changes
- BD: new input port `pad_refclk_in` → BUFG → `phy_clk_div/clk_in` (replacing `clk_wiz
  clk_out1` as the `/8` source). Source board: `pad_refclk_out` from the same internal node.
- XDC: `PACKAGE_PIN <freed HDGC ball>`, `IOSTANDARD LVCMOS33`, `create_clock -period 40.000`
  (25 MHz); relocate the displaced lane.
- Wire as a **build knob** `FPGA_TIDELINK_EXTREFCLK=1` (mirroring `FPGA_TIDELINK_PTP`), then
  `kr260_resync.sh` + rebuild.

---

## 4. The week

**Days 1–2 — KR260 first light (gate).** Boards on the rig; deploy the shipped V2 bitstreams
via `pynq.Overlay`; `kr260_smoke.py --expect-role die_a|die_b` on each (strap + aperture);
then the manual armed recipe (`NEGO_CFG=0x61` **and** `NEGO_TRAIN_CFG=0x0001` — read both
back, POR is 0x00). Characterize the eye / lane-lock. **Expect per-lane lock debugging** —
KR260 has no physical trim. Nothing downstream matters until this passes.

**Days 2–3 — rebuild with the clock-tree fix (item 1) + build the variants.** As soon as the
sibling's clock-tree fix lands, mirror its parameter set + pblock into the four
`kr260-pair-*` targets. In the same rebuild, add the `FPGA_TIDELINK_EXTREFCLK` knob and
produce the **2×2 matrix**: {SYNC, EPOCH} × {independent, common clock}. The EPOCH-anchor
bitstreams already exist (`feat/epoch-anchor-ab`). Procure the clock generator / fanout
buffer, and prep a ribbon with one extra HDGC conductor.

**Days 3–4 — bench the matrix.** Use topology (b). **Key measurement:** does the
"N-minutes-then-dead" failure disappear under a common clock? If yes → it was ppm (credit
CDC) and mesochronous is a real fix. If no → it's V/T or logic, and you've *isolated* that.
Also compare EPOCH+common (the ASIC-intended regime) vs SYNC+independent (today).
Run a **rebuild-variance soak**, not a single build — bring-up % is build/placement-dependent,
so any number only means something against a *fixed* bitstream.

**Days 4–5 — decide, and feed back to the ASIC.** If EPOCH+common is deterministic, adopt it
as the KR260 default and take the explicit ASIC-clocking decision (confirm the package
distributes a shared reference; retire SYNC; document). If the ASIC is meant to be
plesiochronous, raise that the PHY needs drift-tracking (DLL/PI or a working re-anchor)
**before tapeout**.

## Coordination flags
- **The capture-clock-tree fix is owned by a sibling session.** Do not re-derive it; mirror
  it. It is the #1 lever.
- **The EPOCH-anchor change lives in the shared PHY submodule that feeds tapeout.** The
  current handover says *do not* build `epoch-anchor-ab` into the chip default yet (open
  tapeout defects on those trunks). Keep the KR260 A/B isolated; reconcile the EPOCH decision
  with the ASIC trunks deliberately.
- **`WS_ANCHOR_EXTEND` is unproven** — its 3× lift was the rebuild, not the lever. Don't
  pull it on.
