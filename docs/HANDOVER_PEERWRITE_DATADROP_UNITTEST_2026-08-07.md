# Handover → TideLink agent: isolated cross-die WRITE data-drop — bug, unit test, and a *suggested* fix

> ## ⚠ CORRECTION (2026-08-07, later same day) — read this first
> This handover's mechanism (XHB500 **bufferable/EWR** early-HREADYOUT + W-backpressure,
> fixed by `wr_hold_r`) is **NOT the operative cause of the silicon drop.** The TL-009 leak
> witness added at `235d758` reads `0x21F8 = 0xb5000521` on a dropping write, which decodes to
> **bit4 = 0 → NON-bufferable** (so the EWR/hazard-list path — and therefore `wr_hold_r` — does
> not apply), **bit10 = 1 → bridge HREADYOUT stuck low ≥2¹²** (far-B never returned), **bit8 = 1
> → synth-B fired.** The real root cause is **PHY lane framing** on bring-up (a (0,0)-framing
> lottery): bad framing corrupts the W payload on the wire (die_b reads 0) *and* loses the B,
> which then cascades into the die_a write-stall wedge (TL-009). **TL-001 (drop) and TL-009
> (wedge) are the same bug.** The empirically-working mitigation is a **bilateral
> `swi_training_mode` pulse** (re-lock/re-frame) → **11/11 byte-exact**; the autonomous RTL path
> is the calibrator terminal-latch + centering-on (`e5bd29c`, HW-inconclusive so far).
> `wr_hold_r` remains a **correct latent fix for the bufferable path** — keep it, but it is not
> what the silicon bench needs. Treat §1–§6 below as the (still-valid) EWR-path analysis, not as
> the silicon root cause. See `235d758` commit body + BUG_REGISTRY TL-001/TL-009.

**From:** nanoSoC eth-chiplet integration (KR260 two-board silicon), 2026-08-07.
**Status of the fix:** already committed in tidelink as **`e28c898`** (`wr_hold_r`, "Rank 1").
This handover is **not** asking you to write new RTL blind — it asks you to (a) reproduce
the bug in a *discriminating* unit test, and (b) **independently evaluate** whether the
committed `wr_hold_r` is the right and complete fix, or whether it needs to change.

> **Everything below the "Proposed fix" heading is a SUGGESTION.** I have a strong timing
> argument and silicon evidence, but the g2/pair sim has been *blind* to this defect so far,
> the fix has **never been on silicon**, and it rests on one assumption about the SoC master
> that only you can properly check. Please treat it as a hypothesis to confirm or refute,
> not a directive.

This **supersedes** two earlier notes and corrects them:
- `HANDOVER_RANK1_PEERWRITE_DATADROP_2026-08-06.md` — correct *fix*, but its verification
  section was hand-wavy and it predates the discriminating-test idea below.
- A verbal steer I gave the eth-chiplet owner that "the fix belongs in the parent decode,
  not tidelink." **That was wrong** — see §6.

---

## 1. The bug (explicit)

**Symptom (silicon, KR260 two-board, 2026-08-05):** a die_a→die_b cross-die peer-aperture
write lands its **address** but delivers **data = `0x0000_0000`**. Deterministic **5/5**.

- Deploy: both-fixes build, tidelink **`9dfe1da`** (= `42da64b` synth-B DRAIN + Fix K
  hazard-list BID-correction). **NB: `9dfe1da` is one commit *before* `wr_hold_r`
  (`e28c898`). So the silicon that dropped did NOT have the fix.**
- Link fully up: `reanchored=1` both dies (autonomous, R8=0), beacon done (`0x21F4=0x00bb0100`).
- Stimulus: `xfer_send` die_a writes `0x2F001000 <- 0xC0FFEE01` (peer aperture; CAM →
  die_b `0x2D001000`).
- Result: `xfer_recv` die_b reads `shared_sram_0[0x2D001000] = 0x00000000`, **5/5**.
  Address crossed; data lost. Not an anchor issue (anchor is validated), not a wedge
  (die_a stayed alive).

**Mechanism (the important part — this is what the unit test must hit):**

The XHB500 AHB→AXI subordinate bridge (`u_xhb_sub`) on the **bufferable / early-write-response
(EWR, HPROT[2]=1)** path asserts `xhb_sub_hreadyout_raw` **HIGH at its address-accept** —
**one-plus cycles before** it emits the AXI **W** beat. `wdata_in = {last, strb, LIVE hwdata}`
is only sampled into XHB500's wdata regslice when `wdata_in_ready` rises, and the W beat
reaches `s_axi` only when `wvalid & wready`.

So, without the fix, the master-facing `ahb_sub_hreadyout` goes high at the *address*-accept.
A **spec-compliant** AHB master (holds HWDATA while HREADY low, releases once it sees HREADY
high) therefore ends its data phase and **releases HWDATA** — *correctly, per protocol* —
but **too early for XHB500's deferred W sample**. If the W channel is back-pressured for
≥1 cycle (W FC-node buffer full from a prior in-flight bufferable write / CDC fill / credit
starvation ⇒ `s_axi_wready` low), the deferred `wdata` sample latches the **already-released
value (0)** → the payload is lost on the wire.

Root-cause comment in RTL: `src/rtl/tidelink_top.sv:1772-1818`.

**Why every prior proof missed it:** the idle-link sim holds `s_axi_wready` high, so the W
beat is always at +2 with the live HWDATA still on the wire; and every historical D2D write
proof used a **back-to-back pair carrying identical data**, so a one-cycle data-phase shift
was invisible. The bug only bites a **compliant master + real W-channel backpressure**.

---

## 2. What the current suite does and does NOT catch

File: `cocotb/tidelink_top_pair_v2/test_v2_isolated_write_dataloss.py` (good work — reuse it).

| Test | Master | W-backpressure? | Verdict |
|---|---|---|---|
| `test_isolated_distinct_write_delivers` | compliant, isolated | **no** (idle link, `wready` high) | PASSES **with or without the fix** — does **not** discriminate |
| `test_back_to_back_distinct_writes` | compliant, b2b | no | guards data-phase shift — good, but not our case |
| `test_isolated_promptdrop_write` | **truly non-compliant** (withdraws HWDATA on a fixed cycle count, *ignoring* HREADY) | no | a PROBE only; `wr_hold_r` **cannot** fix this master — but **this is not our master** |
| `test_isolated_write_hready_loopback` | compliant + wrapper loopback | no | the `cb33c9f` discriminator — good, orthogonal |

**The gap:** there is **no test with a *compliant* master AND W-channel backpressure** — which
is exactly the silicon failure surface. `test_isolated_promptdrop_write` is the closest, but
its `PromptDropSubMaster` drops HWDATA after a fixed `data_hold` count *regardless of HREADY*.
That models a master that violates AHB — and no HREADYOUT-hold can save such a master, which
is precisely why that test is a non-asserting probe. **Our SoC D2D master is compliant**
(it holds HWDATA through wait states); the defect is that HREADY was raised too early, not
that the master misbehaves. So the productive test keeps the master compliant and instead
makes the **W beat slip**.

---

## 3. How to unit-test / exercise the bug (the ask)

Build a test that reproduces the drop **deterministically** and **discriminates** the fix:

1. **Compliant master.** Use the existing `AHBSubMaster.write()` (holds HWDATA to
   completion) — do **not** use `PromptDropSubMaster`. The bug does not need a misbehaving
   master; it needs the *timing* to slip.

2. **Make the W beat slip ≥1 cycle after XHB500's address-accept.** This is the crux.
   - **Do NOT** just force `s_axi_wready` low from cocotb. The prior attempt found that
     forcing `s_axi_wready` **corrupts Wlink transport** rather than cleanly slipping the
     beat (it decouples Wlink's internal accept from the wire), so you get garbage, not a
     clean drop.
   - **Do** inject the backpressure where it happens on silicon — at the **Wlink W ingress**:
     the `wlink_axiwFC` FC node's app-to-link ready (`axi_tgt_0_w_ready`,
     `AXI4ToWlink.v:432`). Two plausible ways (your call which is cleanest):
     - Pre-fill / throttle the **W** FC node's credit/buffer so its `wready` drops for a
       cycle or two on the next write, *without* touching the AW node (they are **separate,
       independent** FC nodes — `wlink_axiawFC` vs `wlink_axiwFC`, `AXI4ToWlink.v:430,432`);
       or
     - Prime one prior in-flight **bufferable** write so the W buffer is momentarily full
       when the isolated write's W beat wants to go.
   - The signature you want: XHB500 accepts the address and raises its raw hreadyout, but
     `s_axi_wvalid & s_axi_wready` does **not** fire for ≥1 cycle after.

3. **A/B on the fix with the built-in kill switch.** `wr_hold_r` already has a
   reproduce-first define: `` `ifdef TIDELINK_DISABLE_WR_HOLD `` (`tidelink_top.sv:1823-1834`)
   forces `wr_hold_r = 0`. Run the *same* test twice:
   - `TIDELINK_DISABLE_WR_HOLD=1` (pre-fix behaviour): far BRAM / `MngWriteMonitor` must read
     **`0x0000_0000`** — the drop **reproduces**. If it does not drop here, the backpressure
     injection (step 2) isn't biting and the test proves nothing.
   - default (fix on): far BRAM / monitor must read the **payload**. Fix confirmed.

4. **Instrument.** Reuse the HREADY-aware `MngWriteMonitor` **and** the `_slave_bram_peek`
   cross-check already in the file (the monitor is self-verified against BRAM every test —
   keep that; it's what makes a green trustworthy).

5. **Regression guards.** Keep `test_isolated_distinct_write_delivers` and
   `test_back_to_back_distinct_writes` green (no-backpressure paths must still land).

A test like `test_isolated_write_wchannel_backpressure` that is **RED under
`TIDELINK_DISABLE_WR_HOLD` and GREEN by default** is the missing CI gate — it converts "we
think Rank 1 fixes it" into "the fix is proven, and any regression re-reddens this test."

---

## 4. Proposed fix (already committed — please confirm, don't re-invent)

**`wr_hold_r`** — the write mirror of the existing read fix `rd_pipe_r`. Committed at
`e28c898`. RTL: `tidelink_top.sv:1819-1834` (register) and `:1893-1898` (applied to
`ahb_sub_hreadyout`).

```
wr_hold_set = ext_is_nonseq & ahb_sub_hwrite & ~pipe_valid_r        // peer write addr latched
wr_hold_clr = (s_axi_wvalid & s_axi_wready & s_axi_wlast)           // the W beat actually landed
            | synth_b_pending                                       // backstop drain (deadlock guard)

assign ahb_sub_hreadyout = (sub_err1_r & ~synth_b_pending) ? 1'b0 :
                           (sub_err2_r & ~synth_b_pending) ? 1'b1 :
                           (ext_is_nonseq && !pipe_valid_r) ? 1'b0 :   // cb33c9f pipe-fill stall (1 cycle)
                           rd_pipe_r                        ? 1'b0 :   // I2 read mirror
                           wr_hold_r                        ? 1'b0 :   // Rank 1: hold until the W beat lands
                           xhb_sub_hreadyout_raw;
```

**What it does:** holds the master-facing HREADYOUT **low** from the cycle the peer write
address is latched until the W handshake completes, so a compliant master holds HWDATA
stable through any W backpressure and XHB500 samples the correct live value whenever `wready`
rises. Unlike `rd_pipe_r`'s one-cycle pulse, this is a **SET-then-hold level** (it can span
many cycles under backpressure).

**Deadlock guard (please scrutinise this specifically):** AW and W ride **separate** FC
nodes, so under a wedged link a later write's AW can be accepted (arming the I5 outstanding
backstop) while its W beat's `wready` never rises — which would leave `wr_hold_r` stuck and
the master stalled. It also clears on `synth_b_pending` (the I5 backstop force-completing the
write). `synth_b_pending` only asserts at the ~2^16 I5 timeout, orders of magnitude past any
legitimate W backpressure, so it never pre-empts the normal clear. Confirm this can't hang.

**Why it works through the eth-chiplet parent (so no parent-side change is needed):**
the parent `chiplet_d2d_decode` response mux is **registered** (`dph_code`,
`chiplet_d2d_decode.sv:178-186`, advances only when `hready`), which delays the peer's
HREADYOUT reaching the master by exactly the C0 **address** cycle. On an isolated write:

- **C0** (master address phase): `dph_code` is still `DPH_NONE` (idle) → master sees
  `hready=1` and advances. This is **correct** — the address *is* accepted (tidelink latches
  it into `pipe_valid_r` this edge). `wr_hold_r` is *set* this edge.
- **C1+** (master data phase): `dph_code=DPH_PEER` → master's `hready` = peer HREADYOUT =
  `0` (because `wr_hold_r=1`) → master **holds HWDATA** until the W beat lands.

So the one-cycle mux delay only affects the address cycle (where `hready=1` is right anyway);
the data phase correctly sees the hold. **This is analysis, not silicon** — a bench is still
required.

---

## 5. The one assumption to independently verify

`wr_hold_r` works **iff the SoC D2D master is AHB-compliant** — i.e. it keeps HWDATA stable
while HREADY is low and only releases after seeing HREADY high. The nanoSoC bus-matrix
master (`d2d_ahb_m`) is Arm/CMSDK-derived and *should* be compliant, but this is the load-
bearing assumption and it's on the **eth-chiplet** side of the boundary, so please flag it
back to me to confirm rather than assume it. (If, contrary to expectation, that master
withdraws HWDATA on a fixed count regardless of HREADY — the `PromptDropSubMaster` case —
then `wr_hold_r` is *not* sufficient and the fix has to move; but there is no evidence of
that, and it would violate AHB.)

---

## 6. Correcting the record — why NOT "fix it in the parent," and NOT `cb33c9f`

Two things I want to be explicit about so we don't chase the wrong locus again:

- **`cb33c9f` ≠ the fix.** `cb33c9f` ("xhb: fix ahb_sub hready comb loop") added the
  **one-cycle** pipe-fill stall (`sub_stall_fill = ext_is_nonseq && !pipe_valid_r`,
  `tidelink_top.sv:1542`, applied at `:1895`). That holds HREADYOUT low for the *single* fill
  cycle only; once `pipe_valid_r` is high it releases to raw, and on the EWR path raw is
  already high at address-accept — **before** the W beat. So `cb33c9f` does **not** hold
  through the W beat and does **not** fix this drop. It was already in the `9dfe1da` silicon
  that dropped 5/5. `wr_hold_r` is the part that holds *through the W beat*.

- **The "can't fix it in the bridge" line was about a different fix.** The compute-chiplet
  doc's claim (a `pipe_hwdata_r` that *chases/captures the early word* would corrupt every
  compliant write) is **true of that approach** and true of the eth-chiplet parent-side
  HWDATA-hold attempts (v1/v2/v3). But `wr_hold_r` does **not** capture HWDATA — it fixes the
  **HREADY timing** so the compliant master itself holds HWDATA. Different mechanism, and it
  lives cleanly in the bridge. My earlier "parent-side" steer conflated these; disregard it.

- Consequently the eth-chiplet parent's `d2d_ahb_m_hwdata_q` register (a leftover HWDATA
  data-hold) is **dead** once `wr_hold_r` is confirmed on silicon, and I will remove it on my
  side.

---

## 7. Provenance / pointers

- Fix commit: **`e28c898`** `fix(axinode): Rank 1 — wr_hold_r peer-WRITE data-phase hold`.
  Ancestor of current submodule HEAD `e5bd29c` (branch `fix/tl001-calibrator-terminal-latch`)
  and of the eth-chiplet parent-recorded pointer `1107151`.
- Silicon-that-dropped: `9dfe1da` (Fix K), one commit before `e28c898`. **Rank 1 not yet benched.**
- Kill switch: `` `TIDELINK_DISABLE_WR_HOLD` `` (`tidelink_top.sv:1823-1834`).
- Existing regression to extend: `cocotb/tidelink_top_pair_v2/test_v2_isolated_write_dataloss.py`.
- Root-cause RTL comment: `tidelink_top.sv:1772-1818`. Deadlock-guard rationale: `:1806-1818`.
- Silicon write-up: eth-chiplet `docs/OVERNIGHT_HW_CAMPAIGN_2026-08-05.md`.

## 8. What I'll do on the eth-chiplet side (so we don't duplicate)

- Bench `wr_hold_r` on the two boards (it's already in the pointer line): `xfer_send`/
  `xfer_recv` soak, expect die_b SRAM = payload, die_a alive. Rig has been flaky; this is the
  gating step and it's mine.
- Confirm the `d2d_ahb_m` master-compliance assumption (§5) from the eth-chiplet RTL and
  report back.
- Remove the dead parent-side `d2d_ahb_m_hwdata_q` hold once the bench is green.

**Ask of you:** the discriminating unit test in §3 (compliant master + W-ingress
backpressure + `TIDELINK_DISABLE_WR_HOLD` A/B), and an independent read of §4/§5 —
especially the deadlock guard and whether `wr_hold_r` is the right shape or should change.
