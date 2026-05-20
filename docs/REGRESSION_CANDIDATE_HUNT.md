# Lane-Lock Regression Candidate Hunt — diff-driven analysis

**Date:** 2026-05-20
**Worktree:** `/home/dam1n19/td_idelay_wt`
**Branch:** `feat/td-combined`
**Method:** Exhaustive `git diff 8bc6051..HEAD` (parent) + `de44db6..de32bac` (submodule).
**Scope:** READ-ONLY. No RTL/XDC modification. Companion to (not duplicate of) `docs/LANE_0_7_DEEP_DIVE.md`.

| | Working (morning) | Current |
|--|--|--|
| Parent commit | `8bc6051` | `85af9d9` (+ sub bump to `de32bac`) |
| Sub commit | `de44db6` | `de32bac` (= 88fea5e revert + a510bae structural fix) |
| Reliability | mean 14.30/16 (variable, sometimes 16/16) | 30/30 deterministic `0x7e` (lanes 0+7 NEVER) |

---

## 1. Parent-side diff at a glance

`git diff 8bc6051..HEAD --stat` reports 158 files / +21966/−7415. Most are docs / cocotb / staging cleanup. The RTL hotspots that could touch the data path:

| File | Lines changed | Risk |
|--|--|--|
| `src/rtl/tidelink_phy_align_calibrator.sv` | +513 −95 | **HIGH** — calibrator rewritten (slip-only → slip×phase, best-of-sweep, S_HOLD, EARLY_EXIT hook) |
| `src/rtl/tidelink_phy_align_regs.sv` | +15 −1 | LOW — sticky-once-locked read accumulator only |
| `src/rtl/tidelink_top.sv` | +44 −12 | **HIGH** — `idelay_ref_clk` port added BUT not wired into chiplet; `USE_IDELAY/USE_CLKBUF/USE_T3A` params plumbed but overrides REMOVED at controller instance (`cd91971`/`ef20615`) |
| `src/rtl/tidelink_lane_checker.sv` | +2 −2 | NIL — header-only `wlink_*` → `tidelink_*` rename |
| `src/rtl/tidelink_perf.sv` | +5 −5 | NIL — `LOCAL_LINK_STATE_W` → `_WIDTH` rename, unrelated to PHY |
| `fpga/rtl/tidelink_idelay_rx.sv` | NEW 224 | **HIGH** if reached — but NOT instantiated in current top (controller no longer has IDELAY wrapper inside) |
| `fpga/rtl/tidelink_rxclk_buf.sv` | NEW 93 | **HIGH** if reached — but NOT instantiated in current top either |
| `fpga/vivado_ip/tidelink_vivado_wrapper.v` | +25 −1 | MEDIUM — adds `idelay_ref_clk` BD-port; threads `USE_IDELAY=1/USE_CLKBUF=1/USE_T3A=1` to `tidelink_top` |
| `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc` | +57 −2 | MEDIUM — **pad_tx[7]/pad_rx[7] remapped F20/B19 → W9/V7**; on-board P15/P16 I2C added |
| `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc` | +173 −66 | **HIGH** — `set_input_delay` added to `pad_rx[*]`, `set_max_delay -datapath_only 8 ns` + `set_bus_skew 2 ns` on RX capture, IOB true on pad_rx, **set_clock_groups -asynchronous** still groups `pad_clk_rx ↔ hclk` — so the source-sync pad-capture path now IS timed. |
| `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl` | +85 −63 | MEDIUM — `clk_wiz_0` gains CLKOUT3=200 MHz wired to `tidelink_0/idelay_ref_clk`; `mask_hs_bypass_i` un-tied (1→0); ILA cores reshuffled (ila_rx/ila_pad removed, ila_i2c added) |

## 2. Submodule-side diff at a glance

`git log de44db6..de32bac --oneline` gives 8 commits; only TWO touch live RTL:

| Commit | File | Risk |
|--|--|--|
| `467b889` | `logical/top/axi_chiplet_controller.sv` | **HIGH** — `nego_driving = role_in_nego && ...` → `nego_en && ...`; removes `!role_locked` gate. SW post-lock AXIL writes to i2c_master core now route to the FSM during states 2/3/4/8/9/10. |
| `a510bae` | `logical/top/tidelink_autoneg.sv` | LOW — explicit `default: state_nxt = state_r;` in case (Bug #3 structural; was a `(* keep *)` attribute) |
| `6318c16/743821b` | autoneg MASK_MAX_RETRY/SLAVE_REARM, Wlink.v 0x21C sticky | NIL for lane-lock — purely I2C-handshake hardening, fires AFTER role_lock |
| `de32bac` | Revert of `88fea5e` mark_debug | NIL — synth-attribute strip only |

The PHY itself (`WavD2DGpio.v`, `WavD2DGpioRx.v`, `WlinkGPIOPHY.v`, `Wlink.scala`) is **bit-identical** between de44db6 and de32bac. Lane-checker, GPIO RX deserialiser, bit_slip distribution: unchanged.

---

## 3. Categorisation

| Change | In PHY datapath? | Touches lane wiring? | Could affect lane lock? | Why |
|--|--|--|--|--|
| Calibrator slip→slip×phase rewrite (+phase_offset output) | NO (param-fed) | NO (shared iterator drives all 8 lanes the same `sweep_slip` until done) | **YES (indirect)** | `phase_offset` output exists but is **UNCONNECTED in submodule's `u_calibrator` instance** (axi_chiplet_controller.sv:1022-1043 has no `.phase_offset()`). Calibrator scores each (slip,phase) but only `slip` survives to the PHY — the phase axis is phantom. With `EARLY_EXIT_ON_ALL_LOCKED=0` (default), lanes are forced to walk the full 128-point space and latch the **best-score** slip — which may differ from the slip that worked in the morning's slip-only first-match-wins sweep. |
| `idelay_ref_clk` port added on `tidelink_top` | NO | NO | NO directly | The port is declared (line 192) but the controller instance (line 1606+ has the `NOTE 2026-05-20`) does NOT pass it through. It dangles inside. |
| `USE_IDELAY`/`USE_CLKBUF`/`USE_T3A` params on `tidelink_top` | NO | NO | NO | Threaded from FPGA wrapper as `1/1/1`, then ignored at controller instance (`NOTE 2026-05-20` block). Dead parameters. |
| `fpga/rtl/tidelink_idelay_rx.sv` / `tidelink_rxclk_buf.sv` modules | n/a | n/a | NO | NOT instantiated anywhere in the current call tree. `grep -n tidelink_idelay_rx src/rtl/*.sv deps/.../*.sv` = empty. The two new files in `fpga/rtl/` are orphans. |
| Pin map: `pad_tx[7] B19→W9`, `pad_rx[7] F20→V7` | YES (lane 7 physical) | YES (lane 7 only) | **YES** — lane 7 is one of the failing lanes. The remap explanation cites "v4 diag-swap proved B19/F20 physically bad". But on the v4 evidence, B19/F20 followed the **lane**, not the **pin**, in one diag — so the remap conclusion is contested. The new pins W9/V7 share a bank/MRCC tile that may behave differently w.r.t. pad_clk_rx (Y7). |
| Source-sync constraints (`set_input_delay`, `set_max_delay`, `set_bus_skew`, `IOB TRUE`) | YES | YES — bounds pad_rx[0..7]→capture skew to 2 ns | **YES** | Brand-new constraints since morning. They FORCE the placer to equalise all 8 RX capture paths, but the equalisation budget is **only the 8 lanes Vivado finds** — if the I2C pads (P15/P16) or the LANE-7 W9/V7 remap throws an outlier, the bus-skew target may push lanes 0+7 (vector endpoints) to corner placements. |
| `pynq_z2_tidelink_idelay.xdc` | NO | NO | NO | All `get_cells` filters target IDELAYE2/IDELAYCTRL primitives. Both queries return empty (no such cells exist in the current netlist because the FPGA controller doesn't instantiate them). The XDC is a harmless no-op now. |
| `clk_wiz_0 CLKOUT3=200 MHz` | NO | NO | NO directly | Connected to `tidelink_0/idelay_ref_clk` BD pin, which is dead-end inside the IP. Wastes one MMCM output but has no datapath effect. |
| `mask_hs_bypass_i` strap 1→0 | NO | NO | INDIRECT | If autoneg's I2C handshake fails, role_lock never latches → calibrator never triggers → no lanes lock. But fix is "all 8 zero", not "0+7 zero". Doesn't explain deterministic 0x7e pattern. |
| `nego_driving` decouple (`!role_locked` removed) | NO | NO | NO | I2C-side mux change; fires before calibrator. After role_lock the FSM is in DONE/ERROR/BYPASS so `nego_driving=0` regardless. |
| ila_rx/ila_pad removal + ila_i2c addition | NO | NO | NO | Diagnostic only. (BUT: removal of ila_rx forces Vivado to free up the pad_rx[*] route — could in principle affect placement, but in the OPPOSITE direction: fewer probes = MORE freedom = better placement. Not a regression candidate.) |
| `phy_align_regs.sv` sticky-once-locked register | NO (SW-only) | NO | NO (SW probe-only) | The sticky accumulator is the very thing that **proved** lanes 0+7 are sticky-zero. It is itself working correctly — bit [0] and bit [7] of `lane_locked_sync1` never assert at any sample. |
| `Wlink.v` 0x21C `mask_hs_result` sticky | NO | NO | NO | APB-write sniffer for autoneg I2C verdict. Fires AFTER role_lock; before role_lock it is in apb_reset = both zero. |

## 4. Cross-reference with sticky-once-locked evidence

The sticky-once-locked register accumulates `lane_locked_sync1` over time. Lanes 0+7 NEVER assert. This rules out:
- Sampling-window artefacts (sticky catches any transient ≥ 2 apb_clk cycles)
- Calibrator-iterator-phase sampling artefacts
- Read-mux off-by-one on read (`lane_locked_sticky` is read straight)
- CDC artefacts in `phy_align_regs` (2-flop sync, then OR-accumulator)

It DOES NOT rule out:
- Training byte arriving wrong on lanes 0+7 (PHY input — fully consistent with "0+7 endpoints in vector")
- `lane_checker` for lane 0 / lane 7 receiving wrong data
- TX side gating lanes 0+7 off (peer's TX is dead for those bits)
- Reset stuck high on the per-lane checker FSM for lanes 0+7 (extremely unlikely — same RTL clones)
- Vivado placing pad_rx[0]/pad_rx[7] (vector endpoints) at routing corners where the new `set_bus_skew 2.000` cannot meet the skew bound, silently leaving those two paths metastable

## 5. Top 5 candidates ranked by suspect-likelihood

| Rank | Candidate | File:line | One-line experiment |
|--|--|--|--|
| 1 | **`set_bus_skew 2 ns` on pad_rx[*]→capture is too tight; placer drops the two end-of-vector lanes** | `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc:236-237` (constraint [3c]) | Comment out the `set_bus_skew` line, rebuild, see if 0+7 start locking (or which 2 lanes break instead) |
| 2 | **Calibrator best-of-sweep latches a slip the morning's first-match-wins would have rejected** for lanes whose only locking slip is `0` (the first dwell, mis-scored when the score window started cold) | `src/rtl/tidelink_phy_align_calibrator.sv:712-726` (`always_comb` driving `bit_slip`) + `cocotb/.../tb_early_exit_force_q` hook (line ~280) | Set `EARLY_EXIT_ON_ALL_LOCKED=1'b1` (or force `tb_early_exit_force_q=1` at boot via APB-poke). If 0+7 now lock, best-of-sweep is the regression. |
| 3 | **Lane-7 pin remap W9/V7 sits in a clock-region with much longer routing to Y7 (pad_clk_rx) than F20/B19**; the resulting per-lane skew is outside the calibrator's window. Lane 0 (U7) sits at the OTHER vector endpoint and may be sympathetically displaced by the placer when meeting the new `set_bus_skew` constraint together with the W9/V7 outlier. | `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc:86` and `:108` | Revert the lane-7 remap (restore B19/F20) and rebuild — if 0+7 lock again, the remap is the regression. Confounds candidate #1; ideally run with #1 also reverted as a clean control. |
| 4 | **Unconnected `idelay_ref_clk` BD pin causes clk_wiz CLKOUT3 to dangle, MMCM LOCKED widget reports out-of-range and the placer mis-budgets the other two outputs** | `src/rtl/tidelink_top.sv:192` (port declared, never wired) ↔ `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:459-461` (clk_out3 → tidelink_0/idelay_ref_clk) | Remove the CLKOUT3 wire (and the BD-pin) in tidelink_design.tcl. If lock improves, the dangling clock domain was disturbing placement. |
| 5 | **`mask_hs_bypass_i` un-tied 1→0** means autoneg's I2C handshake must succeed first; if it succeeds with `mask_hs_local_match=0` (because lanes 0/7 are masked OUT in the handshake comparator) the link locks "successfully" with those two reported faulted | `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:373-385` (const_mask_bypass = 0) + `deps/.../tidelink_autoneg.sv` mask comparator | Re-tie `mask_hs_bypass_i` HIGH (CONST_VAL 1), rebuild, see if 0+7 reach `lane_locked`. (Note: works only if NEGO_CFG[6] mask_hs_auto_en is also cleared or the I2C jumper present.) |

## 6. Companion-agent boundary

`docs/LANE_0_7_DEEP_DIVE.md` is hypothesis-driven (likely PHY/board-electrical). This document is diff-driven (commits since 8bc6051). The two analyses are intentionally non-overlapping:

- DIFF agent's strongest signal: **constraint changes** (#1) + **calibrator semantic change** (#2) + **pin remap** (#3)
- DEEP-DIVE agent's strongest signal: presumably PHY-internal / board electrical / scope-trace work.

If both converge on candidate #3 (pin remap), that is the regression. If they diverge, candidate #1 is the safest first revert (it is a pure constraint, no RTL).

---

## Appendix — concrete commit references

- `5633c69` calibrator §9.7 — added phase output (NOT wired in submodule)
- `0d85843` calibrator §9.9 — best-of-sweep replaces first-match-wins
- `c86f17b`/`1b9c2d9` — `tb_early_exit_force_q` reset to 0 for sim X-prop
- `50d394f` — sticky-once-locked register (passive diagnostic)
- `cd91971` — drop `USE_IDELAY/USE_CLKBUF/USE_T3A` overrides at controller instance
- `ef20615` — drop `idelay_ref_clk/idelay_rst` port wires at controller instance
- `5d34baf` — lane-7 remap B19/F20 → W9/V7
- `5ad4b0c` — source-sync `set_input_delay` + `set_max_delay` + `set_bus_skew` on RX
- `4ed8704`/`a510bae` — autoneg explicit default state (Bug #3 structural)
- `c515b88`/`467b889` — `nego_driving` decouple from `role_locked`
- `9089b45`/`743821b` — Wlink 0x21C sticky verdict (post-lock)
