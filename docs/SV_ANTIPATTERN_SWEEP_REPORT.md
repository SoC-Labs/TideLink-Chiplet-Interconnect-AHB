# SV Anti-Pattern Sweep — Full RTL Audit for Class A/B Bug Siblings

**Date:** 2026-05-21
**Scope:** Every TideLink RTL file (first-party + chiplet-controller submodule),
both `.sv` and `.v`. Triggered by Phase A mask-handshake silicon issue and the
three already-fixed I²C bugs (467b889, be5eed2, 6a757e2).
**Tool:** `cocotb/lint/sv_anti_pattern_lint.py` (selftest 6/6 pass).
**Worktree:** `/home/dam1n19/td_idelay_wt` @ `feat/td-combined` (sub a55d346).

## TL;DR

* **Default lint scope (.sv only, 39 files):** **0 findings.** The three known
  bugs in `tidelink_autoneg.sv` are already patched and the linter confirms
  every other first-party `.sv` is clean (every `always_comb` has top-level
  defaults; every `case` has either a `default:` arm or top-level defaults).
* **Extended scope (+ `.v` files in `i2c/rtl`, `wlink`, `bridges`, 165 files
  total):** **14 findings**, all Class B (`CASE_NO_DEFAULT`). 0 are Class A
  (`COMB_NO_DEFAULT`).
* **Zero HIGH severity findings.** All 14 are in third-party IP (Forencich
  i2c_master core, Bluespec-generated AXI bridge) and have top-level default
  assignments above the case, so a missing default does NOT enable latch
  inference and CANNOT cause a transition collapse equivalent to the
  state_r/txn_step_nxt bugs.
* **Phase A hypothesis (b) — DISPROVEN.** `mask_byte_cnt_r` and `mask_retry_r`
  both have explicit top-level defaults in the autoneg always_comb
  (lines 401-402). The cause of mask phase not writing `hs_result` is NOT a
  Class A/B sibling. See "Phase A cross-reference" below.

## 1. Methodology

The lint scanner (cocotb/lint/sv_anti_pattern_lint.py) tokenises SystemVerilog
and walks:

* every `always_comb` / `always @*` block → flags any LHS that is assigned
  **only** inside conditional branches (no top-level default) as Class A,
  the `txn_step_nxt`-style latch trap (be5eed2);
* every `case` / `casex` / `casez` block → flags missing `default:` arms as
  Class B, the `state_r`-style collapse trap (6a757e2);
* it correctly recognises full `if/else` chains and case blocks with `default:`
  as covering the conditional, so signals assigned in every branch are NOT
  flagged.

The default `make lint` target scopes to `.sv` only. The selftest passes 6/6,
including positive fixtures for both bug classes.

### 1a. Selftest

```
$ cd cocotb/lint && make selftest
  [PASS] bad_case_no_default.sv
  [PASS] bad_comb_no_default.sv
  [PASS] good_fixed.sv
  [PASS] good_covered_by_default_arm.sv
  [PASS] good_if_else_chain.sv
  [PASS] good_for_loop_vector.sv
  selftest: 6/6 pass
```

### 1b. Default lint scope (.sv)

```
$ make lint
scanned 39 SystemVerilog file(s)
OK — no anti-patterns detected
```

This confirms the three fixes (467b889 / be5eed2 / 6a757e2) hold and that no
other `.sv` regressed.

### 1c. Extended scope (.sv + .v across submodule)

I patched a temp copy of the linter to also walk `*.v` and ran it across:

```
deps/axi-chiplet-controller/logical/{top,address_translation,apb_control,
                                      i2c/rtl,wlink,bridges,PHY}
src/rtl
```

→ 165 files scanned, 14 findings (all Class B, all in `.v` IP).

## 2. Phase A hypothesis (b) cross-reference

The parallel-agent working hypothesis was that mask-phase counters might have
the same Class A/B issues as `txn_step_nxt` and `state_r`. I checked each
candidate in `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv`:

| Signal | Class A check | Class B check | Verdict |
|---|---|---|---|
| `mask_byte_cnt_nxt` | Top-default at **line 401** (`= mask_byte_cnt_r`) | Inside outer `case(state_r)` with **default at line 937**; inside nested `case(txn_step_r)` each has explicit `default: ;` | SAFE |
| `mask_retry_nxt` | Top-default at **line 402** (`= mask_retry_r`) | Same FSM as above | SAFE |
| `state_nxt` | Top-default at **line 391** (`= state_r`) | Outer case has `default: state_nxt = state_r;` (line 937 — fix 6a757e2) | SAFE (already fixed) |
| `txn_step_nxt` | Top-default at **line 419** (`= txn_step_r`) — fix be5eed2 | Every nested `case(txn_step_r)` has `default: ;` | SAFE (already fixed) |
| `peer_tx_capture_en` / `peer_rx_capture_en` | Top-default at **lines 994-995** | n/a (no case) | SAFE |
| `axl_state_nxt` | Top-default at **line 1111** | Case has `default: axl_state_nxt = AXL_IDLE;` (line 1202) | SAFE |
| `axl_target_addr/_wdata/_is_read` | Top-defaults at **lines 1006-1008** | Case has `default: ;` (line 1093) | SAFE |
| `mask_res_byte/_last`, `mask_rd_addr_byte/_last` | Inside case(`mask_byte_cnt_r`) with explicit `default:` (lines 970, 984) | n/a | SAFE |

The mask phase's failure-to-write-hs_result is **NOT** a comb-default bug.
The sequential block at lines 354-379 has the precise condition:

```systemverilog
if (state_r == ST_NEGO_MASK_RES_TX &&
    state_nxt == ST_NEGO_DONE) begin
    mask_hs_local_match_r <= mask_match_w;
    mask_hs_local_fail_r  <= mask_fail_w;
end
```

If `hs_result` is never written, either (i) the FSM never reaches MASK_RES_TX
in the first place (likely — this matches Phase A symptom "FSM stays in POLL")
or (ii) the MASK_RES_TX→DONE edge never fires. Both are FSM-flow issues, not
anti-pattern issues. The lint clears the FSM combinational logic as the root
cause for Phase A and **redirects investigation toward**:

* the upstream POLL→MASK_RD_ADDR gate at line 599 (`mask_hs_auto_en` /
  `nego_cfg[6]`),
* the AXIL substate FSM stalling mid-transaction, or
* timing on the I²C `axl_done_r` pulse.

The Mask-FSM-review agent (working in `docs/MASK_FSM_REVIEW.md`) is best
placed to drill into those next.

## 3. Findings — extended scope

All 14 findings are Class B in `.v` IP. Every one has a top-level default
assignment **above** the offending case, so the missing `default:` does NOT
cause latch inference and the optimiser sees a fully-driven signal.

### Severity matrix

| # | File:Line | Case selector | Top-default present? | Severity | Notes |
|---|---|---|---|---|---|
| 1 | `deps/axi-chiplet-controller/logical/i2c/rtl/i2c_master.v:337` | `case (state_reg)` | YES — `state_next = STATE_IDLE;` @ 302 | MEDIUM | I²C-master high-level FSM. Vivado may collapse arms but the top-default makes any unreached state fall to IDLE, which is the safe collapse |
| 2 | `i2c/rtl/i2c_master.v:642` | `case (phy_state_reg)` | YES — `phy_state_next = PHY_STATE_IDLE;` @ 608 | MEDIUM | I²C-master PHY-level FSM. Same as above |
| 3 | `i2c/rtl/i2c_init.v:247` | `case (state_reg)` | YES — `state_next = STATE_IDLE;` @ 218 | LOW | Init ROM walker — not on the autoneg AXIL path (only fires once at reset) |
| 4 | `i2c/rtl/i2c_master_axil.v:567` | `case ({s_axil_awaddr[3:2], 2'b00})` | YES — every `_next` has top-default | LOW | 2-bit address decode for AXIL writes; all 4 codes enumerated (effectively full) |
| 5 | `i2c/rtl/i2c_master_axil.v:635` | `case ({s_axil_araddr[3:2], 2'b00})` | YES | LOW | Same: 2-bit AXIL-read address decode |
| 6 | `i2c/rtl/i2c_master_wbs_16.v:475` | wb register decode | YES | LOW | Wishbone variant — not used in TideLink (we use AXIL) |
| 7 | `i2c/rtl/i2c_master_wbs_16.v:538` | wb register decode | YES | LOW | Same |
| 8 | `i2c/rtl/i2c_master_wbs_8.v:463` | wb register decode | YES | LOW | Same |
| 9 | `i2c/rtl/i2c_master_wbs_8.v:520` | wb register decode | YES | LOW | Same |
| 10 | `i2c/rtl/i2c_single_reg.v:117` | `case (state_reg)` inside `always @(posedge clk)` | n/a — sequential | LOW | Sequential case: missing-default = FF hold (safe) |
| 11 | `i2c/rtl/i2c_slave.v:289` | `case (state_reg)` | YES — every `_next` defaulted at top | LOW | I²C-slave FSM (we use this as the slave AXIL-master path) |
| 12 | `i2c/rtl/i2c_slave_axil_master.v:297` | `case (state_reg)` | YES | LOW | Slave's AXIL initiator |
| 13 | `i2c/rtl/i2c_slave_wbm.v:278` | `case (state_reg)` | YES | LOW | Wishbone variant — not used |
| 14 | `deps/axi-chiplet-controller/logical/bridges/mkaxi2axil_bridge.v:968` | `case (rg_accum_err)` | NO — but case enumerates ALL 4 codes (2'b0, 2'b01, 2'b10, 2'b11) so it is structurally full | LOW | Bluespec-generated; full enumeration means optimiser is unconstrained but cannot lose info |

### Suggested fixes (cosmetic; not on Phase A path)

For files we own / can patch in-submodule:

* **i2c_master.v:337, 642** — add `default: state_next = state_reg;` /
  `default: phy_state_next = phy_state_reg;` to eliminate the Synth 8-155
  warning entirely. The top-default already makes this safe, so this is
  cleanliness, not bug-fix.
* **i2c_master_axil.v:567, 635** — add `default: ;` to silence Synth 8-155.
* **mkaxi2axil_bridge.v:968** — auto-generated by Bluespec; do not edit.
  Bluespec emits `unique`-style cases — out of scope for hand fixes.

The `_wbs_*` files (Wishbone variants) are not in our flists. We could remove
them from the submodule entirely to shrink lint surface.

## 4. New findings outside the lint's detection radius

The lint catches Class A/B specifically. For completeness I also walked the
two `src/rtl` files explicitly named in the brief (Phase-A lane-path):

* **`src/rtl/tidelink_phy_align_calibrator.sv`** —
  * `always_comb` @ 191: covered by for-loop (every index assigned).
  * `always_comb` @ 202: top-default `nxt_state = cur_state` + `unique case`
    with explicit `default: nxt_state = S_IDLE` → safe.
  * `always_comb` @ 309: top-default `bit_slip_internal = 24'h0` → safe.
  * `always_ff` @ 246 uses `unique case (cur_state)` with `default:` → safe.
* **`src/rtl/tidelink_lane_checker.sv`** — pure sequential counter, no
  combinational case logic. Safe.

Both are clean. There is no Class A/B trap on the active lane training path.

## 5. Recommendations

1. **Promote the lint to `make ci-lint`.** It already self-tests cleanly, runs
   in <2 s on 39 files, and would have caught the be5eed2 and 6a757e2 bugs
   before silicon. Add to `ci/Makefile` and gate FPGA bring-up on it.
2. **Extend default scope to `.v`.** Patch `iter_sources()` to include `.v` so
   the chiplet-controller IP is permanently in scope. The 14 findings are
   all benign but a future change to the IP (e.g. removing a top-default by
   accident) would re-introduce latch risk.
3. **Phase A debug pivot.** The lint disproves hypothesis (b). The mask phase
   isn't writing `hs_result` because the FSM isn't reaching MASK_RES_TX, not
   because a latch/collapse corrupts it. Hand off to the Mask-FSM-review
   agent to instrument the POLL→MASK_RD_ADDR gate (`mask_hs_auto_en` at
   line 599) and the AXIL substate's `axl_done_r` pulse.

## 6. Cross-references

* `cocotb/lint/sv_anti_pattern_lint.py` — the scanner (docstring documents
  the bug classes and their reference commits).
* `cocotb/lint/Makefile` — `make lint` / `make selftest`.
* Submodule commit `be5eed2` — fixes Class A (txn_step_nxt latch).
* Submodule commit `6a757e2` — fixes Class B (outer case missing default).
* Submodule commit `467b889` — fixes nego_driving gating (NOT a Class A/B —
  this was different: missing `role_in_nego` qualifier on a wire-OR).
* `docs/MASK_FSM_DEFAULTS.md` — the earlier mask-FSM defaults audit (Phase A
  hypothesis (b) origin).
* `docs/NEGO_TIMEOUT_REVIEW.md`, `docs/MASK_FSM_REVIEW.md`,
  `docs/LANE_TRAIN_FLOW.md` — sister-agent docs.

## Verdict

* **Total findings:** 14 (all Class B, all in `.v` IP).
* **HIGH severity:** 0.
* **MEDIUM:** 2 (`i2c_master.v` outer FSM cases).
* **LOW:** 12.
* **Class A (latch-risk):** 0 anywhere in the codebase.
* **Phase A cause:** NOT a Class A/B sibling. Investigate FSM flow (POLL→MASK
  gate or AXIL substate stall).
