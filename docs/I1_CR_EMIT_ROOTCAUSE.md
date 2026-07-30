# I1 d2d bring-up regression — CR-EMIT root-cause analysis

Branch: `analysis/i1-cr-emit-rootcause` (read-only analysis + sim; no HW, no push).
Date: 2026-07-30. Author: verification (subagent).

Scope of the A/B under investigation:
- `flists/tidelink_fpga_v2.flist` FCSM 0-4 pointed at `src/rtl/local_overrides/WlinkGenericFCSM{,_1..4}.v` (the "recovery override") → KR260 eth-chiplet d2d link FAILS bring-up: `SWI_LANE_STATUS=0x00100000`, `cr_seen=0 crack_seen=0 cal_done=0 fcsm=0/1`, BOTH dies.
- Same flist with FCSM 0-4 on `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM*.v` (pristine, recovery-stripped) → brings up (fcsm=4).
- The prior emit-gate fix (`fix/i1-fcsm-bringup` @ `e79a5b8`, the `socl_reached_link_idle` latch) was built into real bitstreams, packaging/netlist-verified, bench-tested, and **did not work** — `cr_seen` stayed 0.

---

## VERDICT (headline)

**There is NO state-1 CR-emit datapath difference between the override and deps. The hypothesis that the override changed the emitted CR word / format / data_id / valid / TX-enable so the shared RX never latches it is REFUTED at the RTL level.** The CR-emit path, the arbiter request (`sop`), and the state-0→state-1 entry are byte-identical to deps across all five override nodes. Every override-added term is provably inert during the pre-CR bring-up window except the L6/L7 emit gates — and those are exactly what the refuted fix already neutralised, with no effect on silicon.

Therefore `cr_seen=0` is **not** a CR-emit *logic* defect in the override. The regression is a **reset/clock-enable-sequencing sensitivity, physically amplified by the extra logic the override adds to the 5 AXI FC nodes** — the same class of failure the UVM env already documents for the *pristine deps* FCSM under a staggered `wlink_por_reset` (SHORTCOMINGS item 14b). This means the next step is an STA/ILA + build A/B, not another CR-emit RTL patch.

Confidence: **high** on "no CR-emit logic bug" (structural proof + first-hand sim). **Medium** on the positive mechanism (reset-sequencing/timing amplification) — that part needs a board/STA cycle to confirm.

---

## 1. Structural diff — local_overrides vs deps (states 0-3 / CR-emit path)

Golden: `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM.v` (1159 lines, pristine Chisel node).
Override: `src/rtl/local_overrides/WlinkGenericFCSM.v` (1311 lines). `_1.._4` carry the **identical** change set (verified individually — no rogue file, no port change, no entry change).

The complete set of override changes (nothing else differs):

| # | Change | Location (override) | Active during pre-CR bring-up? |
|---|--------|---------------------|-------------------------------|
| 1 | License header | 1-14 | no (comment) |
| 2 | `SOCL_*` localparams incl. `SOCL_L7_MIN_CRACK_EMITS` default 8 (was hard 32) | ~53-80 | internal params |
| 3 | L6 CR-emit gate on **state-1 EXIT** (`_GEN_34 & socl_l6_cr_emit_gate_ok`) | 288, 312 | **EXIT only** — refuted |
| 4 | L6 gate on state-1 **switch-to-CRACK** in `data_id` block | 865 | delays CRACK, keeps CR — see below |
| 5 | state-2 values keyed on `socl_l7_crack_release` instead of `crack_pkt_seen` | 316-321 | state 2, after CR |
| 6 | NACK terms use `isNotExpPacket_l7` (masked by `socl_l7_bringup_forgive`) | 299, 368-421, 987-991 | **inert until cr&crack seen** |
| 7 | `out_prepend_swi_disable_crc` reset **1'b0 → 1'b1** | 713 | reset-active — but see §2 |
| 8 | L6/L7 emit counters | ~817-838 | counters only, gate nothing directly |
| 9 | Fix-D watchdog (`socl_l7_wdog_*`) | state 7 only | no |
| 10 | Fix-E periodic re-ACK (`socl_reack_*`) | requires `state>=4` | no |

### The CR-emit datapath itself is byte-identical

State-0→1 entry (deps `WlinkGenericFCSM.v:613-616`, override `:690-692`): both
`else if (_ack_seen_before_T /* state==0 */) if (en_ff2_tx_demet_io_out) state <= 3'h1;` — **unchanged**.

The emitted CR packet, driven whenever the node is granted in state 0/1:
- `data_id <= swi_cr_id` (0x8) — override `:859` / `:868`, deps `:767` — **unchanged**
- `word_count <= 16'hf0f` (credit advert `Cat(ne_rx_credit_max, ne_tx_credit_max)`) — **unchanged**
- `sop` (the arbiter request) — state-0 `_GEN_25 = en_ff2|sop`, state-1 `_GEN_35 = advance|sop` — **unchanged**
- `link_data`, `auto_tx_out_*` port assigns — **unchanged**

Cross-checked against Chisel `FC.scala:444-489` (IDLE sets `data_id_in := cr_id`; SEND_CREDITS1 keeps `cr_id` until `crack_pkt_seen_tx || cr_pkt_seen_tx`). The generated Verilog matches.

Change #4 (the one state-1 body edit) only ANDs `socl_l6_cr_emit_gate_ok` onto the condition that *switches away* from CR to CRACK:
```
deps :   if (crack|cr seen)                       data_id <= crack_id; else data_id <= cr_id;
over :   if ((crack|cr seen) & gate_ok /*cnt>=32*/) data_id <= crack_id; else data_id <= cr_id;
```
This makes the override emit the CR **longer** (up to 32 times) before switching to CRACK. It **cannot suppress** the CR — the `else` branch (emit `cr_id`) is unchanged and is what runs first. RX CR detection is `pkt_is_cr_pkt = auto_rx_in_sop & auto_rx_in_valid & auto_rx_in_data_id == swi_cr_id` (deps `:159`) — purely `sop`+`data_id`, CRC-independent.

**Conclusion of §1: there is no file:line in the override that changes what CR word is emitted or whether it is emitted. The CR-emit "smoking gun" the mission asked me to find does not exist.**

## 2. Why `disable_crc` reset-flip (the only reset-active change) is NOT the cause

`out_prepend_swi_disable_crc` resets to 1'b1 in the override (`:713`) vs 1'b0 in deps. It is the *only* difference that is active out of reset in states 0-3. But it feeds exactly one place:
```
crc_corrupt = auto_rx_in_sop & auto_rx_in_valid
            & auto_rx_in_data_id == swi_data_id_1 /* 0x80 = DATA pkt */
            & ~out_prepend_swi_disable_crc
            & (rx_crc_computed != auto_rx_in_crc);      (deps :153-154)
```
It only masks CRC checking of **DATA packets (data_id==0x80)**. During bring-up only CR/CRACK/ACK/NACK flow (no 0x80), so it is provably inert for `cr_seen`. It is a real deviation worth reverting (CRC-off-by-default is a prior chip-killer), but it is not this bug.

All other override terms (#5,6,9,10) are conditionally inert until `cr&crack seen` / `state>=4` / `state==7`, i.e. they cannot fire before the first CR is latched.

## 3. Reconciliation with the refuted emit-gate fix

The refuted fix forced both emit-gate-OK terms true during bring-up (`socl_reached_link_idle` is 0 until first `state>=4`), making states 1 and 2 exit **deps-identical**. After that fix, the override is functionally equivalent to deps for the entire CR/CRACK handshake (every remaining delta is inert per §1-2). It still produced `cr_seen=0` on silicon. **This is only self-consistent if the failure is not in the FC-node bring-up logic** — precisely the conclusion of §1. Holding the gate open "changed nothing" because there was never a logic gate to open in the first place; the emit-gate livelock is a *sim artifact* (see §5).

## 4. UVM lead (`top_system`) — matches the signature, but with DEPS FCSM

(from the `uvm/` investigation — file:line proof in the sub-report)
- The only d2d UVM env, `uvm/tidelink_top_system/`, compiles the **pristine deps FCSM** via `-y $(DEPS_DIR)/logical/wlink` (`Makefile:299`), NOT the local_overrides copies, and is **QUARANTINED — does not elaborate** since 2026-07-07 (`Makefile:362-384`: current `tidelink_top.sv` needs `local_overrides/axi_chiplet_controller.sv` ports). So **it cannot exercise the override as-is.**
- BUT it *documents the exact silicon signature* with the deps FCSM: `docs/reference/SHORTCOMINGS.md` item 14b (2026-05-08) + the `top.sv:947-995` FCSM diagnostic — in `test_top_autoneg_basic`, `cr_pkt_seen_rx` **never asserts** → SEND_CREDITS1 (state 1) stuck → scoreboard `RX=0x00000000` both dies — attributed to **staggered `wlink_por_reset` / FCSM credit-grant sequencing** (NOT the override).

Implication: `cr_seen=0 / SEND_CREDITS1-stuck / RX-all-zeros` is a **generic "the CR/CRACK credit handshake did not close" symptom that the deps FCSM itself exhibits under a reset/clock-enable stagger.** It is exactly the mechanism class MEMORY records (`role_locked` = mutual clock enable; forwarded `pad_clk_tx` = peer `pad_clk_rx`). The override does not create a new CR-emit bug — it adds ~50 state bits + comb logic to each of 5 FC nodes, which plausibly tips this already-marginal reset/timing handshake (the same one deps narrowly wins) over the edge.

**Can the UVM env be the repro?** Not without work: it must be (a) de-quarantined (re-point top/wlink to the `local_overrides` set, per its own TODO `Makefile:378-382`) and (b) FCSM 0-4 re-pointed deps→local_overrides. Then `test_top_autoneg_basic` run deps-vs-override under its por-reset stagger is the most promising *logical* repro of `cr_seen=0`. Worth doing; it is the only env that already models the stagger that produces the signature.

## 5. Sim evidence I ran (verify-the-instrument; first-hand)

Harness `cocotb/tidelink_fcsm_silicon_ratio` (paired V2 dies; its flist `sed`-re-points FCSM 0-4 → local_overrides, so the override IS compiled).

Command (clean-link CONTROL test, override compiled, gate forced to the FAILING silicon value 32):
```
make CRACK_EMITS=32 SIM_BUILD=sim_build_control32 \
     MODULE=test_fcsm_silicon_ratio \
     TESTCASE=test_axi_fcsm_clean_bringup_at_silicon_ratio
```
Result: **PASS.** All 10 AXI FC nodes reached `state=4` (LINK_IDLE); sideband FCSM `state=4` on BOTH dies; `max_crack_emit_count=32/33` (proves the gate compiled as 32, not the default 8). Verified `+define+SOCL_L7_MIN_CRACK_EMITS_VAL=32` in the build and the local flist re-point.

Why this counts as "reaches a latched CR": a node cannot leave state 1 without `cr_pkt_seen_tx || crack_pkt_seen_tx`, and cannot leave state 2 without `crack_pkt_seen_tx` (FC.scala:460,476). Reaching state 4 on both dies is therefore proof the CR **and** CRACK were latched. **The override, with the exact failing gate, brings the pair fully up on a clean link.**

This is the RED/GREEN inversion the analysis predicted: the override is **GREEN on a clean link**. The cocotb "repro" (`make repro`) only turns RED by *artificially* dropping the LL enable every ~3000 hclk (`_periodic_rebringup`), which resets the emit counter — a modelled marginal link, not the actual stimulus. That sim reproduces an emit-gate *livelock*, which is why the emit-gate fix greened it while silicon stayed red. It does not reach the real `cr_seen=0` mechanism. (This confirms the prior author's own "does not prove the silicon outcome" caveat.)

## 6. What actually breaks (best-supported hypothesis)

`cr_seen=0` on silicon is the **CR/CRACK credit handshake failing to close under reset/clock-enable sequencing**, and the override regresses it because the extra recovery logic (5 nodes × {2×8b emit counters, 16b wdog, 16b reack, several stickies} + combinational gating) perturbs area/switching on/near the documented marginal **RX-capture-clock** path (MEMORY: "z2/KR260 bring-up lottery = fabric LUT on RX capture clock") and/or the FCSM→TxRouter arbiter path. deps (leaner) wins the same marginal handshake; the override loses it. This is invisible in functional RTL sim (which is why the clean-link sim is green) and matches the deps-FCSM por-reset-stagger 14b signature.

Not fully excluded, and cheap to check: a build/packaging delta larger than the FCSM source in the deps-vs-override A/B (the refuted-fix author's stale-IP suspicion). The task states the *latch* reached the netlist; confirm the *baseline override* A/B was a clean-room rebuild whose netlist diff is scoped to the FCSM only.

## 7. Fix proposal (targets the real mechanism, honestly framed)

There is no CR-emit logic to patch. Recommended, in order:

1. **Immediate / safe (do this for the next bench cycle):** revert the eth-chiplet re-point — `flists/tidelink_fpga_v2.flist:292-296` local_overrides → deps for FCSM 0-4 (undo `b98b944`; this is the 2026-07-11 known-good state, and matches the ASIC flists already held on deps by `6e3b25d`). This drops the unproven I1 recovery features on the AXI nodes but restores proven bring-up. FCSM_6 (sideband) stays local; FCSM_5 stays deps.
2. **If the recovery features must be kept**, minimise the override's bring-up-window footprint rather than touch the (correct) CR emit:
   - Revert `out_prepend_swi_disable_crc` reset 1'b1 → 1'b0 (`:713`) to match deps — correct on its own merits (CRC-off-by-default chip-killer) and removes a reset-active delta.
   - Extend the `socl_reached_link_idle` gating to ALL socl_* recovery flops (hold the counters/stickies in reset until first LINK_IDLE), so the node is bit-identical to deps — including toggling — during the handshake. Removes any dynamic contribution; will NOT help if the effect is pure static area/timing.
   - Re-run STA on the override build focused on the RX-capture-clock and FCSM→TxRouter paths; that is the confirm.
3. **Repro for the lead:** de-quarantine `uvm/tidelink_top_system` + re-point FCSM 0-4 to local_overrides, run `test_top_autoneg_basic` deps-vs-override under its por-reset stagger. This is the only environment that already produces the `cr_seen=0` signature.

## 8. Proven vs hypothesised (for the lead)

PROVEN (structural + first-hand sim):
- No CR-emit content/format/data_id/valid/entry difference between override and deps (§1, byte-level).
- `disable_crc` reset-flip is inert for `cr_seen` (§2).
- The override brings the pair fully up (CR+CRACK latched, state 4 both dies) on a clean link at the failing gate=32 (§5).
- The cocotb "repro" is an artificial-enable-drop livelock, not the silicon mechanism (§5); the emit-gate is not the root cause (§3), consistent with the refuted fix's null result.
- The UVM d2d env compiles deps (not the override) and is quarantined; the matching `cr_seen=0` signature it documents is a deps-FCSM por-reset-stagger effect (§4).

HYPOTHESISED (needs a board/STA cycle):
- That the override regresses bring-up by amplifying a reset/clock-sequencing / RX-capture-clock timing margin (§6). Confirm via STA on the override build and/or an ILA on `cr_pkt_seen_rx` + `wlink_por_reset` stagger on the two boards; and a netlist-scoped deps-vs-override A/B to rule out a build delta.
