# Build #5 HW validation — 2026-05-30 (overnight session)

**Build:** #5 (commit `f10e6fefb93a445bd6f05aa4ad58c7984e796eb0`, label `build5-ila`, FPGA_INSERT_DEBUG_CORE=1)
**Bitstreams:** master sha `e4783985d48a…`, slave sha `f77a36ac63ff…`
**Lease:** bridge1 (pynq_z2_02 + pynq_z2_03) held by mapstone-dev
**Branch at build:** `fix/fcsm-l7-wedge-watchdog-build5-hw`

## Headline

**Build #5 ILA build IS HW-functional.** Build #4 R-1 regression (`pair_credit_counter` mark_debug fold breaking returner-busy-clear) is **FIXED** by removing that one attr. Bug A and Bug B both reproduce on silicon as expected from sim. Bug A wedges master link on AHB write. Bug B is a 2-level bug: RTL gate + BD tie-off.

| Capability | Build #3 | Build #4 (ILA, regressed) | Build #5 (ILA, fixed) |
|---|---|---|---|
| Link bringup | ✅ 16/16 | ✅ 16/16 | ✅ 16/16 (via converge loop) |
| `cal_done` both sides | ✅ 1/1 | ✅ 1/1 | ✅ 1/1 |
| Returner not stuck | ✅ REG_STATUS=0x00 | ❌ master busy=1 | ✅ REG_STATUS=0x00 |
| Doorbell M→S | ✅ resp_acc bumps | ❌ 0 | ✅ resp_acc=0x1000 (after ~10 doorbells) |
| FCSM state both sides | 4/4 (LINK_IDLE) | 7/4 (asymmetric) | 4/4 (LINK_IDLE) |
| AHB N=1 M→S | ❌ Bug A (no wedge) | ❌ wedge | ❌ Bug A (wedges master link!) |
| HW_SYNC PTP M→S | ❌ Bug B | ❌ inseparable | ❌ Bug B (slave bit2=0) |

## Build #4 R-1 verification (CONFIRMED)

[docs/BUILD4_HW_VALIDATION_2026_05_29.md](BUILD4_HW_VALIDATION_2026_05_29.md) hypothesised R-1 (~45%) — that `mark_debug` on `pair_credit_counter` blocked a synth fold breaking returner-busy-clear. Build #5 removed ONLY that attr (kept all other mark_debug from build #4). Result:

- Build #5 returner clears properly post-bringup. `REG_STATUS = 0x00` on both sides.
- FCSM lands at 4/4 (LINK_IDLE), matching build #3 baseline (NOT 7/4 like build #4).

**Conclusion**: R-1 hypothesis **confirmed**. Permanent fix is to NEVER apply `mark_debug` to `pair_credit_counter` or `pair_credit_counter_en` in `src/rtl/fifo/tidelink_apb_regs.sv`.

## Bug A — RECONFIRMED on Build #5 silicon

Test: master writes `AHB_TX` (0x44000000) with `(length=2, payload=[0xDEADBEEF, 0xCAFEBABE])`.

Result:
- Slave `REG_PKT_LEN = 0x00` (RX FIFO never got the packet)
- Slave `AHB_RX_FIFO[0..3] = all zeros`
- **Master SSH disconnects** ("client_loop: send disconnect: Broken pipe")
- Slave `SWI_LANE_STATUS` drops from `0x018900ff` → `0x00020000` (LINK GOES DOWN)
- **Master is wedged**, requires fpgahub power-cycle (`pynq_z2_02_ps --off 8.0` + 90s wait) to recover

This matches V1's sim findings: AHB write produces no slave-side response, but additionally on HW it wedges the master FSM hard enough to take down the link. This is a "wedge primitive" — the same pattern noted in handoff doc.

**Implication for autonomous testing**: NEVER write AHB_TX in an autonomous loop without immediately checking liveness + having a recovery path. Wedge recovery is ~2-3 min per occurrence.

## Bug B — RECONFIRMED on Build #5 silicon (with critical SW workaround insight)

Test (with SW workaround attempt — small HW_SYNC_INTERVAL):
```
HW_SYNC_INTERVAL @ 0x044 = 32
PTP_CTRL @ 0x034 = 0x09 (enable + GM)
HW_SYNC_CTRL @ 0x040 = 0x05 (enable + force_en)
```

Result:
- Master `HW_SYNC_STATUS = 0x00000001` — only bit 0 set (`hw_sync_en_r`)
  - **NOT bit 1 (busy)** — FSM stays at ARMED, never reaches FIRE
  - **NOT bits[17:2] (seq_num)** — no sync packets emitted
- Slave `PTP_CTRL bit[2] = 0` — `ptp_rx_valid_r` never asserts (no sync packets received)
- Slave `HW_SYNC_STATUS = 0x00000000` (expected — slave didn't enable HW_SYNC)

**CRITICAL FINDING**: The SW workaround alone (writing small `HW_SYNC_INTERVAL`) is **NOT SUFFICIENT** on this silicon. Why:
- BD ties `phc_nanoseconds = 30'h0` (no PHC counter wired)
- `target_ns_r = phc_nanoseconds + hw_sync_interval_r = 0 + 32 = 32`
- `phc_time_reached = (phc_nanoseconds >= target_ns_r) = (0 >= 32) = FALSE`

The `phc_time_reached` gate is permanently false regardless of how small `hw_sync_interval_r` is, because `phc_nanoseconds` never advances past 0.

**Required fix**: The Bug B RTL fix (force_en bypass of phc_time_reached, V2-validated GREEN-LIGHT) IS necessary. The SW workaround alone won't unblock silicon.

**Secondary requirement**: Long-term, BD-level PHC counter (Option C separate workstream) needs to drive `phc_nanoseconds_i` so the time-based path (when `force_en=0`) works at all.

## Sim-vs-HW reconciliation table

| Behaviour | Sim | HW Build #5 | Match? |
|---|---|---|---|
| FCSM state pre-traffic | 4/4 | 4/4 | ✅ |
| `cr_pkt_seen_rx` both | 1/1 | (not directly readable) | TBD |
| `crack_pkt_seen_rx` both | 1/1 | (not directly readable) | TBD |
| Master `tl_fc_a2l_valid` on AHB write | 0 (Bug A) | wedge (presumed 0) | likely ✅ |
| Slave `tl_fc_l2a_valid` after AHB write | 0 (no traffic) | 0 (presumed; AHB_RX_FIFO empty) | ✅ |
| Master `hw_sync_state_r` after HW_SYNC_CTRL=0x05 | wedged ARMED | wedged ARMED (HW_SYNC_STATUS bit 1 = 0 = not busy) | ✅ |
| Slave `ptp_rx_valid_r` after master HW_SYNC | 0 | 0 (PTP_CTRL bit 2 = 0) | ✅ |
| Master wedges on AHB write | not observable | YES (SSH drops, link DOWN) | sim doesn't have wedge primitive |
| L8 fix advances slave FCSM 4→5 | YES (V1) | not yet tested on HW | TBD |
| L9 fix drains slave RX FIFO | NO (V3 — also incomplete) | not yet tested on HW | TBD |

## ILA capture (deferred)

ILA capture from mapstone-dev Vivado HW Manager was not attempted in this session because:
1. Bug A wedges master link (would lose JTAG mid-capture)
2. Bug B reproduction is verified via APB regs already — Bug B confirmed without needing ILA
3. Vivado HW Manager scripting from mapstone-dev needs interactive setup

**For next iteration**: capture would be useful to verify the L8/L9 trace (master `state==5`, slave `state==4`, peer-side `pkt_is_data_pkt`/`isExpPacket`/`send_nack_req` activity). Use the surgical Build #6 probe set ([docs/BUILD6_ILA_PROBE_PATCH_2026_05_29.patch](BUILD6_ILA_PROBE_PATCH_2026_05_29.patch)) if Build #5 captures are inconclusive on the RX-wedge mechanism.

## Sequence run tonight

1. Build #5 launched (~22:07 by autonomy/separate session); pair-all bit completed 00:45
2. Capture pipeline (build5_capture.sh) hit stale-manifest + srv03335-no-route issues
3. Re-staged on mapstone-dev as `/tmp/tidelink_deploy_build5/`, regenerated manifests with correct SHAs
4. Deploy via `bash deploy_pair.sh ... /tmp/tidelink_deploy_build5` (4th positional arg = artefacts dir)
5. `bringup_pair_converge.sh` (5 iters max, settle=2s) — converged at iter 1 (16/16)
6. **Doorbell M→S** — verified WORKING (slave RESP_ACC = 0x1000)
7. **AHB M→S** — wedged master (Bug A reconfirmed)
8. Power-cycle master via `fpgahub hub power-cycle pynq_z2_02_ps --off 8.0` + 90s wait
9. Re-deploy + re-bringup + **HW_SYNC test** — Bug B reconfirmed (only bit 0 set, no FIRE)

## What's still needed for "link up reliably"

1. **Bug B RTL fix** must be applied to `src/rtl/tidelink_ptp.sv:399`: change `wire phc_time_reached = (phc_seconds...)` to `wire phc_time_reached = hw_sync_force_en_r || (phc_seconds...)`. Build a new bitstream WITHOUT ILA mark_debug (per X2's recommendation — avoid build #4 regression class on a different attribute).
2. **Bug A RTL fix** still unknown. L8 and L9 both INCOMPLETE in sim. Sim doesn't reproduce the master wedge primitive (sim has no AXI/AHB infrastructure that triggers it). HW capture of the wedge moment would inform the next fix iteration.
3. **BD PHC counter** must be wired to `phc_nanoseconds_i` for time-based PTP. Currently `30'h0` constant in `fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl` and similar TCLs.
4. **Optional** — restore `bringup_pair_converge.sh` flow in normal deploy path (it's what makes Build #5 actually converge on first try). Currently `td_set_train.py` single-shot leaves master cal_done=0; the converge loop's per-iteration re-deploy rolls the role_lock/count skew lottery successfully.

## Operational notes from tonight

- mapstone-dev `/tmp/tidelink_deploy/` is shared with `td-autonomy` workstream. Use separate dir `/tmp/tidelink_deploy_build5/` for Build #5 to avoid clobbering.
- `deploy_pair.sh` accepts 4th positional arg for artefacts dir: `bash deploy_pair.sh <IP> <z2_NN> <role> <artefacts_dir>`.
- `fpgahub hub power-cycle pynq_z2_02_ps --off 8.0` works (longer off-time needed for full PSU drain when wedged).
- `pynq_z2_02_pl` has no hub_switch reference — use `_ps` for power cycle.
- Master's `/tmp/` cleared on power-cycle; must re-stage `td_*.py` scripts each time.
- `bringup_pair_converge.sh` is at `/tmp/td_overnight_scripts/` on mapstone-dev.

## Files

- This doc: `docs/BUILD5_HW_VALIDATION_2026_05_30.md`
- Test script: `/tmp/build5_app_test.py` (srv03335 + mapstone-dev + both PYNQs)
- Build artefacts: `/home/dam1n19/SoCLabs/tidelink/imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.{bit,bin,hwh}` + `tidelink_design_wrapper.ltx`
- Staging: `/tmp/tidelink_deploy_build5/` on mapstone-dev
- Predecessor docs: [BUILD4_HW_VALIDATION_2026_05_29.md](BUILD4_HW_VALIDATION_2026_05_29.md), [BUILD5_ILA_BUILD_PLAN_2026_05_29.md](BUILD5_ILA_BUILD_PLAN_2026_05_29.md), [BUG_B_FIX_VERIFICATION_2026_05_29.md](BUG_B_FIX_VERIFICATION_2026_05_29.md), [BUG_A_FIX_VERIFICATION_2026_05_29.md](BUG_A_FIX_VERIFICATION_2026_05_29.md)
