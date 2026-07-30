# Consolidation bug-hunt — `git diff 3574ed2..18491ef` (main tip 18491ef)

READ-ONLY static trace. `make sim_gate` is GREEN; this hunts what sims miss.
CONFIRMED = traced end-to-end in the RTL. PLAUSIBLE = needs a bench/sim check.

---

## P1 — CONFIRMED: tapeout netlist now CONTAINS the TX traffic generator (TXGEN_PRESENT not forced 0 on ASIC)

**Where:** `src/rtl/tidelink_top.sv:112` (`parameter TXGEN_PRESENT = 1'b1`), generate at `:989`;
ASIC top `src/rtl/asic/tidelink_dft_wrapper.sv:519-554` (the `tidelink_top #(...) u_top` param map).

**What:** The design contract (`docs/TXGEN_V1_DESIGN.md:12-13, 73-74`) is explicit:
"`TXGEN_PRESENT=0` ⇒ … the block and its mux are genuinely gone, so the tapeout
netlist is unchanged … (flists set 0)". But:
- `TXGEN_PRESENT` **defaults to `1'b1`** in `tidelink_top`.
- The ASIC/tapeout top `tidelink_dft_wrapper` forwards ~15 params
  (ROLE_FROM_STRAP, TRAIN_ENTRY_FALLBACK, DEBUG_UNLOCK_DEFAULT, ENABLE_AHB_WRITE,
  USE_PHY_V2, NEGO_CFG_RESET, …) but does **NOT** forward or set `TXGEN_PRESENT`.
- Repo-wide grep: `TXGEN_PRESENT` appears ONLY in `tidelink_top` (decl+use) and a
  comment. **No flist, no `.tcl`, no wrapper sets it to 0.** Both ASIC flists
  (`tidelink_top_full_asic.flist:16`, `…_v2.flist:63`) compile `tidelink_tx_gen.sv`.
- The FPGA IP wrapper (`fpga/vivado_ip/tidelink_vivado_wrapper.v`) also does not
  surface it — and that file's OWN comments (lines 157-189) state the rule that a
  param must be on the wrapper face to reach OOC synth. TXGEN_PRESENT breaks that rule.

**Failure scenario:** ASIC synthesis of `tidelink_dft_wrapper` elaborates
`g_txgen` (TXGEN_PRESENT=1) ⇒ the `tidelink_tx_gen` FSM **and the 2:1 mux on the
critical `ahb_tx_*` path** (`tidelink_top:1798-1813`, `ahb_tx_hreadyout` mux at
`:966`) are synthesized into the shipped netlist. This is:
- a violation of the "tapeout netlist provably identical" invariant the whole
  DEBUG_UNLOCK/HONEST_MASK_HS param discipline exists to protect (chip-killer class);
- a **security surface** — an armable line-rate generator reachable through APB
  Region E writes when `!fc_cfg_apb_active` (`tidelink_top:975`), which was supposed
  to be physically absent from silicon;
- an **area/timing** change on the AHB TX group (the doc itself says
  "Watch post-route WNS on the `ahb_tx` group").
It is NOT a data-corruption bug — the generator is POR-disarmed (`gen_owns = state==S_SEND`,
0 after reset) and writes are `!fc_cfg_apb_active`-gated — so the link functions.
This is "a default-OFF-for-tapeout param that isn't actually OFF."

**Sim catches it?** NO. Functional sims pass (disarmed txgen == external path).
The one guard test (doc "a3": `TXGEN_PRESENT=0` elab) sets the param explicitly;
it does not assert the ASIC top's inherited default is 0. Gate stays green.

**Suggested check (not a fix):** confirm with David whether tapeout intends txgen
present. If not, `dft_wrapper` must pass `.TXGEN_PRESENT(1'b0)` (or add a wrapper
param defaulting 0), mirroring how every other tapeout knob is threaded.

---

## P2 — CONFIRMED: the I1 FCSM fix's protective regression is NOT in `make sim_gate`

**Where:** `cocotb/tidelink_fcsm_silicon_ratio/` (new: 221-line test, 1079-line
`tb_top.sv`, standalone `Makefile` with `SIM=vcs`, targets `repro`/`fixed`/`clean`).
Claims in `flists/tidelink_top_full_asic.flist:148-152` and `…_v2.flist:284-291`:
"regression-gated in cocotb/tidelink_fcsm_silicon_ratio".

**What:** `grep fcsm_silicon|silicon_ratio Makefile` ⇒ **not present**. The suite is
a hand-run VCS Makefile, never invoked by any `sim_gate_*` target and absent from
`SIM_GATE_ALL_SUITES`. The flist comments assert it is "regression-gated" — it is
not, in the `make sim_gate` blocking sense.

**Failure scenario:** A future revert of the FPGA FCSM override (re-point
`WlinkGenericFCSM[_1..4]` back to `deps`) or of `SOCL_L7_MIN_CRACK_EMITS 8→32`
passes `make sim_gate` **green** — the only test that distinguishes 8 from 32
(gate=32 FAIL, gate=8 PASS at ref=40ns) never runs. This is the exact prior burn
recorded in memory ("sim_gate suite list EXCLUDES tidelink_ahb ⇒ gate green while
CI red"). The I1 fix itself is correct (see verified-clean below); the hole is that
nothing in the blocking gate protects it.

**Sim catches it?** N/A — it IS the missing sim. `make sim_gate` cannot regress-guard
a suite it never calls.

---

## P3 — CONFIRMED: Option-A `train_fallback` regression not in the gate

**Where:** `cocotb/tidelink_autoneg_rolestrap/test_train_fallback.py` (new, 166 lines);
`grep train_fallback|rolestrap|autoneg Makefile` ⇒ comments only, no recipe.

**What:** The ON-behaviour of TRAIN_ENTRY_FALLBACK (beacon lights ON=1 / dark ON=0)
is proven by this test but it is not wired into `make sim_gate`. Lower severity than
P2 because the param is DEFAULT-OFF and pending David's ratification, so the shipping
default is protected by the constant-fold (verified below); only the opt-in ON path
is ungated. Worth folding in when Option A is ratified.

---

## P3 — CONFIRMED: `docs/SIM_GATE_COVERAGE.md` merge numbering is inconsistent

**Where:** `docs/SIM_GATE_COVERAGE.md` (this diff).

**What:** The union merge left **two `### 2.4` headings** ("Added 2026-07-29 (1)"
and "Added 2026-07-24 … (3)"), both restarting their tables at "# 23" (two #23,
two #24). Header says "22 suites → 25", but suites actually added to the blocking
list include `txgen_unit/txgen_negctl/v2_txgen` (3) + `nack_wedge_recovery` (1) +
`axinode_obs` (1) = 5, so the running count and the `.gitlab-ci.yml` suite number
(previously flagged as needing reconciliation) should be re-derived. Doc-only nit;
no RTL impact.

---

## P3 — PLAUSIBLE: hardware credit-consume dropped when the credit counter is disabled

**Where:** `src/rtl/fifo/tidelink_apb_regs.sv:424-428`.

**What:** `hw_credit_consume_vld` (the txgen's hardware reservation) is applied only
inside `if (pair_credit_counter_en)`. If software sets `pair_credit_counter_en=0`
while the generator is armed, a consume is silently dropped (counter not decremented)
⇒ the generator could out-run its credit. **Mitigated:** `pair_credit_counter_en`
RESETS to `1'b1` (enabled) and the peer-increment is gated the same way, so any
`en=0` misconfig also breaks normal credit return and would surface immediately.
Very low risk; noted for completeness.

**Sim catches it?** No existing suite drives `en=0` while armed; would need a
targeted test.

---

## P3 — PLAUSIBLE: I5 outstanding backstop is single-outstanding / rlast-gated

**Where:** `src/rtl/tidelink_top.sv:1509-1600` (`sub_rd_os_r`/`sub_wr_os_r`, `sub_osr_ctr_r`).

**What:** The backstop tracks a single-bit read/write-outstanding flag and resets
its timer only on `sub_r_done` (`rvalid&rready&rlast`) / `sub_b_done`. Two corners a
sim wouldn't hit on the XHB500 window path (which is single-outstanding, single-beat):
(a) two ARs accepted before the first R(last) ⇒ the first R clears tracking and the
second outstanding read is untracked; (b) a genuinely slow multi-beat burst whose
rlast is > 2^16 hclk away ⇒ false 2-cycle ERROR even though it was progressing. Both
require AXI multi-outstanding / long-burst behaviour the bridge likely never emits.
Low risk; the per-beat timer has the same 2^16 rationale.

---

# Verified CLEAN (green) — traced, no defect

- **`ext_stalled`→`sub_ext_stalled` rename (I2/I5):** the only two remaining
  `ext_stalled` (`tidelink_top:905,912`) are the intended module-scope APB
  ext-timeout wire; the per-beat backstop is now uniquely `sub_ext_stalled`
  (`:1489,1573`). No reference binds the wrong signal. CONFIRMED clean.
- **I1 FCSM ASIC/FPGA separation:** FPGA v2 flist points `FCSM[_1..4]` at
  `local_overrides` (gate=8 via ``ifndef SOCL_L7_MIN_CRACK_EMITS_VAL / define 8``);
  BOTH ASIC flists (v1+v2) keep `FCSM 0-4` on `deps` (hard-coded 8'd32, no macro).
  The `` `define`` never enters the ASIC compile (those files aren't in the ASIC
  flist), so ASIC gets 32 and FPGA gets 8, as intended. `+define+…_VAL=32` restores
  the failing value for the repro. CONFIRMED correct.
- **TRAIN_ENTRY_FALLBACK default-OFF everywhere:** `1'b0` at autoneg, controller,
  tidelink_top, dft_wrapper, and FPGA wrapper. All 4 Option-A hooks constant-fold to
  prior logic when 0: (1) ST_TRAIN_ENTER timeout `if(FB && state==ENTER)…else{error}`;
  (2) NEGO-NACK `(FB&&train_auto_en)?NEGO_DONE_PRE:NEGO_DONE`; (3) TXN_CHECK
  `MISS_ACK && !FB` ≡ `MISS_ACK`; (4) ST_TRAIN_FAIL park `else if(FB&&…)` folds away.
  No path fires them with param 0. CONFIRMED.
- **I4 Region F decode:** `apb_region=paddr[8:5]`; Region F (`4'b1111`) special-cased
  onto `ctrl_reg_addr[4:3]==2'b00` with `ctrl_reg_rf`, priority `rf>rd>r10>r9` and
  apb_regs asserts ≤1 of {rf,rd,r10} ⇒ no alias with Region C (its naive `2'b11`) and
  no collision with Region E/txgen (`1110`). RO: excluded from `ctrl_reg_write`,
  `pwrite⇒pslverr=1` in the `4'b1111` case. `regionF_axinodes_rdata` + the
  `tidelink_axinode_obs` instance are OUTSIDE any `ifdef TIDELINK_PHY_V2`, and the
  tapped `axi_tgt_0_*/axi_ini_0_*` are module ports (exist in V1 and V2) ⇒ live in
  both, no V1 elaboration break. Full chain apb_regs→fifo→top→controller wired
  (`ctrl_reg_rf` at fifo:121/335, top:706/1745, controller port). CONFIRMED.
- **I2 `rd_pipe_r` guard:** single-cycle pulse (set on `ext_is_nonseq & !hwrite &
  !pipe_valid_r`, else-cleared); masks the master-facing hreadyout for exactly the
  one pipe-offset cycle on reads only, after which `xhb_sub_hreadyout_raw` resumes.
  Priority below the sub_err ERROR sequence, above raw. Adds ≤1 latency cycle, no
  data loss (hrdata held). Does not touch `xhb_sub_hready` into the bridge. CONFIRMED.
- **pair_credit 3-way combine:** 33-bit widened sum, saturate-at-zero underflow
  guard preserved; simultaneous peer-increment + generator-consume nets correctly
  (no dropped increment). High-end 32-bit overflow wrap is pre-existing (matches the
  old `counter+pwdata`), not a regression. CONFIRMED.
- **txgen datapath restructure:** AHB address/data pipelining fixed (HWDATA trails
  HADDR one cycle via `data_word_r`/`data_pend_r`), ownership held through the final
  data phase, `total_beats=pkt_len+2` word count exact, header now `WR_REQ` (2'b01) in
  [19:18] so the peer stores it. Gated byte-exact by `v2_txgen`. CONFIRMED.
- **Makefile sim_gate union:** both merge sides preserved; new blocking suites
  (`txgen_unit/negctl`, `v2_txgen`, `nack_wedge_recovery`, `axinode_obs`) added to
  `SIM_GATE_ALL_SUITES` AND to the explicit `@$(MAKE)` run list; `test_14` correctly
  kept OUT (non-blocking, real red, not masked). CONFIRMED (except the P2/P3 omissions).
- **DEBUG_UNLOCK_DEFAULT 1→0 on ASIC:** intentional secure default (LOCKED), gate
  decoupled to `mask_hs_match | mask_hs_bypass_i`; FPGA wrapper stays `1'b1` (bench
  unlocked). Documented residual: ASIC (nanoSoC) bring-up not yet run — a noted risk,
  not a defect.

---

# Bottom line

One P1 worth surfacing before tapeout: **the traffic generator is in the ASIC
netlist** because `TXGEN_PRESENT` defaults to 1 and no ASIC-side override sets it 0,
contradicting the documented "tapeout netlist provably identical" invariant (sim-invisible).
One P2 coverage hole: **the I1 FCSM fix's regression is not in `make sim_gate`**, so
the FPGA gate=8 fix is one silent revert from regressing despite flist comments claiming
it is "regression-gated." Everything else in the focus areas (Region F decode, the I2/I5
rename + guards + backstop, Option-A default-OFF constant-folding, the merge unions) traced
CLEAN. No P0.
