# TideLink V2 — Staged Bottom-Up Bring-Up Plan (S0→S7)

> **Status:** design document, read-only. Repo: `/home/dam1n19/SoCLabs/tidelink`. Build target family: `pynq-z2-pair-all` (V2 requires `TIDELINK_PHY_V2=1`). Never touch `/research/AAA/**`.

## Rationale — why staged, why now

For months the integrated data-delivery failure was debugged the wrong way: deploy the *entire* stack, run a long SW recipe, then chase an **emergent** end-to-end symptom (no TX / NACK / credit exhaustion). That loop burned 100+ silicon rolls and a built-deployed-**falsified** reset-coherency fix, because every surrounding layer reported green and the one failing observable had no tap.

This session the bug was finally **mechanically localized in RTL** to **one layer, S5** — the `a2l` (app→link) replay FIFO's ACK-pointer clock-domain crossing:

- `a2l_full = (a2l_app_addr[4] != a2l_link_addr_app_clk[4]) & (a2l_app_addr[3:0] == a2l_link_addr_app_clk[3:0])` — `WlinkGenericFCReplayV2_13.v:54`.
- The synced ACK pointer `a2l_link_addr_app_clk` (from `WlinkGenericFCReplayAddrSync_18` → `WavMultibitSync_18`) sat a **full lap ahead** of the write pointer: `0b10001` vs `wptr=0b00000`.
- → `a2l_full=1` on the **first** write → `app_ready = ~a2l_full = 0` (`:94`) → `fifo_io_winc` never fires → FCSM send-gate `_T_59` starves → FCSM never leaves `LINK_IDLE` (state 4). No TX, ever.

Root cause is **reset-init coherency**, not a real ACK: `link_ack_update` (the only thing that advances `a2l_link_addr`, `:123`) is gated on `isAckPacket` only (`FCSM:1014`, `ack_nack_fifo_rdata[18:16]==3'h2`), and `ack_nack_fifo` is written **only** by ack/nack/exp traffic (`FCSM:999`) — **never** by CR(`0x44`)/CRACK(`0x45`). So the non-zero ACK at link-up is a stale latch in the AddrSync/MultibitSync ping-pong, and the CDC is **reset-asymmetric**: AddrSync `w_reset = link_reset` (=`wlink_por_reset = ~poresetn|~role_locked`), `r_reset = app_reset` (=`app_clk_reset = ~hresetn|~role_locked`) — `replay:115/119`.

**The gating gap that let this hide:** there is **no isolated test for S5**. Every env that touches this CDC is *integrated* (`tidelink_top_pair*`, HW deploy). A 50-line unit TB with asynchronous app/link clocks and a deliberate reset-skew adversarial vector would have caught it **in minutes**.

This plan rebuilds bring-up as a **ladder**: prove each component **at its interface, in isolation**, with a hard go/no-go gate and the instrumentation to *see* that gate, **before** stacking the next layer. It would have caught the ACK-pointer bug at the **S5 replay-FIFO-CDC stage** instead of as an S7 emergent symptom.

---

## The principle (applies to every stage)

1. **Prove at the interface boundary, in isolation.** A stage's gate exercises *only* that component's I/O contract — not the layers above it.
2. **A gate is BOTH a sim assertion AND a silicon OBS readback of the *same* observable.** Sim is the real proof (deterministic, minutes); silicon merely *confirms* the same value. Do not deploy S(n+1) until S(n) is green in both.
3. **Never proceed on a non-green stage.** A red sim stage is *never* carried onto a bitstream.
4. **Instrument every interface** so its state is observable — a sim assertion or an APB `0x4403_2xxx` OBS register, never "inferable in waves only" for anything that must be gated on silicon.
5. **Exit criterion is uniform: green-and-held.** The gate value must be *stable*, not a one-sample lottery roll (the marginal-eye link-up is a known lottery — a single pass is not an exit).
6. **Sufficiency caveats are part of the gate.** Per-lane `lane_locked` is a *per-lane-isolated* oracle — it passes on a cross-lane-incoherent link. Credit is a **VALUE** gate (`0x219C`), never a boolean (`0x2108[31]` only catches `==0`).
7. **Always verify `TIDELINK_PHY_V2=1`** (flist `flists/tidelink_fpga_v2.flist`) before any S1+ build. A silent-V1 fallback invalidates the entire PHY half of the ladder — this is a documented prior dead-link root cause.

---

## The stage ladder S0 → S7

Legend for the **Isolated test** column: **[EXISTS]** proven asset · **[PARTIAL]** asset exists but the *specific* gate assertion is missing · **[ADD]** must build.

### S0 — Clocking & reset tree + role_lock latch

| | |
|---|---|
| **Component & interface** | `clk_wiz` + reset fan-out + `role_lock` latch. Contract presented to every downstream block: `hclk(=apb_clk=app_clk)`, `link_clk = io_hsclk/16` (~4.7 MHz rig), `pad_clk_rx` (shared IBUFG→BUFG, `USE_CAP_CLKBUF=0`). Three reset nets: `apb_reset=~hresetn`, `app_clk_reset=~hresetn\|~role_locked` (`axi_chiplet_controller.sv:1732`), `wlink_por_reset=~poresetn\|~role_locked` (`:1730`). **The contract under test:** all three must DEASSERT on the SAME bring-up event (`role_lock` W1S) so the S5 replay FIFO's app-side and link-side pointers init coherently — the 2026-06-21 coherent-release fix (`:417/:1731`). |
| **Isolated test** | **[PARTIAL]** `cocotb/tidelink_v2_smoke` (`test_tidelink_v2_smoke.py` + `tb_top.sv`) — single `tidelink_top` on the V2 flist, APB-only, checks reset deasserts cleanly (no X on APB, `pready`/`pslverr` resolve). **[EXISTS]** `cocotb/tidelink_clkfreq_check` (freq cross-check, `freq_mismatch_sticky`) + `cocotb/tidelink_rxclk_buf` (`pad_clk_rx` passthru/optout, `USE_CLKBUF=0`). **[ADD]** one timing assertion to `tidelink_v2_smoke`: toggle `ROLE_CFG[1]` W1S and assert `wlink_por_reset` AND `app_clk_reset` both fall within ≤2 `hclk` of the SAME edge. (Optionally a sibling `cocotb/tidelink_reset_coherency` modeled on `tidelink_v2_smoke`.) |
| **GO / NO-GO gate** | **SIM:** `tidelink_v2_smoke` PASS (FAIL=0): `PHY_ALIGN_ID@0x211C == 0x5041_0100`; Region10@`0x2140` reads `0` & `pready=1`; `SWI_BIT_SLIP_LO@0x2104` write/readback clean; **no X** on any APB output post-reset. **ADD-assert:** `\|t(wlink_por_reset↓) − t(app_clk_reset↓)\| ≤ 2 hclk` after `ROLE_CFG[1]` W1S. `clkfreq`: matched 25 ns/25 ns → `freq_match=1`, `sticky=0`; 2:1 mismatch → `freq_mismatch_sticky=1`. `rxclk_buf`: `use_clkbuf==0` and passthru tracks `clk_i`. **SILICON:** after POR + `ROLE_CFG[1]=1` W1S, `ROLE_STATUS` shows `role_locked=1` and `PHY_ALIGN_ID@0x211C` reads `0x5041_0100` (not `0x`/timeout). |
| **Instrumentation** | **[EXISTS]** `PHY_ALIGN_ID` `0x211C` (liveness/identity); `ROLE_CFG/ROLE_STATUS` `0x2080[1]` W1S + readback; `freq_mismatch_sticky` in the clkfreq DUT. **[ADD] (sim-only)** bind probes on the `wlink_por_reset` / `app_clk_reset` / `apb_reset` deassert edges in `tb_top`. No new silicon tap needed (`role_locked` already in `ROLE_STATUS`); **the two reset-deassert edges are NOT silicon-observable — which is the load-bearing reason S5 must be provable one level up at the FIFO.** |
| **Exit criterion** | Smoke PASS **and** the reset-coincidence assertion PASS in sim; on silicon `role_locked=1` + APB responsive, held. Do not proceed until green. **S0 and S5 are co-developed** — the S5 replay-CDC TB is the natural place to *sweep* reset-deassert offsets and prove the coherent-reset fix actually fixes the pointer lap (it was falsified once at the integrated level). |

### S1 — Per-lane PHY bit serdes (WavD2DGpioTx/Rx ×8)

| | |
|---|---|
| **Component & interface** | `WavD2DGpioTx ×8` / `WavD2DGpioRx ×8` (`deps/tidelink-phy/rtl/wav`). 16b parallel word in (TX link-clk) → serial `io_pad_tx[N]`; `io_pad_rx[N]` → deserialize (`io_phase_offset` sub-bit, `io_bit_slip` post-capture rotation, word-pin window, lane-0 /16 clock forward) → 16b word out. **ONE lane at a time, no cross-lane coupling.** |
| **Isolated test** | **[EXISTS]** `cocotb/wav_d2d_gpio_tx` (TX leaf); `cocotb/wavd2d_gpiorx_clkbuf` + `wavd2d_gpiorx_t3a/_off/_timeout` (RX leaf variants); `deps/tidelink-phy/cocotb/lane_checker_single` (`test_lock_acquisition`/`test_threshold_sweep`/`test_noise_metrics`/`test_vote_behavior`/`test_wiring_discriminator`/`test_canary`) + `lane_checker_8lane` (`test_concurrent_lock`/`test_lane_swap`); `cocotb/tidelink_idelay_rx` (`test_idelay_optout_passthrough`); `phy_bist tb_oddr_capture_edge.sv` / `tb_rx_word_capture_skew.sv` / `tb_rx_clk_glitch.sv`. **Standalone FPGA isolator [EXISTS]:** `deps/tidelink-phy/fpga/targets/pynq-z2-phy-bist-pair(-flip)` (PRBS-15 BIST, cocotb 5/5 green, runs on z2_02/03 ribbon WITHOUT link/FC stack). |
| **GO / NO-GO gate** | **SIM:** `wav_d2d_gpio_tx` + `wavd2d_gpiorx_clkbuf` PASS (FAIL=0); `lane_checker_single` locks (per-lane `link_up=1`, `ERR_CNT==0`) across the (slip×phase) grid; `idelay` opt-out path bit-exact passthrough. **SILICON (phy-bist-pair bitstream):** per-lane PRBS-15 BIST = `lane_locked` set + `BER==0` (`ERR_CNT==0`) on each active lane of mask `0xe4`; KNOWN-GOOD = die_a solid 8/8 @6.25 / die_b 8/8 @25. |
| **Instrumentation** | **[EXISTS]** per-lane `lane_locked` + `ERR_CNT` in the phy-bist register block; in the full design `SWI_LANE_STATUS 0x2108[7:0]` lane_locked, `[15:8]` fault, `[16]` cal_done. |
| **Exit criterion** | All active lanes locked + BER=0, held. **CAVEAT baked into the gate:** `lane_locked` is a **per-lane-isolated** oracle — it passes on a cross-lane-incoherent link (each lane self-syncs at any whole-word lag). **S1 green is necessary but NOT sufficient for link coherence — that is S2/S3's job. Never accept S1-green as link-coherent.** Also note the phy_bist crossover is **ideal zero-skew** (README: "does not yet model per-lane skew/phase or bit errors") — calibrator *recovery-under-impairment* is exercised only by `phy_pair_serdes`/`phy_rx_deskew` (sim) and on real silicon. |

### S2 — Cross-lane word deskew (tidelink_lane_deskew.sv)

| | |
|---|---|
| **Component & interface** | `tidelink_lane_deskew.sv` (`LANES=8, WIDTH=16, DEPTH_LOG=5, EPOCH_ANCHOR_EN=1, EPOCH_MATCH_THRESH=5`). 8 phase-skewed per-lane 16b streams (each in its `gpiorx_N` clock) → ONE coherent `deskew_aligned_data[127:0]` on `gpiorx_0` clock. Proves occupancy deskew (`all_primed≥PRIME_THRESH=5`, `all_ready` gate) AND the content-only EPOCH anchor (Hamming-streak training-exit → backward read offsets, `span≤EPOCH_OFF_MAX=24`). **The V2 core; the historical cross-lane-incoherence blind spot.** |
| **Isolated test** | **[EXISTS]** `cocotb/tidelink_lane_deskew` (`test_lane_deskew.py` + `test_lane_deskew_mask.py`, `tb_deskew.sv`) — direct unit DUT with injected per-lane word-skew; `cocotb/tidelink_deskew_bubble` (`test_deskew_bubble.py` — the duplicate-bubble regression); `cocotb/tidelink_top_pair_wordskew` (injects per-lane word skew at the pair level); `deps/tidelink-phy/cocotb/phy_rx_deskew` (`test_deskew.py` / `test_deskew_epoch.py` / `tb_deskew_epoch.sv`) — epoch-anchor unit; `phy_bist tb_deskew_selfheal.sv` / `tb_counter_cdc.sv` / `tb_cdc_tear.sv` (the Gray write-ptr CDC into `out_clk`). **Best-covered layer in the stack.** |
| **GO / NO-GO gate** | **SIM:** `tidelink_lane_deskew` PASS (FAIL=0) incl. mask variant; `phy_rx_deskew::test_deskew_epoch` asserts `epoch_anchored_o=1` and `epoch_span_o≤24` under injected word-skew, AND the recovered 128b word is **byte-identical** to the injected word (the cross-lane coherence assertion). **NEGATIVE CONTROL required:** with `EPOCH_ANCHOR_EN=0` the same word-skew vector must FAIL — proves the test detects incoherence, not merely lane lock. **SILICON:** `SWI_EPOCH_STATUS 0x2140[0]=epoch_anchored=1`, `[6:1]=epoch_span≤24`, held stable; `0x2114[31:16]` sync_detected sat-count climbs. |
| **Instrumentation** | **[EXISTS]** `epoch_anchored_o`/`epoch_span_o` ports; `SWI_EPOCH_STATUS 0x2140`; `SYNC_DET/ECC 0x2114[31:16]` sync_detected saturating-cnt (coherent-deskew health proxy); `0x2144` live SYNC oracle. The **cross-lane oracle on silicon is the SYNC beacon (S3)** — epoch alone says "anchored", `sync_seen_cnt>0` proves the 128b bus is *actually* coherent. |
| **Exit criterion** | Byte-identical recovered word in sim **with the negative control failing**, `epoch_anchored` + `span≤24` held on silicon. Do not proceed. |

### S3 — SYNC / framing / eye-centre

| | |
|---|---|
| **Component & interface** | `tidelink_phy_sync_insert` (TX beacon) + `tidelink_phy_sync_detect` (mask-aware RX, post-deskew 128b equality, Hamming tol) + byte/word-phase alignment + `tidelink_phy_align_calibrator` (per-lane (slip×phase) eye-centre FSM: asserts `training_mode`, sweeps the 128-pt grid, releases). Post-deskew 128b word → (a) SYNC-beacon equality across masked-in lanes = the cross-lane coherence proof, (b) per-lane eye centre → `bit_slip[23:0]`/`phase_offset[31:0]`, `training_mode` released. |
| **Isolated test** | **[EXISTS]** `phy_bist tb_tx_sync_insert.sv` + `tb_rx_sync_detect.sv` (`test_rx_sync_detect`) + `tb_sync_word.sv` + `tb_word_pin_seam.sv` + `tb_beacon_kill.sv` + `test_phy_reanchor_transition.py`; calibrator `tb_cal_*eyescan.sv ×6` (eye-centre, multilane converge, reduced-mask, arm/recover, pin-skew, precedence); **the definitive cross-lane gate** `deps/tidelink-phy/cocotb/phy_pair_serdes::test_phy_pair_epoch.py` (real-SerDes pair, oracle = `sync_seen_cnt>0` under word-epoch skew, with a documented negative control). In the full design: `cocotb/tidelink_phy_align_calibrator` (`test_calibrator`/`_centering`/`_s_probe_skip`) + `cocotb/tidelink_eye_regs`. |
| **GO / NO-GO gate** | **SIM:** `sync_insert` overrides one idle word every `SYNC_PERIOD=32`, default-off = passthrough; `sync_detect` fires on full-128 `SYNC_WORD` (mask-aware, tol5) — `sync_seen_cnt` advances; under un-anchored skew `sync_seen_cnt==0` (negative control); `phy_pair_serdes::test_phy_pair_epoch` asserts `sync_seen_cnt>0` on the skewed die while `link_up`/PRBS green; calibrator selects an eye of **width≥2** on the marginal lane. **SILICON:** with `R8(0x2100)=0x1D` (train+sync_insert+force_always+robust_detect), `SYNC_DET 0x2114[31:16]` saturating; `cal_done 0x2108[16]=1`; eye-width `0x2150 ≥2`; SYNC mask `0x2128=0x5e4`. |
| **Instrumentation** | **[EXISTS]** `SYNC_DET/ECC 0x2114`; SYNC bank `0x2128` (mask+tol); live SYNC oracle `0x2144` (LIVEMATCH per-lane); eye-width `0x2150`/`0x2154` (sel/lane); `cal_done 0x2108[16]`; `R8 0x2100` SWI_TRAINING_MODE `[0..5]` (insert/force/robust/recal). |
| **Exit criterion** | `sync_seen_cnt>0` + `cal_done=1` + eye≥2, held, **with the un-anchored negative control producing `sync_seen_cnt==0`.** This is the layer that *certifies cross-lane coherence* — do not proceed without it. |

### S4 — Link-up CR/CRACK + credit handshake (WlinkGenericFCSM_6)

| | |
|---|---|
| **Component & interface** | Wlink `WlinkGenericFCSM_6` (8-state FSM). Coherent 128b link in/out → FSM walks reset→emit-CR(`0x44`)→emit-CRACK(`0x45`)→`LINK_IDLE`(state 4); CR/CRACK carry `word_count=0x1f1f` which LOADS `fe_tx/rx_credit_max` (`FCSM:498/675`). Proves bilateral link-up AND a **correct credit decode** — not just `cr_seen/crack_seen`, but `credit_max` *value* sane. **Upstream of, and independent from, the app→link send path (S5).** |
| **Isolated test** | **[EXISTS] (rich, integrated):** `cocotb/debug/wlink_pair` — two full `Wlink.v` cross-wired via `pad_skid`: `test_link_bringup`, `test_assert_bringup`, `test_credit_handshake_end_to_end.py`, `test_asymmetric_rx_credit_block_recovery.py`, `test_fcsm_io_rx_reset_sticky.py`, `test_13_ack_drop_recovery`, `test_asymmetric_failure_fuzz`, `test_hw_regression_gates`; `cocotb/tidelink_top_pair` deterministic bring-up chain. **NOTE:** `wlink_pair` wraps the WHOLE Wlink (link+phy-skid + **replay FIFOs in the integrated path**) — it proves CR/CRACK+credit at the FCSM boundary but **NOT the replay-FIFO CDC in isolation**, reinforcing that S5 needs its own env. **[ADD] if S4 regresses with S0-S3 green:** a thin two-`WlinkGenericFCSM_6`-back-to-back env on an ideal link (no PHY) to gate credit-decode pre-silicon. |
| **GO / NO-GO gate** | **SIM:** `make sim-repro` PASS (`test_assert_bringup`: both FCSM reach state 4; `test_hw_regression_gates` green); `credit_max` decoded == expected `0x1f`-class, **not** small-nonzero garble. **SILICON:** `SWI_LANE_STATUS 0x2108[23] cr_seen=1`, `[24] crack_seen=1`, `[19:17] fcsm_state==4` **BILATERALLY**; `OBS_FC_CREDIT 0x219C[7:0] fe_rx_credit_max` sane **by VALUE**. |
| **Instrumentation** | **[EXISTS]** `SWI_LANE_STATUS 0x2108` (`cr_seen[23]`, `crack_seen[24]`, `fcsm_state[19:17]`, `llrx_state[22:21]`); `OBS_FC_CREDIT 0x219C[7:0]` credit_max + `[31:24]=0xFC` presence marker. **GATE RULE:** credit must be read at `0x219C` **by VALUE** — `0x2108[31] fe_rx_is_full` only catches `credit==0`. The ~40% credit-garble lottery decodes to small-nonzero (passes `0x2108[31]==0`, exhausts after 1–4 pkts) and is invisible to the boolean. |
| **Exit criterion** | Bilateral `fcsm_state=4` + `cr_seen`+`crack_seen` + `credit_max` sane-by-value, held. Do not proceed. |

### S5 — App↔link CDC / a2l (and l2a) REPLAY FIFO — **THE GAP / THE CURRENT BUG**

| | |
|---|---|
| **Component & interface** | `WlinkGenericFCReplayV2_13` (a2l, app→link, WITH revert) + `WlinkGenericFCReplayV2_12` (l2a, link→app, no revert), each = `WavFIFO_20` + `WlinkGenericFCReplayAddrSync_18` (Gray ACK-pointer CDC via `WavMultibitSync_18`). **Boundary (THE BUG SITE):** app_clk(`hclk`) write side vs link_clk read side, joined **only** by the synced ACK pointer. Ports are clean and standalone: `app_clk/app_reset/app_enable/app_data/app_valid/app_ready` + `link_clk/link_reset/link_ack_update/link_ack_addr/link_revert/link_advance/link_valid/link_empty/link_cur_addr`. **Exact failure:** synced ACK ptr `a2l_link_addr_app_clk = 0b10001` a full lap ahead of `wptr=0b00000` → `a2l_full=1` (`:54`) on the first write → `app_ready=~a2l_full=0` (`:94`) → `fifo_io_winc` never fires → FCSM send-gate `_T_59` starves → no TX. Reset-init artifact, **not** an ACK (CR/CRACK don't advance the ptr; reset is asymmetric `w_reset=link_reset`, `r_reset=app_reset`, `:115/:119`). |
| **Isolated test** | **[ADD] — first-class new stage, THE reason this ladder exists.** `cocotb/tidelink_a2l_replay_cdc` (model after `cocotb/tidelink_fifo`: `SIM=vcs`, `tb_top.sv` instantiates `WlinkGenericFCReplayV2_13` standalone, own flist). Drive **independent** app_clk/link_clk (e.g. `hclk` vs `hclk/16`) + **independently-skewed** `app_reset(=app_clk_reset)` / `link_reset(=wlink_por_reset)` deassertion. **Phase 1 = reset-only (NO ack/nack traffic).** **Phase 2 = app writes + link ACKs + revert.** Add `WlinkGenericFCReplayV2_12` (l2a) as a sibling TOPLEVEL. Reuse the `phy_bist tb_counter_cdc.sv` / `tb_cdc_tear.sv` Gray-ptr CDC harness style. **(Red-herring envs to ignore:** `cocotb/tidelink_fifo` = plain `tidelink_fifo_mem` sync RAM; `cocotb/tidelink_phc_cdc` = PHC crossing; `phy_bist tb_counter_cdc/tb_cdc_tear` = PHY capture-counter Gray CDC — none elaborate the replay AddrSync.) |
| **GO / NO-GO gate** | **SIM — PHASE 1 (reset coherency, the actual bug):** after both resets deassert at **all** relative skews (sweep 0..N link_clk), assert `a2l_link_addr_app_clk==0 && fifo_io_wbin_ptr==0 && a2l_full==0 && app_ready==1` for ≥64 app_clk with **zero** link traffic. **SIM — PHASE 2 (functional):** every cycle assert lap-aware `synced_ack ≤ wptr` — i.e. NEVER `(ack[4]!=wptr[4] && ack[3:0]==wptr[3:0])` *unless* genuinely 32-deep full; first `app_valid` with `app_ready=1` produces `fifo_io_winc` and advances `wbin_ptr`; a single link ACK of addr K advances `a2l_link_addr` to K within bounded sync latency; `link_revert` rewinds read ptr without corrupting `app_ready`. **ADVERSARIAL (negative control):** force AddrSync reset to deassert LATER than app reset — must **FAIL on pre-fix RTL** and **PASS post-fix**. **SILICON:** after POR **before any link traffic**, extended `0x2158` shows `wptr-field==0 && synced-ack-field==0`; after the first AHB_TX write, `0x2158[0] app_ready==1` and `[1] link_empty` transitions `1→0` (marker `0xA2` present so the read is trusted). |
| **Instrumentation** | **[EXISTS] for the EFFECT (just wired 2026-06-21):** `OBS_A2L 0x2158 [0]=a2l_replay_app_ready`, `[1]=a2l_replay_link_empty`, marker `0xA2` — fans out FCSM `io_obs_a2l_replay_app_ready/link_empty` (`WlinkGenericFCSM_6.v:265-266,971-972`; `tidelink_top.sv:1058` decode); plus `SWI_LANE_STATUS 0x2108[30]=a2l_fc_replay_link_valid`, `[31]=fe_rx_is_full`. **[ADD] for the CAUSE — the single most valuable new tap in the whole ladder:** bits `[23:2]` of `0x2158` are spare (`ctrl_reg_addr==3'h6`, `axi_chiplet_controller.sv:1542`). Add FCSM obs ports `io_obs_a2l_app_addr[4:0]` + `io_obs_a2l_link_addr_appclk[4:0]` (FCSM exposes neither today — only `app_ready/link_empty/link_valid`, `:265/:266/:248`), 2-flop sync into `apb_clk`, pack `0x2158[6:2]=wptr`, `[11:7]=synced_ack`. This makes the "ACK ptr a full lap ahead of wptr" signature (`0b10001` vs `0b00000`) **directly readable on silicon**, not inferred from waves. |
| **Exit criterion** | Phase-1 reset-skew sweep green at **all** offsets **and** the adversarial control fails-on-pre-fix/passes-on-fix in sim; **then** the silicon post-POR `0x2158` read shows both pointer fields `==0`. Only then is S5 green. (`app_ready=0` alone cannot distinguish skid-empty vs false-full vs real credit-exhaustion — this is exactly why the raw-pointer tap is load-bearing.) |

### S6 — FC adapter / packetization (tidelink_fc_adapter.sv)

| | |
|---|---|
| **Component & interface** | `tidelink_fc_adapter.sv`. **TX:** AHB-Lite write (`0x8400_0000`) → 48b FC word `{pkt_type, addr_offset, data}` → arbiter(returner>servo>TX) → 1-entry skid → `tl_fc_a2l_valid/data/ready` into S5. **RX:** 3-state FSM, `tl_fc_l2a_valid` 48b word → single-cycle direct `fc_rx_fifo_*` write (FIFO_DATA `00`) / SIDEBAND APB (`01`) / PKT_EXT TideChart (`10`). |
| **Isolated test** | **[EXISTS]** `cocotb/tidelink_fc_adapter` (`test_tidelink_fc_adapter.py` — AHB↔FC mapping + skid; `test_rx_pkt_type_decode.py` — `00` vs `01` classify + aliasing guards; `test_buga.py` + `Makefile.buga` — the removed wedge-watchdog regression); `cocotb/tidelink_fifo` (RX FIFO RAM commit target); `cocotb/tidelink_returner`, `cocotb/tidelink_apb_addr_ctrl`. |
| **GO / NO-GO gate** | **SIM:** PASS (FAIL=0). reset: `a2l_valid=0`, `fc_rx_fifo_valid=0`, `hreadyout=1` (no wedge). TX: AHB write → correct 48b `{00, addr_offset, data}` on `tl_fc_a2l_valid` with skid back-pressure honest (`skid_can_accept=~skid_valid_r\|tl_fc_a2l_ready`, `sv:469`), terminating with AHB **ERROR** (2-cy) after `TX_STALL_TIMEOUT_LOG2=16` and `tx_dropped_cnt_r==0` (no silent beat-drop). RX: type `00` → single-cycle `fc_rx_fifo` write at `addr_offset`; type `01` → APB `psel` only; no SIDEBAND↔FIFO aliasing on back-to-back. **SILICON:** drive one AHB_TX write; confirm via `0x2158[0] app_ready` that the adapter handed off, `0x2108[30] a2l_fc_replay_link_valid=1` (a word reached the link side), and `tx_dropped_cnt` reads `0`. |
| **Instrumentation** | **[EXISTS]** DUT `tl_fc_a2l_valid/data`, `fc_rx_fifo_valid`, `fc_rx_cfg_psel`; `SWI_LANE_STATUS 0x2108[30]` a2l_fc_replay_link_valid, `[20] a2l_replay_app_valid` (skid presents word); `tx_dropped_cnt_r` RO. **Pairs with S5's `0x2158`** to localize *app-stuck* (`0x2158[0]=0`) vs *crossed-but-stalled* (`0x2158[1]` stuck). |
| **Exit criterion** | All adapter asserts PASS; on silicon a single write produces `link_valid=1` with `tx_dropped_cnt=0`. Do not proceed. |

### S7 — End-to-end data (host AHB_TX → peer RX FIFO)

| | |
|---|---|
| **Component & interface** | Host AHB_TX (GP1 `0x8400_0000`) → `fc_adapter` → a2l → FCSM send-gate → lltx → PHY TX → wire → peer PHY RX → deskew → llrx → l2a → peer `fc_adapter` RX → peer RX FIFO (`0x8401_0000`), **byte-correct**. The full integrated chiplet pair; **only stacked once S0-S6 are each independently green.** |
| **Isolated test** | **[PARTIAL]** `cocotb/tidelink_top_pair_v2` — the v38 paired-V2 pre-silicon gate (`make sim-regression-v2` → `v2_gate`): `test_v2_pair_b2b` (test_04 M→S / test_05 S→M byte-correct burst), `test_v2_fc_contiguous.py`, `test_v2_pair_data.py`, `test_v2_reduced_lane.py` (mask `0xe4`), `test_v2_marginal_eye.py`, `test_v2_sync_insert_en.py`, `test_v2_eye_width_obs`, `test_v2_pair_epoch_negctl.py` (negative control), with `EPOCH_PROFILE=zero/staircase/silicon`; plus single-die `cocotb/tidelink_top::test_01` (fifo-data loopback byte-correct). **Silicon:** `deploy_pair.sh` + the proven recipe. **GAP it exposes:** S7 passes in sim but the S5 CDC bug manifests only on silicon (real async reset offsets) — **so S7 sim-green ≠ silicon-green until S5 has its own gate.** |
| **GO / NO-GO gate** | **SIM:** `make sim-regression-v2` PASS (`v2_gate` green) — zero/staircase/silicon profiles 3/3 (link-up + M→S + S→M byte-correct), 4-pkt AHB_TX burst lands byte-perfect (`hdr=0x0024_0000`, `p0=0xDA7A_0000` class); negative-control (anchor off) 1/1 = defect detected (rx all-zeros). **SILICON:** host AHB write at `0x8400_0000` → readback at peer `0x8401_0000` byte-identical; preceded by `0x2108 fcsm_state=4` bilateral + `0x2158 app_ready=1` + `0x219C` credit sane; `fe_rx_full(0x2108[31])=0` stays clear; credit not exhausted after >4 pkts (`0x219C` value stable). |
| **Instrumentation** | **[EXISTS]** full OBS chain (all 2-flop synced to `apb_clk`): `0x2108` (send-gates `[30]` link_valid, `[31]` is_full), `0x2158` OBS_A2L, `0x219C` OBS_FC_CREDIT, `0x2140` EPOCH, `0x2114` SYNC, `0x2150/4` eye. End-to-end correctness oracle = byte-compare of the RX FIFO readback aperture. |
| **Exit criterion** | Byte-perfect peer readback, held over a multi-packet burst with credit stable. **This is the emergent-symptom layer the ladder exists to STOP debugging at** — by construction it is only entered with S0-S6 green. |

---

## Current state vs the ladder

| Stage | State | Notes |
|---|---|---|
| **S0** | **Green-ish, gap** | `tidelink_v2_smoke` proves no-X / APB-alive, but **no assertion that `wlink_por_reset` and `app_clk_reset` deassert together** — the precondition the S5 fix depends on. The 2026-06-21 coherent-release fix has **no unit gate**; it can only be validated transitively through S5 (and was falsified once at the integrated level). |
| **S1** | **Green** | phy-bist bilateral 8/8 silicon-validated; per-lane lock + BER=0. (Coherence-insufficient by design.) |
| **S2** | **Green** | Best-covered layer; `epoch_anchored` + `span≤24` with byte-identical recovered word; silicon `0x2140`. |
| **S3** | **Green** | `cal_done=1`, `sync_seen_cnt>0` with negative control; silicon recipe `R8=0x1D` + mask `0x5e4`. |
| **S4** | **Green (bilateral link-up)** | `fcsm_state=4` + cr/crack bilateral on z2_01/z2_02 silicon (the 2026-06-20 bilateral link-up). Credit-decode lottery is a known soft spot — gate on `0x219C` VALUE. |
| **S5** | **RED — the bug lives here** | **No isolated test exists.** Synced ACK ptr a full lap ahead of wptr → false-full → `app_ready=0` → FCSM never sends. Localized this session via the new `0x2158` tap; CAUSE still wave-only (no raw-pointer register yet). |
| **S6** | **Green** | `tidelink_fc_adapter` asserts pass; skid honest; `tx_dropped_cnt=0`. |
| **S7** | **Sim-green, silicon-blocked by S5** | `v2_gate` passes in sim; silicon end-to-end blocked because S5's reset-init CDC fault only manifests under real async reset offsets. |

**THE GAP, restated:** every stage S0–S4, S6, S7 has at least a partial isolated test. **S5 has none.** That is precisely why the ACK-pointer bug survived 100+ integrated rolls — `S1 lane_locked`, `S2 epoch`, `S3 sync`, `S4 cr/crack` were all GREEN, and the only failing observable (`app_ready`) had no tap until `0x2158` was wired this session. **S0 (reset coherency)** is the secondary gap and must be **co-developed with S5** — the S5 replay-CDC TB is the natural place to sweep reset-deassert offsets and *prove* the coherent-reset fix actually closes the pointer lap.

---

## Immediate next actions — isolate + fix the S5 ACK-pointer bug

Sequenced, sim-first, paying the plan off now.

1. **ADD the S5 unit env `cocotb/tidelink_a2l_replay_cdc`** (~1–2 h, **no FPGA build**). Model after `cocotb/tidelink_fifo` (`SIM=vcs`, `tb_top.sv` instantiates `WlinkGenericFCReplayV2_13` standalone + own flist). Independent app_clk/link_clk; independently-skewed `app_reset`/`link_reset` deassertion. **Run PHASE-1 reset-skew sweep FIRST:**
   - GATE: after both resets deassert at all relative skews, `a2l_link_addr_app_clk==0 && fifo_io_wbin_ptr==0 && a2l_full==0 && app_ready==1` for ≥64 app_clk with **zero** link traffic.
   - If this reproduces `ack!=0` with `wptr=0`, the bug is **PROVEN reset-init (CDC)**, not ACK-driven — definitively confirming the CR/CRACK-don't-advance-the-ptr code-read — and is fixable + gatable **entirely in sim before any 18–20 min/die FPGA roll.**
   - Then run **PHASE-2** (writes + ACKs + revert) with the per-cycle lap-aware `synced_ack ≤ wptr` assertion, and the **adversarial negative control** that must FAIL on pre-fix RTL and PASS on the fix.

2. **IN PARALLEL, extend the OBS_A2L silicon tap (the CAUSE tap).** Add FCSM obs ports `io_obs_a2l_app_addr[4:0]` + `io_obs_a2l_link_addr_appclk[4:0]`, 2-flop sync into `apb_clk`, pack into the spare `0x2158[11:2]` (`[6:2]=wptr`, `[11:7]=synced_ack`; marker `0xA2` retained, decode `ctrl_reg_addr==3'h6` at `axi_chiplet_controller.sv:1542`). This surfaces the `0b10001`-vs-`0b00000` signature directly on silicon.

3. **Add the S0 reset-coincidence assertion** to `tidelink_v2_smoke` (or sibling `tidelink_reset_coherency`): after `ROLE_CFG[1]` W1S, `|t(wlink_por_reset↓) − t(app_clk_reset↓)| ≤ 2 hclk`. Co-developed with step 1's reset-skew sweep — the same vector that proves S5 also proves the S0 fix.

4. **Develop + gate the fix in sim.** Land the reset-coherency / AddrSync-init fix only when S5 Phase-1 sweep is green at **all** offsets **and** the adversarial control passes post-fix. (The prior integrated-level fix was falsified — do not trust an integrated PASS as the S5 gate.)

5. **Rebuild ONE die with V2 explicit** — `make build_design TARGET=pynq-z2-pair-all TIDELINK_PHY_V2=1` (~18–20 min). **VERIFY the define** (silent-V1 fallback is a documented dead-link cause). Deploy via `deploy_pair.sh` on a **GRANTED** fpgahub lease (verify "granted", not "queued").

6. **Silicon confirmation read — BEFORE any link/training recipe.** Immediately after POR, read extended `0x2158`:
   - **GO/NO-GO:** `wptr-field==0 && synced-ack-field==0`.
   - A non-zero synced-ack with zero wptr **CONFIRMS reset-init root cause** and rules out CR/CRACK-advance on silicon.
   - With the fix in place, both fields read `0` post-POR → S5 silicon gate green.

7. **Only after S5 is green (sim Phase-1+2 AND the `0x2158` HW read)** re-run the full S7 link-up recipe: POR → autonomy-off (`0x210C=0`) → mask `0xe4e4` → per-lane-AUTO word-pin (`0x104=0`) → SYNC mask+tol5 (`0x128=0x5e4`) → `R8=0x1D` → recal, dwell ~18 s; then host AHB write `0x8400_0000` → byte-compare peer `0x8401_0000`.

---

## Tooling note

- **Sim-first, always.** cocotb gates run in **minutes** (`make MODULE=… SIM=vcs`); they are the *real* proof. The FPGA build is **~18–20 min/die** (IP cache + jobs8); a paired silicon roll + recipe + dwell (~18 s) is far longer and **lottery-prone** (marginal-eye). The discipline: **exhaust the sim gate of a stage, then confirm the SAME observable on silicon, then and only then stack S(n+1).** A red sim stage is **never** carried onto a bitstream.
- **Lease per-use.** Deploy to bridge1 via `deploy_pair.sh` on `mapstone-dev`; verify the fpgahub lease is **granted** before deploy; `pkill -9` the whole deploy tree on teardown (parent-only kill leaves orphans). HW deploy + ILA capture to bridge1 is pre-authorized.
- **Build the right PHY.** Verify `TIDELINK_PHY_V2=1` / `flists/tidelink_fpga_v2.flist` before every S1+ build — a silent-V1 fallback invalidates the entire PHY half of the ladder.
- **Worktrees** under `/home/dam1n19/SoCLabs/td-bisect/<exp>/`, never `/tmp` (10 GB, fills with Vivado + sub trees).
