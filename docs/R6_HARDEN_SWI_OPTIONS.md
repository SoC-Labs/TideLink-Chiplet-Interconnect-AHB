# R6 — HARDEN_SWI / master fcsm=2 blocker: analysis + fix options

Lane R6 of `docs/KR260_RECOVERY_PLAN_2026_07_17.md`. Read-only investigation; the
only file this lane writes is this one. Nothing here is applied or committed.

**Context:** the AFI-width fix (G0) brought the KR260 control plane alive and both
dies now reach `cal=1`. Residual blocker: the **master's FCSM sticks at 2** while the
slave reaches **4 (LINK up)**. This document verifies the mechanism against the RTL,
explains the master/slave asymmetry, and lays out every fix option with tradeoffs.

---

## TL;DR — recommendation

**Primary fix — Option (a): `CONFIG.HARDEN_SWI_ENABLE {0}` on the four kr260 pair
targets.** One line per target, in the `set_property -dict … $tl` block that already
sets `CONFIG.USE_IDELAY {0}`. It restores the *proven* Z2/manual `0x208` swreset
triplet (`0x27f09 → 0x27f01 → 0x27f07`), which is the exact mechanism the autonomous
FC-handoff sequencer uses internally. Needs a rebuild. Zero risk to Z2 and to the ASIC
(both keep the default `=1`). The parameter is already surfaced on the packaged IP face
(`component.xml`), so this is a pure BD-config change — no RTL edit, no repackage of new
ports. sim_gate-neutral (no cocotb test drives an external 0x208 swreset; the autonomous
tests use the internal FCH path which bypasses the shim regardless of this parameter).

**Fallback — Option (b): additionally set `CONFIG.NEGO_CFG_RESET {7'h00}` on those
targets** so the Wlink POR (and therefore the FCSM's reset release) is *software-timed*
via the role-lock write, identical to Z2, instead of latching HIGH at PL load. Use this
if (a) alone does not clear fcsm=2 on hardware (i.e. if the master still latches a
spurious CR-seen during the pre-cal training window). Cost: disables zero-poke autonomy
on these two-board bring-up targets (the `kr260-pair-onchip` autonomy demo is a separate
target and is left unchanged).

**Option (d) — a software-only, no-rebuild path — DOES NOT EXIST on the current KR260
bitstream** (proven below). A rebuild is unavoidable.

---

## 1. What fcsm=2 means, and why the master sticks while the slave doesn't

### 1.1 FCSM state encoding (verified in `WlinkGenericFCSM_6.v`)

The FC flow-control state machine lives in the `io_tx_clk` domain
(`WlinkGenericFCSM_6.v:629-647`). Decoding the next-state mux:

| state | name (reconstructed) | meaning | leaves when |
|---|---|---|---|
| `3'h0` | IDLE / reset / enable-parked | reset value; also forced here when enable is low (`_fe_rx_ptr_in_T`) | `en_ff2_tx_demet` (swi_enable synced) ⇒ `1` |
| `3'h1` | SEND_CR | enabled, emitting CR, waiting to observe the peer | `auto_tx_out_advance` & (cr **or** crack seen) ⇒ `2` (`_GEN_34`, l.259) |
| `3'h2` | **CR-SEEN / await CRACK** | saw the peer's CR (or a CRACK), still waiting for the CRACK to advance | `auto_tx_out_advance` & **crack_pkt_seen** ⇒ `3` (`_GEN_45`, l.267) |
| `3'h3` | CRACK-SEEN | `swi_link_en_wait` countdown | `count==0` ⇒ `4` (`_GEN_52`, l.271) |
| `3'h4` | **LINK up (idle/active)** | data mode; `5/6/7` are ack/nack TX substates | — |

`obs_fcsm_state_o` (3 bits) is surfaced at APB `0x2108[19:17]`. **fcsm=2 = "CR-seen,
CRACK never arrived."**

This is not my interpretation alone — the RTL says it verbatim. The autonomous
FC-handoff sequencer's own comment (`axi_chiplet_controller.sv:3346-3350`) describes the
exact failure:

> "…a SHORT swreset pulse would let one die's framer reset, release, and walk past the
> CR/CRACK exchange before the peer's framer has even reset — leaving the link half-up
> **(slave reaches data, master stuck at CR-seen with no inbound CRACK, mirroring the
> documented S→M Bug-A signature).**"

That is the KR260 signature exactly: slave fcsm=4, master fcsm=2.

### 1.2 Why the asymmetry — it is NOT a role asymmetry in the FCSM

The FCSM itself is symmetric (same RTL both dies). The asymmetry is a **reset-timing /
CR-CRACK-epoch** artefact:

- The FCSM's reset (`io_tx_reset`/`io_rx_reset`) is released by
  `wlink_por_reset = ~poresetn | ~role_locked` (`axi_chiplet_controller.sv:2672`;
  `Wlink.v:1948/1951` OR this with `swi_swreset`).
- On **KR260**, `NEGO_CFG_RESET=0x61` latches `role_locked` HIGH **at PL load, before
  software or calibration exists**. So `wlink_por_reset` deasserts immediately and the
  FCSM leaves reset **during training**, against garbage traffic — the classic
  "SEND_CR against training traffic" condition the FCH block documents
  (`:3230-3238`). It advances `0→1→2` on a spurious/early CR observation and then waits
  forever for a CRACK that either already flew past or was never validly framed.
- The **slave** happens to leave its window cleanly and walks to 4; the **master** (which
  also runs the winscan/calibrator and comes clean *later*) is the one that latches the
  stale CR-seen. Which die loses is a placement/timing lottery, consistent with the
  known KR260 bring-up lottery — but on these runs it is the master.

**The cure is a fresh, overlapping reset of *both* LL framers, issued AFTER cal, so they
traverse CR→CRACK in the same epoch.** That is precisely what the swreset triplet
(held HIGH long enough to overlap) does, and precisely what HARDEN_SWI blocks.

---

## 2. Reset fan-in — exactly which resets reach the FCSM/LL vs the calibrator

Two **disjoint** software-reachable reset paths. This is the heart of the bug.

### 2.1 FCSM / LL framer resets (the thing that is stuck)

`Wlink.v` (verified):
```
1948  tx_link_clk_reset_wrs_io_reset_in  = por_reset | out_prepend_swi_swreset;
1951  rx_link_clk_reset_wrs_io_reset_in  = por_reset | out_prepend_swi_swreset;
1957  app_clk_reset_scan_wrs_io_reset_in = app_clk_reset | out_prepend_swi_swreset;
1998  out_prepend_swi_swreset <= bundleIn_0_pwdata[3];   // 0x208 bit[3], plain reg
```
These three synced resets feed `TideLinkToWlink` → `WlinkGenericFCSM_6`
(`io_tx_reset`/`io_rx_reset`/`io_app_reset`). So the **only** SW-reachable reset to the
FCSM/LL is:

- `por_reset` = `~poresetn | ~role_locked` — released by role-lock (POR-timed on KR260,
  SW-timed on Z2); **not re-triggerable without a POR** once `role_locked` latches, and
- `swi_swreset` = **0x208 bit[3]** — the *only* runtime lever, and the one HARDEN_SWI
  masks.

### 2.2 Calibrator reset (a DIFFERENT block — already satisfied on KR260)

`axi_chiplet_controller.sv`:
```
1961  swi_recal_r <= ctrl_reg_wdata[1];      // R8 (0x2100) bit[1] SWI_RECAL, level
5592  .swreset( swi_recal_r | local_swreset_pulse_w | … )   // u_calibrator.swreset
```
`swi_recal` (R8 bit[1]) resets **only the calibrator** — it is how `cal=1` was reached on
KR260. **It does not reach the FCSM/LL.** So the "use swi_recal" workaround got cal up
but can never move the FCSM off 2.

**Conclusion:** with `role_locked` POR-latched (can't re-pulse without POR) and
`swi_swreset` masked, KR260 has **no** SW-reachable way to re-reset the master's LL
framer. That is the whole blocker.

---

## 3. Why HARDEN_SWI_ENABLE exists (and what it protects against)

Introduced by commit **`1b628da`** ("rtl(tidelink_top): block Wlink+0x208 swreset bit at
harden_swi_apply shim", 2026-05-28), extending an earlier swi_enable guard from the
2026-05-25 interface-debug session (`docs/TIDELINK_PHASE0_OBS_20260524_2109.md §9`).

The shim (`tidelink_top.sv:2164-2179`):
- **(a)** OR-forces `swi_enable` (bit[0]) HIGH on any 0x208 write that asserts swreset —
  so the 7 FCSMs don't drop to IDLE / lose CR/CRACK sticky state.
- **(b)** AND-masks `swi_swreset` (bit[3]) to 0 on **every** write to 0x208.

**The incident (from the commit body):** the `deploy_pair.sh` swreset cycle
(`0x27f09→0x27f01→0x27f07`) asserts `app_clk_reset_scan_wrs_io_reset_in`, which resets
`axi2wl` (the Wlink AXI target). If an AHB-sub (peer-window) transaction is in flight at
`u_ahb_to_axi_chiplet_slv` when swreset pulses, axi2wl drops it mid-burst, **BVALID never
returns, the PS7 M_AXI_GP0 SmartConnect SI port saturates, and every other PL slave on
M_AXI_GP0 returns SLVERR until a USB power-cycle** (uart-reset and PL reload do not
recover it). Blocking the bit at the shim was the cheap unblock.

**Risk being hardened against:** a swreset issued **while live peer-window traffic is in
flight** wedges the whole PL until power-cycle. Note the hazard requires *concurrent
AHB-sub traffic* — during **bring-up** (pre-data-mode) the link is quiescent, so the
swreset triplet is safe there. HARDEN_SWI is a blanket guard that also blocks the
legitimate bring-up use.

**ASIC / tapeout reliance:** none that pins it ON. `HARDEN_SWI_ENABLE` defaults `1'b1`
in `tidelink_top.sv:93`, the FPGA wrapper (`fpga/vivado_ip/tidelink_vivado_wrapper.v:88`)
and the DFT/ASIC wrapper (`src/rtl/asic/tidelink_dft_wrapper.sv:70`), and is **surfaced
but never overridden** by any flist or ASIC tcl (grep: no `HARDEN_SWI` in `flists/` or
`src/rtl/asic/*.tcl`). The ASIC keeps the safe default. Turning it off for four FPGA
targets does not touch the ASIC posture. The commit itself notes `=0` "restores bit-exact
passthrough for cocotb/UVM regressions that rely on the legacy swreset path" — i.e. `=0`
is an intended, tested value.

---

## 4. The autonomous FC-handoff sequencer (why there is no SW-only escape today)

`axi_chiplet_controller.sv:3226-3800` contains an internal sequencer that *replicates*
the manual triplet autonomously and — critically —

```
3270-3276: "The injected writes carry swi_swreset=1 … the Tier-2 hardening shim in
           tidelink_top.sv … is UPSTREAM of this module's wl_apb_pwdata mux, so it does
           NOT touch these internally-generated writes — the swreset pulse reaches
           Wlink intact."
```

So the FCH bypasses HARDEN_SWI, holds swreset HIGH for `FCH_SWRESET_DWELL ≈ 0.25 s`
(`:3367`) to guarantee cross-die overlap, and is exactly the fix we want. **But its arm
is unreachable by SW on the current KR260 build:**

```
3687-3724 (TIDELINK_PHY_V2 path — the deployed build):
   winscan_gate = WINSCAN_FSM_EN ? winscan_done : 1'b1;
   fch_pending_r <= autonomy_armed & swi_training_mode_fall (or reanchor-catchup);
   fch_arm       = fch_pending_r & winscan_gate & autonomy_armed;
```

`fch_arm` needs **`winscan_done`**. On KR260, `USE_IDELAY=0` and at 2.343 MHz the IDELAY
winscan never converges → `winscan_done=0` (memory: PHASE=0/winscan_done=0) → `fch_arm`
never fires → the autonomous swreset never runs. The reanchor-catchup arm depends on the
winscan FSM being in the committed-anchor WS_IDLE state, which is not reliably
SW-pokeable. So even though the mechanism exists in the silicon, **nothing SW can write
today triggers it on KR260.**

Hence: manual 0x208 swreset → masked; `swi_recal` → wrong block; autonomous FCH → gated
behind an unreachable `winscan_done`. **No SW-only, no-rebuild path. Rebuild required.**

---

## 5. Options

Legend: **RB** = needs rebuild. Z2 / ASIC = risk to certified behaviour.

### (a) Per-target `HARDEN_SWI_ENABLE=0` for the kr260 pair targets  ★ RECOMMENDED
Restores the external 0x208 swreset triplet so the proven Z2/manual bring-up recipe
works. The parameter is already a packaged CONFIG property (`component.xml`), settable
per-BD exactly like `CONFIG.USE_IDELAY {0}` — **no RTL edit, no new IP ports, no
repackage.**
- **How plumbed:** add `CONFIG.HARDEN_SWI_ENABLE {0}` to the existing `set_property
  -dict … $tl` block in each target tcl (these targets instantiate ONE `$tl` cell — the
  pair is two boards running the same bitstream, role by strap).
- **Both dies reachable:** master via the direct external-APB path; slave via
  `apb_debug_unlock_i` (tied 1'b1 under `HONEST_MASK_HS=0`, `:2270`) which passes external
  writes through with strobes on (`:3454-3464`). Verified.
- **Z2 risk:** none — Z2 targets untouched, keep `=1`.
- **ASIC risk:** none — ASIC/DFT wrapper untouched, keeps `=1`.
- **Residual risk:** re-exposes the mid-burst-swreset PS-wedge *on these 4 FPGA targets
  only*. Only bites if SW pulses 0x208 swreset during live peer-window traffic; the
  bring-up recipe issues it only while quiescent, so acceptable for demo vehicles.
  Document the constraint in the recipe.
- **RB:** yes. **Verification:** sim_gate green (neutral — see §6); on HW, canary +
  master fcsm 2→4 after the triplet on both dies with overlapping swreset-HIGH windows.

### (b) Per-target `NEGO_CFG_RESET=0x00` (restore SW-timed role-lock / POR)  ★ FALLBACK
Makes `role_locked` start LOW so `wlink_por_reset` (and the FCSM reset release) is
software-timed via the role-lock write — **identical to Z2**, where this exact path is
certified. Directly addresses the §1.2 root cause (FCSM leaving reset during training)
rather than papering over it with a re-reset.
- **Does it fix fcsm=2?** Yes in principle: the FCSM leaves reset fresh *after* the SW
  sets role/cal, avoiding the spurious pre-cal CR-seen. This is why Z2 reaches 4/4.
- **Cost:** disables **zero-poke autonomy** on these targets (SW must drive role-lock +
  the mask handshake). Acceptable for the two-board `-ptp/-nptp` bring-up vehicles (they
  are SW-driven anyway); the `kr260-pair-onchip` autonomy deliverable is a *separate*
  target and is not touched. Conflicts with "hardware autonomy is MANDATORY" only if
  these specific targets were meant to demo autonomy — they are not.
- **Blast radius > (a):** changes role-lock, autoneg, and mask-handshake behaviour, not
  just one reset bit. More to re-validate.
- **Z2 risk:** none (Z2 untouched). **ASIC risk:** none (ASIC default unchanged).
- **RB:** yes. **Verification:** sim_gate (the SW-role_lock path is the pair_data suite's
  default — well covered); HW N≥8 bring-up.
- Note: strongest when combined with (a) — (a) gives the runtime re-reset lever back,
  (b) fixes the POR-timing that created the stale CR-seen in the first place.

### (c) Surgical RTL: hardened-but-recoverable swreset (magic-unlock or hazard-gated)
Two sub-variants:
- **(c1) magic unlock:** allow swreset through only after a magic value is written to a
  new/existing unlock register. Hardened AND recoverable.
- **(c2) hazard-gated mask (preferred if any (c)):** narrow the shim so it blocks
  swreset **only while axi2wl is mid-burst** (condition the `swreset_clear_mask` on the
  AHB-sub/axi2wl busy signal), instead of blanket-masking. Preserves the original intent
  (block the wedge) while permitting the quiescent bring-up swreset — on *all* targets,
  Z2 and ASIC included.
- **Tradeoffs:** touches `tidelink_top.sv` RTL ⇒ repackage IP + new sim coverage; larger
  review surface; (c2) needs a proven busy signal. Higher effort than (a). Worth doing as
  a *follow-up hardening* for tapeout, not for the immediate KR260 unblock.
- **Z2/ASIC risk:** non-zero (changes shared RTL) ⇒ must re-run full sim_gate + a Z2
  regression. **RB:** yes.

### (d) Software-only, no rebuild — NOT AVAILABLE (see §4)
Exhaustively searched: manual 0x208 swreset (masked), `swi_recal` (calibrator only, not
FCSM), autonomous FCH (gated behind `winscan_done`, which never asserts on KR260). No
reachable register produces the FC/LL reset edge on the deployed bitstream. **Ruled out.**

### (e) Better idea found — sequence (a) as the unblock, (c2) as the tapeout hardening
Ship (a) now to unblock KR260 bring-up (minimal, proven, zero shared-RTL risk). Separately
schedule (c2) — the hazard-gated mask — as the *correct* long-term fix that keeps the
wedge-guard for everyone while never blocking a legitimate quiescent swreset. Do not
conflate the two: (a) is the recovery build; (c2) is a reviewed RTL change for a later
tapeout-quality drop.

---

## 6. sim_gate / test coverage and the test_31 question

- **`test_31_autonomous_training_exit.py`** exercises the NEGO_CFG=0x61 autonomous path
  and asserts the FCSM leaves state 1 via the **internal FCH** handoff. That path
  **bypasses the shim** (§4), so `HARDEN_SWI_ENABLE` (0 or 1) does not change its result.
  The "test_31:601 enshrines an autonomy bug" note (from the SYNC-clamp memory) concerns
  the event-gated **retire** logic, not swreset — it does **not** constrain any option
  here.
- **No cocotb test drives an external 0x208 swreset** through `tidelink_top` (grep of
  `cocotb/tidelink_top_pair/`), and no sim overrides `HARDEN_SWI_ENABLE` (it runs at the
  `tidelink_top` default `=1`). The raw-Wlink `cocotb/debug/wlink_pair/` tests operate
  below the shim. ⇒ Options (a)/(b) are **sim_gate-neutral**; (c) touches shared RTL and
  must re-run the full suite + a Z2 regression.
- **Verification for (a):** structural (V2 markers, `RETIRE_EN`, WNS≥0), then HW: AFI
  canary green → apply the swreset triplet with overlapping swreset-HIGH windows on both
  dies → master fcsm 2→4 → byte-exact data both directions (N≥8, per G3).

---

## 7. Exact patch (Option (a)) — NOT applied

Apply to the four kr260 pair targets. Each has an identical block; add one line.

```diff
--- a/fpga/targets/kr260-pair-nptp/tidelink_design.tcl
+++ b/fpga/targets/kr260-pair-nptp/tidelink_design.tcl
@@ set_property on $tl
     set_property -dict [list \
         CONFIG.TIDELINK_PAIR_BASE {0x84032000} \
         CONFIG.USE_IDELAY         {0} \
+        CONFIG.HARDEN_SWI_ENABLE  {0} \
     ] $tl
```
Identical hunk for:
- `fpga/targets/kr260-pair-ptp/tidelink_design.tcl`
- `fpga/targets/kr260-pair-flip-nptp/tidelink_design.tcl`
- `fpga/targets/kr260-pair-flip-ptp/tidelink_design.tcl`

(`kr260-pair-onchip` is deliberately **excluded** — it is the zero-poke autonomy demo and
must keep the autonomous FCH path, which works there via the internal swreset.)

### Fallback (Option (b)) — add ONLY if (a) is insufficient on HW
```diff
     set_property -dict [list \
         CONFIG.TIDELINK_PAIR_BASE {0x84032000} \
         CONFIG.USE_IDELAY         {0} \
         CONFIG.HARDEN_SWI_ENABLE  {0} \
+        CONFIG.NEGO_CFG_RESET     {7'h00} \
     ] $tl
```
(`NEGO_CFG_RESET` is a `bitString`-format CONFIG param — mirror the `kr260-pair-onchip`
`_tl_assert_bitcfg` idiom if you want the build to assert the baked value; the plain
`CONFIG.NEGO_CFG_RESET {7'h00}` set is sufficient to change it. This makes the FCSM
POR-release SW-timed like Z2. Re-validate role-lock/autoneg on these targets.)

---

## 8. One-paragraph summary for the status board

The master's FCSM sticks at **2 = "CR-seen, CRACK never arrived"** — a half-up link where
the two dies' LL framers left reset in different CR/CRACK epochs. The only
software-reachable reset to the FCSM is `swi_swreset` (0x208 bit[3]), which
`HARDEN_SWI_ENABLE=1` masks on every 0x208 write; `swi_recal` resets only the calibrator
(already `cal=1`), and the autonomous FC-handoff sequencer — which *would* deliver the
right overlapping swreset — is gated behind `winscan_done`, which never asserts on KR260.
There is no SW-only escape; a rebuild is required. **Fix: `CONFIG.HARDEN_SWI_ENABLE {0}`
on the four kr260 pair targets** (one line each, packaged CONFIG property, no RTL edit),
restoring the proven manual swreset triplet. Z2 and ASIC keep the `=1` default and are
untouched. Fallback if that alone is insufficient: also set `CONFIG.NEGO_CFG_RESET {7'h00}`
to make the FCSM's POR release software-timed exactly like Z2, at the cost of zero-poke
autonomy on these two-board targets (the onchip autonomy demo is separate and unchanged).
