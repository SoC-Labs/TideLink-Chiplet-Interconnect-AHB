# TideLink ILA Placement Audit — Build #3 Debug

**Date:** 2026-05-29
**Repo HEAD:** `e72db73` on `feat/td-gpio-phy-integration` (prompt cited `dda0a0e`; working tree audited is `e72db73`).
**Insertion gate:** `FPGA_INSERT_DEBUG_CORE=1` env var → `fpga/build_design.tcl:289` sources `fpga/insert_debug_core.tcl` post-synth.

---

## 1. Executive summary

Current build instruments **link-layer and PTP-short-packet boundary nets** via `(* mark_debug *)` attributes auto-scraped into the post-synth `u_dbg_int` core. Coverage: Wlink LL_RX framer (state/ECC/decode), FCSM observability (state + sticky CR/CRACK on RX), PHC short-packet boundary at `tidelink_top`, PTP control gate in `tidelink_ptp`, slave `ShortPacketToWlink` rx_fifo handshake. Two Vivado-IP ILAs on `pynq-z2-pair-ila` (`ila_rx`/`ila_pad`) and `ila_tx` on `pynq-z2-pair-flip-ila` capture raw `pad_rx`/`pad_tx`.

**Gaps for live bugs:**
- Bug A: no visibility on `tidelink_fc_adapter` RX FSM, `fc_rx_fifo_*` valid/ready, `tl_fc_l2a_*` link interface, or FCSM TX-side CR/CRACK *emit* (only RX-seen sticky exists).
- Bug B: master HW_SYNC FSM (`hw_sync_trigger`, `tx_pending_r`, `tx_router_idle`) and master `ShortPacketToWlink` tx_fifo handshake unprobed; only `ptp_sp_tx_valid` is.
- Calibrator FSM (`tidelink_phy_align_calibrator.sv`): zero ILA probes.
- `pair_credit_counter` source path (build-#3 headline symptom): not probed.

Incremental work: ~20 `mark_debug` attrs + rebuild + redeploy + capture ≈ 75–105 min.

---

## 2. Current ILA inventory

### 2.1 Auto-scraped `u_dbg_int` core (FPGA_INSERT_DEBUG_CORE=1)

| Module (file:line) | Signals | Clock | Width |
|---|---|---|---|
| `tidelink_top.sv:505-512` | `ptp_sp_tx_valid/data_id/payload/ready`, `ptp_sp_rx_valid/data_id/payload/accept` | hclk | 1/8/16/1 x2 |
| `tidelink_ptp.sv:141-142` | `ptp_enable_r`, `ptp_rx_valid_r` | hclk | 1/1 |
| `local_overrides/Wlink.v:240-253` | `llrx_io_obs_state[1:0]`, `llrx_io_obs_is_short/long_pkt`, `llrx_io_obs_valid`, `tl2wl_io_obs_fcsm_state[2:0]`, `cr_pkt_seen_rx`, `crack_pkt_seen_rx`, `pkt_is_cr/crack_pkt` | rx_link_clk + io_tx_clk | 2/1/1/1/3/1/1/1/1 |
| `local_overrides/Wlink.v:1872-1899` | `swi_training_mode_rxsync_0/1`, `dbg_swi_training_mode_in`, `dbg_llrx_reset_out`, `dbg_framer_stuck` | apb_clk + rx_link_clk | 1 each |
| `local_overrides/WlinkRxLinkLayer.v:138-205` | `ecc_check_corrected_ph[23:0]`, `ecc_corrected`, `ecc_corrupted`, framer `state[1:0]`, `valid_byte_reg`, `corrected_ph[23:0]`, `is_short_pkt`, `is_long_pkt`, `is_short_pkt_prev`, `valid`, `word_count[15:0]`, `first_short_pkt_seen` | rx_link_clk | mixed |
| `deps/axi-chiplet-controller/.../ShortPacketToWlink.v:40-58` | `rx_fifo_io_winc/rinc/wfull/rempty`, `rx_accept`, `dataIdMatch`, `rx_pkt_valid` | hclk (rx side) | 1 each |

Core settings (`insert_debug_core.tcl:87-92`): `C_DATA_DEPTH=4096`, no trigger I/O, `INPUT_PIPE_STAGES=1`. `C_CLK_INPUT_FREQ_HZ` is auto-detected from `clk_wiz_0/clk_out1` period (25 MHz on pair-flip-all, 50 MHz elsewhere) and pushed onto `dbg_hub` to avoid the Vivado 2025.2 corrupted-waveform bug.

### 2.2 Explicit Vivado IP ILAs (BD-level, target-specific)

| Target | Instance | Clock | Probes |
|---|---|---|---|
| `pynq-z2-pair-ila/tidelink_design.tcl:331-345` | `ila_rx` | `pad_clk_rx` (recovered) | `{pad_clk_rx, pad_rx[7:0]}` 4096-deep |
| `pynq-z2-pair-ila/tidelink_design.tcl:348-361` | `ila_pad` | `clk_wiz_0/clk_out1` (50 MHz hclk) | `{pad_clk_rx, pad_rx[7:0]}` 4096-deep |
| `pynq-z2-pair-flip-ila/tidelink_design.tcl:324-337` | `ila_tx` | `clk_wiz_0/clk_out1` | `{pad_clk_tx, pad_tx[7:0]}` 4096-deep |

Default `pynq-z2-pair-all`/`pynq-z2-pair-flip-all` omit these IP ILAs (removed 2026-05-19, per `pair-all/tidelink_design.tcl:420-427`); they get `u_dbg_int` only.

### 2.3 Disabled probes

`Wlink.v:358-743` (`phy_link_tx_tx_link_data[127:0]`, `tx_lane_mask[7:0]`, `tidelinktl_tx_out_*`) and several `WlinkRxLinkLayer.v` per-lane byte regs are tagged `/* mark_debug-disabled */` due to dbg_hub noise.

---

## 3. Bug A — AHB packet RX returns empty: probe-set recommendation

Distinguish: (a) master FC TX never asserted, (b) crosses link but lost, (c) arrives at slave with wrong `pkt_type`, (d) accepted but FIFO writer back-pressured.

| Probe | RTL file:line | Clock | Width | Trigger / why |
|---|---|---|---|---|
| `tl_fc_a2l_valid` | `tidelink_top.sv:492` | hclk | 1 | rules out (a): master TX never asserts |
| `tl_fc_a2l_data` | `tidelink_top.sv:493` | hclk | 48 | top 2 bits = `pkt_type`; trigger `valid & pkt_type==PKT_FIFO_DATA` |
| `tl_fc_a2l_ready` | `tidelink_top.sv:494` | hclk | 1 | Wlink absorbed the word |
| `tl_fc_l2a_valid` | `tidelink_top.sv:495` | hclk | 1 | slave RX side — rules out (b) |
| `tl_fc_l2a_data` | `tidelink_top.sv:496` | hclk | 48 | decode `rx_pkt_type[47:46]`, `rx_addr_offset[45:32]` |
| `tl_fc_l2a_accept` | `tidelink_top.sv:497` | hclk | 1 | confirms fc_adapter accepted |
| `u_fc_adapter.rx_state_r` | `tidelink_fc_adapter.sv:422` | hclk | 2 | RX FSM stuck → IDLE = no accept, ADDR_PHASE = FIFO not ready |
| `u_fc_adapter.rx_pkt_type` | `tidelink_fc_adapter.sv:429` | hclk | 2 | scopes (c) vs (d) |
| `u_fc_adapter.rx_is_fifo` | `tidelink_fc_adapter.sv:434` | hclk | 1 | should pulse with every FIFO write |
| `fc_rx_fifo_valid` | `tidelink_fc_adapter.sv:508` | hclk | 1 | (d): writer asserts but FIFO refuses |
| `fc_rx_fifo_ready` | `tidelink_top.sv:602` | hclk | 1 | back-pressure from FIFO controller |
| `fc_rx_fifo_addr` | `tidelink_fc_adapter.sv:510` | hclk | 14 | confirm byte addr hits 0x44010000 aperture |
| FCSM TX sticky `cr_pkt_emit_tx` (new) | `local_overrides/Wlink.v` mirror of line 250 | io_tx_clk | 1 | covers Alt-3: did master ever EMIT a CR? Existing probes only cover RX-seen direction. |
| `pair_credit_counter[31:0]` and `pair_credit_counter_en` | `tidelink_apb_regs.sv:197-220` | pclk | 32+1 | live update pattern — actual change events instead of polled snapshots |

Trigger recipes:
- "Master TX seen but slave RX not seen" → independent captures on z2_02/z2_03, trigger `tl_fc_a2l_valid` master vs `tl_fc_l2a_valid` slave, compare via PPS timestamp.
- "RX accepts but FIFO drops" → `fc_rx_fifo_valid & ~fc_rx_fifo_ready` for ≥2 cycles.
- "RX mis-decodes" → `tl_fc_l2a_valid & rx_pkt_type!=2'b10` while master is provably driving FIFO_DATA.

---

## 4. Bug B — PTP HW_SYNC slave STATUS=0: probe-set recommendation

Distinguish: (a) master `ptp_sp_tx_valid` never asserts, (b) entered tx_fifo but never drained, (c) crossed but slave `rx_fifo_io_winc` never pulses, (d) winc pulses but PHC consumer doesn't drain. Existing probes cover (c) and parts of (d). Missing: master TX side and HW_SYNC FSM.

| Probe | RTL file:line | Clock | Width | Trigger / why |
|---|---|---|---|---|
| `hw_sync_trigger` | `tidelink_ptp.sv:156` | hclk | 1 | (a): does HW_SYNC FSM fire at all? |
| `tx_pending_r` | `tidelink_ptp.sv:168` | hclk | 1 | TX state held |
| `tx_router_idle` | `tidelink_top.sv:516` | hclk | 1 | gate that defers SYNC during long packets |
| Master `tx_fifo_io_wfull`, `tx_fifo_io_rempty`, `auto_tx_out_valid`, `auto_tx_out_ready` | mirror block at `ShortPacketToWlink.v` (TX side, near line 40 RX block) | hclk | 1 each | (b): SP-TX FIFO queues but never drains |
| `hw_seq_num_r[15:0]` | `tidelink_ptp.sv:157` | hclk | 16 | sequence number for matching M→S frames |
| `ptp_rx_msg_type_r[3:0]` | `tidelink_ptp.sv:143` | hclk | 4 | confirm SYNC vs DELAY_REQ decode at slave |
| `hw_sync_force_en_r` | `tidelink_ptp.sv:149` | hclk | 1 | shows whether `phc_locked_i` gate was bypassed |

Trigger recipes:
- (a) vs (b): trigger `hw_sync_trigger` rising edge with capture window covering next ~1024 cycles of `ptp_sp_tx_valid`.
- Slave drop: trigger `rx_fifo_io_winc & ~ptp_sp_rx_accept` — already capturable today with current probes.

---

## 5. Future-proofing probe set

| Area | Probes | RTL location | Domain | Why |
|---|---|---|---|---|
| Calibrator FSM | `cur_state[3:0]`, `sweep_active_o`, `calibration_done` | `tidelink_phy_align_calibrator.sv:436/477/647/1555` | hclk | Zero ILA today; APB shadow lags transient retries. Mandatory if f900e07 S_PROBE fix is suspect again. |
| Per-lane Hamming / lock | `lane_locked_o[7:0]`, internal Hamming reg | `deps/tidelink-gpio-phy/rtl/tidelink_lane_checker.sv:27` + `_single.sv` | recovered RX clk | Catches eye-margin collapse before APB lock-loss latches. |
| Pair credit counter delta | `pair_credit_counter[31:0]`, `_en` | `tidelink_apb_regs.sv:197-220` | pclk | Headline build-#3 symptom — see live update pattern, not snapshots. |
| Doorbell (known-good reference) | latched `rtn_fc_word[47:0]` + `tl_fc_a2l_valid` mask | `tidelink_fc_adapter.sv:240` | hclk | Doorbell works — keep mark_debug'd to compare against broken AHB-FIFO traffic. |
| TX arbiter | skid-buffer/select signals | `tidelink_fc_adapter.sv:352-398` | hclk | If returner sideband starves AHB-TX, the arbiter shows it. |
| LL_TX framer | re-enable `phy_link_tx_tx_link_data[127:0]` once dbg_hub noise mitigated | `Wlink.v:358` | tx_link_clk | Closes the loop FCSM emit → wire → recovered framer. |

---

## 6. Vivado gotchas (per `reference_insert_debug_core.md`)

1. **Bracketed net lookup** — `get_nets foo[0]` mangles; store net *objects* from the initial scrape (done at `insert_debug_core.tcl:38-49`).
2. **Core-name collision** — do not name a second core `u_ila_int` (internal scope inside `ila_rx`/`ila_pad`/`ila_tx`); use `u_dbg_int`.
3. **Clock-net hierarchy** — pick BD-level `clk_wiz_0/clk_out1` (fewest `/`); deeper IP-internal nets pass `connect_debug_port` but fail Chipscope DRC.
4. **`MAX_DATA_DEPTH` removed in Vivado 2025.2** — set once at IP creation (`4096`), unchangeable at HW Manager time.
5. **`CAPTURE_MODE` read-only in 2025.2** — use trigger conditions (DATA_AND_TRIGGER), not capture conditions.
6. **`wait_on_hw_ila` corrupts waveform** against auto-inserted dbg_hub — `phc_ila_capture.tcl` polls `STATUS.HW_ILA`; don't revert.
7. **Cross-clock-domain** — `u_dbg_int` is hclk-only. Probes from `rx_link_clk`/`io_tx_clk`/`tx_link_clk`/`pad_clk_rx` sample async (synth flags CDC — accept skew or false-path). New Bug-A/B probes on `tl_fc_a2l_*`/`tl_fc_l2a_*` are hclk-native.
8. **Stale `u_dbg_int` in synth_1 DCP** — auto-deleted (`insert_debug_core.tcl:80-83`); iterate without `reset_run synth_1`.
9. **`C_CLK_INPUT_FREQ_HZ`** auto-detected from clock period; verify when swapping to non-25/50 MHz target.

---

## 7. Build / deploy / capture estimate

| Step | Estimate |
|---|---|
| Add ~20 `mark_debug` attrs across `tidelink_top.sv`, `tidelink_fc_adapter.sv`, `tidelink_ptp.sv`, `local_overrides/Wlink.v` (TX FCSM mirror), `ShortPacketToWlink.v` (TX mirror) | 15–20 min |
| Sim-gate (`make sim_pair` cocotb on tidelink_top_pair) per `feedback_sim_gate_before_hw_deploy.md` | 6–8 min |
| Farm build pair (`make build_pair_farmed FPGA_INSERT_DEBUG_CORE=1`) — parallel master/slave | 50–60 min wall |
| Deploy to z2_02/z2_03 via fpgahub (lease granted, not queued) | 5 min |
| ILA capture pipeline via `pynq_host/scripts/phc_ila_capture.sh` on mapstone-dev | 10 min for 3 trigger profiles |
| **Total** | **≈85–105 min** sim-gated |

Best single-pass diagnostic: 3 simultaneous batch captures — (i) master `tl_fc_a2l_valid`, (ii) slave `tl_fc_l2a_valid`, (iii) master `hw_sync_trigger`. At 25 MHz × 4096 samples ≈ 164 µs window — covers the credit handshake round trip.

Notes: read-only audit, no code changes. Headline targets `pynq-z2-pair-all`/`pynq-z2-pair-flip-all` pick up `u_dbg_int` with the env flag; run `*-ila` variants in parallel for raw pin-domain capture if Bug A turns out PHY-level (unlikely given `LANE_STATUS=0x018900ff`). `.ltx` must be staged on mapstone-dev under `~/td_milestone_stage/` alongside `.bit`.
