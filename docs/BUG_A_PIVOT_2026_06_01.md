# Bug A pivot — 2026-06-01 (the big day of falsifications)

After 4 days of chasing wedges + NACK loops + state-machine asymmetries, today's sim sweeps and the ODDR audit completely reframed Bug A. **Most of our prior hypotheses were chasing artefacts.** Tonight's iteration finally identified the real bug class.

## What we believed (now falsified)

| Theory | Source | Status |
|---|---|---|
| Slave RX `rx_pkt_type` misdecode (A-1) | F1 force experiment | Falsified by unit test |
| H-A1 AHB→fc_adapter handoff | Q-audit | Falsified |
| H-A2 skid backpressure | Q-audit | Falsified |
| H-A3 arbiter starvation | Q-audit | Falsified |
| H-A4 FCSM asymmetry | Q-audit | Falsified |
| H-A5 link bit-flip | sim baseline | Sim-falsified, HW open |
| Credit gate (PCC=0) | early hypothesis | Falsified by Agent 7 |
| L8 surface state advance | V1 sim test | RED-LIGHT |
| L9 pktnum resync | V3 sim test | FAIL |
| Q5 NACK-loop mechanism | RTL audit | Falsified by NACK predicate probe today |
| Slot-0 address aliasing | delivery sim hypothesis | Falsified by addr-aliasing probe today |

## What we found today (3 separate breakthroughs)

### Breakthrough 1 — sim NACK predicate probe (morning)

Probed all 8 Build #6 RX-wedge signals during AHB write in sim:
- `pkt_is_data_pkt` = 26 cy high (slave decodes data packets)
- `isExpPacket` = 25 cy high (pktnum matches expected — no mismatch)
- `crcCorruptSeen` = 0 (NO CRC errors ever)
- `isNotExpPacket_l7` = 0
- `send_nack_req` = 0 (NEVER LATCHES)

**Q5's entire mechanism falsified.** Slave RX framer is healthy. L7 logic works correctly. No NACK loop.

### Breakthrough 2 — delivery-path sim probe (afternoon)

Probed master TX path + slave RX delivery path concurrently:
- Master `tl_fc_a2l_valid` fires 4 cy (one per AHB word) ✅
- Slave `tl_fc_l2a_valid` fires 4 cy ✅
- Slave `fc_rx_fifo_valid` fires 4 cy ✅ (RAM gets 4 word-writes)
- Slave `exp_pkt_num` advances 2→6 (FCSM acknowledges receipt) ✅
- `S.fc_rx_cfg_psel` = 0 (no sideband misroute) ✅

**End-to-end data path is functional.** Initial hypothesis: slot-0 address aliasing (since `fc_rx_fifo_addr=0x0` on every fire).

### Breakthrough 3 — address-aliasing probe (afternoon, deeper)

Probed addr field continuity master→link→slave:
- **Aliasing REFUTED**: addresses transit `0x0 → 0x4 → 0x8 → 0xC` preserved end-to-end
- **BUT discovered cocotb BFM bug**: `PairTB._ahb_tx_write_word` sets `hwdata.value` AFTER the data-phase rising edge in cocotb 2.x → RTL samples `ahb_tx_hwdata = 0` → every prior pair-tb AHB test silently used zero payload
- With BFM fixed: `tx_fc_word` = `0x240000, 0x0, 0xdeadbeef, 0xcafebabe`, `fc_rx_fifo_wdata` mirrors correctly, `packet_word_length_r` transitions `0 → 2 → 0` (the value 2 is observable mid-commit)
- **AND found `REG_PKT_WORD_LEN` self-clears**: `tidelink_fifo_ctrl.sv:186-189` clears `packet_word_length` on `write_complete` → polling REG_PKT_LEN AFTER commit always returns 0. **Expected RTL behaviour, not a bug.**

### Bonus breakthrough — ODDR clock-output audit (also today)

Scope observation by user: clock arrives very late within data eye.

- `pynq-z2-pair-all` + `pynq-z2-pair-flip-all` targets (Build #10) wire `pad_clk_tx` straight to BD output via WavClockGate → OBUF
- Data lanes use IOB-packed OFF (faster path)
- → clock ~1-3 ns AFTER data transitions (matches scope)
- **Fix exists in tree but never wired into active target**: `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_clk_tx_oddr.v` (added 2026-05-28, commit 6ace849)
- Known-good 72c280b worked WITHOUT ODDR because RX-side IDELAYE2 + calibrator phase sweeps absorbed the skew

**Build #11 (`pynq-z2-pair-mmcmbypass-oddr-all`) is currently building** (kicked off 11:03, in Phase 2.4 placement).

## What Bug A might ACTUALLY be (revised hypothesis)

### Hypothesis 1: SW polling wrong register
- HW: master sends AHB packet → slave RX FIFO commits → `packet_word_length_r` momentarily becomes 2 → self-clears on `write_complete` → SW polls REG_PKT_LEN sees 0
- SW should poll `REG_STATUS bit[4]` (`packet_committed`) at offset 0x010
- **Need HW test**: write AHB, then immediately poll `REG_STATUS` bit[4]. If 1, this IS the bug.
- BUT we previously read slave AHB_RX_FIFO[0..3] = all zeros (which CAN'T self-clear). So data also isn't actually in the FIFO — this hypothesis is incomplete.

### Hypothesis 2: HW clock-late-in-eye corrupts payload
- Sim is bit-perfect (no skew) so works
- HW has clock ~1-3 ns after data → RX may sample wrong bit edges
- Even if pktnum matches and CRC computes from received bits (so passes), the actual payload bits could be wrong
- → fc_rx_fifo_wdata = wrong/zero data → slave FIFO reads zero
- Build #11 (ODDR target) tests this directly

### Hypothesis 3: BFM-like timing race in HW master TX path
- The cocotb BFM bug was hwdata-late-vs-addr-phase-edge
- On HW the AXI-AHB bridge handles AHB-Lite per spec, no equivalent race
- BUT it's worth probing: master's `ahb_tx_hwdata` timing relative to `tx_data_phase_r`
- ILA capture on master could verify

### Hypothesis 4: Something else entirely
- ILA on master AND slave with Build #10 (or Build #11) would settle it

## What to do next (action checklist)

### Immediate (HW path is BLOCKED — SSH to mapstone-dev down)
1. **Restore SSH to mapstone-dev** — first action when user returns. mapstone-dev ping responds (1.7 ms) but TCP/22 times out — sshd likely needs restart.

### When SSH back AND Build #11 done
2. **Deploy Build #11** (ODDR target) — should fix clock-in-eye
3. **AHB write + read REG_STATUS bit[4]** — settles Hypothesis 1
4. **Read raw AHB_RX_FIFO** at addresses 0, 4, 8, 12 (not just 0) — if data is in FIFO at the addresses master wrote to, then it's just SW polling
5. **ILA capture on Build #10 first** (existing bitstream) — capture master `fc_rx_fifo_*` + slave equivalents during AHB write

### Software-side action (not yet done)
6. **Fix cocotb BFM** in `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py` — see `test_buga_addr_aliasing.py` for the fix pattern (pre-arm hwdata before addr-phase edge). This unblocks all future sim work.
7. **Update PYNQ SW** test scripts to poll `REG_STATUS bit[4]` instead of `REG_PKT_LEN`

### Build/deploy queue
- Build #11 (ODDR target) — in flight, Phase 2.4 placement, ETA ~30-40 min
- After Build #11: deploy + verify clock centering reduces calibrator IDELAY tap counts (should drop from current ~10-20 to near 0)

## What's been mitigated already

- **Bug A wedge primitive** — L11 watchdog (Build #8/#9). Master no longer wedges on AHB write. Loop iteration is now fast.
- **R-1 mark_debug regression** — fixed in Build #5 by removing `pair_credit_counter` mark_debug.
- **ILA `.ltx` mismatch** — fixed in Build #10 by re-emitting from impl_1 routed.dcp.

## What's still really open

- **Bug A correctness root cause** — narrowed to one of 4 hypotheses above. Build #11 + ILA capture will resolve.
- **Bug B RTL fix** — sim-validated but reverted from working tree. 1-line `hw_sync_force_en_r` bypass.
- **BD-level PHC counter** — `phc_nanoseconds=30'h0` tied off. Bug B's time-based path (without force_en) cannot work until this is wired to a real counter.

## Docs of record (in priority order)

1. **This doc** — today's pivot summary
2. [docs/HANDOFF_COMPREHENSIVE_2026_06_01.md](HANDOFF_COMPREHENSIVE_2026_06_01.md) — comprehensive bug status (slightly outdated by today's findings but still useful for build history)
3. [docs/BUG_A_DELIVERY_PATH_SIM_2026_06_01.md](BUG_A_DELIVERY_PATH_SIM_2026_06_01.md) — delivery sim findings
4. [docs/BUG_A_ADDR_ALIASING_SIM_2026_06_01.md](BUG_A_ADDR_ALIASING_SIM_2026_06_01.md) — aliasing refuted + BFM bug + REG_PKT_WORD_LEN self-clear finding
5. [docs/CLOCK_EYE_TIMING_AUDIT_2026_06_01.md](CLOCK_EYE_TIMING_AUDIT_2026_06_01.md) — ODDR missing, fix in mmcmbypass-oddr target
6. [docs/BUG_A_NACK_PREDICATE_SIM_2026_06_01.md](BUG_A_NACK_PREDICATE_SIM_2026_06_01.md) — Q5 NACK theory falsified
7. [docs/BUG_DIAGRAMS_2026_06_01.md](BUG_DIAGRAMS_2026_06_01.md) — visual data flow + bug positions

## Honest assessment

Today reduced 11 active Bug A hypotheses to 4. The bug class shifted from "sequencer is broken" to "either SW polls wrong register OR HW clock skew corrupts payload". Build #11 (ODDR target) tests the second hypothesis directly. With SSH restored, ~30 min of HW work should resolve.

L11 wedge mitigation continues to be the most operationally important fix from this whole campaign — Bug A iteration is no longer blocked by manual power-cycle cost.
