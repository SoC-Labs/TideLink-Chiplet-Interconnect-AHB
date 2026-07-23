# `make sim_gate` — Coverage Inventory

**Owner of this document:** the `sim_gate` section of the top-level `Makefile` is the
single source of truth; this file explains *what each suite protects* and, more
importantly, **what it does not**.

**Last updated:** 2026-07-19 (P1 forced-recal W1P gated — 21 suites → 22
blocking suites + 2 known-defect sentinels + 2 parked targets).

---

## 0. Why this document exists

This project's recorded failure mode is not "the fix was wrong". It is **"the fix
was never gated, so it rotted out and nobody noticed"**:

- the XHB channel fix **silently rotted out of three branches** (`iter6`, `iter7`,
  `phase2`) — no suite protected it;
- **all four tapeout chip-killers** existed because `make sim_gate` was wired into
  **no CI hook** at all until 2026-07-16;
- `set_bus_skew` was **silently dropped from every bitstream ever built**.

A finding that is not gated becomes folklore. So the rule this file enforces is:
**every bench is either gated, or explicitly parked with the one line that
promotes it.** "We ran it once and it passed" is not a state this repo recognises.

> ⚠️ **`make -n sim_gate` WRITES FAKE PASS FILES.** The `sim_gate_run` macro's
> recipe body writes `<suite>.status` unconditionally, and `-n` echoes it into
> existence without running a single simulation. **Never use `-n` to validate the
> gate.** Validate individual targets by running them (`make sim_gate_<name>`).

---

## 1. Status vocabulary

| Status | Meaning | Fails the gate? |
|---|---|---|
| `PASS` | suite asserted its policy and held | no |
| `FAIL` | suite ran and its assertions failed | **yes** |
| `MISS` | no `.status` file — the suite never ran | **yes** |
| `XFAIL` | **known defect, present and UNCHANGED** — the recorded signature still matches exactly | no (reported in its own section) |
| `XCHG` | **a sentinel's behaviour CHANGED** — fixed, worsened, or moved. A human must look | **yes** |
| `XERR` | a sentinel's module errored (harness/precondition/environment broke) | **yes** |

`XFAIL` is deliberately **never printed as `PASS`**. The summary prints sentinels
in a separate block under a header that says so in words. See §5.

---

## 2. The blocking aggregate (22 suites)

`make sim_gate` → `SIM_GATE_ALL_SUITES`. Feature IDs are those defined in
`docs/TIDELINK_FPGA_VERIFICATION_PLAN.md` §"Feature inventory" (F01–F20).

### 2.1 Pre-existing suites (15)

| # | Suite | Bench / config | Feature | What it actually protects |
|---|---|---|---|---|
| 1 | `t31_autonomous_training_exit` | `tidelink_top_pair`, V2, `sim_build_l4` | F02, F16 | The full zero-poke chain a–h including the real `fch` bootstrap + a bilateral data cross. The headline autonomy deliverable. |
| 2 | `t32_die_a_first_zombie_retry` | same, `BYPASS_AUTONEG=1`, `sim_build_l5` | F02, F16 | die_a-first arm order + the zombie-peer trap auto-retry (R5). Asserts the FSM parks in `ST_BYPASS` pre-arm. |
| 3 | `t33_arm_stagger_episode_bind` | shares `sim_build_l5` | F02, F16 | FIX-1/2/3 arm-stagger episode binding: private-episode rebind, mid-scan kick-loss abort-restart, zero-stagger symmetric. |
| 4 | `t30_autonomous_fc_handoff` | shares `sim_build_l4` | F02 | The autoneg FSM drives the FC handoff (not software). |
| 5 | `v2_pair_data` | `tidelink_top_pair_v2`, `EPOCH_PROFILE=zero` | F06, F07 | Bilateral link-up + M↔S packet delivery. |
| 6 | `v2_autonomous_sync_detect` | same | F02, F03 | Autoneg SYNC config → `sync_det` against the silicon register model. |
| 7 | `v2_winscan_fsm` | same | F03 | The on-chip WINSCAN FSM centre + reanchor. |
| 8 | `fifo_rx_phantom_pop` | `tidelink_fifo` (42 tests) | **F10** | The tapeout chip-killer: reading an **empty** RX FIFO popped a phantom zero-length packet, walked `read_ptr` 2 words and minted credit **above** `MAX_CREDITS`. Sim was blind until `tidelink_sram.sv` began zero-initialising to match FPGA BRAM power-up. |
| 9 | `v1_elab` | `TIDELINK_PHY_V2=0`, build-only | build integrity | Catches V2-only `` `ifdef `` breakage of the V1 flist. Fresh `sim_build_v1elab` so a stale simv cannot false-PASS. |
| 10 | `asic_v1_elab` | `flists/tidelink_top_full_asic.flist` | tapeout | The **chip-build** flist. Chip-killer #4 (`a405809`) broke exactly this while every V2 sim stayed green. |
| 11 | `asic_v2_elab` | `..._asic_v2.flist` (`ASIC_PHY=_v2`, the synth default) | tapeout | The flist a real tape-out synth uses **by default**. A break here is literally a chip-killer. |
| 12 | `apb_fc_cfg_preempt` | `tidelink_top_pair`, V2 | F15 | The `fc_cfg` priority mux must never preempt an in-flight external PS transaction. **Locks a PS hang that costs a physical power cycle.** |
| 13 | `fch_apb_watchdog` | same | F15 | The `fch` sequencer must release the Wlink APB on timeout instead of pinning `pready` low for ever. Same PS-hang class. |
| 14 | `zeropoke_por` | `NEGO_CFG_RESET=7'h61`, own build | **F02** | TRUE zero-poke: autonomy arms from POR with **zero** APB writes. A passive monitor fails the test on any such write. The mandated deliverable (David: "a firmware recipe is not a deliverable"). |
| 15 | `retire_en_plumb` | `TB_TOP_RETIRE_EN=0` A/B vs t31 | **F16** | Proves `RETIRE_EN` genuinely reaches `axi_chiplet_controller` — identical stimulus, one parameter flipped, opposite outcome, with a hierarchical read-back taken **inside** the controller. Guards the `NEGO_CFG_RESET` failure mode (plumbed at the top, never forwarded). |

### 2.2 Added 2026-07-18 (6)

| # | Suite | Bench / config | Feature | What it actually protects |
|---|---|---|---|---|
| 16 | `tc_pair_smoke` | `tidechart_tidelink_pair`, V2 | **F18** | TideChart + a real TideLink pair elaborate and run together; the pair links up (role + cal) **with** TideChart attached; TideChart consumes TideLink's `link_active`. |
| 17 | `tc_pair_election_datamode` | same, shares `sim_build_gate_tc` | **F18** | Single-root election + a `PKT_EXT` crossing over the live link. |
| 18 | `eth_relay_m0` | `eth_tidelink_pair`, `EPOCH_PROFILE=zero` | eth M0 | A link-crossed frame lands byte-exact in a **real** ethernet-subsystem scratch RAM (`nanosoc_region_sram` → `sl_ahb_sram`), not a throwaway BRAM model. |
| 19 | `eth_relay_m1` | `eth_tidelink_pair_m1`, zero | eth M1 | The same crossing **through the real `ethernet_ss_ahb` AHB matrix** into `eth_scratch_rx` — surfacing the actual matrix `hready` / `hprot` / burst contract. |
| 20 | `eth_regs_shape_a` | `eth_tidelink_pair_shape_a`, zero | eth M1 | Real **MAC / HA1588 registers** driven across the link. |
| 21 | `errinj_regressions` | `tidelink_error_injection`, V2, zero | **F14**, F10 | The three **verified-good** F14 results kept as regressions: S5 SYNC-collision (payload can never alias SYNC — confirmed both directions), S6 reset storm (N≤5 always recovers, F-1 NACK watchdog), S4 credit observability + an **independent second lock** that the `f9b94b7` phantom-pop fix still holds. |

### 2.3 Added 2026-07-19 (1)

| # | Suite | Bench / config | Feature | What it actually protects |
|---|---|---|---|---|
| 22 | `force_recal_w1p` | `tidelink_force_recal` — three arms: `RTL=v2`, `RTL=v1`, `pair` | **F03**, tapeout | The **P1 forced-recal W1P** (`SWI_FORCE_RECAL`, R8 slot0 bit[6]). Guards both directions at once: (a) that a firmware-reachable PHY retrain EXISTS — `calibrated_once_q` made `SWI_RECAL` a measured no-op after first lock, so there was none at all, in the FPGA image **and the ASIC path** (`docs/LINK_RECOVERY_MECHANISM.md` §4); and (b) that the **Bug-A guard is not weakened** — the baseline arms assert `SWI_RECAL` and a `role_locked` re-pulse STAY no-ops after first lock, including *after* a forced recal (proving the sticky is bypassed for one arming, never cleared). Runs against **both** calibrator copies because the fix spans two flist families, plus a full-stack arm that does a real APB write and re-checks **byte-exact** data both directions. |

**Why three arms.** The V2 arm covers `tidelink_fpga_v2.flist` +
`tidelink_top_full_asic_v2.flist` (FPGA + **tapeout**); the V1 arm covers
`tidelink_fpga.flist` + `tidelink_top_full_asic.flist`. Both calibrator copies
carry the same `calibrated_once_q` sticky, so a fix or a regression in one is
invisible to the other. The `pair` arm is the only one that exercises the APB
W1P decode, the 1024-cycle pulse-stretcher and the `apb_clk → rx_link_clk` CDC.

**F18 note.** Per the verification plan, TideChart is *"entire IP unproven on
hardware — no two-die on-silicon integration exists"*. Suites 16–17 are therefore
the **only** integration evidence for it anywhere, which is exactly why they are
gated rather than left as a weekend result.

---

## 3. The three nuanced dispositions

### 3.1 Error injection — gate the good, sentinel the defects

`docs/ERROR_INJECTION_FINDINGS.md` produced **both** verified-good regressions and
**two tapeout-gating defects**. They cannot share a status.

The trap: the bench is written so that *"a WEDGE or SILENT-CORRUPTION is recorded
as a `VERDICT[...]` log line, **not** a test failure"* (§5 of that doc). So
`make MODULE=test_ei_lane7_repro` **exits zero while demonstrating a critical
silent-corruption defect**. Gating those modules the ordinary way would print a
green `PASS` next to a chip-killer — strictly worse than not gating them at all.

**Disposition:**

- **Verified-good → `errinj_regressions`** (blocking, suite 21). These modules
  assert real policy and pass against current RTL.
- **F14-A and F14-B → sentinels** (`XFAIL`/`XCHG`/`XERR`, §1). The gate runs the
  module and matches the log against the **exact verdict signature recorded on
  2026-07-18**, as fixed strings, ANDed together.

| Sentinel | Signature clauses (all required) | Trips on |
|---|---|---|
| `xfail_f14a_lane7_silent` | lane7 **flip**, **stuck1**, **stuck0** each `COMMITTED-WRONG/SILENT: 4` **and** lane6 control `NOT-COMMITTED: 4` | a **fix** (a lane-7 clause stops matching), the defect going **intermittent** (count ≠ 4), or a **worsening** (the escape spreads to lane 6, so the control clause drops) |
| `xfail_f14b_datamode_wedge` | S1 all-lane flip **and** S1 link-clock dropout both `WEDGES(unwedged only by full POR of BOTH dies)` **and** S0 passthrough still `RECOVERS` | a **retrain-lite recovery path** landing (WEDGES clauses drop) or the **injector splice breaking** (S0 clause drops — the instrument check, so a wedge for a trivial reason cannot masquerade as a comfortable `XFAIL`) |

**Why not just fail the gate on a known defect?** Because a permanently-red gate
gets ignored, and that is the same rot by another route. The sentinel is the only
shape that is **never green** and **only red on news**.

**Why fixed strings, not regexes?** The verdict lines contain `{}`, `''` and `/`.
An ERE would rot into a pattern that quietly matches nothing — a sentinel that
cries `XCHG` for ever, which is indistinguishable from noise and gets muted.

> The `XERR` state earned its keep during validation on 2026-07-18: a co-scheduled
> Vivado build SIGKILLed the simulator mid-run, and the sentinel reported `XERR`
> — **not** a misleading `XFAIL` and not a false `XCHG`. Cf.
> `feedback_verify_instrument_before_dut`, and the standing rule: **never
> co-schedule a Vivado build with `sim_gate`.**

### 3.2 `fifo_rx_twin2` — **ACTIVE** (in the aggregate since 2026-07-19)

F10's **write-side twin**: the unguarded write-side length-latch arm at
`src/rtl/fifo/tidelink_fifo_ctrl.sv:189` lets any AHB write to offset 0 arm the
packet-length latch, walking the `write_ptr` that the **FC committer shares** —
worse than the shipped read-side phantom pop, which corrupted only the read
pointer.

**Promoted 2026-07-19: `docs/proposals/twin2_fix.patch` is APPLIED to `src/rtl`.**
The RTL now carries an `ENABLE_AHB_WRITE` parameter (default **1** = legacy
behaviour, bit-for-bit) through `tidelink_fifo_ctrl` → `tidelink_fifo_mem` →
`tidelink_fifo`; setting it **0** makes AHB writes to the FIFO a no-op.

The bench's `FIFO_SRC=patched` pin existed **only** to point at local
`*.PATCHED.sv` copies of the then-unapplied fix. Those copies are **deleted** and
the pin is **dropped**: `sim_gate_fifo_twin2` now runs the bench's default config
(`FIFO_SRC=tree`) against the **real shared `src/rtl`**, because the gate must
test what ships.

**The negative control is deliberately NOT gated.** `FIFO_SRC=unfixed` compiles
frozen `*.UNFIXED.sv` copies of the pre-fix RTL and is **expected to fail**, so it
can never be a gate suite. Re-run it by hand whenever this bench is touched:

```
make -C cocotb/fifo_rx_twin2 ab      # unfixed 1/3 (FAIL, correct) | tree 3/3 (PASS)
```

If `unfixed` ever **passes**, the test has gone blind and the green in the
aggregate is worthless.

> ✅ **GAP CLOSED 2026-07-19 — the gate now protects a fix that ships.**
> `src/rtl/tidelink_top.sv` instantiates the RX FIFO with
> `.ENABLE_AHB_WRITE (0)`, so F10 is closed in the RTL and this suite gates the
> real shipping configuration, not just the mechanism.
>
> The tie is at that **one** site deliberately. The other two `tidelink_fifo`
> instantiation sites (`tidelink_fifo_ahb.sv`, the legacy `tidelink.sv`) hardwire
> the FC direct-write port **off**, so tying them 0 would leave a FIFO nothing can
> fill — and neither is instantiated anywhere in `src/`, so it would buy no
> silicon safety. Both keep the default 1. Measured rationale:
> `docs/RXFIFO_TWIN2_DISPOSITION.md` §4.2.
>
> An earlier draft of this note predicted the tie-off would break five benches and
> require migrating them to the FC port. That prediction was **over-broad** — it
> described the blast radius of hardcoding `0` inside the `tidelink_fifo` wrapper,
> not of tying at the integration point. Measured after the tie landed: no
> migration was needed. `cocotb/tidelink` **25/25**, `cocotb/tidelink_ahb`
> **14/14**, and every gated suite that reaches the FIFO through `tidelink_top`
> passes, because they deliver over the FC port the fix preserves.

The disposition doc records the intent question (is AHB-write-to-RX supported?
evidence says **no** — every access to the RX aperture in `fpga/`, `src/sw/` and
`scripts/` is a read).

### 3.3 `xhb_window_skew_debug` — **no gate** (deliberate)

`cocotb/xhb_window_skew_debug/` has **no Makefile and no testbench**: it is a
single instrumentation module (`instr_xhb.py`) that attaches to the pair_v2 bench
to probe `epoch_anchored_o` / `epoch_span_o`.

It has **no pass criterion to assert**. It is the *microscope* that produced
`docs/XHB_WINDOW_SKEW_ROOTCAUSE.md`, not a claim about the DUT. Gating a
diagnostic would assert that its own measurements never change — not a property
anyone wants locked, and it would break the moment the defect it measures is
fixed.

The finding it produced **is** gated, where it belongs: the un-armed whole-word
corrector is why `sim_gate_xhb` stays out of the aggregate, and is the documented
reason suites 18–20 pin `EPOCH_PROFILE=zero` (§4).

---

## 4. Why `EPOCH_PROFILE=zero` is pinned on the eth suites — and why that is honest

Suites 18–20 are pinned to `EPOCH_PROFILE=zero`. **This is not hiding a defect,
and the reasoning must survive review:**

The `silicon` profile injects a **modelled** whole-word S→M skew fingerprint.
Under it the peer-window round-trip hangs — and per
**`docs/XHB_WINDOW_SKEW_ROOTCAUSE.md`** that hang is **not a bug in any of these
three benches**:

- the V2 build compiles `src/rtl/local_overrides/WavD2DGpio_v2.v`, which
  **hard-selects** `SYNC_REANCHOR_EN(1'b1)` / `EPOCH_ANCHOR_EN(1'b0)` (lines
  **790 / 827**);
- there is **no** `` `ifdef TIDELINK_EPOCH_ANCHOR `` selector in the V2 override, so
  the Makefile `EPOCH_ANCHOR` knob is a **dead no-op for V2**;
- the only corrector that *is* built (`SYNC_REANCHOR`) arms only when the SYNC
  beacon floods the RX in data mode — and data-mode bring-up turns the beacon
  **off**. Runtime confirms `epoch_anchored_o = 0`, `epoch_span_o = 0`.

So **any** V2 bench crossing a skewed direction shears identically. That is **one**
root cause, in the PHY, with **one** owner. Pinning the three eth suites to `zero`:

1. locks what they are genuinely evidence *for* — the ethernet subsystem's AHB
   matrix / MAC / HA1588 register contract survives a link crossing;
2. stops three unrelated suites re-litigating a fourth suite's root cause and
   painting the gate red for something none of them can fix.

**Pinning is dishonest only when the pin is undocumented.** It is documented here,
in the Makefile at the pin site, and cross-referenced to the root-cause doc. Note
also that the root-cause doc itself flags its premise as **modelled, not
measured** — MEMORY contests whether real silicon exhibits whole-word epoch skew
at all ("25 MHz byte-exact both dirs"; the lane-7 skew story refuted).

**If the corrector is ever armed, the promotion is to ADD `EPOCH_PROFILE=silicon`
variants — not to edit the pinned lines.**

---

## 5. Summary output shape

```
 sim_gate summary
=======================================================
  t31_autonomous_training_exit PASS     412s
  ... (21 blocking suites)
-------------------------------------------------------
  KNOWN-DEFECT SENTINELS (XFAIL = defect present, UNCHANGED —
  this is NOT a pass; XCHG = behaviour changed, INVESTIGATE)
  xfail_f14a_lane7_silent      XFAIL    110s
  xfail_f14b_datamode_wedge    XFAIL     59s
-------------------------------------------------------
  RESULT: ALL SUITES PASS  (logs: imp/sim_gate/)
          (known defects F14-A/F14-B still present as recorded —
           see docs/ERROR_INJECTION_FINDINGS.md)
```

The blocking loop accepts only `*PASS*`; the sentinel loop accepts only `*XFAIL*`.
Neither vocabulary can be mistaken for the other (`FAIL` and `XFAIL` are distinct
substrings, and no sentinel ever emits `PASS`).

---

## 6. Parked targets (authored, run on demand, NOT in the aggregate)

| Target | Suite name | Why parked | Promotion |
|---|---|---|---|
| `sim_gate_xhb` | `v2_xhb_window_bridge` | **F09.** The refactored pair_v2 tb does not model the **peer-side XHB500 target memory** a window write forwards into (`_slave_bram_peek` returns X). A tb gap, not an RTL one. The XHB channel is gated **on silicon** via `fpga/hw_regression/td_v2_channels.sh --channels xhb`. | Model the peer XHB target in the pair tb, then append `v2_xhb_window_bridge` to `SIM_GATE_ALL_SUITES`. |
| `sim_gate_nack_wedge` | `nack_wedge_recovery` | Pre-existing WIP (see its Makefile note). | Confirm PASS with no Vivado running, then append to `SIM_GATE_ALL_SUITES`. |

> `sim_gate_fifo_twin2` / `fifo_rx_twin2` was **removed from this table on
> 2026-07-19** — the fix landed in `src/rtl` and the suite is now in
> `SIM_GATE_ALL_SUITES`. See §3.2, including the standing gap that the shipping
> RX instances still default `ENABLE_AHB_WRITE=1`.

---

## 7. What remains UNGATED, and why

Being explicit here is the point of the document: an unlisted gap is a gap nobody
owns.

| Gap | Feature | Why it is not gated in sim | Where it *is* covered |
|---|---|---|---|
| XHB peer-window round trip | F09 | peer XHB500 target absent from the pair tb | silicon only (`td_v2_channels.sh --channels xhb`) |
| Any behaviour under **real** whole-word skew | F04 | no whole-word corrector is armed in V2 (§4) | `tidelink_top_pair_wordskew` test_08 gates the deskew block itself; silicon content-anchor `1a08308` |
| **F14-A / F14-B fixes** | F14 | no fix exists — only sentinels that alert on change | §3.1 |
| RX-FIFO write-side twin | F10 | fix is an unapplied proposal | §3.2 |
| `xhb_window_skew_debug` diagnostic | — | no pass criterion (§3.3) | its output lives in `XHB_WINDOW_SKEW_ROOTCAUSE.md` |
| Lane mask `0xFF` (the 2× lever) | F05 | mask is latched at the mask-handshake; a runtime poke does not rewire the datapath, so sim cannot gate the HW lever | separate rebuild campaign (`LANE_MASK_RESET=0xFF`) |
| Throughput / sustained soak | F12 | wall-clock; not a correctness gate | `linkhold_soak.sh`, `HW_CHARACTERIZATION_PLAN` T1–T8 (**unexecuted**) |
| Two-board PTP convergence | F13 | needs two real PHCs | `gate_ptp` on silicon; never end-to-end on HW |
| On-silicon PHY BIST / BER | F19 | no production bitstream contains it | nothing — the standing BIST gap |
| TideChart **on hardware** | F18 | suites 16–17 are sim-only | nothing — never wired to a TideLink pair on silicon |
| Straps for `apb_debug_unlock_i` / `mask_hs_bypass_i` | F17 | tied `1'b1`; **APB debug is permanently unlocked in silicon** | open pre-tapeout item |

---

## 8. Expected wall-clock

Measured individually on `srv03335`, 2026-07-18, warm `/research` NFS, no Vivado
co-scheduled. Times are **per target**, including the VCS compile that target owns.

Pre-existing suite times are the **measured** values from the last full aggregate
(`imp/sim_gate/*.status`, 2026-07-16); new-suite times are measured individually
on 2026-07-18.

| Suite | Runtime | Notes |
|---|---|---|
| `t33_arm_stagger_episode_bind` | **2148 s (~36 min)** | the aggregate's dominant cost, on its own |
| `t32_die_a_first_zombie_retry` | 280 s | owns the `sim_build_l5` compile t33 reuses |
| `t31_autonomous_training_exit` | 255 s | owns the `sim_build_l4` compile t30 reuses |
| `v2_autonomous_sync_detect` | 295 s | |
| `t30_autonomous_fc_handoff` | 130 s | reuses `sim_build_l4` |
| `v2_pair_data` | 27 s | |
| `v2_winscan_fsm` | ~30 s | shares the `sim_build_zero` compile |
| `force_recal_w1p` | ~60 s | 2 small unit compiles (V2 + V1 calibrator) + 1 pair compile |
| `fifo_rx_phantom_pop` | ~2 min | 42 tests, fresh build dir |
| `v1_elab` / `asic_v1_elab` / `asic_v2_elab` | ~15 s each | elaboration only |
| `apb_fc_cfg_preempt` / `fch_apb_watchdog` / `zeropoke_por` / `retire_en_plumb` | ~1–3 min each | |
| **`tc_pair_smoke`** | **22 s** | owns the `sim_build_gate_tc` compile |
| **`tc_pair_election_datamode`** | **6 s** | reuses it |
| **`eth_relay_m0`** | **29 s** | |
| **`eth_relay_m1`** | **41 s** | heaviest new compile (M0+ core, EthMAC, HA1588, bootrom) |
| **`eth_regs_shape_a`** | **47 s** | same compile set |
| **`errinj_regressions`** | **90 s** | owns the shared `sim_build_gate_ei` compile |
| **`xfail_f14a_lane7_silent`** | **105 s** | 4 reps × 3 modes, POR ladder per trial |
| **`xfail_f14b_datamode_wedge`** | **55 s** | POR ladder per wedged case |

**Net effect of the 2026-07-18 additions: 395 s ≈ 6.6 minutes** (measured sum of
the eight new targets) on an aggregate
already dominated by `t33` (2148 s on its own). The previously documented
"~25–40 min" band becomes **~35–50 min**.

---

## 9. Validation evidence (2026-07-18)

Each new target was validated **individually** (`make sim_gate_<name>`), never via
`-n`, and never as part of the aggregate.

Final runs, all from clean gate-owned build dirs:

| Target | Result | Runtime | Evidence |
|---|---|---|---|
| `sim_gate_tc_smoke` | PASS | 22 s | `TESTS=1 PASS=1 FAIL=0`; sub-checks (a) combined stack elaborated + ran (b) pair link up w/ TideChart (role+cal) (c) TideChart consumed TideLink `link_active` — all PASS |
| `sim_gate_tc_election` | PASS | 6 s | `TESTS=1 PASS=1 FAIL=0`; correctly reused the shared `sim_build_gate_tc` compile |
| `sim_gate_eth_m0` | PASS | 29 s | `TESTS=1 PASS=1 FAIL=0` |
| `sim_gate_eth_m1` | PASS | 41 s | `TESTS=1 PASS=1 FAIL=0`; log shows the 16-word frame landing at `eth_scratch_rx 0x30000040+` after decoding through the real subsystem region, plus the `eth_ss_0` bus contract observed on `ahb_mng` |
| `sim_gate_eth_shape_a` | PASS | 47 s | `TESTS=1 PASS=1 FAIL=0`; log shows real register traffic across the link — `MAC.TX_BD_NUM` read-back `0x00000040` vs golden, `HA1588.SCRATCH` write/read-back `0xdeadbeef` |
| `sim_gate_errinj` | PASS | 90 s | all three modules ran (S5 sync-collision, S6 reset storm, S4 credit + phantom-pop), each writing its own `res_*.xml` |
| `sim_gate_xfail_f14a` | **XFAIL** (correct) | 105 s | all four signature clauses matched: lane7 flip/stuck1/stuck0 = `COMMITTED-WRONG/SILENT: 4`, lane6 control = `NOT-COMMITTED: 4` |
| `sim_gate_xfail_f14b` | **XFAIL** (correct) | 55 s | S1 flip + S1 clock-kill both `WEDGES(unwedged only by full POR of BOTH dies)`, S0 passthrough `RECOVERS` |
| `sim_gate_fifo_twin2` | PASS (**now in the aggregate**) | 6 s | `TESTS=3 PASS=3 FAIL=0` against the **real shared `src/rtl`** (`FIFO_SRC=tree`), from a clean build dir. Negative control re-verified the same day: `FIFO_SRC=unfixed` → 1/3, still FAILING, so the test retains its teeth. Revalidated 2026-07-19 after the fix was applied. |

Summary-logic validation (status files only, no simulation): both sentinels
`XFAIL` → **exit 0** with the sentinel block printed under its own header;
sentinel forced to `XCHG` → **exit 1**; to `XERR` → **exit 1**; status file
deleted (`MISS`) → **exit 1**.

### 9.1 Two gate-integrity bugs found *by* this work

Both were found because a target reported something other than green — worth
recording, because both are the "false green" class this repo keeps getting
burned by.

1. **`SIM_BUILD` passed in the environment is silently ignored.** The benches set
   `SIM_BUILD :=`, and a `:=` assignment beats an environment value. Every early
   errinj gate run therefore executed in the bench's own `sim_build_ei` —
   **sharing a build directory with a concurrent run in the same checkout**,
   which produced both a SIGKILLed simulator and a stale-simv skip. Fixed by
   passing `SIM_BUILD` (and `COCOTB_RESULTS_FILE`) as make **command-line**
   variables, which beat both `:=` and `?=`.
2. **cocotb can skip the simulation and still exit 0.** Its execution rule is
   `$(COCOTB_RESULTS_FILE): $(SIM_BUILD)/simv`, with `COCOTB_RESULTS_FILE`
   defaulting to `./results.xml` **shared by every module of a bench**. The `sim`
   target deletes it and re-enters make; if anything re-creates it in that window,
   the sub-make prints `'results.xml' is up to date` and **runs nothing while
   exiting 0** — a gate target would report `PASS` having simulated nothing.
   Every new target now points `COCOTB_RESULTS_FILE` at its own file inside its
   gate-owned build dir (the defence `cocotb/fifo_rx_twin2/Makefile` already
   applied to its A/B configs).

The F14-B sentinel is what surfaced (2): it reported **`XCHG`**, not a
comfortable `XFAIL`. A conventional suite would have gone green.

---

## 10. CI prerequisite (action required)

`.gitlab-ci.yml` job `sim-gate` runs `make sim_gate` with `allow_failure: false`,
so **these suites become blocking automatically**. But the `clone` job checks out
**tidelink only**, and six of the new suites need **sibling repo checkouts**:

| Needed by | Sibling repo | Probed file |
|---|---|---|
| `tc_pair_*` | `tidechart` | `flist/tidechart.flist` |
| `tc_pair_*` | `nanosoc-ethernet-chiplet` | `src/rtl/tidechart_shim.sv` |
| `eth_*` | `ethernet-subsystem-ahb` | `set_env.sh` (which in turn provides the M0+ core, EthMAC and HA1588 paths under `/research/AAA`, read-only) |

Handled by the `SIM_GATE_REQUIRE` guard: a missing sibling fails **only its own
suites**, with a one-line actionable message in that suite's log, while the other
15 still run. It is **deliberately not** a `sim_gate_env_check` hard-fail —
aborting the whole gate over one absent checkout would be worse than the gap it
reports. It is equally deliberately **not a silent skip**: a suite that quietly
vanishes when its dependency is missing is the exact rot this file exists to
prevent.

**→ Before this lands on a trunk with blocking CI, the `clone` job must check out
the three siblings** (or `sim-gate` must be given the sibling paths via
`TIDECHART_HOME` / `CHIPLET_HOME` / `ETH_SS_HOME`).

Also worth reconciling while you are there: the `sim-gate` job comment says
**"10 suites"**, `allow_failure` says **13**, the consolidation plan says **14**,
the old aggregate banner said **13** and the real pre-existing count was **15**.
The banner is now generated-accurate at **21 + 2**; the CI comment is still stale.

---

## 11. Ad-hoc per-bench runs are now staleness-safe

`make sim_gate` was always immune to the stale-`simv` trap because it **cleans
each suite's build dir** before running. The danger lived entirely in **ad-hoc /
lane-private runs** — `cd cocotb/<bench> && make ...` with a persistent
`SIM_BUILD`. That path already produced a **false "hazard refuted"** result once
(memory `project_cocotb_stale_simv_flist_rtl`): an RTL edit was "tested", passed,
and the reverted RTL **had never actually compiled**.

**Root cause.** cocotb's VCS build rule is
`$(SIM_BUILD)/simv: $(VERILOG_SOURCES) $(CUSTOM_COMPILE_DEPS)`. In ~30 of 33
benches `VERILOG_SOURCES` lists **only the tb `.sv` files**; every DUT RTL file
arrives via `COMPILE_ARGS += -f <flist>`, which make **cannot see**. With
`CUSTOM_COMPILE_DEPS` unset, an RTL-only edit changes no prerequisite make knows
about, so `make` **re-runs the previous `simv`** and silently tests stale RTL.

**The fix.** Every flist-sourced bench now sets `CUSTOM_COMPILE_DEPS` so the
`simv` target depends on the flist file **and every bare source path it lists**.
An RTL-only edit now forces a VCS recompile on the next `make`, from any dir,
with any `SIM_BUILD`.

- Shared helper: **`cocotb/flist_deps.mk`** defines `flist_srcs(flist)`, which
  parses a flist into its bare source paths — dropping comments (`//`, `#`),
  `+incdir`/`+define`, and `-options`; expanding `${VAR}` refs; and **dropping
  any path that does not resolve to an existing file** so a bench with an unset
  var (e.g. `CMSDK_DIR`) still runs standalone instead of dying on a phantom
  prerequisite. (`${VAR}` is expanded via `envsubst` with the flist vars injected
  into its environment, because GNU make neither exports make-set vars to a
  parse-time `$(shell)` nor re-scans `$(shell)` output for `${VAR}`.)
- Per-bench pattern (the greppable line in each Makefile):
  ```make
  include $(TIDELINK_HOME)/cocotb/flist_deps.mk
  _flist_deps := $(MY_FLIST) $(call flist_srcs,$(MY_FLIST))
  CUSTOM_COMPILE_DEPS += $(_flist_deps)
  ```
- **Conditional / generated flists are tracked correctly:** `fifo_rx_twin2`
  (`FIFO_SRC=tree|unfixed`) and `tidelink_cdc_tear` (`DUT_KIND`, plus the DUT via
  `$(DUT_SRC)` since it enters through the churning `dut_src.f` the parser skips)
  follow whichever flist is selected; `tidelink_top_pair` follows the
  `TIDELINK_PHY_V2` V1/V2 selection; `tidelink_top_pair_v2` (`PREFIX_FC=1`) depends
  on the **stable source** `tidelink_fpga_v2.flist` file — *not* the generated
  `*_prefixfc.flist`, whose mtime churns every invocation — while parsing the
  selected (generated) flist for RTL, so `prefix_fc_adapter.sv` is tracked without
  forcing a rebuild every run.

**Benches this covers (23):** `crc_diag`, `eth_tidelink_pair`,
`tidelink_error_injection`, `tidelink_v2_smoke`, `tidelink_a2l_replay_cdc`,
`tidelink_ahb`, `tidelink_apb_addr_ctrl`, `tidelink_apb_regs`, `tidelink_eye_regs`,
`tidelink_fifo`, `tidelink_py_pair`, `tidelink_returner`, `tidelink_system`,
`tidelink_top`, `tidelink`, `tidelink_top_pair_drift`, `tidelink_top_pair_skewed`,
`tidelink_top_pair_wordskew`, `tidechart_tidelink_pair`, `tidelink_top_pair`,
`fifo_rx_twin2`, `tidelink_cdc_tear`, `tidelink_top_pair_v2`. The three
`eth_*` real-subsystem benches (`eth_ptp_chain`, `eth_tidelink_pair_m1`,
`eth_tidelink_pair_shape_a`) already carried `CUSTOM_COMPILE_DEPS` (they depend on
their generated expanded flists). Benches that list all their RTL directly in
`VERILOG_SOURCES` (e.g. `tidelink_force_recal`, `tidelink_phy_align_calibrator`,
`tidelink_perf`, the `wav*` envs) were **never affected** — make already tracks
those files.

**Proof (touch RTL → recompile).** For `tidelink_apb_regs` and `fifo_rx_twin2`:
build once; a second `make` with no change leaves `simv` **untouched** (no
spurious rebuild); then `touch`-ing a DUT `.sv` that arrives only via the flist
(`src/rtl/fifo/tidelink_apb_regs.sv`, `src/rtl/fifo/tidelink_fifo_ctrl.sv`) makes
the next `make` **rebuild `simv`**. Before this change, that `touch` was a no-op
to make and the stale binary re-ran. This ADDS a prerequisite only — it never
changes what or how VCS compiles.
