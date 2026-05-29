# Bug Diagnoses 2026-05-29 — Build #3 silicon validation

**Branch** `feat/td-gpio-phy-integration` HEAD `dda0a0e`. PHY 16/16, `cal_done=1`, doorbell M↔S works, `REG_DOORBELL_RESP_ACC` bumps 0x5000/AHB-write. Two residual gaps: (A) AHB packet RX empty at slave, (B) PTP SYNC RX empty at slave.

## Key data-path facts (read from RTL)

- **Three independent FC channels.** (1) **TideLink FC** `tl2wl` (~data_id 0xa1, 48-bit, AHB packets + returner sideband) — `tidelink_fc_adapter.sv` encodes `pkt_type[47:46]` (00=FIFO_DATA, 01=SIDEBAND, 10=EXT) + `addr_offset[45:32]` + `payload[31:0]`. (2) **ShortPacket** `sp2wl` (data_ids 0x50=SYNC, 0x51=DELAY_REQ) — `ShortPacketToWlink.v` has tx_fifo + rx_fifo, **NO credit logic**, RX hard-filter `dataIdMatch = (data_id==0x50)|(data_id==0x51)` (line 57). (3) AXI bridges via XHB500 (not used by AHB-packet path).
- **`PAIR_CREDIT_COUNTER` is SW-only.** `tidelink_apb_regs.sv:321-347` driven only by APB writes; not a TX gate.
- **Slave AHB packet RX path.** `tl_fc_l2a_data` → `tidelink_fc_adapter` RX FSM → if `pkt_type==FIFO_DATA` drives `fc_rx_fifo_*` to `tidelink_fifo_ctrl`. **`fc_write_valid = fc_wr_valid && fc_wr_write && packet_active_r`** (`fifo_ctrl.sv:97`). `packet_active_r` is set ONLY by `fc_write_addr0 = … && (fc_wr_addr=='0)` (line 157+191). `fc_wr_ready=1'b1` constant — no backpressure.
- **0x024 write source.** Master's returner: `write_data_1 = credit_count_data` (master's local free credits), `write_addr_1 = pair_base+0x024`, sent as SIDEBAND. Slave RX-FSM lands it via `fc_rx_cfg_*` → APB write to 0x024 → saturating add. **Proof that slave SIDEBAND demux + APB pass-through works for at least offset 0x024.**
- **HW_SYNC_STATUS (0x048)[0] = `hw_sync_en_r`** — the **initiator** enable (`tidelink_ptp.sv:535`). Slave never enabled it, so 0 is correct. The slave-side RX evidence is **PTP_STATUS (0x03C)[2] = `ptp_rx_valid_r`** and **PTP_RX_PAYLOAD (0x038)**. `ptp_sp_rx_accept = ptp_sp_rx_valid & ptp_enable_r` (`tidelink_ptp.sv:288, 290`).

---

## 1. Bug A hypothesis bank — AHB packet RX empty at slave

### A-1 (~50%) — Slave FC RX pkt_type misdecode: FIFO_DATA mis-routed to SIDEBAND
**Mechanism.** `tidelink_fc_adapter.sv:429` decodes `rx_pkt_type = rx_fc_word_r[47:46]`. The 48-bit FC payload rides a 50-bit `tidelink_in/out` packed bus (`tidelink_top.sv:1951-1952`). A 1-bit slice/shift in `axi_chiplet_controller.sv` (local override) or `Wlink.v:1003` `tl_in_wire`/`l2a_data` mapping would corrupt the top two bits, routing FIFO_DATA (00) to `fc_rx_cfg_*` (APB) instead of `fc_rx_fifo_*`.
**Predicted.** Slave `rx_pkt_type` reads 01 (or 10/11) for AHB-packet beats; `fc_rx_fifo_valid` never asserts; `fc_rx_cfg_psel` toggles on every word — but lands at random APB offsets that explain part of the 0x5000 bump at 0x024.
**Experiment.** ILA slave `u_fc_adapter.{tl_fc_l2a_valid,tl_fc_l2a_data[47:32],rx_pkt_type,fc_rx_fifo_valid,fc_rx_fifo_addr,fc_rx_cfg_psel,fc_rx_cfg_paddr}` while master executes one packet write (N=1, payload=0xCAFEBABE). **Effort:** 2 h.

### A-2 (~25%) — Slave `packet_active_r` never asserts: first-word capture race
**Mechanism.** `fifo_ctrl.sv:97,157,191`. `packet_active_r` only sets when `fc_wr_valid && fc_wr_write && fc_wr_addr=='0`. If the first beat from master arrives with `fc_wr_addr != 0` (TX skid `tx_addr_r` not cleared after a prior bring-up) — or master's `ahb_tx_haddr[13:0]` is non-zero on word 0 because the external decoder dropped only the top bits — slave stays inactive and silently drops every subsequent beat. REG_PKT_LEN=0 is the direct prediction.
**Predicted.** Slave `packet_active_r=0` permanent; `fc_wr_addr != 0` on first beat; OR `fc_wr_wdata=0` (length clamped/lost) on first beat.
**Experiment.** ILA slave `u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl.{packet_active_r,fc_wr_addr,fc_wr_wdata,fc_write_addr0,packet_word_length_r}` + master `u_fc_adapter.{ahb_tx_haddr,tx_addr_r,tx_fc_word[45:32]}`. **Effort:** 3 h.

### A-3 (~15%) — TX arbiter starves FIFO_DATA behind returner SIDEBAND
**Mechanism.** `tidelink_fc_adapter.sv:367`: `sideband_grant = (rtn_fc_valid || servo_fc_valid || ext_grant) && !sideband_starving`. The starvation guard fires only after 4 sideband grants. If the master returner keeps re-firing (release/doorbell triggers chain), the FIFO_DATA word is delayed; if the AHB master times out / withdraws before the granted cycle, the packet word is lost.
**Predicted.** Master `sideband_burst_r` sits at 4 frequently; `arb_data[47:46]` rarely 00; slave occasionally sees first beat (length) without payload.
**Experiment.** Master ILA `{sideband_burst_r,sideband_grant,arb_data[47:46],tx_fc_valid,rtn_fc_valid,servo_fc_valid}`. **Effort:** 2 h.

### A-4 (~10%) — Slave FC RX FSM wedged in ADDR/DATA phase from reset glitch
**Mechanism.** `tidelink_fc_adapter.sv:467` resets `rx_state_r` async on `hresetn`. If `hresetn` deasserts mid-`l2a_valid` during `bringup_pair_converge.sh`, FSM latches a half-formed word with `rx_pending_r=1`, jams in `RX_ADDR_PHASE`. `tl_fc_l2a_accept` stuck low → eventually link backpressures master TX. (Master HREADY in 0.17 ms argues against jam on every txn, but transient jam early in the run is consistent.)
**Predicted.** Slave `rx_state_r==01` or `10` permanently; `tl_fc_l2a_accept=0`.
**Experiment.** Same ILA as A-1, add `{rx_state_r,rx_pending_r,tl_fc_l2a_accept}`. **Effort:** included in A-1.

---

## 2. Bug B hypothesis bank — PTP SYNC RX empty at slave

### B-0 (5 min, do first) — Measurement: read PTP_STATUS (0x03C)[2], not HW_SYNC_STATUS (0x048)
HW_SYNC_STATUS is initiator-side (`tidelink_ptp.sv:535`). Slave RX evidence is PTP_STATUS bit[2]=`ptp_rx_valid_r` and PTP_RX_PAYLOAD. If PTP_STATUS[2]=1 after master TX, B is a measurement artefact only.

### B-1 (~50%) — `ptp_enable_r` RX-consumer replica fails on slave-role bitstream (PHC Phase-1 candidate)
**Mechanism.** `tidelink_ptp.sv:288`: `wire rx_accept = ptp_sp_rx_valid & ptp_enable_r`. `ptp_enable_r` feeds TX (line 272) AND RX (line 288). Per `project_phc_phase1_hw_diagnosis_2026_05_24.md` (Agent J), on slave-role P&R the RX-consumer replica is dropped/mis-reset → reads 0 → rx_accept=0 → `sp2wl.rx_fifo` fills → `wfull` → all subsequent SYNCs dropped at link. Build #21 attempted manual replication with `(* keep *)(* dont_touch *)`; the current `dda0a0e` tree appears to have reverted that — confirm by inspecting current `tidelink_ptp.sv` line 288.
**Predicted.** APB-write `PTP_CTRL=0x01` reads back 0x01, but slave `u_ptp.rx_accept=0` even when `ptp_sp_rx_valid=1`; `sp2wl.rx_fifo_io_wfull=1` quickly after master TX starts; `sp2wl.rx_fifo_io_rinc=0`.
**Experiment.** ILA `u_ptp.{ptp_enable_r,rx_accept,ptp_sp_rx_valid,ptp_sp_rx_accept,ptp_rx_valid_r}` + `u_chiplet_controller.…sp2wl.{rx_fifo_io_wfull,rx_fifo_io_winc,rx_fifo_io_rinc,rx_fifo_io_rempty,rx_accept,dataIdMatch}` (mark_debug already present on most). **Effort:** 3 h.

### B-2 (~25%) — Slave `sp2wl.rx_pkt_valid` never asserts: sop/valid mismatch at link layer
**Mechanism.** `ShortPacketToWlink.v:58`: `rx_pkt_valid = auto_rx_in_valid & auto_rx_in_sop & dataIdMatch`. If a per-lane sop/valid skew (same family as the WavD2DGpioTx mid-word mux bug per `project_tidelink_interface_fcsm_bug_2026_05_24.md`) lands `auto_rx_in_sop=0` in the cycle that `auto_rx_in_valid=1`, the SP packet is silently dropped at the FIFO write.
**Predicted.** Slave `auto_rx_in_valid` pulses, `auto_rx_in_data_id==0x50`, but `auto_rx_in_sop=0` in the same cycle; `rx_fifo_io_rempty=1` always.
**Experiment.** ILA `sp2wl.{auto_rx_in_sop,auto_rx_in_valid,auto_rx_in_data_id,auto_rx_in_word_count,rx_pkt_valid}`. mark_debug already on these signals. **Effort:** 2 h, captured in same build as B-1.

### B-3 (~10%) — Master HW sync gate held off: `hw_sync_gate=0` so SYNC never fires
**Mechanism.** `tidelink_ptp.sv:368-369`: `hw_sync_gate = force_en_r | phc_locked_i` when `PHC_LOCK_GATE_EN=1`. If the master's PHC isn't locked AND force_en wasn't set, FSM stays in `HW_SYNC_IDLE`. User reports HW_SYNC_STATUS bumps to 0x1e0d initially (seq_num advances → gate must be open at that point), but if `phc_locked_i` deasserts mid-run, sync stops. Not the primary symptom, but a possible second-order effect.
**Predicted.** Master HW_SYNC_STATUS[18]=phc_locked drops to 0; seq_num stops advancing.
**Experiment.** Periodic poll of master 0x048 over 10 s — does seq_num keep advancing? **Effort:** 5 min MMIO loop.

### B-4 (~10%) — Slave `swi_enable=0`
**Mechanism.** `sp2wl.io_app_enable = swi_enable` (Wlink.v:1912). RX path `rx_fifo_io_winc` does NOT consult app_enable, so this only explains TX stalls — not RX=0. Listed for completeness.
**Experiment.** Read slave APB 0x208[0]. **Effort:** 1 min.

---

## 3. Independent or shared root cause?

**Likely independent.** A is on **`tl2wl`** (48-bit, CR-FC). B is on **`sp2wl`** (26-bit, no FC). Different router slots, FIFOs, data_id filters, demux. Doorbell SIDEBAND lands at slave 0x024 → `tl2wl` link + slave APB pass-through work. Prior PHC Phase-1 ILA confirmed slave `sp2wl.rx_pkt_valid` HAS pulsed on past builds.

**Possible shared cause:** slave-role bitstream P&R class (I2C Bug #3 / PHC Phase-1 family — optical-pruned registers). Could plausibly drop `packet_active_r` AND `ptp_enable_r`-RX-replica together. Doorbell working at 0x024 weakens this for Bug A. Investigate in parallel.

---

## 4. Recommended ordering — maximum information gain

1. **(5 min) Re-measure B with PTP_STATUS (0x03C)[2] and PTP_RX_PAYLOAD (0x038).** Resolves B-0. If PTP_STATUS[2]=1 → B is measurement; if 0 → real RX failure.
2. **(5 min) Read slave PTP_CTRL after writing 0x01.** Readback ≠ 0x01 → APB pass-through broken (different class). Readback = 0x01 → primary suspect B-1.
3. **(15 min) Poll master HW_SYNC_STATUS over 10 s.** Confirms B-3 ruled in/out.
4. **(1 min) Read slave Wlink reg 0x208[0]** (swi_enable). Rules B-4 out.
5. **(parallel) Loopback bring-up bisect** (`pynq-z2-loopback-ext` per `project_tidelink_loopback_bringup_pair.md`): does slave AHB-RX work in **self-loopback**? Yes → M↔S asymmetric class. No → shared RTL.
6. **(2 h) Build single ILA covering A-1+A-2+A-4+B-1+B-2** (Groups 1, 2, 4, 5 below). Single trigger: `ahb_tx_hsel & ahb_tx_hwrite & (ahb_tx_haddr==0)` on master; 4 K samples at link-clk.
7. **(15 min after capture) Decide fix path:** A-1 → check 50-bit packing in chiplet-controller local override / `Wlink.v` `tl_in_wire`. A-2 → trace TX `tx_addr_r` reset path. B-1 → re-apply Agent J b24 (decouple `rx_accept` from `ptp_enable_r`).

---

## 5. ILA probe shortlist

Single build covers both bugs.

**Group 1 — Bug A: slave FC RX demux.** `u_fc_adapter.{tl_fc_l2a_valid, tl_fc_l2a_accept, tl_fc_l2a_data[47:32], rx_state_r, rx_pending_r, rx_pkt_type, rx_addr_offset[13:0], fc_rx_fifo_valid, fc_rx_fifo_addr, fc_rx_fifo_wdata, fc_rx_cfg_psel, fc_rx_cfg_paddr, fc_rx_cfg_pwdata}`.

**Group 2 — Bug A: slave FIFO ctrl.** `u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl.{packet_active_r, fc_write_addr0, fc_write_valid, fc_write_complete, packet_word_length_r, write_target_addr_r, write_ptr_r}`.

**Group 3 — Bug A: master TX aperture / arbiter.** `u_fc_adapter.{ahb_tx_hsel, ahb_tx_haddr, ahb_tx_hwdata, tx_addr_r, tx_data_phase_r, tx_fc_valid, sideband_grant, sideband_burst_r, arb_data[47:46], skid_valid_r, tl_fc_a2l_valid, tl_fc_a2l_ready}`.

**Group 4 — Bug B: slave SP RX path.** `u_chiplet_controller.u_wlink.sp2wl.{auto_rx_in_sop, auto_rx_in_valid, auto_rx_in_data_id, auto_rx_in_word_count, dataIdMatch, rx_pkt_valid, rx_fifo_io_winc, rx_fifo_io_wfull, rx_fifo_io_rempty, rx_fifo_io_rinc, rx_accept}` (mark_debug already on most).

**Group 5 — Bug B: slave PTP enable replica.** `u_ptp.{ptp_enable_r, rx_accept, ptp_sp_rx_valid, ptp_sp_rx_data_id, ptp_sp_rx_payload, ptp_sp_rx_accept, ptp_rx_valid_r, ptp_rx_payload_r}`.

**Group 6 — Link health (both sides).** `axi_chiplet_controller.{obs_cr_pkt_seen_rx_w, obs_pkt_is_cr_pkt_w}` (already ILA-routed per `axi_chiplet_controller.sv:759/763`); FCSM state; `cal_done`, `lane_locked[7:0]` for sanity.

**Trigger.** Master AHB write of word 0: `ahb_tx_hsel & ahb_tx_hwrite & (ahb_tx_haddr=='0)`. Capture 4096 samples post-trigger on link-clk.

**Total cycle:** 8–12 h from ILA build → analysis → root cause confirmed for both bugs.
