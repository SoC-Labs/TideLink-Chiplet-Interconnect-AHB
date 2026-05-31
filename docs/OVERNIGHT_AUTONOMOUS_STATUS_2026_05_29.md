# Overnight autonomous session — status as of 2026-05-29 ~23:35 BST

User went offline early evening with directive: "Continue iterating autonomously overnight with hardware loops until the bugs are resolved and the link is brought up reliably."

## TL;DR

- **Bug B**: GREEN-LIGHT fix sim-verified (force_en bypass of phc_time_reached). Patch needs `</content>` trailer strip + SW saturation mitigation. Ready to apply.
- **Bug A**: TWO RTL fix attempts have BOTH failed in sim — L8 (V1, RED-LIGHT) and L9 (V3, FAIL). Deeper investigation underway. Next iteration needs Build #5 ILA capture from silicon before more sim guesses.
- **Build #5 ILA**: Original (21:19) killed by 80-min timeout. Relaunched 22:07 — flip-all (slave) done 23:27, pair-all (master) at Phase 3.6 placement, ~15-30 min remaining as of 23:32.
- **Build #5 capture pipeline**: READY (`pynq_host/scripts/build5_capture.sh` from Q4). Awaiting bit completion.
- **All probe specs + fix patches + recipes**: documented and on disk.

## Artefacts on disk for the morning

### Bug fix work
- `docs/BUG_A_FORCE_EXPERIMENTS_2026_05_29.md` — F1 force experiment evidence (foundational)
- `docs/BUG_A_FIX_VERIFICATION_2026_05_29.md` — V1 L8 RED-LIGHT verdict
- `docs/BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md` — Q5 analysis (deep mechanism) + L9 fix recipe
- `docs/BUG_A_FCSM4_AUDIT_2026_05_29.md` — Q2 FCSM_4 latent-but-unused finding
- `docs/BUG_A_PROPOSED_FIX_2026_05_29.patch` — V1 L8 patch (DON'T apply — fails in sim)
- `docs/BUG_B_PROPOSED_FIX_2026_05_29.patch` — Bug B force_en bypass (trailer stripped; needs apply via Edit due to context drift from ILA mark_debug edits)
- `docs/BUG_B_FIX_PLAN_2026_05_29.md` — Bug B fix rationale
- `docs/BUG_B_FIX_VERIFICATION_2026_05_29.md` — V2 GREEN-LIGHT verdict
- `cocotb/tidelink_top_pair/test_buga_real_fix_rx_wedge.py` — Q5 L9 verification test (FAIL — even with L9 applied, slave RX never drains)
- `cocotb/tidelink_top_pair/test_buga_fix_link_data_consumer.py` — V1 L8 test (also failing)
- `cocotb/tidelink_top_pair/test_bugb_fix_force_en.py` — Bug B fix test (PASS in V2)

### Build #5 ILA work
- `docs/BUILD5_ILA_BUILD_PLAN_2026_05_29.md` — full Build #5 strategy
- `docs/BUILD5_ILA_PROBE_PATCH_2026_05_29.patch` — original patch (malformed @@ counts; manually applied via Edit)
- `docs/BUILD5_CAPTURE_RECIPE_2026_05_29.md` — Q4 capture pipeline doc
- `pynq_host/scripts/build5_capture.sh` — Q4 ready-to-run wrapper (NOT yet executed)
- `pynq_host/scripts/phc_ila_capture.{sh,tcl,discover.sh}` — restored from git + patched for Vivado 2025.2 gotchas
- Working tree RTL mark_debug edits applied: `src/rtl/tidelink_ptp.sv` (+6 probes), `src/rtl/fifo/tidelink_apb_regs.sv` (R-1 mark_debug removed)

### Build #6 (next iteration) work
- `docs/BUILD6_ILA_BUILD_PLAN_2026_05_29.md` — Q3 surgical add-only plan
- `docs/BUILD6_ILA_PROBE_PATCH_2026_05_29.patch` — 8 RX-wedge probes in FCSM_6.v
  - `pkt_is_data_pkt`, `isExpPacket`, `crcCorruptSeen`, `send_nack_req`, `socl_l7_reached_link_data`, `socl_l7_bringup_forgive`, `isNotExpPacket_l7`, `_T_54`

### Errata + ILA placement audit
- `docs/HANDOFF_REPORT_2026_05_29.md` + `docs/HANDOFF_ERRATA_2026_05_29.md` (yesterday's 5-erratum fix-up)
- `docs/BUILD4_HW_VALIDATION_2026_05_29.md` (build #4 regression baseline that informs build #5/6 strategy)

## Iteration history this session

1. **Phase 1 audits** (Q-audit agents): credit-gate / bug A / bug B / channels — RESOLVED handoff doc errata, falsified credit-gate hypothesis
2. **Phase 3a localisation**: Bug B decisively localised to phc_time_reached at tidelink_ptp.sv:399; Bug A localised to master TX side
3. **F1 force experiments**: Bug A IS NOT in fc_adapter — it's in Wlink FCSM. Master drives `tl_fc_a2l_valid` 2126 cy but slave never sees it. Slave FCSM stuck at state 4 (LINK_IDLE)
4. **X1/X2/X3 fix proposals**: Bug B (force_en bypass), Bug A L8 (consumer-side state advance), Build #5 surgical probes
5. **V1 (Bug A L8) RED-LIGHT**: L8 advances state but RX FIFO stays empty; L7 invariant breaks
6. **V2 (Bug B) GREEN-LIGHT**: 3/3 tests PASS
7. **Q2 (FCSM_4)**: latent bug but doesn't trigger today
8. **Q3 (Build #6 probes)**: 8 surgical probes ready
9. **Q4 (capture pipeline)**: ready-to-run script + restored Tcl
10. **Q5 (deep Bug A)**: identified `l2a_app_valid` gate at FCSM_6.v:719 + pktnum resync mechanism; proposed L9
11. **V3 (Bug A L9) FAIL**: L9 sticky latches but RX still doesn't drain

## Why sim keeps failing & next strategy

L8 and L9 both fail in sim despite addressing what looked like the right mechanism each time. The slave RX FIFO never drains, regardless of FCSM state manipulation. Working theories:
- Sim's tb_top has additional path constraints that mask the real bug class (the `app_enable` glitch Q5 hypothesised may not even happen in sim)
- The RX wedge has multiple stacked gates and addressing only one isn't enough
- The bug may be in `WlinkRxLinkLayer.v` (RX framer) BELOW the FCSM, not in FCSM itself

**The right next step is Build #5 ILA capture from silicon**:
- See what state slave's FCSM actually settles at on HW
- Watch `send_nack_req`, `pkt_is_data_pkt`, `isExpPacket`, `exp_pkt_num` while master writes AHB
- Compare to sim — if HW shows different signal patterns, sim isn't reproducing reality and we've been chasing a ghost
- If HW shows same wedge, Build #6 surgical probes give the deeper view

## Pending hand-off items for the morning

1. **Strip Bug B patch `</content>` trailer** (done partially — need to apply Edit due to my mark_debug context drift)
2. **Apply Bug B fix to working tree** when ready to build #5b
3. **Build #5 final bit + .ltx** — should appear ~23:50
4. **Execute `pynq_host/scripts/build5_capture.sh`** when bit is done
5. **Analyze capture** — does HW match sim? What's the deep RX wedge signature?
6. **Iterate Bug A fix** based on HW evidence (NOT more sim guesses)
7. **Commit decision**: 9+ untracked tests, 12+ untracked docs, RTL mark_debug edits (apb_regs + ptp). User hasn't authorised commit. Branch is now `fix/fcsm-l7-wedge-watchdog-build5-hw`.

## Concurrent workstreams (not mine; left alone per instruction)

- `td-bisect/td-autonomy/` worktree — user's autonomy bringup (uses srv04936 farm; contending for build slots)
- A third worktree `agent-a2ab483f1ffd74e0b` — not mine, not collapsing

## Worktree cleanup state

- V1 (a4910badfa0d53fd4): collapsed
- V2 (a9f8a77b02d6a1197): collapsed
- V3 (ad55ce030175b6a47): harness still holds lock, NEEDS CLEANUP when accessible

## Lease state

- bridge1 currently held by srv03335 (the build farm) until 23:48 UTC
- Will free when build #5 deploys finish
- `build5_capture.sh` will re-acquire before deploy

## Process state at 23:32

- 20+ build processes (multiple concurrent builds layered)
- My original (21:19) killed at timeout
- 22:07 build progressing (flip-all done, pair-all at Phase 3.6)
- 22:59 build also queued
- td-autonomy build at 22:48 (separate workstream)

## Memory entries updated this session

- `project_tidelink_bugA_master_tx_block_2026_05_29.md` — multiple updates capturing F1, V1, Q2, Q5, V3 evolution
- `project_tidelink_bugB_phc_time_reached_2026_05_29.md` — V2 GREEN-LIGHT verdict
- `MEMORY.md` index — both entries linked with current status

## Recommended morning sequence

1. `tail -50 imp/fpga/run/farm/pynq-z2-pair-all@local.*.log` — confirm build #5 final state
2. Execute `bash pynq_host/scripts/build5_capture.sh` — deploy + capture both bugs
3. Read the capture report (auto-written to `docs/BUILD5_CAPTURE_REPORT_<ts>.md`)
4. Decide: does HW show Bug A FCSM wedge matching sim, or different?
5. If different → revisit sim model, may need to fix tb_top
6. If same → Build #6 with deep RX probes (already speced)
7. Apply Bug B fix + build #5b (without ILAs) in parallel — fixes the demonstrably-validated bug
