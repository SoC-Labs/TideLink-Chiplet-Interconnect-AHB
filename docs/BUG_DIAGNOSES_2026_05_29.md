# Bug Diagnoses 2026-05-29 — Build #3 silicon validation

**Branch:** `feat/td-gpio-phy-integration` HEAD `dda0a0e`. PHY converges 16/16; calibrator Fix A2+B silicon-validated. Two new gaps surface: (A) AHB packet RX empty at slave, (B) PTP SYNC RX never observed at slave. Doorbell M→S works in both directions; `REG_DOORBELL_RESP_ACC` bumps by 0x5000 per master AHB write — proof that the **FC sideband channel** delivers packets through the link.

---

## Key data-path facts (read out of RTL, falsifies several stale hypotheses)

- **Three independent FC channels** carry payload between dies, each with its own router slot and module:
  1. **TideLink FC node** (`tl2wl`, data_id≈0xa1) — AHB packets + returner sideband. 48-bit packed. `tidelink_fc_adapter.sv` packs `pkt_type[47:46]` (00=FIFO_DATA, 01=SIDEBAND, 10=EXT) + `addr_offset[45:32]` + `payload[31:0]`. Has built-in skid buffer + arbiter, but **no application-level credit gate on TX** (only Wlink CR/CRACK at link layer, which is already converged per `cal_done=1`). `PAIR_CREDIT_COUNTER` (APB 0x028) is purely SW observability, not a TX gate (confirmed: `tidelink_apb_regs.sv:321-347` driven only by APB writes to 0x028/0x02C).
  2. **ShortPacketToWlink** (`sp2wl`, data_ids 0x50=SYNC, 0x51=DELAY_REQ) — PTP. Carries 16-bit payload per packet. Has NO credit logic, just `tx_fifo` + `rx_fifo` (`ShortPacketToWlink.v:81-92`). **RX hard-filter at line 57: `dataIdMatch = (data_id==0x50)|(data_id==0x51)`**. `rx_fifo_io_winc = rx_pkt_valid & ~rx_fifo_io_wfull`. `rx_fifo` drains only via `rx_accept = bore_2[0]` driven by `tidelink_ptp.rx_accept = ptp_sp_rx_valid & ptp_enable_r` (`tidelink_ptp.sv:288`).
  3. **AXI initiator (`m_axi`) + AXI target (`s_axi`)** — XHB500 bridged. Carries remote-read/write AXI bursts. Not used by the AHB-packet path (which is FIFO_DATA over `tl_fc`).

- **Slave AHB packet RX path** (FIFO_DATA): `tl_fc_l2a_data` → `tidelink_fc_adapter.sv` RX FSM (line 422) → if `rx_pkt_type==PKT_FIFO_DATA` it drives `fc_rx_fifo_{valid,addr,wdata}` (line 508-511) → `tidelink_fifo_ctrl.fc_write_valid = fc_wr_valid && fc_wr_write && packet_active_r` (`tidelink_fifo_ctrl.sv:97`). `packet_active_r` is set ONLY when a write at `addr==0` arrives (`fc_write_addr0`, line 157+191). `fc_wr_ready` is hard-wired `1'b1` (`tidelink_fifo_mem.sv:82`), so no backpressure.

- **REG_DOORBELL_RESP_ACC (0x024) write source:** Master's `tidelink_returner.write_data_1 = credit_count_data` (slave-local free credits), `write_addr_1 = pair_base_addr + 0x024`. Sent as SIDEBAND. Slave RX FSM lands it at `fc_rx_cfg_*` → slave APB write to offset 0x024 → `doorbell_response_acc <= acc + pwdata[15:0]` (`tidelink_apb_regs.sv:298-311`, saturating). 0x5000 per AHB master write = the master is firing one doorbell (or one release-credit-trigger that also routes to 0x024) per AHB transaction with payload = the master's own current_credit_count. **This proves the FC sideband demux on the slave is operational and the slave's APB pass-through works** — at least for offset 0x024.

- **HW_SYNC_STATUS (0x048) on slave is hw_sync_en_r**, the **initiator-side** enable (`tidelink_ptp.sv:535`). The slave never enabled HW_SYNC, so 0 is expected. The test should be reading **PTP_STATUS (0x03C) bit[2] = ptp_rx_valid_r** and **PTP_RX_PAYLOAD (0x038)** to see slave RX. This may be a measurement bug, but Bug B is real either way — Build #3 log says "PTP-status passed" yet AHB RX empty, so the PHC servo/sync still isn't bringing the slave into lock.

---

## 1. Bug A hypothesis bank — AHB packet RX empty at slave

### A-1 (HIGHEST — ~60%) — FC RX FSM rx_pkt_type misdecode: SIDEBAND wins, FIFO_DATA never lands

**Mechanism.** `tidelink_fc_adapter.sv:429` decodes `rx_pkt_type = rx_fc_word_r[47:46]`. The 48-bit FC payload is muxed onto a 50-bit `tidelink_in/out` bus (`{a2l_valid, a2l_data[47:0], l2a_accept}` / `{a2l_ready, l2a_valid, l2a_data[47:0]}`, see `tidelink_top.sv:1951-1952`). If a 1-bit shift / mis-slice has crept into `axi_chiplet_controller.sv` (local override) or in the `tl_in_wire`/`tl_out_wire` packing in `Wlink.v:1003`, FIFO_DATA (`00`) packets arrive as SIDEBAND (`01`), get routed to `fc_rx_cfg_*` (APB writes) instead of `fc_rx_fifo_*`. The 0x5000 bumps at 0x024 are partly **misrouted FIFO_DATA word 0** (length=N landing at apb_paddr=0 which decodes Region 0 slot 0 = `pair_base_addr` — but pair_base writes can also leak into 0x024 if address translation rolls over).

**Predicted.** `obs_pkt_is_cr_pkt_w=0` always (not a CR), `obs_cr_pkt_seen_rx_w=1` (sticky from link-up). Slave's RX FSM ILA shows `rx_pkt_type==01` on every AHB packet word. Slave `fc_rx_cfg_psel` toggles on every word; slave `fc_rx_fifo_valid` never asserts. Master AHB returns HREADY in 0.17 ms (consistent).

**Experiment.** Probe **slave** `tidelink_top.u_fc_adapter.rx_fc_word_r[47:46]` and `rx_pkt_type` while master executes `td_ahb_tx_packet(N=1, payload=0xCAFEBABE)`. Also probe `fc_rx_fifo_valid`, `fc_rx_fifo_addr`, `fc_rx_cfg_psel`, `fc_rx_cfg_paddr`. If `pkt_type` is anything but `00` for a FIFO_DATA, A-1 wins. **Effort:** 2 h (one ILA build).

### A-2 (~25%) — `packet_active_r` never asserts: first-word capture race

**Mechanism.** `tidelink_fifo_ctrl.sv:97`: `fc_write_valid = fc_wr_valid && fc_wr_write && packet_active_r`. `packet_active_r` is set only by `fc_write_addr0 = fc_wr_valid && fc_wr_write && (fc_wr_addr == '0)` (line 157) AND the slave isn't holding a stale `packet_active_r=0` due to a prior incomplete packet that never read its target word. If a previous spurious FIFO_DATA write reached the slave with `addr_offset != 0` (e.g. master's TX-aperture skid replayed a stale `tx_addr_r` from a prior bring-up), the FSM is stuck waiting on `read_complete` or `write_complete` that never come.

**Predicted.** Slave's `packet_active_r=0` permanently. `fc_wr_valid` pulses on master TX, `fc_wr_addr` is non-zero on the first beat, OR `fc_wr_addr==0` but the wdata length field is mis-clamped to 0 by `clamp_length` (returning `MAX_PACKET_LEN` if raw>MAX). REG_PKT_LEN=0 is also explained by this.

**Experiment.** Probe `packet_active_r`, `fc_wr_addr`, `fc_wr_wdata`, `fc_write_addr0`, `packet_word_length_r`. Compare slave's first-beat `fc_rx_fifo_addr` with the master's `tx_addr_r`. If `fc_wr_addr` is consistently non-zero on first beat, the TX skid is leaking stale state. **Effort:** 3 h.

### A-3 (~10%) — Master TX address-phase wrong because of address-translator residual

**Mechanism.** `tidelink_addr_translator` (`tidelink_top.sv:1702-1728`) sits between `ahb_sub_haddr` and `translated_sub_haddr`. AHB packets enter via `ahb_tx_*` (a separate port at `tidelink_top.sv:1121`), but the **TX aperture port** receives `ahb_tx_haddr` of width `RAM_ADDR_W-1:0` only (14 bits — top bits stripped at port boundary). The CMSDK external AHB master writing to `0x44000000+offset` should produce `ahb_tx_haddr=offset[13:0]`. If word 0 is being address-clipped (CMSDK sends `0x44000000` and the slot bit decode hands the TX aperture an addr of `0xX000`), `tx_addr_r` is non-zero and slave `packet_active` never asserts (chains to A-2).

**Predicted.** Master's `ahb_tx_haddr[13:0]` for word 0 is **not** `14'h0000`. If it's a constant offset, A-3 is alive.

**Experiment.** Probe master `ahb_tx_haddr`, `ahb_tx_hsel`, `tx_addr_r`. Also read master 0x44000000 vs 0x44000004 from PS7 with a logic analyzer or ILA on the AHB sub bus. **Effort:** 2 h.

### A-4 (~5%) — Slave-side reset glitch leaves `rx_state_r` in `RX_DATA_PHASE`

**Mechanism.** `tidelink_fc_adapter.sv:467` resets `rx_state_r` async on `hresetn`. If hresetn deasserts mid-`l2a_valid` (likely on bring-up after `bringup_pair_converge.sh` toggles training/cal), the FSM may capture a half-valid FC word with `rx_pkt_type=00` but `rx_pending_r` skew → never transitions out of `RX_ADDR_PHASE`. Subsequent words get NACKed because `rx_accept = tl_fc_l2a_valid & (rx_state_r==RX_IDLE) & ~rx_pending_r`. Master's TX skid never drains → backpressure → master AHB stalls. **But user reports master HREADY returns in 0.17 ms**, so master TX is being accepted by Wlink. This makes A-4 unlikely unless slave's FSM is wedged but the wire is still accepting (l2a_valid asserted but l2a_accept stuck low → cr_pkt advertisements stop → master saturates on credit but only after many packets).

**Predicted.** Slave `tl_fc_l2a_valid=1` sticky high, `tl_fc_l2a_accept=0`, `rx_state_r=RX_ADDR_PHASE` permanent.

**Experiment.** Probe slave `rx_state_r`, `rx_pending_r`, `tl_fc_l2a_valid`, `tl_fc_l2a_accept`. **Effort:** 2 h (same ILA build as A-1).

### A-5 (~5%) — TX aperture skid buffer arbitration: returner SIDEBAND starves FIFO_DATA

**Mechanism.** `tidelink_fc_adapter.sv:367` — `sideband_grant` always wins over `tx_fc_word` unless `sideband_starving` after 4 grants. If `release_credits_trigger` or `doorbell_trigger` keeps re-firing (the master returner keeps writing 0x020/0x024/0x014 to the wire because of its own reset_deassert_pulse or accumulator threshold), the FIFO_DATA TX word is starved for >4 beats then granted — but only 1-of-N gets through and the slave never sees a complete N-word packet.

**Predicted.** Master `sideband_burst_r` spends a lot of time at 4; `arb_data` rarely shows pkt_type=00. Slave's REG_PKT_LEN occasionally non-zero (length word leaked through) but payload words missing.

**Experiment.** Probe master `sideband_burst_r`, `sideband_grant`, `arb_data[47:46]`, `tx_fc_valid`, `rtn_fc_valid`. Count FIFO_DATA vs SIDEBAND grants. **Effort:** 2 h.

---

## 2. Bug B hypothesis bank — PTP HW_SYNC RX empty at slave

### B-0 (measurement issue) — Test reads HW_SYNC_STATUS (0x048) on slave; that register is initiator-side

**Mechanism.** `tidelink_ptp.sv:531-535`: `HW_SYNC_STATUS[0]=hw_sync_en_r` (the SW-written initiator enable). Slave never wrote it, so 0 is expected even if RX works. The test should read **PTP_STATUS (0x03C)[2]=ptp_rx_valid_r** and **PTP_RX_PAYLOAD (0x038)**. **Effort:** 5 min (re-run with corrected MMIO offsets). Do this FIRST — if PTP_STATUS[2]=1 then slave is receiving SYNCs and B is a measurement artefact.

### B-1 (HIGHEST real bug — ~50%) — `ptp_sp_rx_accept` tied to `ptp_enable_r` consumer-replica fail (PHC Phase-1 candidate)

**Mechanism.** Documented in `project_phc_phase1_hw_diagnosis_2026_05_24.md` Agent J #1 candidate: `tidelink_ptp.sv:288 wire rx_accept = ptp_sp_rx_valid & ptp_enable_r`. Two consumers of `ptp_enable_r` (TX line 272, RX line 288). In slave-role bitstream, P&R / synth optimisation drops or mis-resets the RX-consumer replica → reads 0 → `rx_accept=0` → `rx_fifo` fills → `rx_fifo_io_wfull=1` → drops all SYNCs. The first build #21 attempted replication with `(* keep *) (* dont_touch *)`, this build (`dda0a0e`) reverted that work — confirm by inspecting `src/rtl/tidelink_ptp.sv` line 288 vs the b24-patched variant.

**Predicted.** Slave `sp2wl/rx_pkt_valid=1` pulses (FC layer delivers), `sp2wl/rx_fifo_io_wfull=1` quickly, `ptp_sp_rx_accept=0` sticky low, `ptp_sp_rx_valid` asserts but `ptp_enable_r` on the RX side reads 0 even though APB write set it.

**Experiment.** Probe slave's `u_ptp.ptp_enable_r`, `u_ptp.rx_accept`, `u_chiplet_controller....sp2wl.rx_fifo_io_wfull`, `rx_fifo_io_winc`, `auto_rx_in_data_id`, `dataIdMatch`. After APB-write `PTP_CTRL=0x01`, read back `PTP_CTRL` — should return 0x01. If readback is 0x01 but `u_ptp.rx_accept=0` even when `ptp_sp_rx_valid=1`, B-1 is confirmed. **Effort:** 3 h ILA build.

### B-2 (~25%) — Slave's PTP module never sees `ptp_sp_rx_valid` because `sp2wl.rx_fifo` is still empty (link-layer drop)

**Mechanism.** `ShortPacketToWlink.v:109`: `rx_fifo_io_winc = rx_pkt_valid & ~rx_fifo_io_wfull`. `rx_pkt_valid = auto_rx_in_valid & auto_rx_in_sop & dataIdMatch`. If `auto_rx_in_sop` is not asserted in the same cycle as `auto_rx_in_valid` (sop/eop timing mismatch in a 16-lane mid-burst — same family as the WavD2DGpio mid-word mux flip bug ref'd in `project_tidelink_interface_fcsm_bug_2026_05_24.md`), `rx_pkt_valid=0` even though the bytes arrived. Slave's `sp2wl.rx_fifo_io_rempty` stays 1.

**Predicted.** Slave `auto_rx_in_valid` pulses on master SYNC firing, `auto_rx_in_data_id==0x50`, but `auto_rx_in_sop` is 0 in the same cycle. `rx_fifo_io_rempty=1`.

**Experiment.** ILA probe slave `sp2wl.auto_rx_in_{sop,valid,data_id,word_count}` + `rx_pkt_valid` + `dataIdMatch`. The `mark_debug` attributes are already on these (`ShortPacketToWlink.v:40-58`). **Effort:** 2 h.

### B-3 (~15%) — `tx_router_idle` never asserts on slave: PTP TX path wedged (not the RX symptom, but caused-by)

**Mechanism.** Slave's PTP would normally reply DELAY_REQ on receipt. If slave is configured GM-mode by accident (`PTP_CTRL=0x0d` writes master flag too), TX path gates on `tx_router_idle`. Doesn't cause RX=0 directly but masks any TX-path verify.

**Predicted.** Not the primary symptom — skip unless B-1/B-2 fail.

**Experiment.** Read slave `PTP_STATUS (0x03C)[0]=tx_router_idle` and `[1]=tx_pending_r`. **Effort:** 5 min.

### B-4 (~10%) — TX router slot-7 ordering: SP TX from master races CR_PKT eviction, link drops first SP after every CR

**Mechanism.** `Wlink.v:1690-1692` — slot 7 of `txrouter_auto_in` is the SP TX. The TX router prioritises CR_PKT/CRACK_PKT (FCSM internal) ahead of every app slot. If the master's SP TX is presented in the same cycle as a CR_PKT, the SP word is **dropped**, not stalled, because the router only forwards one slot per cycle and the `advance` signal is asserted regardless (`sp2wl.auto_tx_out_advance`). Doesn't apply to the AHB FC channel (which has flow control), but SP has none.

**Predicted.** Slave receives some SYNCs but at a rate << master's transmit rate. Master's `hw_seq_num_int_r` advances faster than slave's `ptp_rx_payload_r` advances.

**Experiment.** Probe master `sp2wl.tx_pending`, `auto_tx_out_advance`, `auto_tx_out_sop` and compare with slave `sp2wl.rx_pkt_valid` pulses over a 1 s window. **Effort:** 4 h ILA + analyser.

---

## 3. Are A and B independent, or shared root cause?

**For independent:** Bug A is on the **TideLink FC node** (data_id ≈0xa1, 48-bit, has CR-pkt flow control, owned by `tl2wl`). Bug B is on the **ShortPacket node** (data_ids 0x50/0x51, 26-bit packed, NO flow control, owned by `sp2wl`). Different Wlink instances, different RX FIFOs, different decode paths. Independent demux at the chiplet controller boundary (`rxrouter_auto_out_8` for SP vs `tl2wl_auto_wlink_tidelinktl_rx_in` for TideLink). RTL evidence: each path has its own `data_id` filter and FIFO.

**For shared:** The **only** common pieces between A and B are:
- Wlink LL_RX byte-align and FCSM state (already verified by `cal_done=1` + working doorbell at 0x024).
- The slave's **APB clock/reset domain** — `tidelink_apb_regs` produces `ptp_reg_wdata` etc., and writes to `PTP_CTRL` may not actually latch `ptp_enable_r` if there's a reset/clock issue on the APB → ptp pass-through. But Bug A's symptom (REG_PKT_LEN=0) is on the AHB-FIFO control path, not APB.
- The **slave-role bitstream P&R class** — the I2C Bug #3 / PHC Phase-1 class of "register optically pruned in slave variant." This could plausibly cause **both** if a shared APB write-decode FF is dropped on slave (e.g., `ptp_enable_r` AND `packet_active_r` both fail to latch). However the doorbell-write APB pass-through demonstrably works at offset 0x024, weakening this for A.

**Likely conclusion:** Independent root causes. A is most likely in the FC-adapter pkt_type decode or the slave's `packet_active_r` capture. B is most likely the documented PHC Phase-1 `ptp_enable_r` consumer-replica fail. Don't conflate — investigate in parallel.

---

## 4. Recommended ordering of experiments — maximum information gain

1. **(5 min) Re-measure Bug B with PTP_STATUS (0x03C)[2] and PTP_RX_PAYLOAD (0x038)**, not HW_SYNC_STATUS. If slave PTP_STATUS[2]=1 after master SYNCs, B reduces to a measurement bug — go directly to step 4. If still 0, proceed to (2).
2. **(5 min) Read slave PTP_CTRL after writing 0x01.** If readback ≠ 0x01, the APB pass-through for PTP itself is broken (different class of bug). If = 0x01, write probably latched but RX-consumer replica may still be 0 (B-1).
3. **(30 min) Read master `obs_cr_pkt_seen_rx_w` and `obs_pkt_is_cr_pkt_w`** (`sync_obs_cr_seen_1`, `sync_obs_pkt_cr_1` at APB Region 4 ILA observability bits per `axi_chiplet_controller.sv:759/763`). If `cr_pkt_seen_rx` is 1 on both sides and `pkt_is_cr_pkt` toggles, the link FCSM is healthy. (Likely will confirm — calibrator Fix A2+B already validated this.)
4. **(2 h) Build ILA #1: combined A-1/B-1/B-2 capture set** (see §5 below). Single build covers both bugs.
5. **(15 min after capture) Decide:**
   - If A-1 hits: `pkt_type[47:46]` is wrong on slave → suspect 50-bit packing in `axi_chiplet_controller.sv` local override or in `Wlink.v` `tl_in_wire`/`l2a_data` slice.
   - If A-2 hits: `packet_active_r` capture fails → suspect TX aperture address latch.
   - If B-1 hits: re-apply Agent J's b24 patch (decouple `rx_accept` from `ptp_enable_r`).
   - If B-2 hits: same family as the `WavD2DGpioTx.v` mid-word mux bug → check `local_overrides`.
6. **(parallel) Loopback bring-up bisect** (`pynq-z2-loopback-ext` per `project_tidelink_loopback_bringup_pair.md`): does the slave AHB RX work in **self-loopback**? If yes, the bug is M↔S asymmetric (slave-role bitstream class). If no, the bug is in shared RTL.

---

## 5. ILA probe shortlist

Single ILA capture pass covers both bugs. Build with `mark_debug` attributes already present, plus hierarchical probes from below.

**Group 1 — Bug A: FC adapter RX demux (slave)**
- `u_fc_adapter.tl_fc_l2a_valid`, `tl_fc_l2a_accept`, `tl_fc_l2a_data[47:46]` (pkt_type), `[45:32]` (addr_offset), `[31:0]` (payload)
- `u_fc_adapter.rx_state_r[1:0]`, `rx_pending_r`, `rx_pkt_type[1:0]`, `rx_addr_offset[13:0]`
- `u_fc_adapter.fc_rx_fifo_valid`, `fc_rx_fifo_addr[13:0]`, `fc_rx_fifo_wdata[31:0]`
- `u_fc_adapter.fc_rx_cfg_psel`, `fc_rx_cfg_paddr[11:0]`, `fc_rx_cfg_pwdata[31:0]`

**Group 2 — Bug A: FIFO ctrl packet_active capture (slave)**
- `u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl.packet_active_r`
- `fc_write_addr0`, `fc_write_valid`, `fc_write_complete`
- `packet_word_length_r[13:0]`, `write_target_addr_r[13:0]`, `write_ptr_r[13:0]`

**Group 3 — Bug A: Master TX aperture (master)**
- `u_fc_adapter.ahb_tx_hsel`, `ahb_tx_haddr[13:0]`, `ahb_tx_hwdata[31:0]`, `tx_addr_r[13:0]`, `tx_data_phase_r`, `tx_fc_valid`
- `sideband_grant`, `sideband_burst_r`, `arb_data[47:46]` (pkt_type winning arbitration)
- `skid_valid_r`, `tl_fc_a2l_valid`, `tl_fc_a2l_ready`

**Group 4 — Bug B: SP RX path (slave)**
- `u_chiplet_controller.u_wlink.sp2wl.auto_rx_in_sop`, `auto_rx_in_valid`, `auto_rx_in_data_id[7:0]`, `auto_rx_in_word_count[15:0]` (mark_debug already on most)
- `sp2wl.dataIdMatch`, `rx_pkt_valid`, `rx_fifo_io_winc`, `rx_fifo_io_wfull`, `rx_fifo_io_rempty`, `rx_fifo_io_rinc` (mark_debug already on)
- `sp2wl.rx_accept` (= bore_2[0] = ptp_sp_rx_accept)

**Group 5 — Bug B: PTP enable replica (slave)**
- `u_ptp.ptp_enable_r`, `u_ptp.rx_accept`
- `u_ptp.ptp_sp_rx_valid`, `ptp_sp_rx_data_id[7:0]`, `ptp_sp_rx_payload[15:0]`, `ptp_sp_rx_accept`
- `u_ptp.ptp_rx_valid_r`, `ptp_rx_payload_r[15:0]`

**Group 6 — Link health (both sides)**
- `axi_chiplet_controller.obs_cr_pkt_seen_rx_w`, `obs_pkt_is_cr_pkt_w` (already brought to ILA per `axi_chiplet_controller.sv:759/763`)
- FCSM state register (`u_wlink.fc_*.state[2:0]`)
- `cal_done`, `lane_locked[7:0]` (sanity)

**Trigger:** `ahb_tx_hsel & ahb_tx_hwrite & (ahb_tx_haddr==14'h0)` on master (first word of a packet). Capture 4096 samples post-trigger at link-clk to see slave's response over the full packet + ~50 idle cycles.

---

**Total expected experiment cycle:** 8–12 h for first ILA capture + analysis to confirm A-1 or A-2 and B-1. Pivot to RTL fix only after data lands.
