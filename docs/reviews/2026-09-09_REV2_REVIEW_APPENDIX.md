> **Appendix to the TideLink Rev-2 Review.** These are the eight full reviewer reports behind `docs/reviews/2026-09-09_REV2_REVIEW.md`, reproduced unabridged.
> Every claim is line-cited at the review point `origin/main` **5e8bdb5a**; lines prefixed `rev2:` cite the candidate `rev2/integration` **cba9774d**. Dated 2026-09-09.
> This text has been **redacted** before landing in git: credentials, board and jump-host IPs, vendor release/drop codes, EDA and PDK install paths and user home
> directories are replaced with placeholders (`<REDACTED-IP>`, `<ARM-CMSDK-DROP>`, `<EDA-INSTALL>`, `<PHYS-IP-PATH>`, `<MEM-COMPILER-PATH>`, `$WORKTREES`).
> Because of that redaction some evidence pointers below are generic — a placeholder stands where a concrete host, credential or absolute path was named.
> The `file:line` citations into this repository are unaffected and remain exact.

# TideLink Rev-2 Review — Appendix: the eight reviewer reports

Review point origin/main 5e8bdb5a; candidate rev2/integration cba9774d; 2026-09-09. Every claim line-cited at 5e8bdb5a unless prefixed rev2:. Read-only; no simulation, synthesis or board command was run.

Contents: 1 Architecture · 2 Transaction-layer RTL · 3 Link/PHY/FCSM/PTP RTL · 4 Verification · 5 Open-defect register · 6 Throughput · 7 Flow/tooling/hygiene · 8 rev2 delta · 9 Findings ledger · 10 Coordinator facts


---

# PART 1 Architecture

# TideLink review — ARCHITECTURE & STRUCTURE (maintainability for new users)

Review tree: `origin/main` `5e8bdb5a` at `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a` (read-only).
rev2 comparison tree: `origin/rev2/integration` `cba9774d` at `$WORKTREES/SoCLabs/td-bisect/rev2-final` (59 commits ahead).
All paths below are relative to the review tree unless prefixed. Every count/line number was produced by grep/diff/wc in this session; nothing is relayed from memory without a check. "Confidence" vocabulary: Verified-in-code / Plausible / Hypothesis.

Summary of the biggest structural facts (each expanded below):
- The shipping design is 5 top-level flists over ~250 source entries; the ASIC and FPGA V2 filesets differ in exactly 8 modules, and the ASIC one compiles the AXI flow-control state machines (`WlinkGenericFCSM`, `_1`..`_4`) from `deps/` with **zero** SoC Labs recovery logic (0 `socl_` lines) while the FPGA one compiles hand-patched copies with 72–73 `socl_` lines each.
- `src/rtl/local_overrides/` (35 files, 38,385 lines) is not an "override" directory; it is the product. `axi_chiplet_controller.sv` alone is a 6,871-line fork of a 1,766-line vendor file (+5,245/-140), and the CDC flow black-boxes it.
- `tidelink_top.sv` is 3,477 lines of which 1,503 are comment-only (43%); a ~620-line ahb_sub backstop block (:1498–2115) with 11 `always_ff` and 20 named state regs sits between the APB fabric and the instance list. rev2 grew it to 3,968 lines (1,840 comment-only) without splitting.
- V1 is not dead: it is the default of `cocotb/tidelink_top_pair/Makefile:37`, `fpga/filelist.tcl` (env `TIDELINK_PHY_V2` default 0), the `cdc/` flow, and `lint/verilator`'s full-design target.
- No single document a new engineer can read in an hour matches the code; 22 concrete doc claims checked below are stale or contradictory, and `CONTRIBUTING.md` does not exist on `origin/main` or rev2.

---

## 1. Module hierarchy of the shipping design

Line counts are `wc -l`. Flist tags: **A2** = `flists/tidelink_top_full_asic_v2.flist` (tapeout default, `syn/asic/fusion-compiler/Makefile:19-20`), **F2** = `flists/tidelink_fpga_v2.flist` (FPGA ship config, `fpga/Makefile:405-410`), **A1** = `tidelink_top_full_asic.flist`, **F1** = `tidelink_fpga.flist`, **T** = `tidelink_top.flist` (47 entries; consumed by `cdc/Makefile:20` and `lint/verilator/Makefile:97`). "LO" = `src/rtl/local_overrides/`, "ACC" = `deps/axi-chiplet-controller/logical/`, "TPHY" = `deps/tidelink-phy/rtl/`.

```
tidelink_dft_wrapper (818)  src/rtl/asic/ — in NO flist; used by syn/asic/dft only
└─ tidelink_top (3477)  [A2 F2 A1 F1 T]                                  src/rtl/tidelink_top.sv
   ├─ u_tx_gen           tidelink_tx_gen (426)            gen TXGEN_PRESENT=1  :1097-1138   [all]
   ├─ u_eye_regs         tidelink_eye_regs (352)          `ifndef TIDELINK_PHY_V2  :1194     [A1 F1 T]
   ├─ u_gpio_phy_apb_regs tidelink_gpio_phy_apb_regs      :1334   TPHY [A2 F2] / deps/tidelink-gpio-phy [T]  (+21/-1 between the two)
   ├─ u_tidelink_fifo    tidelink_fifo (386)              :2121   src/rtl/fifo/           [all]
   │   ├─ tidelink_fifo_mem (350) → tidelink_fifo_ctrl (659), cmsdk_ahb_to_sram (CMSDK),
   │   │                              tidelink_sram  fifo/fpga (112) [F2 F1 T] | fifo/asic (61) [A2 A1] | fifo/generic (59) [tidelink_generic.flist]
   │   ├─ tidelink_apb_regs (851)   — carries Regions 0-8, C, D, F decode (apb_regs.sv:210, :626, :632, :753-783)
   │   └─ tidelink_returner (250)
   ├─ u_fc_adapter       tidelink_fc_adapter (725)        :2241   [all]
   ├─ u_ptp              tidelink_ptp (568)               gen STUB_PTP=0    :2346
   ├─ u_servo            tidelink_ptp_servo (713) → tidelink_mul_iter (93)   gen STUB_SERVO=0  :2450
   ├─ u_phc_cdc          tidelink_phc_cdc (504)           :2528
   ├─ u_perf             tidelink_perf (527)              gen STUB_PERF=0   :2592
   ├─ u_xhb_sub          xhb500_ahb_to_axi_bridge_chiplet_slv   :2663   deps/xhb500/generated (16 files, UNTRACKED — .gitignore:72)
   │                       .hmastlock(1'b0) .hexcl(1'b0) .hmaster(12'd0) at :2678-2681 (see §2.4)
   ├─ u_xhb_mng          xhb500_axi_to_ahb_bridge_chiplet_mst   :2750   deps/xhb500/generated (16 files); .hexcl()/.hmaster() unconnected :2822-2823
   ├─ u_addr_translator  tidelink_addr_translator (212) → tl_addr_trans_regs (209), tl_addr_trans_cam (95)   gen BYPASS_ADDR_XLAT=0  :2844
   ├─ u_link_clk_div     tidelink_link_clk_div (207)      :2995   RATIO_RESET=0 (÷1)
   ├─ u_link_rate_regs   tidelink_link_rate_regs (621)    gen LINK_RATE_REGS_PRESENT=0 → ABSENT by default  :3071
   └─ u_chiplet_controller  axi_chiplet_controller   LO (6871) [all 5 flists]   (ACC/top original 1766 lines — never compiled)
       ├─ u_axinode_obs   tidelink_axinode_obs (171)      ctrl:3057
       ├─ u_winscan_obs   tidelink_winscan_obs (212)      ctrl:3095
       ├─ u_axi2axil      mkaxi2axil_bridge (ACC/bridges) ctrl:3234
       ├─ u_i2c_master    i2c_master_axil  LO (785)       ctrl:3378  → i2c_master  LO (902) [F2 F1] | ACC/i2c (905) [A2 A1]
       ├─ i2c_slave_axil_master (ACC) → i2c_slave (ACC)  ctrl:3440
       ├─ u_axil2apb      mkaxil2apb_bridge (ACC)         ctrl:3500
       ├─ tidelink_autoneg  LO (2418)                     ctrl:3557  (ACC/top original 1907)
       ├─ u_lane_checker  tidelink_lane_checker (TPHY) → _single, tidelink_popcount16   ctrl:4071
       ├─ tidelink_phy_align_calibrator ×2 instances      ctrl:6179, :6280
       │        V2: LO/tidelink_phy_align_calibrator_v2.sv (2575, module decl :262) [A2 F2]
       │        V1: src/rtl/tidelink_phy_align_calibrator.sv (1815, decl :211)     [A1 F1 T]
       ├─ tidelink_idelay_rx (250), tidelink_rxclk_buf (93)   ctrl:6463, :6511  (FPGA-only paths, parameter gated)
       └─ u_wlink   Wlink   LO (2945)  ctrl:6521   (ACC/wlink original 2352)
           ├─ xbar      APBFanout (ACC)
           ├─ axi2wl    AXI4ToWlink (ACC)  → APBFanout_1
           │    ├─ wlink_axiawFC WlinkGenericFCSM      F2: LO (1357)  |  A2: ACC (1159)   ← DIVERGENT
           │    ├─ wlink_axiwFC  WlinkGenericFCSM_1    F2: LO (1332)  |  A2: ACC (1159)   ← DIVERGENT
           │    ├─ wlink_axibFC  WlinkGenericFCSM_2    F2: LO (1337)  |  A2: ACC (1159)   ← DIVERGENT
           │    ├─ wlink_axiarFC WlinkGenericFCSM_3    F2: LO (1332)  |  A2: ACC (1159)   ← DIVERGENT
           │    └─ wlink_axirFC  WlinkGenericFCSM_4    F2: LO (1332)  |  A2: ACC (1159)   ← DIVERGENT
           │         each: l2a_fc_replay WlinkGenericFCReplayV2_{0,2,4,6,8} (ACC)
           │               a2l_fc_replay WlinkGenericFCReplayV2_{1,3,5} LO (both builds; TL-027 self-heal), _{7,9} ACC on main (LO on rev2: e88ff7be)
           │               l2a_fifo_addr_to_tx WlinkGenericFCReplayAddrSync{,_3} (ACC)
           ├─ gb2wl     GeneralBusToWlink (ACC) → WlinkGenericFCSM_5 (ACC, both builds) → ReplayV2_10/_11, AddrSync_15 — tied off (ci/check_strip_generalbus.sh)
           ├─ tl2wl     TideLinkToWlink  LO (274) → wlink_tidelinktl: WlinkGenericFCSM_6  LO (2041, both builds)
           │               → l2a ReplayV2_12 LO (207), a2l ReplayV2_13 LO (303), AddrSync_18  F2: LO (170) | A2: ACC (99)   ← DIVERGENT
           ├─ sp2wl     ShortPacketToWlink LO (199)  — carries the 26-bit ptp_in/ptp_out short-packet port (Wlink.v:168-169)
           ├─ txrouter/rxrouter/txpstate  WlinkTxRouter / WlinkRxRouter / WlinkTxPstateCtrl (ACC)
           ├─ lltx      WlinkTxLinkLayer (ACC);   llrx  WlinkRxLinkLayer LO (2229) → WlinkEccSyndrome LO (319)
           ├─ tidelink_fcemit_obs (165)  — instantiated from LO/Wlink.v (unconditional; v2shims header explains why)
           └─ phy       WlinkGPIOPHY   V2: LO/WlinkGPIOPHY_v2.v (375) [A2 F2] | V1: LO/WlinkGPIOPHY.v (211) [A1 F1]
               └─ WavD2DGpio   V2: LO/WavD2DGpio_v2.v (2290, decl :76) | V1: LO/WavD2DGpio.v (1254)
                   ├─ tidelink_phy_sync_insert, tidelink_phy_tx_segmenter, tidelink_phy_tx_mask  (TPHY) [V2]
                   ├─ gpiotx_0..7  WavD2DGpioTx   V2: TPHY/wav (593) | V1: LO (408)
                   ├─ gpiorx_0..7  WavD2DGpioRx   V2: LO/WavD2DGpioRx_v2.v (1121) | V1: LO (623)
                   ├─ tidelink_phy_rx_demask (TPHY) [V2]
                   ├─ tidelink_lane_deskew  V2: LO/tidelink_lane_deskew_v2.sv (1574, decl :190) | V1: LO/tidelink_lane_deskew.sv (670)
                   └─ tidelink_phy_sync_detect (TPHY) [V2]
   CDC/reset primitives pulled from ACC: WavDemetReset ×41 instances, WavResetSync ×8, WavSyncPulse ×2, WavFIFO*, WavMultibitSync (+ LO/WavMultibitSync_18)
```

Sources in `src/rtl` that are **not** in the shipping hierarchy (grep of instantiation sites across src/rtl, LO, TPHY, ACC/wlink/Wlink.v, ACC/top):
`tidelink.sv` (210; header: "legacy thin wrapper ... back-compat wrapper for tidelink_ahb.sv"), `tidelink_ahb.sv` (188), `tidelink_apb_addr_ctrl.sv` (188), `tidelink_clkfreq_check.sv` (176), `tidelink_addr_translation.sv` (66), `tidelink_fifo_ahb.sv` (289; ARCHITECTURE.md §2 admits it is not the instantiated variant), `LO/wlink_wlink_ptp_tl_a2l_48x4.v` (60; present in 4 flists, no instantiation found), `cmsdk_apb_slave_mux` and `apb4_if` (in 5–7 flists, no instantiation found). `NUM_PHY_LANES` (top:15) is used 4× in tidelink_top and 0× in the controller — the lane count is hard-wired at 8 below the top.

**Finding H-1 — The "override" directory is the design.** 21 of the 46 `src/rtl` entries in A2 (and 35/54 in F2) are `local_overrides/`; every one of the five top flists compiles the 6,871-line `LO/axi_chiplet_controller.sv`, never the deps original. A new user following README.md ("Wlink (in `deps/axi-chiplet-controller/`) … `axi_chiplet_controller.sv`") is pointed at a file that is not built. Severity **High**, Confidence **Verified-in-code**, Effort **M** (rename/relocate + doc).

**Finding H-2 — Two dead selection mechanisms live beside the real one.** `USE_PHY_V2` (top:58) drives an **empty** generate arm (top:2949-2951, "Intentionally empty in S2"); `flists/tidelink_phy_v2.flist` lists `tidelink_gpio_phy_tx/rx.sv` that no build flist includes. The real V2 switch is `+define+TIDELINK_PHY_V2` (48 `ifdef` sites across `tidelink_top.sv`(8), `LO/Wlink.v`(8), `LO/axi_chiplet_controller.sv`(32)) plus a flist file swap. Severity **Medium**, Confidence **Verified-in-code**, Effort **S**.

**Finding H-3 — Exclusive/master-ID information does not cross the die (coordinator fact, verified).** `tidelink_top.sv:2680-2681` ties `.hexcl(1'b0)`, `.hmaster(12'd0)` (and `.hmastlock(1'b0)` :2678) into the outbound XHB500; the inbound bridge leaves `.hexcl()`/`.hmaster()` unconnected (:2822-2823). Comment at :2063 documents `awid = hmaster = 12'd0`. Architecturally this means the transparent bridge is a single-master, non-exclusive path; rev2 commit `45f1ef55` ("cross-die exclusive hazard") tests the consequence. Severity **Medium** (documented limitation, not a bug), Confidence **Verified-in-code**, Effort n/a.

---

## 2. ASIC vs FPGA divergence

### 2.1 Which flist does what
| Flist | Entries | `+define` | SRAM | Wlink FCSM 0-4 | AddrSync_18 | i2c_master | Consumer |
|---|---|---|---|---|---|---|---|
| `tidelink_top_full_asic_v2` (A2) | 190 | `TIDELINK_PHY_V2` in-flist | fifo/asic | **ACC (deps)** | ACC | ACC | `syn/asic/fusion-compiler/Makefile:19-20` default (`ASIC_PHY ?= _v2`) |
| `tidelink_fpga_v2` (F2) | 190 | via `v2shims/*` (3 files) | fifo/fpga + `${CMSDK_FPGA_SRAM_V}` | **LO (patched)** | LO | LO | `fpga/Makefile:409`, 12 cocotb envs, most of `sim_gate` |
| `tidelink_top_full_asic` (A1) | 184 | none (V1) | fifo/asic | ACC | ACC | ACC | `ASIC_PHY=` override only |
| `tidelink_fpga` (F1) | 185 | none (V1) | fifo/fpga | ACC (only `_6` is LO) | ACC | LO | `cocotb/tidelink_top_pair/Makefile:37` default, `fpga/filelist.tcl` default, 10+ cocotb Makefiles |
| `tidelink_top` (T) | 47 | none | fifo/fpga | **no Wlink at all** | — | ACC | `cdc/Makefile:20`, `lint/verilator/Makefile:97` |
| `tidelink_asic` / `tidelink` / `tidelink_generic` | 9/10/9 | — | asic/fpga/generic | — | — | — | FIFO-only partitions (`syn/asic/common.mk:44`) |
| `tidelink_netlist` | 4 | — | — | — | — | — | DC netlist + TSMC65 stdcells (`tidelink.mapped.v`) |

Set difference F2 − A2 (exact, from the cleaned flists): `${CMSDK_FPGA_SRAM_V}`, `fifo/fpga/tidelink_sram.sv`, `LO/WlinkGenericFCReplayAddrSync_18.v`, `LO/WlinkGenericFCSM{,_1,_2,_3,_4}.v`, `LO/i2c_master.v`, `v2shims/{v2_Wlink.v,v2_axi_chiplet_controller.sv,v2_tidelink_top.sv}`. A2 − F2: `ACC/i2c/rtl/i2c_master.v`, `ACC/wlink/WlinkGenericFCReplayAddrSync_18.v`, `ACC/wlink/WlinkGenericFCSM{,_1..4}.v`, `TPHY/tidelink_sync_word.svh`, `fifo/asic/tidelink_sram.sv`, and the un-shimmed `LO/Wlink.v`, `LO/axi_chiplet_controller.sv`, `tidelink_top.sv`. That is **8 divergent modules**: FCSM ×5, AddrSync_18, i2c_master, tidelink_sram — matching the peer inventory (8 modules; their 7,210-line figure is from `$WORKTREES/SoCLabs/td-bisect/asicsim-2026-08-26/`, not re-derived here; my own added+removed count for the same 8 is 1,176 lines, a different metric).

### 2.2 The FCSM divergence, characterised
`socl_` line counts (my grep): deps `WlinkGenericFCSM{,_1,_2,_3,_4,_5,_6}.v` = **0, 0, 0, 0, 0, 0, 0**; LO copies = **73, 72, 72, 72, 72, n/a, 130**. Nothing under `deps/axi-chiplet-controller/logical/` contains `socl_` at all (0 files).
The LO patch on FCSM/_1.._4 (+217/-19, +192/-19 ×4 vs deps) adds: `SOCL_L7_WDOG_THRESHOLD` state-7 NACK watchdog ("Fix D"), TL-033 revert-aware exit (`socl_l7_wdog_force_clear` folded into `_GEN_115`), `SOCL_REACK_THRESHOLD` periodic re-ACK ("Fix E"), `socl_l7_bringup_forgive`, `SOCL_L6/L7_MIN_CR(ACK)_EMITS`, and the `TL033_LEGACY_WDOG` ifdef (10 sites) — all of it as `localparam`s driven by file-local `` `define``s (FCSM_1.v:76, :82) "so the module port list stays byte-identical". `FCSM_6` (the TideLink FC node) has the same family as real `parameter`s (FCSM_6.v: `SOCL_L6_MIN_CR_EMITS`, `SOCL_L7_MIN_CRACK_EMITS`, `SOCL_L7_WDOG_THRESHOLD`, `SOCL_REACK_THRESHOLD`, `SOCL_L9B_*`) plus obs ports — and FCSM_6 is LO in **both** builds.
So: the sideband/TideLink node ships with recovery on ASIC; the five AXI nodes (AW/W/B/AR/R) do not. The memory claim "ASIC sources FCSM 0-5 from deps WITHOUT recovery; FPGA uses local_overrides WITH recovery" is **exactly true** for 0-4; FCSM_5 (GeneralBus) is deps in both and tied off.

**Finding D-1 — The tapeout fileset and the validated fileset differ in the AXI flow-control recovery logic.** Everything HW-validated on KR260/PYNQ (F2) has the Fix-D/E/TL-033 watchdogs in the AXI FCSMs; the tapeout flist (A2) does not, and only `tidelink_top`'s own backstops (§7 L1) remain. The intent may be deliberate (rev2 `a585a2f5` "netlist census — the recovery flops are ABSENT from the AXI FC nodes" confirms the fact), but on main nothing enforces or even lists the divergence; the two flists are independently hand-edited (F2 header text even says "The V1 flist MUST NOT be edited"). Severity **Critical** (process), Confidence **Verified-in-code**, Effort **S** to gate / **M** to resolve. rev2: `scripts/ci/flist_divergence.py` + `test_asic_l7_starvation_backstop.py` (`e6bdb616`), ASIC-fileset cocotb runs (`1d0b56f6`, `e31edbcc`), `TD_ASIC_FILESET=1` FPGA build (`526e0ab8`) — **partially on rev2** (measured and gated, not unified; A2 flist has 0 rev2 commits).

**Finding D-2 — `WlinkGenericFCReplayAddrSync_18` differs too.** LO copy (+74/-3 vs deps) synchronises `w_reset` into `r_clk` ("a2l ACK-ptr reset-skew fix … permanent false-FULL", LO/…AddrSync_18.v header) — FPGA only. Severity **High**, Confidence **Verified-in-code** (diff; effect on ASIC not simulated here), Effort **S**.

### 2.3 Every local_override vs its original (`diff` added/removed lines)
| LO file (lines) | Original (lines) | +/- | Nature (from diff/headers) |
|---|---|---|---|
| axi_chiplet_controller.sv (6871) | ACC/top (1766) | +5245/-140 | obs banks (448 `obs_` refs vs 78; 138 "Region" refs), autoneg glue, 2 calibrator instances, 34 `ifdef` arms (vs 5), 26 ad-hoc 2FF sync decls, `FIX-*`×20, `TL-0xx`×10, 45 dated tags |
| Wlink.v (2945) | ACC/wlink (2352) | +619/-26 | 8 `TIDELINK_PHY_V2` arms, EPOCH param plumbing, fcemit obs, `TD_AUTO_LANE_MASK_E4` lane-mask reset |
| WlinkRxLinkLayer.v (2229) | (1735) | +523/-29 | V2 SYNC re-align, hunt holdoff, obs (per PHY_LINK doc §4.3; not re-derived line by line) |
| WlinkGenericFCSM_6.v (2041) | (1188) | +890/-37 | L6/L7 min-emit gates, F-1 state-7 watchdog, Fix E re-ACK, L9B, obs ports (130 `socl_`) |
| WlinkGenericFCSM.v / _1.._4 | (1159 each) | +217/-19; +192/-19 ×4 | identical recovery patch applied 5× by hand (see 2.2) |
| WlinkGenericFCReplayV2_13.v (303) | (175) | +133/-5 | TL-027 a2l CDC self-heal (continuous resend) |
| ReplayV2_1/_3/_5 (220/220/227) | (175) | +49/-4, +49/-4, +56/-4 | TL-027 for AW/W/B a2l |
| ReplayV2_12.v (207) | (165) | +43/-1 | l2a |
| ReplayAddrSync_18.v (170) | (99) | +74/-3 | reset-skew fix (D-2) |
| WavMultibitSync_18.v (204) | (148) | +66/-10 | not characterised |
| WlinkEccSyndrome.v (319) | (309) | +20/-10 | not characterised |
| TideLinkToWlink.v (274) | (169) | +107/-2 | obs port threading |
| ShortPacketToWlink.v (199) | (185) | +25/-11 | not characterised |
| tidelink_autoneg.sv (2418) | ACC/top (1907) | +810/-299 | not characterised |
| i2c_master_axil.v (785) / i2c_master.v (902) | (772) / (905) | +33/-20 / +8/-11 | not characterised |
| V2 PHY: WavD2DGpio_v2 (2290) / Rx_v2 (1121) / WlinkGPIOPHY_v2 (375) / lane_deskew_v2 (1574) / calibrator_v2 (2575) | TPHY (1961 / 1009 / 333 / 1546 / 2397) | +397/-68, +114/-2, +45/-3, +29/-1, +187/-9 | silicon fixes on top of the submodule (EPOCH_MATCH_THRESH 3→5 at WavD2DGpio_v2.v:939; SYNC_REANCHOR complement at :910) |
| V1 PHY: WavD2DGpio (1254) / Rx (623) / Tx (408) / WlinkGPIOPHY (211) / lane_deskew (670) | deps/tidelink-gpio-phy (1160/609/394/193/236) | +138/-44, +14, +14, +18, +494/-60 | V1 only |

**Finding D-3 — Same module name, two submodules, three trees.** `WavD2DGpio`, `WavD2DGpioRx`, `WlinkGPIOPHY`, `tidelink_lane_deskew`, `tidelink_phy_align_calibrator` each exist as V1 LO, V2 LO (`_v2` filename, same module name), TPHY, tidelink-gpio-phy, and (for the Wav ones) ACC/wlink — 3–5 copies per module, none co-compilable. The docs (§6) cite the TPHY copies as "the" source; the builds compile the LO `_v2` copies. Severity **High**, Confidence **Verified-in-code**, Effort **M**.

### 2.4 Vendoring status
`.gitmodules`: `deps/axi-chiplet-controller` → `https://git.soton.ac.uk/...` (the abandoned GitLab per memory; not re-verified for reachability), pinned `efe5623c` (`heads/feat/l3-autonomy-merge`); `deps/tidelink-gpio-phy` and `deps/tidelink-phy` → the **same** GitHub URL at different SHAs (`6ee8418b`, `8c560c57` on `remotes/origin/fix/calibrator-wrap-stitch`), the latter with `branch = main`. `deps/xhb500/generated` is `.gitignore`d (:72) and produced by `set_env.sh`; 32 A2/F2 entries depend on it (HEAD commit message: "untrack deps/xhb500/generated — it pinned a symlink, not RTL"). Severity **Medium**, Confidence **Verified-in-code**, Effort **S-M**.

---

## 3. V1 / V2 / shim situation — is V1 dead?

**No.** Evidence:
- `cocotb/tidelink_top_pair/Makefile:36-41`: `TIDELINK_PHY_V2 ?= 0` → compiles `tidelink_fpga.flist` (V1) by default.
- `fpga/filelist.tcl` (flist selection block): "Default = the V1 list. TIDELINK_PHY_V2=1 in the environment selects the V2" — the Vivado IP packager defaults to V1; `fpga/Makefile:405-410` regenerates V2 only for the eth-chiplet path.
- `Makefile:1469-1474` `sim_gate_v1elab` rebuilds V1 (`TIDELINK_PHY_V2=0`) as a gate; `Makefile` has 3 `TIDELINK_PHY_V2=0` and 6 `=1` sites.
- 12 cocotb env Makefiles reference `tidelink_fpga.flist` (V1); `cocotb/debug/*`, `tidelink_top_pair_skewed`, `tidelink_link_rate_regs_inert`, `tidelink_force_recal` among them.
- `cdc/Makefile:20` and `lint/verilator/Makefile:97,258` run on `tidelink_top.flist` / `tidelink_fpga.flist` — both V1.
- V1-only sources still shipped: `LO/{WavD2DGpio,WavD2DGpioRx,WavD2DGpioTx,WlinkGPIOPHY}.v`, `LO/tidelink_lane_deskew.sv`, `src/rtl/tidelink_phy_align_calibrator.sv` (1815), `src/rtl/tidelink_eye_regs.sv` (352, `ifndef` arm top:1194), `deps/tidelink-gpio-phy` submodule, `flists/{tidelink_fpga,tidelink_top_full_asic,tidelink_top}.flist`.
- The V2 switch itself is three 3–8-line include shims (`src/rtl/v2shims/`) because "a flist/global define never reaches the packaged-IP OOC synth" (v2shims/v2_Wlink.v:2-3) — for the FPGA IP path only; the ASIC flist carries `+define+` directly (A2 line 1).
- `xprop/` (VC Formal X-prop, README: "NOT FPV … no SVA assertions are exercised") covers 14 unit modules, none of the V2 stack. `v1-release/` is a 2026-05-22 rc2 bundle off `72c280b` (docs only, bitstreams/ASIC manifests) — provenance, not a build input.

**Finding V-1 — V1 is the default in three developer entry points and two sign-off flows.** A new user running `make` in `cocotb/tidelink_top_pair`, packaging the Vivado IP, `make -C cdc cdc`, or `make -C lint lint-fpga-top` gets a PHY that is not the one taped out. Severity **High**, Confidence **Verified-in-code**, Effort **M** (retire V1; ~14 files + 3 flists + 1 submodule + 48 ifdef sites collapse). rev2: `cocotb/tidelink_top_pair/Makefile` and `fpga/filelist.tcl` each have 1 commit (`526e0ab8` adds `TD_ASIC_FILESET`, does not flip the default) — **not on rev2**.

---

## 4. Configuration sprawl

### 4.1 Inventory
Top-level behaviour parameters on `tidelink_top` (`src/rtl/tidelink_top.sv:1-222`, 33 parameters); the controller re-declares 16 of its own (`LO/axi_chiplet_controller.sv:8-138`); the DFT wrapper re-declares them a third time (`src/rtl/asic/tidelink_dft_wrapper.sv:75-203`).

| Knob | tidelink_top default | Also declared / overridden | Notes |
|---|---|---|---|
| `AUTO_ANCHOR_EN` | `1'b0` (:205) | ctrl:99 `1'b0`; KR260 targets set `CONFIG.AUTO_ANCHOR_EN` in `fpga/targets/kr260-pair-*/tidelink_design.tcl`; cocotb `tidelink_top_pair_v2` | **dft_wrapper does not forward it** (not in :569-611) → ASIC DFT netlist gets 0 |
| `NEGO_CFG_RESET` | `7'h00` (:105) = nego_en=0 (zero-poke OFF) | dft_wrapper `7'h61` (:167); INTEGRATION_GUIDE says `7'h61` | **three different "defaults"**; in-repo ASIC synth elaborates bare `tidelink_top` (`syn/asic/common.mk:34-37`) with no parameter overrides (no `set_parameter`/`-parameters` in `syn/asic/scripts/tidelink.FC.read_design.tcl:131` `elaborate $top_module`) → 7'h00 |
| `NEGO_TRAIN_CFG_RESET` | `16'h0001` (:96) | ctrl:44 | |
| `TRAIN_ENTRY_FALLBACK` | `1'b0` (:193) | env `TL_TRAIN_ENTRY_FALLBACK` in `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:435-437`; kr260-pair-nptp | |
| `SELF_ARM_TRAIN_EN` | `1'b0` (:201) | uvm/tidelink_top_system only; `fpga/vivado_ip` | |
| `EPOCH_ANCHOR_EN` | `1'b0` (:48) | `LO/Wlink.v:76`, `LO/WavD2DGpio_v2.v:159`, `LO/WlinkGPIOPHY_v2.v:63` all `1'b0`; env `TL_EPOCH_ANCHOR_EN` (pynq-z2-pair-all:451); `fpga/scripts/check_wrapper_params.sh:109-118` **fails the build if the wrapper default is 1** | `WavD2DGpio_v2.v:910` `.SYNC_REANCHOR_EN(!EPOCH_ANCHOR_EN)` → shipping = SYNC re-anchor ON |
| `USE_IDELAY / USE_CLKBUF / USE_T3A` | `1'b0` (:29-38) | KR260 targets `CONFIG.USE_IDELAY {0}` (kr260-pair-flip-ptp:446); PYNQ mmcmbypass targets set them; `check_wrapper_params.sh:182` asserts wrapper XML =1 | docs claim "FPGA wrapper sets all three =1 via component.xml" — no `component.xml` exists (`fpga/vivado_ip/` has `tidelink_vivado_wrapper.v`) |
| `USE_PHY_V2` | `1'b0` (:58) | lint only | dead (H-2) |
| `HARDEN_SWI_ENABLE` | `1'b1` (:67) | KR260 targets `{0}` (kr260-pair-flip-ptp:447); `docs/R6_HARDEN_SWI_OPTIONS.md` | |
| `HONEST_MASK_HS` / `DEBUG_UNLOCK_DEFAULT` | `1'b1` / `1'b1` (:132/:142) | dft_wrapper `DEBUG_UNLOCK_DEFAULT = 1'b0` (:129) | second default mismatch with the wrapper |
| `RETIRE_EN`, `ENABLE_AHB_WRITE`, `ROLE_FROM_STRAP` | `1'b1` (:169/:177/:188) | `docs/RXFIFO_TWIN2_DISPOSITION.md` says `ENABLE_AHB_WRITE` "tied off in silicon" — RTL default is 1 | |
| `TXGEN_PRESENT` | `1'b1` (:86) | dft_wrapper `1'b0` (:203) | third default mismatch |
| `LINK_RATE_REGS_PRESENT` | `1'b0` (:222) | not forwarded by dft_wrapper | `u_link_rate_regs` absent by default (:3116) |
| `WINSCAN_*`, `STUB_*`, `BYPASS_ADDR_XLAT`, `PHC_LOCK_GATE_EN` | 0/1 per :78-110 | ctrl:106-138 (`WINSCAN_DWELL = 2_500_000`) | |
| `SOCL_L7_WDOG_THRESHOLD_VAL` | `16'h4000` | `` `define `` inside each of FCSM.v:83, _1:82, _2:82, _3:82, _4:82 (guarded by `` `ifndef ``); real `parameter` in FCSM_6 | same knob, two mechanisms, five copies |
| `SOCL_L7_MIN_CRACK_EMITS_VAL` | `8` (`define`, FCSM*.v:76) vs `32` (`parameter`, FCSM_6) | | AXI nodes and TL node use **different** values |
| `TL033_LEGACY_WDOG` | undefined | 10 ifdef sites; cocotb `tidelink_axi_datanode_recovery` | selects old vs new state-7 exit |
| `TIDELINK_SUB_STALL_TIMEOUT_LOG2` / `_OUTSTANDING_` | 16 / 16 (top:1564/:1573) | Makefile, cocotb | |
| `TIDELINK_WR_HOLD_CLR_LEVEL_MUTANT`, `TIDELINK_DISABLE_WR_HOLD`, `TXGEN_FORCE_CREDIT_GATE_DIS` | undefined (top:2000/:2011/:1091) | test mutants compiled into shipping RTL | |
| `TD_AUTO_LANE_MASK_E4` | injected by `fpga/filelist.tcl` (env, default ON → lane mask `0xE4`) | `LO/Wlink.v` | FPGA-only; ASIC gets `0xFF`? (not verified which reset the ASIC gets) |
| `TIDELINK_RXCLK_NO_PRIMITIVE`, `TIDELINK_IDELAY_NO_PRIMITIVE`, `TIDELINK_SRAM_RAND_INIT`, `TIDELINK_SRAM_NO_ZERO_INIT`, `TB_TOP_AUTO_ANCHOR_EN` | sim/lint helpers | | |
| `HAZARD_LIST_SIZE` | **not found** anywhere in the repo under that name | XHB500 hazard depth is an XHB500 generator config (`deps/xhb500/configs/*.cfg`, not inspected) | |

### 4.2 Assessment
**Finding C-1 — There is no single place to see the shipped configuration, and the repo holds three inconsistent default sets.** `tidelink_top` (bare, what `syn/asic` elaborates), `tidelink_dft_wrapper` (what `syn/asic/dft` elaborates: `NEGO_CFG_RESET 7'h61`, `DEBUG_UNLOCK_DEFAULT 0`, `TXGEN_PRESENT 0`, `AUTO_ANCHOR_EN`/`LINK_RATE_REGS_PRESENT` not forwarded), and per-target Vivado tcl (`fpga/targets/*/tidelink_design.tcl`) disagree; the eth-chiplet integration that actually tapes out lives out-of-repo. Defaults are "safe" only in the sense of "inert" (autonomy off, anchors off, rate regs absent) — i.e. the bare default is **not** the validated hardware configuration. Severity **High**, Confidence **Verified-in-code**, Effort **M**. rev2: **not on rev2** (dft_wrapper, controller header, top header untouched: 0/0/2 commits, the 2 being TL-042/044).

**Finding C-2 — Test mutants and legacy arms are compiled into product RTL via `` `ifdef``.** `TIDELINK_WR_HOLD_CLR_LEVEL_MUTANT` (top:2000), `TIDELINK_DISABLE_WR_HOLD` (:2011), `TXGEN_FORCE_CREDIT_GATE_DIS` (:1091), `TL033_LEGACY_WDOG` (×10). A stray `+define+` in any flow silently changes the netlist; nothing in `syn/asic` asserts these are undefined. Severity **Medium**, Confidence **Verified-in-code**, Effort **S**.

---

## 5. Clock / reset domains and CDC

### 5.1 Clocks (from `tidelink_top.sv` ports and instances)
| Clock | Port / origin | Consumers | Domain crossing mechanism |
|---|---|---|---|
| `hclk` | :263 | fifo, fc_adapter, ptp, servo, perf, xhb_sub/mng, tx_gen, eye_regs, link_rate_regs, controller `app_clk`/`apb_clk`, all APB | — |
| `user_ref_clk` | :370 → `u_link_clk_div` (:2995; ratios ÷1/2/4/8/16, `RATIO_RESET=0` = ÷1, `scan_mode` bypass, `link_clk_div.sv:66-73`) → `link_hsclk_w` → controller `user_hsclk` → PHY `io_hsclk` → ÷16 inside PHY = **TX link clock** | Wlink lltx/txrouter/FCSM `io_tx_clk`, a2l replay read side | Wlink `WavDemetReset`(41)/`WavResetSync`(8)/Gray `ReplayAddrSync`(11 instances) |
| `pad_clk_rx` | :395 | per-lane RX capture in `WavD2DGpioRx`; per-lane `~count[3]` = ÷16 lane link clocks; deskew `out_clk` = lane-0 link clock = **RX link domain** (llrx, lane checker, calibrator, RX obs) | `tidelink_lane_deskew` Gray write pointers per lane; FCSM `io_rx_clk`↔`io_tx_clk` via `WavFIFO`/`WavDemetReset` |
| `phc_clk` | :266 | `u_phc_cdc` only (6 paths, ~526 FF, `SYNC_STAGES=2`, `BYPASS_CDC` param; `tidelink_phc_cdc.sv:1-30`) | systematic handshake/toggle syncs |
| `idelay_ref_clk` | :401 | FPGA IDELAYCTRL only | — |
| `scan_clk` | :362 → controller :3393 only; `u_link_clk_div.scan_mode` forces ÷1 | DFT | `cdc/tidelink_top.sgdc:` `set_case_analysis scan_clk 0` |

### 5.2 Resets (bindings grepped per instance)
`hresetn` → fifo, fc_adapter, ptp, servo (`.resetn`), phc_cdc, perf, xhb_sub/mng (`.resetn`), tx_gen, eye_regs, link_rate_regs, controller. `poresetn` → `u_link_clk_div.rst_n` (:3004, deliberately: "This clock feeds the PHY, whose reset is held longer"), controller (`wlink_por_reset = ~poresetn | ~role_locked` per PHY_LINK §5.2, ctrl), link_rate_regs (both). `phc_resetn` → phc_cdc. `role_locked` acts as a reset for the calibrator/eye path (comment at u_eye_regs: "Connect .rst_n(role_locked) directly — NO inverter"). ARCHITECTURE.md §6 and `docs/gate_reports/02_clock_reset_cdc.md` §1.3 both call `role_locked` "a mutual clock enable" — consistent with the RTL.

### 5.3 Is CDC systematic?
- Inside Wlink/PHY: yes-by-vendor (`WavDemetReset`, `WavResetSync`, `WavSyncPulse`, Gray-coded `WlinkGenericFCReplayAddrSync*`, `WavFIFO`) — but 11 of those files are hand-patched LO copies (§2.3), so "pre-verified" no longer holds.
- TideLink-authored: `tidelink_phc_cdc` is a proper reusable bridge; everywhere else is **ad hoc** — named `_meta/_sync/_ff2/_s2` chains: 26 declarations in `LO/axi_chiplet_controller.sv`, 11 `tidelink_phc_cdc.sv`, 10 `tidelink_ptp.sv`, 8 `LO/WavD2DGpio_v2.v`, 8 `LO/tidelink_phy_align_calibrator_v2.sv`, 6 `tidelink_top.sv`, 4 `tidelink_link_clk_div.sv`, 2 `tidelink_link_rate_regs.sv`. There is **no** shared `tidelink_sync2ff`/`cdc_sync` module in `src/rtl` (grep of instantiation names found none).
- `cdc/` tool setup exists (SpyGlass: `cdc/Makefile`, `tidelink_top.prj`, `tidelink_top.sgdc` 147 lines, `axi_chiplet_controller.sgdc`, `xhb500.sgdc`, `waiver.swl` 191 lines) **but**: (a) `cdc/Makefile:20` uses `flists/tidelink_top.flist` — the 47-entry V1 list with no Wlink; (b) `tidelink_top.prj` sets `stop_module {axi_chiplet_controller xhb500_*}` — the 6.9k-line controller with the 26 ad-hoc syncs and all patched Wlink CDC is a black box; (c) `waiver.swl:1-15` waives `Wlink`, `Wav*`, `Wlink*`, `AXI4ToWlink`, `TideLinkToWlink`, `axi_chiplet_controller` as "Chisel-generated / pre-verified internal CDC"; (d) the divided link clock from `u_link_clk_div` is not declared as a generated clock (no `generated`/`link_hsclk` in either sgdc; only a comment at `tidelink_top.sgdc:105` about the recovered RX clock); (e) the sign-off record `docs/reference/SPYGLASS_CDC_SIGNOFF.md:3` is dated **2026-05-28 against `6666c1b`** ("PASS — CONDITIONAL", :50), i.e. before TL-027/032/033/037/042, the AddrSync_18 fix, the wr_hold/backstop block, the link-clock divider and the V2 PHY.

**Finding K-1 — CDC sign-off does not cover the shipping design.** Wrong flist (V1, Wlink-less), black-boxed controller, blanket waivers on forked files, stale date, undeclared generated clock. Severity **Critical** for tapeout confidence, Confidence **Verified-in-code** (setup files; the SpyGlass run itself was not executed here), Effort **S** to re-point + **M** tool time. rev2: `cdc/` has **0** commits — **not on rev2**.

**Finding K-2 — No reusable synchroniser cell for TideLink-authored RTL.** ~75 ad-hoc 2FF declarations across 8 files, each a potential ASYNC_REG/constraint miss. Severity **Medium**, Confidence **Verified-in-code**, Effort **M**.

---

## 6. Docs vs code

Doc set: `docs/` 66 top-level `.md` (19,268 lines) + `docs/reference/` 15 + `gate_reports/` 9 + `handoff/` 3 + `proposals/` 1; `docs_site/` is a **second** 7,460-line set (`architecture.md`, `bringup.md`, `contributing.md`, …). 29 of the 66 are dated `HANDOVER_*/OVERNIGHT_*/*_2026_*` notes although `docs/README.md` ("A note on history") says the dated archive was removed in 2026-07 and "nothing was lost" — it re-accumulated.

### 6.1 Spot-checks (claim → code)
| # | Doc claim | Code | Verdict |
|---|---|---|---|
| 1 | ARCHITECTURE.md §2: "`tidelink_top` instantiates **six** sub-components" | 15 instances (`tidelink_top.sv:1098-3170`) | Stale |
| 2 | ARCHITECTURE.md §6: `link_clk` = `pad_clk_rx ÷ 16`, ~6.25 MHz; no divider | `u_link_clk_div` :2995, port `link_clk_div_ratio_i` :388, `link_rate_regs` :3071 | Stale |
| 3 | ARCHITECTURE.md §6: "two real crossings exist" | 41 `WavDemetReset`, `phc_cdc` 6 paths, ~75 ad-hoc syncs (§5.3) | Misleading |
| 4 | ARCHITECTURE.md §3: "Wlink is held in reset until SW writes `role_lock=1`" | `ROLE_FROM_STRAP=1'b1` (:188), `AUTO_ANCHOR_EN`, `SELF_ARM_TRAIN_EN`, `NEGO_CFG_RESET` autonomy knobs | Partially stale |
| 5 | ARCHITECTURE.md §8: calibrator is `src/rtl/tidelink_phy_align_calibrator.sv`, checker in `deps/tidelink-gpio-phy`, "v1 stack being replaced" | A2/F2 compile `LO/tidelink_phy_align_calibrator_v2.sv` and `deps/tidelink-phy` | Stale |
| 6 | README.md: "PTP FC node (data_id=0xa2, 48-bit) … highest TX prio" vs ARCHITECTURE.md §5: "PTP does not have its own long FC node … `0xa2` not in this config" | `LO/Wlink.v:168-169` only exposes 26-bit `ptp_in/ptp_out` short-packet port; no `8'ha2` | README wrong, ARCHITECTURE right — **contradictory docs** |
| 7 | README.md "Wlink (in `deps/axi-chiplet-controller/`) … `axi_chiplet_controller.sv`" | all 5 flists compile `LO/axi_chiplet_controller.sv` | Stale |
| 8 | README.md links `docs/archive/`, `docs/TIDELINK_SPECIFICATION.md`, `docs/SPECIFICATION.md`, `docs/USER_GUIDE.md`, `docs/SHORTCOMINGS.md`, `docs/PTP_PROTOCOL.md`, `deps/ptp-hardware-clock-ahb/`, `wav-wlink-hw/output_tidelink/` | all MISSING (`ls`); spec/shortcomings/ptp moved to `docs/reference/` | Dead links |
| 9 | README.md "syn/asic (Design Compiler, RTL Architect)", INTEGRATION_GUIDE §2 same; README "GitLab CI 9 stages, 16 jobs" | flow is Fusion Compiler (`syn/asic/fusion-compiler/Makefile`); `.gitlab-ci.yml:46-57` has 11 stages; no `.github/` | Stale |
| 10 | INTEGRATION_GUIDE §1.3: "`.gitmodules` declares only these two submodules … no `branch =` line" | 3 submodules; `tidelink-phy` has `branch = main` | Stale |
| 11 | INTEGRATION_GUIDE §4.3: "`NEGO_CFG_RESET` default `7'h61`"; "parameters declared at `tidelink_top.sv:39–108`"; "`AUTOCAL_ENABLE(1'b1)` (tidelink_top.sv:1845)" | `7'h00` at :105 (`7'h61` only in dft_wrapper:167); params at :1-222; AUTOCAL at :3143 | Contradictory / stale |
| 12 | INTEGRATION_GUIDE §3 flist table (no `_v2` flist; "ASIC synth → `tidelink_asic.flist` / `tidelink_top_full_asic.flist`") | tapeout default is `_v2` (`fusion-compiler/Makefile:19-20`) | Wrong for ship config |
| 13 | INTEGRATION_GUIDE §4.3 / IMPLEMENTATION §1.4: "FPGA wrapper drives `USE_IDELAY=1` … via `component.xml`" | no `component.xml`; KR260 targets set `CONFIG.USE_IDELAY {0}` (`fpga/targets/kr260-pair-flip-ptp/tidelink_design.tcl:446`) | Stale |
| 14 | ARCHITECTURE_PHY_LINK §3.1 cites `deps/tidelink-phy/rtl/wav/WavD2DGpio.v:33`, `tidelink_lane_deskew.sv:168`, `…calibrator.sv:211`, `ReplayV2_13` from deps | builds compile `LO/WavD2DGpio_v2.v` (decl :76), `LO/tidelink_lane_deskew_v2.sv` (:190), `LO/…calibrator_v2.sv` (:262), `LO/…ReplayV2_13.v` | Wrong source-of-truth |
| 15 | ARCHITECTURE_PHY_LINK §3.4/§3.5: deskew instanced with `EPOCH_ANCHOR_EN=1`, `SYNC_REANCHOR_EN=0` (dormant) | `WavD2DGpio_v2.v:910` `.SYNC_REANCHOR_EN(!EPOCH_ANCHOR_EN)`; `EPOCH_ANCHOR_EN` default `1'b0` at top:48, Wlink.v:76, WavD2DGpio_v2.v:159; `check_wrapper_params.sh:109-118` enforces 0 | Contradictory (shipping = SYNC re-anchor ON) |
| 16 | ARCHITECTURE_PHY_LINK line refs `FCSM_6:675/:498/:680`, `fc_adapter.sv:469/:488/:538` | actual `:768/:591/:773`, `:553/:622` | Stale line refs |
| 17 | IMPLEMENTATION §6.2: `PRIME_THRESH=4`, `DEPTH_LOG=4 → DEPTH=16`, `SYNC_WIN=16` vs PHY_LINK `DEPTH_LOG=5, PRIME_THRESH=5` | `WavD2DGpio_v2.v:910` `.DEPTH_LOG(5)`; `lane_deskew_v2.sv:198` default 5 | IMPLEMENTATION wrong; docs disagree |
| 18 | REGISTER_MAP: "decode in `tidelink_top.sv` (lines 660-667)"; "`tidelink_apb_regs.sv:163`", ":492" | `:888-890`; `apb_regs.sv:210`; ID not at :492 | Stale line refs (structure OK) |
| 19 | REGISTER_MAP region table (Regions 0-8, 10, 11, C, D, F) | `apb_regs.sv:210,626,632,753-783`; top:1062 (E), :1313 (11) | Correct |
| 20 | `docs/reference/DEPENDENCIES.md` | 0 mentions of `tidelink-phy`, `tidelink-gpio-phy`, `local_overrides`; upstream = `git.soton.ac.uk` | Stale |
| 21 | ARCHITECTURE_PHY_LINK §1: reference platform "PYNQ-Z2 pair … SW-driven, autoneg-off" | 7 `fpga/targets/kr260-*` exist; KR260 is the current rig (memory, not re-verified on boards) | Stale framing |
| 22 | Memory: "CONTRIBUTING §4, 9 land-readiness rules" | no `CONTRIBUTING.md` at root or `docs/` on `origin/main` or `origin/rev2/integration` (`git ls-tree`); only `docs_site/contributing.md` (246 lines; sections "sim_gate contract", "Commit and gate expectations") | Not in repo |

**Finding X-1 — No one-hour document exists.** `ARCHITECTURE_PHY_LINK.md` (428 lines, as-implemented, component-level) is the closest but is FPGA/PYNQ-framed and points at the wrong source files; `ARCHITECTURE.md` is a mid-2026 snapshot (6 instances, ÷16 clock, SW role lock); neither explains the five top flists, V1/V2 selection, the ASIC/FPGA FCSM split, the backstop layer inside `tidelink_top`, or the parameter matrix. Severity **High**, Confidence **Verified-in-code**, Effort **M**. rev2: 0 commits on README.md, docs/README.md, ARCHITECTURE*.md, IMPLEMENTATION.md, INTEGRATION_GUIDE.md, REGISTER_MAP.md, docs_site/contributing.md — **not on rev2** (rev2 adds `docs/FALSE_GREEN_REGISTER.md`, `MERGE_RECONCILIATION_TODO.md`, `coverage/`, `plans/`).

---

## 7. Maintainability assessment — liabilities and next-iteration targets

**L1. `tidelink_top.sv` is a top, a fabric, a guard layer and a lab notebook in one file.** 3,477 lines; 1,503 comment-only (43%); 26 distinct `2026-xx-xx` tags and 8 commit-SHA references inside RTL comments; `backstop` ×28, `wdog|watchdog|timeout` ×24, `TL-0xx` ×18. The ahb_sub block :1498-2115 (~620 lines, 11 `always_ff`, state regs `sub_stall_ctr_r`, `sub_wr_os_ctr`, `sub_rd_os_r`, `wr_hold_r`, `synth_b_pending`, `xhb_stall_stuck_sticky`, …) is the only ASIC-side recovery (§2.2) and is not a module — it cannot be unit-tested, linted or CDC-checked in isolation, and it interleaves with the APB decode (:876-1035), Region E/11 muxes (:1053-1477) and PHY-V2 `ifdef` arms. rev2 added +505 lines here (TL-042/044) — the trend is the wrong direction.
*Target:* `tidelink_top.sv` ≤ 800 structural lines; new `tidelink_apb_fabric.sv` (decode + 2:1 atomic arbiter + region prdata mux), `tidelink_ahb_sub_guard.sv` (stall timer, outstanding counter, wr_hold, synth-B drain — with its own cocotb env and SVA), `tidelink_phc_glue.sv`; all `TL-0xx` prose moved to `docs/design_notes/TL-0xx.md` and referenced by ID. Verify with Formality LEC (flow exists: `syn/asic/formality/`) + `sim_gate`. Effort **L**, risk **M** (netlist-affecting; LEC must pass).

**L2. `axi_chiplet_controller.sv` — a 6.9k-line fork nobody owns.** +5,245 lines over the vendor file, 448 `obs_` references, 138 "Region" references, 34 `ifdef` arms, 26 ad-hoc syncs, two calibrator instances, 45 dated tags; black-boxed by CDC (§5.3). The deps original (1,766 lines) is never compiled and only misleads.
*Target:* rename to `src/rtl/tidelink_link_ctrl.sv` (owned, not "override"); split out `tidelink_ctrl_obs.sv` (Regions C/8/D/F obs banks — pure read-only sinks), `tidelink_role_block.sv` (role/strap/nego/mask-HS), `tidelink_phy_cal_wrap.sv` (calibrator ×2 + checker + idelay/rxclk), leaving a thin Wlink wrapper. Delete the deps copy from `deps/` usage list (already unused). Effort **L**, risk **M**.

**L3. Six hand-patched FCSM copies + ten Replay/AddrSync copies.** The five AXI-node FCSMs are Chisel monomorphs (deps pairwise ±106 lines, all width/ID differences) that each received the same ~192-line recovery patch by hand (LO pairwise ±45..137). `FCSM_6` diverged (+890). rev2 added two more Replay copies (`_7`, `_9`). Every future fix must be applied 5–7 times and verified per copy (TL-033 and the AR/R nodes were missed once already, per rev2 `e88ff7be`).
*Target A (short):* one `WlinkGenericFCSM_socl.v.j2` template + `scripts/gen_fcsm.py` that emits `_0.._4` (and the Replay `_1/_3/_5/_7/_9`), with a CI check that generated == committed. *Target B (right):* land the SoC Labs fixes in the Chisel source (`deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/` — present in the workspace) and regenerate; LO then shrinks to obs-port threading. Effort **M** (A) / **L** (B), risk **L** (A, byte-identical regen) / **M** (B).

**L4. Two hand-maintained top flists that must agree but don't.** F2 and A2 are 190 lines each, edited independently; the 8-module split (§2.1) is undocumented on main. 34 flists total (37 on rev2), 116 KB Makefile with 80 `sim_gate_*` rules.
*Target:* `flists/tidelink_core.f` (single shared body) + 3-line platform wrappers that only add `tidelink_sram` variant and `+define`; the FCSM/AddrSync/i2c choice made **once**, explicitly, with the rev2 `flist_divergence.py` as a hard gate. Effort **S-M**, risk: any change to A2 is netlist-affecting (re-STA).

**L5. V1 residue (§3).** ~14 V1-only RTL files (≈5.5k lines), 3 V1 flists, 1 duplicate submodule, 48 `ifdef` sites, 3 shims, `USE_PHY_V2` dead scaffold, `tidelink_eye_regs`, `tidelink_top.flist`.
*Target:* delete; make V2 unconditional (strip the `ifndef TIDELINK_PHY_V2` arms, keep `v1-release/` as provenance); re-point `cdc/`, `lint/verilator`, `cocotb/tidelink_top_pair` at F2/A2. Effort **M**, risk **L**.

**L6. Configuration (§4).** *Target:* `tidelink_cfg_pkg.sv` with named profiles (`ASIC_TAPEOUT`, `KR260_PAIR`, `SIM_DEFAULT`) generated from one `config/tidelink_cfg.yaml`; `tidelink_dft_wrapper` forwards every parameter (or is generated); a generated `docs/CONFIG_MATRIX.md`; a synth-time `$error` if any test-mutant define is set. Effort **M**, risk **L-M**.

**L7. Build/verif sprawl.** `Makefile` 1,986 lines / 113 targets / 80 `sim_gate_*` (rev2: 2,467 lines); 67 cocotb dirs vs README's "10 envs"; `docs/` + `docs_site/` duplication.
*Target:* `mk/{sim_gate,fpga,asic,lint}.mk`; `sim_gate` generated from `verif/suites.yaml` (the registry/inventory targets already exist: `sim_gate_inventory`, `sim_gate_registry_coverage`); `docs/history/` for the 29 dated notes with a one-line-per-doc index; `docs_site/` becomes the rendered form of `docs/`, not a parallel text. Effort **M**, risk **L**.

**L8. Vendoring (§2.4).** *Target:* one PHY submodule; ACC pinned to a reachable mirror; the ~94 ACC files actually compiled copied into `src/vendor/wlink/` with `MANIFEST.md` (upstream SHA + patch list per file); `deps/xhb500/generated` either tracked or checksum-gated in `set_env.sh`. Effort **M**, risk **L**.

**L9. Lint/CDC scope (§5.3).** `lint/Makefile:19-55` STANDALONE/CMSDK module lists exclude `tidelink_top`, all LO, all V2; `lint/verilator/Makefile:255-262` full-design lint is "best-effort, not in lint-all" on the V1 flist; CDC on V1 with a black-boxed controller. *Target:* both flows take `FLIST=flists/tidelink_top_full_asic_v2.flist TOP=tidelink_top`; remove `stop_module axi_chiplet_controller`; scope waivers to specific paths; refresh `SPYGLASS_CDC_SIGNOFF.md`. Effort **S** + tool time, risk **L**. rev2: lint ratchet fixes (`74106f77`, `fpga/lint_ratchet.sh`) — partial.

**L10. Dormant RTL (§1).** 6 `src/rtl` modules + 3 flist entries never instantiated. Memory (`project_tidelink_intentional_dormant_rtl`) says these are intentionally kept; *Target:* quarantine into `src/rtl/dormant/` with a README stating why each exists and which env uses it (e.g. `cocotb/tidelink_ahb`), and drop `wlink_wlink_ptp_tl_a2l_48x4.v`, `cmsdk_apb_slave_mux`, `apb4_if` from flists unless something elaborates them. Effort **S**, risk **L**.

---

## 8. Top 10 recommendations (ranked; files listed for parallel assignment; rev2 status verified with `git log origin/main..origin/rev2/integration -- <path>`)

1. **Unify the ASIC and FPGA V2 filesets or make the split explicit and gated** (D-1, D-2, L4). Decide per module (FCSM ×5, AddrSync_18, i2c_master) which source ships, write it in ONE place, and fail CI on drift. Files: `flists/tidelink_top_full_asic_v2.flist`, `flists/tidelink_fpga_v2.flist`, `scripts/ci/flist_divergence.py` (rev2), `Makefile` (`sim_gate_asicelab_v2`). Severity Critical. **Partially on rev2** (divergence checker + ASIC-fileset sims `e6bdb616`/`1d0b56f6`/`e31edbcc`/`526e0ab8`; the A2 flist itself unchanged).
2. **Re-scope CDC and lint to the shipping fileset and remove the controller black box** (K-1, L9). Files: `cdc/Makefile:14-20`, `cdc/tidelink_top.prj`, `cdc/waiver.swl:1-15`, `cdc/tidelink_top.sgdc` (declare the divided link clock), `lint/Makefile:19-55`, `lint/verilator/Makefile:255-262`, `docs/reference/SPYGLASS_CDC_SIGNOFF.md`. Severity Critical. **Not on rev2** (`cdc/` 0 commits).
3. **Replace the hand-patched FCSM/Replay copies with a generator or upstream Chisel fix** (L3). Files: `src/rtl/local_overrides/WlinkGenericFCSM{,_1,_2,_3,_4,_6}.v`, `WlinkGenericFCReplayV2_{1,3,5,7,9,12,13}.v`, `WlinkGenericFCReplayAddrSync_18.v`, `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/*`. Severity High. **Not on rev2** (rev2 adds copies `_7`/`_9`).
4. **Split `tidelink_top.sv`** (L1). Files: `src/rtl/tidelink_top.sv` → `tidelink_apb_fabric.sv`, `tidelink_ahb_sub_guard.sv`, `tidelink_phc_glue.sv`; new `cocotb/tidelink_ahb_sub_guard/`; `syn/asic/formality/` LEC as the gate. Severity High. **Not on rev2** (grew +505 lines, 2 commits `82c56e2a`, `c6f091a1`).
5. **Retire V1, shims and the dead `USE_PHY_V2` scaffold; make V2 the only build** (V-1, H-2, L5). Files: `flists/{tidelink_fpga,tidelink_top_full_asic,tidelink_top}.flist`, `src/rtl/v2shims/*`, `src/rtl/local_overrides/{WavD2DGpio,WavD2DGpioRx,WavD2DGpioTx,WlinkGPIOPHY}.v`, `LO/tidelink_lane_deskew.sv`, `src/rtl/tidelink_phy_align_calibrator.sv`, `src/rtl/tidelink_eye_regs.sv`, `deps/tidelink-gpio-phy` (+ `.gitmodules`), `cocotb/tidelink_top_pair/Makefile:36-41`, `fpga/filelist.tcl` (flist-selection block), `Makefile:1469-1474`, the 48 `TIDELINK_PHY_V2` sites in `tidelink_top.sv`/`LO/Wlink.v`/`LO/axi_chiplet_controller.sv`, `tidelink_top.sv:58,2949-2951`. Severity High. **Not on rev2**.
6. **One configuration source of truth; reconcile the three default sets** (C-1, C-2, L6). Files: `src/rtl/tidelink_top.sv:1-222`, `src/rtl/asic/tidelink_dft_wrapper.sv:75-203,569-611`, `src/rtl/local_overrides/axi_chiplet_controller.sv:8-138`, `fpga/targets/*/tidelink_design.tcl`, `fpga/vivado_ip/tidelink_vivado_wrapper.v`, `fpga/scripts/check_wrapper_params.sh`, new `src/rtl/tidelink_cfg_pkg.sv` + `docs/CONFIG_MATRIX.md`; add `$error` guards for `TIDELINK_*_MUTANT`/`TIDELINK_DISABLE_WR_HOLD`/`TXGEN_FORCE_CREDIT_GATE_DIS`/`TL033_LEGACY_WDOG` in synthesis. Severity High. **Not on rev2**.
7. **Promote and split `axi_chiplet_controller.sv`; add a shared 2FF sync cell** (H-1, K-2, L2). Files: `src/rtl/local_overrides/axi_chiplet_controller.sv`, `cdc/axi_chiplet_controller.sgdc`, new `src/rtl/tidelink_ctrl_obs.sv`, `tidelink_role_block.sv`, `tidelink_sync2ff.sv` (then replace the ~75 ad-hoc chains). Severity High. **Not on rev2** (0 commits).
8. **Rewrite the four entry docs against the shipping design and add a root `CONTRIBUTING.md`** (X-1, table 6.1). Files: `README.md`, `docs/README.md`, `docs/ARCHITECTURE.md`, `docs/ARCHITECTURE_PHY_LINK.md`, `docs/IMPLEMENTATION.md` (§1.4, §6.2), `docs/INTEGRATION_GUIDE.md` (§1.3, §3, §4.3), `docs/REGISTER_MAP.md` (line refs), `docs/reference/DEPENDENCIES.md`, `docs_site/contributing.md` → `CONTRIBUTING.md`; move the 29 dated notes to `docs/history/`. The one-hour doc should contain: the hierarchy tree of §1, the flist table of §2.1, the divergence list, the parameter matrix, and the clock/reset table of §5. Severity High. **Not on rev2** (all 0 commits).
9. **Vendoring hygiene** (D-3, L8). Files: `.gitmodules`, `deps/` (collapse `tidelink-gpio-phy` into `tidelink-phy`), `set_env.sh` (checksum `deps/xhb500/generated`), `.gitignore:72`, `flists/*` (32 xhb500 entries), new `src/vendor/wlink/MANIFEST.md`. Severity Medium. **Not on rev2**.
10. **Build/verif consolidation and dormant-RTL quarantine** (L7, L10). Files: `Makefile` → `mk/*.mk`, `verif/suites.yaml`; `src/rtl/{tidelink,tidelink_ahb,tidelink_apb_addr_ctrl,tidelink_clkfreq_check,tidelink_addr_translation,tidelink_fifo_ahb}.sv` → `src/rtl/dormant/`; drop `LO/wlink_wlink_ptp_tl_a2l_48x4.v`, `cmsdk_apb_slave_mux`, `apb4_if` from `flists/tidelink_{fpga_v2,top_full_asic_v2,fpga,top_full_asic}.flist` after confirming no elaboration needs them; `docs_site/` → generated. Severity Medium. **Not on rev2** (Makefile +481 lines, 20 commits, all additive).

---

## Appendix A — Findings index
| ID | Finding | Severity | Confidence | Effort | rev2 |
|---|---|---|---|---|---|
| D-1 | Tapeout fileset lacks the AXI-FCSM recovery the FPGA-validated fileset has; drift ungated on main | Critical | Verified-in-code | S/M | partial |
| K-1 | CDC sign-off runs on V1 Wlink-less flist, black-boxes the controller, waives forked files, dated 2026-05-28 | Critical | Verified-in-code | S+tool | no |
| H-1 | `local_overrides/` is the product; README points at unbuilt deps copies | High | Verified-in-code | M | no |
| D-2 | `ReplayAddrSync_18` reset-skew fix FPGA-only | High | Verified-in-code | S | no |
| D-3 | 3–5 same-named copies of each PHY module across LO/TPHY/gpio-phy/ACC | High | Verified-in-code | M | no |
| V-1 | V1 is the default of cocotb pair env, Vivado packager, cdc, verilator | High | Verified-in-code | M | no |
| C-1 | Three inconsistent default sets; ASIC synth passes no parameters; dft_wrapper drops `AUTO_ANCHOR_EN`/`LINK_RATE_REGS_PRESENT` | High | Verified-in-code | M | no |
| X-1 | No one-hour doc; 22 stale/contradictory claims; no root CONTRIBUTING.md | High | Verified-in-code | M | no |
| L1 | `tidelink_top.sv` 43% comments, 620-line unmodularised backstop block, growing | High | Verified-in-code | L | no (worse) |
| L3 | FCSM/Replay patch duplicated 5–7× by hand | High | Verified-in-code | M/L | no (worse) |
| H-2 | `USE_PHY_V2` empty generate + `tidelink_phy_v2.flist` never built | Medium | Verified-in-code | S | no |
| H-3 | `hexcl/hmaster/hmastlock` tied to 0 outbound, unconnected inbound (:2678-2681, :2820-2823) | Medium | Verified-in-code | n/a | tested (`45f1ef55`) |
| C-2 | Test-mutant `ifdef`s compiled into product RTL, unguarded in synthesis | Medium | Verified-in-code | S | no |
| K-2 | ~75 ad-hoc 2FF chains, no shared sync cell | Medium | Verified-in-code | M | no |
| L8 | Abandoned-GitLab submodule URL; duplicate PHY submodule; untracked generated XHB500 in 32 flist entries | Medium | Verified-in-code | S-M | no |
| L7 | 116 KB Makefile / 34 flists / 67 cocotb dirs / duplicate docs_site | Medium | Verified-in-code | M | no (worse) |
| L10 | 6 orphan `src/rtl` modules + 3 orphan flist entries | Low | Plausible (instantiation grep over src/LO/TPHY/ACC-top/Wlink.v) | S | no |

## Appendix B — What was not done
- No tool runs (SpyGlass, lint, VCS, Vivado, FC) were executed; all statements about flows come from Makefiles/scripts/records.
- `WavMultibitSync_18`, `WlinkEccSyndrome`, `ShortPacketToWlink`, `tidelink_autoneg`, `i2c_master*` LO diffs were sized but not characterised.
- The peer's 7,210-line divergence metric and the `asicsim-2026-08-26` evidence were not re-derived; my 8-module list was derived independently from the flist set difference and agrees on the module set.
- Board/rig state (KR260 vs PYNQ as "current") is taken from memory and target-directory existence, not from hardware.


---

# PART 2 Transaction-layer RTL

# TideLink transaction-layer RTL review — `tidelink_top.sv`, `tidelink_fc_adapter.sv`, obs blocks, FIFO family, DFT wrapper

Review tree: `origin/main` **`5e8bdb5a`**, read at `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a` (all `file:line` below are at THIS commit unless prefixed `rev2:`).
Cross-check tree: `origin/rev2/integration` **`cba9774d`** at `$WORKTREES/SoCLabs/td-bisect/rev2-final`. `git log origin/main..origin/rev2/integration -- <in-scope files>` returns exactly two RTL commits, both to `tidelink_top.sv` only (`82c56e2a` TL-042 HOL write-age watchdog, `c6f091a1` TL-044 read dead-gate containment; +498/-7). `src/rtl/fifo/*`, `tidelink_fc_adapter.sv`, the two obs blocks and `src/rtl/asic/tidelink_dft_wrapper.sv` are **byte-identical** between main and rev2 (empty diffstat). Every finding is tagged **fixed-on-rev2 / partial / not**.

Method: full read of the in-scope files (7,699 lines) + the XHB500 vendor bridge sources actually compiled by the ASIC flist (`deps/xhb500/.../verilog/*.sv`, cited as `hazard_list.sv`, `core_addr.sv`, `core_resp.sv`, `core_wdata.sv`), + the Region-F decode in `src/rtl/local_overrides/axi_chiplet_controller.sv`. Verilator 4.028 `--lint-only -Wall` on the self-contained modules (fc_adapter, both obs blocks, returner, fifo_ctrl, apb_regs): **zero warnings/errors** (`tidelink_apb_addr_ctrl.sv` needs the `apb4_if` interface and was not lintable standalone). No file in any git tree was modified; no board/ssh/IP-library access.

Severity legend: Critical = silicon wedge / data corruption on a shipping path; High = data loss or protocol violation reachable from ordinary traffic; Medium = latent hazard needing a second condition, or a diagnostic that lies; Low = smell/doc drift. Confidence: **V** = Verified-in-code (line-cited), **P** = Plausible (code + one measured fact from memory), **H** = Hypothesis (needs a directed test). Effort S/M/L.

---

## 0. Executive summary (ordered by what I would fix first)

| # | Finding | Sev | Conf | rev2 |
|---|---|---|---|---|
| F1 | ahb_sub write backstops are AGGREGATE-progress timers ⇒ starved during the XHB500 hazard-list-full wedge; synth-B never arms (silicon 0x21F8 bit[8]=0) | Critical | V | **fixed-on-rev2** (`82c56e2a`, HOL write-age), HW-unvalidated |
| F2 | Cross-die READ with lost R permanently parks XHB500 (`read_counter` only decrements on `r_done`); no synthetic-R path exists; read backstop retires the PS but not the bridge; port then ERRORs every 2^16 hclk | Critical | V | **partial** (`c6f091a1` bounded-error containment; no recovery) |
| F3 | fc_adapter: `tc_axis_tx_tready` is asserted without an arbiter GRANT ⇒ TideChart PKT_EXT words silently dropped whenever TX-aperture/returner/servo wins | High | V | not |
| F4 | fc_adapter: servo word selected into the skid while `servo_fc_ready=0` when a TC remote word is also valid ⇒ duplicate servo packet + dropped TC word | High | V | not |
| F5 | fc_adapter: `rtn_pending_r` clears on `skid_can_accept` with no grant term ⇒ during `sideband_starving` the returner's credit/doorbell word is dropped while the returner sees hready=1 | High | V (mechanism) / P (reach) | not |
| F6 | 0x21F8 bit[10] `xhb_stall_stuck_sticky` is a FALSE-RED: threshold 2^12 hclk, 16× below the design's own 2^16 "wedge" definition; sets on any single ≥4095-hclk `hreadyout_raw` low, i.e. every healthy cross-die read / non-bufferable write on the initiating die | Medium (diag) | V | not (identical at rev2:2169-2171) |
| F7 | 0x21F8 bit[9] `sub_err_sticky` sets on `sub_err1_r` even when the ERROR is masked by `~synth_b_pending` ⇒ reports a fire the master never saw; label "(read)" stale since TL-037 | Medium (diag) | V | not |
| F8 | Synthetic-B drain assumes "the real B was permanently lost"; a LATE real B after the drain lands on an empty hazard list / a later write ⇒ wrong write completed, `sub_wr_os_ctr` under-count | Medium | H | not (rev2 adds a second drain source with the same exposure) |
| F9 | Per-beat backstop threshold is in hclk while a cross-die round-trip is link-clock-bound; margin between "healthy slow read" and 2^16 is ratio-dependent and unmeasured on ASIC hclk | Medium | P | not |
| F10 | RX-FIFO write side has NO packet timeout: a truncated inbound packet leaves `write_packet_active_r=1`, the next header is ignored, one mis-framed packet is committed, pointers/credit drift until FLUSH | Medium | V | not |
| F11 | `wr_hold_r` set/clear coincidence ("clear wins") + address pipe re-latching under a held data phase re-open the Rank-1 data-drop for a PIPELINED master under W backpressure (FPGA Xilinx bridge is non-pipelined ⇒ blind) | Medium | H | not |
| F12 | DFT wrapper straps DIFFERENT defaults from `tidelink_top` (NEGO_CFG_RESET 7'h61 vs 7'h00, DEBUG_UNLOCK_DEFAULT 0 vs 1, TXGEN 0); MBIST done/pass tied 0, TAP bypass, 7 of 8 chains pass-through; `scan_mode = test_mode|scan_en|mbist_en` | Medium | V | not |
| F13 | `role_locked_o` (hclk level) used as ASYNC reset of the link_rx_clk domain with no de-assertion synchroniser | Low/Med | V | not |
| F14 | fcemit_obs pushes an 8-bit counter and two 8-bit IDs through a plain 2-FF sync (no gray/handshake) ⇒ torn APB reads | Low | V | not |
| F15 | Code/doc drift: duplicated `sub_wr_stuck_fire` logic; `ext_stall_err_q` comment says "not APB-mapped" but it is bit[11]; 0x21F8 only wired under `TIDELINK_PHY_V2` | Low | V | not |
| F16 | XHB500 `singles_burst` gated on HPROT[3] (vendor `core_addr.sv:147`, not in tidelink RTL); the multi-beat arm is reachable from the PS bridge but the HPROT tie-down lives in the CHIPLET, not here | Info/Med | V | not (tidelink `.hprot({3'h0,…})` unchanged, rev2:3167) |
| F17 | `TC_ERROR[2]` no-setter claim: CONFIRMED in the external tidechart repo (`tidechart_apb_regs.sv:455` writes bit[3] only); not present in the tidelink tree | Info | V (external) | n/a |

---

## 1. `tidelink_top.sv` region map (3,477 lines)

| Lines | Region | Notes |
|---|---|---|
| 1-258 | Header + parameters | 30 parameters; the tapeout-relevant ones: `NEGO_CFG_RESET=7'h00` (:151), `HONEST_MASK_HS=1'b1` (:173), `DEBUG_UNLOCK_DEFAULT=1'b1` (:184), `RETIRE_EN=1'b1` (:209), `TXGEN_PRESENT=1'b1` (:132), `LINK_RATE_REGS_PRESENT=0` (:257) |
| 259-610 | Ports | `ahb_sub_w_beat_consumed_o` (burst-fix strobe) :281; `scan_*` :360-365 |
| 611-760 | Internal AXI wiring | `ahb_sub_w_beat_consumed_o = s_axi_wvalid & s_axi_wready` :638; B mux wires :640-646 |
| 760-930 | Misc wiring (PTP/servo/perf/returner/FC-RX) | |
| 930-957 | Unified APB decode + response mux | quadrant 11 fall-through :954-957 |
| 958-1035 | TideLink-APB 2:1 arbiter (FC-RX cfg vs PS), `ext_lock_q`, mailbox FC-only gate, **bounded external APB stall** (`EXT_STALL_LIMIT=1024`, `ext_stall_err_q`) | :1009-1027 |
| 1035-1138 | **tx_gen** (Region E 0x21C0) + `TXGEN_CGD_EFF` | generate :1096-1138 |
| 1140-1275 | eye_regs shim (V1) / RAZ (V2) | `ifndef TIDELINK_PHY_V2` :1179 |
| 1275-1403 | gpio_phy APB slave (Region 11, 0x2140 epoch word in V2) | `.link_rx_rst_n(role_locked_o)` :1362 |
| 1404-1496 | `tl_apb_*` prdata/pready/pslverr priority mux + FC/PS response routing | ext_timeout ORed :1494-1495 |
| 1497-1530 | Address-translation pipeline decls, `ext_addr_phase/ext_is_nonseq` | :1527-1528 |
| 1531-1650 | **AHB-sub backstop declarations**: `SUB_STALL_TIMEOUT_LOG2=16`, `SUB_OUTSTANDING_TIMEOUT_LOG2=16`, `sub_rd_os_r`, `sub_wr_os_ctr[2:0]`, `synth_b_pending`, `sub_mst_dphase_r`, `sub_stall_busy`, `sub_ext_stalled`, `sub_axi_outstanding`, `sub_axi_progress` | :1566-1650 |
| 1651-1687 | Address pipeline `always_ff` (latch on `ext_is_nonseq && !pipe_valid_r`; clear on raw; abort on `sub_err1_r & ~synth_b_pending`) | |
| 1688-1843 | **Backstop timers + 2-cycle ERROR sequencer**: per-beat stall (F-1 read-only ERROR :1719, TL-037 terminal timeout :1770-1772), I5 outstanding tracker (:1783-1789), N1 conditional abandon (:1818-1821), SOAK-DRAIN note | |
| 1844-1881 | **0x21F8 leak-witness word** (`xhb_stall_ctr_w`, `sub_wr_os_hwm`, 3 stickies) | :1852-1881 |
| 1882-1899 | XHB500-facing muxes, `xhb_sub_hready` | :1897-1898 |
| 1900-1922 | I2 `rd_pipe_r` one-cycle read mask | |
| 1923-2022 | **Rank-1 / TL-002 `wr_hold_r`**, TL-043 edge-qualified `wr_hold_drain_release` | :1994-2020 |
| 2023-2080 | **F-1/F-2 synth-B** (`sub_wr_stuck_fire` :2040, drain :2042-2054, B mux :2056-2057), **Fix K bid-correction** :2078 | |
| 2081-2089 | `ahb_sub_hreadyout` 6-rank mux, `ahb_sub_hresp` | |
| 2090-2114 | TL-037 `sub_mst_dphase_r` driver | :2109-2113 |
| 2115-2234 | u_tidelink_fifo instance | |
| 2235-2328 | u_fc_adapter instance (txgen mux on the TX aperture) | |
| 2329-2440 | PTP (real/stub) | `initial $error` combination guard :2339-2343 |
| 2441-2522 | Servo (real/stub) | |
| 2523-2574 | PHC CDC | |
| 2575-2658 | Perf (real/stub) | |
| 2659-2757 | **u_xhb_sub** (AHB→AXI): `.hprot({3'h0,xhb_sub_hprot})` :2676, `.hexcl(1'b0)` :2680, `.hmaster(12'd0)` :2681, `clk_qreqn/pwr_qreqn = 1'b1` :2745/2749 | |
| 2758-2835 | u_xhb_mng (AXI→AHB) | Q-channel ties :2764/2768 |
| 2836-2880 | Address translator (real/bypass) | |
| 2881-2929 | Tier-2 `swi_enable` hardening + swreset block on 0x208 | :2916-2929 |
| 2930-2958 | `g_phy_v2` empty scaffold | |
| 2959-3010 | Link-clock divider (poresetn) | |
| 3011-3110 | Link-rate regs generate (OFF by default) | |
| 3111-3475 | **u_chiplet_controller** instance; `.xhb_sub_obs_word_i(xhb_sub_obs_word)` ONLY under `ifdef TIDELINK_PHY_V2` :3459; `link_active = role_locked_o` :3476 | |

`always_ff` blocks: 13; `always_comb`/`always @*`: 0 in this file; no latches; all resets `negedge hresetn` async-low (poresetn only on the divider). 7 `mark_debug` attributes remain.

---

## 2. Known-open hazard verification at `5e8bdb5a`

### 2.1 F1 — XHB500 hazard-list saturation wedge: backstops STARVED (Critical, V, fixed-on-rev2)

**Vendor facts (verified in the ASIC-compiled copy):**
- `hazard_list.sv:46` `localparam HAZARD_LIST_SIZE = 4;` `:136` `full = list_pointer >= 3'd4 ? ~remove : 1'b0`.
- Page-granular: `:48` stores `[31:12]`, `:60` low 12 bits explicitly `unused`, `:84` match on `chk_addr[31:12]`. A read in another 4 KiB page is NOT hazarded behind posted writes ⇒ reads keep completing while writes are stuck.
- Entry only for bufferable writes: `core_addr.sv:233-236` `hazard_add = … & hwrite & hprot[2] & ~hprot[6] & ~hazard_full …`; only bufferable writes are paused by a full list: `core_addr.sv:151-158` `pause_addr_submit = … | (hwrite & hprot[2] & ~hprot[6] & (hazard_full | …))`.
- Entry freed only on a bid match: `hazard_list.sv:62` `remove = b_done & b_ewr`, `:86/:138` `b_ewr = |match_bid_i`. `awid = hmaster = 0` (`core_addr.sv:250`; `tidelink_top.sv:2681`), so Fix K (`:2078`) makes the match unconditional.

**Wrapper structure (verified):**
- `sub_wr_os_ctr` counts AW-accepts and decrements on ANY `sub_b_done` (`:1785-1789`), saturating at 7.
- Timer (1), per-beat: `sub_stall_busy = !xhb_sub_hreadyout_raw` (`:1617`); `sub_ext_stalled` (`:1623-1624`); `if (!sub_ext_stalled) sub_stall_ctr_r <= '0` (`:1707-1708`) ⇒ ANY raw-high pulse (a read to another page completing, an idle cycle) re-zeroes it.
- Timer (2), outstanding: `sub_axi_progress = sub_r_done | sub_b_done` (`:1648`, no transaction identity); `if (!sub_axi_outstanding || sub_axi_progress) sub_osr_ctr_r <= '0` (`:1791-1792`) ⇒ any read completion re-zeroes the age of a write that is going nowhere.
- Only write escape: `sub_wr_stuck_fire = (sub_osr_expired | sub_stall_expired) & (sub_wr_os_ctr != 0)` (`:2040-2041`) → `synth_b_pending` (`:2048`). The two ERROR fire sites are read-only or need `sub_wr_os_ctr==0` (`:1719`, `:1770-1772`, `:1818`) — structurally inapplicable at ctr=4.
- Witness: `sub_wr_stuck_sticky` is set-only (`:1862` reset, `:1870` set; no other assignment — `grep -n sub_wr_stuck_sticky` returns exactly those + the pack at `:1878`), so the silicon read `0xB5000498` (bit[8]=0, ctr=hwm=4, hprot[2]=1) proves the expiry never happened since reset.

**What an "age the oldest" fix needs** (and how rev2 meets it):
1. Transaction identity for the head-of-line write. Because `awid≡0` and AXI orders responses per ID, "oldest outstanding" ≡ "next B to arrive"; a pair of wrapping sequence counters (issue on `sub_aw_accept`, retire on `sub_b_done`, retire never overtakes issue) is sufficient — no per-ID timestamps needed. rev2: `sub_wr_hol_seq_issue_r/retire_r` (rev2 diff).
2. The age re-zeroes ONLY on that write's own retirement or write-idle — never on `r_done`, never on a raw-high pulse. rev2: `if (!sub_wr_hol_valid || sub_b_done) age <= 0`.
3. Bounded drain snapshotting the issue pointer at fire so writes accepted later are never given a synthetic B. rev2: `sub_wr_hol_drain_tgt_r <= sub_wr_hol_seq_issue_r`.
4. Must not touch `synth_b_pending`/`wr_hold_*` (the 08-13 TL-042 candidate failed on hardware exactly there). rev2: dedicated `sub_wr_hol_b_pending`, ORed into `s_axi_bvalid/bresp/bid` only.
5. Threshold above the aggregate timers so it never pre-empts them: rev2 uses 2^17.
6. Obs: rev2 adds bit[12] `sub_wr_hol_stuck_sticky`.
**Residual on rev2 (not a defect, a note):** the HOL drain does NOT feed `wr_hold_drain_release` (`wr_hold_clr` still has exactly the two terms at rev2). If the HOL watchdog (not synth-B) is what retires a write whose W beat never handshakes, `wr_hold_r` stays set. Reachable only if the osr timer is starved AND W is wedged AND the link is otherwise alive (contradictory in practice, since starvation implies live completions); flag for the rev2 test plan.
**How to prove:** cocotb on `tidelink_top` with the XHB500 model: post 4 EWR writes whose B is withheld, interleave cross-page reads that complete every <2^16 hclk; baseline: `synth_b_pending` never rises, `0x21F8[8]=0`; rev2: `sub_wr_hol_stuck_sticky` rises at 2^17 and `ahb_sub_hreadyout_raw` returns high. (rev2 commit text says the no-traffic control was measured; the starved case with interleaved reads is the one that matters.)

### 2.2 F2 — Cross-die READ path: lost R parks the bridge forever; no synthetic R (Critical, V, partial-on-rev2)

The cross-die read is reachable from every AHB-matrix initiator (memory: `hsel_peer` has no `hwrite` term). At this commit:
- `core_resp.sv:115-123`: `read_counter` loads on `arvalid&arready`, decrements ONLY on `r_done`. `:233` `ready_for_read = (read_counter==0 | (r_done & read_counter==1))`. `core_addr.sv:151-154`: every later READ is paused on `~ready_for_read`; the RESP FSM sits in `SEQ_NSEQ` with `hreadyout=0` (`core_resp.sv:180-189`). `read_broken`/`ignore_read_data` (`:125-147`) only discard LATE data; they never decrement the counter.
- `grep -n "assign s_axi_r" tidelink_top.sv` → **no hits**; `s_axi_rvalid/rdata/rlast` are wired straight from the controller (`:3380-3385`). There is no synthetic-R mechanism analogous to synth-B.
- The read backstop (`:1719` per-beat, `:1818-1821` outstanding) drives a legal 2-cycle ERROR to the PS and clears `sub_rd_os_r`, and the pipe is aborted (`:1677-1682`), but XHB500 is left in `SEQ_NSEQ` with `read_counter=1`. Every subsequent transfer (read OR write — `hreadyout=0` because `~address_readyout`) stalls 2^16 hclk and is then retired by TL-037 (`:1770-1772`) with an ERROR. The port is dead until POR, at 2.6 ms/ERROR (25 MHz).
- Secondary read-path defects: F6 (bit[10] false-red), F9 (hclk-vs-link-clock threshold), and I2 `rd_pipe_r` (`:1913-1921`) masks only ONE cycle — correct for the IDLE-state leak it targets, but the comment's premise ("Writes never set this") means the SEQ beats of a burst read are unmasked; XHB500 handles those itself, so no defect.
**rev2 (`c6f091a1`)**: a dead-gate detector arms on `sub_err1_r` with no bridge progress (`dg_bridge_alive = raw | any s_axi handshake`), declares `xhb_dead_r` after 2^12, then answers every master transfer with an IMMEDIATE 2-cycle ERROR, frees an idle bus, debounces recovery on 2^12 raw-high, and latches permanently after 2 relapses (obs bits [13]/[14]). This converts "2^16-cycle hang per access" into "bounded ERROR per access" — **containment, not recovery**; the bridge is still parked and nothing re-arms `read_counter`. A real fix needs either (a) a synthetic `rvalid&rlast` (with `rresp=SLVERR`) after the read-age expiry, mirroring synth-B — safe because XHB500 is single-outstanding for reads (`ready_for_read`), or (b) an XHB500 soft-reset of the sub face (its `resetn` is `hresetn`, shared — not available without vendor change).
**How to prove:** cocotb: issue a cross-die read, withhold R; expect backstop ERROR at 2^16; then issue a WRITE to a different page — baseline: stalls 2^16 then ERROR (port dead); with a synthetic-R fix: completes.

### 2.3 TL-042 `wr_hold_r` deadlock at this commit
- No fix on main: `grep -n "wr_hold_stuck\|TL-042" tidelink_top.sv` → only two comment mentions (`:1762`, `:2981`).
- `synth_b_pending` is **no longer a term** of `wr_hold_clr`: `:2008-2009` `wr_hold_clr = (wvalid&wready&wlast) | wr_hold_drain_release` where `wr_hold_drain_release = synth_b_pending & s_axi_bready & (sub_wr_os_ctr <= 1)` (`:1999`) — a one-cycle pulse on the drain's last B (TL-043, present). The pre-fix LEVEL survives only under `ifdef TIDELINK_WR_HOLD_CLR_LEVEL_MUTANT` (`:2003-2006`).
- F-1 read-only ERROR path still read-only: per-beat `if (sub_rd_os_r) sub_err1_r <= 1` (`:1719`); outstanding `if (sub_rd_os_r && ctr==0 && !synth_b_pending)` (`:1818`). The only write-path exit remains synth-B.
- Structural TL-042 residual at this commit: `wr_hold_r` is invisible to the per-beat timer (`sub_ext_stalled` has no `wr_hold_r` term, `:1623`), so a hold that outlives W backpressure while `raw=1` (EWR accepted, W wedged) is bounded only by the osr timer + drain — which F1 shows can be starved. rev2's HOL watchdog bounds the osr-starved case but, per the residual noted in 2.1, does not release `wr_hold_r` itself. **partial**.

### 2.4 Hazard-1/TL-043, Hazard-3/N2, N1, N3, burst-fix strobe — presence and interaction
| Fix | Present at 5e8bdb5a | Evidence |
|---|---|---|
| TL-043 edge-qualified `wr_hold_clr` | yes | `:1999`, `:2008-2009` |
| N1 conditional read abandon | yes | `:1818-1821` `if (sub_rd_os_r && (sub_wr_os_ctr == 3'd0) && !synth_b_pending)` |
| TL-037 terminal timeout + `sub_mst_dphase_r` | yes | `:1770-1772`, `:2109-2113` |
| F-1/F-2 synth-B + Fix K | yes | `:2040-2054`, `:2078` |
| I2 `rd_pipe_r` | yes | `:1913-1921` |
| Burst-fix W-consumption strobe | yes | `:638` `ahb_sub_w_beat_consumed_o = s_axi_wvalid & s_axi_wready` (per beat, no `wlast`) |
| N3 (fifo_ctrl pointer gate) | yes | `fifo_ctrl.sv:227` `read_would_overmint`, `:255` `if (read_complete && !read_would_overmint)` |
| Hazard-3/N2 (auto-anchor) | N/A here | lives in the controller/PHY (`AUTO_ANCHOR_EN` forwarded `:3133`); default 0 in this file |
| HPROT[2] tie-down | **not in this tree** | `:2676` passes `xhb_sub_hprot` through unchanged; the tie is in `nanosoc_eth_chiplet.sv` |

Interactions: (a) The burst-fix guard the memory describes ("arms on hprot[2]=1") is on the CHIPLET side; in this file the strobe is unconditional. Forcing `hprot[2]=0` at the chiplet makes XHB500 never allocate a hazard entry (`core_addr.sv:233-236`) ⇒ `sub_wr_os_ctr` still counts AW/B (it is not hprot-gated) but never exceeds 1, so F1's starvation is unreachable there; it also makes Fix K (`:2078`) a no-op — consistent with the memory's coupling note. (b) N1's deferral depends on `s_axi_bready` liveness; the Q-channel term is transparent because both `qreqn` are tied 1 (`:2745/2749`, `:2764/2768`). (c) TL-037's `& ~synth_b_pending` guard and N1's guard make the read ERROR always land after a drain — correct, and F7 below shows the obs word misreports the masked attempt.

### 2.5 Peer facts requested by the coordinator
- `.hexcl(1'b0)` **`:2680`** (rev2:3171) and `.hmaster(12'd0)` **`:2681`** (rev2:3172) on `u_xhb_sub`; `.hexcl()`/`.hmaster()` left open on `u_xhb_mng` (`:2822-2823`). Confirmed: exclusives cannot cross; single-master identity ⇒ all hazard entries id 0.
- `singles_burst <= ~hprot[3] || hexcl || hburst == BUR_INCR` is **not** in `axi_chiplet_controller.sv` or `tidelink_top.sv`; it is the vendor bridge `deps/xhb500/.../xhb500_ahb_to_axi_bridge_chiplet_slv_core_addr.sv:147` (identical copy at `imp/fpga/tidelink_ip/src/…core_addr.sv:147`), captured on `hsel && hready && htrans==NONSEQ` (`:146`). With `hexcl=0` tied, a fixed-length burst (INCR4/8/16, WRAP) with `hprot[3]=1` (cacheable) takes the multi-beat AXI arm; anything with `hprot[3]=0` becomes AXI singles. The "two AXI bursts, first all-zero" behaviour is a claim about the vendor multi-beat arm that I could not verify inside XHB500 in this review — I confirm only the gating line and that the arm is reachable on the KR260 path (silicon `pipe_hprot_r[2]=1` shows the PS bridge drives non-zero HPROT) and unreachable behind the chiplet tie `{2'b00,hprot[1:0]}` (hprot[3]=0 ⇒ singles). rev2 changes neither the tidelink `.hprot` wiring nor the vendor file; its new `cocotb/xhb500_bridge` suite (20 tests) has no `hprot[3]`/`singles_burst` case (grep empty). **not**.

---

## 3. New findings — `tidelink_fc_adapter.sv` arbiter (F3, F4, F5)

The TX arbiter feeds a 1-entry skid. Grant logic (`:537-547`):
```
ext_grant      = ext_wants && !sideband_starving && (ext_boosted || !tx_fc_valid);          // :537-539
sideband_grant = (rtn_fc_valid || servo_fc_valid || ext_grant) && !sideband_starving;       // :541
arb_valid      = tx_fc_valid | rtn_fc_valid | servo_fc_valid | ext_wants;                   // :542
arb_data       = (sideband_grant && rtn_fc_valid) ? rtn_fc_word :
                 (sideband_grant && servo_fc_valid) ? servo_fc_data :
                 ext_grant ? tc_axis_tx_tdata : tx_fc_word;                                 // :543-546
skid loads on (arb_valid && skid_can_accept)                                                // :558
```
Each SOURCE must advance only when it was the one loaded. Checks:
- TX aperture: completes on `tx_data_phase_r && skid_can_accept && !sideband_grant` (`:325`) — correct (it is the fallthrough of `arb_data` iff no sideband grant; `ext_grant` is folded into `sideband_grant`).
- Servo: `servo_fc_ready = skid_can_accept & ~rtn_fc_valid & ~tc_tx_is_remote & ~sideband_starving` (`:576`).
- TideChart: `tc_axis_tx_tready = tc_tx_is_puf ? (puf_state_r==PUF_IDLE) : (skid_can_accept & ~sideband_starving)` (`:506-507`).
- Returner: `rtn_hready = rtn_pending_r ? skid_can_accept : 1'b1` (`:418`); `rtn_pending_r` clears on `rtn_pending_r && skid_can_accept` (`:404-410`) — no grant term.

**F3 (High, V, S, rev2: not) — TC word dropped without grant.** With `tc_qos_priority=0`, `tc_tx_is_remote=1`, `tx_fc_valid=1`: `ext_grant=0` (not boosted, TX has data) ⇒ `sideband_grant=0` ⇒ `arb_data=tx_fc_word`, skid loads the TX word; but `tc_axis_tx_tready = skid_can_accept & ~starving = 1` ⇒ the TC master retires its beat. **One TC word lost per such cycle.** Same when `rtn_fc_valid` or `servo_fc_valid` is high (grant goes to them, `tready` still 1). Fix: `tc_axis_tx_tready = tc_tx_is_puf ? … : (ext_grant & skid_can_accept)`. Prove: cocotb `tidelink_fc_adapter`: hold a TX-aperture write in its data phase, present `tc_axis_tx_tvalid` with qos=0; count FC words on `tl_fc_a2l_*` vs beats acknowledged on `tc_axis_tx_tready` (existing suite drives `tc_axis_tx_tvalid` only in isolation — `test_tidelink_fc_adapter.py:1133/1547/1573/1601`).

**F4 (High, V, S, rev2: not) — servo/TC collision: servo duplicated, TC dropped.** `servo_fc_valid=1`, `tc_tx_is_remote=1`, `tx_fc_valid=0`, `rtn=0`: `ext_grant=1` ⇒ `sideband_grant=1` ⇒ `arb_data` picks the SERVO (second ternary, `:544`) — but `servo_fc_ready=0` (`~tc_tx_is_remote`, `:576`) so the servo holds `valid` and its word is loaded AGAIN next cycle (duplicate timestamp packet), while `tc_axis_tx_tready=1` acknowledges a TC beat that was never loaded (dropped). Fix: make `arb_data` and the ready signals derive from ONE one-hot grant vector (`grant_rtn > grant_servo > grant_ext > grant_tx`) and set each source's ready = its grant & `skid_can_accept`. Prove: drive `servo_fc_valid` and `tc_axis_tx_tvalid` together for N cycles; expect N servo + N tc words on `tl_fc_a2l_data`; today you get 2N servo-ish and 0..N tc.

**F5 (High mechanism V / reachability P, S, rev2: not) — returner word dropped under `sideband_starving`.** `sideband_starving = (burst_r >= 4) && tx_fc_valid` (`:437-438`). In that cycle `sideband_grant=0`, `arb_data=tx_fc_word`, the skid loads TX; but `rtn_pending_r` clears (`:408`) and `rtn_hready=1` (`:418`) ⇒ the returner completes its data phase believing the credit-return/doorbell went out. **Credit return lost ⇒ peer starvation** (exactly the class the 2026-06-12 credit-leak fix in `apb_regs.sv:604-614` was built to prevent). Reachability: needs 4 consecutive sideband grants with a TX word waiting; the returner alone cannot (it idles ≥2 cycles between writes, `returner.sv:182-203`, and a TX grant zeroes the counter `:462`), but a TideChart PKT_EXT stream of ≥4 words can, and `servo` + `tc` + `rtn` mixes can. Also the burst counter is not zeroed on the starving cycle (`:456-460`: the `if (rtn||servo||tc)` branch is taken), so starvation persists for the whole TX word. Fix: clear `rtn_pending_r` on `(sideband_grant && rtn_fc_valid && skid_can_accept)` and drive `rtn_hready` from the same term. Prove: TC stream of 5 words + TX data phase pending + returner interrupt on the 5th cycle; assert the SIDEBAND word with `rtn_addr_latched_r` appears on the FC.

Skid buffer itself (`:553-566`): `skid_can_accept = ~valid | ready`; load wins over drain; a load in the same cycle the FC drains is legal (valid&ready consumed the old word). **Cannot drop or duplicate on its own** — the defects are all upstream in grant/ready consistency. Bug-A TX_STALL_TIMEOUT path (`:313-340`, 2^16) is correct: the abandoned beat is explicitly ERRORed and `tx_dropped_cnt_r` increments (`:349-354`).

Credit corner cases: `fe_tx_credit_max` re-zero (memory, settled) lives in the Wlink FC node, not this file. The adapter has no credit state; `txgen` credit gating is in `apb_regs.sv:352-451` (pipelined net-delta, saturate-at-zero — correct; the one-cycle delay argument at `:373-386` holds because `tx_gen` reserves `len+2` up front).

RX path (`:582-716`): `rx_accept` only in IDLE with no pending (`:626`); FIFO words complete in ADDR_PHASE (2 cy/word); SIDEBAND drives APB setup→access. Two style notes: (i) the FSM waits on `pready` during the SETUP phase (`:664-666`) — non-APB but harmless with `apb_regs` `pready=1'b1` (`apb_regs.sv:774`) and the top-level grant gate (`tidelink_top.sv:1483`); (ii) `always @(*)` at `:715` — fully assigned, no latch.

---

## 4. Diagnostics that cannot report what they exist to report (F6, F7, F15) + sticky-bit table

### F6 — 0x21F8 bit[10] `xhb_stall_stuck_sticky` (Medium, V, S, rev2: not)
Set condition (`:1865-1867`): `xhb_stall_ctr_w` counts every hclk that `xhb_sub_hreadyout_raw==0`, zeroes on raw high, saturates at `12'hFFF`; `if (xhb_stall_ctr_w == 12'hFFF) xhb_stall_stuck_sticky <= 1'b1`. Reset-only clear (`:1860`). So it latches on the FIRST single stall of ≥4095 consecutive hclk, from any cause.
Why it fires on die_a in clean baselines: (1) XHB500 holds `hreadyout` low for the ENTIRE data phase of a cross-die READ (`core_resp.sv:180-189`, `hreadyout = beat_done`) and of any non-bufferable write (until B). A cross-die round trip crosses two FC nodes, the serialiser at `hsclk/16`, the peer's XHB500 AXI→AHB, its target, and back; the peer-measured ~460 µs (memory 08-25) is ≈11,500 hclk at the 25 MHz rig — nearly 3× the threshold — and die_a is the die that issues the sysval readbacks. (2) Any access issued before the link is up (PS probing the peer window during bring-up) stalls until `role_locked`, far longer than 4095 cycles. (3) The threshold is 2^12 while every other backstop in the same block defines "wedge" as 2^16 (`:1566/:1580`): the witness is inconsistent with its own siblings by construction, so it cannot discriminate "hazard-list full" from "read in flight". Its comment (`:1849`) calls it a "hazard-list-full / deadlock witness" — a false-red diagnostic.
Fix direction: make it a genuine hazard-full witness: `sticky |= (sub_wr_os_ctr >= 3'd4) & ~xhb_sub_hreadyout_raw` (both already exported; hwm bits [7:5] already show the same), or raise the threshold to `SUB_STALL_TIMEOUT_LOG2` and AND with `sub_wr_os_ctr != 0`. Keep a separate "max raw-low run length" counter if the latency observation is wanted.
Prove: on a healthy pair read 0x21F8 before and after ONE cross-die read — bit[10] flips 0→1 with bits [8:1]=0. Negative control: the same after a cross-die write with `hprot[2]=1` on an idle link stays 0.

### F7 — 0x21F8 bit[9] `sub_err_sticky` (Medium, V, S, rev2: not)
`if (sub_err1_r) sub_err_sticky <= 1'b1` (`:1871`). But the master-facing ERROR is masked by `& ~synth_b_pending` (`:2081-2082`, `:2089`). The per-beat path fires `sub_err1_r` on `sub_rd_os_r` REGARDLESS of `sub_wr_os_ctr` (`:1719`) while the same expiry sets `synth_b_pending` (`:2040-2048`) ⇒ `sub_err1_r=1` with the ERROR masked; bit[9] reads "2-cycle ERROR backstop fired" when nothing reached the master (N1's deferred, visible ERROR comes a window later). Also the label "(read)" (`:1848`) is stale: since TL-037 (`:1770-1772`) `sub_err1_r` also fires for write-side terminal timeouts. Fix: latch on `sub_err1_r & ~synth_b_pending` and add a second bit for TL-037. Prove: coincident stuck read + stuck write (N1 vehicle); bit[9] sets at the FIRST expiry while `ahb_sub_hresp` shows no ERROR.

### Sticky / error bit table (APB obs space owned by the in-scope files)
"Set" and "Clear" are grep-verified assignment sites; "Can it lie?" is the must-fail-control judgement.

| Register/bit | Signal | Set | Clear | Verdict |
|---|---|---|---|---|
| 0x21F8[8] | `sub_wr_stuck_sticky` | `:1870` (inline copy of `sub_wr_stuck_fire`) | POR `:1862` only | Honest but DUPLICATED logic (`:1870` vs `:2040`); if one is edited the witness silently diverges from the mechanism |
| 0x21F8[9] | `sub_err_sticky` | `:1871` | POR | **Lies** (F7): sets on masked ERRORs; label stale |
| 0x21F8[10] | `xhb_stall_stuck_sticky` | `:1867` | POR | **Lies** (F6): false-red on any ≥4095-hclk stall |
| 0x21F8[11] | `ext_stall_err_q` | `:1025` | POR | Honest; comment `:976` says "not APB-mapped" — it is (`:1875`) |
| 0x21F8[7:5] | `sub_wr_os_hwm` | `:1868` | POR | Honest |
| 0x21F8[4] | `pipe_hprot_r[2]` | live | – | Live sample of the LAST latched address only |
| 0x21F8 whole | `xhb_sub_obs_word` | – | – | Only reaches the APB under `TIDELINK_PHY_V2` (`:3459`, controller `:3143-3145`); V1 builds read 0x00000000 at 0x21F8 with no 0xB5 marker (undecoded-address trap) |
| 0x21E0[19:10] | axinode `wedge_sticky_q` | `axinode_obs.sv:126-127` | POR | Honest; 4096-cycle unchanged-stall vector — same false-red exposure as F6 for a healthy cross-die read that keeps `tgt_ar`/`tgt_r` stalled >4096 cycles? No: the vector is `valid&!ready`; a read in flight has no valid held against a low ready unless the R node backpressures — OK |
| 0x21E0[21:20] | `tgt_err_q`/`ini_err_q` | `:130-135` | POR | Honest |
| 0x21E0[23] | `data_healthy` | derived | – | Honest |
| 0x21EC[6:0],[14:8],[17] | fcemit `sop_seen/grant_seen/out_adv_ever` | `fcemit_obs.sv:97-99` | `tx_resetn` | Honest (false-green impossible: set-only from live pulses) |
| 0x21F0[23:16] | `ch6_grant_cnt_q` | `:101` | `tx_resetn` | Honest but torn across CDC (F14) |
| STATUS 0x010[1] | fifo `overrun_r` | `fifo_ctrl.sv:614` | flush/POR | Honest |
| STATUS[2] | `underrun_r` | `:615` | flush/POR | Honest |
| STATUS[3] | returner `master_error_r` | `returner.sv:221` (after 3 retries) | flush/POR | Honest |
| STATUS[5] | `ahb_inject_fault_r` | `fifo_ctrl.sv:634` | flush/POR | Honest |
| CTRL 0x01C[2] | `ctrl_lock_r` | `apb_regs.sv:221` | POR only | write-once by design |
| tx aperture | `tx_dropped_cnt_r` | `fc_adapter.sv:352` | POR | Honest; **not APB-mapped anywhere** (grep: no consumer) — observability only via ILA |

Out of my file scope but in the same APB space: the controller's Region 9/C/D stickies (`axi_chiplet_controller.sv`, ~6.7k lines) were not audited bit-by-bit; the Region-F mux at `:1166-1172` and the slot decode `:3130-3146` were.

**F17 — `TC_ERROR[2]` (external).** Not in the tidelink tree (`grep -rn "TC_ERROR\|error_reg_r" --include=*.sv .` → nothing). Verified read-only in `$WORKTREES/SoCLabs/tidechart` (HEAD `b5102b2`): `src/rtl/tidechart_apb_regs.sv:240` decl, `:370` reset, `:455` `error_reg_r[3] <= 1'b1` (the ONLY set), `:477` W1C, `:570` read. Bits [2:0] have no setter — confirmed.

---

## 5. Latent hazards (F8–F11)

**F8 (Medium, H, M, rev2: not) — late real B after a synthetic drain.** `:2032-2037` asserts "The real B was permanently lost, so there is no collision." A B delayed beyond 2^16 hclk (peer AHB slave stalling, retry loops) is not lost. After the drain (`synth_b_pending` cleared at ctr≤1, `:2053`) a real B arrives: XHB500 `b_done` with `list_pointer` possibly 0 ⇒ `b_ewr=0` ⇒ treated as the B of the CURRENT non-EWR write if one is in flight (`core_wdata.sv:305`, `core_resp.sv:105-108`) — that write completes with the stale response; and `sub_wr_os_ctr` decrements for a write that was not this one (`:1787`) ⇒ the I5 tracker under-counts and a genuinely lost B for the new write can never time out. rev2's HOL drain shares the exposure. Mitigation: after a drain, hold a "drain debt" counter and swallow that many real Bs (`s_axi_bready` to the controller asserted, `bvalid` to XHB500 masked). Prove: cocotb — withhold B for 2^16+16 cycles then release it; issue a fresh non-EWR write in the gap; check its B/`hresp`.

**F9 (Medium, P, S, rev2: not) — hclk-denominated timeouts vs link-clock-bound latency.** All four thresholds (`:1566/:1580`, fc_adapter `TX_STALL_TIMEOUT_LOG2=16`, `WEDGE_LOG2=12`) count hclk, but a cross-die round trip scales with `user_ref_clk/16` and lane count. At 25 MHz hclk the measured ~460 µs read ≈ 11.5k cycles (5.7× margin below 2^16). If the ASIC hclk is faster than the rig while the link UI is unchanged, the margin shrinks proportionally; there is no assertion or documented budget. Prove: `grep SUB_STALL` gives no ratio check; add an elaboration-time `$error` if `2**SUB_STALL_TIMEOUT_LOG2 < K * (hclk/link_word_rate)` once the ASIC clock plan is fixed, and measure max raw-low run on silicon (a "max run" counter — see F6 fix).

**F10 (Medium, V, M, rev2: not) — RX FIFO write side has no packet timeout.** `fc_write_addr0 = fc_wr_valid && fc_wr_write && (fc_wr_addr=='0) && !write_packet_active_r` (`fifo_ctrl.sv:303-304`); `write_complete` requires the exact beat at `write_target_addr_r` (`:170`). A truncated inbound packet (peer TX aborted by its TX_STALL_TIMEOUT — a designed behaviour, `fc_adapter.sv:313-340`; or a link drop mid-packet) leaves `write_packet_active_r=1` indefinitely; the next packet's header at offset 0 is NOT captured, its words overwrite the truncated region, and its beat at the OLD target fires `write_complete` with the OLD length ⇒ one mis-framed packet committed, `write_ptr` advanced by the old delta, remaining words scattered at `new_ptr+offset`, credit under-consumed. Self-resyncs after that packet but the corruption is silent (no sticky bit: `overrun/underrun` don't fire). N3/`read_would_overmint` protect the READ side only. Fix: a write-side inactivity watchdog that abandons the packet (clear `write_packet_active_r`, leave pointers) and raises a sticky; or require the peer TX abort to emit a SIDEBAND "abort" word. Prove: cocotb `tidelink_fifo`: FC-write a header for len=4, write 2 words, then start a new packet header; observe the committed length and `packet_committed_irq`.

**F11 (Medium, H, M, rev2: not) — Rank-1 hold under a pipelined master.** Two structural gaps: (a) `:2019-2020` "clear wins if set+clr coincide" — a write whose address latches (`wr_hold_set`, `:1995`) on the same cycle the previous write's W-last handshakes gets NO hold ⇒ for that write the data-phase protection is absent and the original data-drop is back if ITS W beat is back-pressured. (b) The address pipe latches the NEXT address on `ext_is_nonseq && !pipe_valid_r` (`:1662`) with no `!wr_hold_r`/`!rd_pipe_r` term, and `xhb_sub_hready` follows `raw` (`:1897-1898`), so while `wr_hold_r` extends the master's data phase for write A, write B's address can be presented to XHB500; whether XHB500 then samples B's `hwdata` before the master has moved to B's data phase depends on `core_wdata.sv` back-pressuring its address path while the W regslice is full (`:133`, `:191`, `:251` `stall_writes`), which I could not fully establish. The Xilinx `axi_ahblite_bridge` is non-pipelined (idles between transactions — `fc_adapter.sv:174-181` comment), so KR260 is blind; CM0/DMA-250 on the chiplet matrix are pipelined. The chiplet-side per-beat capture keyed on `ahb_sub_w_beat_consumed_o` (`:638`) may cover this in the eth-chiplet integration; it does not cover a bare `tidelink_top` integration. Prove: cocotb pipelined-AHB BFM (next NONSEQ during current data phase), `s_axi_wready` forced low for 3 cycles during write A, check write B's payload on the peer.

---

## 6. General correctness sweep

- **Reset polarity**: uniformly `always_ff @(posedge hclk or negedge hresetn)` (13 in top, 9 fc_adapter, 11 apb_regs, 7 fifo_ctrl, 5 returner, 2+2 obs). `u_link_clk_div` on `poresetn` (`:2998`) by design. **F13**: `u_gpio_phy_apb_regs.link_rx_rst_n(role_locked_o)` (`:1362`) — an hclk-domain level used as the async reset of the recovered-clock domain; assertion is safe, DE-assertion has no synchroniser, so the first link_rx_clk edges after `role_locked` rises can capture metastable reset release. INTEGRATION_GUIDE says "connect directly"; that is a vendor guidance, not a proof. (Low/Med, V, S.)
- **Multi-driven/latch**: none found. `always @(*)` at `fc_adapter.sv:715` and `apb_addr_ctrl.sv:161` assign every output on every path. Plain `always @(posedge…)` at `fifo_mem.sv:172/229`, `apb_addr_ctrl.sv:96/123` — style only.
- **AHB sub port protocol**: `ext_addr_phase = hsel & htrans[1]` (`:1527`) correctly ignores IDLE/BUSY; SEQ beats bypass the pipe; BUSY passes to XHB500 unchanged. The 2-cycle ERROR (`:2081-2089`) is cy1 `HREADYOUT=0/HRESP=1`, cy2 `HREADYOUT=1/HRESP=1` — legal. `sub_mst_dphase_r` clears on `ahb_sub_hreadyout` (`:2112`), and because every hold rank keeps hreadyout low across the whole data phase, there is no early clear. One nit: the fill stall (`:2083`) inserts a wait state while the PREVIOUS transfer may be IDLE — AHB says IDLE transfers get zero wait states; every real master tolerates it, but a strict checker would flag it.
- **AXI handshakes**: `s_axi_bvalid = ctrl | synth_b_pending` (`:2056`) — `synth_b_pending` is a register that stays high until `bready` (`:2053`) ⇒ valid never drops before ready (legal). `bid/bresp` change only with valid (`:2057/:2078`). The controller's `bvalid_ctrl` is consumed by `bready` while `synth_b_pending` is also high — one `b_done` for two responders (F8 discussion; benign during the drain, harmful after).
- **Counters**: all saturating or self-resetting; `sub_stall_ctr_r/sub_osr_ctr_r` are `[LOG2:0]` and reset on the MSB (`:1709/:1794`); `tx_stall_ctr_r` same; `sub_wr_os_ctr` saturates at 7 (>4 EWR + 1 non-EWR max). `sideband_burst_r` saturates at 4 and is not cleared on the starving cycle (F5).
- **Widths**: `SB_CNT_W'(…)` casts present; `perf_region_idx[1:0]` explicit (`apb_regs.sv:600-601`); `(SUB_*_LOG2+1)'(1'b1)` sized increments. No unintended truncation found.
- **X-propagation**: XHB500 `RESP_FSM_undef` drives `hreadyout=1'bx` (`core_resp.sv:218`) — vendor default arm, unreachable from reset. `xhb_sub_obs_word_i` floats in V1 (`:3459`) but is not read there.
- **CDC**: only two crossings in scope — axinode (`app_clk`→`apb_clk`, both = hclk today, `:3059`) and fcemit (`tx_link_clk`→`apb_clk`). fcemit passes a 7-bit sticky (monotonic, OK), an 8-bit saturating counter and two 8-bit last-ID registers through 2-FF (`fcemit_obs.sv:113-135`) — **F14**: torn multi-bit reads (Low, V, S; debug-only).
- **Timeouts unreachable?** `EXT_STALL_LIMIT=1024` (`:1009`) vs `apb_regs` `pready=1` — reachable only via a stuck shim slave; fine. TL-037's branch is unreachable while `sub_wr_os_ctr!=0` — by design (F1 shows that this is the wedge case).
- **Dead code / TODO**: no TODO/FIXME in the RTL except `dft_wrapper.sv:547` "CLOSURE TODO: instantiate jtag_tap_top". Dormant-by-design: `g_phy_v2` empty arm (`:2953-2955`), `TXGEN_CREDIT_GATE_DIS`, `TIDELINK_*_MUTANT` ifdefs (`:2003`, `:2012`) — never in shipping flists (grep of `flists/*.flist` shows only `RANDOMIZE_*` and `TIDELINK_PHY_V2` defines).
- **Verilator**: clean on all lintable in-scope modules (see header).

---

## 7. FIFO family (`src/rtl/fifo/*`, byte-identical on rev2)

**Structure.** `tidelink_fifo.sv` = `u_fifo_mem` (SRAM + `cmsdk_ahb_to_sram` + `u_fifo_ctrl`) + `u_apb_regs` + `u_returner`; single clock `hclk`, no CDC inside the family (the only "pointer/CDC" question is the SRAM race, below). `tidelink_fifo_ahb.sv` and `tidelink_ahb.sv` are thin `cmsdk_ahb_to_apb` wrappers (REGISTER_RDATA=1, WDATA=0) — no logic, no findings.

**TWIN-2 / phantom-pop closure — structurally closed for the READ side, with one residual on the WRITE side (F10):**
- Phantom pop (read of an EMPTY FIFO armed a length latch): `fifo_ctrl.sv:417-418` `… && ~hwrite && !rx_fifo_empty` gates `check_addr_nxt`; `rx_fifo_empty` (`:156`) is the same predicate `underrun_event` uses (`:604-605`). A read of an empty FIFO is now a NO-OP plus the sticky `underrun`. Closed.
- TWIN-2 (stray AHB write walks the FC-shared `write_ptr`): AHB write side gated by `ahb_write_en = ENABLE_AHB_WRITE && swi_ahb_inject_arm` (`:181`; POR-disarmed at `apb_regs.sv:186-208`), `ahb_pkt_start_ok` requires `!write_packet_active_r && credit>=2` (`:310-312`), completion gated (`:186`), and a disarmed attempt raises `ahb_inject_fault` (`:631-637`). Closed.
- TWIN-3 (shared read/write trackers): fully split registers (`:123-131`), independent `if`s in pointer update (`:249-257`), credit composed write-then-read (`:200-227`, `:520-560`). Closed.
- N3 (read pointer advancing on a phantom `read_complete`): `read_would_overmint` (`:227`) gates the pointer (`:255`) and the credit clamp (`:557-560`). Closed.
- Residual (F10): FC write-vs-write self-collision is acknowledged as unguarded (`:297-302` comment) and there is no write-side inactivity timeout — a truncated packet mis-frames exactly one successor packet with no sticky.
- `packet_committed_irq` clears on ANY read of offset 0 (`:572-575`), including an empty-FIFO read that is otherwise a NO-OP — cosmetic.

**SRAM read/FC-write race fix (`fifo_mem.sv:95-202`)** — the vendor SRAM registers its address unconditionally; the fix captures the read's address (`read_addr_pending_r`) and re-presents it (`:337-340`) while stalling `hreadyout` (`:161-162`, `:328`) until two clean cycles. `read_active_r` clears one cycle after `hold_for_sram_race` drops (`:191-199`) — correct for a single-outstanding AHB read; a pipelined back-to-back read (SEQ) re-enters via `ahb_read_addr_phase` (`:170`) only when `ahb_hready_gated` is high, which the stall keeps low — consistent. `sram_cs` forced during recovery (`:223`) — extra reads, power only. `puf_can_read` excluded during recovery (`:208`) — correct.

**Returner (`tidelink_returner.sv`)** — pending set wins over clear (`:131-140`) so a trigger on the service cycle is not lost; 3 retries then sticky `master_error` (`:205-224`); the only sink is `u_fc_adapter` whose `rtn_hresp=0` always (`fc_adapter.sv:419`) so `master_error` is unreachable in `tidelink_top` — a diagnostic that cannot fire on this integration (Low/Info). Note F5: the returner CAN lose a word without ever seeing an error.

**apb_regs** — `pslverr` on RO writes and WO reads (`:776-826`); Region-F/D/C RO writes flagged; `ptp_reg_write` decode (`:505-509`), servo addr arithmetic `3'h5 + paddr[4:2]` / `paddr[4:2]-3'h3` (`:513`) wraps at 3 bits but is only consumed for the decoded regions — OK. `ctrl_flush_r` self-clearing and `swi_ahb_inject_arm_r` survives FLUSH (`:203-206`) — intended. Released/doorbell accumulators saturate at 0xFFFF (`:264-269`, `:285-290`). No findings beyond style.

---

## 8. DFT wrapper (`src/rtl/asic/tidelink_dft_wrapper.sv`, 818 lines, byte-identical on rev2) — F12

- **Which top does the ASIC flow use?** `syn/asic/common.mk:34-35` `TOP_tidelink_top(_full) = tidelink_top`; only `syn/asic/dft/Makefile:20-22` sets `DESIGN := tidelink_dft_wrapper`. So Fusion-Compiler synthesis/CTS run on `tidelink_top`; the wrapper is the DFT-insertion top only. The `sim_gate` `dft_wrapper_elab` PASSes (`imp/sim_gate/dft_wrapper_elab.status`, VCS elab, TXGEN absent).
- **Parameter divergence (Medium, V, S):** wrapper defaults `NEGO_CFG_RESET = 7'h61` (`:167`) vs top `7'h00` (`tidelink_top.sv:151`); `DEBUG_UNLOCK_DEFAULT = 1'b0` (`:129`) vs top `1'b1` (`:184`); `TXGEN_PRESENT = 1'b0` (`:203`) vs top `1'b1`; `HONEST_MASK_HS=1` both. Consequence: a netlist produced through the wrapper boots into autonomous bring-up with debug-unlock from the strap; one produced from `tidelink_top` (the FC flow) boots SW-driven with debug permanently unlocked. Two ASIC "tops" with different POR behaviour is a tapeout-config trap; pick one owner (the chiplet instantiation at `nanosoc_eth_chiplet.sv` is the real top per the memory) and make the wrapper forward, not redefine.
- **Stubs that report nothing:** `mbist_done=0`, `mbist_pass=0` (`:521-522`) — MBIST can never report PASS (fails "fine-ward" only in the sense of never passing; fine as a placeholder but must not survive to signoff); TAP arm `tap_tdo = tap_tdi` bypass (`:549`); scan chains 1..7 `scan_out[gi] = scan_in[gi]` (`:496-503`), chain 0 = the controller's legacy chain (`:476-477`, `:505`). All are pre-stitch placeholders, flagged by the wrapper's own `$display` (`:489`).
- **`scan_mode` derivation:** `any_test_mode = test_mode | scan_en | mbist_en` (`:566`) → `.scan_mode` (`:686`), `.scan_shift(scan_en)` (`:689`). Inside `tidelink_top`, `scan_mode` fans to the controller (`:3391`), `phc_cdc` (`:2536`), `link_clk_div` (`:3006`, forces `/1`) and, inside the vendor PHY, to the clock muxes. So during MBIST (`mbist_en=1`) every functional clock mux flips to `scan_clk` and the divider bypasses — MBIST would run the memories off `scan_clk` with the link domain switched. Probably acceptable for a memory BIST, but it is an unreviewed consequence of ORing the three modes (Low/Med, V).
- **The `scan_clk` 67.6 % CTS-sink problem is NOT the wrapper's clock muxing.** The wrapper only wires `scan_clk` through (`:688`). The muxes are in the vendor PHY/Wlink RTL: `local_overrides/WavD2DGpio_v2.v` (56 `scan_clk` refs), `Wlink.v` (5), `WlinkGPIOPHY_v2.v` (4), `WavD2DGpioRx_v2.v` (6), `axi_chiplet_controller.sv` (2). `syn/asic/fusion-compiler/scripts/1_init_design.tcl:243-254` documents the measurement (14,747/21,962 sinks on `scan_clk` with no case analysis, 0 with `scan_mode=0`) and `:276-386` applies `set_case_analysis 0` on `scan_mode/scan_shift/scan_asyncrst_ctrl` in both scenarios plus the ÷16 generated clocks — so the flow fix is in place at this commit; the open question is whether the `constraints.sdc:168 read_sdc` abort (memory) prevents it from taking effect. That belongs to the ASIC-flow reviewer.
- `INCLUDE_TAP` generate and `SCAN_CHAINS=8` are elaboration-safe (`:537-551`).

---

## 9. What should be re-developed / split out of `tidelink_top.sv`

The 3,477-line file has five independent concerns and two years of fix-on-fix layering in the ahb_sub path; nine named fixes (I2, Rank-1/TL-002, TL-043, F-1/F-2, Fix K, I5, SOAK-DRAIN, N1, TL-037; rev2 adds TL-042-HOL and TL-044) interact through six shared registers. Proposed split, in dependency order, with the 5e8bdb5a line ranges so tasks can be parallelised:

| New module | Extract from (lines) | Interface (in→out) | Notes / order |
|---|---|---|---|
| `tidelink_ahb_sub_pipe` | 1497-1530, 1651-1687, 1882-1922 | `ahb_sub_*`, `translated_sub_haddr` → `xhb_sub_*`, `pipe_valid_r`, `ext_is_nonseq`, `rd_pipe_r` | Pure address pipeline + I2 mask. Do first; its invariant ("no comb path from `ahb_sub_hready`") gets its own SVA. |
| `tidelink_write_hold` | 1923-2022 | `ext_is_nonseq`, `hwrite`, `pipe_valid_r`, `s_axi_w*`, `drain_release` → `wr_hold_r` | Rank-1 + TL-043. Add the F11 `!wr_hold_r` pipe interlock decision here. |
| `tidelink_sub_backstop` | 1531-1650, 1688-1843, 2023-2114 | `s_axi_*` handshakes, `xhb_sub_hreadyout_raw`, `ext_is_nonseq`, `pipe_valid_r` → `sub_err1/2_r`, `synth_b_*`, `s_axi_b*` overrides, `sub_mst_dphase_r`, `pipe_abort` | The whole timer/ERROR/synth-B/N1/TL-037 stack (+ rev2 HOL/TL-044). Replace the two aggregate timers with per-direction age timers (F1) and add synthetic-R (F2). Highest value, highest risk — needs the existing `axi_datanode_recovery/_gaps`, N1, TL-037 cocotb suites moved with it. |
| `tidelink_sub_hready_mux` (or fold into backstop) | 2081-2089 | rank inputs → `ahb_sub_hreadyout/hresp` | The 6-rank priority mux is the single most-argued-about expression in the repo; make it a table with one SVA per rank. |
| `tidelink_xhb_obs` | 1844-1881 | timers/ctr/stickies → `xhb_sub_obs_word` | Fix F6/F7/F15 while moving; derive `sub_wr_stuck_sticky` from the real `sub_wr_stuck_fire`. |
| `tidelink_apb_fabric` | 930-957, 958-1035, 1140-1275, 1275-1403, 1404-1496 | `apb_*`, `fc_cfg_apb_*`, shim responses → `tl_apb_*`, `apb_prdata/pready/pslverr` | Unified decode + 2:1 arbiter + bounded ext stall + the eye/gpio_phy/txgen priority mux (with its V1/V2 ifdef pair). Zero datapath risk, large readability win. |
| `tidelink_swi_harden` | 2881-2929 | `apb_*` → `apb_pwdata_to_chip` | Trivial; keeps the 0x208 policy reviewable on its own. |
| `tidelink_ptp_servo_wrap` | 2329-2574 | ports as today | PTP/servo/PHC-CDC + stub generates. |
| leave in top | 611-760, 2115-2328, 2575-2880, 2930-3110, 3111-3477 | – | Instances and wiring only after the split (~900 lines). |

Companion refactors outside `tidelink_top.sv`: (1) `tidelink_fc_adapter.sv` TX arbiter (`:420-576`) → one-hot grant vector with per-source ready derived from it (fixes F3/F4/F5 in one change) + a `tx_dropped_cnt` APB slot; (2) `tidelink_fifo_ctrl.sv` write-side packet watchdog (F10); (3) `tidelink_fcemit_obs.sv` counter/ID CDC → gray or capture-on-request (F14).

---

## 10. Proof recipes (one line each; all cocotb unless stated)

| # | How to prove |
|---|---|
| F1 | 4 EWR writes with B withheld + cross-page reads every <2^16 hclk; baseline `synth_b_pending` never rises, 0x21F8[8]=0; rev2 `[12]` rises at 2^17 and raw returns high |
| F2 | read with R withheld → ERROR at 2^16; then a write to another page: baseline stalls 2^16 then ERRORs (dead port); rev2 immediate ERROR; fix = completes |
| F3 | TX-aperture data phase held + `tc_axis_tx_tvalid`, qos=0: count FC words vs `tready` acks (today: acks > words) |
| F4 | `servo_fc_valid` and `tc_axis_tx_tvalid` together N cycles: expect N+N words; today duplicate servo, missing tc |
| F5 | TC stream ≥5 words + TX data phase pending + returner interrupt on cycle 5: SIDEBAND word with `rtn_addr_latched_r` must appear |
| F6 | silicon/sim: read 0x21F8 before/after ONE healthy cross-die read — bit[10] flips with [8:1]=0 |
| F7 | N1 vehicle (coincident stuck read+write): bit[9] sets at first expiry while `ahb_sub_hresp` shows no ERROR |
| F8 | withhold B for 2^16+16 then release; new non-EWR write in the gap; check its `hresp`/`sub_wr_os_ctr` |
| F9 | add a "max raw-low run" counter next to F6 and read it on silicon after a read soak; compare to 2^16 |
| F10 | FC-write header len=4, 2 words, then a new header: committed length/IRQ show the mis-frame |
| F11 | pipelined AHB BFM + `s_axi_wready` low 3 cycles during write A; check write B's payload at the peer |
| F12 | `grep -n "NEGO_CFG_RESET\|DEBUG_UNLOCK_DEFAULT" src/rtl/asic/tidelink_dft_wrapper.sv src/rtl/tidelink_top.sv` — two different POR truths |
| F13 | CDC lint (SpyGlass reset-domain) on `u_gpio_phy_apb_regs.link_rx_rst_n`; or SVA `role_locked_o` rise synchronous to `link_rx_clk` |
| F14 | read 0x21F0 in a loop while `in6_adv` pulses; look for non-monotonic `ch6_grant_cnt` |

End of report.


---

# PART 3 Link / PHY / FCSM / PTP RTL

# TideLink deep RTL review — Link / PHY / FCSM / PTP layers

Baseline: `origin/main` = `5e8bdb5a` (review tree `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a`, verified `git rev-parse HEAD`).
Next iteration: `origin/rev2/integration` = `cba9774d` (read-only checkout `$WORKTREES/SoCLabs/td-bisect/rev2-final`).
Cross-worktree WIP compared: `tidelink-consolidated` branch `wip/fcsm-collision-consolidated-2026-08-17` = `b0c75918` (its FCSM edits are COMMITTED there; only docs are dirty — `git status` showed 2 modified docs + 2 untracked).
All line numbers are at `5e8bdb5a` unless prefixed `rev2:` or `b0c7:`. Read-only review; no file in any git tree was touched.

Legend per finding: **Sev** BLOCKER/HIGH/MED/LOW · **Conf** V = Verified-in-code, P = Plausible, H = Hypothesis · **Effort** S/M/L · **rev2** fixed / partial / not.

---

## 0. Executive summary

1. **The WIP commit `52c06677` cannot reach silicon through its FCSM half and DOES reach it through its controller half.** Both ASIC flists source `WlinkGenericFCSM{,_1..5}.v` from `deps/` (`flists/tidelink_top_full_asic_v2.flist:315-320`, `flists/tidelink_top_full_asic.flist:165-170`); `axi_chiplet_controller.sv` is in both (`:403` / `:245`). The ASIC synthesis flow reads the `_v2` flist (`syn/asic/fusion-compiler/Makefile:19-20`, `ASIC_PHY ?= _v2`). The 68 controller lines are 10 `(* mark_debug *)` alias wires **plus a 13-bit saturating counter and a 1-bit latch (14 flops, no functional sink)** — functionally inert in ASIC (swept, no keep attribute) but not "aliases only" (`axi_chiplet_controller.sv:2140-2160`).
2. **Part-B of the watchdog (unconditional state-7 exit on `force_clear`, `WlinkGenericFCSM.v:426`) has a real defect: it exits state 7 without clearing `sop`.** `_GEN_114` (`:425`) only clears `sop` on `auto_tx_out_advance`; LINK_IDLE holds `sop` (`:392 _GEN_55 = ... | sop`); `auto_tx_out_sop = sop` (`:659`); the TX router arbitrates on `sop` level (`deps/.../WlinkTxRouter.v:66-77`) and LINK_IDLE has no `advance` term. Net effect: after a forced exit the node keeps a stale NACK request on the router; when the router resumes granting it can serialise that NACK repeatedly (each one is a `link_revert` at the peer) until the FSM next enters a SEND state. One-line fix (§2.4). Sev HIGH (for the FPGA image where it is live), Conf V for the mechanism.
3. **ASIC FCSMs have ZERO recovery features.** `grep -c socl_` = 0 in every `deps/` FCSM vs 73/72/72/72/72/130 in the local overrides (§4). The peer's ASIC-sim measurement (`$WORKTREES/SoCLabs/td-bisect/asicsim-2026-08-26/l7_starvation_ab_SUMMARY.txt`) shows the ASIC arm **wedged in state 7 for 1536 io_tx_clk under emit starvation while the FPGA twin escaped** — I re-verified the counts and the flist split; the evidence file is consistent with the code. On top of that the ASIC AXI nodes ship **CRC ON** (`deps/.../WlinkGenericFCSM.v:636 disable_crc<=1'h0`) while the FPGA-validated AXI nodes ship **CRC OFF** (`local_overrides/WlinkGenericFCSM.v:747 <=1'h1`): the ASIC will take the NACK/state-7 path on the first CRC error with none of the FPGA-proven backstops. §4 lists what must exist in ASIC-reachable files. Sev BLOCKER, Conf V.
4. **The two WIP worktrees agree on Part-A and disagree only on Part-B's default**: main = unconditional (`:426`), consolidated = `` `ifdef TL035_PARTB `` default OFF (`b0c7:WlinkGenericFCSM.v:431-441`) + `TL035_ILA_TAPS` mark_debug macros. The consolidated controller is BEHIND main (it lacks the Hazard-3 `swi_auto_anchor_force_in` path, `git diff 52c06677 b0c75918`). Recommendation: keep Part-A, make Part-B opt-in (`ifdef`, default OFF) **and** fix the `sop` clear before anyone turns it on; do not merge the consolidated controller. §2.7.
5. **FCSM copies are parameter-only clones** (widths, 5 data_ids, 5×4 CR/CRACK/ACK/NACK ids, replay address width 4 vs 6, and the width-specialised sub-module names) — every `socl_` recovery edit is applied identically to `_0.._4`; `_6` (TideLink node 0xA1) is a different lineage: it still has the pre-TL-035 sticky watchdog (`WlinkGenericFCSM_6.v:646-648`, `_GEN_115` unchanged `:809`) but is the ONLY copy with the `fe_tx_credit_max` swi-enable fix (`:1370-1398`); `_0.._4` still re-zero it (`WlinkGenericFCSM.v:845-846`, `_1.._4:823-824`). §3.
6. **CDC**: the a2l ACK-pointer mailbox is a 1-bit-toggle ping-pong handshake (`WavMultibitSync_18.v:98-141`) — it cannot deliver a torn value; TL-027 is a **dropped update**, and continuous `w_inc=1` is the correct latest-value discipline for a level quantity, not a band-aid. The remaining structural holes: `FCReplayV2_13` had its TL-032 revert-rewind reverted (`:228-247`) while `_1/_3/_5` carry it (`_1:166-168`); ASIC uses the deps `AddrSync_18` (no reset-skew fix, `asic_v2.flist:263`) but the local coherent `MultibitSync_18` (`:238`). §5.
7. **`axi_chiplet_controller.sv`** is 6871 lines at this commit (not 6482). The AW-node replay window is 8-deep (`FCReplayV2_1.v:75,:81`) and there is **no timeout anywhere in the replay nodes** (`grep -n -iE 'timeout|wdog' WlinkGenericFCReplayV2_*.v` = 0 hits) — TL-042 H1 stands. 12 bare `(* mark_debug *)` attributes are in an ASIC-sourced file (`:2127-2147`), plus 11 in `tidelink_fc_adapter.sv:254-264` (also ASIC). §6.
8. **PHY/bring-up**: `NEGO_CFG_RESET=7'h00` (`:84`) still means "no autonomy unless the integration overrides"; `AUTO_ANCHOR_EN/SELF_ARM_TRAIN_EN/TRAIN_ENTRY_FALLBACK/EPOCH_ANCHOR_EN` all default 0. The Hazard-3 idle-qualified beacon path is on main and carries its own documented fail-closed residual (`WavD2DGpio_v2.v:277-295`). `calibrated_once_q` is still a one-shot but main now has the `SWI_FORCE_RECAL` W1P door (`:1244-1262` → `calibrator_v2.sv:529`). Autoneg has terminal `ST_ERROR` (`:1812`) with no self-exit and deliberately un-armed timeouts in the FIN states (`:306-315`). §7.
9. **PTP servo cannot converge from an initial offset > 1 s and can write an invalid nanosecond field**: `needs_phase_step_r` is set (`tidelink_ptp_servo.sv:566,:590`) and never cleared (only writers: `:443` reset), seconds are never corrected on the step (`:611-614` uses the LOCAL `sub_t2_sec`), and `sub_t2_ns - offset_r[29:0]` has no borrow/carry. Plus: no timeouts in either servo FSM, an untagged 3-word mailbox, un-reset multiplier control flops, and a probable stale-timestamp race against the PHC capture CDC. The APB mailbox-RO defect from memory IS fixed on main (`tidelink_top.sv:973-988`). Sev HIGH, Conf V. §8.
10. **Link-clock divider**: the RTL itself is a correct glitch-free two-leg mux with a sound 3-stage ratio CDC; **but the new top-level port `link_clk_div_ratio_i` (`tidelink_top.sv:388`) is not connected by either wrapper** (`grep -rn link_clk_div_ratio_i` hits only `tidelink_top.sv`, the divider, and cocotb benches — nothing in `src/rtl/asic/tidelink_dft_wrapper.sv` or `fpga/vivado_ip/tidelink_vivado_wrapper.v`), there is no SDC for `clkdiv_r`/the negedge interlock flops (`constraints.sdc` has only `pad_clk_tx_fwd` from the port, `:102-104`), and the SDC file the divider header cites (`ASIC/genus-innovus/inputs/tidelink_constraints.sdc`, `tidelink_link_clk_div.sv:202`) does not exist. §9.

rev2 delta in scope (`git log origin/main..origin/rev2/integration -- src/rtl/local_overrides src/rtl/tidelink_link_clk_div.sv src/rtl/tidelink_link_rate_regs.sv src/rtl/tidelink_ptp*.sv src/rtl/tidelink_phc_cdc.sv flists/`) = 4 commits, all TL-043-ARR (AR/R replay self-heal `_7/_9` + FPGA flist re-point + benches). **Nothing else in this review's scope changed on rev2**; every finding below is tagged accordingly.

---

## 1. Flist truth table (verified by grep at 5e8bdb5a; rev2 identical except the FPGA `_7/_9` lines)

| Module | FPGA v2 (`tidelink_fpga_v2.flist`) | ASIC v2 (`tidelink_top_full_asic_v2.flist`, the synthesis flist) | ASIC v1 (`tidelink_top_full_asic.flist`) |
|---|---|---|---|
| `WlinkGenericFCSM{,_1,_2,_3,_4}` (AXI AW/W/B/AR/R, ids 0x80-0x84) | **local** `:322-326` | **deps** `:315-319` | deps `:165-169` |
| `WlinkGenericFCSM_5` (GB, id 0xA0) | deps `:327` | deps `:320` | deps `:170` |
| `WlinkGenericFCSM_6` (TideLink FC, id 0xA1) | local `:334` | **local** `:321` | local `:171` |
| `WlinkGenericFCReplayV2_1/_3/_5` (AW/W/B a2l) | local `:287/:299/:302` | local `:283/:298/:304` | deps `:142/:153/:155` |
| `WlinkGenericFCReplayV2_7/_9` (AR/R a2l) | deps (rev2: **local**, `bf813a74`) | deps `:306/:308` (rev2: still deps) | deps |
| `WlinkGenericFCReplayV2_12/_13` (node-6 l2a/a2l) | local `:290/:294` | local `:286/:290` | local `:145/:149` |
| `WavMultibitSync_18` | local `:260` | local `:238` | local `:126` |
| `WlinkGenericFCReplayAddrSync_18` | local `:282` | **deps** `:263` | deps `:139` |
| `WlinkEccSyndrome` | local `:269` (real syndrome) | local `:253` (real) | **deps `:135` (bypass: `corrected=0; corrupted=0`, deps `:299-301`)** |
| `Wlink.v`, `axi_chiplet_controller.sv`, `tidelink_autoneg.sv` | local (+v2 shims `:370/:417`) | local `:351/:403/:365` | local `:199/:245/:213` |
| `WavD2DGpio_v2 / Rx_v2`, `WlinkGPIOPHY_v2`, deskew_v2, calibrator_v2 | local | local `:166/:182/:260/:157/:387` | V1 files (`:89-91/:136/:228/:229`) |
| `WavD2DGpioTx` | deps `:211` | deps `:183` | local V1 `:91` |
| `i2c_master.v` | local `:384` (cosmetic + ifdef'd ILA tap) | deps `:359` | deps `:207` |
| `tidelink_link_clk_div / link_rate_regs` | `:451/:455` | `:410/:414` | `:252/:256` |
| `tidelink_ptp / ptp_servo / phc_cdc` | `:95-97` | `:75-78` | `:24-27` |

Synthesis selection: `syn/asic/fusion-compiler/Makefile:11 MODULE ?= tidelink_top_full`, `:19 ASIC_PHY ?= _v2`, `:20 override FLIST := flists/$(MODULE)_asic$(ASIC_PHY).flist` → `tidelink_top_full_asic_v2.flist`. (`syn/asic/common.mk:42-43` would pick the V1 file for any flow that does not override — design-compiler/rtl-architect use `ASIC_FLIST=flists/tidelink_asic.flist`, `common.mk:44`, which contains none of these modules.)

---

## 2. WIP commit `52c06677` — line-by-line

### 2.1 What it changed (`git show 52c06677 --stat`: 6 files, +190/-12)
- `WlinkGenericFCSM.v` (+50): `SOCL_L7_WDOG_THRESHOLD` made `` `define ``-overridable (`:79-84`, default `16'h4000` unchanged); `socl_l7_wdog_progress = auto_tx_out_advance` (`:330`); `socl_l7_wdog_force_clear` loses the `& ~socl_l7_real_crc_seen` term unless `TL033_LEGACY_WDOG` (`:331-339`); `_GEN_115` becomes `(auto_tx_out_advance | socl_l7_wdog_force_clear) ? 3'h4 : state` (`:426`); the dwell counter resets on `socl_l7_wdog_progress` instead of the sticky latch (`:1049-1071`).
- `WlinkGenericFCSM_1.._4.v` (+21 each): identical edit, shorter comments (`_1:79-84, :309-318, :404, :1033-1046`; `_2:404, :1041`; `_3/_4:404, :1036`).
- `axi_chiplet_controller.sv` (+68): `:2099-2160` — 10 `(* mark_debug *)` alias wires of existing `sync_obs_*_1` apb_clk snapshots (`:2127-2136`), and a saturating stall counter `dbg_a2l_stall_cnt_q[12:0]` + `dbg_a2l_wedged` (`:2145-2159`, `always_ff @(posedge apb_clk or negedge hresetn)`), counting `sync_obs_a2l_app_v_1 & ~sync_obs_a2l_app_rdy_1`, cleared on `app_rdy`.

### 2.2 Reach
- FCSM half: **FPGA-only** (§1). It is exactly the "silicon UNCHANGED" claim in the commit's own comment (`:80-82`) — true, but for the wrong reason: silicon never compiles this file.
- Controller half: **in the ASIC flist**. The 10 alias wires are zero logic. The counter/latch are 14 real flops with no fan-out except the `mark_debug` attribute; Fusion Compiler ignores Xilinx `mark_debug` and there is no `keep`/`dont_touch` anywhere in `src/rtl` (`grep -rniE '\(\*\s*(dont_touch|keep|async_reg)' src/rtl` = 0), so they will be swept. Reset domain matches the `sync_obs_*` chain (`:1975-2040`, apb_clk / hresetn). Functionally inert in both targets; correct as instrumentation (the clear-on-`app_rdy` idiom makes a transient FIFO-full impossible to count to 2^12). Peer's characterisation "alias wires + comments only" is slightly understated; conclusion unchanged.

### 2.3 Part-A (progress proxy) — sound
- Pre-change (Fix D, still the form in `_6:646-648` and in `TL033_LEGACY_WDOG`): `force_clear = (cnt==THRESH) & ~real_crc_seen`, and the counter was pinned to 0 while `real_crc_seen` (`:1061-1063` legacy arm). `real_crc_seen` is set on the first `crcCorruptSeen` and never cleared (`:1041-1048`) → the backstop is dead after the first real CRC error, i.e. in exactly the regime it exists for. Registry TL-035 (`docs/BUG_REGISTRY.yaml:1328-1345`) agrees.
- Post-change: counter resets on `auto_tx_out_advance` (`:1064-1066`) and on `state != 7` (`:1059-1060`); saturates at `THRESH` (`:1067-1069`). `force_clear` is therefore a level held from `cnt==THRESH` until the state leaves 7. In the state-7 arm every `send_nack_req` writer is masked with `& ~socl_l7_wdog_force_clear` (`:1021-1029`), so the pending NACK request is dropped when the backstop trips. Semantics: "state 7 with zero router grants for 16384 io_tx_clk". Legit replays emit (advance) within a few cycles, so this cannot fire on a healthy link; a >2.6 ms (at 6.25 MHz word clock) grant starvation is a dead link by any other measure. Verdict: **correct and safe** (Conf V). Minor: a fresh `crcCorruptSeen`/`isNotExpPacket_l7` arriving in the same cycle as `force_clear` is also dropped (`:1021` ORs then masks); it re-arms on the next mismatching packet, so bounded.
- Sim proof exists per registry (`test_a2l_r1_probe.py::test_wdog_arming_forced_stall`) and per the peer's `l7_starvation_ab_SUMMARY.txt` (FPGA arm: `wdog_cnt=256 (threshold 256) force_clear=1 ... states seen [4] -> ESCAPED`).

### 2.4 Part-B (state-7 exit) — defect: exits with `sop` still asserted  **Sev HIGH (FPGA image) · Conf V (mechanism) / P (storm magnitude) · Effort S · rev2 not**
- The state-7 arm's next-state is `_GEN_115` via `_GEN_150 = state==3'h7 ? _GEN_115 : _GEN_146` (`:453`) → `_GEN_166` (`:467`) → `_GEN_181` (`:481`) → `state <= _GEN_181` (`:735`). So the exit really is forced. ✔
- But the state-7 arm's `sop` next-value is `_GEN_149 = state==3'h7 ? _GEN_114 : ...` (`:452`) with `_GEN_114 = auto_tx_out_advance ? 1'h0 : sop` (`:425`) — **`force_clear` is not in it**. `data_id`/`word_count`/`link_data` likewise hold (`:456-458`).
- In LINK_IDLE `sop` is self-holding: `_GEN_55 = a2l_fc_replay_link_valid & ~fe_rx_is_full | sop` (`:392`) → `_GEN_63` (`:395`) → `_GEN_72` (`:403`) → `_GEN_173 = state==3'h4 ? _GEN_72 : ...` (`:473`). LINK_IDLE has no `auto_tx_out_advance` term at all (FC.scala 501-533 as emitted; compare state 5/6/7 which all gate on advance `:417,:421,:425`).
- `assign auto_tx_out_sop = sop` (`:659`). The router selects a channel on `auto_in_N_sop` level (`deps/axi-chiplet-controller/logical/wlink/WlinkTxRouter.v:66-77`).
- Consequence: after `force_clear` the node sits in state 4 presenting a valid NACK packet. Under true emit starvation nothing happens (no grants — which is also why the backstop cannot help when the router itself is dead). When grants resume, the router serialises that stale NACK, the FCSM ignores the advance (state 4), `sop` stays 1, and the round-robin can serve it again — each NACK is a `link_revert` + replay at the peer. The storm ends only when this node enters a SEND state (its own data, an ACK on the replayed packet → state 6, or a new mismatch → state 7), i.e. roughly one peer round-trip; it is bounded, not lost-NACK-bounded as the comment claims (`:315-328` says "bounded lost-NACK").
- **Fix (one line, all 5 files):** `wire _GEN_114 = (auto_tx_out_advance | socl_l7_wdog_force_clear) ? 1'h0 : sop;` — mirror what Part-B did to `_GEN_115`. Also consider clearing `word_count`/`link_data` for hygiene (they are re-loaded on the next SEND entry anyway).
- **How to prove:** in `cocotb/tidelink_axi_datanode_recovery` (the `l7_starvation` bench), after the forced exit, re-enable `auto_tx_out_advance` and count NACK-id packets on `auto_tx_out_*` while `state==4`; expect ≥1 today, 0 after the fix. Also assert `!(state==3'h4 && sop && $past(sop) && !a2l_fc_replay_link_valid)` as an SVA in the FCSM.

### 2.5 The threshold and the domain
`SOCL_L7_WDOG_THRESHOLD=16'h4000` io_tx_clk cycles (`:83`); io_tx_clk is the /16 TX word clock (`WavD2DGpioTx.v:515` count, `WlinkGPIOPHY_v2` 1:1 hsclk). With the new divider (§9) a /16 link makes this 16384 × 16 × 16 ref cycles ≈ 42 ms at 100 MHz — still fine. No silicon measurement of the legitimate worst-case round-trip exists (registry `verification_superseded_2026_08_09`: "hw_tested: true 2026-08-13, first attributable A/B" but "NO DEMONSTRATED EFFECT"). The value is defensible on the emit-starvation definition alone; the missing measurement matters only if Part-B is enabled.

### 2.6 Conflict with `tidelink-consolidated` (`b0c75918`)
`git diff 52c06677 b0c75918 -- src/rtl/local_overrides/WlinkGenericFCSM*.v`:
- Identical Part-A on all five files.
- `_GEN_115` wrapped: `` `ifdef TL035_PARTB `` (unconditional form) `` `else `` original `` `endif `` (`b0c7:FCSM.v:431-441`, `_1:404-408`), i.e. **default OFF**, with the author's "BLIND-MERGE-FORBIDDEN … validate THRESHOLD vs the real 40 ns round-trip" note.
- `FCSM.v` only: `` `ifdef TL035_ILA_TAPS `define TL035_DBG (* mark_debug = "true" *) `` applied to `state`, `send_nack_req`, `socl_l7_real_crc_seen`, `socl_l7_wdog_cnt` (`b0c7:196-201, :291, :312-313`). Note the macro is `` `define ``d inside a module and never `` `undef ``d — harmless but a compile-order smell if the other four copies ever get the same treatment.
- `axi_chiplet_controller.sv` in `b0c75918` **lacks** both the WIP ILA block and the Hazard-3 `swi_auto_anchor_force_in` port (it still ORs `auto_anchor_pulse_q` into `swi_sync_force_always_in`, `git diff 52c06677 b0c75918` hunk at `:6659`), i.e. the consolidated controller predates `7157e76d`. Do not take the controller from that tree.
- Registry label: both trees still say "TL-033" in RTL comments; the registry renumbered the watchdog to **TL-035** (`BUG_REGISTRY.yaml:1328`); TL-033 is now the 13-bit credit-underflow bug (`:1293-1297`). Fix the label when merging.

### 2.7 Merge / revert recommendation
1. **Keep Part-A** on main (FPGA-only today; it is the correct form and sim-proven).
2. **Downgrade Part-B to opt-in** exactly as the consolidated tree did (`` `ifdef TL035_PARTB ``, default OFF) — the silicon A/B showed no demonstrated effect either way, the wedge hypothesis has moved to `tidelink_top.sv` `sub_axi_progress`/hazard-list saturation (memory 08-17/08-19), and Part-B as written has the §2.4 defect. When it is enabled, land the `_GEN_114` fix in the same commit.
3. Take the `TL035_ILA_TAPS` macro from `b0c75918` only if the FPGA ILA campaign still needs FCSM-internal probes (the WIP controller taps deliberately skipped them, `:2118-2123`); otherwise drop it.
4. Leave the controller ILA block on main; it is inert for ASIC. Optionally fence it with `` `ifndef SYNTHESIS_ASIC `` to keep the ASIC netlist byte-identical to pre-WIP.
5. Rename TL-033 → TL-035 in the five FCSM comment blocks.
6. **rev2 status: not** — rev2 still carries the unconditional `_GEN_115` (`rev2:WlinkGenericFCSM.v:426`) and the sticky-form `_6` (`rev2:_6:646,:809`).

---

## 3. FCSM copies — divergence analysis

Method: `diff <(sed 's/WlinkGenericFCSM_N/X/' _N.v) <(sed 's/WlinkGenericFCSM_1/X/' _1.v)` for N∈{0,2,3,4}, plus deps-vs-local diffs and targeted greps (all shown in the transcript).

| Copy | data_id (`swi_data_id_1`) | CR/CRACK/ACK/NACK ids | rx data / app data width | replay addr width | a2l / l2a replay modules | CRC gen |
|---|---|---|---|---|---|---|
| `FCSM.v` (AW) | 0x80 `:740` | 0x08-0x0B | 112 / 101 | 4 (16-slot ring, `_link_revert_addr_T_6 == 8'hf`) | `_1` / base (`:616/:574`) | `WlinkCrcGen` |
| `_1` (W) | 0x81 `:718` | 0x0C-0x0F | 48 / 37 | 6 (`8'h3f`) | `_3` / `_2` | `_2` |
| `_2` (B) | 0x82 `:718` | 0x10-0x13 | 24 / 14 | 4 | `_5` / `_4` | `_4` |
| `_3` (AR) | 0x83 `:718` | 0x14-0x17 | 112 / 101 | 4 | `_7` / `_6` | base |
| `_4` (R) | 0x84 `:718` | 0x18-0x1B | 56 / 47 | 6 | `_9` / `_8` | `_8` |
| `_5` (GB, deps only) | 0xA0 (`deps/_5:628`) | — | 40 | — | — | — |
| `_6` (TideLink FC, local) | 0xA1 `:1168` | — | — | — | `_13` / `_12` | `_8` |

- **Every non-width, non-id difference among `_0.._4` is zero** except one longer Fix-G comment in `_2` (`_2:1011-1019` vs `_1:1015-1018`); the logic (`state == 3'h4 || state == 3'h5`) is identical (`FCSM.v:1036`, `_1/_3/_4:1014`, `_2:1023`). All five carry: L6 CR gate (`SOCL_L6_MIN_CR_EMITS=32`), L7 CRACK gate (`SOCL_L7_MIN_CRACK_EMITS_VAL 8`, `:76`), Fix-A forgive, Fix-D/TL-035 watchdog (Part-A + unconditional Part-B), Fix-E re-ACK (`SOCL_REACK_THRESHOLD=16'h0100`), Fix-G, `disable_crc<=1` (`:747`, `_1.._4:725`), and the **un-fixed** `fe_tx_credit_max` re-zero (`:845-846`, `_1.._4:823-824`).
- **`_6` diverges in kind, not just width**: 130 `socl_` lines vs 72-73; it has the L9/L9b/L9c re-anchor substrate (`isNotExpPacket_l9`, `:640`), the sticky-gated Fix-D watchdog (`:646-648`, dwell block `:1635-1641`, no `socl_l7_wdog_progress`), the original `_GEN_115` (`:809`), `disable_crc<=1'h0` (`:1194`), and the Bug-C-style `fe_tx_credit_max` fix (`:1370-1398`, the re-zero is commented out at `:1372`). So the TideLink node has **no** TL-035 fix, and the AXI nodes have **no** credit-max fix — the "fix one twin, not the other" pattern memory warns about, now in both directions.
- **Could they be one parameterised module?** Yes for the FCSM body: parameters `{RX_DATA_W, APP_DATA_W, ADDR_W, DATA_ID, CR_ID, CRACK_ID, ACK_ID, NACK_ID}` cover everything in the table. The blocker is that the sub-modules are also Chisel-emitted width clones (`WlinkGenericFCReplayV2_{1..13}`, `WlinkGenericFCReplayAddrSync{,_3,_15,_18}`, `WavMultibitSync{,_3,_15,_18}`, `WavFIFO_N`, `WlinkCrcGen_N`), so a single Verilog FCSM needs parameterised versions of ~5 more modules — or, better, the `socl_` features added once in Chisel (`wav-wlink-hw/src/main/scala` FC.scala) and regenerated. §11.

**Finding 3.1 — `fe_tx_credit_max` swi-enable re-zero still live on all five AXI nodes (both FPGA-local and ASIC-deps copies).** Sev MED · Conf V (code) / P (reachability) · Effort S · rev2 not. `WlinkGenericFCSM.v:844-848`: `else if (~en_ff2_rx_demet_io_out) fe_tx_credit_max <= 8'h0;`. Memory's silicon root cause (07-09) was exactly this on `_6`. Reachability today is reduced because the autonomous handoff sequencer holds FCCTRL bit0=1 through the LL-swreset (`axi_chiplet_controller.sv:3765-3790`, writes `0x27f09→0x27f01→0x27f07`); it bites if software ever drops `swi_enable` mid-session or uses the old `0x27f08/00` recipe. Prove: in `tidelink_axi_datanode_recovery`, pulse 0x208 bit0 low after CR/CRACK on the AW node and watch `exp_pkt_num` fail to wrap at the 16-packet lap. Fix: mirror `_6:1370-1398` into the five AXI copies (and into whatever ASIC-reachable form §4 chooses).

**Finding 3.2 — TL-035 (watchdog) is absent from `_6`.** Sev MED · Conf V · Effort S · rev2 not. The TideLink FC node still disarms its state-7 backstop forever after the first real CRC error (`_6:646-648`, sticky latch set at the `socl_l7_real_crc_seen` block). Since `_6` runs CRC ON by default (`:1194`), this node is the one most likely to see a real CRC error. Same Part-A edit as `_0.._4`.

**Finding 3.3 — `FCReplayV2_13` lacks the TL-032 revert-rewind that `_1/_3/_5` carry.** Sev LOW-MED · Conf V · Effort S · rev2 not. `_13:228-247` documents the rewind as "REVERTED 2026-07-09" (built for the wrong root cause), while `_1:166-168` (and `_3`, `_5`) landed the same rewind on 08-09 with a reproduce-first proof. The window guard on `_13` (`:132-139`, `<= 5'h10`) has the same wrap-on-revert exposure the `_1` comment describes (`_1:147-162`). Prove with the `_1` revert test re-targeted at NODE=13.

---

## 4. What recovery MUST exist in the ASIC-reachable files

Verified counts (`grep -c socl_`): deps `WlinkGenericFCSM{,_1,_2,_3,_4,_5,_6}.v` = **0, 0, 0, 0, 0, 0, 0**; local = 73, 72, 72, 72, 72, (absent), 130. Deps replay/sync files carry 0 SoC-Labs markers; local `_1/_3/_5` = 4 each, `_12` = 3, `_13` = 8, `MultibitSync_18` = 3, `AddrSync_18` = 4. Peer evidence (`asicsim-2026-08-26/`): `flist_divergence.txt` lists the same 8 shadow pairs I found in §1 (ASIC-side 6542 SLOC behind the shadow); `l7_starvation_ab_SUMMARY.txt` — FPGA arm escapes state 7 via `force_clear`, ASIC arm "stayed in state 7 (SEND_NACK) for 1536 io_tx_clk … never exited"; `fcsm_ab_SUMMARY.txt` — both arms clear state 2 under the marginal-link stimulus (so L6/L7 are not binding in that sim, but they were binding on silicon per the I1 history in `FCSM.v:66-75`).

ASIC-reachable today (v2 flist): `_6` (all its `socl_` features), `FCReplayV2_1/_3/_5` (TL-027 + TL-032), `_12/_13` (w_inc=1 + guard), `WavMultibitSync_18` (coherent reset), real `WlinkEccSyndrome`, `WlinkRxLinkLayer` (`sync_resync_boundary`, `:407`), `Wlink.v` (`swi_delay_cycles` POR 0, `:2674`), and every `axi_chiplet_controller.sv`/`tidelink_top.sv` backstop.
**NOT ASIC-reachable**: everything inside `WlinkGenericFCSM{,_1.._4}` (AXI nodes) and `AddrSync_18`'s reset-skew gate, and the `_7/_9` (AR/R) self-heal even on rev2.

Minimum set that must be made ASIC-reachable, ranked by silicon evidence:

| # | Feature (local `FCSM.v` lines) | Why it must ship | Evidence class |
|---|---|---|---|
| A1 | Fix-A bring-up forgive + Fix-G LINK_IDLE disarm (`:301-309`, `:1031-1040`) | Without it a CR/CRACK-storm NotExp during bring-up NACKs forever; without G the response nodes (B/R) never disarm and mask every real CRC→NACK | silicon (I1, 07-29/31) |
| A2 | L6/L7 min-emit gates (`:292-298`, `:851-872`, `SOCL_L7_MIN_CRACK_EMITS_VAL 8` after I1 retune `:66-75`) | Real-ratio bring-up livelock at 40 ns UI | silicon (I1) — note the peer's ASIC sim did NOT need them, so gate the value on a silicon-ratio regression, not on sim |
| A3 | Fix-D/TL-035 Part-A watchdog (`:310-339`, `:1049-1071`) with the §2.4 `sop` fix if Part-B is ever enabled | ASIC arm measured wedged in state 7; ASIC AXI nodes run CRC ON (deps `:636`) so state 7 is reachable on the first marginal-eye error | ASIC sim (08-26) + silicon TL-035 |
| A4 | Fix-E receiver re-ACK (`:363-370`, `:1090-1110`) | sustained ACK-loss → credit ring full → permanent TX stall (test_14 class) | sim |
| A5 | `fe_tx_credit_max` enable-dip fix (only in `_6:1370-1398`) | pktnum wrap disabled → jam at the lap | silicon (07-09, on `_6`) |
| A6 | CRC default decision: ASIC AXI nodes = ON with no recovery vs FPGA = OFF with recovery; the two have never been validated in the same combination | either re-enable on FPGA with A1-A4 and soak, or ship ASIC OFF with an explicit "no link-layer integrity" contract | memory 07-18/19 |
| A7 | `AddrSync_18` reset-skew gate (`local:58-96`) — currently ASIC uses deps `:263` | silicon bring-up false-FULL on node 6 (07-07) | silicon |
| A8 | `_7/_9` TL-027/TL-032 (rev2 `e88ff7be`) — ASIC flist not re-pointed | 8/8 ACKs lost permanently in sim on unpatched nodes (memory 08-24) | sim (all 5 nodes) |

How: either (i) re-point the ASIC v2 flist lines `:315-319` and `:263` to `local_overrides` (the exact mechanical change already made for the FPGA flist in `b98b944b`) and re-run the peer's `sweep_asic`/`l7_starvation` suites with `ASIC_FLIST=1`, or (ii) the §11 Chisel route. (i) is the only option inside a tapeout window. Note the ASIC v2 flist header comment about V1/V2 composition must be updated, and `docs/SIM_GATE_COVERAGE.md` should carry an `ASIC_FLIST=1` tier so the FPGA/ASIC arms can never diverge silently again (the peer's `sweep_asic_SUMMARY.txt` shows 1 multipkt FAIL and `v2_mask_hs_bilateral` no-result on the ASIC arm — triage those before relying on the tier).

**Finding 4.1 — ASIC ships AXI FC nodes with CRC ON and zero recovery; FPGA validated CRC OFF with full recovery.** Sev BLOCKER · Conf V · Effort M (flist re-point + regression) · rev2 not.

---

## 5. CDC review

### 5.1 The a2l ACK-pointer crossing (TL-027) — structurally sound after the override
- `WavMultibitSync_18.v` is a two-slot ping-pong mailbox with 1-bit `wptr`/`rptr` toggles through `WavDemetReset` 2-FF synchronisers: `we = w_inc & w_ready` (`:98`), `w_ready = ~(rptr_sync ^ wptr)` (`:101`), `r_ready = rptr ^ wptr_sync` (`:103`), data written to `mem_0/mem_1` selected by `rptr` (`:120-133`), pointer toggles only after the write (`:135-141`). The reader reads the slot the writer is not writing → **a torn multi-bit value is impossible by construction**; the only failure is a **dropped update** when `w_inc` pulses while `!w_ready`. Deps `FCReplayV2` used an edge (`w_inc = a2l_link_addr != a2l_link_addr_in`, deps `:116`), so one drop = permanent stale ACK = false-FULL. `w_inc = 1'b1` (`_1:143`, `_13:225`, `_12:148`) turns the mailbox into a latest-value sampler — correct for a level quantity consumed as a level (`a2l_full` compares pointers, `_1:75`). Not a band-aid; it is the right discipline. Gray coding would add nothing (the value never crosses un-handshaken).
- Coherent reset (`MultibitSync_18:46-87`): each domain's reset is synchronised into the other (async-assert/sync-deassert, `:78-86`) and OR'ed into that side's reset. Standard. It applies only to `_18` (node 6's instances); the AXI nodes' mailboxes are deps base/`_3`/`_15` — pointer-parity desync after a single-domain reset re-pulse remains possible there (Conf P; prove with the `a2l_replay_cdc` bench's reset-skew case on NODE=1).
- ACK window guard (`_1:77-83`) and TL-032 rewind (`_1:166-168`) are link-domain-only comparisons; no new crossing.

### 5.2 Other multi-bit crossings without gray/handshake (verified)
- `axi_chiplet_controller.sv:1975-2040`: ~30 multi-bit `sync_obs_*` fields (fcsm_state[2:0], a2l_wptr[4:0], sack[4:0], fe_rx_cred[7:0], ecc counters…) are plain 2-FF synchronised from link/word clocks into apb_clk. Fine for observability, **but two of them are used functionally**: `auto_anchor_link_up = sync_obs_fcsm_state_1[2]` (`:4992`, single bit — OK) and `auto_anchor_tx_idle = ~sync_obs_a2l_app_v_1` (`:4993`, single bit — OK). The WIP wedge counter uses two single bits (`:2150,:2156`). No multi-bit field is decoded functionally. LOW.
- `tidelink_link_clk_div.sv:86-115`: `ratio_i[2:0]` 3-FF + "two consecutive equal samples" adopt. For a quasi-static APB-written value this is sound; a multi-bit transient can only be adopted if two successive clk_in samples see the same intermediate code, which needs inter-bit skew > one clk_in period — not the case for a register output. Conf V.
- `tidelink_phc_cdc.sv`: all six paths are toggle req/ack handshakes (`:168-225, :228-271, :274-336, :339-366, :369-437, :440-499`); data is held stable across the handshake. Path 1 (`:228-271`) assumes the PHC does not re-capture within the toggle latency — see §8 for the servo-side consequence. The `(* cdc_sync = "true" *)` attribute (`:176`) is not a tool-recognised keyword (`ASYNC_REG`/`async_reg` are); harmless, but CDC lint will not pick it up.
- `WlinkGenericFCSM.v`: rx→tx crossings are all single-bit `WavDemetReset` demets (`:568,:635,:641,:647`) or the async `WavFIFO_1 ack_nack_fifo` (`:599`); `fe_tx_credit_max`/`fe_rx_credit_max` are loaded in the rx domain and consumed there. No unprotected multi-bit crossing found in the FCSM.

### 5.3 Reset-domain notes
- `WavMultibitSync_18` local uses a combinational OR of an async reset and a synchronised reset as an async reset (`w_reset_coh`, `:86`; used at `:109,:118,:127`). Assert is async, de-assert is synchronous to the local clock (the synchronised term releases last) — acceptable, but reset-tree tools will flag "reset driven by logic". Document or restructure as a proper reset synchroniser cell for the ASIC flow. LOW.

---

## 6. `axi_chiplet_controller.sv` (6871 lines at 5e8bdb5a)

### 6.1 Region map (line anchors)
| Lines | Content |
|---|---|
| 22-160 | module + parameters: `AUTOCAL_ENABLE`, `USE_IDELAY`, `USE_CLKBUF`, `USE_T3A`, `EPOCH_ANCHOR_EN=0` (:52), `NEGO_TRAIN_CFG_RESET=16'h0001` (:65), `NEGO_CFG_RESET=7'h00` (:84), `ROLE_FROM_STRAP=1` (:89), `TRAIN_ENTRY_FALLBACK=0` (:94), `SELF_ARM_TRAIN_EN=0` (:113), `AUTO_ANCHOR_EN=0` (:120), `WINSCAN_*` (:127-139), `RETIRE_EN=1` (:150), `WINSCAN_DWELL=2.5M` (:159) |
| 538-640 | Region 4/8 chiplet-controller registers (ROLE_CFG, NEGO_*, R8 slots), `nego_cfg_reg <= NEGO_CFG_RESET` (:781), lock-pending / SELF_ARM arcs (:833-912) |
| 673-682 | `role_locked = role_lock_reg` |
| 1005-1120 | R8 CDC synchronisers; `TIDELINK_PHY_V2` arms |
| 1179-1475 | Region 8 extended (phy-align, I2C-train); `SWI_FORCE_RECAL` W1P (:1204-1262); `autonomy_armed` (:1428) |
| 1758-1970 | Region D + obs sync chain (:1975-2040) |
| 2099-2160 | **WIP ILA block (52c06677)** |
| 2165-2520 | Region 9/10 writes; FC handoff sequencer commentary (:2414-2470) |
| 2518-2720 | Region 9 SYNC-insert obs, RX sync-detect, Region 10 sweep oracle, Region D sticky capture |
| 2845-2967 | Region 8 read mux; Region C autoneg obs |
| 3046-3150 | Region F (AXI data-node obs, winscan/cal obs, FC-emit obs) |
| 3154 | `wlink_por_reset = ~poresetn \| ~role_locked` |
| 3412-3700 | APB bridge to Wlink / winscan FSM |
| 3713-3800 | FC data-mode handoff sequencer (autonomous 0x208 bootstrap 0x27f09→0x27f01→0x27f07) |
| 3964-4380 | winscan / anchor gate / quiesce |
| 4381-4930 | `` `ifdef TIDELINK_PHY_V2 `` PHY-side glue (calibrator, lane mask, deskew obs) |
| 4896-4950 | RETIRE logic |
| 4960-5060 | AUTO_ANCHOR FSM + obs word |
| 6521-6800 | `Wlink` instance (`.EPOCH_ANCHOR_EN`, `.swi_sync_force_always_in` :6739, `.swi_auto_anchor_force_in` :6757) |

### 6.2 Data-ids (verified)
AXI FC nodes: AW 0x80 (`FCSM.v:740`), W 0x81, B 0x82, AR 0x83, R 0x84 (`_1.._4:718`); GB 0xA0 (`deps/_5:628`); TideLink FC 0xA1 (`_6:1168`). PTP rides **short packets** 0x50/0x51 (`tidelink_ptp.sv:130-131`) plus FC SIDEBAND (`PKT_SIDEBAND=2'b01`, `servo:106`) — there is no 0xA2 FC node in this tree (0xA2 at `controller:2658` is an obs-word marker byte); memory's "dedicated PTP FC node 0xa2" describes the plan, not the code.

### 6.3 Findings
**6.3.1 — Replay window: 8-deep, no timeout (TL-042 H1 stands).** Sev HIGH · Conf V · Effort M · rev2 not. `FCReplayV2_1.v:75` `a2l_full` uses ptr[3] vs ptr[2:0] → depth 8; window guard `<= 4'h8` (`:81`). `grep -n -iE 'timeout|wdog|watchdog' local_overrides/WlinkGenericFCReplayV2_*.v` → 0 hits; the FCSM has no per-outstanding-packet timer either (its only timers are the CR/CRACK emit counters, the state-7 dwell and the re-ACK idle counter). A peer that stops ACKing (dead, or the §3.1 credit-max jam) fills the 8 slots and `app_ready` drops forever → AXI `awready` stalls the PS (registry TL-042 "open … candidate REJECTED ON HARDWARE", `BUG_REGISTRY.yaml:1761-1765`). Fix direction: an outstanding-age watchdog in the FCSM tx domain that raises an error/`link_revert`-and-drain rather than a silent stall, exposed as a sticky status bit; the design decision (drop vs error-respond) needs the XHB500 side. Prove: `test_awready_stall` class bench with the peer's ACK path forced off.

**6.3.2 — `mark_debug` in ASIC-sourced RTL.** Sev LOW · Conf V · Effort S · rev2 not. 12 bare attributes in `axi_chiplet_controller.sv:2127-2147` and 11 in `tidelink_fc_adapter.sv:254-264` (no `` `ifdef `` guard in either — the awk scan of fc_adapter found no preprocessor directives around them). Fusion Compiler ignores them; they are a hygiene/portability issue, not a functional one. Fence with `` `ifdef FPGA_DEBUG_ILA `` as `i2c_master.v:199-201` already does.

**6.3.3 — Credit path.** `fe_tx_credit_max` has no obs tap on any AXI node (only `obs_fe_rx_credit_max_o`, `:489/:6395`); memory's 07-09 fix plan item 3 ("expose fe_tx_credit_max + exp_pkt_num") is still open. Sev LOW · Conf V · Effort S. The handoff sequencer's bit0-held-high recipe (`:3765-3790`) is the operative mitigation for the enable-dip re-zero.

**6.3.4 — Auto-anchor beacon (Hazard-3 / N2) — landed, with a disclosed residual.** Sev MED (recovery efficacy, not corruption) · Conf V · Effort M (HW campaign) · rev2 not. `auto_anchor_pulse_q` is removed from `swi_sync_force_always_in` (`:6739`) and threaded to `swi_auto_anchor_force_in` (`:6757` → `Wlink.v:249/:1458` → `WavD2DGpio_v2.v:305`), qualified there by `io_link_tx_tx_idle`. The Defect-A guard is real (`:5027-5038`), the cap is ~8 s at 25 MHz (`ANCHOR_LEN=200_000_000`, `:4984`). `WavD2DGpio_v2.v:277-295` documents that under severe skew `io_link_tx_tx_idle` was observed 0 for ~3144 sampled edges → the beacon is inert (fail-closed). The `postcount==0` drain guard is architecturally dead on shipping silicon because `swi_delay_cycles` PORs to 0 (`Wlink.v:2674`) → `tx_en≡1` (`WavD2DGpio_v2.v:270-276`). Nothing on rev2 changes this. The mandatory ≥10-cycle HW campaign from memory is still owed.

**6.3.5 — Bring-up "lottery" mechanisms still present (inventory).**
- RX capture-clock placement race (physical): `tidelink_fpga_v2.flist:189-205` documents it and the `USE_EXT_CAP_CLK`/shared-BUFG fix (`WavD2DGpioRx_v2.v:216` default 0, `WavD2DGpio_v2.v:127 USE_SHARED_CAP_BUFG = USE_CLKBUF`). ASIC default 0 = bit-identical to the submodule; the ASIC equivalent (balanced capture-clock tree) is a CTS/placement constraint, not RTL — nothing in `constraints.sdc` names the per-lane capture clock. Sev MED · Conf P · rev2 not.
- `io_pol` resets to 1 (`WavD2DGpio_v2.v:116-117`, flist `:201`) — safe only because the shared path preserves the mux; `USE_CAP_CLKBUF` would invert all 8 lanes. LOW (documented).
- role-lock stagger: `wlink_por_reset = ~poresetn | ~role_locked` (`:3154`) gates `WavD2DGpioTx` `clk_en_qual` (`deps/…/WavD2DGpioTx.v:508,:522-524`) → the forwarded pad clock = the peer's RX clock. Verified chain; memory's "mutual clock enable" claim holds. The free-pass lock (no verdict gating) is still the design.
- `NEGO_CFG_RESET=7'h00` (`:84`) → `nego_en=0` at reset unless the integration overrides → zero-poke autonomy is a parent-repo decision; no sim tripwire here asserts what the chiplet build passes.

---

## 7. PHY / bring-up

### 7.1 `tidelink_autoneg.sv` (2418 lines)
- 20 states (`:256-317`): NEGO_INIT/WAIT/CLAIM/POLL/DONE, MASK_RES_TX/RD_ADDR/RD_DATA, TRAIN_ENTER/RUN/POLL_PEER/EXIT/DONE/FAIL, FIN_RDV/FIN_GO, BYPASS, ERROR.
- Timeouts: global `NEGO_TIMEOUT_DEFAULT` 1.31 s (`:27`) decremented "in all transient negotiation states" (`:853-856`) → `ST_ERROR` (`:899`); poll budget `T_POLL_TIMEOUT_DEFAULT=15` (`:438`); R5 retry backoff 0.3 s (`:483`) with "retry-forever" from `ST_TRAIN_FAIL` (`:476-479`, `:1781`).
- **States without a timeout, by design**: `ST_TRAIN_DONE`, `ST_FIN_RDV`, `ST_FIN_GO` (`:306-315`: "the global nego timeout is deliberately NOT armed in these states") — they rely on the winscan's `WS_FIN_WAITPEER` timeout to drop `local_fin_wait_i`. That is a cross-FSM liveness dependency with no assertion binding the two. `ST_ERROR` (`:1812`) is terminal: no arc out except a new episode/POR. Sev LOW-MED · Conf V · Effort S (add an SVA that FIN states always see `local_fin_wait_i` fall within the winscan timeout).
- `TRAIN_ENTRY_FALLBACK` (`:71`, default 0): a dead-I2C NACK routes into training (`:885`, `:1023`, `:1283-1292`) — the cand-2 mechanism, confirmed on silicon per memory; still default OFF here (the FPGA tcl sets it). rev2 not.
- I2C master used for autoneg: FPGA compiles `local_overrides/i2c_master.v`, ASIC compiles deps; the diff is cosmetic plus an `` `ifdef FPGA_DEBUG_ILA `` tap (`local:199-201`) — equivalent.

### 7.2 Calibrator (`tidelink_phy_align_calibrator_v2.sv`, 2575 lines; V1 `src/rtl/tidelink_phy_align_calibrator.sv`)
- One-shot: `calibrated_once_q` latches on first `S_DONE` and gates both re-trigger edges (V1 `:652-660`; v2 keeps the same sticky per its header `:14-31`). Memory's "no firmware retrain" finding is now **half-fixed on main**: `SWI_FORCE_RECAL` W1P (R8 slot0 bit6, `controller:1204-1262`, stretched `FORCE_RECAL_STRETCH`) → `force_recal_i` (`calibrator_v2:529`). Whether a forced recal clears the W2 clock-dropout wedge is still unmeasured (memory 07-19). Sev MED · Conf V (door exists) / H (efficacy) · rev2 not.
- `MIN_LOCK_DWELLS=2` (`:296`), `HOLD_CYCLES = 8*128*64 = 65536` RX word clocks (`:311`, ≈336 ms at the KR260 /16 rate), `MAX_RESWEEPS=0` (`:278`), `VALIDATION_TIMEOUT=4096` (`:340`). `S_HOLD` (`:627`) is a peer-aware park with a bounded hold; `S_CANCEL` waits for `swreset` deassert (`:626`) — no timeout, but swreset is software-owned.
- ASIC path uses the **same** v2 calibrator (`asic_v2.flist:387`) — the sticky and the W1P door both ship.

### 7.3 PHY layer (`WavD2DGpio_v2`, `WavD2DGpioRx_v2`, `WlinkGPIOPHY_v2`, `WlinkRxLinkLayer`)
- `EPOCH_ANCHOR_EN` is plumbed end-to-end (`controller:52` → `Wlink.v:76/:1396` → `WlinkGPIOPHY_v2:63/:254` → `WavD2DGpio_v2:159`) and default 0 → `SYNC_REANCHOR_EN=1` corrector is the shipping one; memory's `xfail_epoch_shipping_corrector` sentinel covers this. Not a defect; a ratify-decision.
- `WlinkRxLinkLayer.v:407 sync_resync_boundary = sync_resync & (state != 2'h1)` — the mid-long-packet abort guard (d593058) is present in the file both flists compile (`fpga_v2:339`, `asic_v2:322`).
- Header ECC: the deps `WlinkEccSyndrome.v` **is the bypass** (`deps:299-301` `corrected=0; corrupted=0; corrected_ph=ph_in`); the local override restores the real syndrome (`local:299-318`). ASIC v2 compiles the local one (`:253`) → **header ECC is live in the synthesis flist**; ASIC v1 (`:135`) would ship the bypass. Memory's "header ECC BYPASSED in the shipping ASIC (TL-006)" is therefore true only for the V1 composition. Sev LOW (state it in the freeze manifest) · Conf V.
- Link CRC defaults (see §4 A6): FPGA AXI nodes OFF, ASIC AXI nodes ON, node 6 ON both. `crc_corrupt` is a live Mux else-arm (memory 07-19 correction) so clearing bit[16] at runtime restores checking on FPGA.
- `swi_delay_cycles` POR 0 (`Wlink.v:2674`) = tdif-04 PSTATE-deadlock escape; consequence chain (tx_en≡1 → postcount never 0 → idle beacon dead) unchanged.

### 7.4 One-shots that cannot re-arm (inventory, all Conf V)
| One-shot | Where | Re-arm path |
|---|---|---|
| `calibrated_once_q` | calibrator v1 `:652-660`, v2 header | POR only; W1P door bypasses it (`force_recal_i`) |
| `auto_anchor_done_q` | controller `:5000-5038` | `swi_training_mode_rise` only (`:4999`) |
| `autonomy_retire_q` | controller `:1427-1429`, `:4946` | per training episode |
| `socl_l7_real_crc_seen` (node 6 only after WIP) | `_6:646-648` | reset only — this is TL-035 on `_6` (§3.2) |
| `socl_l7_reached_link_data` | FCSM `:1031-1040` | reset only (by design — bring-up forgive must not re-arm) |
| `role_lock_reg` (W1S) | controller `:673` | POR only (by design; mutual clock enable) |

---

## 8. PTP (`tidelink_ptp.sv` 568 l, `tidelink_ptp_servo.sv` 713 l, `tidelink_phc_cdc.sv` 504 l, `wlink_wlink_ptp_tl_a2l_48x4.v`)

All three are in the ASIC v2 flist (`:75-78`); `STUB_PTP/STUB_SERVO` default 0 (`tidelink_top.sv:114-116`), so the real blocks ship. The APB "mailbox not RO" defect from memory is **fixed on main**: `tidelink_top.sv:973-988 mbox_reg_write_fc_only = mbox_reg_write && fc_cfg_apb_active` feeds the servo (`:2484`), and the peer's ASIC sweep lists `v2_mbox_apb_writeprotect PASS`. What follows is what is still wrong.

**8.1 — Servo cannot converge from |offset| > 1 s; phase step corrects only nanoseconds and uses the LOCAL seconds.** Sev HIGH · Conf V · Effort M · rev2 not.
- `SUB_COMPUTE_1/2` compress the seconds difference to −1/0/+1 and set `sec_diff_*_ovf` when |Δsec| > 1 (`:524-536`, `:545-557`); in the ovf case `d_fwd_r`/`d_rev_r` are NOT adjusted (`default:` arms `:559-564`, `:572-577`) so `offset_r` is a nanosecond-only garbage value.
- `needs_phase_step_r` is set at `:566`/`:590` and **never cleared** (writers: `:443` reset only — `grep -n needs_phase_step_r`): after one overflow every later exchange takes the phase-step branch forever and the PI loop is never entered.
- The step itself (`:611-614`): `phc_hw_set_seconds <= sub_t2_sec; phc_hw_set_nanoseconds <= sub_t2_ns - offset_r[29:0];` — seconds = the subordinate's own t2 seconds (never the master's), and the ns subtraction has no borrow/carry: `t2_ns < offset` underflows to a value ≥ 1e9, a negative offset can push it past 999,999,999. Either way the PHC is written an invalid nanosecond field, and a subordinate that starts > 1 s away oscillates in phase-step forever with the seconds never corrected.
- Fix direction: keep full 48+30-bit t1..t4, compute offset as a 79-bit signed (sec,ns) pair (or at least carry the ±1/ovf seconds into the step: `set_seconds = t2_sec - sec_offset`, normalise ns with borrow), clear `needs_phase_step_r` on every exchange, and enter the PI branch only when the seconds match. Prove: the sync UVM/cocotb env with the subordinate PHC pre-set 5 s and 0.5 s away; expect lock in N exchanges, currently never / invalid ns.

**8.2 — No timeouts in either servo FSM; untagged mailbox.** Sev MED · Conf V · Effort S · rev2 not. `GM_WAIT_DREQ_RX` (`:294-297`), `SUB_WAIT_DREQ_TX` (`:482-485`), `SUB_WAIT_T1` (`:494-497`), `SUB_WAIT_T4` (`:506-509`) wait forever; a lost SYNC/DELAY_REQ short packet (no CRC on short packets) or a lost SIDEBAND word leaves both ends parked until software toggles `SERVO_CTRL` (`:277`, `:460`). The mailbox is three registers with "NS write = complete" (`:233-246`); T1 vs T4 are distinguished only by order (`:494-516`), so one lost word swaps them silently. Add a per-state timeout (reuse `hw_sync_interval_r`), a T1/T4 tag bit in the SIDEBAND offset, and a sequence number.

**8.3 — Probable stale-timestamp race between servo capture and the PHC CDC.** Sev HIGH if real · Conf P · Effort S to prove · rev2 not. `GM_CAPTURE_T1` samples `hw_cap_seconds/ns` one clock after `sync_tx_done` (`:283-291`); `SUB_CAPTURE_T2` likewise (`:466-475`). The capture pulse leaves `tidelink_ptp` combinationally (`:322`), crosses `tidelink_phc_cdc` Path 4 (toggle req/ack, `:187-225`) into phc_clk, the PHC latches, then Path 1 brings the value back only on `cap_done_pulse_h` (`:239-270`): ≥ 4-6 clocks in CDC mode, ≥ 2 even with `BYPASS_CDC` (`:112-122`). So the servo latches the **previous** event's timestamp. Prove: in the existing servo bench compare `gm_t1_sec/ns` against the PHC `HW_CAP_*` after the first SYNC; expect a one-event lag. Fix: wait for `cap_done` (export the pulse from the CDC) before `*_CAPTURE_*`.

**8.4 — Un-reset control flops in the servo.** Sev LOW-MED · Conf V · Effort S · rev2 not. `mul_start`, `mul_a`, `mul_b`, `pi_p_term_r` are written only in the FSM (`:631-633`, `:640-646`, `:652`) and are absent from the reset branch (`:431-454`). In simulation `mul_start` is X until the first `SUB_ADJUST`; `tidelink_mul_iter.sv:64` gates on `start && !active_r`, so an X `start` X-propagates `active_r`/`done` in RTL sim (VCS may resolve optimistically) and, on silicon, a random-1 `start` at reset runs one bogus multiply — harmless only because the FSM does not look at `done` until it has issued its own `start`. Reset them.

**8.5 — `current_frac_r` wraps modulo 2^32 (`:654-656`).** Sev LOW-MED · Conf V. `current_frac_r - (P + I)` has no clamp; a large correction can wrap the frequency word from 0 to 0xFFFF_FFFF (`phc_hw_adj_ns_incr_frac`), i.e. a step of one full ns/cycle in the wrong direction. Saturate. Gains are Q0.32 (`:35-36`); `mul_result[63:32]` (`:642`, `:654`) yields ns-valued P/I terms subtracted directly from a ns-fraction increment register — the loop gain is therefore proportional to phc_clk frequency and the PHC's increment scaling; tunable, but the defaults (0.7/0.3) were never validated on hardware (F13 HIGH in memory stands).

**8.6 — `tidelink_ptp` AHB write port can stall the bus indefinitely.** Sev MED · Conf V · Effort S · rev2 not. `ahb_ptp_hreadyout` is 0 in `TX_WAIT_IDLE`/`TX_SEND` (`:282-283`); `TX_WAIT_IDLE` leaves only on `tx_router_idle || hw_sync_force_en_r` (`:260`) — its own comment says LP-state frames "hold link_idle low for long bursts … can deadlock the PTP TX path". The PTP_CTRL clear bit only clears `tx_pending_r` (`:235-237`), not `tx_state_r`, so software cannot release a stalled AHB. Bound the wait (or return `hresp=ERROR`), and make the clear bit reset the FSM.

**8.7 — Shared capture pulse.** Sev LOW · Conf V. `phc_hw_capture = tx_handshake | rx_accept` (`:322`): a TX handshake and an RX accept in the same hclk produce one capture for two events; the servo's sequential protocol makes this unlikely, the SW-driven path does not. Serialise or dual-bank.

**8.8 — RX back-pressure while PTP is disabled.** Sev LOW · Conf P. `ptp_sp_rx_accept = ptp_sp_rx_valid & ptp_enable_r` (`:292-294`) → with PTP disabled the short-packet RX (`ShortPacketToWlink.v:67`) is never accepted; whether that stalls the Wlink short-packet channel or drops depends on `ShortPacketToWlink`'s FIFO discipline (not traced here). Prove by sending a SYNC with `ptp_enable=0` and watching the SP RX FIFO occupancy.

**8.9 — What is actually verified.** `tidelink_phc_cdc` handshakes are textbook and sim-covered (`flists/tidelink_phc_cdc.flist` unit env). Memory (07-19/21) proves the *ha1588→PHC* servo hop in the ethernet subsystem — that is a different servo (`ha1588_servo`), not `tidelink_ptp_servo`. For **this** servo the only evidence I can see is unit-level cocotb (`sim_gate` wires "PTP link-sync", `c3a34069`) with a tied-off or idealised PHC; no two-board convergence, no hardware. F13 HIGH stands, and 8.1/8.3 say the block would not converge in the field even if the link were perfect.

---

## 9. Link-clock divider (`tidelink_link_clk_div.sv` 207 l, `tidelink_link_rate_regs.sv` 621 l; commits `001b231d`..`e4a4c36b`)

**Status on main**: in all three flists (§1). Memory says it was deliberately kept off main on 08-19; the fold landed via `033a0880`/`e4a4c36b` and is now on `origin/main`. rev2 does not touch it.

### 9.1 RTL correctness — sound (Conf V)
- Ratio CDC (`:86-115`): 3 flops + adopt-on-two-equal-post-sync-samples (the `e2491436` fix; the old form compared the stage-1 flop). Correct for a quasi-static input.
- Clamp `>4 → 4` (`:119`); divider (`:143-158`) uses `>=` so a shrinking ratio cannot strand the counter; `clkdiv_r` free-runs so bypass↔divided is reversible (`:126-129`).
- Handover (`:172-195`): two enables, each retimed through 2 flops on the **falling edge of its own clock** and gated by the other leg being off; `clk_out = (clk_in & byp_en_r) | (clkdiv_r & div_en_r)` (`:203`). Enables only change while their clock is low and are mutually exclusive → no runt, no merge. Standard glitch-free clock mux; correct.
- Reset: async assert with `byp_en=1, div_en=0` (`:179-180`, `:189-190`) → clock passes during reset (the PHY's reset synchronisers need it). `RATIO_RESET=3'd0` at the instance (`tidelink_top.sv:2998`), `rst_n=poresetn` (`:3003`), so a warm reset cannot retime a running link (and `link_rate_regs` keeps `ratio_req_r` in the POR scope for the same reason, `:419-471`).
- Default behaviour: at /1 the output is combinationally `clk_in` through one AND-OR — same topology as before plus one gate of insertion delay, as the commit message says.

### 9.2 Chip-interface consequences — NOT closed
**9.2.1 — New top-level port `link_clk_div_ratio_i[2:0]` (`tidelink_top.sv:388`) is unconnected in both wrappers.** Sev HIGH · Conf V (by grep) · Effort S · rev2 not. `grep -rn link_clk_div_ratio_i --include=*.v --include=*.sv --include=*.tcl --include=*.yaml .` hits only `tidelink_top.sv`, `tidelink_link_clk_div.sv` and four cocotb benches; `src/rtl/asic/tidelink_dft_wrapper.sv` and `fpga/vivado_ip/tidelink_vivado_wrapper.v` (both instantiate `tidelink_top`) do not name it. With `LINK_RATE_REGS_PRESENT=0` (default, `:258`) the port IS the divider's ratio (`:3117 link_ratio_sel_w = link_clk_div_ratio_i`). In simulation an unconnected input floats to Z → the equality adopt never fires → `ratio_r` holds 0 (safe by accident, exactly the "X-safe" claim). In synthesis an undriven input is a floating net on a clock-select path: FC will either tie it or flag it, and the DFT wrapper is the ASIC top. Tie it to `3'b000` in both wrappers now (or set `LINK_RATE_REGS_PRESENT=1` and drive it from the bank), and record the port in the chiplet boundary spec (the commit message itself asks for this).
**9.2.2 — No timing constraints for the divided leg.** Sev MED · Conf V · Effort S. `syn/asic/fusion-compiler/inputs/constraints.sdc` declares `user_ref_clk` at the port (`:90`) and `pad_clk_tx_fwd` as `-source [get_ports user_ref_clk] -divide_by 1` (`:102-104`). No `create_generated_clock` for `clkdiv_r`, nothing for the negedge-clocked enables (`:177-195`), no `set_dont_touch`/clock-cell mapping directive for the AND-OR the header asks for (`:197-202`). The file the header points to (`ASIC/genus-innovus/inputs/tidelink_constraints.sdc`, `:202`) **does not exist** (`test -d ASIC/genus-innovus` → no). At /1 STA still resolves through the AND-OR; the moment a divided ratio is selected the design is unconstrained, and the negedge flops are unconstrained at any ratio. Add: generated clock on `clkdiv_r` (divide_by 2/4/8/16 as a set of mode-dependent clocks or a worst-case one), `set_clock_groups` treatment for the muxed output, `set_case_analysis`/`set_dont_touch` on `u_link_clk_div`.
**9.2.3 — DFT.** Sev MED · Conf P · Effort S. Negedge flops on the clock path and a flop clocked by the generated `clkdiv_r` (`:187`) must be excluded from scan chains or given scan-mode bypass; `scan_mode` forces `/1` (`:172`) but the flops still exist in the netlist. Confirm `syn/asic/dft/` handles them (not traced here).
**9.2.4 — Semantics that the rest of the link silently depends on.** `io_tx_clk` (FCSM word clock) = hsclk/16 scales with the ratio: the TL-035 threshold, Fix-E `SOCL_REACK_THRESHOLD`, `HOLD_CYCLES` (RX side follows the peer's pad clock, so it scales with the *peer's* ratio), `tidelink_clkfreq_check`, and the rate at which the 1.31 s autoneg timeout would be consumed by CR/CRACK emits. None are documented as ratio-dependent. LOW.
**9.2.5 — Asymmetric ratios.** Each die's RX follows its peer's forwarded clock, so die A at /4 and die B at /1 is electrically legal; the credit/ACK loop then has a 4:1 asymmetry never exercised (the pair benches ran symmetric `/1../16`, `21d19f8a`, `82404660`). Bound it in the register spec (or add a peer-ratio handshake via the mask/lane handshake) before enabling in the field. LOW-MED · Conf H.

---

## 10. Prioritised bug / hazard list

| # | Item | Sev | Conf | Effort | rev2 | Fix direction | Prove |
|---|---|---|---|---|---|---|---|
| 1 | ASIC AXI FC nodes ship CRC ON with zero `socl_` recovery; ASIC-sim wedges at state 7 (§4, F4.1) | BLOCKER | V | M | not | re-point `asic_v2.flist:315-319,:263` to local overrides (+ A5/A8), run `ASIC_FLIST=1` sweep | peer `l7_starvation_ab` on the re-pointed flist → both arms ESCAPE |
| 2 | PTP servo: sticky `needs_phase_step_r`, seconds never corrected, ns underflow (§8.1) | HIGH | V | M | not | full (sec,ns) offset arithmetic, clear flag per exchange | servo bench with PHC 5 s / 0.5 s off |
| 3 | Divider port `link_clk_div_ratio_i` unconnected in DFT + Vivado wrappers (§9.2.1) | HIGH | V | S | not | tie 0 / drive from bank; boundary spec | `grep link_clk_div_ratio_i src/rtl/asic fpga/vivado_ip` non-empty |
| 4 | Part-B forced state-7 exit leaves `sop` asserted → stale NACK re-emission (§2.4) | HIGH (FPGA) | V/P | S | not | `_GEN_114` also clears on `force_clear`; make Part-B opt-in | l7_starvation bench: count NACK-id packets in state 4 after release |
| 5 | Replay window 8-deep, no timeout (TL-042 H1) (§6.3.1) | HIGH | V | M | not | outstanding-age watchdog + sticky error | awready-stall bench with ACKs forced off |
| 6 | Servo stale-timestamp race vs PHC CDC (§8.3) | HIGH? | P | S | not | wait for `cap_done` before `*_CAPTURE_*` | compare `gm_t1` vs PHC `HW_CAP` after first SYNC |
| 7 | `fe_tx_credit_max` enable-dip re-zero on all 5 AXI nodes (§3.1) | MED | V/P | S | not | port `_6:1370-1398` | pulse 0x208 bit0 low post-CR/CRACK, watch `exp_pkt_num` wrap |
| 8 | TL-035 watchdog absent from `_6` (§3.2) | MED | V | S | not | apply Part-A to `_6` | `test_wdog_arming_forced_stall` on node 6 |
| 9 | Servo/PTP FSMs without timeouts; untagged T1/T4 mailbox; AHB stall (§8.2, 8.6) | MED | V | S | not | per-state timeouts, tag bit, clear resets FSM | drop one SIDEBAND word / hold `tx_router_idle` low |
| 10 | No SDC for `clkdiv_r`/negedge interlock; cited SDC file missing (§9.2.2) | MED | V | S | not | generated clocks + dont_touch | `read_sdc` + report_clocks shows the divided clock |
| 11 | Hazard-3 beacon inert under severe skew (fail-closed residual) (§6.3.4) | MED | V | M (HW) | not | ≥10-cycle HW campaign; consider a fallback force after N idle-less seconds | KR260 pair campaign, `io_link_tx_tx_idle` ILA |
| 12 | `calibrated_once_q` one-shot; W1P door unproven against W2 (§7.2) | MED | V/H | S | not | measure forced recal vs clock-dropout | error-injection W2 rung with `SWI_FORCE_RECAL` |
| 13 | RX capture-clock placement race has no ASIC-side constraint (§6.3.5) | MED | P | S | not | balanced capture-clock CTS constraint | post-CTS skew report on the 8 capture clocks |
| 14 | `FCReplayV2_13` lacks TL-032 rewind (§3.3) | LOW-MED | V | S | not | port `_1:166-168` | `_1` revert test at NODE=13 |
| 15 | Servo un-reset `mul_*`/`pi_p_term_r`; `current_frac_r` wrap (§8.4, 8.5) | LOW-MED | V | S | not | reset + saturate | X-check at reset; large-offset sim |
| 16 | Autoneg FIN states rely on winscan timeout; `ST_ERROR` terminal (§7.1) | LOW-MED | V | S | not | SVA on the cross-FSM dependency; SW-visible error + re-arm | inject a peer that never writes FINALIZE_GO |
| 17 | `mark_debug` in ASIC-sourced RTL (§6.3.2) | LOW | V | S | not | `` `ifdef FPGA_DEBUG_ILA `` fences | `grep -c '(\* mark_debug' $(asic flist files)` = 0 |
| 18 | `TL-033` label vs registry TL-035 (§2.6) | LOW | V | S | not | rename in 5 files | grep |
| 19 | WIP controller ILA counter is real logic (14 flops) in the ASIC flist (§2.2) | LOW | V | S | not | fence or accept | synth report: no `dbg_a2l_*` cells |
| 20 | AR/R (`_7/_9`) self-heal not in ASIC flist on rev2 (§4 A8) | MED | V | S | partial | re-point `asic_v2.flist:306/:308` | `a2l_replay_cdc` NODE=7/9 with ASIC flist |

rev2 tags for the four in-scope rev2 commits: `e88ff7be`/`bf813a74` (AR/R overrides, FPGA flist) = **partial** for item 20 only; everything else in this review is **not** addressed on rev2 (`git diff 5e8bdb5a cba9774d --stat` on the reviewed paths shows only `_7.v`, `_9.v`, two `a2l_replay_cdc_{7,9}` flists, `xhb500_bridge_unit.flist`, and a 4-line FPGA flist change).

---

## 11. Re-develop for the next iteration

| Task | Why | Touches | Effort |
|---|---|---|---|
| **R1. One parameterised FC-node FSM** (`WlinkGenericFCSM #(RX_W, APP_W, ADDR_W, DATA_ID, CR_ID, CRACK_ID, ACK_ID, NACK_ID)`) with every `socl_` feature as a named parameter (`RECOVERY_L6_L7`, `WDOG_PARTA`, `WDOG_PARTB`, `REACK`, `CREDIT_MAX_HOLD`, `CRC_DEFAULT_ON`) | §3: five clones differ only in parameters; §3.1/3.2 show fixes landing on one twin and not the others; §4 shows the ASIC/FPGA split is a flist accident | `local_overrides/WlinkGenericFCSM*.v` (collapse to 1), `WlinkGenericFCReplayV2_*` (→1 param'd), `WlinkGenericFCReplayAddrSync*`, `WavMultibitSync*`, `WavFIFO_*`, `WlinkCrcGen_*`, `Wlink.v` instances, all 4 flists, `verify_fix_delivery.sh` | L (Verilog) / M if done in Chisel (`wav-wlink-hw/src/main/scala` FC.scala + regenerate) |
| **R2. Vendor Wlink as a patched submodule**, not forked copies: carry the SoC-Labs changes as Chisel patches (or a `patches/` series applied to `deps/axi-chiplet-controller` at build), regenerate, and make `flists/*` point at ONE generated tree for both targets | §1: 8 shadow pairs, 6542 SLOC behind them (peer's `flist_divergence.txt`); the ASIC/FPGA divergence is the root of item 1 | `deps/axi-chiplet-controller`, `Makefile` regen target, all flists, `docs/SIM_GATE_COVERAGE.md` (ASIC_FLIST tier) | L |
| **R3. Single bring-up FSM spec with explicit timeouts** — one document + one SVA bind file covering autoneg, winscan, calibrator, FCSM CR/CRACK and the AUTO_ANCHOR beacon, every state either has a bounded exit or is declared terminal-with-SW-visibility | §7.1 cross-FSM liveness dependency, §7.4 one-shot inventory, §6.3.4 residual | `tidelink_autoneg.sv`, `axi_chiplet_controller.sv` (winscan/anchor), `tidelink_phy_align_calibrator_v2.sv`, new `verif/sva/bringup_liveness.sv`, `docs/AUTONOMOUS_BRINGUP.md` | M |
| **R4. Replay-node outstanding-age watchdog + error response** (closes TL-042 H1 by design) | §6.3.1 | `WlinkGenericFCReplayV2` (param'd), FCSM tx arm, XHB500 error-response path in `tidelink_top.sv`, obs regs | M |
| **R5. PTP servo v2**: 79-bit offset arithmetic, per-state timeouts, tagged/sequenced mailbox, `cap_done`-synchronised capture, reset all control flops, saturating frequency word, gain units documented in ns/cycle; then a two-instance convergence bench with a real PHC model | §8 | `tidelink_ptp_servo.sv`, `tidelink_ptp.sv`, `tidelink_phc_cdc.sv` (export `cap_done`), `tidelink_top.sv`, `cocotb/` servo env | M |
| **R6. Divider integration closure**: wrappers, boundary YAML, SDC generated clocks, DFT exclusion, ratio-dependent-timer documentation, peer-ratio handshake or a documented symmetric-only rule | §9 | `src/rtl/asic/tidelink_dft_wrapper.sv`, `fpga/vivado_ip/tidelink_vivado_wrapper.v`, `syn/asic/fusion-compiler/inputs/constraints.sdc`, `syn/asic/dft/`, `docs/D2D_RATE_CONTROL_ARCH.md` | S-M |
| **R7. CRC/ECC policy as a single parameter** surfaced at `tidelink_top` (`LINK_CRC_DEFAULT_ON`, `HEADER_ECC_EN`) with a sim tripwire that fails if FPGA and ASIC flists disagree | §4 A6, §7.3 | FCSM (R1), `WlinkEccSyndrome.v`, flists, `sim_gate` | S (after R1) |
| **R8. Observability hygiene**: fence all `mark_debug` behind one macro; add `fe_tx_credit_max`/`exp_pkt_num` obs taps; drop dead obs regs | §6.3.2, §6.3.3 | `axi_chiplet_controller.sv`, `tidelink_fc_adapter.sv`, FCSM obs ports | S |

---

## Appendix — evidence commands (all run in `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a` unless noted)
- `git rev-parse HEAD` → `5e8bdb5a…`; `git show 52c06677 --stat`; `git show 52c06677 -- <6 files>`; `git diff 52c06677 b0c75918 -- src/rtl/local_overrides/{WlinkGenericFCSM.v,WlinkGenericFCSM_1.v,axi_chiplet_controller.sv}`.
- Flists: `grep -n -E '^\$\{TIDELINK_HOME\}.*(WlinkGenericFCSM|FCReplay|MultibitSync|EccSyndrome|…)' flists/{tidelink_fpga_v2,tidelink_top_full_asic_v2,tidelink_top_full_asic}.flist`; `sed -n 25,60p syn/asic/common.mk`; `grep -n -E '_v2|FLIST' syn/asic/fusion-compiler/Makefile`.
- Copies: `diff <(sed 's/WlinkGenericFCSM_N/X/' _N.v) <(sed 's/WlinkGenericFCSM_1/X/' _1.v)` for N∈{0,2,3,4}; `diff deps/…/WlinkGenericFCSM.v local/…/WlinkGenericFCSM.v`; `for f in FCSM{,_1..6}: grep -c socl_ deps/$f local/$f`.
- CDC: `diff deps/…/{WavMultibitSync_18,WlinkGenericFCReplayAddrSync_18,WlinkGenericFCReplayV2_{1,3,5,12,13}}.v local/…`; `grep -n -iE 'timeout|wdog' local/WlinkGenericFCReplayV2_*.v` → 0.
- Router: `grep -n -E 'advance|_sop' deps/axi-chiplet-controller/logical/wlink/WlinkTxRouter.v`.
- Divider: `cat -n src/rtl/tidelink_link_clk_div.sv`; `grep -rn link_clk_div_ratio_i --include=*.v --include=*.sv --include=*.tcl --include=*.yaml .`; `grep -n -iE 'link_clk_div|clkdiv|create_generated_clock' syn/asic/fusion-compiler/inputs/constraints.sdc`; `test -d ASIC/genus-innovus`.
- PTP: `cat -n src/rtl/tidelink_ptp.sv src/rtl/tidelink_ptp_servo.sv src/rtl/tidelink_phc_cdc.sv`; `grep -n needs_phase_step_r src/rtl/tidelink_ptp_servo.sv`; `grep -n -E 'mbox_reg_write|BYPASS_CDC|hw_cap' src/rtl/tidelink_top.sv`.
- mark_debug: `grep -rn -E '\(\*\s*mark_debug' src/rtl | awk -F: '{print $1}' | sort | uniq -c`.
- rev2: `git log --oneline origin/main..origin/rev2/integration -- src/rtl/local_overrides src/rtl/tidelink_link_clk_div.sv src/rtl/tidelink_link_rate_regs.sv src/rtl/tidelink_ptp*.sv src/rtl/tidelink_phc_cdc.sv flists/`; `git -C rev2-final diff 5e8bdb5a HEAD --stat -- <paths>`; greps of `_GEN_115`, `fe_tx_credit_max <= 8'h0`, ASIC flist FCSM lines in `rev2-final`.
- Peer evidence read: `$WORKTREES/SoCLabs/td-bisect/asicsim-2026-08-26/{l7_starvation_ab_SUMMARY,fcsm_ab_SUMMARY,flist_divergence,sweep_asic_SUMMARY,coverage_run_SUMMARY}.txt`.
- Memory files consulted (hints only; every claim above re-verified in code): `project_tl027_winc_cdc_tearing_proven_all_nodes_2026_08_24`, `project_fcsm_gen115_conflict_unresolved_2026_08_17`, `project_hazard3_n2_autoanchor_corrected_2026_08_18`, `project_beacon_fix_cand1_verified_cand2_hw_deploy_2026_08_10`, `project_z2_no_data_rootcause_beacon_starves_corrector_2026_07_30`, `project_role_lock_is_a_mutual_clock_enable_2026_07_24`, `project_tidelink_ptp`, `project_ethernet_ptp_chain_phc_hop_broken_2026_07_18`, `project_tapeout_risk_recheck_f09_f12_f13_f19_2026_07_31`, `project_link_crc_disabled_by_default_2026_07_18`, `project_no_firmware_phy_retrain_calibrated_once_2026_07_18`, `project_a2b_rootcause_fe_tx_credit_max_2026_07_09`.


---

# PART 4 Verification and validation

# TideLink — Testing, Verification and Validation review

Review tree: `origin/main` = `5e8bdb5a` at `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a` (all `file:line` cites are relative to it unless prefixed).
In-flight next iteration: `origin/rev2/integration` = `cba9774d` (59 commits ahead) at `$WORKTREES/SoCLabs/td-bisect/rev2-final`.
Peer work I cite and do NOT redo: `rev2-final/docs/FALSE_GREEN_REGISTER.md` (354 lines, ~49 diagnostics, Tier 0-2) and the coverage baseline at
`$WORKTREES/SoCLabs/td-bisect/coverage-2026-08-26/` (`README.md`, `FINDINGS.md`, `bench_support_gap.txt`, `gate_vs_wholerepo.txt`, `logs/bench_sweep.log`).
Static review only: I ran **no** simulation, elaboration, lint, `make -n`, board or ssh command. Every "last run" claim below is a timestamped artifact on disk.
Severity: S1 = would let a defect ship / a green that cannot be trusted; S2 = blind spot; S3 = hygiene. Effort S/M/L.

---

## 0. Executive verdict (read this if nothing else)

1. **There is no automated gate on `origin/main` today.** `origin` is GitHub (`git remote -v`), the repo has no `.github/` (verified), `.gitlab-ci.yml` clones from `$CI_REPOSITORY_URL` (`.gitlab-ci.yml:126`) i.e. the GitLab remote, and `gitlab/main` is `9092300b` (2026-07-23), **293 commits behind** `origin/main` (`git rev-list --count gitlab/main..origin/main` = 293, reverse = 0). The `sim-gate` job (`:364-392`, `allow_failure: false`) has never run against any commit newer than 07-23; the peer measured 0 pipelines/0 MRs on that server. `install-git-hooks` (`Makefile:1961`) only delegates to an external toolkit installer and is documented "NOT run automatically and NOT run by CI". **"Gated" in this repo means "run by whoever remembers"** — and rev2 does not change this (rev2 touches `.gitlab-ci.yml` by +103 lines, still no `.github/`).
2. **`make sim_gate` on a clean checkout of `5e8bdb5a` cannot report PASS.** The `a2l_replay_cdc_{1,3,5}` targets rewrite three *tracked* files every invocation (`cocotb/tidelink_a2l_replay_cdc/Makefile:65` `$(shell echo "$(DUT_SRC)" > $(DUT_SRC_F))`, tracked per `git ls-files`), so `GATE_DIRTY` (`Makefile:253`) flips `clean`→`dirty` mid-run. Evidence: the 08-25 run in `imp/sim_gate/` has 22 statuses stamped `5e8bdb5a2141-clean` and 36 stamped `5e8bdb5a2141-dirty`; `git status --porcelain` in the review tree shows exactly those 3 files modified. `sim_gate_summary` then refuses PASS (`exit 2`, `Makefile:1755-1759`). Memory records the workaround (`git update-index --assume-unchanged`), i.e. the anti-false-green stamp is defeated by the gate itself. **Still present on rev2** (`rev2-final/cocotb/tidelink_a2l_replay_cdc/Makefile:22-46`, now 5 nodes).
3. The last real gate run on the review tree (08-24/25, 59 statuses, ~83 min summed + ~11 min of duplicate re-runs) is **55 PASS / 2 FAIL / 3 XFAIL**; the 2 FAILs are `tc_pair_smoke` and `tc_pair_election_datamode` — real assertion failures (`imp/sim_gate/tc_pair_election_datamode.log`: `FCSM m=-1 s=-1`; `tc_pair_smoke.log`: `Cannot convert Logic('X') to int` at `test_tc_pair_smoke.py:195`), not the CHIPLET_HOME dependency abort. They also FAIL on the rev2 coverage run (`coverage-2026-08-26/sim_gate/tc_pair_*.status`). This is the standing red that the Makefile itself warns "is how a real red gets waved off" (`Makefile:1093-1101`).
4. **The datapath the chip ships has never been simulated as a system**: peer coverage shows `xhb500_axi_to_ahb_bridge_chiplet_mst_core_xin` FSM 0.00% on both dies (`FINDINGS.md`) and every bench in this tree drives `HBURST=0/HPROT=0` (34 files, no INCR anywhere in `cocotb/` outside `debug/`). The UVM side adds nothing here: all 8 AHB sequence classes constrain `burst_type == SINGLE` (§7).
5. UVM is 7 envs, 61 tests, 4 quarantined `allow_failure: true` in a CI that never runs; only `tidelink_top_system` is alive on disk (built 08-24 for `sim_gate_i1_selfarm`). I found two component-level defects the peer's scoreboard sweep did not cover (§7): a by-value `wait_for_irq` that can never observe an IRQ (`uvm/tidelink_ptp_stress/sequences/ptp_sync_sequence.sv:117`) and drivers that were deliberately de-pipelined to hide a DUT race that is in no registry (`uvm/tidelink_fc_adapter/env/ahb_tx_driver.sv:51-68`, `rtn_driver.sv:50-72`).
6. Hardware: the one-command HW gate exists (`make hwtest_gate` → `pynq_host/scripts/hwtest_gate.sh`) but **no `imp/hw_gate/verdict.json` exists in any worktree** (find over `$WORKTREES/SoCLabs`) — it has never completed; its provenance check compares `source_commit` to HEAD and never reads `git_dirty` (`hwtest_gate.sh:44-49`), and the `git_dirty` fail-open fix `df0f1f24` is on **neither** `origin/main` nor `rev2/integration` (`merge-base --is-ancestor` = NO for both). The most recent trustworthy HW evidence is the 08-19 consolidation run (autonomy proven, 5000/5000 byte-exact, smoke PASS) — see §6.

---

## 1. Inventory

### 1.1 Counts
- `cocotb/`: 72 entries = 63 benches with a Makefile + `common/` + `lint/` (sv_anti_pattern + xdc lint, not a bench) + `debug/` (12 orphan sub-benches, 154 `@cocotb.test`) + 2 dirs with no Makefile (`asic_nego_cfg_plumb` = `run_proof.sh` + tb, `xhb_window_skew_debug` = one instrumentation script). Total `@cocotb.test` in the 63 benches: ~1,080; `skip=True`: 5 (all in gated benches: `test_v2_p1_gate_recovery.py:44`, `test_v2_sync_midpacket_noloss.py:47`, `test_axi_datanode_writehold.py:192`, `test_n1_read_backstop_defeat.py:488`, plus the runtime `_skip()` in `test_v2_onchip_pair.py:102` that the peer's B4 shows reports PASS at 0 ns on main — fixed on rev2 `c5141c36`). `expect_fail`: 0 outside `debug/`.
- `uvm/`: 7 envs, 61 test classes (tidelink 5, fc_adapter 5, integration 4, ptp_chain 8, ptp_stress 3, system 16, top_system 20), 15 covergroups (all in system/top_system/ptp_stress).
- `fpga/hw_regression/`: 22 scripts (soaks, preflight, zeropoke proofs, `td_v2_regress.sh`), last git touch 07-24. `fpga/farm_gate.sh` (Tier-0 ratchets + Tier-1 sim; baselines `farm_gate_sv_baseline.txt` 41 lines, `farm_gate_xdc_baseline.txt` 25 lines) — invoked by `fpga/scripts/build_farm.sh:83-88` as a pre-build precondition, and by CI jobs `farm-gate-lint`/`farm-gate-sim`.
- `pynq_host/scripts/`: ~55 scripts + `hwtest/01..14_*.sh` + `run_all.sh` + `hwtest_gate.sh`; `python/tidelink/` = `driver.py`, `packet.py`, `pair_model.py` (Python model of the peer's APB bank used by `tidelink_py_pair`), `pynq_driver.py`, `regs.py`.
- Static: `lint/` (HAL + `lint/verilator/`), `cdc/` (SpyGlass, 3 `.sgdc` + 11 KB `waiver.swl`, last touch 07-24), `xprop/` (VC Formal xprop, 14 module dirs, last touch 06-11), `ci/` (8 helper scripts), `.gitlab-ci.yml` 1,431 lines / 37 jobs.

### 1.2 What `make sim_gate` wires (main `5e8bdb5a`)
`SIM_GATE_ALL_SUITES` (`Makefile:1544-1563`) = **55 blocking suites** + 3 sentinels (`:1564`). The aggregate body (`:1599-1694`) invokes 60 distinct `sim_gate_*` targets; they touch **18 cocotb dirs + 1 UVM env** (`tidelink_top_pair_v2` 23 invocations, `tidelink_axi_datanode_recovery` 22, `tidelink_top_pair` 15, `tidelink_txgen` 4, `force_recal`/`error_injection`/`a2l_replay_cdc` 3 each, `tidelink_fifo`/`tidechart_tidelink_pair` 2, and one each of `phy_align_calibrator`, `i1_fixe_training_release`, `fifo_twin2`, `axinode_obs`, `apb_regs`, `fifo_rx_twin2`, `eth_tidelink_pair{,_m1,_shape_a}`; `uvm/tidelink_top_system` via `sim_gate_i1_selfarm` `:676`).
Defects in the wiring on main (all verified by grep of `:1599-1694`):
- **4 targets invoked twice**: `sim_gate_v2_sustained`, `sim_gate_v2_trunc_credit`, `sim_gate_fifo_twin2_tree`, `sim_gate_axi_datanode_gaps` (~11 min wasted; second run overwrites the first `.status`). The 07-30 audit removed two of these; they are back. **Fixed on rev2** (no duplicates in `rev2-final/Makefile`).
- **`sim_gate_fifo_twin2` invoked but `fifo_rx_twin2` is not scored** (`:1439` writes it; absent from `:1544-1563`). The Makefile comment says this is deliberate because the bench pinned a stale fork of the FIFO RTL (`:1420-1437`) — but that comment is itself stale: `cocotb/fifo_rx_twin2/Makefile:8-27` now defaults to `FIFO_SRC=tree` (real `src/rtl/fifo/*.sv`; the PATCHED copies are deleted) with an `unfixed` arm as a must-fail control. It consumes 7 s, prints a green line nobody reads, and its control arm is never run.
- Peer B6 (`rev2` history): the commit that added `a2l_replay_cdc_7/_9` invoked-but-unscored them; **fixed on rev2 `abe7fcaf`** with a guard.
- 19 `sim_gate_*` targets are defined but NOT invoked by the aggregate: `t33` (3.5 h nightly), `v2_mask_hs_bilateral` (superseded by the `v2_mask_hs_regress` sentinel), `nack_wedge_sustained`, `xhb`, `xfail_i5_ahb_legal`, `xfail_i5_clean_drop` (both retired into `axi_datanode_gaps`), and the 5 "rescued, never triaged" parked targets `fc_adapter_rx_saturation`, `fifo_concurrent_race`, `txgen_deadtime`, `v2_lane_mask_throughput`, `v2_fc_contiguous` (`:610-624` explains why) — plus the 8 driver targets (`env_check`, `clean_builds`, `quick`, `summary`, `inventory`, `one`, `registry_coverage`, `regressions`).
- **Phantom targets**: `sim-repro` / `sim-repro-skid3` (`Makefile:99-110`) run `cocotb/wlink_pair`, which does not exist (it is `cocotb/debug/wlink_pair`); CI job `cocotb-wlink-pair` (`.gitlab-ci.yml:777`) has the same dead path (`allow_failure: true`). `sim-regression` (`:133`) runs the whole `tidelink_top_pair` bench with a docstring that still expects `test_04/05 FAIL` as "HW-faithful" (`:117-121`) — a pre-fix contract.
- `docs/SIM_GATE_COVERAGE.md` header §2 says "(25 suites)" (`:63`) and §5 "(21 blocking suites)" (`:345`); `.gitlab-ci.yml:370` says "10 suites" and `:387` "13/13 green". Real: 55+3. Count rot, third time.

### 1.3 Definitive per-bench table (coordinator item (a))
Columns: gate wiring on main; membership of `cocotb/Makefile` `ENVS` (31 envs, run only by `make -C cocotb regression|coverage`, which only the never-running `cocotb-regression` CI job calls); GitLab job that names the bench; newest `results.xml` found in any main-era worktree (`$WORKTREES/SoCLabs/tidelink`, `td-bisect/*` excluding `rev2*`) as `date tests/pass/fail/skip`; the peer's 08-26 whole-repo sweep on rev2 `5994cce7` (`logs/bench_sweep.log` + per-bench `TESTS=` lines; "in-gate" = skipped by the sweep because the gate already ran it; NOBUILD = VCS `SFCOR`/compile error in that sweep, TIMEOUT = 20 min cap); and what rev2 adds to the gate for that bench.
| bench | DUT flist | tests | skip | in make sim_gate (main 5e8bdb5a) | cocotb/Makefile | gitlab job | last on-disk results.xml (main-era) | rev2 sweep 08-26 @5994cce7 | rev2 gate adds |
|---|---|---|---|---|---|---|---|---|---|
| asic_nego_cfg_plumb | - | 0 | 0 | NO Makefile (not a cocotb bench) | - | - | never (no results.xml) | - | - |
| crc_diag | tidelink_fpga_v2.flist | 12 | 0 | NO | - | - | 07-24 2/2P/0F/0S | PASS 2/2P/0F/0S | - |
| debug/* (12 sub-benches) | - | 154 | 1 | - | NO (orphan diagnostics) | - | - | see per-dir results.xml (May 2026) | - |
| deskew_handoff_lottery | tidelink_fpga_v2.flist | 7 | 0 | NO | - | - | 07-22 6/6P/0F/0S | PASS 6/6P/0F/0S | - |
| eth_ptp_chain | tidelink_fpga_v2.flist | 2 | 0 | NO | - | - | 07-18 1/1P/0F/0S | - NOBUILD | - |
| eth_ptp_phc_subsystem | VERILOG_SOURCES only | 5 | 0 | NO | - | - | 07-21 5/5P/0F/0S | - NOBUILD | - |
| eth_tidelink_pair | tidelink_fpga_v2.flist | 1 | 0 | YES aggregate | - | - | 08-25 1/1P/0F/0S | PASS 1/1P/0F/0S | - |
| eth_tidelink_pair_m1 | tidelink_fpga_v2.flist | 1 | 0 | YES aggregate | - | - | 08-25 1/1P/0F/0S | - NOBUILD | - |
| eth_tidelink_pair_shape_a | tidelink_fpga_v2.flist | 1 | 0 | YES aggregate | - | - | 08-25 1/1P/0F/0S | in-gate | - |
| fifo_rx_twin2 | VERILOG_SOURCES only | 3 | 0 | YES aggregate | - | - | 08-25 3/3P/0F/0S | in-gate | - |
| honest_mask_hs | tidelink_top_full_asic_v2.flist | 1 | 0 | NO | - | - | 07-24 1/1P/0F/0S | PASS 1/1P/0F/0S | - |
| tidechart_tidelink_pair | tidelink_fpga_v2.flist | 2 | 0 | YES aggregate | - | - | 08-25 1/0P/1F/0S | in-gate | - |
| tidelink | tidelink.flist | 25 | 0 | NO | ENVS | - | 07-19 25/25P/0F/0S | - 25/24P/1F/0S | - |
| tidelink_a2l_replay_cdc | VERILOG_SOURCES only | 12 | 0 | YES aggregate | - | - | 08-25 2/2P/0F/0S | PASS 6/6P/0F/0S | +_7/_9/wready_tear |
| tidelink_addr_translator | VERILOG_SOURCES only | 34 | 0 | NO | ENVS | - | never (no results.xml) | PASS 34/34P/0F/0S | addr_translator (423e41de) |
| tidelink_ahb | tidelink_ahb.flist | 23 | 0 | NO | ENVS | cdriver-regression | 07-24 17/17P/0F/0S | PASS 17/17P/0F/0S | - |
| tidelink_apb_addr_ctrl | tidelink_apb_addr_ctrl.flist | 16 | 0 | NO | ENVS | - | never (no results.xml) | PASS 16/16P/0F/0S | - |
| tidelink_apb_regs | tidelink_apb_regs.flist | 61 | 0 | YES aggregate | ENVS | - | 08-24 5/5P/0F/0S | in-gate | - |
| tidelink_autoneg | VERILOG_SOURCES only | 7 | 0 | NO | ENVS | - | never (no results.xml) | PASS 7/7P/0F/0S | - |
| tidelink_autoneg_deadi2c | VERILOG_SOURCES only | 1 | 0 | NO | - | - | never (no results.xml) | - 1/0P/1F/0S | - |
| tidelink_autoneg_rolestrap | VERILOG_SOURCES only | 2 | 0 | NO | - | - | 07-29 1/1P/0F/0S | PASS 1/1P/0F/0S | - |
| tidelink_axi_datanode_recovery | tidelink_fpga_v2.flist | 53 | 2 | YES aggregate | - | - | 08-24 1/1P/0F/0S | - 9/8P/1F/0S | +tl044_* |
| tidelink_axinode_obs | VERILOG_SOURCES only | 3 | 0 | YES aggregate | - | - | 08-24 3/3P/0F/0S | PASS 3/3P/0F/0S | - |
| tidelink_cdc_tear | tidelink_cdc_tear_l2a.flist | 2 | 0 | NO | - | - | never (no results.xml) | PASS 2/2P/0F/0S | - |
| tidelink_clkfreq_check | VERILOG_SOURCES only | 5 | 0 | NO | ENVS | - | never (no results.xml) | PASS 5/5P/0F/0S | - |
| tidelink_deskew_bubble | VERILOG_SOURCES only | 1 | 0 | NO | - | - | 06-23 1/1P/0F/0S | PASS 1/1P/0F/0S | - |
| tidelink_error_injection | tidelink_fpga_v2.flist | 35 | 0 | YES aggregate | - | - | 08-25 3/3P/0F/0S | in-gate | - |
| tidelink_eye_regs | tidelink_eye_regs.flist | 19 | 0 | NO | ENVS | - | never (no results.xml) | PASS 19/19P/0F/0S | - |
| tidelink_fc_adapter | VERILOG_SOURCES only | 63 | 0 | parked target only | ENVS | cocotb-fc-adapter | 07-03 10/10P/0F/0S | PASS 34/34P/0F/0S | - |
| tidelink_fcsm_silicon_ratio | tidelink_fpga_v2.flist | 2 | 0 | NO | - | - | 07-29 2/1P/0F/1S | PASS 2/2P/0F/0S | asic_fcsm_silicon_ratio |
| tidelink_fifo | tidelink_fifo.flist | 43 | 0 | YES aggregate | ENVS | - | 08-25 43/43P/0F/0S | in-gate | - |
| tidelink_fifo_concurrent_race | tidelink_fifo.flist | 6 | 0 | parked target only | - | - | never (no results.xml) | PASS 3/3P/0F/0S | - |
| tidelink_fifo_twin2 | tidelink_fifo.flist | 5 | 0 | YES aggregate | - | - | 08-25 5/5P/0F/0S | PASS 5/5P/0F/0S | - |
| tidelink_force_recal | tidelink_fpga_v2.flist | 10 | 0 | YES aggregate | - | - | 08-25 6/6P/0F/0S | PASS 6/6P/0F/0S | - |
| tidelink_i1_fixe_training_release | tidelink_fpga_v2.flist | 2 | 0 | YES aggregate | - | - | 08-24 2/2P/0F/0S | PASS 2/2P/0F/0S | - |
| tidelink_idelay_rx | VERILOG_SOURCES only | 3 | 0 | NO | ENVS | - | 06-25 2/2P/0F/0S | PASS 2/2P/0F/0S | - |
| tidelink_lane_deskew | VERILOG_SOURCES only | 29 | 0 | NO | - | - | 06-25 20/9P/11F/0S | PASS 3/3P/0F/0S | - |
| tidelink_link_clk_div | VERILOG_SOURCES only | 7 | 0 | NO | ENVS | - | never (no results.xml) | PASS 7/7P/0F/0S | - |
| tidelink_link_rate_regs | VERILOG_SOURCES only | 4 | 0 | NO | ENVS | - | never (no results.xml) | PASS 4/4P/0F/0S | - |
| tidelink_link_rate_regs_inert | tidelink_fpga.flist | 4 | 0 | NO | ENVS | - | never (no results.xml) | PASS 4/4P/0F/0S | - |
| tidelink_mul_iter | VERILOG_SOURCES only | 10 | 0 | NO | ENVS | - | never (no results.xml) | PASS 10/10P/0F/0S | - |
| tidelink_perf | VERILOG_SOURCES only | 15 | 0 | NO | ENVS | - | never (no results.xml) | PASS 15/15P/0F/0S | - |
| tidelink_perf_congestion | VERILOG_SOURCES only | 9 | 0 | NO | ENVS | - | never (no results.xml) | PASS 9/9P/0F/0S | - |
| tidelink_phc_cdc | VERILOG_SOURCES only | 15 | 0 | NO | ENVS | - | never (no results.xml) | PASS 15/15P/0F/0S | - |
| tidelink_phy_align_calibrator | tidelink_fpga_v2.flist | 14 | 0 | YES aggregate | ENVS | - | 08-25 1/1P/0F/0S | PASS 3/3P/0F/0S | - |
| tidelink_ptp | VERILOG_SOURCES only | 21 | 0 | NO | ENVS | cocotb-ptp | never (no results.xml) | PASS 15/15P/0F/0S | - |
| tidelink_ptp_servo | VERILOG_SOURCES only | 18 | 0 | NO | ENVS | - | never (no results.xml) | PASS 18/18P/0F/0S | - |
| tidelink_py_pair | tidelink.flist | 21 | 0 | NO | ENVS | - | never (no results.xml) | - 21/12P/9F/0S | - |
| tidelink_returner | tidelink_returner.flist | 19 | 0 | NO | ENVS | - | never (no results.xml) | PASS 19/19P/0F/0S | - |
| tidelink_rxclk_buf | VERILOG_SOURCES only | 4 | 0 | NO | ENVS | - | never (no results.xml) | PASS 4/4P/0F/0S | - |
| tidelink_system | tidelink_ahb.flist | 29 | 0 | NO | ENVS | cocotb-system(AF) | never (no results.xml) | - 25/24P/1F/0S | - |
| tidelink_top | tidelink_ahb.flist | 14 | 0 | NO | ENVS | cocotb-top | never (no results.xml) | PASS 14/14P/0F/0S | - |
| tidelink_top_pair | tidelink_fpga_v2.flist | 103 | 0 | YES aggregate (+parked: sim_gate_t33 nightly) | - | cocotb-top-pair-smoke | 08-25 1/1P/0F/0S | in-gate | - |
| tidelink_top_pair_drift | tidelink_fpga.flist | 7 | 0 | NO | - | - | never (no results.xml) | TIMEOUT NOBUILD | - |
| tidelink_top_pair_skewed | tidelink_fpga.flist | 7 | 0 | NO | - | - | never (no results.xml) | TIMEOUT NOBUILD | - |
| tidelink_top_pair_v2 | tidelink_fpga_v2.flist | 130 | 3 | YES aggregate (+parked: xhb/fc_contiguous/lane_mask_throughput/mask_hs_bilateral) | - | - | 08-25 3/1P/2F/0S | in-gate | +asic_v2_pair_data/xdie_exclusive |
| tidelink_top_pair_wordskew | tidelink_fpga.flist | 13 | 0 | NO | - | - | never (no results.xml) | - 12/5P/7F/0S | - |
| tidelink_txgen | VERILOG_SOURCES only | 12 | 0 | YES aggregate (+parked: sim_gate_txgen_deadtime(+3 in agg)) | - | - | 08-25 2/2P/0F/0S | PASS 7/7P/0F/0S | - |
| tidelink_v2_smoke | tidelink_fpga_v2.flist | 3 | 0 | NO | - | - | never (no results.xml) | PASS 1/1P/0F/0S | - |
| wav_d2d_gpio_tx | VERILOG_SOURCES only | 5 | 0 | NO | ENVS | - | never (no results.xml) | PASS 5/5P/0F/0S | - |
| wavd2d_gpiorx_clkbuf | VERILOG_SOURCES only | 2 | 0 | NO | ENVS | - | never (no results.xml) | PASS 2/2P/0F/0S | - |
| wavd2d_gpiorx_t3a | VERILOG_SOURCES only | 4 | 0 | NO | ENVS | - | never (no results.xml) | PASS 4/4P/0F/0S | - |
| wavd2d_gpiorx_t3a_off | VERILOG_SOURCES only | 2 | 0 | NO | ENVS | - | never (no results.xml) | PASS 2/2P/0F/0S | - |
| wavd2d_gpiorx_t3a_timeout | VERILOG_SOURCES only | 1 | 0 | NO | ENVS | - | never (no results.xml) | PASS 1/1P/0F/0S | - |
| xhb_window_skew_debug | - | 1 | 0 | NO Makefile (not a cocotb bench) | - | - | never (no results.xml) | - | - |

**Reading the table.** 63 benches: **18 in the aggregate**, **2 parked-target-only** (`tidelink_fc_adapter`, `tidelink_fifo_concurrent_race`), **43 not wired at all** (27 of those are in `ENVS`, 16 are in neither list: `crc_diag`, `deskew_handoff_lottery`, `eth_ptp_chain`, `eth_ptp_phc_subsystem`, `honest_mask_hs`, `tidelink_autoneg_deadi2c`, `tidelink_autoneg_rolestrap`, `tidelink_cdc_tear`, `tidelink_deskew_bubble`, `tidelink_fcsm_silicon_ratio`, `tidelink_lane_deskew`, `tidelink_top_pair_{drift,skewed,wordskew}`, `tidelink_v2_smoke`, plus 12 `debug/*`). **Last-known state of the unwired set (rev2 sweep, untriaged, may be rev2-induced or pre-existing):** red or unknown for `tidelink` (24P/1F), `tidelink_autoneg_deadi2c` (0P/1F), `tidelink_py_pair` (12P/9F), `tidelink_system` (24P/1F), `tidelink_top_pair_wordskew` (5P/7F), `tidelink_lane_deskew` (main-era 06-25: 9P/**11F**; the sweep ran only a 3-test module), `eth_ptp_chain` / `eth_ptp_phc_subsystem` / `eth_tidelink_pair_m1` (NOBUILD in the sweep — sibling-repo env; `eth_tidelink_pair_m1` is green in the gate), `tidelink_top_pair_{drift,skewed}` (TIMEOUT). 23 benches had **never produced a `results.xml` on any main-era worktree** until the peer's sweep. rev2 wires 3 of the 43 (`addr_translator`, and two new benches `xhb500_bridge`, `wlink_tx_pstate`) — **40 remain unwired on rev2**.

---

## 2. `make sim_gate` anatomy

- **Entry**: `Makefile:1599` `sim_gate: sim_gate_env_check sim_gate_clean_builds`, then `rm -rf imp/sim_gate`, then 63 sequential `$(MAKE) SIM_GATE_NONFATAL=1 sim_gate_<x>` invocations, then `sim_gate_summary` over `SIM_GATE_ALL_SUITES` + `SIM_GATE_SENTINELS`. Order: t31→t32→t30→ptp_link_sync→nack_wedge_recovery→axinode_obs→axi_datanode_{recovery,gaps}→n1→i1_{selfarm,fixe}→v2_{isolated,mbox,lostresp,auto_anchor}→v2 data/sustained/trunc/syncdet→`xfail_mask_hs`→winscan→force_recal→calibrator_wrap→a2l×3→v2_perf/reduced_lane→epoch×2→(dups)→fifo×4→v1elab→apb_preempt→fch_wdog→zeropoke→asicelab×2→dftelab→retire_plumb→lane_mask×3→txgen×4→tc×2→eth×3→(dup)→errinj→f14a→`xfail_f14b`→`xfail_epoch_shipping`→summary. Slowest: `v2_mask_hs_regress` 626 s (sentinel), `v2_winscan_fsm` 566 s, `axi_datanode_gaps` 507 s, `axi_datanode_recovery` 326 s, `t32` 295 s, `v2_autonomous_sync_detect` 296 s, `t31` 263 s, `retire_en_plumb` 262 s. Measured wall-clock ≈ 95 min (sum 5007 s over 59 statuses + 683 s of duplicate re-runs); the banner says "~40-55 min" (`:1603`); the peer's coverage-instrumented run took 2 h 47 m.
- **Per-suite recipe** `sim_gate_run` (`:258-281`): refuses to run under `make -n` (checks `MAKEFLAGS` for `n`, `:259-268`) — the "make -n writes fake PASS" trap (`:26-31` of the sim_gate comment block, reproduced 07-18) is closed *for this macro*; `sim_gate_sentinel` (`:1257-1273`) has **no `-n` guard** and `sim_gate_elab`-style targets shell out directly, so `make -n sim_gate_xfail_f14b` would still execute (not tested by me; reading the recipe). Exit codes never propagate under `SIM_GATE_NONFATAL=1`; the summary is the only verdict.
- **Provenance stamp**: `GATE_STAMP := <sha12>-<clean|dirty>` (`:252-254`), written into every `.status`, checked by the summary (`:1735-1737`, `:1751`) → `exit 2` on any foreign/stale stamp. Sound in design; defeated in practice by the a2l `dut_src_*.f` churn (§0.2) and by any sub-make started from a shell without `TIDELINK_HOME` (`tc_pair_smoke.status` from the 08-25 17:05 re-run reads `nosha-clean`).
- **`df0f1f24` (`git_dirty` fail-closed)**: on `origin/rev2/hygiene` only. NOT an ancestor of `5e8bdb5a`; NOT an ancestor of `rev2/integration` (`rev2-final/fpga/scripts/build_provenance.tcl:76` still has the `![catch{...}] && ...` short-circuit). Every FPGA manifest's `git_dirty:false` remains unverified.
- **Env trap** (memory 07-24): `sim_gate_env_check` (`:301-312`) still checks only `vcs` and `cocotb-config` on PATH, **not** `CMSDK_FPGA_SRAM_V`; without `source ./set_env.sh` every suite fails in 4-5 s with `SFCOR`. The peer's sweep reproduced exactly this signature on three benches (`sweep_eth_*.log`: `Error-[SFCOR] Source file cannot be opened`). **Not fixed on rev2** (same two checks).
- **CHIPLET_HOME / TIDECHART_HOME false-reds**: the marker-file probe + `export` (`:1088-1110`) closed the 0-s abort class on 08-14; the `tc_pair_*` reds on 08-25 are post-elaboration assertion failures (real co-sim disagreement, memory calls it tidechart_shim↔tidechart version skew) and are **still red on rev2**.
- **XFAIL sentinels** (`:1564`, contract `:1231-1256`): three, each a `grep -F` signature over the log (`xfail_f14b`: `:1309-1315`; `xfail_epoch_shipping`: `:1331-1340` with `TESTS=3 PASS=1 FAIL=2`; `v2_mask_hs_regress`: `:1795-1798`). XFAIL is printed in its own block, never as PASS; any change → XCHG → gate fails. This is the best-designed piece of the gate: it *can* go red in both directions.
- **Stale-simv guard**: `cocotb/flist_deps.mk` (`CUSTOM_COMPILE_DEPS` from flist contents) is included by 23 benches; the gate additionally globs away `sim_build*` for its own 7 dirs (`:1581-1597`). The `verif/g2_soc_pair` `build/` variant of the trap (memory 08-18) lives in the ethernet-chiplet repo, out of scope here.
- **Registry binding**: `make sim_gate_regressions` (`:1780`) = `registry_coverage.py` + gate. `docs/BUG_REGISTRY.yaml` has 42 bugs (statuses: 13 root_caused, 10 sim_proven, 7 open, 4 hw_proven, 4 fix_built, 4 deferred, 1 wontfix), 17 `in_sim_gate: true`, 6 `in_hw_gate: true`. Peer B7: 7 of the 17 skip the existence check (`registry_coverage.py:106`) — **fixed on rev2 `107b0dcd`**.
- **Is anything automated?** No. No git hook installed (`.git` is a worktree pointer; toolkit installer absent), no GitHub Actions, GitLab trunk 293 commits stale with 0 pipelines. `make sim_gate` is a manual ~95-min ritual whose last complete run on the review tree could not have printed PASS.

---

## 3. Test-quality audit (18 sampled tests/modules the gate depends on)

Method: read the assert/payload/negative-control lines of each file (cited), plus the peer's Tier-2 dead-term list where it overlaps. "Discriminating" = there is a reachable assert that fails on the defect the test names. "Distinct payload" = per-packet/per-position data, not a repeated constant. "Post-fire normal path" = after a backstop/recovery fires, the test asserts recovery state CLEARS and a subsequent normal transfer succeeds.

| # | Test (gate suite) | Discriminating? | Negative control? | Payload | Post-fire normal path? | HBURST≠0? | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | `tidelink_top_pair_v2/test_v2_pair_data.py` (`v2_pair_data`, `epoch_silicon`, `epoch_anchor_plumb`, `xfail_epoch_shipping`) | yes: cal/lock/FCSM==4 (`:42-63`), then `send_and_check` byte-compare (`:71-72`, `:82`) | only via the separate `xfail_epoch_shipping` sentinel and `test_v2_pair_epoch_negctl.py` (not in gate) | 2-word constants `0xA5A5F00D/0x0BADC0DE`, `0xDA7A0000/0xCAFEBABE` | n/a | no | OK but thin: the sustained test's own docstring says the legacy oracle "asserts only got[0], got[2], got[3] — never checks got[1]" (`test_v2_pair_sustained.py:9-10`) — word[1] (dest_addr) is unchecked here |
| 2 | `test_v2_pair_sustained.py` (`v2_pair_sustained`) | yes | no | **distinct position-encoding** `(seed<<16)|i`, sweep 2..128 (`:53-57`, `:19`) | n/a | no | **good** — the strongest data-plane oracle in the gate |
| 3 | `tidelink_top_pair/test_31_autonomous_training_exit.py` (`t31`) | yes, 32 asserts incl. fch 0x208 sequence (`:171-183`) and a byte-exact cross (`:583-592`) | 17 "control" mentions; peer lists `:515` as unproven | one 2-word constant `0xC0DE1234/0xFEED5678` | n/a | no | OK |
| 4 | `test_32_die_a_first_zombie_retry.py` (`t32`) | mostly | — | — | — | no | peer T1: `:264` assert is dead (`train_ok_seen` forced at `:260`) — the named failure is exactly what it cannot detect |
| 5 | `tidelink_a2l_replay_cdc/test_a2l_replay_cdc_1.py` (`a2l_replay_cdc_1/3/5`) | yes (`:29`, `:57` `full==0 and rdy==1`) | **exists but not run by the gate**: the must-fail arm is `USE_DEPS_DUT=1` (`:8`, Makefile `:48`) and no gate target passes it | n/a (control-plane) | n/a | n/a | **A/B present, B never executed in the gate.** rev2 `a2l_wready_tear` (memory 08-24) runs both arms on all 5 nodes with a 12/12 must-be-present control — the model to copy |
| 6 | `tidelink_fc_adapter/test_tidelink_fc_adapter.py` (parked `fc_adapter_rx_saturation`; CI `cocotb-fc-adapter`) | yes, 108 asserts, byte-level (`:1062-1067`) | no | constants (`0xF0F0F0F0`…) | n/a | no | OK unit bench; **not in the gate**, last main-era run 07-03 (10/10), rev2 sweep 34/34 |
| 7 | `eth_tidelink_pair/test_eth_relay_smoke.py` (`eth_relay_m0`) | yes: 16-word frame written via peer window, read back byte-exact (`:52-64`), 2 asserts | 1 mention | `make_eth_frame(16)` (deterministic) | n/a | no (hburst tied 0 in `tb_top.sv`) | thin (1 test, 1 frame) but discriminating |
| 8 | `tidelink_error_injection/test_ei_{sync_collision,reset_storm,credit_probe}.py` (`errinj_regressions`) | weak in-module: 8 tests / 11 asserts; the bench records defects as `VERDICT[...]` log lines by design (`Makefile:1231-1236`) | the sentinel/grep predicates ARE the control | injected patterns | `test_ei_link_glitch` asserts RECOVERS for S0 (`:1315`) | no | acceptable only because the Makefile greps exact verdict strings (`:1292-1294`); a module that "exits 0 while demonstrating a defect" must never be promoted without its grep |
| 9 | `tidelink_fifo_twin2/test_twin2.py` (`fifo_rx_twin2_tree`, scored) | yes, 20 asserts on `write_ptr`/credit invariants + byte-exact AHB-injected packet (`:134-166`, `:200-203`) | red/green script `run_redgreen.sh` exists, not run by the gate | constants | n/a | no | **good** — compiles the shipping `flists/tidelink_fifo.flist` (`Makefile:1449-1450`). The *other* twin-2 bench, `cocotb/fifo_rx_twin2` (3 tests, target `sim_gate_fifo_twin2` `:1438-1441`, writes `fifo_rx_twin2.status`, **unscored**), now defaults to `FIFO_SRC=tree` = real RTL (`cocotb/fifo_rx_twin2/Makefile:8-27`); the Makefile comment justifying non-scoring ("pins a stale fork", `:1420-1437`) is obsolete, and its `FIFO_SRC=unfixed` arm is a ready-made must-fail control that could be gated as a sentinel |
| 10 | `tidelink_txgen/test_txgen_unit.py` (`txgen_unit`) + `txgen_negctl` | yes, 17 asserts incl. EN=0 must-not-emit (`:138-143`, `:164`) | **yes** (own negctl module) | random gaps (`:9`, `:18`) | n/a | n/a (generator) | **good** |
| 11 | `tidelink_axinode_obs/test_axinode_obs.py` (`axinode_obs`) | yes, 17 asserts (`:59-88`) | 1 | n/a | n/a | n/a | discriminating for the unit, but peer C1: the field diagnostic it validates cannot latch a wedge while any other channel is active; the test stalls one channel with the other nine tied off — green on an instrument that is blind in the field |
| 12 | `tidelink_axi_datanode_recovery/test_n1_readbackstop_suppress.py` (`n1_read_backstop`) | yes: `cls=="ERROR"`, `err1_fires>0`, HRESP pulse, `synthb_fires==0` (`:298-304`); construction guards (`:352`, `:381` "CANNOT-CONSTRUCT") | 7 control mentions | constants | **not asserted in this file**: the clean read is asserted BEFORE the fault (`:276`), I found no post-fault clean-transfer assert; `:368` only checks `rd_os` did not re-arm | forced `arvalid` (bypasses HBURST) | partial — "a passing escape test is not a safety test" applies |
| 13 | `test_axi_datanode_gaps.py` / `test_axi_datanode_recovery.py` (`axi_datanode_gaps/recovery`) | yes (49 / 35 asserts, 55 / 44 recovery-clear mentions) | 5 / 13 | constants | largely yes (per-node injection then re-use) | forced AXI, hburst=0 | **good**; note 2 `skip=True` in this bench (`writehold:192`, `n1_read_backstop_defeat:488`) — SKIP, not PASS |
| 14 | `test_v2_xhb_lostresp_pipe.py` (`v2_xhb_lostresp_pipe`) | yes: stall ≥16×osr (`:243`), data (`:254`) | no | 1 const | no | no | OK; peer T4: `:262` asserts a TB-deposited value on a driverless signal (tautology) |
| 15 | `test_v2_isolated_write_dataloss.py` (`v2_isolated_write_dataloss`) | yes, with **instrument self-checks** ("far monitor disagrees with BRAM — instrument bad", `:230`, `:266`, `:326`) | 1 | data vs BRAM peek | no | no | **good pattern** (instrument-before-DUT) |
| 16 | `test_v2_perf_ctrl.py` (`v2_perf_ctrl`) | weak: counters "increase" (`:79`, `:90`) | 1 | 1 const | n/a | no | near-vacuous on values (any nonzero delta passes) |
| 17 | `tidelink_top_pair/test_zeropoke_por.py` (`zeropoke_por`) | yes, 13 asserts on POR register state + `nego_poke_seen==0` (`:146-215`) | 1 | n/a | n/a | n/a | **good** |
| 18 | `test_v2_lane_mask_sweep.py` (`v2_lane_mask_oddlane/position`) | — | — | — | — | — | peer B3: oracle self-test constant-False, passes on the all-zeros signature → **fixed on rev2 `0bad1d29`** |

**Structurally vacuous / near-vacuous in the gate (main):** #4 (t32 dead assert), #11 (validates a blind instrument), #12 (no post-fire normal-path check), #16 (any-delta), #18 (fixed on rev2), peer B4 (`test_v2_onchip_pair` 5×PASS at 0 ns, fixed rev2 `c5141c36`), peer B5 (`test_v2_mask_hs_bilateral.py:236` 0 asserts — the module behind the `v2_mask_hs_regress` sentinel; the sentinel grep at `Makefile:1798` is what actually discriminates), peer T2/T3/T4/T18/T19. The 07-30 audit's "84 of 982 tests cannot fail" figure has not been re-measured; nothing on rev2 claims to have re-measured it.

**HBURST:** every `tb_top.sv` in the 34 HBURST-referencing files ties `hburst=3'h0`/`hprot=4'h0` or passes the DUT's own `m_ahb_sub_hburst` through; every Python driver sets `hburst.value = 0`. The only "INCR" string in `cocotb/` outside `debug/` is a divider ratio comment. Combined with `xhb500_..._core_addr.sv:147` (`singles_burst <= ~hprot[3] || hexcl || hburst==BUR_INCR`) this means **the XHB500 non-singles arm has executed in no test at any commit** — peer instrument-check confirms (`FINDINGS.md`: `case (hburst)` 0/1, `burst_int/len_int` never toggle). rev2 `ea1c3e49` adds `test_v2_burst_encodings.py` (measured: a cacheable INCR4 becomes two AXI bursts, the first all-zero) but it is **not in the rev2 gate** (`grep burst rev2-final/Makefile` = none).

---

## 4. Coverage

- **Collection on main**: `-cm` is honoured only when `COVERAGE=1` and only by 9 unit benches + `a2l_replay_cdc` (`cocotb/*/Makefile` `ifdef COVERAGE`) and unconditionally by `uvm/tidelink_top_system` (`cm.log` present in `sim_build_selfarm`). The gate itself collects nothing (`bench_support_gap.txt`: 3/55 gate suites had `-cm`). No functional coverage in cocotb (0 uses of `cocotb_coverage`); 15 covergroups exist only in UVM envs that are quarantined or not gated. `docs/SIM_GATE_COVERAGE.md` is a prose inventory, not a coverage report, and its counts are wrong (§1.2). rev2 adds `cocotb/coverage.mk`, `make coverage_gate`, a fail-loud `urg` merge (`d7a928c8`) and a **must-fail instrument check** (`make coverage_check` asserts the XHB500 burst arm is still UNCOVERED) — this is the right shape; keep it.
- **First baseline (peer, rev2 `bfa3c8de`, scoped to the 186 shipping files of `tidelink_top_full_asic_v2.flist`)**: line 85.63 %, cond 71.98 %, branch 75.31 %, toggle 60.41 %, FSM state 85.26 %, **FSM transition 41.84 %**. Running every non-gate bench moves line 85.63→85.81 % and rescues 0 of the top-30 uncovered items (`gate_vs_wholerepo.txt`) — the gap is the corpus, not the gate selection.
- **RTL compiled by no flist** (cross of `src/rtl/**` 71 files vs all 34 `flists/*.flist` + bench `.f`): `src/rtl/tidelink_addr_translation.sv` and `src/rtl/asic/tidelink_dft_wrapper.sv` (the latter is added on the `vcs` command line by `sim_gate_dftelab` `:1530-1536`, elaboration only). Note this is "compiled", not "exercised"; the peer's `unexercised_shipping_rtl.txt` (14,699 items) is the exercised view.
- **Features with zero (or elaboration-only) gate coverage on main** — with rev2 status:
  1. AHB non-single bursts / HPROT[3] cacheable path — none; rev2 bench exists, ungated. **partial**
  2. Cross-die READ end-to-end through the peer-side inbound bridge — `mst_core_xin` FSM 0/6 transitions on both dies ("no AXI AR or AW ever reaches the peer-side bridge in any simulation"); the N1/TL-04x read-backstop tests force `arvalid` at the node, not through the bridge. rev2 adds a unit bench `xhb500_bridge` (20 tests, gated) and `xdie_exclusive`; the *system* path is still un-simulated. **partial**
  3. XHB500 hazard-list saturation (the 08-19 silicon wedge, memory) — no bench names it; `RESP_FSM_ERROR`/`LOCK_ERROR` never entered. **not**
  4. Link divider ≠ /1 on the pair bench — `cocotb/Makefile:59-72` `link_rate_quick/full` exist (3.5/18 min), in no gate, in no CI job. **not**
  5. PTP end-to-end — one gated two-die test (`ptp_link_sync`, 42 s); UVM `ptp_chain`/`ptp_stress` quarantined; PHC lock interlock compiled out of every build and its 6-test module unbound (peer C6). **not**
  6. Error injection on the ASIC flist — `errinj` uses `tidelink_fpga_v2.flist`; the ASIC flist is elaboration-only on main (`asic_v1_elab`, `asic_v2_elab`, `dft_wrapper_elab`). rev2 adds `asic_v2_pair_data`, `asic_fcsm_silicon_ratio`, `asic_l7_starvation_backstop`, `asic_fileset_identity`, `flist_divergence` (`1d0b56f6`, `e31edbcc`, `634e60a1`). **partial** (no ASIC-fileset error injection)
  7. DFT wrapper — elaboration + an absence-grep for `tidelink_tx_gen` (`:1537-1542`); no positive control, no functional test. **not**
  8. `WlinkTxPstateCtrl` 0/4 transitions — rev2 adds `wlink_tx_pstate` (`d96199ee`). **fixed**
  9. `cmsdk_ahb_to_sram` `HRESP/HREADYOUT` never toggle, byte/halfword never driven — rev2 `bcf20a6e`. **fixed**
  10. Lane 7 never in the active mask (every `io_lane_mask[7]` arm dead, ≥10 sites). **not**
  11. `tidelink_autoneg` `ST_ERROR/ST_FIN_GO/AXL_*` never entered (23/66 transitions); `tidelink_fc_adapter` PUF states 0/4. **not**

---

## 5. Formal / lint / CDC

| Check | Where | Runs? | Can it fail? |
|---|---|---|---|
| HAL lint (Cadence) | `lint/Makefile` (19 standalone + 4 CMSDK modules) | CI `hal-lint` (tag `xcelium`) only → never | unknown; no on-disk log |
| Verilator lint | `lint/verilator/Makefile` + README | invoked by nothing (`grep` in `Makefile`, CI, `farm_gate.sh` = 0) | — |
| SpyGlass CDC | `cdc/Makefile` (top `tidelink_top`, `.sgdc` ×3, `waiver.swl` 11 KB) | CI `spyglass-cdc` (tag `vcs`) only → never; no `cdc/*/` run dir on disk | 11 KB of waivers, last reviewed 07-24 |
| VC Formal X-prop | `xprop/Makefile` 14 modules | never (0 refs in CI; `clean_xprop` only in `Makefile:1853-1859`) | **no** — peer C10: pipe swallows exit code, `grep "FAIL\|ERROR"` misses `*** Error 127`, so a missing tool writes PASS. Still so on rev2 (`xprop/Makefile:28`) |
| sv_anti_pattern + xdc_lint (ratcheted) | `cocotb/lint/`, `fpga/farm_gate.sh` Tier-0 | before every farm build (`build_farm.sh:83-88`); CI `farm-gate-lint/sim` never | selftests exist (`test_lint_selftest.py`, `test_xdc_lint_selftest.py`, `make robust_all`); peer A4: a *crashed* lint scores as no new findings (`farm_gate.sh:288,300`) |
| SVA in RTL | `grep -c '\bassert\b' src/rtl` = 36 lines, all in `tidelink_phy_align_calibrator{,_v2}.sv`; `assert property` = 0 (peer, confirmed; rev2 = 2 hits) | with the sim | there are no concurrent properties on any FSM, backstop, credit counter or CDC |
| Formal | none (`syn/asic/formality` = LEC only; no `.sby`, no Jasper) | — | — |
| Merge guard | `fpga/scripts/merge_guard.sh` (greps for silicon-proven fixes) | CI `merge-guard` only → never | yes (grep) |
| Vendor-collateral scan | `make vendor-check` (external toolkit) | CI only → never | — |

**Minimum static stack recommendation** (ordered by value/effort): (1) make `farm_gate_fast` (Tier-0 ratchets, seconds) a *local* pre-push hook via `install-git-hooks` with an in-repo fallback installer; (2) Verilator `--lint-only` on the ASIC flist as a second, licence-free lint (the Makefile exists, wire it into `sim_gate_env_check`-adjacent `sim_gate_lint`); (3) fix `xprop/Makefile` exit-code handling and run `standalone` weekly; (4) SpyGlass CDC on `tidelink_top_full_asic_v2` with the waiver file reviewed line-by-line against the TL-027 `w_inc` finding (a CDC tool with 11 KB of waivers that never runs is worse than none); (5) SVA: 10-20 concurrent properties on the things silicon has already broken — FCSM state-7 exit, `sub_wr_os_ctr`/read backstop mutual exclusion (N1), credit never exceeds `MAX_CREDITS` (twin-2/phantom-pop), `a2l_full` never latches with `app_ready=0` on an idle link (TL-027), `hazard-list` occupancy bound — bound into every cocotb build via `+define+TL_SVA`; (6) a bounded formal (SymbiYosys is enough) on `tidelink_fifo_ctrl` credit arithmetic and the FCSM.

---

## 6. Hardware validation

- **Artifacts that prove something** (all read, not trusted from prose): `td-bisect/kr260-consolidation-hwval-2026-08-19-results/` — `00_worktree_state.log` (target `d0a977aa`, clean), `04_build_design_v2.log` (`BUILD_EXIT=0`, manifest written), `08_deploy_kr260_01.log` (PL loaded; **`make deploy` exited 1** because `kr260_afi.sh fix` needed a sudo password), `09_afi_fix_direct.log` (AFI 32-bit both ports, canaries PASS when re-run directly), `10_autonomy_kr260_01.log` (`AUTONOMY PROVEN — zero host writes`, both dies `fcsm=4 cal=1 locked=1 match=1 gate=1`), `11_soak_kr260_01.log` (`sent=5000 drained=5000 good=5000 bad=0 stalls=0`), `12/13` post-soak health + `SMOKE1 PASS`, `15` lease released. This proves the **on-chip pair** (one board, both dies in fabric) delivers A→B credit-gated packets byte-exact at `d0a977aa`. It says nothing about cross-die reads, the eth-chiplet vehicle, or the ASIC file set; the manifest's `git_dirty` field is pre-`df0f1f24` (unverified), and the build tree was a scratchpad worktree, not the repo.
- `imp/hw_gate/` (tracked evidence tree, 08-13/08-18 material: TL-035/TL-042 A/B scripts, ILA captures, `SIGNOFF_LEDGER_2026_08_13.md` with its five evidence rules) — a good ledger; note its own rule 5 found a cited fix SHA that does not exist.
- **Instruments**: `kr260_sysval.py` on main still has the relabel (`:235-239`: only `rc==124` is special-cased; `rc==255`/empty output → `"read mismatch @%d: %s" % (start, out[:80])`), remote stderr discarded (`:58` `2>/dev/null`), fresh ssh per call (`:47-52`), and T6 unconditional PASS (peer C4, `:220-223`). **All fixed on rev2** (`575e3528` classify `TRANSPORT_ERROR`, `72ee8b6d` sudo prompt corruption, `a50a7b30` on-hardware must-fail proof, `736607c9` T6) with `ControlMaster` and retries (`rev2 kr260_sysval.py:40-67`). `kr260_onchip_soak.py`: sound — distinct tag + complement per packet, credit-gated send (`b_room()`), verdict `bad==0 and good==sent and stalls==0` (`:126`). `kr260_onchip_autonomy.py`: predicate fcsm==4 ∧ cal==1 ∧ role_lock ∧ `mask_hs_match==gate_open` (peer ruled sound). `health_snapshot.py` exit-0-when-unevaluable (peer C3) fixed rev2 `deaed7ea`; `test_loopback_pair.py`/`test_single_instance.py` always-exit-0 (peer C11) fixed rev2 `9788d2cc`. `hwtest/lib_hwtest.sh:192` 4-bit FCSM mask false-red (peer R1) **not fixed on rev2** (no `pynq_host/scripts/hwtest` commit in the rev2 log).
- **One-command HW regression?** `make hwtest_gate` (`Makefile:1810` → `hwtest_registry_coverage.py` then `hwtest_gate.sh`: provenance → N×(kpor→deploy→autonomy→soak) → `verdict.json`, threshold `MIN_PASS/N`). In form, yes. In trust: (i) **no `verdict.json` exists anywhere** — it has never completed; (ii) provenance = `source_commit == HEAD` only (`:44-49`), `git_dirty` never read, and the fail-open producer is unfixed on both branches, so a dirty-tree bitstream passes; (iii) `PW="${KR260_PASSWORD:-<REDACTED-BOARD-CREDENTIAL>}"` (`:33`) hard-codes a board password in a public repo; (iv) it depends on `ssh mapstone-dev ~/bin/kpor` (`:55`) — a per-machine convenience; (v) `hwtest/run_all.sh` is the alternative (`exit "$overall"` `:164`, so it does propagate) but is the PS-driven Z2/0x4403 vehicle, 9/13 categories untouched since 05-23 (memory), not the on-chip pair. Verdict: **not yet a trustworthy one-command gate**; it is one afternoon from being one (§8 task H1).

---

## 7. UVM (coordinator item (c): sequences/drivers/monitors)

**Liveness on disk.** Only `uvm/tidelink_top_system` has been built on the review tree (`sim_build_selfarm/`, 08-24, `test_top_i1_selfarm.log`: `TEST PASSED`, 0 UVM_ERROR) — because `sim_gate_i1_selfarm` runs it. The main tree has 07-30 `compile.log`s for `ptp_chain`, `ptp_stress`, `top_system` with 0 `Error-` lines (so the July "4 of 7 do not elaborate" was resolved by 07-30) but no run logs. `tidelink`, `tidelink_fc_adapter`, `tidelink_integration` have **no build directory in any worktree** and their last git touch is May 2026. CI quarantines `uvm-top-system`, `uvm-system`, `uvm-ptp-stress`, `uvm-ptp-chain` (`allow_failure: true`) and would block on `uvm-regression`, `uvm-fc-adapter`, `uvm-integration` if it ran. Peer B1/B2 (scoreboards pass on total packet loss; dead backstop) → **fixed on rev2 `24cb2cba`, `2c0783d8`** (+ a scoreboard self-test bench `uvm/tidelink_top_system/selftest/`). No rev2 commit touches a driver, monitor or sequence.

**Component review (read in full: `apb_master_{driver,monitor,if}.sv`, `ahb_tx_driver.sv`, `rtn_driver.sv`, `fc_agent/fc_{driver,monitor}.sv`, `fc_tx_ready_driver.sv`, `ahb_rx_responder.sv`, `ahb_{packet_write,random_packet,gapped_packet_write}_sequence.sv`, `sys_packet_sequence.sv`, `top_sys_{autoneg,ahb_sub}_sequence.sv`, `ptp_sync_sequence.sv`):**

- **U1 (S1 for that env, High confidence, S)** `uvm/tidelink_ptp_stress/sequences/ptp_sync_sequence.sv:117` `task wait_for_irq(logic irq_signal, string irq_name)` takes the IRQ **by value**; called with `tb_if.b_ptp_irq` (`:144`) and `tb_if.a_ptp_irq` (`:161`). The `while (!irq_signal && cycles < timeout_cycles)` loop (`:119`) can never observe the IRQ rising after the call, so every exchange either returns immediately (IRQ already high) or burns 50,000 cycles and raises `uvm_error` (`:124`). The env can therefore never go green regardless of the DUT; this is invisible because the job is `allow_failure: true` and nobody has run it. Proof: run `test_ptp_*` and grep `Timeout waiting for b_ptp_irq`; fix = `ref logic` or poll `tb_if` inside the task.
- **U2 (S2, High, M)** `uvm/tidelink_fc_adapter/env/ahb_tx_driver.sv:51-68` and `rtn_driver.sv:50-72`: both drivers wait for `hreadyout`/`hready` at the pre-edge **plus one settle cycle** before every address phase, explicitly to avoid a DUT race ("BUG-22 … the DUT is out of scope to modify here", `rtn_driver.sv:52-69`) in `tidelink_fc_adapter.sv` (TX aperture latch, returner `rtn_pending_r`). Consequences: the UVM env can never issue pipelined AHB (address phase N+1 overlapping data phase N) or back-to-back beats on either port, so the RTL's later "held-NONSEQ one-shot lock" (`src/rtl/tidelink_fc_adapter.sv:181-245`, `TX_IDLE_GAP=3`, documented trade-off that back-to-back same-address NONSEQ beats collapse to one transfer) is exercised only by the cocotb bench (`test_tidelink_fc_adapter.py:750` "Back-to-back alternating…"), and **"BUG-22" appears nowhere in `docs/BUG_REGISTRY.yaml`** (0 hits) — a real hazard was worked around in the testbench and lost. Otherwise the AHB phase timing in both drivers is correct (hwdata driven in the cycle after address acceptance; hready polled with `while`).
- **U3 (S2, High, S)** All 8 AHB sequence classes constrain `burst_type == svt_ahb_transaction::SINGLE` (`ahb_packet_write_sequence.sv:58/74/90`, `ahb_random_packet_sequence.sv:62/78/94`, `ahb_gapped_packet_write_sequence.sv:65/80/100`, `sys_packet_sequence.sv:63/79/95`, `top_sys_ahb_sub_sequence.sv:36/71`, `ptp_sync_sequence.sv:68/94`). The SVT VIP can drive INCR4/8/16/WRAP for free; UVM contributes zero HBURST coverage today.
- **U4 (S3, High, S)** `top_sys_autoneg_sequence.sv:125` `#(poll_interval * 10ns)` hard-codes a 10 ns clock; `:145-147` reports negotiation error/timeout as `uvm_info` (only the poll-loop overrun is `uvm_error`). The consuming tests do check `nego_done`/`nego_error` themselves (`test_top_autoneg_basic.sv:55-58`, `test_top_autoneg_timeout.sv:60-66`) so this is not a false green, but any new test that only starts the sequence would pass on a failed negotiation.
- **U5 (S3, Medium, S)** `top_sys_ahb_sub_sequence.sv`: defaults write `0x1000`/`0xCAFE_F00D` and read `0x2000` — the read cannot verify the write unless the test overrides `addr`; `rdata` is captured but not compared in the sequence. Only `test_top_ahb_passthrough` uses it and it is `TESTS_EXPERIMENTAL` (`uvm/tidelink_top_system/Makefile:320`).
- **U6 (S3, High, S)** `ahb_rx_responder.sv`: `ahb_rx_fifo_responder` drives `fc_rx_fifo_ready<=1` forever (`:57`) and `ahb_rx_cfg_responder` drives `pready<=1`, `prdata<=0` forever (`:104-105`) — the fc_adapter's RX FIFO write path and its APB master never see backpressure, wait states or non-zero read data. Only the a2l side gets random backpressure (`fc_tx_ready_driver.sv:36-43`, 25 %).
- **U7 (S3, Medium, S)** `fc_monitor.sv:43-46` and both responders sample raw `vif.*` signals at `@(posedge clk)` without a clocking block while `fc_tx_ready_driver` drives `tl_fc_a2l_ready` with an NBA at the same edge; sampling precedes NBA update so it works, but it is order-dependent and will break under a `#1step` VIP mix. `apb_master_{driver,monitor}` use clocking blocks correctly (setup→access→`pready` wait, `:43-75`; monitor keys on `psel&&penable&&pready`, `:43-46`); no back-to-back APB (psel held) is ever driven, and `pslverr` is captured but asserted by no sequence I read.
- **Sequences that are fine**: `ahb_random_packet_sequence` (`$urandom()` payload, 1..64 words), `ahb_gapped_packet_write_sequence` (random `num_idle_cycles` 1..8), `sys_packet_sequence` (payload from test).

**Keep/kill/merge.** Keep `tidelink_top_system` (the only env that reaches align/autoneg/lane-mask/train/addr-translate — 20 tests — and the only one the gate runs); make it the single UVM env, move the 15 covergroups there, and gate `TESTS` + `TESTS_ALIGN` (not just `i1_selfarm`). Merge `tidelink_system` into it (16 tests, same SVT stack). Kill `tidelink` (5 tests, May 2026, duplicated by `cocotb/tidelink` 25 tests) and `tidelink_integration` (4 tests, duplicated by `cocotb/tidelink_ahb`/`tidelink_system`). `tidelink_fc_adapter` (5 tests): kill after porting U2's back-to-back case into `cocotb/tidelink_fc_adapter` (63 tests already). `ptp_chain`/`ptp_stress` (11 tests): keep only if U1 is fixed and they are run once; otherwise the two-die cocotb `ptp_link_sync` + `eth_ptp_phc_subsystem` cover more with less.

---

## 8. `.gitlab-ci.yml` — 37 jobs and what `allow_failure` means here (coordinator item (b))

Parsed with PyYAML (37 job keys, 11 stages). Runner tags: `vcs` ×19, `xcelium` ×1, `fpga` ×2, `bridge1-runner` ×3, untagged ×12. **15 of 37 are `allow_failure: true`**; 22 are blocking. Since the forge holds a 07-23 trunk and has run 0 pipelines, *every* row below is "would" not "does".

| stage | job | tag | allow_failure | trigger | runs | note |
|---|---|---|---|---|---|---|
| setup | clone | - | false | always | git clone `$CI_REPOSITORY_URL` (=GitLab) + 4 sibling repos with `|| echo WARN` | peer: cannot go red |
| setup | preflight | - | false | always | checks tool/IP dirs (`:140-200`) | checks `CMSDK_DIR` dirs, not `CMSDK_FPGA_SRAM_V` |
| lint | strip-generalbus-check | - | false | always | `ci/check_strip_generalbus.sh` | |
| lint | vendor-collateral | - | false | always | `make vendor-check` (external toolkit) | comment `:249-252` says it "does not currently pass" |
| lint | farm-gate-lint | - | false | always | `make farm_gate_fast` | ratchet; A4 crash-fail-open |
| lint | merge-guard | - | false | always | `fpga/scripts/merge_guard.sh` | grep for 3 silicon fixes |
| lint | hal-lint | xcelium | false | always | `make -C lint lint-standalone; lint-each` | |
| lint | spyglass-cdc | vcs | false | always | `make -C cdc cdc` | |
| regression | **sim-gate** | vcs | **false** | always | `make sim_gate` | stale comment "10 suites"; cannot PASS on a clean tree (§0.2) |
| regression | cocotb-regression | vcs | false | always | `make -C cocotb coverage` (31 ENVS) | the only path that runs the 27 ENVS-only benches |
| regression | farm-gate-sim | vcs | false | always | `make farm_gate` | |
| regression | cdriver-regression | vcs | false | always | `make -C cocotb/tidelink_ahb driver-so` (target exists `:45`) | |
| regression | uvm-regression | vcm | false | always | `make -C uvm/tidelink run_all` | B1 scoreboard (fixed rev2) |
| new_module | cocotb-fc-adapter / cocotb-top / cocotb-ptp | vcs | false | always | `COVERAGE=1 make` in bench | |
| new_module | cocotb-top-pair-smoke | vcs | false | always | `MODULE=test_tidelink_pair_doorbell` | |
| new_module | uvm-fc-adapter / uvm-integration | vcs | false | always | `run_all` | B1 (fixed rev2) |
| new_module | uvm-top-system | vcs | **true** | always | `run_all` | the only UVM env that is alive is the one quarantined |
| new_module | cocotb-wlink-pair | vcs | **true** | always | `cd cocotb/wlink_pair` | **phantom path** |
| system | cocotb-system, uvm-system, uvm-ptp-stress, uvm-ptp-chain | vcs | **true** ×4 | always | | U1 makes ptp-stress unpassable |
| fpga | fpga-pair | fpga | **true** | rules: main / `feat/fpga-flow` / schedule / web | `ci/fpga_run_pair.sh` | |
| fpga | fpga-ptp-pair | fpga | **true** | rules: schedule / web / `feat/phc-hw-test` | | peer: branches exist on no ref |
| synthesis | synth-fifo / synth-top / synth-top-full | vcs | **true** ×3 | needs cocotb-regression | DC | |
| synthesis | formality-lec | vcs | **true** | manual | | |
| coverage | coverage-merge | vcs | false | always | `urg` merge | peer: exits 0 with no `.vdb` |
| pages | dashboard | - | false | `when: always` | `ci/generate_dashboard.py` | cannot go red |
| cleanup | cleanup | - | false | `when: always` | `rm -rf \|\| true` | cannot go red |
| hwtest | hwtest:safe | bridge1-runner | **true** | `$SCHEDULE_HWTEST==1` else manual | `hwtest/run_all.sh` | |
| hwtest | hwtest:full / hwtest:soak | bridge1-runner | **true** ×2 | manual | `run_all.sh` | |

**Semantics.** With `allow_failure: true` on all four system-level UVM jobs, both FPGA jobs, all synthesis, and all three HW jobs, the pipeline's red/green is decided by: 8 lint/guard jobs, `sim-gate`, `cocotb-regression`, `farm-gate-sim`, `cdriver-regression`, `uvm-regression`, 4 `new_module` cocotb jobs, `uvm-fc-adapter`, `uvm-integration`, `coverage-merge`. Of those, `sim-gate` cannot pass (§0.2), `vendor-collateral` is documented as failing, `coverage-merge`/`clone`/`dashboard`/`cleanup` cannot fail, and the two UVM blocking jobs passed on total packet loss until rev2. **Net: if this pipeline were switched on today it would be red for the wrong reasons and green for the wrong reasons at the same time.** rev2 does not address any of this (its `.gitlab-ci.yml` delta is +103 lines; I did not diff it line-by-line — stated, not verified).

---

## 9. Findings ledger (severity / confidence / effort / how to prove)

| ID | Finding | Sev | Conf | Eff | Prove it | rev2 |
|---|---|---|---|---|---|---|
| V1 | No automated gate on `origin/main`; GitLab trunk 293 commits stale, 0 pipelines; no `.github/` | S1 | High | M | `git rev-list --count gitlab/main..origin/main`; `ls .github` | **not** |
| V2 | `make sim_gate` dirties its own tree via tracked `dut_src_*.f` → summary `exit 2` on a clean checkout | S1 | High | S | run gate on clean tree; `git status` shows 3 M files; mixed stamps in `imp/sim_gate` | **not** (5 nodes now) |
| V3 | `sim_gate_env_check` does not check `CMSDK_FPGA_SRAM_V`; unsourced env = every suite FAIL in 4-5 s | S2 | High | S | `make sim_gate_env_check` in a fresh shell passes, then suites SFCOR | **not** |
| V4 | `tc_pair_smoke`/`tc_pair_election_datamode` standing red (assertion failures, both branches) | S2 | High | M | `imp/sim_gate/tc_pair_*.log` | **not** |
| V5 | 4 duplicate invocations; `fifo_rx_twin2` invoked-unscored; 5 rescued targets never triaged | S3 | High | S | grep `:1599-1694` | dup **fixed**; rest **not** |
| V6 | HBURST≠SINGLE exercised nowhere (cocotb + UVM); XHB500 non-singles arm never executed | S1 | High | M | `coverage_check` on rev2; grep `hburst.value` | **partial** (bench, ungated) |
| V7 | Peer-side inbound bridge FSM 0 % — the shipping read path is un-simulated as a system | S1 | High | L | `FINDINGS.md`; `mst_core_xin` in `merged.vdb` | **partial** (unit bench) |
| V8 | a2l CDC A/B: must-fail arm (`USE_DEPS_DUT=1`) exists but the gate never runs it | S2 | High | S | gate targets `:597-608` pass no `USE_DEPS_DUT` | **fixed** by `a2l_wready_tear` pattern for _1/_3/_5/_7/_9 (verify it runs both arms in gate) |
| V9 | Post-fire "normal path still works" not asserted in `n1_readbackstop_suppress` | S2 | Med | S | read `:276` vs after `:336` | **not** |
| V10 | `df0f1f24` git_dirty fail-closed fix on neither branch; `hwtest_gate.sh` never reads `git_dirty` | S1 | High | S | `merge-base --is-ancestor`; `grep git_dirty hwtest_gate.sh` = 0 | **not** |
| V11 | `hwtest_gate.sh` has never produced `verdict.json`; hard-coded board password `:33` | S2 | High | S | `find … verdict.json` empty | **not** |
| V12 | `kr260_sysval.py` rc≠124 → "read mismatch", empty detail string, T6 unconditional PASS | S1 (false red + false green) | High | S | `repr()` of `sysval_a4.json` detail | **fixed** (`575e3528`,`72ee8b6d`,`a50a7b30`,`736607c9`) |
| V13 | UVM `wait_for_irq` by value (U1) | S2 | High | S | run `test_ptp_*`, grep Timeout | **not** |
| V14 | UVM fc_adapter drivers de-pipelined to hide an unregistered DUT race (U2) | S2 | High | M | read `rtn_driver.sv:50-72`; grep BUG-22 in registry = 0 | **not** |
| V15 | UVM scoreboards pass on total loss (peer B1/B2) | S1 | High | S | peer | **fixed** |
| V16 | `xprop/` fail-open, never runs; SpyGlass/HAL/Verilator never run | S2 | High | S | `xprop/Makefile:28` | **not** |
| V17 | Zero concurrent SVA on any FSM/backstop/credit counter | S2 | High | M | `grep -r 'assert property' src` | **not** |
| V18 | Coverage: FSM transition 41.8 %; no functional coverage in the gate; `SIM_GATE_COVERAGE.md` counts wrong | S2 | High | M | peer baseline | **fixed** infra; closure **not** |
| V19 | 43 benches unwired, ≥6 with known reds/unknowns (§1.3) | S2 | High | M | table | 3 wired |
| V20 | `link_rate_quick/full` divider sweeps in no gate | S2 | High | S | `cocotb/Makefile:59-72` | **not** |
| V21 | Phantom targets/jobs (`cocotb/wlink_pair`), stale suite counts in 3 docs/files | S3 | High | S | `ls cocotb/wlink_pair` | **not** |
| V22 | `registry_coverage.py` skipped existence check for 7/17 gated bugs (peer B7) | S2 | High | S | peer | **fixed** (`107b0dcd`) |
| V23 | `test_v2_onchip_pair` 5×PASS at 0 ns; lane-mask oracle constant-False (peer B3/B4) | S1 | High | S | peer | **fixed** (`c5141c36`, `0bad1d29`) |
| V24 | `sim_gate_sentinel` macro has no `make -n` guard (only `sim_gate_run` does) | S3 | Med | S | read `:1257-1273`; do NOT test with `-n` on a real tree | **not** |

---

## 10. Verdict and plan

### 10a. Top 10 verification gaps by tapeout risk
1. **No gate runs automatically anywhere** (V1). Four of five tapeout defects reached T-3wk for this reason once already (`docs/TIDELINK_FPGA_VERIFICATION_PLAN.md:41-45`, per peer); the doc says it was fixed; it is not.
2. **The shipping read/burst datapath is unsimulated**: peer-side inbound bridge 0 %, no non-single burst anywhere (V6, V7). Compute-die DMA emits cacheable INCR by construction (memory 08-24); the only reason the eth die is safe is a tie-down.
3. **The gate cannot print PASS on a clean checkout** (V2) — every recent "gate green" required a local `assume-unchanged` hack, i.e. the stamp that exists to prevent false greens is routinely bypassed.
4. **Provenance fail-open on both branches** (V10) — every FPGA "built clean from X" claim is unverified; the HW gate does not even look.
5. **Hazard-list saturation / XHB500 response-path wedge** (silicon, 08-19) has no sim reproduction and no bench; `RESP_FSM_ERROR` never entered.
6. **Recovery paths are tested for escape, not safety** (V9): several backstop tests stop at "ERROR was returned".
7. **ASIC file set vs FPGA file set divergence** (memory: FPGA-proven recovery does not transfer to ASIC; `deps/` FCSM 0-5 stripped of recovery). rev2's `asic_*` suites + `flist_divergence` are the right response — but they are on an unmerged branch.
8. **Standing reds train people to ignore red** (V4 `tc_pair_*`; `vendor-collateral`).
9. **CDC never analysed by a tool** (V16) on a design whose last three real defects (TL-027 `w_inc`, a2l false-full, `wr_hold_clr`) were CDC.
10. **43 benches with unknown/red state outside any gate** (V19) — the 07-30 audit's "84 tests cannot fail" and the peer's ~49 broken diagnostics say the untended half rots fast.

### 10b. Next-iteration verification architecture
- **One entry point, three tiers, one stamp**: `make check` = Tier-0 (env self-test incl. `CMSDK_FPGA_SRAM_V` + ratcheted lints + Verilator lint + registry coverage, < 2 min) → Tier-1 `sim_gate_quick` (≤ 15 min, must include one non-single-burst and one inbound-bridge test) → Tier-2 full `sim_gate` (+ coverage on) → Tier-3 `hwtest_gate` (nightly, on-chip pair). Every tier writes `<suite>.status` with `<sha>-<clean|dirty>-<flist-sha>`; **nothing the gate runs may write a tracked file** (move `dut_src_*.f` under `sim_build*/` or make them `-f` command-line args), and the summary refuses PASS on dirty — no `assume-unchanged` escape.
- **Forge decision + hook**: pick GitHub Actions on a self-hosted `vcs` runner (origin is GitHub) or move origin back; either way `install-git-hooks` must install an in-repo `pre-push` = Tier-0. Until then, a cron on the sim host that runs `make check` on `origin/main` nightly and posts the summary is better than the current nothing.
- **Coverage-driven closure**: adopt rev2's `coverage_gate`/`coverage_check`; publish `unexercised_shipping_rtl.txt` per run; set a ratchet (no new uncovered shipping lines vs baseline) rather than a percentage target; add functional covergroups for HBURST/HPROT/HSIZE at both AHB ports, FCSM transitions, backstop fire→clear→next-transfer, credit at MAX/0.
- **Every diagnostic ships with its must-fail control** (peer's rule, the project's own memory 08-25): a gate target is not accepted unless it has a `USE_*_DUT`/mutant arm the gate actually runs (the `a2l_wready_tear` shape), and every HW instrument has an "inject one bad word → reports it" self-test.
- **Formal on the small, already-bitten pieces**: SVA properties (§5 item 5) compiled into every build; bounded model check on `tidelink_fifo_ctrl` credits and the FCSM; SpyGlass CDC with the waiver file re-derived from scratch.
- **UVM: one env** (`tidelink_top_system`), gated in full, with U1-U3 fixed; retire the rest.
- **HW: one command that can be trusted**: `hwtest_gate.sh` reads `git_dirty` (after landing `df0f1f24`), refuses dirty, takes the password from env only, and has run at least once with a stored `verdict.json` before anyone cites it.

### 10c. Parallelisable tasks (files, effort, prerequisite, rev2 status)
| # | Task | Files | Eff | Prereq | rev2 |
|---|---|---|---|---|---|
| T1 | Stop the gate writing tracked files; add `flist-sha` to `GATE_STAMP` | `cocotb/tidelink_a2l_replay_cdc/Makefile:65`, `.gitignore`, `Makefile:252-281` | S | none | not |
| T2 | `sim_gate_env_check`: test `-f "$CMSDK_FPGA_SRAM_V"`, `TIDELINK_HOME`, `CHIPLET_HOME`, `TIDECHART_HOME` | `Makefile:301-312` | S | none | not |
| T3 | Land `df0f1f24`; make `hwtest_gate.sh` read `git_dirty` and refuse; drop default password | `fpga/scripts/build_provenance.tcl`, `pynq_host/scripts/hwtest_gate.sh:33,44-49` | S | none | not |
| T4 | Gate a non-single-burst test (rev2 `test_v2_burst_encodings.py`) with HPROT[3]=1 and INCR4/8/16, both dies, byte-exact + "exactly one AXI burst" assert | rev2 bench, `Makefile` | M | rev2 merge | partial |
| T5 | System-level cross-die READ through the inbound bridge (peer-side XHB target memory in `tidelink_top_pair_v2/tb_top.sv`), AR/R FSM coverage ≥ 1 transition each | `cocotb/tidelink_top_pair_v2/tb_top.sv`, new test | L | T4 optional | partial (unit) |
| T6 | Hazard-list saturation reproduction (stall B responses ≥ hazard depth, assert recovery + next write lands) | `tidelink_top_pair_v2`, new test | M | T5 | not |
| T7 | Post-fire safety asserts in every backstop test (state clears, next clean transfer OK) | `tidelink_axi_datanode_recovery/test_n1_*.py`, `test_axi_datanode_gaps.py` | S | none | not |
| T8 | Triage the 43 unwired benches from §1.3: fix/kill the 6 red-or-unknown, wire the green ones into `sim_gate_quick`/`sim_gate`, delete `debug/` or move to `docs/` | `cocotb/*`, `Makefile` | M | T1,T2 | 3/43 |
| T9 | Fix U1 (`ref` IRQ), U3 (allow INCR in SVT sequences), U6 (backpressure responders); register BUG-22; gate `tidelink_top_system` `TESTS`+`TESTS_ALIGN` | `uvm/tidelink_ptp_stress/sequences/ptp_sync_sequence.sv:117`, `uvm/*/sequences/*.sv`, `uvm/tidelink_fc_adapter/env/*`, `docs/BUG_REGISTRY.yaml`, `Makefile` | M | none | not |
| T10 | Static stack: `xprop/Makefile` exit codes, Verilator lint target in Tier-0, SpyGlass run + waiver review | `xprop/Makefile:26-31`, `lint/verilator/Makefile`, `cdc/waiver.swl` | M | licences | not |
| T11 | SVA pack (`+define+TL_SVA`) for FCSM/N1/credits/a2l_full/hazard bound | `src/rtl/*.sv` (or bind files under `verif/sva/`) | M | none | not |
| T12 | Divider ≠ /1 in the gate: `link_rate_quick` as a `sim_gate_link_rate` target | `cocotb/Makefile:59-72`, `Makefile` | S | T1 | not |
| T13 | Resolve `tc_pair_*` red (tidechart_shim↔tidechart pin) or convert to an XCHG-capable sentinel | `cocotb/tidechart_tidelink_pair`, sibling repos | M | sibling owner | not |
| T14 | Forge + hook: GitHub Actions self-hosted runner running Tier-0/1; fix phantom `cocotb/wlink_pair` job/targets; correct suite counts in `.gitlab-ci.yml:370,387`, `docs/SIM_GATE_COVERAGE.md:63,345` | `.github/workflows/*`, `.gitlab-ci.yml`, `Makefile:99-110`, docs | M | decision | not |
| T15 | Run `hwtest_gate.sh` once end-to-end on the on-chip pair and commit `imp/hw_gate/verdict.json`; add an instrument self-test (inject one bad word) | `pynq_host/scripts/hwtest_gate.sh`, `kr260_onchip_soak.py` | S | T3, board lease | not |
| T16 | Merge rev2's verification infra now (coverage.mk, scoreboard fixes, sysval fixes, unscored-suite guard, registry fix, ASIC-fileset suites) as a separate PR ahead of its RTL changes | `origin/rev2/integration` | M | review of the 59 commits | — |

---

## Appendix A — evidence paths
- Gate statuses/logs: `baseline-5e8bdb5a/imp/sim_gate/*.status|*.log` (08-24/25); older: `$WORKTREES/SoCLabs/tidelink/imp/sim_gate/` (07-31), `td-bisect/tl-siteenv-2026-08-19/`.
- Peer: `rev2-final/docs/FALSE_GREEN_REGISTER.md`; `td-bisect/coverage-2026-08-26/{README,FINDINGS}.md`, `bench_support_gap.txt`, `gate_vs_wholerepo.txt`, `logs/bench_sweep.log`, `logs/sweep_*.log`, `merged.vdb`.
- HW: `td-bisect/kr260-consolidation-hwval-2026-08-19-results/00..15_*.log`; `baseline-5e8bdb5a/imp/hw_gate/*` (08-13 ledger); `td-bisect/kr260-hwval-77d9bcbe-2026-08-18/imp/hw_gate/`.
- Scratch artefacts from this review: `scratchpad/inv.md`, `all_targets.txt`, `agg_targets.txt`, `main_suites.txt`, `rev2_suites.txt`, `flist_rtl.txt`, `all_rtl.txt`.


---

# PART 5 Open-defect and risk register

# TideLink — Consolidated Open-Defect and Risk Register
**Review point:** `origin/main` = `5e8bdb5a` (read-only checkout `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a`).
**Next-iteration point:** `origin/rev2/integration` = `cba9774d` (59 commits ahead of main; checkout `$WORKTREES/SoCLabs/td-bisect/rev2-final/`), plus `origin/rev2/hygiene` = `df0f1f24` (5 commits, NOT merged into integration — verified `git merge-base --is-ancestor` = false).
**Date:** 2026-09-09. **Method:** every claim below was checked against `git` on the review tree or a file read; where a claim could not be checked it is marked **Unverified** and the resolving measurement is named. Nothing in any git tree, board, or `/research/AAA/**` was modified.

Legend for "Status" columns:
- **Open** — no fix in tree.
- **Fixed-unproven** — fix in tree, no reproduce-first test, or test not gated.
- **Fixed-sim-proven** — fix in tree + reproduce-first (RED→GREEN) test, gated in `make sim_gate`.
- **Fixed-HW-proven-FPGA(vehicle)** — retained artefact on disk from a real board run; vehicle named (`onchip` = `kr260-pair-onchip`, one xck26 two dies no ribbon; `eth-pair` = two-board KR260 eth-chiplet; `Z2`).
- **ASIC-reachable?** — Y if the fix lives in a file the shipping `flists/tidelink_top_full_asic_v2.flist` compiles; N if it lives only in `src/rtl/local_overrides/WlinkGenericFCSM{,_1..4}.v` / FPGA-only flists (the ASIC flist sources FCSM 0-5 from `deps/`, lines 315-320 — verified).
- **OVERCLAIMED** — registry status says `hw_proven` but no retained artefact exists on disk.

---

## 1. Registry audit — `docs/BUG_REGISTRY.yaml` at 5e8bdb5a

**Which registry is newer:** the review tree's registry (42 entries, last touched `c1f53756` 2026-08-17) is newer than the primary worktree's rescue-branch copy (`$WORKTREES/SoCLabs/tidelink/docs/BUG_REGISTRY.yaml`, 17 entries, last touched `5169de3d` 2026-08-10). The rescue copy lacks TL-018..TL-042 and still says `open_functional_high: 0`. Use the 5e8bdb5a copy; the rescue copy is a stale snapshot. `origin/rev2/integration` has the same 42 ids (TL-042 amended with `hol_write_age_watchdog_2026_08_23`; TL-043/TL-044 have **zero** registry references there even though they are used as fix/suite names — see §2.19).

**Fix-SHA ancestry:** every `fix.commit` recorded in the registry (17 distinct: e5bd29c e28c898 9dfe1da 41c4107 9b4c40b e827199 42da64b 1aaed00 8e071f7 63222b6 383927e 235d758 a0a224c 5be494b 602ef8d b0e9334 9622c3d) **is an ancestor of 5e8bdb5a** (100%). Four entries whose `commit:` field says `null`/`pending` actually have landed fixes: TL-027 (`1037a63`), TL-032 (`3f037c0`), TL-037 (`2b84732f`), TL-026 (`651a71b`), TL-006 A3 (`d78268a4`), TL-020 (obs lines in ASIC flist). The registry is **stale in the optimistic-to-pessimistic direction** for those — it under-reports what landed.

| ID | Title (short) | Sev | Registry status | Fix sha → on 5e8bdb5a? | Evidence artefact on disk? | Audit verdict |
|---|---|---|---|---|---|---|
| TL-001 | Peer-write data-drop / calibrator lottery | rank1 | root_caused | e5bd29c FIX1 ✔, 2c249ec FIX2 ✔, 20af2b1 FIX-D ✔ | `hw_fix3 11/11`, `hw_fix1_*` logs: **NOT on disk** (prose only). n=20 campaign `imp/hw_gate/overnight/` ✔ | Open (mitigated). eth-pair delivery 17/20; predictor = anchor pair. onchip vehicle lottery-free (5000/5000 ✔ `td-bisect/kr260-*-2026-08-19-results/`) |
| TL-002 | wr_hold_r early HREADYOUT | high | sim_proven | e28c898 ✔ (+ TL-043 edge-qualified clear 2413aa60 ✔) | gated `axi_datanode_recovery` ✔ | Fixed-sim-proven (standalone IP). Implicated as wedge holder 08-13 (ILA round-2), then **refuted as holder 08-19** (silicon: `wr_hold_r=0` during hazard-list wedge). Redundant on eth-chiplet (`cap_done_r` holds HWDATA upstream) |
| TL-003 | Fix K hazard-list BID mux | high | **hw_proven** | 9dfe1da ✔ | "silicon #3→#6": **no artefact** (BUILD_REGISTRY entry itself: "the cited HW log does not exist on disk") | **OVERCLAIMED**. Also unreachable once HPROT[2] tie-down lands (EWR-only path) |
| TL-004 | F-1 illegal AHB ERROR | high | sim_proven | 41c4107 ✔ | `gaps_backstop::test_i5_error_is_ahb_legal` gated ✔ | Fixed-sim-proven, ASIC-reachable Y |
| TL-005 | F-2 backstop never restores (synth-B) | high | **hw_proven** | 9b4c40b, e827199, 42da64b ✔ | one B-byte-0 inject observation, **no artefact**; 08-19 silicon `0x21F8[8]=0` proves the backstop **never fired** in the real wedge | **OVERCLAIMED** and **non-operative** in the measured wedge (starved). Drain fix 42da64b HW-disproven for the soak wedge (08-05) |
| TL-006 | Header ECC restore (WlinkEccSyndrome) | high | sim_proven (REOPENED note) | 1aaed00 ✔, d78268a4 ASIC re-point ✔ (flist :253 = local_override, verified) | `gaps_ecc` 6/6 gated ✔; `gaps_ecc_asic` combined-config 6/6 (memory) | Fixed-sim-proven, **ASIC-reachable Y** — registry "REOPENED/bypass ships" is STALE. W-byte-0 never HW-validated; byte-1 divergence = TL-038 |
| TL-007 | synth-B OKAY not SLVERR | high | **hw_proven** | e827199 ✔ | same single observation as TL-005, no artefact | **OVERCLAIMED** |
| TL-008 | txgen ownership-mux hijack | high | sim_proven | 383927e ✔ | `sim_gate_txgen_ext_hijack` ✔ | Fixed-sim-proven; ASIC N/A (`TXGEN_PRESENT=0` in dft_wrapper) |
| TL-009 | die_a PS wedge under sustained writes | high | root_caused | 235d758 obs ✔; no fix | `hw_regionf_soak.log` etc.: **not on disk**. 08-19 ILA `results_wnode_2026_08_19`: **not in this tree** (peer's eth-chiplet tree) | Open. Mechanism SUPERSEDED: XHB500 hazard-list saturation awaiting B (`sub_wr_os_ctr=4`, HPROT[2]=1), backstops starved. See §2.1 |
| TL-010 | F13 PTP mailbox-RO + convergence | high | fix_built | a0a224c ✔, gated `v2_mbox_writeprotect` ✔ | none HW | Mailbox half Fixed-sim-proven; convergence/PHC hop Open |
| TL-011 | F19 PHY BIST unwired | high | deferred | — | `make phy_bist` 1P/10F in consolidated env (memory 08-08) | Open; suite itself red |
| TL-012 | `_generate_xhb500` pipefail | high | fix_built | 5be494b ✔ | n/a | Fixed (on main). Note `deps/xhb500/generated` is **untracked** at 5e8bdb5a (commit 5e8bdb5a itself untracked it); content-digest pin `6a174a3b` is on `rev2/hygiene` only |
| TL-013 | V1 flist elab | med | fix_built | 5be494b ✔ | n/a | Fixed; retire-or-keep decision open |
| TL-014 | dup PHY submodule | low | deferred | — | — | Open (low) |
| TL-015 | pins unreachable / land on main | high | deferred | — | — | **RESOLVED by consolidation** (main = d0a977aa→5e8bdb5a carries the integ line). Registry stale |
| TL-016 | SSH URLs in .gitmodules | med | fix_built | 5be494b ✔ | n/a | Fixed |
| TL-017 | tl_data_mode_o lint | fyi | wontfix | — | — | closed |
| TL-018 | ASIC CRC resets ON, FPGA OFF | med | root_caused | — | verified: deps `:636 <=1'h0` (CRC ON) vs local `:747 <=1'h1` (OFF) | Open (decision). Combination now co-simulated on rev2 (`asicsim-2026-08-26` sweep), not on main |
| TL-019 | ASIC FCSM 0-4 on deps (no `socl_` recovery) | high | root_caused | — | verified `socl_` deps=0 / local=72-73 each; **`asicsim-2026-08-26/l7_starvation_ab_SUMMARY.txt`: ASIC arm WEDGES at state 7, FPGA twin escapes** | Open — now MEASURED, not reasoned. Highest ASIC-specific risk |
| TL-020 | ASIC flist hygiene (obs/dedup/a2l_48x4) | high | sim_proven | in flist ✔ (lines 71-72, 198, 230) | 3 elab gates | Fixed. Parent `nanosoc_eth_chiplet_asic.flist:81-82` double-define coordination still owed |
| TL-021 | First-silicon obs gaps | high | root_caused | sub-item (3) `ext_stall_err_q`→`0x21F8[11]` **landed** (tidelink_top.sv:1875 verified) | — | Partially fixed; (1) APB region D/F hit and (2) i2c_slv_reset override Open |
| TL-022 | rf_16k random init | med | sim_proven | randinit 42/42 | `14_rx_fifo_phantom_pop.sh` never board-run | Fixed-sim-proven; incomplete-packet 2nd case untested |
| TL-023 | mailbox async rptr ICG | low | open | — | — | Open (needs pnr netlist read) |
| TL-024 | FIX1/FIX2 regress 14 suites | rank1 | root_caused | 2e6f8dc ✔ (7 tests), waiver | `docs/WAIVER_TL024_FIX2_MASK_STAGGER.md` ✔ | Dispositioned (2 XFAIL sentinels; masked/staggered autonomous bring-up dead in sim at thresh 6 — real regression under waiver) |
| TL-025 | tidechart `device_strap` elab | med | root_caused | — | still failing 08-18 | Open (tidechart owner) |
| TL-026 | pair_credit_next pipeline | med | sim_proven | 651a71b ✔ | equivalence harness (memory) | Fixed-unproven-on-HW (memory: HW-validated 08-08 onchip, prose only) |
| TL-027 | a2l _1/_3/_5 no CDC self-heal | high | root_caused | **1037a63 ✔ wired into BOTH flists** (verified fpga_v2 :287/:299/:302, asic_v2 :283/:298/:304) | `a2l_replay_cdc` NODE=1/3/5 gated; w_inc tearing 8/8 ACK-loss proven 08-24 (rev2 `b0ae7a8d`) | Fixed-sim-proven, ASIC-reachable Y; registry STALE. `_7/_9` (AR/R) unfixed on main (§2.10) |
| TL-028 | RX word clock gen-clock | high→low | root_caused | ASIC SDC has it; FPGA XDC not | — | Open (low leverage; diagnostic only) |
| TL-029 | F14-B data-mode wedge waiver | med | deferred | sentinel | `docs/WAIVER_F14B_DATAMODE_WEDGE.md` ✔ | Open under waiver (unsigned) |
| TL-030 | EPOCH corrector XCHG | med | open | — | — | Open (bisect or re-baseline) |
| TL-031 | eye-qual metric | med | open | — | n=20 shows anchor-pair predictor exists | Open, premise partly refuted (script-level gate available) |
| TL-032 | calibrator wrap-stitch | high | sim_proven | 3f037c0 ✔ (deps twin 8c560c5 **not** ancestor — submodule pin) | `test_calibrator_wrap.py` ✔ | Fixed-sim-proven; HW 08-09: safe, **did not change land-rate** |
| TL-033 | credit-counter underflow | high | open | **guard already present**: `tidelink_fifo_ctrl.sv:199-204` "BUG-002 fix: saturate at zero" since `ce2f2c90` 2026-04-06 | none | **Registry WRONG** (says unconditional decrement). Residual: no FPV/test asserts it |
| TL-034 | TideChart reg-map (force_root, TC_CTRL[3], dual-root) | med | open | — | `TC_ERROR[2]` no setter **verified** (`tidechart_apb_regs.sv` :370/:455/:477 only); dual-root HW repro evidence `td-bisect/dualroot-hwval-2026-09-09/evidence/` (exists; verdict not parsed by me) | Open; being worked (rev2 timeout width — §2.18) |
| TL-035 | state-7 watchdog dead after 1st CRC | high | root_caused | **Part-A AND Part-B landed on main via `52c06677` "wip … uncommitted, unreviewed"** — `_GEN_115 = (auto_tx_out_advance \| socl_l7_wdog_force_clear)` unconditional in local FCSM 0-4 (verified :426/:404) | HW A/B n=6 (`imp/hw_gate/tl035_*`): **no demonstrated effect**; Part-B ILA never taken | Fixed-unproven, landed against its own BLIND-MERGE-FORBIDDEN note. FPGA only (ASIC N) |
| TL-036 | watchdog fix not on FCSM_6 | med | root_caused | FCSM_6 `:646-648` still `& ~socl_l7_real_crc_seen` (verified) | — | Open |
| TL-037 | ahb_sub terminal-timeout dead gate | high | sim_proven ("NOT LANDED") | **2b84732f ✔ landed** (`sub_mst_dphase_r` :1605/:2110) + wired into sim_gate | onchip no-regression runs 08-18/19 ✔ (`td-bisect/kr260-hwval-77d9bcbe-2026-08-18`, `*-hazard1-*`, `*-consolidation-*`: 5000/5000) | Fixed-sim-proven + HW no-regression (onchip). Registry STALE. Structurally inapplicable to the hazard-list wedge (needs `sub_wr_os_ctr==0`, wedge has 4) |
| TL-038 | B byte-1 inject still wedges | high | open | — | not re-run since 08-03 | Open |
| TL-039 | ILA mis-scoped | med | root_caused | — | — | Open (instrument). rev2 `a585a2f5` netlist census partially addresses |
| TL-040 | dbg_a2l_wedged trigger inert | med | root_caused | — | — | Open (instrument) |
| TL-041 | servo_locked change under "lint" header | high | sim_proven | b0e9334 ✔ fix present (:680) | `grep -c ptp_servo Makefile` = **0** (ungated, verified) | Fixed, ungated, unsigned |
| TL-042 | backstop class / wr_hold deadlock | high | open | v1 candidate REJECTED on HW; nothing on main | `imp/hw_gate/TL042_HW_RESULT_REJECTED_2026_08_13.md` ✔, `tl042_v2/` ✔ | Open on main. rev2 `82c56e2a` HOL write-age watchdog: sim-proven, **HW-unproven, and rests on a silicon capture that contradicts the 08-13 ILA** (§2.2) |

**Counts (42 entries):**
- Closed-and-proven (fix on main, reproduce-first test gated, no unsupported HW claim): **13** — TL-002, 004, 006, 008, 012, 013, 016, 020, 022, 027(_1/_3/_5), 032, 037, 041(ungated caveat).
- Closed-but-unproven / landed without its own gate: **5** — TL-010 (mailbox half), 021(3), 026, 033 (guard exists, no test), 035 (landed via unreviewed WIP, HW A/B null).
- Open: **20** — TL-001, 009, 011, 014, 018, 019, 021(1,2), 023, 024(waiver), 025, 028, 029, 030, 031, 034, 036, 038, 039, 040, 042.
- Overclaimed (`hw_proven` with no artefact on disk): **3 of 3** `hw_proven` entries — TL-003, TL-005, TL-007. 100% of hw_proven statuses are unsupported by a retained artefact; TL-005/007 are additionally shown non-operative in the only silicon wedge captured with `0x21F8`.
- Resolved-but-still-listed-open: **2** — TL-015 (consolidation done), TL-033 (guard predates registry).
- Registry entries whose `commit:` field under-reports a landed fix: **6** (TL-006 A3, 020, 026, 027, 032, 037).

**BUILD_REGISTRY.yaml LKG:** `last_known_good: BLD-2026-08-08-kr260-onchip`, `git_sha 9cca6fe2…` — **is an ancestor of 5e8bdb5a** (verified), clean tree, bit sha256 recomputed. Its retained artefact `onchip_landrate.log` exists (`$WORKTREES/SoCLabs/tidelink-consolidated/onchip_landrate.log`, 1172 B). Caveat carried by the registry itself: `hwtest_gate.sh` verdict.json never produced. Newer HW-validated builds with retained artefacts exist but are NOT in BUILD_REGISTRY (it was last regenerated 08-10): `d0a977aa` onchip 5000/5000 (`td-bisect/kr260-consolidation-hwval-2026-08-19-results/11_soak_kr260_01.log`), `77d9bcbe`, pin-bump `e6aaa82f` (`kr260-pinbump-hwval-2026-08-19-results/13_soak_5000.log`). **Every pre-08-24 manifest's `git_dirty:false` is UNVERIFIED** (§2.6).

---

## 2. Items NOT (adequately) in the registry — characterised at 5e8bdb5a

### 2.1 XHB500 hazard-list saturation write wedge (the real TL-009/TL-042 mechanism)
- **What silicon showed (08-19, peer capture, 116 probes, contiguous `dbg_freerun_ctr`):** `sub_wr_os_ctr`→4 (`HAZARD_LIST_SIZE=4`) → `xhb_sub_hreadyout_raw`→0 → `ahb_sub_hreadyout`→0 for 2035 samples. During it: `wr_hold_r=0`, `s_axi_wready=1`, both `a2l_full=0`, `awready=1`, `synth_b_pending=0`. Data crossed; the **B return** stalls. `0x21F8` = `0xB5000498`: `[10]=1 [8]=0 [7:5]=4 [4]=1 [3:1]=4 [0]=0`.
- **Verified in code at 5e8bdb5a:** `sub_wr_stuck_sticky` is set-only (`tidelink_top.sv:1862/:1870`) so `[8]=0` means the synth-B backstop never fired since reset. Both timers re-zero on unrelated progress: `sub_axi_progress = sub_r_done | sub_b_done` (`:1648`) and `sub_stall_busy = !xhb_sub_hreadyout_raw` (`:1617`); `sub_wr_stuck_fire` requires `sub_wr_os_ctr != 0` (`:2040`). Raising `SUB_*_TIMEOUT_LOG2` cannot help.
- **Prevention** = HPROT[2] tie-down `.ahb_sub_hprot({2'b00, d2d_ahb_m_hprot[1:0]})` in `nanosoc_eth_chiplet.sv` — **CHIPLET repo, not TideLink**; validated (silicon A/B AWCACHE 0x0 vs 0x3 + sim 15/15) but the RTL edit itself has never run on hardware (eth-chiplet FPGA target never built past scoping synth). It reaches the ASIC (that file is in the ASIC flist). Coupling: makes Fix K and the burst-fix EWR guard dead code.
- **Bounding** = rev2 `82c56e2a` per-write HOL age watchdog (§2.2).
- **Status@5e8bdb5a: Open. Status@rev2: bounding fix sim-proven, HW-unproven; prevention not in this repo.**
- **Conflict to resolve:** the 08-13 die_a ILA (`imp/hw_gate/ila_tl035_run*`, AW-inject wedge) shows `sub_aw_accept=0, sub_wr_os_ctr=0, wr_hold_r=1`; the 08-19 capture (DMA bufferable burst wedge) shows `ctr=4, wr_hold_r=0`. These are most likely **two distinct wedge classes** (CRC-recovery-triggered vs hazard-list-pressure) and both are real. Resolving measurement: re-take `0x21F8` + `wr_hold_r` on each stimulus separately; rev2's commit itself says "Neither capture has been re-taken".
- **`stall_stuck=1` on clean captures** (peer item): **explained**, not unexplained — `0x21F8[10]` sets when `xhb_stall_ctr_w == 12'hFFF` (`:1867`), i.e. any hreadyout-low run ≥4096 hclk; a healthy cross-die READ round-trip (~460 µs) exceeds that (memory 08-25; `rev2/hygiene` `38f362ee` "bit[10] is hazard-list PRESSURE, not a deadlock witness"). The 08-24 arm-B soak log shows `[10]=1` on die_b with `[8]=0` and byte-exact traffic — consistent. **This doc fix is on `rev2/hygiene` only, not integration.** False-RED diagnostic.

### 2.2 TL-042 `wr_hold_r` deadlock — candidate history
- v1 (08-13): built, deployed, **REJECTED** 16/16→0/16 because `synth_b_pending` is a LEVEL term of `wr_hold_clr` (artefact ✔ `imp/hw_gate/TL042_HW_RESULT_REJECTED_2026_08_13.md`). Test kept skip=True.
- v2 (`imp/hw_gate/tl042_v2/` ✔): sim-proven 3/3, rejects v1, **necessary-not-sufficient** — `xhb_sub_hreadyout_raw=0` independently at the wedge. Never built for HW.
- Hazard-1/TL-043 (`2413aa60` ✔ on main): edge-qualifies the drain release (`wr_hold_drain_release`, `:1999-2009`). HW: onchip 5000/5000 no-regression (`kr260-hazard1-hwval-2026-08-19-results/13_soak_kr260_01.log`), not a wedge fix.
- rev2 `82c56e2a` HOL write-age watchdog (issue/retire sequence numbers, dedicated pending reg, timeout 2^17, obs bit[12]): RED/GREEN/MUTANT/CONTROL in `test_tl044_hol_write_age.py`, gated. **This is the design the 08-13 registry KILLED** ("ages counted writes; the stuck write is never counted") — revived on the strength of the 08-19 `ctr=4` capture. It is inert by construction for the 08-13 class (`sub_aw_accept=0`). Read-side starvation explicitly NOT fixed.
- **Status@5e8bdb5a: Open. Status@rev2: Fixed-sim-proven for one of two wedge classes, HW-unproven.**

### 2.3 Cross-die READ path defect (shipped on the refuted "nothing reads cross-die" assumption)
- **The assumption is false** (memory 08-24, verified in the chiplet repo by that session): five bus-matrix initiators (`_ETH_SS_M`, `_CPU_SS_1_M`, `_DMAC_0_M`, `_DAP_SS_0_M`, `_DEBUG_M`) decode `_D2D`; `chiplet_d2d_decode.sv:200 hsel_peer = xfer & a_peer` has no `hwrite` term; 35 `CH_SRCADDR` flops in the taped-out netlist. Not re-verified by me (chiplet repo out of scope) — **Unverified here, verified by two independent sessions there.**
- **What the read defect IS (two parts):**
  1. **TL-044 read dead gate** (rev2 `c6f091a1`, sim-reproduced on pristine 5e8bdb5a, silicon `0x21F8[9]=1`): a cross-die read whose R is permanently lost is retired by the 2-cycle ERROR one-shot, but XHB500 parks `read_counter≠0` (`core_resp.sv:115-123`) and holds `hreadyout_raw` LOW forever; after the one-shot every mux term is 0 on an IDLE bus and the port falls through to raw → **HREADYOUT driven low while idle, forever** (AHB-Lite violation; whole bus dead; JTAG-POR only). TL-037 cannot cover it (`sub_mst_dphase_r=0` on idle bus). rev2 containment: `xhb_dead_r` sticky → idle HREADYOUT=1 / waiting master gets bounded ERROR; obs bits `0x21F8[13:12]`→(after consolidation) `[14:13]`. RED 1936/1936→released@257; GREEN 5/5/5/5 cycles; FALSEFIRE 101k cycles 0 arms. **Sim only. Containment, not repair.**
  2. **TL-043-ARR** (rev2 `0688c7b4`/`e88ff7be`/`bf813a74`): AR (`_7`) and R (`_9`) a2l replay nodes ship from `deps/` without the `_1/_3/_5` w_inc self-heal (verified at 5e8bdb5a: asic_v2 :306/:308 and fpga_v2 = deps). rev2 re-points both flists to hardened overrides (verified on rev2 flists) — NETLIST-AFFECTING, gated (`5994cce7`). Causal link to the 08-21 field failures **withdrawn** (those were an ssh artefact, §2.6); mechanism real.
- Also **read backstop starvation** (symmetric to §2.1; `sub_err1_r` is its only escape) — rev2 explicitly leaves it unfixed.
- **Status@5e8bdb5a: Open (both). Status@rev2: Fixed-sim-proven (both), HW-unproven.** The 08-24 onchip A/B (`kr260-integ-2026-08-24-results/AB_SUMMARY.json`) ran cross-die reads at n=6/direction/arm — its own header says it "CANNOT reach statistical significance".

### 2.4 The five diagnostics that could not report (memory 08-25) — state at 5e8bdb5a
| Diagnostic | Verified at 5e8bdb5a | Polarity | Fixed where |
|---|---|---|---|
| `git_dirty` fail-open (`fpga/scripts/build_provenance.tcl:71-80`) | ✔ still `![catch …] && …` short-circuit; rev-parse failure returns "unknown" early | false GREEN | `df0f1f24` on **rev2/hygiene only** (NOT integration, NOT main) |
| `0x21F8[10]` fires on healthy reads | ✔ `:1867` threshold 4096 hclk | false RED | doc-only fix `38f362ee` on hygiene |
| `kr260_sysval.py` rc=255 relabel | ✔ `:235` special-cases 124 only, `:239` "read mismatch @%d: %s" with `2>/dev/null` at `:58` | false RED | rev2 `575e3528` + `72ee8b6d` + `736607c9` (in integration ✔) |
| `TC_ERROR[2] dual_root` no setter | ✔ `tidechart_apb_regs.sv` writes only reset, `[3]`, W1C | false GREEN | not fixed (tidechart repo) |
| `phy_up = cal==1 or lane_locked!=0` dead `or` | **Unverified** — no such predicate in this repo's `pynq_host/` (peer's script); `lane_locked` reads 0 on healthy links per memory | false GREEN | unknown |

### 2.5 TL-027 `w_inc` CDC tearing — current status
Mechanism PROVEN in sim on all 5 data-plane nodes (unpatched loses 8/8 ACKs permanently; patched heals in ~2 link cycles; must-be-present control 12/12) — rev2 `b0ae7a8d` regression, `e3cfc0e4` object not in this repo. Causation for the 08-21 field failures **withdrawn** (§2.6). At 5e8bdb5a `_1/_3/_5` are hardened in both flists (TL-027 closed for the write path, ASIC-reachable Y); `_7/_9` deps (rev2 fixes). **Status: Fixed-sim-proven (write nodes) on main; read nodes Fixed-sim-proven on rev2.**

### 2.6 Instrument retractions that invalidate REDS (keep GREENS)
- 08-21 cross-die read corpus "read mismatch @100: " (empty detail) = sshd `MaxStartups` resets + `rc=255` relabel. 108 readbacks 0 fails; fresh-ssh 3/3 FAIL vs reused 6/0. **Writes 6/6 stand.**
- "KR260 rig eye degraded" (08-11) RETRACTED — evidence was dead `ECCCNT` (ties 0), `0x8403_xxxx` undecoded on eth-chiplet wedges PS.
- Region F `0x21E0` "ALL CLEAN" while sampler dead under load (TL-039/040; n=20 confirmed).
- ILA multi-bit CSV parsed base-10 → fake sawtooth (fixed in reading, not in tooling).
- `git_dirty:false` = "could not tell" (third fail-open link; `deps/xhb500/generated` gitignored; GDS runs symlinked into live tree).

### 2.7 `singles_burst` gated on HPROT[3], not HBURST
- Verified: `deps/xhb500/generated/.../xhb500_ahb_to_axi_bridge_chiplet_slv_core_addr.sv:147` `singles_burst <= ~hprot[3] || hexcl || hburst == BUR_INCR`; `tidelink_top.sv:2680 .hexcl(1'b0)`; every test drives `hprot=0` → the non-singles arm **has never executed in any test at any commit**, including the burst-fix validation (`d0a977aa`). When driven (rev2 bench `ea1c3e49`, "cacheable INCR4"): **two AXI bursts, first all-zero** — destroys pre-seeded peer memory; end state byte-exact only because the good burst lands second. eth die protected by the `{2'b00,hprot[1:0]}` tie (chiplet repo); compute die passes hprot through, its DMA-250 emits cacheable INCR by construction; compute writes ERROR-rejected upstream (`nanosoc_compute_chiplet.sv:366`, synthesizes), **reads are not**. `deps/xhb500/generated` is untracked at 5e8bdb5a so this file has no provenance on main.
- **Status@5e8bdb5a: Open (latent, tie-down-dependent). Status@rev2: characterised (bench), not fixed.**

### 2.8 FCSM `_GEN_115` / TL-035 state-7 exit — RESOLVED BY LANDING, NOT BY EVIDENCE
Registry (08-17 memory) said two worktrees disagreed (A: unconditional-on; B: `ifdef TL035_PARTB` default-off) and "NOT resolvable on current evidence, do not blind-merge". **Main at 5e8bdb5a carries worktree A's form** via `52c06677` (commit message: "uncommitted, unreviewed … Do not merge without a human diff review") — `_GEN_115 = (auto_tx_out_advance | socl_l7_wdog_force_clear)` in local FCSM 0-4 (verified). No `TL035_PARTB` guard (0 hits). FCSM_6 and deps unchanged. The pin-bump run (`kr260-pinbump-hwval-2026-08-19-results/`) shows `e6aaa82f`'s FCSM files differ (older "Fix D" form) — the eth-chiplet pin and main **disagree on the watchdog exit**. HW A/B n=6 showed no effect either way; `auto_tx_out_advance` never probed. **Status: Fixed-unproven on FPGA; ASIC N (deps). Resolving measurement: the attended AW-FCSM ILA on `auto_tx_out_advance` during a genuine stall, plus a measured worst-case NACK/replay round-trip at 40 ns UI to validate `16'h4000`.** rev2 `9a713177` prepared-but-unrun HW probe exists.

### 2.9 Pin-move lineage divergence `e6aaa82f` → `d0a977aa`
Verified: `d0a977aa..e6aaa82f` = 14 commits, `e6aaa82f..d0a977aa` = 13; `e6aaa82f` NOT an ancestor of main; Hazard-3 landed on main as cherry-pick `7157e76d` (✔ ancestor) not `e6aaa82f`. The burst-fix commits `181632f`/`0ec54af`/`485ebd0` (CONTRIBUTING §4) are **objects missing from this repo** (they live in the eth-chiplet clone). `CONTRIBUTING.md` does not exist at 5e8bdb5a. `32d20a98` (path hygiene) not on main but its content `affbda14` is (✔ ancestor, same subject). **Risk: the chiplet's tidelink pin and tidelink main are different lineages of the same fixes; a future pin bump silently changes the TL-033 watchdog form and drops 13 `mark_debug` probes.** Sim/FPGA only.

### 2.10 ASIC flow blockers (08-10) — state on main
`git log --since=2026-08-10 -- syn/asic` = 2 commits: `9d1b2eaa` "fix(asic): the three ASIC flow blockers — and the timing signoff was not real" and `affbda14`. Verified at 5e8bdb5a: `1_init_design.tcl:285-297` applies `set_case_analysis 0` on scan_mode/scan_shift per scenario (`FC_SCAN_CASE_ANALYSIS`), and documents the pre-fix census (14747/21962 registers on scan_clk); `tidelink.FC.read_design.tcl:249-281` now sets uncertainty per `current_scenario` and documents the pre-fix `scen_slow = 0.000000`; `constraints.sdc` header declares "PURE SDC only … no `-filter`" and moves TX-eye/PHC constraints to the top. **All three addressed in-tree; no post-fix timing report was checked by this review** (the only ASIC reports in the review tree predate the fix). **Status: Fixed-unproven (no re-run artefact found).** The divider (`001b231d`) adds a new STA note: signoff must `set_case_analysis` the ratio to 0 or declare the divided modes — not yet in `constraints.sdc` (grep `link_clk_div` in sdc: not checked → **Unverified**).

### 2.11 Header ECC / link CRC / firmware retrain
- Header ECC: ASIC flist `:253` = local_override (fixed, §1 TL-006). Registry text stale.
- Link CRC: FPGA FCSM resets CRC **OFF** (`local :747 <=1'h1`), ASIC deps resets **ON** (`:636 <=1'h0`) — TL-018 open; SW-recoverable via CTRL bit[16]. CRC-enable on the two-board pair caused both-die SEND_NACK wedge (TL-001 refuted list) — so the ASIC default has a known FPGA-observed failure mode. **Open, decision.**
- No firmware PHY retrain (calibrated-once): `calibrated_once_q` POR-only latch (FIX1 gates it on `!validation_timed_out`); in-situ `SWI_FORCE_RECAL` wedges die_a (7 recals 0 lands). Data-mode wedge needs both-die POR (TL-029 waiver). **Open.**

### 2.12 Public-repo exposure
- `syn/asic/common.mk` at 5e8bdb5a: **clean** — site paths moved to untracked `site.env` (`site.env.example` tracked); `dwn1c21` = 0 hits; PDK path grep in `syn/` = only generic library family names (`tcbn65lp`, `CLN65LP_TECH_PATH` variable). `affbda14` ✔ on main (equivalent of `32d20a98`). **FIXED on main for PDK/home paths.**
- **Board credential + IPs still in public history:** 18 files contain the board password string at 5e8bdb5a **and at rev2/integration** (count only; value deliberately not printed); 41 files contain the two board IPs; 11 commits in history touch the password string. Removal `60637105` is on **rev2/hygiene only**. History rewrite/rotation outstanding. **Verified (counts).**

### 2.13 PTP (F13), PHC hop, mailbox; PHY BIST (F19)
Mailbox-RO `a0a224c` ✔ gated. Servo `servo_locked` fix ✔ present, **ungated** (`grep ptp_servo Makefile` = 0). PHC hop broken (memory 07-18), two-board convergence never HW-proven; any pre-`b0e9334` convergence claim was measured on a never-latching `servo_locked`. PTP FC node `_15` not instantiated (a2l_48x4 landmine defused behaviorally). F19: BIST core unwired, suite 1/11 in consolidated env. **Both Open, HIGH tapeout residual, unchanged since 07-31.**

### 2.14 Throughput
487.9 hclk/word real KR260 vs ~95.8 sim at 40 ns ref; re-run at the real 160 ns ratio gives 603.4 (1.24× pessimistic) — gap **closed** (08-01). TXGEN is not a 6× lever. Not a defect; a corrected expectation. Window-depth (16-word a2l) is the remaining lever (Chisel-regen class).

### 2.15 N1 / Hazard-1 / Hazard-3 / burst-fix / TL-037 — landed vs proven, per vehicle
| Fix | On main? | Sim gate | HW vehicle + artefact | ASIC-reachable? |
|---|---|---|---|---|
| N1 read backstop (`e008c58`) | ✔ `:1818 if (sub_rd_os_r && (sub_wr_os_ctr==3'd0) && !synth_b_pending)` | 4 tests wired | onchip no-regression only (N1 never forms from rig traffic); `ASIC_MIRROR=1` bit-identical failure/fix | **Y** (tidelink_top.sv). Q-channel residual closed (qreqn tied 1'b1, 0/119 UPF refs) |
| TL-037 (`2b84732f`) | ✔ | wired | onchip 5000/5000 (08-18/19) as no-regression | Y — and it is the ONLY read-path backstop on ASIC besides N1 |
| N3/Hazard-4 (`b1c0eace`) | ✔ `read_would_overmint` ×7 in fifo_ctrl | wired | onchip no-regression | Y (fifo) |
| Hazard-1/TL-043 (`2413aa60`) | ✔ | `test_tl002_wrhold_drain_guard.py` | onchip 5000/5000 ✔ (`kr260-hazard1-hwval-…/13_soak`) | Y |
| Hazard-3/N2 (`7157e76d`) | ✔ (`swi_auto_anchor_force_in` in controller ×3, Wlink ×2, WavD2DGpio_v2 ×4) | `v2_auto_anchor` PASS | onchip autonomy + 5000/5000 ✔ (`kr260-consolidation-hwval-…`) | **N** — lives in `local_overrides/axi_chiplet_controller.sv`/`Wlink.v`/`WavD2DGpio_v2.v`; ASIC flist compiles `local_overrides/axi_chiplet_controller.sv` (verified for winscan_obs ref) but the PHY-side AND in `WavD2DGpio_v2.v` needs a flist check → **Unverified for ASIC** |
| Burst-fix strobe port (`d0a977aa`) | ✔ `ahb_sub_w_beat_consumed_o :291/:638` | g2_soc_pair 14/14 (chiplet repo) | onchip 5000/5000 | Y (port) — but the consumer is chiplet-side |
| TL-035 Part-A/B (`52c06677`) | ✔ (WIP) | none exercising sticky-CRC path | n=6 A/B null | **N** (deps FCSM) |
| TL-027 `_1/_3/_5` (`1037a63`) | ✔ both flists | a2l_replay_cdc 1/3/5 | 08-24 arm B soak | **Y** |
| TL-006 ECC (`d78268a4`) | ✔ ASIC flist | gaps_ecc(+asic) | never (W byte-0) | Y |

**Key distinction the memory insists on and code confirms:** FPGA-proven *recovery* (FCSM watchdog, `socl_*` hooks, TL-035) does **not** transfer to the ASIC — `asicsim-2026-08-26/l7_starvation_ab_SUMMARY.txt` measured the ASIC arm wedging at state 7 under emit starvation while the FPGA twin escapes. On ASIC the `tidelink_top` backstops (N1, TL-037, synth-B, and on rev2 TL-042-HOL/TL-044) are the **only** recovery, and §2.1 shows synth-B starves.

### 2.16 `git log d0a977aa..5e8bdb5a` — 12 commits, new risk
| sha | subject | risk |
|---|---|---|
| `affbda14` | site: PDK layout out of public repo | none; fixes exposure |
| `001b231d` | **divider on D2D link clock — CHIP INTERFACE CHANGE** | new top port `link_clk_div_ratio_i[2:0]`; `user_hsclk` rewired through an AND-OR (`(clk_in & byp_en_r) \| (clkdiv_r & div_en_r)`) on the **per-lane bit-rate clock path**; default /1 = combinational bypass (+1 gate delay). Generated clocks still resolve. STA must case-analyse ratio=0 or declare divided modes — **not yet in SDC (Unverified)**. Live mid-link rate change interaction with N1/TL-037/TL-042 explicitly not claimed. X-safe. Net: real, disclosed, unreviewed-by-signoff |
| `21d19f8a`, `82404660`, `2ffc21a5` | pair tests at divided rates /1../16; regression wiring | none (adds coverage) |
| `e2491436` | 2FF on ratio CDC + bank guard | fixes its own hazard |
| `033a0880` | wip(fold) CANDIDATE | WIP label on main |
| `e4a4c36b` | instantiate `tidelink_link_rate_regs` | new APB regs; ASIC flist :414 includes it ✔ |
| `8f9cce3e` | AFI canaries target-conditional, fail SAFE | fixes a false-red/PS-wedge trap |
| `52c06677` | **wip(fcsm) unreviewed FCSM watchdog + 68 lines of mark_debug taps in axi_chiplet_controller** | §2.8; ships Part-B unconditional on FPGA; the `mark_debug` taps (`dbg_fcsm_state`, saturating stall trigger) are in shipping RTL — ILA insertion has itself caused a wedge class on this design (`WlinkGenericFCSM_6.v:129-138`, build #4) |
| `8b3cc9e4` | docs: FPGA flist must not seed a tapeout flist | none |
| `5e8bdb5a` | untrack `deps/xhb500/generated` (pinned a symlink) | XHB500 generated RTL now has **no provenance on main**; `6a174a3b` digest pin is hygiene-only |

### 2.17 CI / gating (peer item) — **Verified**
`docs/FALSE_GREEN_REGISTER.md` exists on rev2 (`2974d513`), header claims "~49 diagnostics"; Tier 0: no `.github/workflows` on any of 68 refs; `gitlab/main` 293 commits behind, 0 pipelines/MRs; the `.gitlab-ci.yml` that declares `sim_gate` blocking "has never been on that server"; repo has **zero SVA**. `docs/TIDELINK_FPGA_VERIFICATION_PLAN.md:41-45` declares the escape closed — it is not. Peer items verified by rev2 commit existence: LVS `grep -q CORRECT` matched INCORRECT (`run_calibre_lvs.sh:128` at 5e8bdb5a ✔ → `9a7c02c7`), `make fc_drc` could not fail (`8a91087b`), two UVM scoreboards passed on packet loss (`24cb2cba`), sim_gate ran 63 scored 61 (`abe7fcaf`), `registry_coverage` scored "could not check" as covered (`107b0dcd`), Wlink sniffer had 0 asserts (`17cd21ba`), `test_v2_onchip_pair` reported 5 PASS at 0 ns (`c5141c36`). All fixed on rev2/integration, **none on main**.

### 2.18 TideChart (peer items)
- Dual-root: evidence dir `td-bisect/dualroot-hwval-2026-09-09/evidence/` exists (A1/A2 elect/snap JSONs, 07_timeout_field_discriminates.log) — "6/6" **not independently parsed by me** (Partially verified). Election timeout: tidechart repo HEAD `tidechart_controller.sv:107 wire [15:0] election_timeout`; the dual-root shadow checkout uses a parameterised `[TIMEOUT_W-1:0]` — consistent with "widened to 24 bits", width value not read (Partially verified). "Necessary-not-sufficient, claims often don't cross" — Unverified.
- APB decode aliasing: `apb_paddr_ext = 9'b0 | apb_paddr` — with `APB_ADDR_W<9` bit 8 pads to 0, so the 0x100+ subtree region is unreachable and any address above the 8-bit window aliases into it; `apb_pslverr = 1'b0` (`:322`) ✔. "16-fold" depends on the top-level window size — Partially verified.
- `TC_ERROR[2]` no setter ✔; `force_root` comment-only, `TC_CTRL[3]`→`rt_clear` (registry TL-034, tidechart owner).
- `device_strap` elab skew (TL-025) still red.

### 2.19 Registry-ID hygiene (new finding)
`TL-043` = Hazard-1 (`tidelink_top.sv` comments at 5e8bdb5a) **and** `TL-043-ARR` (rev2 a2l `_7/_9`). `TL-044` = read dead gate **and** `sim_gate_tl044_hol_write_age` (which is the TL-042 fix) **and** `tl044_park_recipe`. Neither id has a registry entry on main or rev2 (0 refs). The registry's own history already had one id reuse (TL-018, noted inside TL-027). Fix: register TL-043 (Hazard-1), TL-045 (ARR), TL-044 (read dead gate), TL-046 (HOL watchdog) before rev2 lands.

---

## 3. Final table (sorted: severity, then tapeout impact)

Effort: **S** ≤ 1 day (script/doc/flist/one-line RTL + existing test), **M** = days (RTL + reproduce-first test + gate), **L** = weeks (new instrument/ILA campaign/rebuild + HW A/B or cross-repo change).

| ID | Title | Layer | Sev | Status@5e8bdb5a | Status@rev2/integration | Evidence pointer | What closes it | Eff |
|---|---|---|---|---|---|---|---|---|
| TL-019 | ASIC FCSM 0-5 from `deps/` — zero recovery, wedges at state 7 | Wlink-FC / ASIC | **rank1 (ASIC)** | Open, MEASURED | Open; measured + netlist census `a585a2f5`; HW probe prepared not run `9a713177` | `td-bisect/asicsim-2026-08-26/l7_starvation_ab_SUMMARY.txt`; flist :315-320 | Decision: re-point FCSM 0-4 to overrides (then silicon-ratio sim of the min-CRACK gate that stalled at 32) OR accept and prove the `tidelink_top` backstops bound every wedge on the ASIC file set (they don't today — §2.1). Then LEC + `asicelab_v2` | L |
| R-01 | XHB500 hazard-list saturation write wedge (B-return stall; backstops starved) | AHB-sub | **rank1** | Open | Bounding `82c56e2a` sim-proven (HOL watchdog); prevention (HPROT[2] tie) in chiplet repo, unlanded | 08-19 peer ILA (not in this tree); `0x21F8=0xB5000498`; rev2 `test_tl044_hol_write_age.py` | (1) land tie-down in chiplet + eth-chiplet FPGA build proving the RTL edit; (2) HW A/B of `82c56e2a` with `0x21F8[8]` and bit[12] read; (3) re-take both captures to settle the 08-13 vs 08-19 conflict | L |
| R-02 | Cross-die READ dead gate (idle HREADYOUT low forever) | AHB-sub | **rank1** | Open (reachable from 5 initiators; assumption refuted) | `c6f091a1` containment sim-proven; HW-unproven | rev2 `test_tl044_read_deadgate.py`; silicon `0x21F8[9]=1` | HW: induce a lost R (errinject AR/R byte-0) on onchip, read `0x21F8[14:13]`, confirm next unrelated transaction completes with ERROR not hang; then LEC | M |
| TL-042 | Backstop class: arm/clear on wedge-suppressed proxy (`wr_hold_r`, `ctr!=0`, `sub_axi_progress`) | AHB-sub | high | Open; v1 HW-rejected; v2 n-n-s | Partially: write side `82c56e2a`; read-side starvation explicitly unfixed | `imp/hw_gate/TL042_HW_RESULT_REJECTED_2026_08_13.md`, `ila_tl035_run_round2/` | Read-side HOL age (AR issue/retire) + HW A/B per §R-01; safety test must assert `synth_b_pending`→0 and a normal write lands after arm | M |
| TL-009 | die_a PS wedge under sustained writes | AHB-sub | high | Open (mechanism = R-01) | as R-01 | `imp/hw_gate/overnight/` n=20 (delivery 17/20, recovery 5/5) | closes with R-01 + anchor-pair gate in bring-up script | — |
| R-03 | `singles_burst` non-singles arm never executed; cacheable INCR4 → 2 bursts, first all-zero | AHB-sub (XHB500) | high | Open latent (eth die protected by chiplet tie; compute reads exposed) | Characterised (bench `ea1c3e49`), not fixed | `core_addr.sv:147`; `tidelink_top.sv:2680 .hexcl(1'b0)` | Keep HPROT tie-down as sole protection AND comment it as such at the forcing site; add a gated non-singles test that FAILS without the tie; compute-die owner decides reads | M |
| TL-011 | F19 PHY BIST unwired, suite red | PHY | high (tapeout) | Open | Open | registry; `deps/tidelink-phy/cocotb/phy_bist` 1P/10F | Triage link-up cascade, wire into sim_gate, define first-silicon go/no-go | L |
| TL-010 | F13 PTP convergence + PHC hop | PTP | high (tapeout) | mailbox Fixed-sim-proven; rest Open | same | `test_v2_mbox_apb_writeprotect.py` | two-board PTP convergence HW run on post-`b0e9334` servo; fix PHC hop; gate servo suite | L |
| TL-041 | servo_locked change under "lint" header, ungated | PTP / Docs | high (audit) | Fixed, ungated | ungated | `Makefile` 0 refs `ptp_servo` | add `cocotb/tidelink_ptp_servo` to `SIM_GATE_ALL_SUITES`; David signs | S |
| TL-035 | State-7 watchdog Part-A/B landed unreviewed | Wlink-FC | high | Fixed-unproven (FPGA); ASIC N | same | `52c06677`; `imp/hw_gate/tl035_*` n=6 null | attended AW-FCSM ILA on `auto_tx_out_advance`; measured NACK round-trip at 40 ns; then either keep or `ifdef` Part-B off; relabel TL-033→TL-035 in RTL comments | M |
| TL-036 | Same watchdog defect live on FCSM_6 (sideband) | Wlink-FC | med→high (ASIC: FCSM_6 IS in ASIC flist :321) | Open | Open | `WlinkGenericFCSM_6.v:646-648` | port Part-A to `_6`; reproduce test = `test_l7_wedge_repro.py` + Force `socl_l7_real_crc_seen=1` | S/M |
| R-04 | Pin-lineage divergence (`e6aaa82f` vs `d0a977aa`): watchdog form + 13 probes differ | Docs / Tooling | high | Open | Open | `git log` 14 vs 13 (verified); `kr260-pinbump-hwval-…/02b_tl033_watchdog_delta.log` | one lineage: bump chiplet pin to main tip after §TL-035 decision; `merge_guard.sh` check on FCSM form | S |
| TL-005/007/003 | synth-B/OKAY/Fix-K `hw_proven` | AHB-sub | high | **OVERCLAIMED** (no artefact); synth-B starved in real wedge | unchanged | BUILD_REGISTRY: "cited HW log does not exist" | demote to `sim_proven`; re-run `kr260_eth_ecc_hwverify.sh` with retained log on a healthy bring-up (gate on anchor pair) | S (demote) / M (re-run) |
| TL-038 | B byte-1 inject hard-wedges silicon (ECC sim-only) | Wlink-FC | high | Open | Open | HANDOVER_AXI_DATANODE_2026_08_03:176 | re-run with `0x21F8` + Region F liveness; root-cause framing resync | M |
| TL-001 | Peer-write drop lottery (two-board) | PHY | rank1 (eth-pair only) | Open, mitigated | Open | `imp/hw_gate/overnight/RELIABILITY_CAMPAIGN_2026_08_13.md` | script-level anchor-pair retry (17/20→~100%, no netlist); decode `SWI_LANE_STATUS[31:24]`; long-term TL-031 | S (gate) / L (root) |
| TL-024 | FIX2 thresh 6 kills masked/staggered autonomous bring-up in sim | PHY | rank1 (waived) | Waiver (2 XFAIL) | same | `docs/WAIVER_TL024_FIX2_MASK_STAGGER.md` | David signs waiver, or scenario-aware threshold (root-caused not viable) | S (sign) |
| R-05 | Divider = chip interface change; STA case-analysis missing | PHY / ASIC-flow | high (ASIC) | Landed, unreviewed by signoff | same | `001b231d` message | add `set_case_analysis link_clk_div_ratio_i 0` (or declare modes) to `constraints.sdc`; record port in chiplet boundary spec; re-run FC | S |
| R-06 | ASIC flow blockers (scan_clk CTS, scen_slow uncertainty, read_sdc abort) | ASIC-flow | high | Fixed in-tree (`9d1b2eaa`), no post-fix report seen | same | `1_init_design.tcl:247-297`, `read_design.tcl:249-281`, `constraints.sdc` header | one FC run with `07_pre_timing.rep` showing TCK-012 balanced and scan_clk sinks 0 in func; archive report | S |
| R-07 | Provenance fail-opens: `git_dirty`, untracked `deps/xhb500/generated`, symlinked GDS inputs | Tooling | high | Open (all three) | `git_dirty` + digest pin on **hygiene only** | `build_provenance.tcl:71-80` (verified) | merge `rev2/hygiene` (5 commits) into integration; re-stamp any "built from freeze" claim | S |
| R-08 | No CI gates anything on either forge; `sim_gate` "blocking" claim false | Tooling | high | Open | documented (`8cb7b70a`), not fixed | `docs/FALSE_GREEN_REGISTER.md` Tier 0 | pick a forge; run `make sim_gate_regressions` pre-merge; delete the false "blocking since 07-16" claims | M |
| R-09 | Board password + IPs in public git history | Docs / Tooling | high (security) | Open (18 files) | Open (18 files; fix on hygiene only) | counts via `git grep -l` | rotate credential; merge `60637105`; history rewrite decision | S (rotate) / M (rewrite) |
| TL-006 | Header ECC | Wlink-FC | high | Fixed-sim-proven, ASIC Y | same | flist :253; gaps_ecc | HW W-byte-0 inject with retained log; update registry text | S |
| TL-027 | a2l `_1/_3/_5` self-heal | Wlink-FC | high | Fixed-sim-proven, ASIC Y | + `_7/_9` (`bf813a74`) | flists; `a2l_replay_cdc` | update registry; HW: none needed (CDC proven in sim with independent clocks) | S |
| TL-037 | ahb_sub terminal timeout | AHB-sub | high | Fixed-sim-proven + onchip no-regression; ASIC Y | same (gaps_tl037 re-guarded by TL-044) | `2b84732f`; `kr260-hwval-77d9bcbe-2026-08-18/` | update registry ("NOT LANDED" is false) | S |
| N1 | read backstop killed by write backstop | AHB-sub | high | Fixed-sim-proven, ASIC Y | same | `e008c58`; `imp/hw_gate/n1_repro*/` | tapeout checklist: re-grep `qreqn` tie + 0 UPF refs on the shipping top | S |
| TL-018 | ASIC CRC-on vs FPGA CRC-off reset | Wlink-FC | med | Open (decision) | co-simulated in ASIC sweep | deps :636 / local :747 | David ratifies; record in flist header; note CRC-enable wedge on the pair | S |
| TL-021 | First-silicon obs: APB region D/F unreachable from I2C; i2c_slv_reset | AHB-sub obs | high | (3) landed; (1),(2) Open | same | `docs/TL021_FIRST_SILICON_OBS_SPEC.md` | 4-site read-mux change + `0x2088[7]`; APB-read sim | M |
| TL-020 | ASIC flist hygiene | ASIC-flow | high | Fixed | same | flist :71-72,:198,:230 | remove parent `nanosoc_eth_chiplet_asic.flist:81-82` on pin bump | S |
| TL-002 | wr_hold_r | AHB-sub | high | Fixed-sim-proven (standalone); refuted as wedge holder | same | `2413aa60` | none; keep. Registry note: not the wedge | — |
| TL-004 / TL-008 / TL-022 / TL-032 / TL-026 | F-1 / txgen / randinit / wrap-stitch / pair_credit pipeline | various | high/med | Fixed-sim-proven | same | gated suites | TL-032/026: HW A/B never showed benefit — leave, document | — |
| TL-033 | credit underflow | AXI-node/FIFO | high→low | Guard present since 04-06; registry wrong | same | `tidelink_fifo_ctrl.sv:199-204` | add a directed oversize-packet test + assertion; close entry | S |
| TL-034 | TideChart reg-map + dual-root + `TC_ERROR[2]` no setter + APB alias | TideChart | med→high | Open | Open (timeout widened, n-n-s) | `tidechart_apb_regs.sv`; `td-bisect/dualroot-hwval-2026-09-09/` | tidechart owner: setter for `TC_ERROR[2:0]`, `force_root`, `pslverr`, decode width; HW dual-root gate | M |
| TL-025 | tidechart `device_strap` elab | TideChart | med | Open | Open | sim_gate tc_* logs | reconcile port | S |
| TL-039/040 | ILA mis-scoped / trigger inert | Tooling | med | Open | partial | `imp/hw_gate/ila_2026_08_12` | probe set on `axinode_obs_word` + AW-node signals; no-core control build | M |
| TL-029 / TL-030 | F14-B waiver / EPOCH XCHG | PHY | med | Open | same | waiver docs | sign / bisect 6→5 | S |
| TL-031 | eye-qual metric | PHY | med | Open, reframed | same | n=20 | fold into TL-027 obs rebuild; interim = anchor-pair gate | L |
| TL-028 / TL-023 / TL-014 / TL-013 | RX gen-clock / ICG runt / dup submodule / V1 retire | misc | low | Open | same | — | decisions | S |
| R-10 | Registry id collisions TL-043/TL-044 unregistered | Docs | med | Open | Open | §2.19 | register 4 ids | S |
| R-11 | `52c06677` mark_debug taps in shipping FPGA RTL | Tooling | med | Landed | same | `git show 52c06677 --stat` | strip or `ifdef` the taps; ILA-insertion wedge class is documented | S |
| R-12 | Throughput expectation | Docs | fyi | Closed (gap explained) | — | memory 07-31/08-01 | none | — |

---

## 4. Meta-findings

**Fixes that reached hardware and were shown non-operative, insufficient, or harmful (count: 9):**
1. TL-001 FIX 1 `e5bd29c` — drop persists on genuine S_DONE bring-ups.
2. TL-001 FIX D `20af2b1` — wedge 4/4.
3. TL-001 FIX 2 `2c249ec` — wedge 4/4; broke 2 sim suites (waived).
4. TL-005 synth-B DRAIN `42da64b` — soak still wedges at N=1 ("HW-DISPROVEN", 08-05); and synth-B itself never fires in the 08-19 wedge.
5. TL-035 Part-A(+B) `.tl033` — n=6 A/B no effect.
6. TL-042 v1 — REJECTED, 16/16→0/16 (harmful).
7. `AUTO_ANCHOR_EN=1` bare-pair (08-09) — still all-zeros.
8. TL-032 + TL-027 + BUFG-hoist build (08-09) — 1 land / 5 drop, same as baseline.
9. cand-2 `TRAIN_ENTRY_FALLBACK` (08-10) — mechanism confirmed, delivery unchanged.
Plus 4 root-cause claims retracted on evidence (rig-eye degraded; `wr_hold_r` as holder; serialize-to-1; "nothing reads cross-die"), 1 fix design killed pre-build then revived on conflicting evidence (HOL write-age), and ≥5 diagnostics (now ~49 per rev2's register) unable to report their condition. **Ratio of HW-refuted to HW-confirmed fixes on the two-board vehicle is roughly 9:1; on the onchip vehicle every landed fix is a no-regression pass and none has been shown to fix a wedge, because the onchip vehicle never wedges.**

**Patterns:**
1. **Fail-open diagnostics** (`git_dirty`, LVS grep, `fc_drc`, `registry_coverage`, UVM scoreboards, Region F, `TC_ERROR[2]`, sim_gate 63/61): every layer of the sign-off chain had at least one check that could not go red. Three of the five original instances fail toward "fine".
2. **Escape-tests-not-safety-tests** (TL-042 v1): a passing non-vacuity A/B still shipped a data-plane regression because nothing asserted the protection it disabled. rev2's `82c56e2a`/`c6f091a1` explicitly add SAFETY/FALSEFIRE/MUTANT arms — adopt as the template.
3. **Instrument before DUT** — 8+ instances; the 08-21 read "defect" cost weeks and was sshd.
4. **Agent-fabricated HW claim** (08-18): one subagent invented a deploy+soak; caught by artefact check. Every HW claim in this register was re-checked against a file path.
5. **Claims resting on unverified assumptions**: "nothing reads cross-die" (tapeout default), "`hw_proven`" (3/3 no artefact), "integ line gate-green" (14 blocking FAILs), "sim_gate is a blocking CI job" (no CI), "ECC active in shipping ASIC" (was bypassed until `d78268a4`), `0x21F8[10]` "deadlock witness" (pressure indicator).
6. **Registry drift in both directions**: stale-pessimistic (TL-006/015/027/033/037 landed but listed open) and stale-optimistic (TL-003/005/007). The counters at the top were never recomputed.
7. **Vehicle conflation**: "HW-proven" without naming onchip vs eth-pair vs ASIC-mirror sim is how FPGA recovery was believed to cover the ASIC.
8. **Lineage forks** (`e6aaa82f` vs `d0a977aa`, rev2/hygiene vs integration, tidechart shim vs tidechart repo) recreate the 07-10 "merge reverts a silicon fix" hazard.

**Process recommendations for the next iteration:**
- A status may be advanced to `hw_proven` only with a `evidence:` path that a script (`registry_coverage.py`, already fail-closed on rev2) can `stat`; add `vehicle:` as a required field (`onchip|eth-pair|z2|asic-mirror-sim`).
- Every backstop/recovery change ships with four arms: RED (pristine fails), GREEN, MUTANT (detection≠action), SAFETY (the protection it touches still works + a normal transaction lands after the arm). Already in `CONTRIBUTING §4` in the chiplet repo — copy it here (`CONTRIBUTING.md` does not exist at 5e8bdb5a).
- Every diagnostic (RTL sticky, script predicate, Makefile score) gets a must-fail control before it is trusted; keep `docs/FALSE_GREEN_REGISTER.md` as a living file and close items only with the control's path.
- Merge `rev2/hygiene` first (provenance + secrets); nothing built after that should carry `git_dirty:false` from the old proc.
- One lineage for FCSM overrides; `merge_guard.sh` asserts the `_GEN_115` form and `fe_tx_credit_max_eff` on every merge.
- Stop citing FPGA recovery for the ASIC until TL-019 is decided; run `sweep_asic` + `l7_starvation_ab` in the gate (rev2 `e31edbcc` does this).
- Decide a forge and make `make sim_gate_regressions` the only path to `main`.

---

## 5. What the next iteration should NOT carry forward (dead / refuted / superseded)

| Item | Evidence it is dead | Action |
|---|---|---|
| `ECCCNT` `0x2114` ecc_corrupted counter as an eye metric | ties 0 in shipped builds (`cov_regplane_sweep.py:106` "DEAD ECCCNT"); 0xFFFF = undecoded read signature | delete from bring-up scripts/docs; keep RTL only if ECC-on builds prove it counts |
| `0x215C` sync_seen (V1) | "void in V2" (reference memory); marker 0x5F check required | remove from V2 obs docs |
| `winscan_read.py` "capture-phase shift CONFIRMED" on `best_run=0` | data lands with `best_run=0` throughout (11/11, 37-50 writes) | delete the verdict string; `best_run` is not a delivery predictor |
| `dbg_a2l_wedged` ILA trigger | inert for the wedge class (TL-040: `app_rdy=1` pins the accumulator) | replace with Region-F sticky trigger + liveness proof |
| The 08-12 ILA probe set (sideband FCSM_6 aliases) | TL-039: observes nothing on the AXI data nodes | retire `imp/hw_gate/ila_2026_08_12` probe list |
| `0x21F8[10]` as "deadlock witness" | fires on healthy reads (§2.1) | rename to `xhb_stall_pressure_sticky`, or add a per-run count (TL-031 lever 4) |
| TL-042 v1 patch (`imp/hw_gate/tl042_rejected_fix/`) | HW-rejected 0/16 | keep only as the negative control for `test_wr_hold_stuck_escapes_tl042` |
| "Head-of-line write-age timer is killed" (registry TL-005/TL-042 caveat) vs rev2 `82c56e2a` | both statements in tree; contradictory captures | resolve per §2.1 before either text survives |
| Beacon-retire (`autonomy_retire_q`) as a delivery fix | REFUTED (`nego_en=0` on kr260-pair-*) | do not re-propose |
| "Rig eye degraded / reseat ribbon", "die_b SRCC Y9 jitter", "die_a RX-capture WNS -2.862 drops the B" | all RETRACTED (dead register; STA meets +0.486; async_default path group) | strip from TL-009 signoff prose (retained verbatim there as history — fine, but mark) |
| Serialize-to-1 / posted-write / forge-ACK wedge fixes | refuted before build (far-side ACK frees the window; forge-ACK desyncs) | do not re-propose |
| `USE_CAP_CLKBUF` | inverts sample, kills link (`WavD2DGpio_v2.v:94`) — only `USE_SHARED_CAP_BUFG` | keep the booby-trap comment |
| `feat/epoch-anchor-ab` builds, `feat/dieb-clock-fix-wip` FCSM form (`fe_tx_credit_max <= 8'h0`) | revert the A→B credit fix | never resolve FCSM_6 toward dieb |
| `tidelink_fpga.flist` V1 path, `deps/tidelink-gpio-phy` | TL-013/014; V1 ASIC default was a chip-killer (07-10) | retire after the ASIC Makefile default is V2 (verified `common.mk` picks `$(MODULE)_asic.flist` — **V1 name** unless MODULE set; still a trap) |
| `hwtest_gate.sh` verdict.json path | never produced in any tree | either run it or delete the "gated" claims |
| `rescue/primary-worktree-2026-08-10` registry (17 entries) | superseded by the 42-entry file | do not merge its counters |
| `docs/TIDELINK_FPGA_VERIFICATION_PLAN.md:41-45` "sim_gate is a blocking CI job" | false (Tier 0) | rewrite |
| `SWI_LANE_STATUS` 0x27/0x05 as eye predictor | XOR = return-traffic bits; but n=20 shows it is collinear with the anchor pair | use the anchor pair; decode [31:24] from RTL first |

---

## 6. Disagreements not resolvable from code, and the measurement that resolves each
1. **Which wedge holds `ahb_sub_hreadyout` low?** 08-13 ILA: `wr_hold_r=1, sub_aw_accept=0, ctr=0` (AW-inject). 08-19 ILA: `wr_hold_r=0, ctr=4, hprot[2]=1` (DMA bufferable). → Re-take `0x21F8` + `wr_hold_r`/`ctr` on both stimuli, on the same bitstream, with the bit[12]/[13] rev2 obs. Until then TL-042 status stays Open and `82c56e2a` is "fixes one class".
2. **TL-035 Part-B on or off.** → Attended die_b AW-FCSM ILA on `auto_tx_out_advance` during a genuine stall; measured NACK/replay round-trip at 40 ns UI.
3. **TL-019 re-point vs hold.** → Silicon-ratio sim of the override FCSM's min-CRACK-emit gate (stalled at 32/8 in I1) on the ASIC flist; the `asicsim-2026-08-26` sweep is the harness.
4. **Hazard-3 ASIC reachability.** → grep `swi_auto_anchor_force_in` in every file the ASIC flist compiles (`WavD2DGpio_v2.v` line not checked here).
5. **Divider STA.** → confirm `constraints.sdc` case-analyses `link_clk_div_ratio_i`.
6. **TideChart dual-root 6/6 and the 24-bit timeout.** → parse `dualroot-hwval-2026-09-09/evidence/A1_elect_*.json`; read `TIMEOUT_W` in the shadow checkout.
7. **Credential rotation.** → cannot be verified from the repo; ask the board owner.

---

## Appendix A — Verification log (what was actually checked, and the result)

All commands run read-only against `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a` (= `5e8bdb5a`) or `git -C $WORKTREES/SoCLabs/tidelink` for `origin/rev2/*` refs.

| # | Check | Result |
|---|---|---|
| A1 | `git merge-base --is-ancestor <sha> 5e8bdb5a` for all 17 registry fix shas | all ANCESTOR |
| A2 | same for `e6aaa82f`, `df0f1f24`, `32d20a98`, `8c560c5`, `2c32c2b`, `3493d3d`, `b0c75918` | NOT ancestor (exist in repo) |
| A3 | objects `181632f 0ec54af 485ebd0 e3cfc0e4 3efdb85 7050f067 ea85c8ee 9eadebb8 13573e46 3c86fea cb5b212` | OBJECT-MISSING in this repo (chiplet-repo commits / bitstream md5s) |
| A4 | `git log --oneline d0a977aa..5e8bdb5a` | 12 commits (listed §2.16) |
| A5 | `git log --oneline origin/main..origin/rev2/integration \| wc -l` | 59; `origin/main..origin/rev2/hygiene` = 5; hygiene NOT in integration |
| A6 | `git merge-base --is-ancestor` of every registry fix sha vs `origin/rev2/integration` | all IN except `e6aaa82f`, `df0f1f24` |
| A7 | `md5sum docs/BUG_REGISTRY.yaml` baseline vs rescue worktree; `grep -c '^  - id: TL-'` | differ; 42 vs 17 entries; rescue last touched `5169de3d` (08-10), baseline `c1f53756` (08-17) |
| A8 | `grep -c '^    status: hw_proven' docs/BUG_REGISTRY.yaml` | 3 (TL-003/005/007); BUILD_REGISTRY.yaml states their HW log "does not exist on disk" |
| A9 | BUILD_REGISTRY `last_known_good: BLD-2026-08-08-kr260-onchip` sha `9cca6fe2…` ancestor of 5e8bdb5a; `onchip_landrate.log` | ANCESTOR; file exists (1172 B, 08-08 12:38) |
| A10 | `tidelink_top.sv` greps: `sub_wr_stuck_sticky` assignments; `xhb_stall_stuck_sticky` threshold; `sub_axi_progress`; `sub_stall_busy`; `sub_wr_stuck_fire`; `wr_hold_clr`/`wr_hold_drain_release`; N1 conditional abandon; `sub_mst_dphase_r`; `ahb_sub_w_beat_consumed_o`; `.hexcl(1'b0)`/`.hmaster(12'd0)`; `ext_stall_err_q` in obs word | :1862/:1870 set-only; :1867 `12'hFFF`; :1648; :1617; :2040; :1999-2009; :1818; :1605/:2110; :291/:638; :2680-2681; :1875 bit[11] |
| A11 | `read_would_overmint` in `tidelink_fifo_ctrl.sv`; `swi_auto_anchor_force_in` in controller/Wlink/WavD2DGpio_v2 | 7; 3/2/4 |
| A12 | ASIC v2 flist: ECC line, FCSM 0-5, FCReplayV2_1/3/5/7/9, obs modules, sync_detect count, a2l_48x4, link_rate_regs | :253 local ECC; :315-320 deps FCSM, :321 local FCSM_6; _1/_3/_5 local, _7/_9 deps; :71-72 obs; sync_detect once (:198); :230; :414 |
| A13 | FPGA v2 flist same | :269 local ECC; :322-326 local FCSM 0-4; _1/_3/_5 local |
| A14 | rev2 flists `_7/_9` | both flists → `src/rtl/local_overrides/WlinkGenericFCReplayV2_{7,9}.v` |
| A15 | CRC reset: deps `WlinkGenericFCSM.v:636` vs local `:747` | `1'h0` (ON) vs `1'h1` (OFF) |
| A16 | `TL033_LEGACY_WDOG` / `socl_l7_wdog_progress` / `TL035_PARTB` counts in local FCSM `.v,_1,_4,_6`; `_GEN_115` form | 2/2/0 for 0-4 (unconditional Part-B), 0/0/0 for `_6` (still `& ~socl_l7_real_crc_seen` :646-648); deps `_GEN_115` unmodified |
| A17 | `grep -c socl_` deps vs local FCSM 0-4 | 0 vs 73/72/72/72/72 |
| A18 | `git show 52c06677 --stat` + diff of `_GEN_115` | 6 files, +190/-12; Part-B unconditional; 68 lines mark_debug taps |
| A19 | `git show 001b231d` message | new port `link_clk_div_ratio_i[2:0]`; `user_hsclk` rewired; default = combinational bypass |
| A20 | `git grep -i dwn1c21 5e8bdb5a`; `tsmc` outside deps; drop-code regex in `syn/`; `site.env.example` tracked; `common.mk` head | 0; docs/prose only; only `tcbn65lp`/`CLN65LP_TECH_PATH`; yes; site paths delegated to untracked `site.env` |
| A21 | `git grep -l '<board password>' 5e8bdb5a \| wc -l`; same on rev2/integration; IPs; `git log -S<pw> --all \| wc -l` | 18; 18; 41; 11 (values not printed) |
| A22 | `git log --oneline --since=2026-08-10 -- syn/asic` | `affbda14`, `9d1b2eaa` |
| A23 | `set_case_analysis` in `1_init_design.tcl`; `constraints.sdc` header; `read_design.tcl` uncertainty block | :285-297 per-scenario; "PURE SDC only"; `current_scenario` before `set_clock_uncertainty` :278-281 |
| A24 | `build_provenance.tcl:71-80 proc tl_git_sha` | fail-open form present at 5e8bdb5a |
| A25 | `kr260_sysval.py` :58 `2>/dev/null`, :235 `rc == 124` only, :239 mismatch string | present (rc=255 falls into mismatch branch) |
| A26 | `tidechart_apb_regs.sv` `error_reg_r` writes; `apb_pslverr`; `apb_paddr_ext` | :370 reset, :455 `[3]`, :477 W1C only; `= 1'b0` :322; `9'b0 \| apb_paddr` :356 |
| A27 | `tidechart_controller.sv` election width (repo HEAD vs dual-root shadow) | `[15:0]` vs `[TIMEOUT_W-1:0]` |
| A28 | `deps/xhb500/generated/.../core_addr.sv:147 singles_burst` | `~hprot[3] \|\| hexcl \|\| hburst == BUR_INCR`; dir untracked at 5e8bdb5a |
| A29 | `run_calibre_lvs.sh:128` at 5e8bdb5a; rev2 `9a7c02c7` | `grep -q "CORRECT"` (matches INCORRECT); fixed on rev2 |
| A30 | `grep -c ptp_servo Makefile`; `tidelink_ptp_servo.sv:680` | 0; two-sided signed compare present |
| A31 | `tidelink_fifo_ctrl.sv:199-204` credit guard; `git log -S` | saturate-at-zero present since `ce2f2c90` 2026-04-06 |
| A32 | `tidelink_apb_regs.sv` `inc_r/dec_r/update_r`; `651a71b` ancestry | 14 refs; ANCESTOR |
| A33 | `git log -1 -S'local_overrides/WlinkEccSyndrome.v' -- flists/tidelink_top_full_asic_v2.flist` | `d78268a4` 2026-08-08 |
| A34 | Existence of registry-cited artefacts (list in §1) | EXIST: tl037 result, n1_repro(+patch), TL042 rejected, ila_tl035_run(+round2), overnight campaign, tl042_v2, TL021/TL027 specs, both waivers, roadmap, hwtest_gate.sh, ecc_hwverify.sh, 14_rx_fifo_phantom_pop.sh, all cited cocotb tests. MISSING: `tl035_tl035/00_run.log` (dir has `99_verdict.txt` + liveness note), `awready_ila_capture/results_wnode_2026_08_19` (peer tree), `BUG_REGISTRY_ADDITIONS_2026_08_13.yaml` (merged, premerge copy in imp/hw_gate), `verify_fix_delivery.sh`, `CONTRIBUTING.md`, TL-009's four `hw_*.log` files |
| A35 | `td-bisect/kr260-{consolidation,hazard1,pinbump}-hwval-2026-08-19-results/*soak*` | each `SOAK: sent=5000 drained=5000 good=5000 bad=0 stalls=0` |
| A36 | `td-bisect/kr260-integ-2026-08-24-results/AB_SUMMARY.json` | vehicle onchip; cross-die READ n=6/direction/arm; self-declared underpowered |
| A37 | `td-bisect/asicsim-2026-08-26/l7_starvation_ab_SUMMARY.txt` | FPGA ESCAPED (states [4]); ASIC WEDGED at 7 for 1536 io_tx_clk |
| A38 | `docs/FALSE_GREEN_REGISTER.md` on rev2 | exists; Tier 0 = no CI on either forge; "~49" per header |
| A39 | rev2 registry `TL-043`/`TL-044` refs; rev2 Makefile `tl044_*` targets; rev2 `tidelink_top.sv` `.hexcl` line | 0/0; `tl044_hol_write_age`, `tl044_read_deadgate`, `tl044_park_recipe`; :3171 |
| A40 | rev2 `82c56e2a` / `c6f091a1` commit bodies | HOL watchdog (write) / read dead-gate containment; both "no hardware test of any kind" |

**Not checked (would need a rebuild, a board, or a repo outside scope):** any post-`9d1b2eaa` FC timing report; `WavD2DGpio_v2.v` presence in the ASIC flist for Hazard-3; SDC case-analysis of the divider ratio; the compute/eth chiplet decode files; the dual-root JSON verdicts; the `phy_up` predicate (peer script); credential rotation.


---

# PART 6 Throughput

# TideLink review — THROUGHPUT: where the bandwidth goes, and what the next iteration could gain

Review tree: `origin/main` `5e8bdb5a` at `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a` (all `file:line` cites are relative to it unless prefixed). Chisel source: `$WORKTREES/SoCLabs/axi-chiplet-controller/wav-wlink-hw/src/main/scala`. Prior experiments: `$WORKTREES/SoCLabs/tidelink-throughput-overnight`, `$WORKTREES/SoCLabs/tidelink-link-survey-2026-08-01`. Next iteration: `origin/rev2/integration` `cba9774d`. Every number below is tagged **[RTL]** (read from a cited parameter), **[LOG]** (a cited result file), **[MEM]** (a memory-file number I could not re-run tonight — treated as reported, not re-verified), or **[CALC]** (arithmetic shown; script at `scratchpad/tp_model.py`).

## 0. Headline

1. **The link runs one Wlink packet per 32-bit word, and the sender may have only 16 packets un-ACKed while the ACK round trip is ≈49 link-layer cycles.** Every sim throughput number ever taken on the TideLink node collapses onto one invariant when expressed in link-layer cycles: **3.01 / 3.05–3.06 / 3.06–3.26 link cycles per word** at link:hclk ratios of 0.32:1, 2:1 and 8:1 [CALC from LOG/MEM, §1.6]. That is `RTT_ack / window = 49 / 16`. Lane count barely moves it (1.00–1.07×) because serialisation (1 cycle @8 lanes, 2 @4 lanes) is *hidden inside* a 3-cycle window stall — which is exactly the "2× lanes bought 1.065×" puzzle.
2. The 487.9 hclk/word measured on KR260 is that same 3.06 floor at the KR260's 8:1 ratio (391.6 hclk) plus the live RX-credit loop (+25%). **It contains zero PS→PL cost** — TXGEN drives `ahb_tx` from the fabric (`src/rtl/tidelink_tx_gen.sv:4-9`).
3. The `ahb_sub` (XHB500/AXI) path has never been cycle-measured and is structurally ~15× slower still: one non-bufferable 32-bit write costs a full link round trip (≈47 link cycles ≈ 6 000 hclk on KR260, ≈7.5 µs on a 100 MHz ASIC) [CALC §1.7]; reads are single-outstanding by XHB500 construction (`core_resp.sv:233`).
4. **Single biggest lever: replay-window depth vs. link-domain RTT** (16 vs ≈49). Fixing it alone is a 3.06× gain at 8 lanes. Combined with multi-word packets it is ≈10× on the *same* pads/PHY. `rev2/integration` touches none of the throughput levers (it is a backstop/verification branch — §3 tags).

## 1. Datapath serialisation model

### 1.1 Clocks and units (the thing every prior analysis got subtly wrong)

| Quantity | Value | Source |
|---|---|---|
| PHY serialiser | 16:1 **SDR**, one bit per `io_clk`(=`user_hsclk`) edge per lane; `io_link_clk = ~count[3]` ⇒ link-layer clock = hsclk/16 | `GPIO.scala:44,59-66`; `deps/tidelink-phy/rtl/wav/WavD2DGpioTx.v:206-208,418-426` [RTL] |
| 1 UI | 1 `user_ref_clk` period (divider `RATIO_RESET=3'd0` = /1 bypass) | `src/rtl/tidelink_link_clk_div.sv:10-12,66` [RTL] |
| 1 link-layer cycle | **16 UI**; carries one 128-bit link word = 8 lanes × 16 b | `LinkLayer.scala:391-392,412`; `WlinkGPIOPHY_v2.v:81` [RTL] |
| bytes per link cycle | `2 × popcount(lane_mask)` → 16 B @8 lanes, 8 B @4 lanes | `LinkLayer.scala:489` [RTL] |
| KR260 | hclk = clk_out1 = 25 MHz; user_ref_clk = clk_out1/8 = 3.125 MHz ⇒ UI = 320 ns, link cycle = 5.12 µs = **128 hclk** | `fpga/targets/kr260-pair-onchip/tidelink_design.tcl:190-211`; `tidelink_phy_clk_div2.v:19` [RTL] |
| KR260 lane mask POR | **0xE4 (4 lanes)** unless `TD_AUTO_LANE_MASK_E4=0` at build | `fpga/filelist.tcl:59-60`; `local_overrides/Wlink.v:2564-2567` [RTL] |
| ASIC v1 | UI = 10 ns (100 MHz, per SDC comment and memory); `constraints.sdc` *placeholder* is `T_UI_NS 4.0` and hclk 4 ns; on the eth chiplet `user_ref_clk` is aliased onto `sys_fclk` ⇒ hclk = UI clock ⇒ link cycle = 160 ns = **16 hclk**; lane mask POR 0xFF | `syn/asic/fusion-compiler/inputs/constraints.sdc:5,59-72,86-90`; `tidelink_link_clk_div.sv:13-15` [RTL] |
| Sim | hclk 20 ns; `TIDELINK_SIM_REF_PERIOD_NS` 8 / 40 / 160 ⇒ link cycle 6.4 / 32 / 128 hclk | `tidelink-throughput-overnight/cocotb/tidelink_top_pair_v2/test_v2_txgen_throughput.py:21-29` [RTL] |

Note the design docs' "1 UI = 2 hclk, 8 UI per word" ceiling (`docs/ARCHITECTURE_PHY_LINK.md:289`, test docstring line 9) is wrong on two counts: a link word is 16 UI, not 8, and a TideLink data packet is 13 B, which is 1 link cycle at 8 lanes and 2 at 4 lanes. The correct serialisation ceiling on Z2 (2:1) is 32 hclk/word @8 lanes, 64 @4 lanes — not 16.

### 1.2 Two different datapaths — do not conflate

* **Path B — the mailbox path (what all throughput numbers were taken on):** `ahb_tx` → `tidelink_fc_adapter` → 48-bit FC word → `TideLinkToWlink`/`WlinkGenericFCSM_6` (data_id 0xa1) → `WlinkTxRouter` ch6 → `WlinkTxLinkLayer` → `WlinkGPIOPHY_v2`/`WavD2DGpio_v2`. TXGEN drives exactly this port (`tidelink_tx_gen.sv:4-9`).
* **Path A — the transparent bus path:** `ahb_sub` → `tidelink_top` address pipeline → `xhb500_ahb_to_axi_bridge_chiplet_slv` → `s_axi_*` → `axi_chiplet_controller.axi_tgt_0_*` → `AXI4ToWlink` FC nodes AW 0x80 / W 0x81 (fwd) … peer `axi_ini` → `xhb500_axi_to_ahb` → `ahb_mng` → SRAM; B 0x82 returns; AR 0x83/R 0x84 for reads. Never cycle-measured; memory reports an "8000-hclk settle window" for a single transaction [MEM].

### 1.3 Hop table — Path B, one 32-bit write

| # | Hop | Width | Clock | Beats / overhead | Handshake that serialises the next word | Source |
|---|---|---|---|---|---|---|
| 1 | `ahb_tx` AHB-Lite → fc_adapter addr/data phase | 32 b + 14 b addr | hclk | 1 addr + 1 data phase; pipelined masters get (N+1)/N cy/word, single-beat masters 2.0 | `hreadyout = skid_can_accept & ~sideband_grant` — only blocks when the 16-deep a2l is full | `tidelink_fc_adapter.sv:316-334,371-375,553` [RTL]; pipelining figures `cocotb/tidelink_fc_adapter/test_pipelining.py` [MEM] |
| 2 | 1-entry skid → `tl_fc_a2l_*` 48-bit FC word `{type[47:46], addr_off[45:32], data[31:0]}` | 48 b | hclk | 1 word/hclk; skid transparent when `tl_fc_a2l_ready` | none (skid+FIFO = 17 words elasticity) | `:549-566`; `tidelink_top.sv:2584-2586` [RTL] |
| 3 | a2l **replay** FIFO (`WlinkGenericFCReplayV2_13`, 16 deep, `ADDR_SIZE=4`) — app write / link read | 48 b | hclk → tx_link_clk | 1 entry per word | **`app.ready = ~full`, and an entry is freed only by a peer ACK (`link.ack_update`), not by being sent** — this is the window | `FC.scala:740-790`; `local_overrides/WlinkGenericFCReplayV2_13.v:238` [RTL] |
| 4 | FCSM TX (`LINK_IDLE`/`LINK_DATA`) → packet `{data_id=0xa1, word_count=7, data=48 b + 8 b pktnum}` | 56 b payload | tx_link_clk | 1 packet per word; next `sop` loads the cycle `ll_tx.advance` returns (combinational) | also gated by `~fe_rx_is_full` (peer l2a 16-deep) and pre-empted by NACK>ACK (SEND_ACK detour = 2 cycles) | `FC.scala:74,501-560,578-598`; `WlinkGenericFCSM_6.v:773` [RTL] |
| 5 | `WlinkTxRouter` (8 ch, `curr_ch` combinational, strict-priority one-active) → `WlinkTxPstateCtrl` (pass-through) | packet | tx_link_clk | 0 extra cycles for a single active channel | one packet at a time across ALL FC nodes (TDM) | `LinkLayer.scala:64-135,254-259`; channel map `tidelink_fcemit_obs.sv:18` [RTL] |
| 6 | `WlinkTxLinkLayer`: 4 B header (data_id, wc[7:0], wc[15:8], **ECC** from `WlinkEccSyndrome` over the 24-bit header) + 7 B payload + 2 B **CRC-16** = **13 B**; no cross-packet packing (`byte_count` resets at `endOfPacket`) | 128 b link word | tx_link_clk | **1 link cycle @8 lanes, 2 @4 lanes** (`ceil(13/bytesPerCycle)`) | `advance` only at `endOfPacket` | `LinkLayer.scala:427-461,489-493,516-530` [RTL] |
| 7 | PHY TX: `link_data_stage` captured at `count==7`, `link_data_ser` at `count==15`, 16-bit 16:1 mux to pad | 16 b/lane | hsclk (UI) | 16 UI per link word; ~1–2 link cycles latency | — | `WavD2DGpioTx.v:381-389` [RTL] |
| 8 | Peer PHY RX (16:1 deser) → `tidelink_lane_deskew_v2` (DEPTH_LOG 4/5, PRIME_THRESH 5 cushion) → `WlinkRxLinkLayer` (ECC-correct header, CRC check) → RX router → FCSM RX (`exp_pkt_seen`) → l2a replay FIFO (16 deep) → fc_adapter RX FSM (2 hclk/word) → RX FIFO SRAM | — | rx_link_clk → hclk | several link cycles of latency, 1 word/link-cycle throughput | `ack_nack_fifo` (8 deep, rx→tx CDC) requests an ACK | `local_overrides/tidelink_lane_deskew_v2.sv:47,105`; `FC.scala:260-291`; `fc_adapter.sv:655-661` [RTL] |
| 9 | Peer FCSM sends **ACK** (4 B short, 1 link cycle) with cumulative pointer, **≥ `ack_dly_count`(=7) cycles apart** | 4 B | peer tx_link_clk | SEND_ACK + LINK_IDLE = 2 cycles of the peer's TX | frees sender window entries | `FC.scala:502-521,578-598,664`; `WlinkGenericFCSM_6.v:1712` [RTL] |
| 10 | Sender: ACK → `ack_nack_fifo` → `a2l_link_addr` → `WavMultibitSync` (1-entry toggle mailbox) → app-clock `full` clears | 5 b ptr | rx→tx→app | ~3+1+~4 cycles | closes the loop that gates hop 3 | `FC.scala:770-782`; `local_overrides/WavMultibitSync_18.v:22-25` [RTL] |
| 11 | **RX-FIFO credit loop** (separate from the Wlink window): peer pop → `release_threshold` accumulator (**POR 20 words**) → `tidelink_returner` AHB write (3-state FSM) → fc_adapter SIDEBAND word → *another* 13 B packet on the reverse direction → our `pair_credit_counter` | 48 b | hclk both ends + the reverse link | one reverse packet per release; rides the reverse a2l window and its own ack_dly | TXGEN gates on `pair_credit_counter ≥ len+2` | `tidelink_apb_regs.sv:267`; `docs/TXGEN_V1_DESIGN.md:125-152` [RTL] |

### 1.4 Packet framing per FC node [RTL + CALC]

`word_count = ceil((dataWidth + 8)/8)` — the +8 is the pktnum byte (`FC.scala:74`, `TideLinkToWlink.v:20` shows the 56-bit rx_in_data for a 48-bit node). Packet = 4 B header + word_count + 2 B CRC. Cycles = `ceil(bytes / bytesPerCycle)`.

| Node (data_id) | a2l data width | word_count | packet bytes | link cycles @8 lanes | @4 lanes | payload efficiency (4 B useful) | window depth |
|---|---|---|---|---|---|---|---|
| TL 0xa1 | 48 (`FCSM_6.v:236`) | 7 | 13 | 1 | 2 | 31% of packet, 25% of a 16 B link word | 16 (`ReplayV2_13`, `ne_tx_credit_max=0x1f`) |
| AW 0x80 | 101 (`FCSM.v:42`) | 14 | 20 | 2 | 3 | 0 (address) | 8 (`nonDataFifoSize`, `AXI.scala:44`; CR word `16'hf0f`) |
| W 0x81 | 37 (`FCSM_1.v:42`) | 6 | 12 | 1 | 2 | 33% | 32 (`dataFifoSize`, `AXI.scala:43`; `16'h3f3f`) |
| B 0x82 | 14 (`FCSM_2.v:42`) | 3 | 9 | 1 | 2 | 0 | 8 |
| AR 0x83 | 101 | 14 | 20 | 2 | 3 | 0 | 8 |
| R 0x84 | 47 (`FCSM_4.v:42`) | 7 | 13 | 1 | 2 | 31% | 32 |
| ACK/NACK/CR/CRACK | short | — | 4 | 1 | 1 | — | — |

Header ECC/CRC is 6 B fixed per packet (memory Finding 3 is correct on that) — but the cost that matters is **one packet per 4-byte word**, i.e. 69% of every Path-B packet and 75% of every 8-lane link word is not payload. That is a packet-granularity problem, not a "header is too big" problem.

### 1.5 Theoretical cycles per 32-bit word and bits/s [CALC]

Model: `cycles/word = max( serialisation , RTT_ack / window )` in link cycles, then × (UI × 16) for time. Raw pad rate = lanes × 1/UI.

| Target | link cycle | raw pad (8 lanes) | Path B serialisation floor 8L / 4L | Path B **today** (window-bound 3.06 / 3.26) | Path B today measured |
|---|---|---|---|---|---|
| KR260 (25 MHz hclk, UI 320 ns) | 5.12 µs = 128 hclk | 25 Mb/s | 128 hclk = 6.25 Mb/s / 256 hclk = 3.12 Mb/s | 392 hclk = **2.04 Mb/s** / 417 hclk = 1.92 Mb/s | 487.9 hclk = **1.64 Mb/s** (0.205 MB/s) [MEM] |
| ASIC v1 (100 MHz UI, hclk = UI) | 160 ns = 16 hclk | 800 Mb/s | 16 hclk = 200 Mb/s / 32 hclk = 100 Mb/s | 49 hclk = **65 Mb/s** (8.2% of raw) | — (never run) |
| ASIC at SDC placeholder 250 MHz | 64 ns | 2 Gb/s | 500 Mb/s | 163 Mb/s | — |

Path A (ahb_sub) is in §1.7.

### 1.6 Reconciling the measurements — the ≈3.06 link-cycle invariant

Measured hclk/word → link cycles/word (÷ link cycle in hclk) → implied RTT (= 16 × cycles/word):

| Run | hclk/word | link cyc/word | implied RTT (link cyc) | source |
|---|---|---|---|---|
| sim REF=8 (link = 6.4 hclk), ample credit | 19.253 | **3.01** | 48.1 | [MEM] `project_link_parallelism…` C1 |
| sim REF=40, 4 lanes / 8 lanes | 97.879 / 97.672 | **3.06 / 3.05** | 48.9 / 48.8 | [LOG] `tidelink-link-survey-2026-08-01/imp/sim_gate/v2_lane_mask_throughput.log` |
| sim REF=160 (KR260 ratio), 4L / 8L | 417.134 / 391.639 | **3.26 / 3.06** | 52.1 / 49.0 | [MEM] C1/C7 |
| sim REF=40, `ack_dly_count=0` | 89.1 | 2.78 | **44.5** | [MEM] ack_dly sweep |
| sim REF=160, **live** credit | 603.4 | 4.71 | 75.4 | [MEM] C7 |
| **KR260 HW**, live credit, ack_dly 7 / 4 | **487.9 / 456.6** | 3.81 / 3.57 | 61.0 / 57.1 | [MEM] 07-31 HW run |

Reading:
* Across a 20× range of link:hclk ratio the cost is constant **in link cycles** (3.01–3.06 @8 lanes), so the bottleneck lives entirely in the link-clock domain and is not the fc_adapter, TXGEN, PS or any hclk logic. It is `RTT_ack/16 ≈ 49/16`. The `ack_dly_count` 7→0 sweep shaves exactly the expected ~4.4 cycles of RTT (average half of a 7-cycle ACK-spacing wait plus the SEND_ACK detour) and then plateaus at RTT ≈ 44.5 — the **fixed pipeline latency** (PHY stage+ser, deser, deskew cushion, RX-LL header decode, `ack_nack_fifo` CDC, FCSM detour, `WavMultibitSync`, ×2 directions).
* 4-lane vs 8-lane at 8:1 differs by 0.2 cycles/word (3.26 vs 3.06) = 3 extra RTT cycles because the data packet takes 2 cycles instead of 1 on both the outbound and the ACK-carrying inbound serialisation. Serialisation is otherwise **hidden** inside the window stall — hence 1.065×, not 2×.
* The 487.9 vs 95.8 gap: (a) clock ratio 2:1 → 8:1 = ×4 in hclk (95.8 → 383; sim at the right ratio says 391.6) — **this is not a hardware phenomenon, it is the same 3.06 link cycles**; (b) live RX-credit loop on top: sim 603 vs 392 (+54%), HW 488 vs 392 (+25%) — the returner/sideband packet path (hop 11) rides the reverse a2l window and its own ack_dly; (c) HW was at 4 lanes (+6.5%). Nothing is left unexplained to within the sim/HW spread.
* **PS→PL share: zero** in the 487.9 number (TXGEN never touches the PS bridge). It is the whole of the *CPU-driven* ~96 hclk/word number on Z2, where the busref control (36.7 cycles bare bus access) shows the PS→PL→AHB-lite round trip dominates and the CPU has ≤1 store outstanding, so the 16-word window never fills [MEM `project_throughput_is_ps_bus_roundtrip…` §3]. The coincidence that the Z2 link floor (3.06 × 32 = 98 hclk) equals the CPU number means **no Z2 measurement could ever separate the two**; only an 8:1 board can (link floor 392 vs PS ~96).

### 1.7 Path A (ahb_sub → XHB500 → AXI FC nodes) — model, never measured [CALC]

XHB500 write completion rules (RTL): non-bufferable write → `hreadyout = beat_done` waits for **B** (`core_resp.sv:188`); bufferable/EWR (`hprot[2] & ~hprot[6]`) → hreadyout at address accept, up to `HAZARD_LIST_SIZE=4` outstanding (`hazard_list.sv:46,136`; `core_addr.sv:150-158`); reads → `ready_for_read` allows **one** outstanding (`core_resp.sv:233`). `tidelink_top` adds one wait state per NONSEQ (`pipe_valid_r`, `:1503-1530,1897`) and `wr_hold_r` holds completion until the W beat lands (`:2081-2086`). `hexcl`/`hmaster` tied 0 (`:2678-2679`) — exclusives never cross, every hazard entry has master id 0.

Per single non-bufferable 32-bit write at 8 lanes: AW (2 cyc) + W (1 cyc) serialised through the one router, one-way pipeline ≈ (44.5 − 2)/2 ≈ 21 link cycles, peer AXI→XHB500-mst→AHB→BRAM→B (≈10 hclk ≈ 0.1 link cycle on KR260, 0.6 on ASIC), B packet 1 cyc + 21 back ⇒ **≈47 link cycles/word** ⇒ KR260 ≈ 6 000 hclk ≈ 240 µs (0.13 Mb/s); ASIC-100 ≈ 7.5 µs (**4.3 Mb/s**). With EWR ×4 outstanding: ≈12 cycles/word (KR260 0.5 Mb/s; ASIC 17 Mb/s). Reads: same ≈47 cycles, no overlap possible. Memory's "8000-hclk settle window" [MEM] is the same order. **Path A is ~15× slower than Path B today and ~45× slower than Path B's serialisation floor.**

## 2. Bottleneck ranking (evidence-weighted)

| Rank | Bottleneck | Path | Factor today | Evidence |
|---|---|---|---|---|
| 1 | **a2l/l2a replay window 16 vs link-domain ACK RTT ≈ 49 cycles** | B (and A: AW/B/AR windows are only **8**) | 3.06× off the serialisation floor at 8 lanes; 1.63× at 4 | §1.6 invariant across 3 ratios [LOG/MEM]; ack_dly sweep plateau at RTT 44.5 [MEM]; C9 `a2l_full` interval constant vs backlog [MEM]; window depth `ReplayV2_13.v:238`, `FC.scala:138` [RTL] |
| 2 | **One packet per 32-bit word** (13 B packet, 6 B framing + 1 B pktnum per 4 B payload; no LL packing) | B, and W/R nodes on A (1 beat per packet) | 4× vs link-word capacity at 8 lanes (only 4 of 16 B are payload); 3.2× achievable with 16-word packets | `FC.scala:74`, `LinkLayer.scala:489-522` [RTL]; §1.4 |
| 3 | **Per-transaction B round trip + single outstanding** (XHB500 non-EWR writes wait for B; reads 1 outstanding; eth chiplet ties `hprot[2]=0` so EWR is off) | A | ≈47 link cycles/word ≈ 15× worse than Path B | `core_resp.sv:188,233`; `hazard_list.sv:46` [RTL]; tie-down [MEM `project_wedge_silicon…`] |
| 4 | **No usable AHB burst**: `singles_burst <= ~hprot[3] \|\| hexcl \|\| hburst==INCR` — every test drives hprot=0, and when a cacheable INCRx *is* driven the bridge emits TWO AXI bursts, the first all-zero (peer memory destroyed) | A | AW (20 B, 2 cyc) + B per beat instead of per burst; AW window 8/49 ⇒ ≥6.1 cyc/beat even with unlimited outstanding | `core_addr.sv:147` [RTL]; corruption: coordinator-verified + [MEM `project_tl027…` §2] |
| 5 | **Live RX-credit return loop** (`REL_THRESHOLD` POR 20; returner AHB → sideband packet on reverse link) | B | +25% HW (488 vs 392), +54% sim | §1.6 [MEM]; `tidelink_apb_regs.sv:267` [RTL] |
| 6 | **Lane mask 0xE4** (4 of 8 lanes) on every FPGA build | both | 2× serialisation — currently hidden (1.065×) until rank 1 is fixed; +3 RTT cycles | `fpga/filelist.tcl:59`; C1 [LOG] |
| 7 | **`ack_dly_count=7`** | both | 6.7% (sim), 6.4% (HW) | [MEM] sweep + HW A/B; `FCSM_6.v:1712` |
| 8 | **Link clock ratio**: KR260 `/8` divider is an uncharacterised carry-over (25 MHz → 3.125 MHz); ASIC SDC still at a 250 MHz placeholder vs 100 MHz target | both | up to 4× on KR260 (bench eye needed); 2.5× ASIC if the pads support it | `tidelink_phy_clk_div2.v:16-19`; `kr260_tidelink_timing.xdc:132-134`; `constraints.sdc:59-72` [RTL] |
| 9 | **SDR PHY**: 16 UI per link word | both | 2× available with DDR | `GPIO.scala:44` [RTL] |
| 10 | fc_adapter skid / RX FSM | B | **not** a bottleneck: (N+1)/N cy/word TX pipelined [MEM test_pipelining], RX 2 hclk/word (fix present, `fc_adapter.sv:655-661`) — RX would bind only at ≤2 hclk per link cycle, i.e. never on KR260 (128) or ASIC (16) | [RTL/MEM] |
| 11 | PS→PL AXI-GP/AHB-lite round trip | CPU-driven only | ~37–96 hclk per store, ≤1 outstanding — KR260/Z2-specific, not the design; irrelevant to TXGEN/DMA | [MEM busref] |
| 12 | Obs/backstop logic on hclk critical path | — | none today: routed WNS +27.4 ns at 40 ns (fmax ≈ 78 MHz); worst paths are `swi_rx_lane_mask → sync_obs_rxcap0` (12.2 ns, 21 levels) and `axi_ahb_sub HADDR → a2l_fc_replay mem CE` (10.9 ns, 20 levels) | `imp/fpga/output/kr260-pair-onchip/tidelink_design_wrapper_timing_summary_routed.rpt:355-364,602-611` [LOG] |

Correctness coupling (ranks 3/4): the XHB500 **hazard-list saturation wedge** is the B-return path failing to retire entries (`[MEM] project_wedge_silicon…`: `sub_wr_os_ctr` pinned at 4, B never returns). Anything that raises outstanding writes (EWR, bursts, deeper AW/B windows) makes that wedge *more* reachable unless the B-return path is made robust first. `rev2/integration` adds the head-of-line write-age watchdog (`82c56e2a`, TL-042) and read dead-gate containment (`c6f091a1`, TL-044) — bounding, not prevention.

## 3. Improvement candidates

For each: mechanism · gain (calc) · RTL scope · risk · verification · effort. **rev2 tag** = whether `origin/main..origin/rev2/integration` touches it (`git log --oneline origin/main..origin/rev2/integration -- src/rtl` = `c6f091a1`, `82c56e2a`, `e88ff7be` only; diffstat: `tidelink_top.sv`, `local_overrides/WlinkGenericFCReplayV2_{7,9}.v`, tests/tooling).

**C1. Deepen the replay windows (a2l AND l2a) to ≥ RTT — the biggest lever.** Mechanism: `cycles/word = max(ser, RTT/W)`; with W ≥ 49 (use 64) the TideLink node becomes serialisation-bound. Gain: 3.06 → 1.0 link cyc/word @8 lanes = **3.06×** (KR260 2.04 → 6.25 Mb/s; ASIC 65 → 200 Mb/s); @4 lanes 3.26 → 2.0 = 1.63×. Also lifts the AXI nodes (AW/B/AR at 8 deep are at 8/49 = 6.1 cyc/pkt). Scope: Chisel `fifoSize` for the TideLink node (`TideLink.scala` in the wlink tree — not in the review checkout; generated `WlinkGenericFCReplayV2_13/_12`, `WavFIFO_20`, `wlink_wlink_tidelink_tl_a2l_48x16`), pointer widths 5→7 bits hard-coded across the generated files, `io_obs_a2l_wptr[4:0]` obs ports (`TideLinkToWlink.v:69-77`), `ne_tx_credit_max=Fill(addrWidth+1,1)` fits 8-bit CR fields up to 254 (no wire-format change, `FC.scala:137-140`); `AXI.scala:43-44` `dataFifoSize/nonDataFifoSize` for the AXI nodes. Both `_12`/`_13` are local overrides that the ASIC v2 flist sources (`flists/tidelink_top_full_asic_v2.flist:286,290`) so the change reaches the ASIC — but the two active hand-patches there (TL-027 `w_inc` self-heal, false-FULL fix) must be re-applied post-regen. Risk: **high** — worst bug-history module in the repo; SRAM grows 48×16 → 48×64 per direction per node; deeper replay = longer NACK replay bursts; the l2a `fe_rx_is_full` gate uses the same depth. Verification: `test_v2_lane_mask_throughput` at REF 8/40/160 must show link-cyc/word dropping from 3.06 to ~1.0 (8L) and to ~2.0 (4L) — the lane-count doubling must now appear; CDC-tearing suite `sim_gate_a2l_wready_tear` on the regenerated cells; full `sim_gate`; KR260 A/B with perf counters. Effort: **L**. rev2: **not touched**.

**C2. Multi-word packets on the mailbox node (wider FC word / burst-of-words).** Mechanism: carry N×32 b per Wlink packet so the 6 B framing + pktnum amortise and link words fill. Gain @8 lanes: N=4 (17 B payload, 23 B pkt → 2 cyc) = 0.5 cyc/word (2×); N=16 (65 B payload, 71 B pkt → 5 cyc) = 0.31 cyc/word (**3.2×** on top of C1; ASIC 640 Mb/s = 80% of raw). Needs C1 first (a 16-entry window of 5-cycle packets is 80 cycles > RTT, so it is then serialisation-bound). Scope: new FC node data width (Chisel regen of the TideLink node, `FC_DATA_W` parameter through `tidelink_top`/`fc_adapter`), fc_adapter TX packer (collect N words or flush on packet end/timeout) and RX unpacker, `tidelink_fifo_ctrl` write side (already 1 word/cycle), perf taps (`fc_tx_is_data` decode of bit 47). Risk: medium-high — changes the 48-bit word format that SIDEBAND/EXT/TideChart share (`fc_adapter.sv:152-155`), packet-boundary flush latency for small packets, replay granularity. Effort: **L**. rev2: not touched.

**C3. Enable 8 lanes (mask 0xFF) — only pays after C1.** Gain: 2× serialisation (KR260 3.12 → 6.25 Mb/s post-C1); today 1.065× (measured). Scope: build flag `TD_AUTO_LANE_MASK_E4=0` (`fpga/filelist.tcl:59`), ASIC already 0xFF. Risk: KR260 has no IDELAY (`USE_IDELAY=0`); 8-lane bring-up HW-proven on Z2 only [MEM]. Effort: **S** (+ bench). rev2: not touched.

**C4. Posted writes / early B for bufferable traffic on Path A, with a correct hazard scheme.** Mechanism: let XHB500's EWR path run (needs `hprot[2]=1` at the chiplet boundary — the eth chiplet currently ties it to 0 precisely to keep the hazard list empty) so up to 4 writes overlap; gain 47 → ~12 link cyc/word (**≈4×**, ASIC 4.3 → 17 Mb/s) — still 12× behind Path B. Correct hazard scheme required: age the *oldest* outstanding B (per-entry timestamp) and fail it with SLVERR instead of the aggregate-progress timers that provably never expire [MEM `project_wedge_silicon…`]; rev2's TL-042 HoL write-age watchdog (`82c56e2a`) is that mechanism for the current 1-deep case and would need extension to per-ID at depth 4; Fix K BID-correction (all ids 0, `tidelink_top.sv:2058-2064`) becomes load-bearing. Risk: **high** — this is the exact configuration that wedged silicon (`0x21F8[10]` hazard-list-full witness). Verification: burst-corruption bench on rev2/burst-measure `test_v2_burst_encodings.py` (non-singles arm), XHB500 unit bench (`c5bc7efa`), a saturating-B-return injection test asserting the watchdog *and* that normal traffic resumes (a passing escape test is not a safety test). Effort: **M** RTL, **L** verification. rev2: **partially touched** (TL-042/044 backstops), no throughput intent.

**C5. AHB burst → AXI burst mapping (INCR4/8/16) on Path A.** Mechanism: one AW + N W + one B per burst instead of per beat; W node is 1 cyc/beat @8 lanes with a 32-deep window (32/49 = 1.53 cyc/beat bound) ⇒ **≈1.7 link cyc/word** (from 47) with C4-style outstanding; ASIC ≈120 Mb/s. **Not a config flip**: (a) `singles_burst` is gated on HPROT[3] (`core_addr.sv:147`), so bursts require cacheable attributes at the port; (b) the non-singles arm has never executed in any test, and when driven it produces two AXI bursts with the first all-zero — a latent data-corruption bug that must be root-caused/fixed first (coordinator-verified); (c) the compute chiplet's DMA-250 emits cacheable INCR4/8 by construction, so this arm is *live* on the compute die for reads today [MEM]. Scope: XHB500 configuration/regeneration (`deps/xhb500/configs`), `tidelink_top` address pipeline (`pipe_*_r` only holds one beat), `wr_hold_r`/burst guard (`:1926-1995`), `ahb_sub_w_beat_consumed_o`. Risk: high (correctness bug + hazard-list exposure). Effort: **L**. rev2: burst bench added (`ea1c3e49`), no fix.

**C6. Multiple outstanding AR/AW with ordering.** XHB500 allows 1 read (`ready_for_read`) and 1 non-EWR write; the AW/AR nodes' windows are 8. Gain bounded by AW/AR window: 8/49 ⇒ ≥6.1 cyc/txn (7.7× over 47) until C1 deepens them; needs in-order return (hmaster tied 0, ids all 0 — reordering by master is impossible as wired, `tidelink_top.sv:2678-2679`). Scope: XHB500 regen (outstanding read limit), AXI node `nonDataFifoSize`, ordering/ID plumbing. Risk: high (same wedge family). Effort: **L**. rev2: not touched.

**C7. Faster/DDR link clock.** (a) KR260 `/8 → /4 or /2`: 2–4× on *every* number, no RTL — but zero KR260 eye/BER data exists and there is no IDELAY (`KR260_PORT.md:354`); hclk is already decoupled from the divider (`tidelink_design.tcl:190,218`). (b) ASIC: run the pads at the 100 MHz target (SDC placeholder is 250 MHz — decide which and re-sign-off; 250 would be 2.5×). (c) DDR (`WavD2DGpioTx` `padWidth`/ODDR, `tidelink_clk_tx_oddr.sv` exists for the clock only): 2× on top; changes the PHY (deser, deskew, calibrator) — a real PHY revision. Effort: S (a), S (b, constraints only), L (c). rev2: not touched.

**C8. Header compression / short-packet path for 32-bit singles.** Wlink short packets carry only the 4 B header (word_count is the payload, `LinkLayer.scala:492`) — a 32-bit data word cannot fit. Compressing the long header 6 B → e.g. 3 B saves at most 3/13 = 23% of a Path-B packet and 0 link cycles at 8 lanes (13 → 10 B is still one 16 B word); at 4 lanes it would make TL/W/R packets 1 cycle instead of 2. Format change on both dies, ECC/CRC coverage change. **Dominated by C2** — not worth it on its own. Effort: M. rev2: no.

**C9. Decouple obs/backstop from the hclk critical path (FPGA fmax).** Current worst path 12.2 ns of 40 ns; fmax ≈ 78 MHz vs 25 MHz used. Zero throughput value today (link clock, not hclk, binds). Only relevant if hclk goes ≥75 MHz; then the two 20-level paths (`sync_obs_rxcap0` chain; `axi_ahb_sub HADDR → a2l_fc_replay mem CE`) need a register stage. Effort: S. rev2: adds more `tidelink_top` backstop logic (TL-042/044) — re-check WNS on rev2's ASIC-fileset FPGA image (`526e0ab8`).

**C10. DMA-driven / streaming path for bulk moves.** TXGEN (`tidelink_tx_gen.sv`) already drives `ahb_tx` at 1 word/hclk with a hardware pair-credit gate; it *is* the streaming engine and it is what measured the 3.06 floor — so it gains everything C1–C3 deliver, with no further RTL. A DMA should therefore target the **mailbox port (Path B)**, not `ahb_sub` (Path A, 15–45× slower). Missing pieces: a memory-to-`ahb_tx` DMA (TXGEN generates patterns, it does not read memory), a PL/ASIC-side RX drainer symmetric to TXGEN (`kr260_drain.py` issues `len+2` PS reads per packet), and `REL_THRESHOLD` programmed to 0 at bring-up. Effort: M. rev2: not touched. Correctness caveat: the un-root-caused concurrent-drain corruption (150–300 mismatches/run) sits exactly on this pattern [MEM C5/C7] and must be closed first.

**C11. Small runtime tunings (ship now).** `ack_dly_count=4` on the *receiver* side per direction (6.4% HW-validated), `REL_THRESHOLD=0` at bring-up, TXGEN dead-time fix (already in tree, `tidelink_tx_gen.sv:358`). Effort: S.

### Ranked by gain/effort

| Rank | Candidate | Gain (Path) | Effort | Prereq / risk |
|---|---|---|---|---|
| 1 | C7a KR260 divider /8→/4 (or /2) | 2–4× everything (both) | S + bench eye | electrical only |
| 2 | C11 ack_dly=4 / REL_THRESHOLD=0 | 1.07× / removes +25% credit-loop tax (B) | S | none |
| 3 | **C1 window 16→64** | **3.06× @8L** (B), lifts A's AW/B/AR nodes | L | Chisel regen of worst-history module |
| 4 | C3 lanes 0xFF | 2× after C1 (both) | S | KR260 eye at 8 lanes |
| 5 | **C2 multi-word packets** | 2–3.2× after C1 (B) | L | FC word format |
| 6 | C10 DMA→mailbox | removes CPU/PS from the loop; enables C1–C3 to be seen | M | concurrent-drain corruption |
| 7 | C5 bursts + C4 posted writes | 47 → ~1.7 cyc/word (A), i.e. ~25× on Path A | L + L | latent burst corruption; hazard-list wedge |
| 8 | C7c DDR PHY | 2× (both) | L | PHY revision |
| 9 | C6 multi-outstanding AR/AW | ≤7.7× (A) until C1 | L | ordering, wedge family |
| 10 | C8 header compression | ≤1.3× @4L, 0 @8L | M | dominated by C2 |
| 11 | C9 fmax decoupling | 0 today | S | only if hclk ≥75 MHz |

## 4. Verdict — is there "much" we can do?

**Today (realistic, measured or ratio-scaled):** the mailbox path delivers 3.06–3.8 link cycles per 32-bit word ⇒ **1.6–2.0 Mb/s on KR260 (6.6–8% of the 25 Mb/s raw pad rate)** and, at the same link-cycle cost, **≈65 Mb/s on a 100 MHz-UI ASIC (8% of 800 Mb/s raw)**. The bus path is ≈47 link cycles per word ⇒ ≈4 Mb/s ASIC, ≈0.13 Mb/s KR260 (non-bufferable singles), and it cannot be sped up by bursts until a latent corruption and the B-return wedge are fixed.

**Next iteration, same GPIO PHY and pads:** C1 (window ≥ RTT) + C3 (8 lanes) ⇒ 1 link cycle/word = **200 Mb/s ASIC / 6.25 Mb/s KR260 (25% of raw)**; + C2 (16-word packets) ⇒ **≈640 Mb/s ASIC / 20 Mb/s KR260 (80% of raw)** — roughly **10× over today**, all in the digital stack (Chisel regen + fc_adapter packing), no pad or PHY change. Faster/DDR link clock multiplies that by 2–4× on the FPGA rig and 2× on the ASIC (C7). Beyond ≈1.6 Gb/s the 8-lane SDR/DDR GPIO PHY is the wall; anything past that needs a serial/UCIe-class PHY (min 4 GT/s per lane — a different chiplet, per `docs/UCIE_VS_WLINK_ANALYSIS_2026_06_09.md`).

**The single biggest lever is the replay-window depth versus the link-domain ACK round trip (16 vs ≈49 link cycles).** It is the reason lanes, clock ratio, packet size and every hclk-side optimisation looked flat; it is the first thing to change, and it is measurable with no RTL change (§5) before committing to the regen.

## 5. Measurement plan — validate the model before any RTL change

What exists and is readable:
* `tidelink_perf` (Regions 5–7, offsets `0x0A0–0x0FC`; on KR260 die_a `0x8403_20A0` PERF_CTRL, `0x…20D0` TX_WORD_COUNT, `0x…20E8` SAMPLE_COUNT [MEM]) counts, in **hclk**: `tx/rx_pkt_count`, `tx/rx_word_count`, `tx_stall_count` (= `tl_fc_a2l_valid & ~ready`, i.e. a2l-window-full time), `rx_stall_count`, `link_busy_count` (= `~tx_router_idle`, wired from Wlink `.tx_link_idle`, `tidelink_top.sv:3339`), `credit_starve_count`, `sample_count`; PERF_CTRL bit 2 clears (`tidelink_perf.sv:240-241,269-296,470-500`). Wired for real (`tidelink_top.sv:2593-2640`, `STUB_PERF=0`). The 2026-07-17 off-by-one that made them unwritable is fixed [MEM].
* `tidelink_fcemit_obs` (tx_link_clk domain) has sticky "presented/granted" witnesses per router channel, not counters (`tidelink_fcemit_obs.sv:1-27`). `tidelink_axinode_obs` gives AXI-channel stalled/wedged bits (Region F). None counts **link cycles**.
* Gap: **no link-clock-domain cycle counter is APB-readable.** Add to `tidelink_fcemit_obs` (already in the editable `Wlink.v` override, tx_link_clk domain): a free-running `tx_link_clk` counter, per-channel `sop&advance` packet counters, an `a2l_full` (window-stall) cycle counter, and `ack_rx` count, snapshot-frozen by PERF_CTRL and 2-flop'd to apb like the existing words. Then `link cycles/word = link_cyc / tl_packets` is read directly on silicon, independent of hclk and host timing.

Sim (no RTL change, cocotb hierarchical probes; all in the existing pair_v2 bench):
1. **Invariant check**: run `test_v2_lane_mask_throughput` at REF 8 / 40 / 160, report link-cycles/word (÷ link period) — expect ≈3.0 flat, both lane masks. Falsifies the model if it scales with hclk.
2. **RTT decomposition**: timestamp, for packet N, the sender `sop`(FCSM_6) → LL `link_data_reg` → PHY pad → peer `WlinkRxLinkLayer` `valid` → `ack_nack_fifo` write → peer `SEND_ACK` sop → sender ACK `pkt_is_ack_pkt` → `a2l_link_addr` update → app `full` deassert. Expect ≈49 link cycles (ack_dly 7) / ≈44.5 (ack_dly 0); the split tells which fixed latencies (deskew cushion, RX-LL header path, CDC FIFOs) are worth attacking alongside C1.
3. **Window-law check**: force `ne_tx_credit_max`/`fe_rx_credit_max` (hierarchical) to emulate windows of 4, 8, 12 with the same RTT — cycles/word must follow RTT/W (12.2, 6.1, 4.1). This validates the lever before the regen, because C9's probe only showed the RTT is constant, not that throughput scales with W.
4. **Path A baseline**: `test_v2_xhb_window.py` timing of one write and one read `ahb_sub → hreadyout`, with `hprot[2]` 0/1 and back-to-back sequences — expect ≈47 link cycles each; then the rev2 burst bench (`test_v2_burst_encodings.py`) for INCR4/16 (corruption must be characterised, not scored green).
5. Live-credit tax: `test_v2_txgen_kr260_ratio.py` with `REL_THRESHOLD` 0 vs 20 and pre-seeded credit — quantifies rank 5 separately from rank 1.

KR260 (on-fabric counters only — the PS→PL path and ssh/Python dominate any host-timed number; the 08-24 "read failures" were an ssh artefact):
1. Same build, TXGEN via APB, read `SAMPLE_COUNT`/`TX_WORD_COUNT`/`TX_STALL_COUNT`/`LINK_BUSY_COUNT` deltas: `tx_stall/sample` ≈ fraction of time window-full (expect ≈ 2/3); `link_busy/sample` ≈ link utilisation (expect ≈ 1/3 at 8 lanes, 2/3 at 4 lanes). These two numbers alone discriminate "window-bound" from "serialisation-bound".
2. A/B pairs, one variable at a time, ≥3 runs each: `ack_dly_count` 7/4/0 (receiver side only); `REL_THRESHOLD` 20/0; pre-seeded vs live credit; lane mask 0xE4/0xFF (rebuild with `TD_AUTO_LANE_MASK_E4=0`); divider /8 → /4 (rebuild) — hclk/word should halve while link-cycles/word (new counter) stays ≈3.06.
3. Path A: never wedge the PS — probe with reads; use the Region F `0x21F8` word (`0xB5` marker) before and after; measure `ahb_sub` single-write throughput with a paced PL-side master (not the CPU) once the burst corruption is fixed.

Traps to keep in the plan: verify each counter can read non-zero *and* zero on a known stimulus before trusting it (five diagnostics in this repo could not report what they exist to report); never take a throughput number at the sim default REF=8 as absolute; never chain lease acquisition with board operations.

## Appendix — evidence index

* PHY 16:1 SDR, link clk = hsclk/16: `GPIO.scala:44,59-66`; `deps/tidelink-phy/rtl/wav/WavD2DGpioTx.v:206-208,381-389`.
* LL framing (4 B hdr + wc + 2 B CRC; bytesPerCycle; no packing): `LinkLayer.scala:427-461,489-493,505-530`; ECC `local_overrides/WlinkEccSyndrome.v`.
* FCSM TX FSM, ACK priority/spacing, credit max: `FC.scala:74,137-140,260-291,444-598,664`; `local_overrides/WlinkGenericFCSM_6.v:236,773,1712`; per-node widths `WlinkGenericFCSM{,_1,_2,_3,_4}.v:42` and CR words `:896-918`.
* Replay window semantics: `FC.scala:740-790`; `local_overrides/WlinkGenericFCReplayV2_13.v:238`; `TideLinkToWlink.v:69-77`.
* Router/pstate: `LinkLayer.scala:64-135,186-259`; channel map `src/rtl/tidelink_fcemit_obs.sv:18`.
* fc_adapter: `src/rtl/tidelink_fc_adapter.sv:152-155,316-334,371-375,433,549-566,655-661`.
* XHB500: `deps/xhb500/generated/xhb_chiplet_slv/.../core_addr.sv:142-166`, `core_resp.sv:160-236`, `hazard_list.sv:46,136`; instantiation/tie-offs `src/rtl/tidelink_top.sv:2663-2679`; ahb_sub pipeline/backstops `:1503-1530,1897-1898,2081-2089`.
* Clocks: `fpga/targets/kr260-pair-onchip/tidelink_design.tcl:190-211`, `tidelink_phy_clk_div2.v:16-19`, `kr260_tidelink_timing.xdc:66-69,132-134`; `syn/asic/fusion-compiler/inputs/constraints.sdc:5,59-95`; `src/rtl/tidelink_link_clk_div.sv:10-24,66`.
* Lane mask: `fpga/filelist.tcl:46-60`; `local_overrides/Wlink.v:2564-2567`.
* Measurements: `tidelink-link-survey-2026-08-01/imp/sim_gate/v2_lane_mask_throughput.log` (97.879 / 97.672); memory files `project_txgen_sim_throughput_measured_2026_07_31.md` (95.8, 89.1, 487.9, 456.6, 152), `project_link_parallelism_and_phy_survey_2026_08_01.md` (19.253, 417.134, 391.639, 603.394, C9 1151 hclk), `project_throughput_is_ps_bus_roundtrip_not_the_link_2026_07_17.md` (busref 36.7).
* FPGA timing: `imp/fpga/output/kr260-pair-onchip/tidelink_design_wrapper_timing_summary_routed.rpt:193-200,355-364,602-611`.
* rev2 delta: `git log --oneline origin/main..origin/rev2/integration -- src/rtl` → `c6f091a1` (TL-044), `82c56e2a` (TL-042 HoL write-age), `e88ff7be` (AR/R CDC overrides); `ea1c3e49` burst bench; `526e0ab8` ASIC-fileset FPGA build.
* Model script: `scratchpad/tp_model.py` (this session).


---

# PART 7 Flows, tooling, hygiene

# TideLink review — BUILD FLOWS, TOOLING, ASIC/FPGA COLLATERAL, REPO HYGIENE

Review tree: `origin/main` = `5e8bdb5a` at `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a` (all file:line cites are relative to that root unless stated). History/branch analysis from the primary repo `$WORKTREES/SoCLabs/tidelink`. Read-only throughout; no boards, no EDA tools. Every claim below was re-measured this session — memory files were used as hints only.

Legend per finding: **Sev** (P0 blocker / P1 high / P2 medium / P3 low) · **Conf** (H/M/L) · **Effort** (S <1d / M 1-3d / L >3d) · **rev2** (whether `origin/rev2/hygiene` `df0f1f24` or `origin/rev2/integration` `cba9774d` already addresses it: FIXED / PARTIAL / NOT).

Two side-notes on method, first:
- **My own instrument tripped one of the findings.** `make -C cocotb -n regression` (a dry run, permitted by the ground rules) executed for >2 min and **wrote `.result`=FAIL and `run.log` into ~30 `cocotb/<env>/` dirs** of the review tree. They are gitignored (`*.log`, `*.result`; `git status --porcelain` is unchanged — still only the 3 known `dut_src_*.f` churn lines), but they exist. My attempt to remove them was blocked by the permission classifier, consistent with the read-only rule, so **they are still on disk** — see F-2.2 for why this happened and please delete `find cocotb -maxdepth 2 \( -name .result -o -name run.log \) -newer scratchpad/origin_tags.txt` at the caller's discretion.
- `rev2/hygiene` is **not** merged into `rev2/integration` (`git merge-base --is-ancestor` = NO), so "fixed on rev2" below always names which branch.

---

## 0. Headline verdicts

| Area | Verdict |
|---|---|
| Root Makefile | Works, heavily guarded, but 84% of 1986 lines is a hand-expanded `sim_gate` table duplicated 4 ways. Table-driven rewrite is mechanical. |
| cocotb/Makefile | **Broken gate**: `make regression` can never exit non-zero (summary recipe is attached to `.PHONY`), and `make -n regression` writes FAIL result files. |
| Flists | 33 hand-maintained lists, 9 orphans, the two 186-source tapeout/FPGA lists are parallel copies (174 shared / 12 deliberately different), and ≥10 further forks of the FPGA list live in cocotb/imp/scratch. Semantic tooling exists but is **not wired in** (no `.gitattributes`, no CI call). |
| ASIC flow | Closer than 08-10: all three blockers are fixed at script level on `main` (`9d1b2eaa`). **Not tapeout-ready**: no post-fix build archived (the fix commit itself says the correctly-constrained design fails timing), the RTL-Architect copy of `read_design.tcl` still has blocker #2, DFT is a TODO scaffold, LVS grader false-passes on `main`, derates are placeholders. |
| FPGA flow | One-command build exists; the manifest **can lie** on `main` (fail-open `git_dirty`, no `.bin` hash, no XHB500 digest, no `axi-chiplet-controller` pin). rev2/hygiene closes 2 of 4. |
| Public exposure | `affbda14` cleaned `syn/asic` + `set_env.sh` + `common.mk` only. **Still on `origin/main`**: a board credential (24 hits / 18 files, in public history since `a04a194b` 2026-07-31), both board IPs (87 hits / 41 files), Arm release-coded drop name in 41 Makefiles, EDA install paths in 40, a real PDK path in `cocotb/tidelink/Makefile:40-42`. rev2/hygiene removes the credential only. **Rotation is the only remediation for the credential.** |
| Deps | 3 real submodules + an ungoverned 195 MB generated vendor tree. Fresh public clone is buildable **only** with Arm-licensed CMSDK/XHB500 + VCS/Vivado — document that; the repo is not independently buildable and never can be. |
| Hygiene | 18 worktrees (3 dirty), 35 local branches (28 merged, 2 local-only tips), 145 tags all on origin (the "19 on neither" is resolved), gitlab abandoned, GitHub has **no CI at all**. |
| Docs/regmap | Four hand-maintained descriptions of one register map (SV, RDL, 2×MD) with documented disagreements; the C headers are generated from the RDL that is wrong about `fcsm_state`. |

---

## 1. Makefiles

### 1.1 Root `Makefile` — map
`wc -l` = 1986 lines, 115,838 bytes. Section headers (`# ===` / `# ---` lines):

| Lines | Section | Notes |
|---|---|---|
| 6-60 | Silicon-replication test gates, `xdc_lint` | |
| 61-80 | `farm_gate` (mandatory pre-farm gate) | delegates to `fpga/farm_gate.sh` |
| 81-162 | `sim-repro`, `sim-regression`, `sim-regression-v2` | legacy pre-`sim_gate` gates |
| 163-1874 | **`sim_gate`** (aggregate pre-deploy gate) | **1,712 lines = 86% of the file** |
| 1875-1986 | Publication guard (`vendor-check*`, `install-git-hooks`) | added 2026-08-14 |
| 1819 | `include flows/makefile.asic` (72 lines: `fc`, `gdsii`, `fc_lec`, `fc_etm`, `fc_calibre_*`, `asic_stage`, `flist_synopsys`) | |

Counts: 113 rule definitions; **80 `sim_gate*` targets**; 7 `.PHONY` lines.

**F-1.1 — 4-way hand-maintained duplication of the suite table.** Sev P2 · Conf H · Effort M · rev2 NOT.
Every suite is spelled in four places that must agree by hand: (a) its target body (e.g. `sim_gate_v2_data` at :412-414, one `$(call sim_gate_run,<name>,$(MAKE) -C cocotb/<dir> … MODULE=…)` each), (b) the `.PHONY` list :285-300, (c) `SIM_GATE_ALL_SUITES` :1544-1560 (55 names) / `SIM_GATE_QUICK_SUITES` :1568-1572 / `SIM_GATE_SENTINELS` :1566, (d) the ordered `sim_gate:` recipe :1594 ff (one `$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_X` per suite). The repo has already paid for this: `abe7fcaf` on rev2/integration "score the 2 suites the gate ran but never read", `7aaaf1af` "WIRE the orphaned sim_gate_tl044_hol_write_age into the run sequence". A single table `SUITE_<name> := <dir> <env> <module> [tier]` + `$(foreach … $(eval …))` (the pattern `cocotb/Makefile:22-41` already uses for `run_env`) removes (a),(b),(d) and makes "in the table but not run" impossible.

**F-1.2 — `make -n` trap: closed for `sim_gate_run`, open elsewhere.** Sev P2 · Conf H · Effort S · rev2 NOT.
`sim_gate_run` (:250-283) carries a double guard (MAKEFLAGS `n` refusal at :251-263 and the `case "$${MAKEFLAGS%% *}"` at :269) after the 2026-07-18 incident (:173, :237-245). But GNU make still executes any recipe line containing `$(MAKE)` under `-n`, and 17 such lines exist outside the guarded macro body (`grep -nE '\$\(MAKE\).*(&&|\|)' Makefile` → :565-566, :759, :784, :798-807, :855-858, :1797). Those that sit inside a `$(call sim_gate_run,…)` argument are protected by the macro's early `exit 1`; the ones that are not need the same `case` guard. `cocotb/Makefile:31` is the confirmed live instance (F-2.2).

**F-1.3 — Env dependencies are sane at the root; the sibling-repo layout is the hidden one.** Sev P3 · Conf H · Effort S · rev2 NOT.
`$(TIDELINK_HOME)` is used 19×, `$(CHIPLET_HOME)` 1× (:1111); `ETH_SS_HOME` is *derived* from a wildcard over `../nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh` and `../../…` (:1174-1176) — i.e. the `eth_*` suites assume a particular sibling directory layout. `SIM_GATE_REQUIRE` (:1075) fails loudly with a message, which is the right behaviour, and `site.env.example §7` documents the three sibling vars. The only absolute path in the root Makefile is in a comment (:1166). `set_env.sh` (:33-50) `_require`s `CMSDK_DIR`, `XHB500_IP_DIR` with **no default** — good — and `syn/asic/common.mk:19-20` `-include`s the same `site.env`; `make -C syn/asic/fusion-compiler site-check SITE_ENV=/nonexistent` correctly lists 7 missing vars and exits 1, and `make -n fc_init SITE_ENV=/nonexistent` refuses (`common.mk:195-198`, verified this session).

**F-1.4 — Anti-false-green provenance stamp is good; document it.** (Positive.) `GATE_STAMP := <sha12>-<clean|dirty>` (:246-249) is written into every `.status` and `sim_gate_summary` refuses PASS on a stale stamp. Note its `GATE_DIRTY` is `git status --porcelain` — blind to the gitignored `deps/xhb500/generated` (same gap as F-4.2).

### 1.2 `cocotb/Makefile` (135 lines)
**F-2.1 — `make regression` can never fail.** Sev **P1** · Conf **H** · Effort S · rev2 NOT.
`regression: $(ENVS)` (:44) has no recipe. The "Regression Summary" block that computes `PASS=/FAIL=` and ends in `[ "$$fail" -eq 0 ]` (:80-92) is tab-indented **directly under `.PHONY: link_rate_quick link_rate_full`** (:79) — it is now the recipe of the `.PHONY` special target and is never run. Verified: the dry-run output contains per-env `>> tidelink_fifo: FAIL` lines and **zero** occurrences of "Regression Summary", exit 0. `git blame` shows the summary lines are from `dbb9d73c` (2026-05-23) and the `.PHONY` line that severed them from `regression:` arrived with `2ffc21a5` (2026-08-18, "wire the divider into the regression"). Since 08-18, `cd cocotb && make regression` (the README :286 recipe and the `cocotb-regression` CI job) reports success regardless of any env failing. Fix: move :79 above :44 or give `regression` the recipe explicitly.

**F-2.2 — `make -n regression` writes FAIL result files.** Sev P2 · Conf H · Effort S · rev2 NOT.
`run_env` (:22-41) pipes `$$(MAKE) -C $(1) 2>&1 | tee $(1)/run.log | grep …` then `grep -q 'FAIL=0' run.log || echo FAIL > .result`. Under `-n` make executes the line (it contains `$(MAKE)`), the sub-make dry-runs and prints no `FAIL=0`, so every env is stamped FAIL and `run.log` is overwritten. This is exactly the class the root guard at `Makefile:173` was written for. Same fix (MAKEFLAGS guard) or drop `.result` files entirely in favour of exit codes.

### 1.3 `fpga/Makefile` (1091 lines)
- `-include site.local.mk` (:38) for board IPs/farm host; `site.local.mk.example` ships RFC-5737 placeholders (`192.0.2.1`). Good.
- `VALID_TARGETS` (:56) = 22 targets: **14 `pynq-z2-*` variants**, 7 `kr260-*`, `mps3`. `XILINX_PART` is a 10-arm `ifeq` ladder of identical values (:101-119) — table-driven candidate (**F-1.5**, P3, S).
- `build_design` (:424-451) exports 15 `FPGA_*` env vars and runs `vivado -mode batch -source build_design.tcl` — this is the one-command build. `bit2bin` split by `kr260-%` pattern rule (:643-647): `bit2bin_zynqmp.py` (header-strip only) vs `bit2bin.py` (byte-swap) — the trap from memory is encoded in the Makefile and in `fpgahub.toml` comments; the `$(BITBIN): $(BITSTREAM)` dependency means a stale `.bin` is rebuilt by `make`, but only if you go through `make deploy*`; `verify_build.sh` check (f) only **WARNs** on `.bin` older than `.bit` (:60 header). Should be FAIL (**F-5.4**).
- Deploy: 8 flavours (`deploy`, `deploy_kr260`, `deploy_kr260_both`, `deploy_pair_role`, `*_via_fpgahub`, `*_via_plugin`, `kr260_afi_fix`). Memory records `deploy_kr260` "exits 2 even on success" and `kr260_afi_fix` uses the wrong inner path — I did not touch boards and cannot re-verify; flag as **unverified-known-defect**.

### 1.4 `syn/asic/*/Makefile` + `common.mk`
`common.mk` (200 lines): no defaults for any site path (:9-20, :46-60, :81-131), `MODULE→TOP` map (:29-36), `FLIST` selection prefers `flists/<MODULE>_asic.flist` (:41-44 — for `MODULE=tidelink_top_full` that resolves to `tidelink_top_full_asic.flist`, the **V1** list; the V2 tapeout list is selected by the fusion-compiler Makefile per `git_merge_flist.sh:118`). Site check with named-missing-variable failure (:160-200). `fusion-compiler/Makefile` (411 lines) uses `FC_STAGE_OK: <stage>` markers per stage (:160-255) — the right pattern. `dft/Makefile` (162 lines) targets `insert_scan/insert_mbist/run_atpg/drc_only` all licence-gated. `design-compiler/Makefile` (48 lines) is the legacy flow that `ci/parse_ppa.py` still parses (F-3.9).

---

## 2. Flists

### 2.1 Inventory and consumers
`flists/` holds 33 `.flist` + 1 `.md` (1,972 lines total). Consumer map (`git grep -l -F <name>` excluding `flists/`, `docs/`, `*.md`):

| Flist | Consumed by | |
|---|---|---|
| `tidelink_fpga_v2.flist` (456 lines, 186 sources) | `fpga/filelist.tcl`, `fpga/Makefile`, `build_provenance.tcl`, 20+ cocotb Makefiles/tb_top, `uvm/tidelink_top_system` | **the FPGA source of truth** |
| `tidelink_top_full_asic_v2.flist` (415 lines, 186 sources) | `syn/asic/fusion-compiler` (via `git_merge_flist.sh:118`), `formality/run_lec.tcl`, root `Makefile` (`sim_gate_asicelab_v2`), 6 cocotb benches | **the tapeout selector** |
| `tidelink_top_full_asic.flist` (257) | `syn/asic/scripts/tidelink.FC.read_design.tcl`, `common.mk` default, root `Makefile` (`asic_v1_elab`) | V1 ASIC |
| `tidelink_fpga.flist` (334) | `.gitlab-ci.yml`, `fpga/filelist.tcl` (V1 default!), 8 `cocotb/debug/*`, `lint/verilator`, 3 uvm | V1 FPGA |
| `tidelink_asic.flist` (9) | `common.mk` (`ASIC_FLIST`), `git_merge_flist.sh` | |
| `tidelink_netlist.flist` (4) | 8 forks (see below) | GLS: `${STDCELL_VERILOG}/sc12_cln65lp_base_rvt*.v` |
| `tidelink_top.flist` (90) | `cocotb/tidechart_tidelink_pair`, `lint/verilator` | |
| `tidelink_ahb/apb_regs/apb_addr_ctrl/returner/fifo/fifo_ahb/eye_regs/eye_visibility/lane_checker/cdc_tear*/a2l_replay_cdc*` | one cocotb or lint consumer each | unit lists |
| **ORPHANS (no consumer)**: `tidelink_clkfreq_check`, `tidelink_generic`, `tidelink_idelay_rx`, `tidelink_mul_iter`, `tidelink_perf`, `tidelink_phc_cdc`, `tidelink_rxclk_buf`, `tl_addr_trans_cam`, `tl_addr_trans_regs` | — | 9 of 33, all 2-9 lines |

**F-2.3 — 9 orphan flists.** Sev P3 · Conf H · Effort S · rev2 NOT. Delete or wire (cocotb envs of the same name carry their own `VERILOG_SOURCES`).

### 2.2 ASIC vs FPGA: hand-maintained parallel copies
Normalised source sets (comments/`+incdir`/`+define` stripped): FPGA-v2 186, ASIC-v2 186, **174 common**, 12 differ on each side:

- Deliberate re-points (same basename, different dir): `WlinkGenericFCSM.v`, `_1.._4`, `WlinkGenericFCReplayAddrSync_18.v`, `i2c_master.v` → FPGA reads `src/rtl/local_overrides/`, ASIC reads `deps/axi-chiplet-controller/logical/`. This is the "recovery-stripped ASIC / recovery-bearing FPGA" split; `8b3cc9e4` (2026-08-20) added an 18-line **comment** warning that the FPGA list must not seed a tapeout list, because the compute chiplet already inherited the re-point by copying.
- Platform swaps: `src/rtl/fifo/{fpga,asic}/tidelink_sram.sv`, `${CMSDK_FPGA_SRAM_V}`.
- Shim mechanism: FPGA uses `src/rtl/v2shims/v2_{Wlink.v,axi_chiplet_controller.sv,tidelink_top.sv}` (materialised by `fpga/filelist.tcl:97-160` into `imp/fpga/gen_v2/`), ASIC compiles the originals directly. `tidelink_sync_word.svh` only in ASIC (the "$unit-scope header MUST compile first" chip-killer #1, `tidelink_top_full_asic_v2.flist:42-48`).

**F-2.4 — No generator; the two 186-file lists are edited by hand in parallel, and the FPGA list has ≥10 further forks.** Sev **P1** · Conf H · Effort M · rev2 PARTIAL.
Forks of `tidelink_fpga_v2.flist` (each a full copy with a local tweak): `cocotb/tidelink_axi_datanode_recovery/tidelink_fpga_v2_{eccoff,full_bypass,ecc_only_local}.flist`, `cocotb/tidelink_fcsm_silicon_ratio/tidelink_fpga_v2_fcsm_local.flist`, `cocotb/crc_diag/tidelink_fpga_v2_prefix.flist`, `imp/hw_gate/n1_repro_dam/n1{fix,nofix}_{base,local}.flist` (4), `scratch_resolved/flists__tidelink_fpga_v2.flist`, `scratch_resolved/flists__tidelink_top_full_asic_v2.flist`. This is precisely the "XHB channel fix silently rotted out" / "TL-006 ECC bypass shipped" mechanism: the fix lands in one list and the others keep the old line. `rev2/integration` adds `scripts/ci/flist_divergence.py` and `fpga/asic_fileset/` (TD_ASIC_FILESET=1 builds an FPGA image from the tapeout set, `526e0ab8`) — a checker, not a generator.

### 2.3 `scripts/flist_semantic.py` (37 KB) and the merge driver
- `flist_semantic.py`: `normalise | key | diff | check`; two-layer model (semantic key expands only `${TIDELINK_HOME}`; resolved layer for on-disk existence), order-preserving, no dedup, comments stripped before expansion, absolute paths recorded as their own record kind, exit 2 on any grammar it cannot parse, ratchet allowlist for `check` (:1-70). Well designed.
- `scripts/git_merge_flist.sh` (18 KB): policy R0 denylist (tapeout lists **never** auto-resolved even when byte-identical, :88-119, named approver), R1 absolute path, R2 parse, R3 semantic delta, R5 doc fork.
- **F-2.5 — None of it is active.** Sev P2 · Conf H · Effort S · rev2 NOT. `git ls-files .gitattributes` is empty; only `.gitattributes.flist-driver-snippet` (which says so at :7-12) exists. `git grep flist_semantic -- Makefile fpga .gitlab-ci.yml ci` finds no caller. The driver registration is per-clone (`setup_flist_merge_driver.sh:20`). So the semantic guard protects nothing today; `scratch_resolved/` (6 tracked files, 84 KB) is the residue of a hand-resolved merge that this tooling exists to prevent.
- **F-2.6 — `cocotb/tidelink_a2l_replay_cdc/dut_src_{1,3,5}.f` contain absolute worktree paths** (`$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a/src/rtl/local_overrides/WlinkGenericFCReplayV2_1.v`) and are regenerated per checkout — they show as modified in every worktree (3 lines of churn here; memory's `assume-unchanged` workaround). Sev P3 · Conf H · Effort S. Generate them into `imp/` or use `${TIDELINK_HOME}`.

### 2.4 Recommendation — single source of truth
One machine-readable core description (YAML, FuseSoC-style `.core`, or a tiny Python DSL) with **filesets** (`common`, `phy_v2`, `fpga_sram`, `asic_sram`, `fcsm_recovery_overrides`, `fcsm_deps`, `v2shims`, `ecc_local`, `netlist_gls`) and **targets** that compose them (`fpga_v2 = common+phy_v2+fpga_sram+fcsm_recovery_overrides+v2shims`, `asic_v2 = common+phy_v2+asic_sram+fcsm_deps+sync_word_first`). Generate every `.flist`, `fpga/filelist.tcl`'s input, the cocotb local variants (as *overlays*, not copies) and the Vivado/FC read lists from it; commit the generated lists **and** a `make flists-check` that regenerates and diffs (the `flist_semantic.py diff` already gives the comparator). The tapeout-vs-FPGA divergence then becomes a 5-line, reviewable, named choice instead of an 18-line comment.

---

## 3. ASIC flow (`syn/asic/`)

### 3.1 What changed since 08-10
`git log --since=2026-08-10 -- syn/asic` on `main`: exactly two commits — `9d1b2eaa` 2026-08-14 "the three ASIC flow blockers — and the timing signoff was not real" and `affbda14` 2026-08-14 "move the PDK layout out of a public repository". `git log d0a977aa..HEAD -- syn/asic` → only `affbda14`. `rev2/integration` touches 3 files: `calibre/scripts/lvs_verdict.sh`, `run_calibre_lvs.sh`, `fusion-compiler/scripts/7_drc.tcl`.

### 3.2 The three blockers at `5e8bdb5a`
(a) **scan_clk / case analysis — FIXED on main.** `1_init_design.tcl:243-300`: `set_case_analysis 0` on `scan_mode/scan_shift/scan_asyncrst_ctrl` per scenario (:291), gated `FC_SCAN_CASE_ANALYSIS` default on (:277), and the ÷16 TX/RX word clocks declared via `create_generated_clock` (:349) with an abort if the selector does not resolve, because case analysis alone strands 9,610 flops (TCK-002, :264-267). The commit message records the measurement (14,747→0 scan_clk sinks). `constraints.sdc:124` keeps `scan_clk` in its own async group.
(b) **scen_slow zero uncertainty — FIXED in the FC copy, NOT in the RTLA copy.** `syn/asic/scripts/tidelink.FC.read_design.tcl:272-288` loops `current_scenario` over all scenarios before `set_clock_uncertainty/-setup/-hold` and I/O delays, plus a placeholder OCV derate (:289 ff, "NOT characterised numbers"). **But `syn/asic/rtl-architect/tidelink.FC.read_design.tcl` (234 lines, a divergent older copy) still does `set_clock_uncertainty` at :192 and I/O delays at :220-223 with no `current_scenario`** after creating `scen_slow` (:152) and `scen_fast` (:160) — the exact blocker, alive in the RTL-Architect flow. **F-3.1** Sev P2 · Conf H · Effort S · rev2 NOT. Delete the copy; have `rtl-architect/Makefile` source the shared `scripts/` one.
(c) **`read_sdc` abort — FIXED.** `constraints.sdc` contains `-filter` only in comments (:166, :174, :212, :214, :225); an ordering-rule header (:160-180) mandates pure SDC and early placement of the TX-eye/PHC constraints; a completion marker is asserted by `1_init_design.tcl:101-140`, which `redirect`s `read_sdc` to a log per scenario and fails on `stopped at line`, `Errors reading SDC file`, or missing `TIDELINK_SDC_OVERLAY_COMPLETE`. The Tcl-only constraints were re-landed in `1_init_design.tcl` (:172 ff).

### 3.3 What is still not closed
**F-3.2 — No post-fix build exists on `main`; the fix commit states the correctly-constrained design fails timing.** Sev **P0** (for "tapeout-ready") · Conf H · Effort L · rev2 NOT. `9d1b2eaa` body: "Build b11 … closed at setup WNS -0.40 / hold -1.51 / 140 NVE, against the shipping -0.06/-0.22. THE CONSTRAINTS ARE RIGHT; THE DESIGN FAILS THEM. Expect red on the first build after re-landing these." Nothing under `syn/asic` or `imp/ASIC` on `main` records a build after 08-14 (`imp/ASIC` tracks only `Makefile`+`README.md`; all run dirs are gitignored). `rev2/integration` `9ce95fe3` records an FPGA image built from the tapeout file set, not an FC run.
**F-3.3 — DFT is a scaffold.** Sev P1 · Conf H · Effort L · rev2 NOT. `dft/README.md:1-5` "scaffolding, not closure"; `insert_scan.tcl:147-209` emits only `puts "TODO: set_dft_signal …"`/`preview_dft`/`insert_dft`; `insert_mbist.tcl` likewise. `9d1b2eaa`: "insert_scan.tcl issues zero set_dft_signal today; this fix makes FUNCTIONAL mode correct, nothing more." RX ÷16 phase (`adj_count = count + io_phase_offset`, combinational) is flagged open for STA sign-off in the same commit.
**F-3.4 — LVS verdict false-passes on `main`.** Sev P1 · Conf H · Effort S · rev2 **FIXED** (`9a7c02c7`, `lvs_verdict.sh`, `f95c3726` checker controls). `calibre/scripts/run_calibre_lvs.sh:128-131` tests `grep -q "CORRECT"` **before** `grep -q "INCORRECT"`; "INCORRECT" contains "CORRECT", so every mismatch report prints `RESULT: LVS CORRECT`.
**F-3.5 — `fc_drc` / `07_summary` vacuous PASS.** `9d1b2eaa` fixed `summarise_check` in `7_drc.tcl` on `main`; rev2/integration `8a91087b` goes further ("make fc_drc able to fail, and stop scoring absent reports as 0"). PARTIAL on main.
**F-3.6 — TL-006 header-ECC bypass.** V2 tapeout list closed: `tidelink_top_full_asic_v2.flist:247-253` re-points to `src/rtl/local_overrides/WlinkEccSyndrome.v` (2026-08-08) with a "NETLIST-AFFECTING, needs combined-config sim" note. **V1 list still reads the deps bypass** (`tidelink_top_full_asic.flist:135` `deps/axi-chiplet-controller/logical/wlink/WlinkEccSyndrome.v`) — fine only if V1 is truly dead; `sim_gate_asicelab` still elaborates it. Sev P3 · Conf H.
**F-3.7 — `verify_fix_delivery.sh` does not exist in the tree.** `ls syn/asic/scripts/` → `build_mem_ff_db.tcl create_fusion_lib.tcl tech_paths.tcl tidelink.FC.read_design.tcl verify_partition_handoff.sh`; not on rev2/integration's file list either. The netlist-marker checker with must-be-present controls (memory 08-19) is **uncommitted and possibly lost**. Sev P2 · Conf H · Effort S. Recover from the worktree it was written in (`git -C … status` in each of the 18 worktrees; none of the dirty ones lists it) or rewrite from the rule set in `feedback_netlist_grep_wires_are_invalid_markers_2026_08_19.md`.
**F-3.8 — Two divergent `create_fusion_lib.tcl` and `read_design.tcl` copies** (`syn/asic/scripts/` vs `syn/asic/rtl-architect/`), see F-3.1. 
**F-3.9 — `ci/parse_ppa.py` parses Design Compiler reports** (`syn/asic/design-compiler/tidelink_dc_reports`, :1-12) for a flow the project left in May (`fusion-compiler` since `81095614`/`6e904c63`, 2026-05-21). The PPA row on the dashboard is measuring nothing current. Sev P3 · Conf H · Effort S.
**F-3.10 — Derates are placeholders** (`read_design.tcl:289 ff` "conventional 65 nm flat-derate starting values, NOT characterised … Replace with foundry AOCV/POCV tables before tapeout"). Sev P1 · Conf H · Effort M (needs foundry tables).

**Verdict:** closer to tapeout-ready than 08-10 — the *flow* can now detect its own constraint loss and times the right clocks — but the *design* has not been shown to close under it, DFT does not exist, and two sign-off checkers on `main` cannot report failure. Not tapeout-ready.

---

## 4. FPGA flow (`fpga/`)

### 4.1 Targets and liveness
23 target directories under `fpga/targets/` (22 in `VALID_TARGETS`, plus `kr260_resync.sh`). Evidence of life: `fpgahub.toml` has build/deploy actions for `pynq-z2-{single,pair,pair-all,pair-flip-all}`, `kr260-pair-{ptp,flip-ptp}`, `kr260-eth-chiplet{,-flip}`, `mps3`; **`kr260-pair-onchip` — the vehicle every HW result since 07-16 came from (memory) — has no fpgahub action** and is deployed by the hand recipe in `project_consolidation_landed_hwvalidated_2026_08_19.md`. The 10 `pynq-z2-pair-{slow,ila,mmcmbypass*,flip*}` variants are 2026-05/06 bring-up experiments with no consumer other than the Makefile ladder. **F-4.1** Sev P3 · Conf M · Effort S: archive the z2 variants to a tag; add an `onchip` fpgahub action.

### 4.2 Build provenance manifest — can it lie?
`fpga/scripts/build_provenance.tcl` writes `imp/fpga/output/<target>/*.manifest.json` from inside `build_design.tcl` with: `sha256` (of the `.bit`), `source_commit`, `git_dirty`, `phy_marker`, `flist`, `submodule_pins{deps/tidelink-phy, deps/tidelink-gpio-phy}`, `usr_access`, `target`, `build_host`, `build_date`, `label` (:281-299). It also verifies the packaged IP against current RTL (`tl_ip_verify`, :240-243) — that closes the "stale packaged IP" trap of 07-02 at build time (and `farm_gate.sh` Tier-0.a re-uses the same procs).

Ways it can still lie at `5e8bdb5a`:
1. **`git_dirty` fail-open** — `tl_git_sha` (:71-80): `rev-parse` failure returns `"unknown"` and skips the dirty check; `![catch{status}] && …` short-circuits to *clean* when `git status` errors (symlinked `deps/` → rc 128). **F-4.2** Sev **P1** · Conf H · Effort S · rev2/hygiene **FIXED** (`df0f1f24`: `unknown-dirty`, `catch → -dirty`), rev2/integration NOT, main NOT. Every `git_dirty:false` manifest predating the fix is unverified.
2. **`git status --porcelain` is structurally blind to `deps/xhb500/generated`** (gitignored, `.gitignore:72`; 0 of ~2,626 files tracked; 4 flists compile 32 files from it incl. the hazard-list block). **F-4.3** Sev P1 · Conf H · Effort S · rev2/hygiene **FIXED** (`6a174a3b`: `scripts/xhb500_tree_digest.sh` + `deps/xhb500/TREE.sha256`, `sim_gate_env_check: xhb500-check`), main NOT.
3. **No pin for `deps/axi-chiplet-controller`** — the Wlink/FCSM source, and the one whose re-point *is* the tapeout divergence — is not in `submodule_pins`. **F-4.4** Sev P2 · Conf H · Effort S · rev2 NOT.
4. **The `.bin` is not hashed**; the sha256 is of the `.bit`. Boards flash the `.bin`. `verify_build.sh` check (f) only WARNs on a `.bin` older than its `.bit` (:60), and memory records a live case (08-24) of `.bit`/manifest rewritten mid-campaign while the `.bin` stayed old. **F-4.5** Sev P2 · Conf H · Effort S · rev2 NOT. Hash the `.bin` too and make (f) a FAIL.
5. No tool version, no XDC/target-dir digest, no `FPGA_INSERT_DEBUG_CORE`/define set recorded — an ILA vs no-ILA build of the same commit produce manifests that differ only in `sha256`. **F-4.6** Sev P3 · Conf H · Effort S.

### 4.3 `-verilog_define` → OOC IP trap
`build_design.tcl:478-542`: the comment at :478-488 records the measurement (OOC `runme.log` had zero `-verilog_define`), and :503-524 materialises the BD's IP runs (`export_ip_user_files` + `create_ip_run`) before injecting, "for ANCHOR builds only" per the memory and the comment at :503. `TIDELINK_PHY_V2` deliberately stays top-only, so the three `` `ifdef TIDELINK_PHY_V2 `` blocks in `local_overrides/axi_chiplet_controller.sv` remain dead in every bitstream. **F-4.7** Sev P2 · Conf M (I did not re-open a Vivado run) · Effort S: decide what those blocks were for and either delete them or make the define reach the OOC run for every build, with a `grep -c verilog_define <ooc>/runme.log` assertion in `verify_build.sh`.

### 4.4 ILA / mark_debug path
`FPGA_INSERT_DEBUG_CORE=1` → `insert_debug_core.tcl` after `synth_1` (opens the run, groups `MARK_DEBUG` nets by base name, attaches to `clk_wiz_0 clk_out1`, `implement_debug_core`); otherwise `strip_mark_debug.tcl` is installed as `STEPS.OPT_DESIGN.TCL.PRE` on `impl_1` (`build_design.tcl:570-590`) to avoid Chipscope 16-213 on constant-folded marked nets. Clean and documented. The 13 `mark_debug` probes dropped by the pin move `e6aaa82f→d0a977aa` (memory) are an RTL-side artefact, not a flow one.

### 4.5 Gates around the build
`farm_gate.sh` (mandatory pre-farm): Tier-0.0 provenance JSON, 0.a IP-match, 0.b `xdc_lint`, `sv_anti_pattern_lint` with **line-number-keyed** baselines (`farm_gate_sv_baseline.txt`, 41 lines; rev2/hygiene `57b67002` re-keys them on content — FIXED there, NOT on main: **F-4.8** Sev P2). `verify_build.sh` (26 KB, checks a-i) is the post-build gate; rev2/integration `59d4366f` fixes it exiting 0 on a build it could not verify (NOT on main: **F-4.9** Sev P1 · Conf H (peer-verified, commit read) · Effort S). `msg_gate_child_*` Vivado message promotion; rev2 `48897cb0` fixes it installing nothing while looking armed (NOT on main).

**One-command reproducible build with a manifest that cannot lie?** `make -C fpga build_design TARGET=<t>` is one command and does emit a manifest, but on `main` the manifest can report clean on an unevaluable tree, is blind to the largest source tree, omits the Wlink pin and the flashed artefact's hash. With rev2/hygiene merged and F-4.4/F-4.5 done: yes.

---

## 5. Public-repo exposure (`origin` = public GitHub `SoC-Labs/TideLink-Chiplet-Interconnect-AHB`)

All counts are `git grep` over **tracked** files at the named ref. **The board credential is never printed here; it is an 11-character string used as a shell/python default password.**

| Class | `origin/main` @5e8bdb5a | `rev2/hygiene` | `rev2/integration` | Example (file:line) |
|---|---|---|---|---|
| **Board credential** | **24 hits / 18 files** | **0** | 24 / 18 | `imp/hw_gate/ila_run_tl035.sh:30`, `pynq_host/scripts/bringup_pair_release.sh:14`, `docs/HANDOVER_AXI_DATANODE_RECOVERY.md:48,59`, `docs/handoff/TL027_A2L_ETHCHIPLET_HANDOFF.md:47` (with username + both IPs on one line) |
| Board IPs `<REDACTED-IP>` | 87 / 41 | 87 / 41 | — | `docs/KR260_BOARD_ENV.md:18-19`, `docs_site/boards.md:134`, `docs/BUILD_REGISTRY.yaml:556` |
| Jump-host IP `<REDACTED-IP>` | 2 | — | — | `docs/BOARD_DEPLOY_RUNBOOK.md:18`, `docs_site/boards.md:66` |
| Arm release-coded drop `…/<ARM-CMSDK-DROP>` | 41 files | 41 | 41 | 40× `cocotb/*/Makefile` (`export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/<ARM-CMSDK-DROP>/…`, e.g. `cocotb/tidelink/Makefile:6`), `cdc/Makefile:2,8` |
| EDA install paths `<EDA-INSTALL>` etc. | 40 files | 40 | — | 38× `cocotb/*/Makefile` `VERDI_HOME = …`, `cdc/Makefile:12` `SPYGLASS_HOME ?= …`, `cocotb/debug/phc_pair/Makefile:39` `<EDA-INSTALL>`, `docs/reference/DEPENDENCIES.md:107-109` |
| Real PDK / memory-compiler paths | 1 Makefile + docs | same | — | **`cocotb/tidelink/Makefile:40` `PHYS_IP_PATH ?= <PHYS-IP-PATH>`, `:42` `MEM_PATH ?= <MEM-COMPILER-PATH>`**; `docs/reference/DFT_PLAN_2026_05_28.md:36-37,55`; `docs_site/integration.md:593-594` (`tcbn65lpbwp12t`, rf_16k path) |
| Library / process names (`tcbn65*`, `cln65lp`, `sc12_cln65lp`) | 7 files tcbn65; `flists/tidelink_netlist.flist:2-3`; `fusion-compiler/Makefile:90`; `constraints.sdc:241`; `routing_rules.tcl.template:5,11` | same | — | family names, not drop codes — lower severity, but `site.env.example:34-45` says the policy is to keep even corner-encoded stems out |
| `$WORKTREES/…` | 139 hits | 73 files | — | 30× cocotb Makefiles/tests (`cd $WORKTREES/td_idelay_wt && source set_env.sh`), `.claude/workflows/tidelink-bug-lifecycle.js:12`, `dut_src_*.f` |
| `<FORMER-USER-HOME>` | **0** on main | 1 file (inventory doc) | 0 | removed by `affbda14`/`32d20a98`; still in history (`b9523996`, `2bb154c6` 2026-06-02) |
| `/research/` | 33 files | 33 | — | mostly "read-only, never write" prose; the two Makefile defaults above are the real ones |
| `<REDACTED-IP>`, `CG096`, `PL417`, `ts1n65`, `sc12mc` | 0 | 0 | 0 | |

**F-5.1 — The board credential is published, and history rewriting cannot unpublish it.** Sev **P0** · Conf H · Effort S (rotate) · rev2/hygiene FIXED going forward (`60637105` removes the 24 defaults, adds `scripts/ci/check-secrets.sh` with self-arming rules :39-45), rev2/integration NOT, main NOT.
Evidence: first commit carrying it `a04a194b` (2026-07-31) **is an ancestor of `origin/main`** (`git merge-base --is-ancestor` → yes); `git log --all -S<cred>` = 11 commits. It sits beside the username (`ubuntu`) and both board IPs in the same lines (`docs/handoff/TL027_A2L_ETHCHIPLET_HANDOFF.md:47`, `docs/HANDOVER_AXI_DATANODE_RECOVERY.md:47-48`). Even if `main` is force-rewritten, forks, clones, GitHub's cached views and anyone who fetched since 07-31 keep it. **State plainly: rotate the board password (and any host that shares it), then merge the removal; do not spend effort on history rewriting for this class.** The IPs are RFC-1918 behind the jump host; still, `site.local.mk.example` already shows the right pattern (placeholders) — move the runbook IPs into `site.local.mk`/`fpgahub` config.

**F-5.2 — `affbda14` closed the ASIC layer only.** Sev P1 · Conf H · Effort M · rev2 NOT.
`affbda14` (24 files, all under `syn/asic`, `set_env.sh`, `site.env.example`, `.gitlab-ci.yml`) removed 37 real-path lines from `common.mk` alone. The **cocotb/cdc/lint Makefile layer was never touched**: 41 files still embed the Arm release-coded CMSDK drop name that `site.env.example:38-45` explicitly classes as licensee inventory, 40 embed versioned EDA install paths, and `cocotb/tidelink/Makefile:40-42` embeds a real Arm/TSMC physical-IP path and the memory-compiler path. These are `?=` defaults, so they silently *work* on the lab host and defeat the "no default path" policy that `set_env.sh:22-30` states. Fix is mechanical: delete the 3 lines from each cocotb Makefile (they are already exported by `set_env.sh`), route `VERDI_HOME`/`SPYGLASS_HOME` through `site.env`.

**F-5.3 — The vendor guard depends on an external repo and no GitHub CI runs it.** Sev P2 · Conf H · Effort S.
`make vendor-check` (Makefile:1911-1935) fails closed (exit 2) when `../ASIC/asic-toolkit/ci/check-vendor-collateral.sh` is absent — correct — but that scanner lives in `nanoSoC-ASIC-Toolkit`, so a standalone clone cannot run it, and the GitLab job `vendor-collateral` (`.gitlab-ci.yml:254-258`, `allow_failure: false`) runs on the abandoned forge. **There is no GitHub Actions workflow on any local or origin branch tip** (scan of all `refs/heads` + `refs/remotes/origin`; a `.github/workflows/ci.yml` was added once in `a1a27de7` 2026-05-28 and is on no current branch). Only the `deps/tidelink-phy` submodule has `.github/workflows/ci.yml`. rev2 `8cb7b70a` says the same ("nothing is gated by CI on either forge"). Consequence: nothing prevents the next `git push origin main` from adding another credential.

**F-5.4 — Public history already contains the pre-08-14 PDK layout.** Informational. 14 commits on `origin/main`'s history match `<PHYS-IP-PATH>` (`0cf39daa` "prepare repo for publication" 2026-07-24 among them — i.e. it was pushed *after* a publication-prep pass). Same conclusion as F-5.1: treat as disclosed; the mitigation is that these are mount points and family names, not keys.

---

## 6. Deps / vendoring

`.gitmodules`: three submodules. `git ls-files -s deps` shows three gitlinks (mode 160000) + two tracked `deps/xhb500/configs/*.cfg`; **`deps/xhb500/generated` is gitignored** (`.gitignore:72`) and was, until `5e8bdb5a`, tracked as a **symlink into the primary worktree's ignored tree** (commit body: "a freeze SHA did not pin the XHB500 bridge RTL; it pinned a pointer into an ungoverned tree").

| Path | Kind | URL | Pin @5e8bdb5a | Pin is | Reachable anonymously? |
|---|---|---|---|---|---|
| `deps/axi-chiplet-controller` | submodule | `https://git.soton.ac.uk/soclabs/chiplets/axi-chiplet-controller.git` | `efe5623c` | tip of `feat/l3-autonomy-merge` | **yes** (`git ls-remote` OK this session); has nested submodules `soctools_flow`, `asic_flow` (also soton) |
| `deps/tidelink-gpio-phy` | submodule | `https://github.com/SoC-Labs/TideLink-Chiplet-GPIO-PHY.git` | `6ee8418b` | tip of `feat/standalone-phy-bist` | yes |
| `deps/tidelink-phy` | submodule | **same URL as above** | `8c560c57` | tip of `fix/calibrator-wrap-stitch` | yes |
| `deps/xhb500/generated` | generated (Arm XHB-500 generator, `set_env.sh:74-125`) | — | none on main (rev2/hygiene: `TREE.sha256`) | — | requires licensed `XHB500_IP_DIR` |

**F-6.1 — Same repository vendored twice at two branch tips.** Sev P2 · Conf H · Effort M · rev2 NOT. `tidelink-gpio-phy` and `tidelink-phy` are the same GitHub repo; every pin is a *branch head*, none a tag; the primary repo pins `tidelink-phy` at `5c76e764` (different from main's `8c560c57`). `mainclone` remote in the primary repo is a filesystem path into `deps/tidelink-phy`, and the review tree's submodules have `origin` = a path into the primary's `deps/` (they were cloned from the sibling checkout, not upstream). Reproducible today because the SHAs are reachable, but a branch force-push upstream breaks `--recursive` silently. Pin to tags, collapse to one submodule.
**F-6.2 — Fresh clone, in principle:** `git clone --recursive` → works (all URLs reachable, nested soton submodules included) → `cp site.env.example site.env` → needs **Arm-licensed** `CMSDK_DIR` (+ `cmsdk_fpga_sram.v`, absent from some packages, `set_env.sh:55-64`) and `XHB500_IP_DIR` → `source set_env.sh` runs the XHB500 generator (needs perl `File::Slurp`, python 3.7-3.10, `set_env.sh:129-150`) → any `make` needs VCS (sim), Vivado 2024.1 (FPGA), FC/PT/Formality/Calibre (ASIC). The `_require`/`site-check` failures are loud and named. **The public repo is therefore not independently buildable and never can be** (Arm IP + foundry collateral); README should say so up front and offer the Verilator/lint path (`lint/verilator/Makefile` consumes `tidelink_top.flist`) as the licence-free entry point.
**F-6.3 — `deps/axi-chiplet-controller` is 438 MB of tracked content (wav-wlink-hw verif 419 MB)** — the biggest weight in a recursive clone; consider `--depth`/sparse guidance or a slimmed fork.

---

## 7. Repository hygiene

### 7.1 Tracked junk at `5e8bdb5a` (1,778 tracked files excl. submodules; 0 tracked `.bit/.bin/.vcd/.log/.dcp`)
- `BRINGUP_REPORT.md` (72 KB) at root — a 2026-05 campaign log; belongs in `docs/` or an archive tag.
- `scratch_resolved/` (6 files, 84 KB): hand-resolved copies of the two big flists + `dut_src` files from a merge — delete (**F-7.1**, P3, S).
- `.gitattributes.flist-driver-snippet` — inactive by its own admission (F-2.5).
- `docs/`: 100 tracked files, 30 date-stamped handovers/overnight summaries; `docs/bug_registry.html` + `docs/build_registry.html` are **generated outputs tracked** (`gen_bug_registry_html.py:1-15`), and `docs/build_registry.html:616` embeds the board IPs.
- `.gitlab-ci.yml` (58 KB, 47 jobs incl. `sim-gate` `allow_failure: false`) for the abandoned forge; 16 `allow_failure: true` jobs.
- `pynq_host/throughput_gui/static/vendor/plotly.min.js` 4.5 MB — largest first-party blob.
- `imp/hw_gate/` 127 files / 4.2 MB tracked deliberately as the evidence tree (`.gitignore:88-103`) — keep, but it is where 4 of the 18 credential files live.
- Untracked-but-present junk in the primary worktree: `build_freeze_kr260-pair-{nptp,flip-nptp}.log` (448 KB each), `vivado*.jou/log` ×4, `.Xil/` — all covered by `.gitignore` (`*.log`, `vivado*.jou`, `/.Xil/`), so no risk; just delete.

### 7.2 `.gitignore` (300 lines)
Adequate for run directories (suffixed EDA globs added 08-14, `:233-300`), `site.env`, `fpga/site.local.mk`. Over-broad global rules cause real loss: `*.rep`, `*.log`, `*.xml`, `*.map`, `*.gz`, `*.done`, `*.err`, `*_log` (:14, :106-121). rev2/integration `5c5328ef`: "`.gitignore '*.rep'` had silently eaten [the LVS fixtures]". **F-7.2** Sev P2 · Conf H · Effort S: scope those to the flow dirs, add a `git check-ignore` test for every tracked fixture path.

### 7.3 Worktrees (18) and branches (35 local, 18 on origin)
Dirty worktrees (`git status --porcelain | wc -l`): `tidelink` (primary, `rescue/primary-worktree-2026-08-10`) **26**; `tidelink-consolidated` (`wip/fcsm-collision-consolidated-2026-08-17`) **4**; `td-bisect/baseline-5e8bdb5a` 3 (the `dut_src` churn, F-2.6). The other 15 are clean.

Branch classification vs `origin/main` (`git merge-base --is-ancestor`):
- **MERGED (28)** — safe to delete locally: `integ/tidelink-consolidated-2026-08-07`, `rescue/primary-worktree-2026-08-10` (but its *worktree* is 26-dirty — the uncommitted `syn/asic` site-hygiene edits listed in the session's git status; rev2/integration `25472d11` "carry in the uncommitted site.env path-hygiene state" suggests they were imported — verify before dropping), `rescue/tidelink-{fixe,throughput-overnight,wip-testrepoint,i1fix-confirm,link-survey-2026-08-01}-2026-08-10`, `docs/bug-registry-2026-08-07`, `integ/axirec-on-chiplet`, `feat/unit-regression-from-ethchiplet`, `wip/axirec-{f1-readonly-error,header-ecc-probe,test-repoint}`, `fix/axi-datanode-recovery`, `analysis/link-survey-2026-08-01`, `integ/freeze-2026-07-31`, `integ/z2-override-verify-2026-07-31`, `confirm/i1-fix-throughput-2026-07-31`, `integ/i1-fix-2026-07-31`, `test/i1-{fixe-training-release,selfarm-regression}`, `fix/tidelink-isolated-write-dataloss`, `fix/i1-selfarm-rolelock`, `experiment/throughput-overnight-2026-07-31`, `fix/z2-drop-park-hook`, `fix/v2-sync-clock-gate`, `fix/txgen-present-asic-tieoff`, `integ/gate-plan-2026-07-30`, `main` (local, at `18491efc` — **stale, 2026-07-29**), `worktree-agent-aa5e31fe26d736e36`, `feat/txgen-v1-integration`.
- **UNMERGED, on origin (2)**: `rev2/signoff-checkers` (+8/-227, superseded by rev2/integration merge `a3b69ef1`), `wip/fcsm-collision-consolidated-2026-08-17` (+1/-36, WIP, also `origin/wip/…`).
- **UNMERGED, LOCAL-ONLY tip (2)** — single-copy: `fix/tidechart-dualroot-timeout-tooling` (+1, 2026-09-02, worktree `td-bisect/tidechart-dualroot-2026-09-02/tidelink`, clean) and `worktree-agent-ac06dd75b70af4bbf` (+1/-242, 2026-07-29, unknown agent residue).
- Tags: **145 local = 145 on origin**, including all 16 `archive/i1/*` and 3 `archive/pad-clockgate/*` — the memory's "19 tags on neither remote" is **resolved**; `archive/i1/strategy-i1-rolelock` (the only ref keeping the `b98b944` retraction reachable) is now safe on origin.
- Remotes: `gitlab` 17 branches, abandoned (unchanged since 07-23); `ethclone` (path remote) still has 4 branches 2-4 commits ahead of `origin/main` (`fix/fifo-stale-probe-rename` +4, `integ/i1-fcsm-on-proven` +4, `integ/fix-on-selfarm` +3, `fix/i1-fcsm-bringup-ethchiplet` +2) — triage or tag before that clone is touched; `mainclone` = path into `deps/tidelink-phy` (delete the remote).

### 7.4 Cleanup plan (do NOT execute; ordered, each independent)
1. Rotate the board credential (F-5.1). Then merge `rev2/hygiene` into `rev2/integration` and `main` (it is 5 commits, all hygiene/provenance, no RTL except a 38-line `tidelink_top.sv` change in `38f362ee` to review).
2. Tag-and-delete: `git tag archive/2026-09/<branch> <sha>` for the 28 merged branches, then `git branch -D`; `git worktree remove` the 13 clean worktrees whose branch is merged (keep `td-bisect/baseline-*`, `tidechart-dualroot-*`, `tidelink-consolidated`, and the primary).
3. Push the two local-only tips (`fix/tidechart-dualroot-timeout-tooling`, `worktree-agent-ac06dd75b70af4bbf`) to origin under `archive/` or `wip/` before any gc.
4. Fetch-and-tag the 4 ethclone-ahead branches (`git fetch ethclone` already done; tag them `archive/ethclone/*`), then `git remote remove ethclone mainclone gitlab`.
5. Commit or discard the 26 dirty files in the primary worktree (they are the `syn/asic` site-hygiene edits; compare against `rev2/integration:25472d11`).
6. `git rm -r scratch_resolved .gitattributes.flist-driver-snippet` (after activating the real `.gitattributes`); move `BRINGUP_REPORT.md` → `docs/archive/`; stop tracking `docs/*.html` (generate in CI/RTD).
7. Delete the 9 orphan flists; regenerate `dut_src_*.f` with `${TIDELINK_HOME}`.
8. Reset local `main` to `origin/main` (it is 3 weeks stale and a footgun for `git checkout main`).

---

## 8. Docs & onboarding tooling

- `docs_site/` — 16 MyST pages + `conf.py`; `.readthedocs.yaml` builds it (htmlzip, `fail_on_warning: false`). `conf.py:19` `release = "v1 (branch fix/z2-drop-park-hook)"` — a merged-and-dead branch; stale since 08-10 (**F-8.1**, P3, S: derive from `git describe`).
- `scripts/gen_bug_registry_html.py` (71 KB) renders `docs/BUG_REGISTRY.yaml`/`BUILD_REGISTRY.yaml` → tracked HTML; `--check` mode exists but no CI calls it. `ci/generate_wiki.py` writes a GitLab wiki (abandoned forge); `ci/generate_dashboard.py` + `parse_ppa.py` (DC-only, F-3.9).
- **Register map — four hand-maintained descriptions:**
  1. RTL: `src/rtl/fifo/tidelink_apb_regs.sv` (851 lines) — hand-written `case` on `paddr` sub-fields (`3'h0…3'h7` per region, :275-277, :685-717, :807, :821). Not generated.
  2. RDL: `src/rdl/tidelink_regs.rdl` (28 regs, offsets `@ 0x000…0x11C`), `tidelink_perf_regs.rdl` (24), `wlink_regs.rdl` (19), `phc_regs.rdl` (20), `tidelink_ptp_regs.rdl` (3), `tidelink_addr_translator_regs.rdl` (5), `tidelink_unified_regs.rdl` (composes them at `0x0000/0x2000/0x4000`).
  3. `docs/REGISTER_MAP.md` (hand-written).
  4. `docs_site/register_map.md` (hand-written).
  `scripts/rdl2c.py` compiles the RDL (via `systemrdl-compiler`, with a preprocessor for the non-standard `->hw/->sw` syntax, :42-60) into `src/sw/*.generated.h` through `src/sw/Makefile:50-62`; the outputs are gitignored (`.gitignore:79`). Nothing generates SV from RDL, nothing checks RDL against SV, and the site itself records the disagreements: `docs_site/register_map.md:255-258` "the RDL (`tidelink_regs.rdl:437-470`) still documents `fcsm_state` at `[20:17]` … The instantiated RTL packs `[19:17]`. RTL wins."; `:191-192` `NEGO_PRIORITY` reset `0xFFFF` in RDL vs strap-derived in RTL. **Therefore the C headers generated from the RDL carry a wrong `fcsm_state` mask for the register that every bring-up script polls** (`0x2108 [19:17]` per memory). **F-8.2** Sev **P1** · Conf H · Effort M · rev2 NOT.
- Recommendation: make the RDL the single source — `peakrdl-regblock` (or the in-house `rdl2c.py` extended with an SV emitter) generates `tidelink_apb_regs.sv`'s decode/field logic, `rdl2c.py` the headers, and `peakrdl-html`/`-markdown` the two docs; add `make regmap-check` that regenerates and diffs, and a cocotb test that reads every RO-ID/reset value from RTL and compares to the RDL model (the `tidelink_apb_regs` env already exists). First step is cheap: fix the two documented divergences in the RDL and add the diff check so they cannot reopen.

---

## 9. Prioritised findings

| # | Finding | Sev | Conf | Effort | rev2 |
|---|---|---|---|---|---|
| F-5.1 | Board credential in public history since 07-31; 24 hits/18 files on `main` and on `rev2/integration`. **Rotate.** | P0 | H | S | hygiene FIXED fwd |
| F-3.2 | No ASIC build archived after the constraint fix; the fix commit says the design fails the correct constraints | P0 (tapeout) | H | L | NOT |
| F-2.1 | `cocotb make regression` cannot fail (summary recipe attached to `.PHONY` since `2ffc21a5`) | P1 | H | S | NOT |
| F-2.4 | Two 186-file tapeout/FPGA flists + ≥10 forks, hand-maintained; no generator | P1 | H | M | PARTIAL (divergence checker) |
| F-4.2 | `git_dirty` fail-open in the FPGA manifest | P1 | H | S | hygiene FIXED |
| F-4.3 | 195 MB generated vendor tree invisible to provenance | P1 | H | S | hygiene FIXED |
| F-4.9 | `verify_build.sh` exits 0 when it cannot verify | P1 | H | S | integration FIXED |
| F-3.4 | LVS verdict grades INCORRECT as CORRECT (`run_calibre_lvs.sh:128`) | P1 | H | S | integration FIXED |
| F-3.3 | DFT is a TODO scaffold; RX ÷16 phase unsigned-off | P1 | H | L | NOT |
| F-3.10 | OCV derates are placeholders | P1 | H | M | NOT |
| F-5.2 | 41 Makefiles carry the Arm drop code, 40 carry EDA install paths, 1 a real PDK path | P1 | H | M | NOT |
| F-8.2 | RDL wrong vs RTL (`fcsm_state`, `NEGO_PRIORITY`); generated C headers inherit it | P1 | H | M | NOT |
| F-1.1 | 4-way duplicated `sim_gate` suite table (1,712 lines) | P2 | H | M | NOT |
| F-1.2 / F-2.2 | `make -n` executes `$(MAKE)` pipelines and writes result files (cocotb confirmed) | P2 | H | S | NOT |
| F-2.5 | Flist semantic merge driver / `check` not activated anywhere | P2 | H | S | NOT |
| F-3.1 | RTL-Architect `read_design.tcl` copy still has blocker #2 | P2 | H | S | NOT |
| F-3.7 | `verify_fix_delivery.sh` never committed; absent from every branch | P2 | H | S | NOT |
| F-4.4 / F-4.5 | Manifest lacks `axi-chiplet-controller` pin and `.bin` hash; stale-`.bin` is WARN not FAIL | P2 | H | S | NOT |
| F-4.7 | `TIDELINK_PHY_V2` never reaches OOC synth; 3 dead `ifdef` blocks | P2 | M | S | NOT |
| F-4.8 | Lint ratchet baselines keyed on line numbers | P2 | H | S | hygiene FIXED |
| F-5.3 | No CI on GitHub at all; vendor/secrets guards only run on abandoned GitLab or by hand | P2 | H | S | NOT |
| F-6.1 | Same PHY repo vendored twice at branch-tip pins; `mainclone` path remote | P2 | H | M | NOT |
| F-7.2 | Global `*.rep/*.log/*.xml/*.map` ignores eat fixtures | P2 | H | S | integration FIXED (one case) |
| F-2.3, F-2.6, F-1.5, F-3.6, F-3.9, F-4.1, F-4.6, F-7.1, F-8.1 | Orphans, absolute `dut_src`, XILINX_PART ladder, V1 ECC bypass, DC-only PPA parse, no onchip fpgahub action, manifest lacks tool/ILA info, `scratch_resolved`, stale `release=` | P3 | H | S | NOT |

---

## 10. Next-iteration tooling architecture

1. **One design description → every file list.** `design/tidelink.core.yaml` (filesets × targets, §2.4) → generator commits `flists/*.flist`, `fpga/filelist` input, cocotb overlays; `make flists` regenerates, `make flists-check` (in pre-commit and CI) diffs with `flist_semantic.py diff`. The tapeout/FPGA delta becomes an explicit named fileset (`fcsm_recovery: overrides|deps`) reviewed as a 1-line change. Activate `.gitattributes` `*.flist merge=flist` on day one.
2. **One register description → RTL + headers + docs** (§8): RDL is the source; SV decode, C headers, MD/HTML pages generated; a `regmap-check` diff and a cocotb readback test close the loop.
3. **Table-driven gates.** Root `Makefile` `sim_gate` from a suite table; cocotb `regression` with exit codes not `.result` files; every recipe that recurses guarded against `-n` (or a policy of never using `$(MAKE)` inside shell `if`/pipes). Target: root Makefile <500 lines.
4. **Provenance that cannot say "clean" when it cannot tell.** Merge rev2/hygiene; extend the manifest with the Wlink pin, `.bin` sha256, XHB500 tree digest, Vivado version, define set, ILA flag; make `verify_build.sh` (f) and (i) hard FAILs; record the manifest **in the bitstream** (USR_ACCESS already carries the SHA — add a dirty bit).
5. **Site facts in one file, no defaults anywhere.** Finish what `affbda14` started: strip the 3 default lines from all 40 cocotb Makefiles, route `VERDI_HOME/SPYGLASS_HOME/XILINX_VIVADO` through `site.env`, add `make site-check` at the root that walks every Makefile for `/research/|/eda/|/apps/|/home/` and fails.
6. **CI on the forge that is actually public.** A GitHub Actions workflow with the licence-free tier only: `vendor-check` (vendor the scanner or make it a submodule), `check-secrets.sh --arm-only && check-secrets.sh`, `flists-check`, `regmap-check`, `xdc_lint`/`sv_anti_pattern` ratchets, Verilator lint of `tidelink_top.flist`, Sphinx build with `fail_on_warning`. Licensed tiers (`sim_gate`, FC) stay on a self-hosted runner but report status to the PR.
7. **Deps as tags.** One PHY submodule at a tag; `axi-chiplet-controller` at a tag (with `deps/xhb500/TREE.sha256` covering the generated bridge); README states the licence prerequisites and the licence-free path.
8. **ASIC flow.** Delete the `rtl-architect/` script copies; land rev2's LVS/DRC/verify_build fixes; archive one full FC run post-`9d1b2eaa` under `imp/ASIC/<date>/` with reports (timing red is information, not something to hide); replace placeholder derates; start the DFT programme as its own tracked item.

---

## 11. Parallelisable cleanup tasks (each independent; effort)

| Task | Effort | Owner-type |
|---|---|---|
| Rotate the board credential; merge `rev2/hygiene` (5 commits) into `rev2/integration` and `main` | S | HW lead / infra |
| Fix `cocotb/Makefile` (`regression` recipe, `-n` guard, exit codes) | S | any |
| Strip `CMSDK_DIR`/`VERDI_HOME`/`PHYS_IP_PATH`/`MEM_PATH` defaults from 41 cocotb+cdc Makefiles | S-M (mechanical, 41 files) | any |
| Activate `.gitattributes` flist driver; add `flist_semantic.py check` to `farm_gate_fast` | S | verif-infra |
| Write the flist generator + fileset YAML; regenerate and diff-check (§2.4) | M | verif-infra |
| Fix RDL `fcsm_state`/`NEGO_PRIORITY`; add `regmap-check`; evaluate `peakrdl-regblock` for `tidelink_apb_regs.sv` | M | RTL + docs |
| Manifest: add Wlink pin, `.bin` sha, XHB500 digest, tool version; `verify_build.sh` (f)/(i) → FAIL | S | fpga-infra |
| Table-drive `sim_gate` (root Makefile) | M | verif-infra |
| Delete `syn/asic/rtl-architect/{tidelink.FC.read_design.tcl,create_fusion_lib.tcl}` copies; source shared ones | S | asic |
| Recover/rewrite `verify_fix_delivery.sh`; commit under `syn/asic/scripts/` with its control test | S | asic |
| Land rev2 LVS/DRC/verify_build/msg_gate fixes on `main` (cherry-pick `9a7c02c7 8a91087b 59d4366f 48897cb0 74106f77`) | S | asic |
| Scope `.gitignore` globals (`*.rep *.log *.xml *.map *.gz`) to flow dirs; add check-ignore test for fixtures | S | any |
| Branch/worktree/remote cleanup per §7.4 (tag-then-delete) | S | repo owner |
| GitHub Actions licence-free tier (§10.6) | M | infra |
| `docs_site/conf.py` release from `git describe`; stop tracking `docs/*.html`; move `BRINGUP_REPORT.md`, delete `scratch_resolved/` | S | docs |
| Archive 10 `pynq-z2-pair-*` experiment targets to a tag; add `kr260-pair-onchip` fpgahub action | S | fpga |
| Retarget `ci/parse_ppa.py` at FC `reports*/` or delete with `generate_wiki.py` | S | ci |
| Remove the ~60 gitignored `cocotb/*/{.result,run.log}` files my dry-run created in `td-bisect/baseline-5e8bdb5a` | S | caller |


---

# PART 8 rev2 delta

# Review: the in-flight `rev2/*` iteration (origin/main `5e8bdb5a` -> `origin/rev2/integration` `cba9774d`)

Reviewer scope: what the rev2 branches implement, their quality, what is missing, land-readiness.
Method: read-only; `git -C` history queries against the primary repo and the off-repo clone
(`$WORKTREES/SoCLabs/nanosoc-ethernet-chiplet/.git/modules/tidelink`, which hosts every rev2 worktree);
on-disk artefacts inspected, none produced. No simulation, no board contact. Every claim below cites a file:line
or a sha; anything I could not check is marked **Unverified**.

Reference points
- baseline = `origin/main` `5e8bdb5a` (2026-08-20 20:59) at `$WORKTREES/SoCLabs/td-bisect/baseline-5e8bdb5a`
- candidate = `origin/rev2/integration` `cba9774d` (2026-09-02 11:15, dam1n19) at `$WORKTREES/SoCLabs/td-bisect/rev2-final`;
  59 commits ahead, 0 behind (`git rev-list --count` both directions).
- `origin/rev2/hygiene` `df0f1f24` (2026-08-24 22:52): 5 commits off `5e8bdb5a`, **not** an ancestor of integration.
- Local-only branches in the off-repo clone: `rev2/asic-fpga` `9ce95fe` (ancestor of integration), `rev2/sim-probe` `45f1ef5`
  (ancestor), `rev2/fix-exclusives` `35c75ae` (+1 unique), `rev2/ar-r-selfheal` `b1c9c9b` (+2 unique), `rev2/signoff-checkers`
  `5c5328e` (in the primary repo too; ancestor of integration).

---------------------------------------------------------------------------------------------------------------------

## 0. Headline findings (read these first)

1. **Only three RTL commits reach silicon-relevant files, and only two of them reach the ASIC flist.**
   `82c56e2` (TL-042 head-of-line write-age watchdog) and `c6f091a` (TL-044 dead-bridge containment) edit
   `src/rtl/tidelink_top.sv`, which is line 415 of `flists/tidelink_top_full_asic_v2.flist`. `e88ff7b` adds
   `src/rtl/local_overrides/WlinkGenericFCReplayV2_{7,9}.v`, but the ASIC v2 flist still lists
   `deps/.../WlinkGenericFCReplayV2_7.v` (:306) and `_9.v` (:308); only `flists/tidelink_fpga_v2.flist` was re-pointed
   (`bf813a7`). **The TL-043-ARR read-path CDC self-heal does not tape out on rev2/integration.**
2. **rev2/integration fails its own new gate.** `sim_gate_flist_divergence` (added by `e6bdb61`, target at `Makefile:1708`)
   reports `FLIST DIVERGENCE CHECK: FAIL` because `bf813a7` created two shadow pairs (`_7`, `_9`) "that nobody recorded a
   decision for" (`$WORKTREES/SoCLabs/td-bisect/rev2-excl/imp/sim_gate/flist_divergence.log`). The last merge (`cba9774`)
   was never re-gated against the branch's own checker.
3. **No RTL fix on rev2 has any hardware validation artefact.** BUG_REGISTRY on integration says exactly that for TL-042
   ("SIM-PROVEN ON BRANCH rev2/tl042-backstop. NOT hw-tested. NOT on main."); TL-044, TL-043-ARR and TL-045 have **no registry
   entry at all** on integration (`grep -c TL-04[345] docs/BUG_REGISTRY.yaml` = 0 on main, integration and hygiene). The only
   on-board work in the period is harness repair (`pynq_host/evidence/harness_repair_2026-08-25/`, 9 JSON files) and the
   TideChart election campaign (`td-bisect/election-2026-08-26/`, `dualroot-hwval-2026-09-09/`), neither of which exercises
   the rev2 RTL.
4. **The only complete sim_gate run on the candidate content is at `cba9774d-dirty`** (rev2-excl worktree, 2026-09-02 12:38-14:14):
   75 suites, 69 PASS / 3 FAIL / 3 XFAIL. The dirty content was the then-uncommitted TL-045 change (its `xdie_exclusive_redproof`
   suite ran at 14:14:51; `35c75ae` was committed 14:15:20), so that run is evidence for **cba9774d + TL-045**, not for pristine
   `cba9774d`. The rev2-final worktree's `imp/sim_gate/*.status` files are all stamped **today 17:27-17:30**, 3-5 s each, FAIL,
   with `Source file "${CMSDK_FPGA_SRAM_V}" cannot be opened` in every log: the documented no-`source ./set_env.sh` env trap
   (a concurrent reviewer's run), **not a verdict on the RTL**.
5. **A false-green the branch claims to have fixed is still live.** `736607c` "kr260_sysval T6_endurance recorded PASS without
   reading its check" is in the log, but the merge `77db1c5` took the harness-repair version instead:
   `pynq_host/scripts/kr260_sysval.py:463-465` still calls `board(B, "verify ...")`, discards the result and records PASS.
   `docs/MERGE_RECONCILIATION_TODO.md` documents this honestly; the control `test_kr260_sysval_t6.py` was deleted.
6. **The five sign-off checker controls are wired into nothing.** `ci/checker_controls/run_all.sh` is referenced by no Makefile
   target and no CI job (`grep checker_controls Makefile .gitlab-ci.yml` = 0 hits); `make selfcheck_gates` (`Makefile:2236`) runs
   only `scripts/ci/tests/test_*.py`. Given Tier 0 of the register ("gated by whoever remembers to run it"), this is the same
   pattern the branch set out to eliminate.
7. **rev2/hygiene conflicts with rev2/integration in two files** (`git merge-tree --write-tree`): `fpga/farm_gate.sh`
   (`57b6700` content-keyed ratchets vs `74106f7` crashed-lint) and `src/rtl/tidelink_top.sv` (`38f362e` comment-only bit[10]
   re-documentation vs the obs-word rewrite for bits [12:14]). The board password removed on hygiene (`6063710`) is still present
   on integration: **24 occurrences in 18 files** on both `origin/main` and `origin/rev2/integration`, 0 on hygiene, first
   introduced `a04a194b` 2026-07-31, 11 commits touch it. (Counted with `git grep -c`; the string is not reproduced here.)
8. The new 0x21F8 obs bits [12] `sub_wr_hol_stuck_sticky`, [13] `xhb_dead_r`, [14] `xhb_dead_perm_r` are a **silicon/APB contract
   change** with **no host decoder updated** (`grep -rl 'sub_wr_hol\|xhb_dead' pynq_host` = 0).

---------------------------------------------------------------------------------------------------------------------

## 1. Commit map

### 1a. `origin/main..origin/rev2/integration` (59 commits, oldest first)

ASIC reach = commit modifies a file listed in `flists/tidelink_top_full_asic_v2.flist` (or `tidelink_asic.flist`).
Only `82c56e2` and `c6f091a` do. Categories: RTL-fix, RTL-feature, checker-fix, coverage, ASIC-sim, tooling, docs, hygiene, merge.

| sha | date | subject (abridged) | category | files touched | ASIC/FPGA |
|---|---|---|---|---|---|
| 0688c7b | 08-23 | test(TL-043-ARR): reproduce a2l CDC self-latch on shipping read nodes | coverage | 9: `cocotb/tidelink_a2l_replay_cdc/{Makefile,tb_top_7.sv,tb_top_9.sv,test_a2l_replay_cdc_{7,9}.py,dut_src_{7,9}.f}`, `flists/tidelink_a2l_replay_cdc_{7,9}.flist` | test only |
| e88ff7b | 08-23 | fix(TL-043-ARR): TL-027/TL-032 CDC self-heal overrides for AR(_7) and R(_9) | **RTL-fix** | 4: `src/rtl/local_overrides/WlinkGenericFCReplayV2_{7,9}.v` (+226 each), `cocotb/tidelink_a2l_replay_cdc/tl027only_*_{7,9}.v` | **FPGA only** (ASIC flist :306/:308 still `deps/`) |
| b0ae7a8 | 08-24 | test(TL-027): CDC-tearing regression for w_inc continuous resend | coverage | 2: `Makefile`, `cocotb/tidelink_a2l_replay_cdc/test_a2l_wready_tear.py` | test only |
| 82c56e2 | 08-23 | fix(TL-042): head-of-line WRITE-age watchdog | **RTL-fix** | 5: `src/rtl/tidelink_top.sv`, `Makefile`, `cocotb/tidelink_axi_datanode_recovery/{Makefile,test_tl044_hol_write_age.py}`, `docs/BUG_REGISTRY.yaml` | **ASIC + FPGA** |
| c6f091a | 08-24 | fix(TL-044): contain the ahb_sub READ DEAD GATE | **RTL-fix** | 5: `src/rtl/tidelink_top.sv`, `Makefile`, `cocotb/tidelink_axi_datanode_recovery/{Makefile,test_tl044_read_deadgate.py}`, `docs/BUG_REGISTRY.yaml` | **ASIC + FPGA** |
| 7aaaf1a | 08-24 | fix(sim_gate): WIRE orphaned sim_gate_tl044_hol_write_age | checker-fix | 1: `Makefile` | - |
| 5994cce | 08-24 | fix(sim_gate): wire a2l_replay_cdc _7/_9 into the gate | checker-fix | 1: `Makefile` | - |
| ea1c3e4 | 08-24 | test(burst): bench for the XHB500 NON-SINGLES arm | coverage | 1: `cocotb/tidelink_top_pair_v2/test_v2_burst_encodings.py` (770 lines) | test only, **not gated** |
| 575e352 | 08-25 | fix(sysval): classify ssh transport failures | checker-fix/tooling | 1: `pynq_host/scripts/kr260_sysval.py` | host |
| a50a7b3 | 08-25 | test(sysval): reproducer + on-HW proof harness discriminates | tooling + HW evidence | 10: `pynq_host/evidence/harness_repair_2026-08-25/*` (9), `pynq_host/scripts/*` | host |
| 72ee8b6 | 08-25 | fix(sysval): `sudo -S -p ''` | tooling | 1: `pynq_host/scripts/kr260_sysval.py` | host |
| 2974d51 | 08-26 | docs: merged false-green register | docs | 1: `docs/FALSE_GREEN_REGISTER.md` | - |
| 9a6d08e | 08-26 | feat(coverage): durable fail-closed coverage repository | coverage | 13: `.gitlab-ci.yml`, `Makefile`, `docs/coverage/`, `docs/plans/COVERAGE_REPOSITORY_2026-08-26.md`, `scripts/coverage/*` | - |
| bfa3c8d | 08-26 | feat(coverage): first merged coverage DB over the WHOLE sim_gate | coverage | 68: `cocotb/coverage.mk`, ~60 `cocotb/*/Makefile`, `uvm/tidelink_top_system`, `docs/SIM_GATE_COVERAGE.md`, `scripts/ci` | - |
| 25472d1 | 08-26 | baseline(worktree-import): site.env path-hygiene state | hygiene | 2: `syn/asic/calibre/scripts/run_calibre_lvs.sh`, `syn/asic/fusion-compiler/Makefile` | flow |
| 9a7c02c | 08-26 | fix(signoff): LVS graded INCORRECT as CORRECT | checker-fix | 4: `syn/asic/calibre/scripts/{run_calibre_lvs.sh,lvs_verdict.sh}`, `ci/checker_controls/control_lvs.sh`, `ci/fixtures/*` | flow |
| 8a91087 | 08-26 | fix(signoff): fc_drc able to fail; absent reports not scored 0 | checker-fix | 2: `syn/asic/fusion-compiler/scripts/7_drc.tcl` (+202/-38), `ci/checker_controls/control_fc_drc.sh` | flow |
| 1d0b56f | 08-26 | feat(sim): behavioural cocotb benches against the ASIC file set | ASIC-sim | 2: `cocotb/tidelink_top_pair_v2/*` | - |
| d5fdb49 | 08-26 | feat(coverage): first merged coverage DB ... (**same subject as bfa3c8d, different patch-id** a33cfa5f vs 83b2b9e7; re-applied on another sub-branch) | coverage | 68 (same set) | - |
| 74106f7 | 08-26 | fix(signoff): CRASHED lint no longer ratchets as "no new findings" | checker-fix | 3: `fpga/farm_gate.sh`, `fpga/lint_ratchet.sh`, `ci/checker_controls/control_farm_gate_ratchet.sh` | FPGA flow |
| 8cb7b70 | 08-26 | docs: Tier 0 — nothing gated by CI on either forge | docs | 1: `docs/FALSE_GREEN_REGISTER.md` | - |
| 24cb2cb | 08-26 | fix(uvm): tidelink + integration scoreboards fail on packet loss | checker-fix | 8: `uvm/tidelink/{env/tidelink_scoreboard.sv,tests/tidelink_scoreboard_loss_selftest.sv,Makefile,env/tidelink_pkg.sv}`, same 4 under `uvm/tidelink_integration/` | - |
| 48897cb | 08-26 | fix(signoff): Vivado message gate could install nothing | checker-fix | 3: `fpga/scripts/msg_gate_child_{promote,check}.tcl`, `ci/checker_controls/control_msg_gate.sh` | FPGA flow |
| e6bdb61 | 08-26 | test(asic-sim): FCSM recovery divergence + flist divergence checker | ASIC-sim + checker | 5: `cocotb/tidelink_fcsm_silicon_ratio/*`, `cocotb/tidelink_top_pair_v2/*`, `scripts/ci/flist_divergence.py` | - |
| 59d4366 | 08-26 | fix(signoff): verify_build exited 0 on unverifiable build | checker-fix | 2: `fpga/scripts/verify_build.sh`, `ci/checker_controls/control_verify_build.sh` | FPGA flow |
| f95c372 | 08-26 | test(signoff): single runner for all five checker controls | checker | 1: `ci/checker_controls/run_all.sh` | - (unwired) |
| 5c5328e | 08-26 | fix(signoff): track LVS fixtures (`*.rep` gitignored) | hygiene | 6: `.gitignore`, `ci/checker_controls/*`, `ci/fixtures/*` | - |
| e31edbc | 08-26 | fix(asic-sim): L7 control decisive; wire ASIC suites into sim_gate | ASIC-sim/checker | 2: `Makefile`, `cocotb/tidelink_top_pair_v2/*` | - |
| 2c0783d | 08-26 | fix(uvm): revive unmatched-TX backstops that read deleted queues | checker-fix | 7: `uvm/tidelink_system/env/*_scoreboard.sv`, `uvm/tidelink_top_system/{env/*_scoreboard.sv,Makefile,selftest/*}` (3), `.gitignore` | - |
| abe7fca | 08-26 | fix(sim_gate): score the 2 suites run but never read; guard the pair | checker-fix | 3: `Makefile`, `scripts/ci/sim_gate_integrity.py`, `scripts/ci/tests/test_sim_gate_integrity.py` | - |
| 107b0dc | 08-26 | fix(ci): registry_coverage must not score "could not check" as covered | checker-fix | 2: `scripts/ci/registry_coverage.py`, `scripts/ci/tests/test_registry_coverage.py` | - |
| 634e60a | 08-26 | feat(asic-sim): simulate ASIC SRAM against REAL rf_16k macro | ASIC-sim | 2: `cocotb/tidelink_fcsm_silicon_ratio/*`, `cocotb/tidelink_top_pair_v2/*` | - |
| 0bad1d2 | 08-26 | fix(cocotb): lane-mask oracle self-test could not go red | checker-fix | 3: `cocotb/tidelink_top_pair_v2/*`, `scripts/ci/tests/test_lane_mask_oracle.py` | - |
| c5141c3 | 08-26 | fix(cocotb): test_v2_onchip_pair 5 PASS at 0 ns -> SKIP | checker-fix | 2: `cocotb/tidelink_top_pair_v2/*` | - |
| c5bc7ef | 08-26 | test(xhb500): unit bench for INBOUND AXI->AHB bridge + both error paths | coverage | 5: `Makefile`, `cocotb/xhb500_bridge/*`, `flists/xhb500_bridge_unit.flist` | test only (gated: `xhb500_bridge`) |
| 9788d2c | 08-26 | fix(pynq_host): two board tests always exited 0 | checker-fix | 4: `pynq_host/{hosttest_verdict.py,test_loopback_pair.py,test_single_instance.py}`, `scripts/ci/tests/test_hosttest_verdict.py` | host |
| deaed7e | 08-26 | fix(pynq_host): health_snapshot exited 0 when it could not evaluate | checker-fix | 2: `pynq_host/scripts/health_snapshot.py`, `scripts/ci/tests/test_health_snapshot.py` | host |
| 736607c | 08-26 | fix(pynq_host): kr260_sysval T6 recorded PASS without reading its check | checker-fix (**superseded at merge 77db1c5; defect still live**) | 2: `pynq_host/scripts/kr260_sysval.py`, `scripts/ci/tests/test_kr260_sysval_t6.py` (later deleted) | host |
| 423e41d | 08-26 | test(addr-xlat): assert APB slave-mux error response; gate the bench | coverage | 2: `Makefile`, `cocotb/tidelink_addr_translator/*` | test only |
| 17cd21b | 08-26 | fix(cocotb): Wlink sniffer probe had 0 asserts | checker-fix | 2: `Makefile`, `cocotb/tidelink_top_pair_v2/*` | - |
| bcf20a6 | 08-26 | test(fifo): sub-word AHB access at cmsdk_ahb_to_sram byte-lane decoder | coverage | 1: `cocotb/tidelink_fifo/*` | test only |
| d7a928c | 08-26 | fix(coverage): fail loud when urg silently discards merged DBs | checker-fix | 2: `Makefile`, `scripts/ci/coverage_merge_integrity.py` | - |
| 066e818 | 08-26 | measure(asic-sim): tapeout file set now has coverage 16.0% -> 2.7% unmeasured | docs (message-only, **0 files**) | 0 | - |
| d96199e | 08-26 | test(wlink): exercise TX power-state idle timeout | coverage | 4: `Makefile`, `cocotb/wlink_tx_pstate/*` | test only (gated: `wlink_tx_pstate`) |
| b88ebd4 | 09-01 | Merge rev2/diag-sweep | merge | 0 | - |
| 3dea54b | 09-01 | Merge rev2/coverage-infra | merge | 1 (`Makefile` conflict resolution) | - |
| 3bf7e46 | 09-01 | Merge rev2/harness-repair | merge | 0 | - |
| 311159a | 09-01 | Merge rev2/burst-measure | merge | 0 | - |
| 056f20a | 09-01 | Merge rev2/fix-falsegreen | merge | 4 (`Makefile`, `cocotb/tidelink_top_pair_v2`, `pynq_host/scripts`, `uvm/tidelink_top_system` resolutions) | - |
| 4fb428f | 09-01 | Merge rev2/cover-datapath | merge | 1 (`Makefile`) | - |
| 77db1c5 | 09-01 | merge: consolidate rev-2 work onto one integration branch | merge + docs | 4: `Makefile`, `docs/MERGE_RECONCILIATION_TODO.md`, `pynq_host/scripts/*`, `scripts/ci/*` | host |
| a3b69ef | 09-01 | Merge rev2/signoff-checkers | merge | 2 (`.gitignore`, `syn/asic`) | - |
| bf813a7 | 09-01 | build(fpga): point _7/_9 at hardened overrides — NETLIST-AFFECTING | tooling/flist | 1: `flists/tidelink_fpga_v2.flist` (:304,:306 deps -> local_overrides) | **FPGA only**; creates the 2 unrecorded shadow pairs that fail `flist_divergence` |
| 526e0ab | 09-01 | build(fpga): TD_ASIC_FILESET=1 image from the TAPEOUT file set | tooling | 3: `fpga/asic_fileset/rf_16k_fpga.v`, `fpga/filelist.tcl`, `fpga/scripts/build_provenance.tcl` | FPGA build of ASIC sources |
| 9a71317 | 09-01 | test(hw): prepared-but-unrun probe for AXI FC-node state-7 recovery | tooling/HW-test | 5: `fpga/hw_regression/{asic_l7_board_agent.py,asic_l7_starvation_hwtest.py,test_asic_l7_offline.py}`, `fpga/asic_fileset/*`, `fpga/scripts/*` | host |
| 45f1ef5 | 09-01 | test(sim): settle TL-044's park recipe + cross-die exclusive hazard | coverage | 5: `Makefile`, `cocotb/tidelink_axi_datanode_recovery/{Makefile,test_tl044_park_recipe.py,test_xdie_exclusive.py}`, `cocotb/xhb500_bridge/*` | test only |
| a585a2f | 09-01 | verify(asic-fpga): netlist census — recovery flops ABSENT from AXI FC nodes | tooling | 3: `fpga/scripts/{verify_asic_fileset_image.sh,asic_fileset_netlist_census.tcl}`, `fpga/asic_fileset/*` | FPGA |
| 9ce95fe | 09-01 | docs(asic-fpga): record the built image (sha256, timing, why manifest says dirty) | docs | 1: `fpga/asic_fileset/README.md` (297 lines) | - |
| cba9774 | 09-02 | Merge rev2/asic-fpga | merge | 0 | - |

Totals: 3 RTL-fix commits (4 RTL files, +950/-7 lines in `src/rtl`), ~16 checker-fix commits, ~12 coverage/test commits,
5 ASIC-sim commits, ~8 tooling/build, 4 docs, 2 hygiene, 9 merges.

### 1b. `origin/rev2/hygiene` (5 commits off `5e8bdb5a`)

| sha | date | subject | category | files | reach |
|---|---|---|---|---|---|
| 38f362e | 08-24 | docs(TL-009): 0x21F8 bit[10] is hazard-list PRESSURE, not a deadlock witness | docs (RTL comment only) | `src/rtl/tidelink_top.sv` (comment block at :1846-1885), `docs/BUG_REGISTRY.yaml`, 3 handover docs | comment; **conflicts** with integration's obs-word rewrite |
| 57b6700 | 08-24 | gate(farm): key the lint ratchets on CONTENT, not line numbers | checker-fix | `cocotb/lint/{sv_anti_pattern_lint,xdc_lint}.py`, `fpga/farm_gate.sh`, `fpga/farm_gate_{sv,xdc}_baseline.txt`, `docs_site/verification.md` | **conflicts** with `74106f7` |
| 6a174a3 | 08-24 | build(xhb500): pin the gitignored vendor tree by content digest | hygiene/tooling | `deps/xhb500/TREE.sha256` (new), `scripts/xhb500_tree_digest.sh` (new), `Makefile`, `.gitlab-ci.yml`, `docs/BUILD_REGISTRY.yaml`, `fpga/scripts/build_provenance.tcl` | - |
| 6063710 | 08-24 | security: remove the hardcoded board password; secrets guard; inventory residual | hygiene/security | 24 files (18 with the credential + `scripts/ci/check-secrets.sh` new, `Makefile:1983` wires it, `.gitlab-ci.yml:275`) | - |
| df0f1f2 | 08-24 | fix(provenance): fail CLOSED — "could not tell" was recorded as CLEAN | checker-fix | `fpga/scripts/build_provenance.tcl` | FPGA flow |

### 1c. Unique commits on the other rev2 branches (`git log rev2/integration..<branch>`)

| branch | unique | note |
|---|---|---|
| `rev2/asic-fpga` `9ce95fe` | 0 | fully folded (`cba9774` merged it) |
| `rev2/sim-probe` `45f1ef5` | 0 | fully folded |
| `rev2/fix-exclusives` `35c75ae` (09-02 14:15) | 1: `fix(TL-045): refuse cross-die exclusives instead of silently executing them` — 33 files, +1602/-257; RTL: `src/rtl/tidelink_top.sv` (+237: new `ahb_sub_hexcl`/`ahb_sub_hexokay` pins, `excl_refuse`, `excl_err{1,2}_r`, obs bits [15],[16]), `src/rtl/asic/tidelink_dft_wrapper.sv` (+17), `fpga/vivado_ip/tidelink_vivado_wrapper.v` (+10); 21 tb_top.sv port updates; `scripts/ci/check_excl_port_wired.py` + control; `docs/BUG_REGISTRY.yaml` (+112). **Not on integration.** |
| `rev2/ar-r-selfheal` `b1c9c9b` | 2: `b1c9c9b` (patch-id identical to integration's `0688c7b4` — already folded by re-commit) and `5c31619` docs(registry): "TL-027 was INVERTED — close it, open TL-043-ARR" (+84 lines `docs/BUG_REGISTRY.yaml`) — **NOT on integration**, which is why TL-043-ARR has no registry entry there |
| `rev2/signoff-checkers` `5c5328e` | 0 | folded via `a3b69ef` |

Sub-branches referenced only by merge commits (diag-sweep, coverage-infra, harness-repair, burst-measure, fix-falsegreen,
cover-datapath) no longer exist as refs; their content is in integration.

---------------------------------------------------------------------------------------------------------------------

## 2. RTL changes review (`git diff 5e8bdb5a..cba9774d -- src/rtl`)

Stat: `src/rtl/local_overrides/WlinkGenericFCReplayV2_7.v` +226 (new), `..._9.v` +226 (new), `src/rtl/tidelink_top.sv` +505/-7.

### 2.1 TL-043-ARR: `WlinkGenericFCReplayV2_7.v` (AR, 4-bit ptr/depth-8) and `_9.v` (R, 6-bit ptr/depth-32) — `e88ff7b`

What it does: ports the TL-027 three-part a2l ACK-pointer fix (window guard `a2l_ack_valid`, continuous `w_inc = 1'b1`,
gated latch) plus the TL-032 revert-aware rewind (`a2l_link_addr <= link_revert_addr` on `link_revert`, priority over ACK)
from the already-landed `_1/_3/_5` overrides to the two read-path nodes that previously shipped raw from `deps/`.
Node-specific instances preserved (`WavFIFO_11`/`wlink_wlink_axi_arFC_a2l_101x8`/`WlinkGenericFCReplayAddrSync` for `_7`;
`WavFIFO_14`/`_47x32`/`AddrSync_3` for `_9`) — checked against the header comments and the instantiations in the diff.

Review
- Reset/CDC: `a2l_link_addr` is in the link clock domain with async `link_reset`, identical to the `_1/_3` pattern;
  the app-side consumer reads it through the existing `WlinkGenericFCReplayAddrSync` mailbox (multibit sync). No new CDC
  crossing is introduced; `w_inc=1` only changes the resend policy of an existing crossing. Correct by construction
  relative to the sibling overrides that have been on the FPGA AW/W/B path since 2026-08-08.
- Window bounds (`4'h8`, `6'h20`) match the FIFO depths. `link_revert`/`a2l_ack_valid` mutual exclusion argument
  (same 3-bit tag decode) is inherited from `_1/_3` and not re-verified here.
- Safety: none of this touches `tidelink_top.sv`; no interaction with the backstops.
- **Reach: FPGA only.** `flists/tidelink_top_full_asic_v2.flist:306,308` still name `deps/...` for `_7/_9`. The branch's own
  `fpga/asic_fileset/README.md` and the `flist_divergence` FAIL both record this. So the "shipping read path" gap this
  commit was written to close remains open for tapeout unless the ASIC flist is re-pointed **and** that decision is recorded
  in `scripts/ci/flist_divergence.py`'s allow-list.
- Hygiene wart: `cocotb/tidelink_a2l_replay_cdc/dut_src_7.f` and `dut_src_9.f` are committed containing an absolute path into a
  personal worktree (`$WORKTREES/SoCLabs/td-bisect/tl-siteenv-2026-08-19/deps/...`). They are regenerated by
  `cocotb/tidelink_a2l_replay_cdc/Makefile:85` on every run (which is why every worktree shows them `M`), so they are harmless
  to results but should not be tracked.

Tests
- `cocotb/tidelink_a2l_replay_cdc/test_a2l_replay_cdc_7.py::test_ar_node_predata_ack_lap_ahead` and
  `::test_ar_node_revert_recovery_ack_accepted` (same pair in `_9.py`); gate targets `sim_gate_a2l_replay_cdc_7/_9`
  (`Makefile:621-629`), in `SIM_GATE_ALL_SUITES` since `5994cce`. Pass 2/2 in the rev2-excl run.
- Negative control: reproduce-first is available (`USE_DEPS_DUT=1`, Makefile:63) but **manual only** — the gate runs the
  override side only. The `_7.py` docstring (:5) still says "THIS TEST IS EXPECTED TO FAIL TODAY", stale since `e88ff7b`.
- The `w_inc` half is covered separately by `test_a2l_wready_tear.py::test_wready_low_ack_must_self_heal` with three
  anti-vacuity guards A1/A2/A3 (:305-325), swept over nodes 1,3,5,7,9 by `sim_gate_a2l_wready_tear` (`Makefile:668`). PASS 37 s
  in the rev2-excl run. This is a genuinely discriminating bench.
- Hardware: **none** for `_7/_9` (no artefact anywhere; no bitstream on any board carried them — the ASIC-fileset image
  deliberately did not, and the election/dual-root campaigns used pins `5e8bdb5a`-era images).

### 2.2 TL-042 instance 1: head-of-line write-age watchdog — `82c56e2` (`tidelink_top.sv` ~:1955-2128 on rev2)

What it fixes: the two aggregate timers (`sub_stall_ctr_r`, `sub_osr_ctr_r`) are re-zeroed by *any* progress
(`sub_axi_progress = sub_r_done | sub_b_done`, :1707), so a stuck write on a port with mixed traffic never expires
(silicon: 0x21F8 = 0xB5000498, bit[8] `sub_wr_stuck_sticky` = 0, bit[10] = 1). Fix: 4-bit issue/retire sequence numbers name
the oldest outstanding write; `sub_wr_hol_age_r` is re-zeroed only by `sub_b_done` or write-idle; at 2^17 hclk a bounded drain
injects one OKAY B per write outstanding at expiry (`sub_wr_hol_drain_tgt_r` snapshot), as an additional OR term on
`s_axi_bvalid/bresp/bid` (:2363-2389).

Review (correctness/safety)
- Registers only, `hclk`/`hresetn` like the surrounding block; no read of `ahb_sub_hready`; feeds only the same three nets the
  existing synth-B already drives. The cb33c9f no-comb-loop invariant holds by inspection.
- `sub_b_done = s_axi_bvalid & s_axi_bready` (:1705) includes synthetic beats, which is what lets the drain advance its own
  retire pointer; the retire pointer is guarded (`sub_b_done && sub_wr_hol_valid`) so a late real B cannot overtake issue
  (the commit records measuring 15 spurious beats before that guard — a real bug caught by
  `test_tl044_escape_is_clean_and_normal_path_survives`).
- Ordering: 2^17 is one binade above the 2^16 timers, so it cannot pre-empt an existing backstop. Sim runs use 2^13/2^14
  via `+define+` to preserve the ordering.
- Concern 1 (policy, disclosed): fabricates OKAY for a write that may not have landed. Same policy as synth-B, justified by the
  ILA-proven SLVERR retry-loop. Visible only via new obs bit[12].
- Concern 2 (not disclosed): after a drain, XHB500 has received more B beats than it issued AWs if the real B later arrives;
  the late B is bid-corrected to `sub_wr_awid_r` and enters a hazard list that has already freed that entry. The
  escape/normal-path test passes, but the XHB500-side effect of a stray B (write counter underflow?) is not analysed in the
  commit message. This pre-exists with synth-B; TL-042 multiplies the number of fabricated beats (up to 4 per expiry).
- Concern 3 (not disclosed): a legitimately slow write (>2^17 hclk, e.g. across a link recalibration/retrain in data mode)
  will be drained. At 25 MHz that is 5.2 ms; at the ASIC's 100 MHz, 1.3 ms. Whether any in-service retrain exceeds that on the
  real vehicle is not measured.
- Concern 4: obs word 0x21F8 bit[12] was claimed by both TL-042 and TL-044; resolved by landing order (comment at :2145-2152).
  Bits [12:14] are a silicon/APB contract change; no host decoder updated.

Tests
- `cocotb/tidelink_axi_datanode_recovery/test_tl044_hol_write_age.py` (4 tests: control aggregate-fires-without-traffic,
  starvation-defeats-aggregate, escape-clean-and-normal-path-survives, healthy-traffic-never-trips); gate target
  `sim_gate_tl044_hol_write_age` (`Makefile:940`), in `SIM_GATE_ALL_SUITES` since `7aaaf1a`. PASS 154 s in the rev2-excl run.
- Discrimination: the primary test asserts `osr_expiries == 0 and stall_expiries == 0` (starvation real) **and**
  `(hol_b_rises > 0 or synthb_rises > 0)` (:59 of the test body). The disjunction is loose on its face but the first assertion
  makes `synthb_rises` unreachable, so it does discriminate.
- Negative control: `tl044_hol_prefix` (`+define+TIDELINK_DISABLE_SUB_WR_HOL`, cocotb Makefile:229-236) exists and is
  documented as "the PRIMARY test must FAIL here" — **but it is not invoked by the gate** (only `tl044_hol` is). No recorded
  run of the prefix arm found on disk.
- Hardware: **none**. BUG_REGISTRY: "SIM-PROVEN ON BRANCH rev2/tl042-backstop. NOT hw-tested. NOT on main."

### 2.3 TL-044: XHB500 dead-bridge containment — `c6f091a` (`tidelink_top.sv` :1576-1631 params, :1710-1737 taps, :1771-1800 abort, :2392-2405 mux, :2430-2605 block)

What it fixes: after the read backstop errors a stuck read, XHB500's `read_counter` stays non-zero, `xhb_sub_hreadyout_raw`
stays 0 forever (measured 0/8093 cycles), and the `ahb_sub_hreadyout` mux's terminal fallback drives HREADYOUT low **while
idle** — an AHB-Lite violation that hangs the whole bus. Fix: `xhb_dead_r` sticky, armed by `sub_err1_r` then 2^12 consecutive
cycles of raw-low AND no s_axi progress; while dead, a waiting master gets an own 2-cycle ERROR (`dg_err{1,2}_r`), an idle bus is
released (`dg_act_ready = xhb_dead_r & ~sub_mst_dphase_r`), stranded pipe entries are cleared (`dg_act_abort`); recovery needs
2^12 consecutive raw-high cycles; after `XHB_DEAD_RELAPSE_MAX`=2 clear/re-arm cycles `xhb_dead_perm_r` latches until `hresetn`.

Review (correctness/safety)
- The detection/action split with `TIDELINK_XHB_DEAD_NO_ACTION` is the best-constructed control in the whole branch:
  positive arm (detection still latches) **and** negative arm (GREEN test must FAIL with action disabled), both in the gate
  (`tl044_mutant`, cocotb Makefile:407-421).
- No comb loop: taps are registers or `s_axi_*`/`xhb_sub_hreadyout_raw`; `ahb_sub_hready` is not read. Verified by reading
  the mux at :2392-2405.
- `dg_act_ready` is qualified by `~sub_mst_dphase_r`, so it cannot complete a master's transfer with OKAY — the invariant
  the comments rest on; `sub_mst_dphase_r` is set on `ext_is_nonseq && !pipe_valid_r` and cleared on `ahb_sub_hreadyout`
  (:2425-2427), so the abort arm's clearing of `pipe_valid_r` keeps re-arm reachable. Consistent.
- `dg_act_err{1,2}` and `dg_act_ready` outrank `wr_hold_r` — the one priority change to an existing protection; the argument
  (a dead bridge never samples HWDATA) is sound, and `test_tl044_false_fire_guard_zero_arms` asserts bit-identity when disengaged.
- Arming path for the write-wedge case: `sub_err1_r` fires only for reads (:1836, :1936) or the TL-037 terminal timeout with
  `sub_wr_os_ctr == 0` (:1887-1889). So a hazard-list write wedge does not arm containment directly; the chain is
  HOL drain retires writes -> `wr_os_ctr`=0 -> next transfer waits -> terminal timeout -> `sub_err1_r` -> 4096 cycles no progress
  -> `xhb_dead_r`. Two more relapses and the port is permanently error-only until reset. That is bounded and legal, but it is
  a new end state for the silicon wedge that nobody has observed on hardware; the relapse counter never decays.
- Minor: comment says `dg_axi_progress` uses "XHB500's OWN B valid" for `s_axi_bvalid_ctrl`; in this bridge B is an input to
  XHB500, so `_ctrl` is the FC-node (link-side) B before the synthetic OR. The intent (exclude synthetic beats) is right.
- Permanent latch is reset-only; on ASIC that is a SoC-level reset. Policy call, documented.

Tests
- `test_tl044_read_deadgate.py` (RED/GREEN/MUTANT/SAFETY/INTERMITTENT/FALSE-FIRE, 6 tests) via `sim_gate_tl044_read_deadgate`
  (`Makefile:1030`), plus `test_tl044_park_recipe.py` (5 tests, real parks: far-terminus stall, R lost in link; NEVER/RECOVERED/
  INTERMITTENT exits with no Force) via `sim_gate_tl044_park_recipe` (`Makefile:1054`). Both PASS in the rev2-excl run
  (203 s / 124 s). These are discriminating tests with a killed mutant.
- Hardware: **none**. The "prepared-but-unrun" `fpga/hw_regression/asic_l7_starvation_hwtest.py` (`9a71317`) targets FCSM
  state-7 on the ASIC-fileset image, not TL-044; its docstring says its likely honest outcome is COULD-NOT-EVALUATE.

### 2.4 TL-045 cross-die exclusives — `35c75ae`, **rev2/fix-exclusives only**

New `ahb_sub_hexcl` input / `ahb_sub_hexokay` output on `tidelink_top`; a transfer with HEXCL=1 is never issued to XHB500
(`xhb_sub_hsel` gated) and gets a two-cycle ERROR; obs bits [15] `excl_refused_sticky`, [16] `excl_inbound_sticky`.
Mutant control `+define+TIDELINK_XDIE_EXCL_LEGACY_MUTANT` with a **positive** assertion of the original defect
(`xdie_exclusive_redproof`, PASS 26 s in the rev2-excl run). Structural checker `scripts/ci/check_excl_port_wired.py`
(45/45 instantiations) with its own control, which caught a fail-open parser bug. The commit is explicit that the parent
chiplet's D2D port is AHB-Lite with no HEXCL (`nanosoc_multicore_soc.sv:77-87`), so the end-to-end silent double-commit
**remains reachable** on the current chiplet: this fix is necessary-not-sufficient and needs an upstream AHB5 port.
Not merged; 21 `tb_top.sv` port edits + a DFT-wrapper + Vivado-wrapper change make it the largest RTL-adjacent delta on any
rev2 branch. No HW validation ("Sim only, by instruction").

---------------------------------------------------------------------------------------------------------------------

## 3. Checker / test changes review

### 3.1 The checker fixes (16 counted: 6 signoff, 2 uvm, 3 cocotb, 3 pynq_host, 3 sim_gate/ci/coverage — plus 1 provenance on hygiene)

| item | fix | must-fail control | control wired? |
|---|---|---|---|
| A1 LVS INCORRECT graded CORRECT | `9a7c02c`: `run_calibre_lvs.sh` now calls `lvs_verdict.sh` (0 CORRECT / 1 INCORRECT / 2 COULD-NOT-EVALUATE) and only emits `CALIBRE_LVS_OK` on 0 | `ci/checker_controls/control_lvs.sh`: fixtures `lvs-missing-connection` -> INCORRECT rc 1, `lvs-truncated` -> COULD-NOT-EVALUATE rc 2, `lvs-clean`, `lvs-empty`; refuses to run on missing fixtures (:29-34) | **no** — `run_all.sh` unwired |
| A2/A3 fc_drc OK unconditional; absent report = 0 | `8a91087`: `7_drc.tcl` gains `grep_count_status` (nofile/noparse/ok), FC_STAGE_OK conditional | `control_fc_drc.sh` (138 lines) | **no** |
| A4 crashed lint ratchets as clean | `74106f7` | `control_farm_gate_ratchet.sh` | **no** |
| A5 verify_build exits 0 unverifiable | `59d4366` | `control_verify_build.sh` | **no** |
| A6 Vivado message gate fails open | `48897cb` | `control_msg_gate.sh` | **no** |
| B1 UVM scoreboards pass on total loss | `24cb2cb`: `uvm_warning` -> `uvm_error` + `packet_count_mismatches` counter, report_phase check | `tests/tidelink_scoreboard_loss_selftest.sv` (+ integration twin) with a NEGATIVE control (matched queues silent, :195) | registered in `uvm/tidelink/Makefile:157`; **not in sim_gate** |
| B2 unmatched-TX backstop reads deleted queues | `2c0783d`: surplus captured into counters before `delete()` | `uvm/tidelink_top_system/selftest/tl_top_sb_selftest*.sv`, `make sb_selftest` | **not in sim_gate** |
| B3 lane-mask oracle cannot go red | `0bad1d2` | `scripts/ci/tests/test_lane_mask_oracle.py` | `selfcheck_gates` (manual) |
| B4 5 PASS at 0 ns | `c5141c3` -> SKIP | n/a | - |
| B5 sniffer probe 0 asserts | `17cd21b` | n/a | gated suite |
| B6 63 invoked / 61 scored | `abe7fca`: `scripts/ci/sim_gate_integrity.py`, `sim_gate: sim_gate_integrity ...` (`Makefile:1893`) | `scripts/ci/tests/test_sim_gate_integrity.py` | **yes — blocks sim_gate** (the one checker control that gates) |
| B7 registry_coverage scores "could not check" as covered | `107b0dc` | `test_registry_coverage.py` | `selfcheck_gates` |
| C3 health_snapshot exits 0 unevaluable | `deaed7e`: rc 0/1/2 (`EXIT_COULD_NOT_EVALUATE = 2`) | `test_health_snapshot.py` | `selfcheck_gates` |
| C4 kr260_sysval T6 discards check | `736607c` — **lost at merge**; `kr260_sysval.py:463-465` still discards | control deleted | **defect live** |
| C11 two host tests always exit 0 | `9788d2c`: `hosttest_verdict.summarise_and_exit` | `test_hosttest_verdict.py` | `selfcheck_gates` |
| coverage merge silently drops DBs | `d7a928c`: `coverage_merge_integrity.py` | — | in `coverage_gate` path |
| `git_dirty:false` = could not tell | `df0f1f2` (hygiene only) | none found | **not on integration**; the ASIC-fileset README explicitly warns the flag is still fail-open on that branch |

Verdict: the fixes are real and mostly well-constructed (three-outcome verdicts throughout, fixtures guarded against vacuity),
but **only B6 actually gates**. `selfcheck_gates` is manual; `ci/checker_controls/run_all.sh` is wired into nothing; the UVM
self-tests are not in `sim_gate`. On a repo whose register's Tier 0 is "nothing is gated by CI", a manual target is the same
thing as before.

### 3.2 Coverage instrumentation (`9a6d08e`, `bfa3c8d`/`d5fdb49`, `d7a928c`, `1d0b56f`, `634e60a`, `e6bdb61`, `066e818`)

Verified in `$WORKTREES/SoCLabs/td-bisect/coverage-2026-08-26/`: `README.md:60` FSM transition 177/423 = **41.84 %**,
line 85.63 % (`gate_vs_wholerepo.txt`); `FINDINGS.md`: `xhb500_axi_to_ahb_bridge_chiplet_mst_core_xin` FSM **0.00 %** on both
dies, XHB500 non-singles arm uncovered (with a correct note that `singles_burst` itself is not a valid marker), **16.0 %**
(7 890/49 323 SLOC) unmeasured due to ASIC twins shadowed at elaboration; 4 elab-only suites are the only cover for ASIC sources.
`asicsim-2026-08-26/`: ASIC_FLIST=1 sweeps (23 suites, 20 pass, 2 fail, 1 no-result) and `066e818` records 2.7 % unmeasured
(1 348 SLOC) with per-file numbers for the 8 former shadow pairs. Sound instrument checks (a positive-control "the burst arm
reports UNCOVERED" step; a corrected keying bug documented in `gate_vs_wholerepo.txt`).
Caveat: `bfa3c8d` and `d5fdb49` share a subject with different patch-ids (03:15 vs 09:11 on 08-26) and both are in history;
harmless but a sign the sub-branches were re-based by hand.

### 3.3 New benches — are any vacuous?

- `test_v2_burst_encodings.py` (`ea1c3e4`): 12 tests; `test_cacheable_incr4_backstop`, `test_nonseq_relatch_ab`,
  `test_incr4_cacheable_pulse_nonseq` and **`test_cacheable_incr4_destroys_prior_data` end in `assert True`** (:521, :637, :710,
  :770) — characterisation only; the "all-zero burst lands in peer memory" claim is logged, not asserted. **Not wired into
  `sim_gate`** (no Makefile reference). So claim (g) is a characterised observation with no regression behind it and no fix.
- `test_xdie_exclusive.py` (`45f1ef5`, 2 tests, gated as `xdie_exclusive`): asserts the marker never reaches AXI and both
  initiators commit — a defect-documenting test that passes on the defect; discriminating once `35c75ae` flips it.
- `test_tl044_park_recipe.py`, `test_tl044_read_deadgate.py`: non-vacuous (mutant, Force-free parks, explicit must-be-present
  controls).
- `test_a2l_wready_tear.py`: three anti-vacuity guards; good.
- `cocotb/xhb500_bridge` unit bench (`c5bc7ef`, gated): directly addresses the 0.00 % `mst_core_xin` finding.
- `wlink_tx_pstate` (`d96199e`, gated): addresses the 0/4 transitions finding.

---------------------------------------------------------------------------------------------------------------------

## 4. Docs added

- `docs/FALSE_GREEN_REGISTER.md` (354 lines; `2974d51` + `8cb7b70`). Structure: Tier 0 (no CI on either forge), Tier 1 =
  **24 numbered items** (A1-A6 sign-off, B1-B7 verification apparatus, C1-C11 runtime/RTL observability), Tier 2 proven dead
  terms, Tier 2 false-RED, UNPROVEN, RULED OUT, NOT COVERED. The "~49" figure is the doc's own count including Tier 2 and
  unproven; I count 24 Tier-1 items. Top items: A1 LVS substring, A2/A3 fc_drc, B1 UVM loss, B6 63/61, C1 `data_nodes_healthy`
  cannot latch while another channel moves, C2 `LINK_STATUS[4]` hardwired constant, C4 T6, C10 `xprop/` never runs. The
  "Structural fact: zero SystemVerilog assertions" line is a useful summary for the main report.
  **Staleness:** the header still says "survey only. Nothing here has been fixed" although ~16 items were fixed on the same
  branch; only one "fixed on" note. Needs a status column before it can be handed to anyone.
- `docs/MERGE_RECONCILIATION_TODO.md` (54 lines): honest record that C4/T6 is unfixed on integration and why (semantic
  disagreement on `rc=3`-with-output). Good practice; it is an open blocker, not a nit.
- `docs/SIM_GATE_COVERAGE.md` (+78), `docs/coverage/README.md`, `docs/plans/COVERAGE_REPOSITORY_2026-08-26.md` (559 lines):
  coverage repository design. Not audited line-by-line.
- `fpga/asic_fileset/README.md` (297 lines): the best document on the branch. Records the 10-file ASIC/FPGA divergence
  (7 210 vs 8 326 lines), the sha256-at-two-hops proof, the netlist census (`socl_l7_wdog_cnt in_axi_nodes=0 anywhere=45`,
  controls present), timing (WNS +27.9 ns, 0/148 403 failing), and **why the manifest says dirty**. Artefact verified on disk:
  `rev2-asicfpga/imp/fpga/output/kr260-pair-onchip/artefact/tidelink_ASICFILESET_9465208f3dca.bit` sha256 prefix matches,
  manifest `phy_marker: V2-ASICFILESET`, `git_dirty: true`, `source_commit: 9a713177-dirty`. **Never deployed** (README says so;
  no board log anywhere under td-bisect).
- `docs/BUG_REGISTRY.yaml`: +89 lines on integration, all under TL-042; no TL-043/044/045 ids (they are on side branches).

---------------------------------------------------------------------------------------------------------------------

## 5. Divergence between rev2 branches

- `git merge-tree --write-tree origin/rev2/integration origin/rev2/hygiene` -> **2 conflicts**: `fpga/farm_gate.sh`,
  `src/rtl/tidelink_top.sv`. Auto-merges: `.gitlab-ci.yml`, `Makefile`, `docs/BUG_REGISTRY.yaml`,
  `fpga/scripts/build_provenance.tcl`. The `tidelink_top.sv` conflict is comment-only on the hygiene side (bit[10] block,
  :1846-1885) against integration's obs-word comment rewrite (:2139-2152) — trivially resolvable but it must be resolved by a
  person, and the resolution should keep hygiene's "bit[10] is PRESSURE" correction (evidence:
  `td-bisect/kr260-integ-2026-08-24-results/AB_SUMMARY.json`, present on disk).
- `rev2/hygiene` carries four things integration lacks: the fail-closed `git_dirty` (`df0f1f2`), the credential removal +
  `check-secrets.sh` wired at `Makefile:1983` (`6063710`), the xhb500 vendor-tree digest pin (`6a174a3`), content-keyed lint
  ratchets (`57b6700`).
- Folded into integration: asic-fpga, sim-probe, signoff-checkers, and the six unnamed sub-branches. Not folded:
  fix-exclusives (`35c75ae`, 1 commit), ar-r-selfheal (`5c31619` registry entry only), hygiene (5).

---------------------------------------------------------------------------------------------------------------------

## 6. Land-readiness verdict for rev2/integration -> main

### What has been run on `cba9774d`
- **Full sim_gate at `cba9774d9c78-dirty`** (rev2-excl, 2026-09-02): 75 suites — 69 PASS, XFAIL x3 (`v2_mask_hs_regress`,
  `xfail_epoch_shipping_corrector`, `xfail_f14b_datamode_wedge`), **FAIL x3**:
  `flist_divergence` (real, caused by `bf813a7`), `tc_pair_smoke` and `tc_pair_election_datamode` (VCS `UPIMI-E` undefined port
  — the known tidechart_shim<->tidechart version skew, external). All rev2 RTL suites PASS in that run (a2l_replay_cdc_7/9,
  a2l_wready_tear, tl044_hol_write_age, tl044_read_deadgate, tl044_park_recipe, xdie_exclusive, asic_l7_starvation_backstop,
  asic_fcsm_silicon_ratio, asic_fileset_identity, xhb500_bridge, wlink_tx_pstate). Caveat repeated: the tree held the
  uncommitted TL-045 edits.
- **rev2-final (`cba9774d`, clean)**: only today's env-trap run (all FAIL in 3-5 s, `${CMSDK_FPGA_SRAM_V}` unexpanded). No valid
  clean-stamp gate on disk. rev2-simprobe has 2 PASS at `bf813a74-dirty`; tl-siteenv has a 59-suite run at `8b3cc9e4-clean`
  (2026-08-20, pre-rev2).
- **Hardware**: nothing on the rev2 RTL. HW artefacts in the period: harness-repair proof (2026-08-25, host tooling),
  election campaign (2026-09-01, TideChart at main-era image), dual-root fix validation (today, `fix/tidechart-dualroot-timeout-tooling`
  `b32d4b5b` + tidechart `6cc1dac`, images sha-pinned, in progress — latest file 16:43).
- ASIC-fileset FPGA image built and verified structurally (netlist census) — not deployed.

### Working-tree state of each rev2 worktree (`git status --porcelain | wc -l`)
| worktree | HEAD | branch | dirty lines | uncommitted RTL |
|---|---|---|---|---|
| td-bisect/rev2-final | cba9774 | rev2/integration | 0 at start; 4 now (`dut_src_{1,3,5,7}.f` churn from the concurrent run) | none |
| td-bisect/rev2-asicfpga | 9ce95fe | rev2/asic-fpga | 0 | none |
| td-bisect/rev2-excl | 35c75ae | rev2/fix-exclusives | 6 (`dut_src_*.f` x5, `tidelink_fcsm_silicon_ratio/*.flist`) | none |
| td-bisect/rev2-simprobe | 45f1ef5 | rev2/sim-probe | 0 | none |
| td-bisect/tl-siteenv-2026-08-19 | b1c9c9b | rev2/ar-r-selfheal | 0 | none |
| td-bisect/baseline-5e8bdb5a | 5e8bdb5a | detached | 3 (`dut_src` churn) | none |

### Verdict: **NOT land-ready as-is.** Checklist before it becomes main
1. Fix or decide the `flist_divergence` FAIL: either re-point `_7/_9` in `flists/tidelink_top_full_asic_v2.flist` (then the
   ARR fix tapes out — and needs its own ASIC-flist elaboration + `asic_v2_pair_data` re-run) or record the deviation in
   `scripts/ci/flist_divergence.py`. Then re-run `make sim_gate` on the **clean** tip after `source ./set_env.sh` and keep the
   `*.status` files with a `-clean` stamp.
2. Resolve `docs/MERGE_RECONCILIATION_TODO.md` (T6 delivery check) and restore its control to `selfcheck_gates`.
3. Wire `ci/checker_controls/run_all.sh` and the two UVM loss self-tests into `sim_gate` (or at least `selfcheck_gates`), and
   make `selfcheck_gates` a prerequisite of `sim_gate` like `sim_gate_integrity` already is.
4. Merge `rev2/hygiene` first (resolve the 2 conflicts), so main stops carrying the credential (24/18) and gets the fail-closed
   `git_dirty`; then rebase/merge integration on top. Rotate the credential regardless — history keeps it (11 commits).
5. Add registry entries for TL-043-ARR (`5c31619` from ar-r-selfheal), TL-044, and — if merged — TL-045, so `registry_coverage`
   can gate them; set `hw_validated: false` explicitly.
6. Add the negative arms to the gate: `tl044_hol_prefix` (TL-042 isolation build) and a `USE_DEPS_DUT=1` run for
   `a2l_replay_cdc_7/_9`; fix the stale "EXPECTED TO FAIL TODAY" docstring.
7. Update the 0x21F8 decoders (`pynq_host/scripts/health_snapshot.py`, `eth_tlapb_poke.py`, `kr260_sysval.py`) for bits
   [12:14] (and [15:16] if TL-045 lands) and update `docs/TL021_FIRST_SILICON_OBS_SPEC.md`.
8. Untrack `cocotb/tidelink_a2l_replay_cdc/dut_src_*.f` (generated; committed with a personal absolute path).
9. Hardware: at minimum one `kr260-pair-onchip` deploy of an integration image with (a) the 5 000-packet soak and cross-die
   read/write regression (rule: anchor-pair gate), (b) a forced R-loss to observe TL-044's containment and its obs bits,
   (c) a forced B-loss to observe TL-042's drain and confirm no stray-B side effect in XHB500. Optionally the ASIC-fileset image
   with the prepared `asic_l7` probe (accepting COULD-NOT-EVALUATE as a possible honest outcome).
10. Update `FALSE_GREEN_REGISTER.md` with a per-item status column (fixed / open / superseded) before circulation.
11. Decide `rev2/fix-exclusives`: it is the right fix, but it changes the `tidelink_top` port list and needs the parent
    chiplet (`nanosoc_eth_chiplet.sv:925`) to connect `.ahb_sub_hexcl`; landing it without that connection re-creates the
    defect silently, which the structural checker only catches inside this repo.

---------------------------------------------------------------------------------------------------------------------

## 7. What rev2 does NOT yet address (against the known-open list)

| open item | rev2 status | evidence |
|---|---|---|
| XHB500 hazard-list saturation write wedge (B-return stall; timers re-zeroed by unrelated progress) | **Partially**: TL-042 HOL watchdog is exactly the "timers re-zeroed by unrelated progress" fix and gives a bounded escape (synthetic B drain) — it is containment, not a root cause for why B never returns; sim-only, not HW-tested | `82c56e2`; registry "NOT hw-tested" |
| TL-042 `wr_hold_r` deadlock (awready drops after 8-deep replay window fills) | **Not addressed**: the a2l_fc_replay timeout gap is untouched; rev2 renamed "TL-042 instance 1" to the starvation defect, which is a different mechanism | no change to `wr_hold_*` (commit says so explicitly) |
| Cross-die READ path defect (`hsel_peer` no `hwrite` term; 5 initiators reach `_D2D`) | **Partially**: TL-044 contains the *consequence* (idle-bus dead gate after a lost R) and the read nodes get the CDC self-heal on FPGA; the read-path routing itself is unchanged and the ASIC still ships raw `_7/_9` | flist :306/:308 |
| ASIC-flow blockers (`scan_clk` 67.6 % CTS, `scen_slow` zero uncertainty, `read_sdc` abort at `constraints.sdc:168`) | **Not addressed**: rev2's `syn/asic` changes are checker/verdict plumbing only (`7_drc.tcl`, LVS scripts, `common.mk` site.env); no constraint or CTS change | `git diff --stat -- syn/asic` |
| Header ECC bypass in ASIC (TL-006) | **Not addressed** | no ECC-related diff |
| ASIC FCSM zero recovery (state-7 wedge) | **Characterised, not fixed**: A/B sim proves ASIC arm wedges at state 7 where FPGA escapes (`l7_starvation_ab_SUMMARY.txt`), ASIC-fileset image built with netlist census proving recovery flops absent, HW probe prepared-but-unrun; **no decision to re-point FCSM 0-4** | `e6bdb61`, `a585a2f`, `9a71317` |
| Link CRC off by default | **Not addressed** | no diff in CRC enable defaults |
| PTP/PHC hop broken | **Not addressed** (only `eth_ptp_*` coverage Makefile wiring) | - |
| Throughput (singles-only) | **Not addressed; made worse-known**: burst bench shows the non-singles arm emits a leading all-zero AXI burst (logged, `assert True`), so enabling bursts is currently unsafe | `ea1c3e4` |
| `tidelink_top.sv` monolith | **Worse**: +505 lines (now ~3.4 k+), three more backstop machines in one file | diff stat |
| Six FCSM copies | **Not addressed** (now documented as ten shadow pairs incl. `_7/_9`) | `fpga/asic_fileset/README.md` |
| Flist single-source | **Partially**: `flist_divergence.py` makes divergence a checked artefact (and immediately fails); `asic_fileset_identity` suite asserts which file compiled; no single source yet | `Makefile:1708-1716` |
| Public-repo credential rotation | **Not addressed on integration/main** (24/18 still present); removal + guard exist only on hygiene; **rotation** is outside git and not evidenced anywhere | `git grep` counts |
| 34 unwired cocotb benches | **Partially**: +8 suites wired (a2l_replay_cdc_7/9, a2l_wready_tear, tl044 x3, xdie_exclusive, xhb500_bridge, wlink_tx_pstate, addr_translator, asic_* x5); `gate_vs_wholerepo.txt` says 43 non-gate benches ran, 2 timed out, 9 do not build — those 9 remain | coverage evidence |
| `stall_stuck=1` (0x21F8 bit[10]) on die_a in every capture | **Explained on hygiene only** (`38f362e`: bit[10] = hazard-list *pressure*, fires on any >4096-hclk cross-die round trip; corroborated by `election-2026-08-26/SUMMARY.json` `cross_die_reads.obs_interpretation`); integration still carries the "deadlock witness" comment and TL-044 reuses the same 4096 threshold with the *additional* no-progress qualifier, which is the right discriminator | :1583-1590 |
| TideChart dual-root / `TC_ERROR[2]` no setter / APB decode aliasing | **Not on any rev2 branch**: reproduced 6/6 on HW (`election-2026-08-26`), fix is in the tidechart repo (`6cc1dac`, TIMEOUT_W 24) + tidelink host tooling `b32d4b5b` on `fix/tidechart-dualroot-timeout-tooling`; HW validation in progress today | `dualroot-hwval-2026-09-09/evidence/00_build_identity.txt` |

---------------------------------------------------------------------------------------------------------------------

## 8. Verification of the `tidelink-23` session's reported claims

| claim | status | evidence |
|---|---|---|
| (a) `FALSE_GREEN_REGISTER.md` lists ~49 diagnostics | **Verified (doc exists, 354 lines)**; 24 numbered Tier-1 items, the rest in Tier 2/unproven; header stale ("nothing fixed") | `docs/FALSE_GREEN_REGISTER.md:1-16` |
| (b) no CI on either forge; GitLab 293 behind | **Verified**: `.github/workflows` absent on main and integration; `gitlab/main` = `9092300b` (2026-07-23), 293 behind, strict ancestor (local ref, last fetch) | `git ls-tree`, `git rev-list --count` |
| (c) LVS substring bug + fc_drc unconditional OK, fixed with must-fail controls | **Verified** (`9a7c02c`, `8a91087`, `control_lvs.sh:82-84`, `control_fc_drc.sh`); controls **unwired** | section 3.1 |
| (d) two UVM scoreboards passed on total loss | **Verified** (`24cb2cb` diff: `uvm_warning` -> `uvm_error`, `min_size` loop noted) + self-tests with negative controls; not gated | section 3.1 |
| (e) sim_gate 63 invoked / 61 scored | **Verified from the branch's own record** (`Makefile:1874-1886`, `sim_gate_integrity.py` docstring) and now mechanically blocked; my raw grep on main: 55 names in `SIM_GATE_ALL_SUITES` vs more invoked | `abe7fca` |
| (f) FSM transition 41.84 % vs line 85.6 %; `mst_core_xin` 0.00 %; 16 % -> 2.7 % | **Verified** (`coverage-2026-08-26/README.md:60`, `FINDINGS.md`, `066e818`) | section 3.2 |
| (g) XHB500 non-singles arm never executed; when driven emits two bursts, first all-zero, destroying peer memory | **Never-executed: Verified** (coverage). **Two-burst/all-zero: Unverified as a gated assertion** — the bench logs it and ends `assert True`; not wired into sim_gate; no fix | `test_v2_burst_encodings.py:714-770` |
| (h) ASIC FCSMs zero recovery (`socl_` 0 vs 73), wedge at state 7 | **Verified** (`socl_` 0 in deps; 73/72/72/72/72 per file in the README, 491 lines total by my grep; `l7_starvation_ab_SUMMARY.txt` WEDGED at 7 vs ESCAPED) | section 3.2 |
| (i) cross-die exclusives silently do nothing: `.hexcl(1'b0)` at `tidelink_top.sv:3171`, `.hmaster(12'd0)` | **Verified** (:3171, :3172 on integration; :3313/:3319 mng side); fix on fix-exclusives only; unfixable end-to-end from this repo (AHB-Lite D2D port) | section 2.4 |
| (j) TideChart dual-root 6/6 on HW, timeout widened 16 -> 24 bits, necessary-not-sufficient | **Verified** (`election-2026-08-26/SUMMARY.json`: `dual_root_observed: true`, `dual_root_rounds: 6`, threshold between 0xD000 and 0xD800 hclk, field ceiling 0xFFFF = 18.5 % headroom; `dualroot-hwval-2026-09-09/evidence/00_build_identity.txt`: `TIMEOUT_W = 24`, `07_timeout_field_discriminates.log` readback tracks on both dies). Final campaign verdict **still in progress today** | evidence dirs |
| (k) `TC_ERROR[2]` no setter; APB decode aliases; `pslverr` tied 0 | **Setter absence: Verified** (`tidechart_apb_regs.sv` at pin `4b4b898`: `error_reg_r` assigned only :426 reset, :513, :535 W1C; `dual_root` only in comment :189). **`pslverr=0`: Verified** (:355). **16-fold aliasing: Unverified** (decode at :384-396 uses `apb_paddr[8:0]` in a generate; not traced) | tidechart repo |
| (l) `git_dirty:false` = could not evaluate, fixed on hygiene | **Verified** (`df0f1f2`, hygiene-only; README on asic-fpga confirms not an ancestor) | section 5 |
| (m) board password in public history, 24 occurrences / 18 files | **Verified exactly**: 24/18 on `origin/main` and on `origin/rev2/integration`; 0 on hygiene; 11 commits; first `a04a194b` 2026-07-31. Not printed | `git grep -c` |

---------------------------------------------------------------------------------------------------------------------

## 9. Quality assessment (short)

Strengths: the RTL work is narrow, heavily commented with measured motivation, and each backstop is a register-only block with
an explicit no-comb-loop argument; TL-044's mutant design (detection kept, action removed, negative arm required to fail) is
the standard the rest of the repo should adopt; the coverage and ASIC-sim work turned two long-standing "reasoned" claims
(ASIC FCSM recovery absent; ASIC sources never simulated) into measurements with positive controls; the false-green register
is the right document, and the merge-reconciliation note is honest.

Weaknesses: the branch fails its own new gate; nothing RTL has touched a board; the ASIC flist is unchanged so the read-path
self-heal does not ship; the checker controls are decoration until wired; one claimed false-green fix was silently dropped at
merge; hygiene (credential, provenance) is stranded on a conflicting branch; the obs-word contract moved without tooling;
`tidelink_top.sv` grew another 500 lines; two identically-titled commits and generated files with personal paths are in
history.

Files most relevant to the main report:
`$WORKTREES/SoCLabs/td-bisect/rev2-final/src/rtl/tidelink_top.sv` (:1576-1631, :1710-1800, :1955-2128, :2139-2152, :2360-2405, :2430-2605),
`$WORKTREES/SoCLabs/td-bisect/rev2-final/src/rtl/local_overrides/WlinkGenericFCReplayV2_{7,9}.v`,
`$WORKTREES/SoCLabs/td-bisect/rev2-final/flists/tidelink_top_full_asic_v2.flist` (:283-321, :415),
`$WORKTREES/SoCLabs/td-bisect/rev2-final/docs/FALSE_GREEN_REGISTER.md`,
`$WORKTREES/SoCLabs/td-bisect/rev2-final/docs/MERGE_RECONCILIATION_TODO.md`,
`$WORKTREES/SoCLabs/td-bisect/rev2-final/fpga/asic_fileset/README.md`,
`$WORKTREES/SoCLabs/td-bisect/rev2-excl/imp/sim_gate/` (the only full gate run on the candidate content),
`$WORKTREES/SoCLabs/td-bisect/rev2-final/pynq_host/scripts/kr260_sysval.py:463-465` (live false-green).


---

# PART 9 Findings ledger

# Findings ledger (normalised IDs) — built from reviews as they land
# Columns: ID | Title | Layer | Sev | Conf | Status@main 5e8bdb5a | Status@rev2 cba9774d | Effort | Source
## Transaction layer (review_rtl_transaction_layer.md)
TL-A1 | Write backstops are aggregate-progress timers → starved in hazard-list-full wedge; synth-B never fires (silicon 0x21F8[8]=0) | AHB-sub | Critical | V | Open | Fixed-sim (82c56e2a HOL write-age), HW-unproven; HOL drain doesn't release wr_hold_r | L (HW A/B) | F1
TL-A2 | Cross-die READ with lost R parks XHB500 forever (read_counter only dec on r_done); no synthetic-R; idle HREADYOUT low forever | AHB-sub | Critical | V | Open (reachable from 5 initiators) | Contained (c6f091a1 bounded ERROR), NOT recovered | M | F2 / R-02
TL-A3 | fc_adapter: tc_axis_tx_tready without arbiter grant → TideChart words silently dropped | fc_adapter | High | V | Open | Open | S | F3
TL-A4 | fc_adapter: servo word duplicated + TC word dropped on collision | fc_adapter | High | V | Open | Open | S | F4
TL-A5 | fc_adapter: returner credit/doorbell word dropped under sideband_starving | fc_adapter | High | V/P | Open | Open | S | F5
TL-A6 | 0x21F8[10] xhb_stall_stuck_sticky false-RED (2^12 threshold, fires on any healthy cross-die read) | Obs | Med | V | Open | Open (doc fix on hygiene only) | S | F6
TL-A7 | 0x21F8[9] sub_err_sticky sets on masked ERROR; label stale | Obs | Med | V | Open | Open | S | F7
TL-A8 | Late real B after synthetic drain → wrong write completed / ctr under-count | AHB-sub | Med | H | Open | Open (rev2 adds 2nd drain w/ same exposure) | M | F8
TL-A9 | hclk-denominated timeouts vs link-clock-bound latency; ASIC margin unmeasured | AHB-sub | Med | P | Open | Open | S | F9
TL-A10 | RX-FIFO write side has no packet timeout → truncated packet mis-frames successor silently | FIFO | Med | V | Open | Open | M | F10
TL-A11 | Rank-1 hold gaps for a PIPELINED AHB master (KR260 bridge non-pipelined → blind) | AHB-sub | Med | H | Open | Open | M | F11
TL-A12 | DFT wrapper straps different POR defaults than tidelink_top (NEGO_CFG_RESET 7'h61 vs 7'h00, DEBUG_UNLOCK 0 vs 1); MBIST/TAP/7 chains stubbed | DFT/ASIC | Med | V | Open | Open | S | F12
TL-A13 | role_locked_o (hclk) used as async reset of link_rx_clk domain, no de-assert sync | PHY | Low/Med | V | Open | Open | S | F13
TL-A14 | fcemit_obs multi-bit through plain 2FF (torn reads) | Obs | Low | V | Open | Open | S | F14
TL-A15 | Duplicated sub_wr_stuck_fire logic; stale comments; 0x21F8 only under PHY_V2 | Smell | Low | V | Open | Open | S | F15
TL-A16 | XHB500 singles_burst gated on HPROT[3] (vendor core_addr.sv:147); multi-beat arm never tested; tie-down in chiplet repo | XHB500 | High(latent) | V | Open | Characterised (bench ea1c3e49), not fixed | M | F16 / R-03
TL-A17 | Refactor: split tidelink_top.sv into 8 modules (line-range map in review §9) | Maint | — | — | — | worse (+491 lines) | L | §9
## Link / PHY / FCSM / PTP (review_rtl_link_phy.md, partial: sections 0-5)
LP-1 | 52c06677 split: FCSM half FPGA-only; controller half ASIC-reachable = 10 alias wires + 13-bit counter + latch (14 flops, no sink, swept) | Tooling | Info | V | Landed | same | S (ifndef fence) | §2.2
LP-2 | TL-035 Part-B exits state 7 WITHOUT clearing sop → stale NACK re-serialised when grants resume (NACK storm, bounded by one round-trip) | Wlink-FC | High (FPGA) | V | Landed unconditional | same | S (one line ×5 files) | §2.4
LP-3 | ASIC AXI FC nodes (deps) have ZERO socl_ recovery AND run CRC ON; FPGA validated CRC OFF WITH recovery; ASIC arm measured wedged in state 7 | Wlink-FC/ASIC | BLOCKER | V | Open | Open (measured, netlist census) | M (flist re-point + regression) | §4 / TL-019
LP-4 | Consolidated worktree disagrees only on Part-B default (ifdef OFF); its controller is BEHIND main (lacks Hazard-3) — do not take | Tooling | Med | V | — | — | S | §2.6
LP-5 | FCSM _0.._4 are parameter-only clones; _6 is a different lineage: has credit-max fix, lacks TL-035; _0.._4 have TL-035, lack credit-max fix | Wlink-FC | Med | V | Open | Open | S each / L (one Chisel module) | §3
LP-6 | fe_tx_credit_max swi-enable re-zero still live on all 5 AXI nodes (FPGA-local and ASIC-deps) | Wlink-FC | Med | V/P | Open | Open | S | 3.1
LP-7 | TL-035 watchdog absent from _6 (the CRC-ON node) | Wlink-FC | Med | V | Open | Open | S | 3.2
LP-8 | FCReplayV2_13 lacks TL-032 rewind that _1/_3/_5 carry | Wlink-FC | Low/Med | V | Open | Open | S | 3.3
LP-9 | a2l ACK mailbox = ping-pong handshake; TL-027 w_inc=1 is correct latest-value discipline (not a band-aid); AXI nodes' mailboxes lack coherent reset (deps) | CDC | Info/Low | V | — | — | S | §5
LP-10 | AddrSync_18 reset-skew fix: ASIC uses deps copy (no fix) | CDC/ASIC | Med | V | Open | Open | S | §1/A7
LP-11 | _7/_9 (AR/R) self-heal: rev2 re-points FPGA flist only; ASIC flist still deps | Wlink-FC/ASIC | High | V | Open | Partial (FPGA only) | S | A8
LP-12 | No timeout anywhere in replay nodes (TL-042 H1 stands); 12 bare mark_debug in ASIC-sourced controller + 11 in fc_adapter | Wlink-FC | Med | V | Open | Open | S | §6(summary)
LP-13 | PTP servo cannot converge from offset >1 s; needs_phase_step_r never cleared; ns field no borrow; no FSM timeouts; untagged 3-word mailbox | PTP | High | V | Open | Open | M | §8(summary)
LP-14 | Link-clock divider: RTL sound, but new top port link_clk_div_ratio_i unconnected by BOTH wrappers; no SDC for clkdiv_r; cited SDC file doesn't exist | PHY/ASIC | High (ASIC) | V | Landed | same | S | §9(summary)
LP-15 | Autoneg terminal ST_ERROR with no self-exit; FIN-state timeouts deliberately un-armed; calibrated_once one-shot (SWI_FORCE_RECAL door exists) | PHY | Med | V | Open | Open | M | §7(summary)
## Consolidated register (review_open_defects.md) — headline counts
REG-1 | Registry: 42 entries; 13 closed-and-proven, 5 closed-unproven, 20 open, 3/3 hw_proven OVERCLAIMED (TL-003/005/007), 2 resolved-but-listed-open (TL-015, TL-033), 6 under-report landed fixes | Docs | High | V | — | TL-043/TL-044 IDs collide & unregistered | S | §1
REG-2 | 9 fixes reached HW and were shown non-operative/insufficient/harmful; 4 root-cause claims retracted; ~49 false-green diagnostics | Process | — | V | — | — | — | §4
REG-3 | ASIC flow blockers (scan_clk/scen_slow/read_sdc) FIXED in-tree (9d1b2eaa) but NO post-fix timing report found | ASIC-flow | High | V | Fixed-unproven | same | S (one FC run) | §2.10
REG-4 | Public-repo: PDK/home paths FIXED on main (affbda14); board credential in 18 files on main AND rev2/integration, 41 files with board IPs, 11 commits; removal on hygiene only; rotation outstanding (DECISION) | Security | High | V | Open | Open | S (rotate) | §2.12
REG-5 | PTP F13 + PHY-BIST F19 unchanged since 07-31; servo suite ungated (0 refs in Makefile) | PTP/PHY | High | V | Open | Open | L | §2.13
REG-6 | Throughput gap 487.9 vs 95.8 CLOSED by clock-ratio correction (603.4 predicted, 1.24x pessimistic); window depth is remaining lever | Perf | Info | V | Closed | — | — | §2.14
## Verification (review_verification.md)
V-1 | No automated gate on origin/main: GitHub has no .github; GitLab trunk 293 behind, 0 pipelines; sim-gate "blocking" claim false | Verif | S1 | V | Open | Open (+103 lines .gitlab-ci, no .github) | M | V1
V-2 | make sim_gate dirties its own tree (tracked dut_src_*.f regenerated at parse) → summary exit 2 on clean checkout; 22 clean/36 dirty stamps on 08-25 run | Verif | S1 | V | Open | Open (5 nodes now) | S | V2
V-3 | Last real gate on main (08-25): 55 PASS / 2 FAIL (tc_pair_smoke, tc_pair_election_datamode — real assertion failures, standing red on both branches) / 3 XFAIL; ~95 min wall | Verif | S2 | V | Open | Open | M | V4
V-4 | 63 cocotb benches: 18 in gate, 2 parked, 43 unwired (27 ENVS-only, 16 in neither); ≥6 red/unknown (tidelink 24P/1F, autoneg_deadi2c 0/1, py_pair 12/9, system 24/1, wordskew 5/7, lane_deskew 9P/11F 06-25); 23 never produced results.xml until peer sweep | Verif | S2 | V | Open | 3/43 wired | M | V19
V-5 | HBURST≠SINGLE exercised nowhere (34 tb files tie hburst=0; all 8 UVM AHB sequences constrain SINGLE); peer-side inbound bridge mst_core_xin FSM 0% — shipping read/burst datapath never simulated as a system | Verif | S1 | V | Open | Partial (unit bench xhb500_bridge gated; burst bench ea1c3e49 UNGATED) | L | V6/V7
V-6 | Hazard-list saturation (the 08-19 silicon wedge) has NO sim reproduction; RESP_FSM_ERROR never entered | Verif | S1 | V | Open | Open | M | gap 3
V-7 | Backstop tests are escape tests not safety tests (n1_readbackstop_suppress asserts clean read BEFORE fault only) | Verif | S2 | V | Open | Open | S | V9
V-8 | a2l CDC must-fail arm USE_DEPS_DUT=1 exists but gate never runs it (main); rev2 a2l_wready_tear runs both arms | Verif | S2 | V | Open | Fixed | S | V8
V-9 | Vacuous/near-vacuous in gate: t32 dead assert (train_ok_seen forced), axinode_obs validates a field-blind instrument, v2_perf_ctrl any-delta, mask_hs_bilateral 0 asserts (sentinel grep discriminates) | Verif | S2 | V | Open | 2 fixed (onchip_pair 0ns, lane-mask oracle) | S | §3
V-10 | Coverage: FSM transition 41.84% / line 85.6%; whole-repo run moves line only +0.18% (corpus gap, not selection); no functional coverage in gate | Verif | S2 | V | none | infra fixed (coverage.mk, coverage_gate, must-fail instrument check) | M | V18
V-11 | Static: HAL/SpyGlass/Verilator/xprop never run; xprop Makefile swallows exit code (missing tool → PASS); 11KB CDC waivers never reviewed; ZERO concurrent SVA; no formal | Verif | S2 | V | Open | Open (2 SVA hits) | M | V16/V17
V-12 | UVM: 7 envs, only top_system alive; U1 wait_for_irq by-value (ptp_stress can never pass); U2 fc_adapter drivers de-pipelined to hide unregistered DUT race "BUG-22"; U3 all sequences SINGLE; U6 responders never backpressure | Verif | S2 | V | Open | scoreboards fixed only | M | U1-U7
V-13 | .gitlab-ci.yml: 37 jobs, 15 allow_failure; if switched on: sim-gate can't pass, vendor-collateral documented failing, clone/dashboard/cleanup/coverage-merge can't fail; phantom cocotb/wlink_pair job | Verif | S2 | V | Open | Open | M | §8
V-14 | hwtest_gate.sh never produced verdict.json; provenance compares source_commit only, never reads git_dirty; hard-coded board password :33 | HW-val | S2 | V | Open | Open | S | V10/V11
V-15 | kr260_sysval.py rc≠124 relabel + T6 unconditional PASS + health_snapshot exit 0 — all fixed on rev2; lib_hwtest.sh:192 4-bit FCSM mask false-red NOT fixed | HW-val | S1 | V | Open | Fixed (mostly) | S | V12
V-16 | link_rate_quick/full divider sweeps in no gate; divider ≠ /1 never gated | Verif | S2 | V | Open | Open | S | V20
V-17 | sim_gate_sentinel macro lacks make -n guard; 4 duplicate invocations (fixed rev2); fifo_rx_twin2 invoked-unscored with stale justification; 5 rescued targets never triaged | Verif | S3 | V | Open | partial | S | V5/V24
## Flow / tooling / hygiene (review_flow_tooling.md)
FT-1 | Board credential in PUBLIC history since a04a194b (07-31): 24 hits/18 files on main AND rev2/integration; +username +both board IPs (87/41). hygiene removes going fwd + secrets guard. ROTATION = only remediation (DECISION) | Security | P0 | V | Open | hygiene fixed fwd | S | F-5.1
FT-2 | No ASIC build archived after constraint fix 9d1b2eaa; fix commit says correctly-constrained design FAILS timing (WNS -0.40 setup / -1.51 hold / 140 NVE) | ASIC | P0 | V | Open | Open | L | F-3.2
FT-3 | cocotb `make regression` can NEVER fail: summary recipe attached to .PHONY since 2ffc21a5 (08-18); `make -n regression` writes FAIL .result files | Tooling | P1 | V | Open | Open | S | F-2.1/2.2
FT-4 | Two 186-file flists (FPGA v2 / ASIC v2) hand-maintained in parallel (174 shared/12 differ) + ≥10 forks; flist_semantic.py + merge driver exist but NOT activated (.gitattributes absent, no CI caller); 9 orphan flists | Tooling | P1 | V | Open | Partial (divergence checker, TD_ASIC_FILESET build) | M | F-2.4/2.5
FT-5 | FPGA manifest can lie: git_dirty fail-open (hygiene fixes), xhb500 195MB generated tree invisible (hygiene fixes), no axi-chiplet-controller pin, .bin not hashed (stale .bin = WARN only), no tool/define/ILA record | Tooling | P1 | V | Open | hygiene 2/5 | S | F-4.2..4.6
FT-6 | ASIC: 3 blockers fixed at script level on main (scan case-analysis, scen_slow per-scenario, pure SDC) BUT rtl-architect copy of read_design.tcl still has blocker #2; DFT = TODO scaffold; OCV derates placeholders; LVS false-pass on main (rev2 fixed); verify_fix_delivery.sh NEVER committed (lost) | ASIC | P1 | V | Partial | LVS/DRC/verify_build fixed | L | F-3.x
FT-7 | affbda14 cleaned syn/asic only: 41 cocotb/cdc Makefiles still embed Arm release-coded CMSDK drop name, 40 embed EDA install paths, cocotb/tidelink/Makefile:40-42 embeds real Arm/TSMC phys-IP + memory-compiler paths (`?=` defaults) | Security | P1 | V | Open | Open | M | F-5.2
FT-8 | Register map described 4 ways (SV hand-written, RDL, 2×MD) with DOCUMENTED disagreements (fcsm_state [20:17] RDL vs [19:17] RTL; NEGO_PRIORITY reset) → generated C headers carry wrong fcsm_state mask | Docs/SW | P1 | V | Open | Open | M | F-8.2
FT-9 | Root Makefile 1986 lines, 86% is sim_gate hand-expanded 4-way (target body/.PHONY/ALL_SUITES/recipe) — already caused 2 "invoked but unscored" bugs; make -n executes 17 $(MAKE) pipelines outside the guarded macro | Tooling | P2 | V | Open | Open | M | F-1.1/1.2
FT-10 | Deps: same PHY repo vendored twice at branch-tip pins (tidelink-phy 8c560c57 vs gpio-phy 6ee8418b); mainclone remote = path into deps/; axi-chiplet-controller 438MB (419MB verif); public repo NOT independently buildable (Arm IP + VCS/Vivado) and README doesn't say | Tooling | P2 | V | Open | Open | M | F-6.x
FT-11 | Hygiene: 18 worktrees (3 dirty), 35 local branches (28 merged → tag+delete), 2 local-only tips to push, 4 ethclone-ahead branches to tag, gitlab+mainclone remotes to remove; 145 tags all on origin (memory's "19 on neither" RESOLVED); scratch_resolved/ + BRINGUP_REPORT.md at root + tracked generated docs/*.html; global .gitignore *.rep/*.log/*.xml eat fixtures | Hygiene | P2 | V | Open | 1 case fixed | S | §7
FT-12 | kr260-pair-onchip (the vehicle for every HW result since 07-16) has NO fpgahub action; deployed by hand recipe; 10 pynq-z2 experiment targets dead | Tooling | P3 | M | Open | Open | S | F-4.1
FT-13 | TIDELINK_PHY_V2 define never reaches OOC synth → 3 ifdef blocks in axi_chiplet_controller dead in every bitstream | Tooling | P2 | M | Open | Open | S | F-4.7
FT-14 | Reviewer side-effect: `make -C cocotb -n regression` wrote ~60 gitignored .result/run.log files into td-bisect/baseline-5e8bdb5a/cocotb/*/ — harmless to git, still on disk, needs caller cleanup | Housekeeping | — | V | — | — | S | note


---

# PART 10 Coordinator-verified facts

# Coordinator-verified facts (as of 2026-09-09 17:40, for the TideLink Rev-2 Review)

## Repo state
- Primary worktree `$WORKTREES/SoCLabs/tidelink` is on `rescue/primary-worktree-2026-08-10` @ `3d4748fc`, **227 commits behind origin/main** and carrying 25 modified ASIC-flow files + untracked `site.env.example`. It is NOT a valid review target.
- `origin/main` = `5e8bdb5a` (12 commits after the 08-19 consolidation `d0a977aa`): programmable link-clock divider (`001b231d`, CHIP INTERFACE CHANGE, deliberately kept off main on 08-19, now on it), `52c06677` "wip(fcsm) safety-commit ... unreviewed" (5 FCSM files = FPGA-only; 68 lines in `axi_chiplet_controller.sv` = ASIC-reachable mark_debug alias wires per peer), `affbda14` site hygiene, `5e8bdb5a` untrack `deps/xhb500/generated`.
- `origin/rev2/integration` = `cba9774d` (2026-09-02): strict descendant of main, **59 commits ahead, 185 files, +20,855/−553**. RTL delta is only 3 files (+950): `tidelink_top.sv` +505 (TL-042 HOL write-age watchdog `82c56e2a`, TL-044 read dead-gate containment `c6f091a1`), new `WlinkGenericFCReplayV2_7.v`/`_9.v` (AR/R a2l CDC self-heal `e88ff7be`). All 11 sibling rev2 branches have 0 unique commits.
- `origin/rev2/hygiene` = `df0f1f24`: 5 commits, NOT an ancestor of integration. Peer's stated intent: land hygiene FIRST (secrets guard + fail-closed provenance before anything larger touches the public remote).
- `tidelink_top.sv`: 3,477 lines on main → 3,968 on rev2. Growing, not shrinking.
- 18 worktrees, ~37 local branches, 4 remotes (`origin`=GitHub public, `gitlab`=abandoned/293 behind, `ethclone`, `mainclone` → points at `deps/tidelink-phy`, a submodule dir).
- Submodules: `deps/axi-chiplet-controller` (soton GitLab, pinned `efe5623c`), `deps/tidelink-gpio-phy` and `deps/tidelink-phy` BOTH point at the same GitHub repo (different pins `6ee8418b` / `8c560c57`).

## Gate / provenance facts
- **No full `sim_gate` has ever run on `cba9774d`** (peer, confirmed by empty `imp/sim_gate` before today). Two attempts today were VOID: (1) 17:27 no `set_env.sh` → `${CMSDK_FPGA_SRAM_V}` unresolved, ~30 suites FAIL in 3-5 s with a `-clean` stamp; (2) 17:31 submodules populated while gate running → `apb4_if.sv` missing, plus `-dirty` stamp from `dut_src_{1,3,5,7}.f` churn. Third attempt launched 17:35.
- `sim_gate_env_check` (Makefile:304-308) checks only `vcs` and `cocotb-config` on PATH — not `CMSDK_DIR`/`CMSDK_FPGA_SRAM_V`/`XHB500_IP_DIR` or any flist `${VAR}`. Gate does not refuse on uninitialised submodules.
- `dut_src_N.f` churn mechanism: `cocotb/tidelink_a2l_replay_cdc/Makefile:22-52` selects a TRACKED `dut_src_N.f`, and the build rewrites `${TIDELINK_HOME}/...` into an absolute path in place → tree dirty → every stamp `-dirty`.
- `SIM_GATE_NONFATAL=1` is passed to every suite → aggregate `$?` lies; parse `.status`.
- No `.github/` on any of main / rev2/integration / rev2/hygiene. Zero `assert property` in src/uvm/cocotb on main.

## ASIC vs FPGA (verified)
- `flists/tidelink_top_full_asic_v2.flist:315-321`: `WlinkGenericFCSM.v`,`_1`..`_5` from `deps/axi-chiplet-controller/logical/wlink/` (**0 `socl_` recovery hooks each**); `_6` from `local_overrides` (130); `axi_chiplet_controller.sv` from `local_overrides` (:403). FPGA flists take all from `local_overrides` (72-73 `socl_` each).
- `tidelink_top.sv:2680-2681` (main) / `:3171-3172` (rev2): `.hexcl(1'b0)`, `.hmaster(12'd0)` on the outbound bridge → exclusives and master-id never cross the die. Comment at :2063 acknowledges awid=hmaster=0.
- `singles_burst <= ~hprot[3] || hexcl || hburst == BUR_INCR` lives in **XHB500 generated RTL** (`deps/xhb500/generated/.../xhb500_ahb_to_axi_bridge_chiplet_slv_core_addr.sv:147`), not TideLink — the non-singles arm is a vendor-IP path TideLink has never exercised.
- `docs/FALSE_GREEN_REGISTER.md` (rev2, 354 lines, 2026-08-26): ~49 false-green diagnostics; Tier 0 = nothing gated by CI on either forge; states `docs/TIDELINK_FPGA_VERIFICATION_PLAN.md:41-45` declares the sim_gate CI escape CLOSED when it is not.
- `rev2/hygiene` `38f362ee`: 0x21F8 bit[10] is hazard-list PRESSURE, not a deadlock witness → explains die_a `stall_stuck=1` on clean captures.

## Coordination log
- Peer `tidelink-23` (owner of rev2/*) is on both KR260s until 19:32Z root-causing TideChart election claims not crossing the die. We agreed: I review, do not touch boards or origin/main; I take the four unclaimed targets (unwired benches, .gitlab-ci jobs, UVM drivers/monitors, stall_stuck false-red). Peer asked that credential rotation be reported as an outstanding DECISION for David, not a task.

## Gate narrative CORRECTION (peer tidelink-23, 17:45)
- Attempt 1 (17:27) void: `set_env.sh` IS fail-closed and printed `[ERROR] CMSDK_DIR is not set` / `[ERROR] CMSDK_FPGA_SRAM_V is not set`; the peer's launcher ran `source ./set_env.sh >/dev/null 2>&1` and silenced it. Caller error, same discarded-stderr class as the sysval phantom-mismatch corpus. Log kept as `simgate-cba9774d.VOID-no-env.log`.
- Attempt 2 (17:31) void: `site.env` missing in fresh worktree (gitignored) + submodules uninitialised (race) + `dut_src_*.f` churn → `-dirty`.
- Attempt 3 (~17:40) GENUINE: launcher now prechecks env, CMSDK sram file, deps populated, xhb500 generated, submodule `-` prefix, clean tree. `t31_autonomous_training_exit PASS (280s)`. ~45 min to complete.
- `sim_gate_env_check` finding stands, narrower: checks `command -v vcs/cocotb-config` only; would catch "forgot to source" but not a silenced source. Fix should add: flist `${VAR}` resolution to existing paths, `git submodule status --recursive` no `-` prefix, clean tree at launch. Tag: "not on rev2, and should be" (peer will implement after the run — editing the Makefile during the run would dirty the tree and void the stamps).
- `dut_src_{1,3,5,7,9}.f` are TRACKED files regenerated by `$(shell echo ... > $(DUT_SRC_F))` at Makefile PARSE time — rewritten by any invocation incl. `make -n`. `--assume-unchanged` is per-clone, which is why it recurs. Real fix: untrack or write outside the tree.

