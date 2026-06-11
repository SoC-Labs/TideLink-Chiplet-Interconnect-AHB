# TideLink Design Shortcomings

An analysis of limitations, potential issues, and areas for improvement in the current TideLink design, derived from code review.

## Critical

### 1. No Credit Underflow Protection (BUG-002)

**Location**: `tidelink_fifo_ctrl.sv` — credit count decrement on `write_complete`

The credit counter is decremented unconditionally on `write_complete` without checking that the packet fits. If software writes a packet larger than `credit_count`, the unsigned 13-bit counter wraps to a large value, silently corrupting credit accounting. The overrun flag only detects `credit_count == 0` at the point of a valid transfer, not whether the entire packet will fit.

**Impact**: FIFO pointer and credit state become inconsistent. Unread data can be silently overwritten.

**Recommendation**: Either saturate the counter at zero (preventing wrap) or add a pre-flight check that compares `packet_word_length + 1` against `credit_count` before allowing `write_complete` to fire.

### 2. Single Packet In-Flight Limitation

**Location**: `tidelink_fifo_ctrl.sv` — metadata capture at address 0

Only one packet can be written or read at a time. Writing to address 0 overwrites the current `packet_word_length`, meaning a second packet cannot begin until the first completes. There is no queuing of packet metadata.

**Impact**: Throughput is limited to one packet at a time. Software cannot pipeline writes of consecutive packets and must wait for `write_complete` before starting the next packet. Similarly, reads are serialised.

**Recommendation**: For higher throughput, consider a packet descriptor ring or a header FIFO that can hold metadata for multiple in-flight packets.

## Moderate

### 3. No Hardware-Enforced Packet Size Validation

**Location**: `tidelink_fifo_ctrl.sv` — metadata capture

The packet word length captured from address 0 is accepted unconditionally. Software can write a length that exceeds `MAX_CREDITS`, producing a target address beyond the SRAM boundary. The pointer arithmetic will wrap, but this can cause the packet to overwrite data from other packets.

**Recommendation**: Clamp or reject packet lengths that exceed available credits or `MAX_CREDITS - 1`.

### 4. No AHB Error Response on Overrun/Underrun

**Location**: `tidelink_fifo_mem.sv`, `tidelink_fifo_ctrl.sv`

When the FIFO is full (overrun) or empty (underrun), the AHB slave completes the transfer normally (`hresp=0`) and silently sets a sticky flag. The bus master receives no indication that the transfer failed.

**Impact**: Software must poll the STATUS register to discover errors. In a DMA scenario, the DMA engine has no way to know a write was discarded.

**Recommendation**: Assert `hresp=1` (ERROR) on overrun/underrun so the bus master can detect the failure immediately.

### 5. Returner Has No Retry Mechanism

**Location**: `tidelink_returner.sv`

If the returner receives an AHB error response (`hresp=1`), it sets the `master_error` sticky flag but does not retry the write. The credit delta or doorbell response is permanently lost.

**Impact**: Credit accounting between the pair can drift out of sync after a transient bus error. Recovery requires a full flush and re-handshake on both sides.

**Recommendation**: Add a configurable retry count (e.g. 1–3 retries) before latching `master_error`.

### 6. No Protection Against Partial Packet Writes

**Location**: `tidelink_fifo_ctrl.sv`

If a packet write is abandoned partway through (e.g. software crash, bus error, or the block is disabled mid-write), the FIFO is left in an inconsistent state:
- `packet_word_length` is non-zero (captured from address 0)
- The write pointer has not advanced
- Partial data occupies SRAM but the packet is not committed
- The only recovery is FLUSH, which discards all buffered data

**Recommendation**: Add a watchdog timer or explicit abort mechanism that can roll back a partial write without flushing the entire FIFO.

### 7. Pair Credit Counter Has No Underflow Guard

**Location**: `tidelink_apb_regs.sv` — pair credit counter decrement via 0x02C

Software writes to 0x02C unconditionally subtract from the pair credit counter. There is no check that the counter remains non-negative. An erroneous consume write can cause the counter to wrap, leading software to believe the remote side has billions of free credits.

**Recommendation**: Saturate at zero on decrement, or return an error indication.

### 8. Release Accumulator Race with Simultaneous Read and Write

**Location**: `tidelink_apb_regs.sv` — accumulators at 0x020 and 0x024

The W-add/R-clear accumulators handle simultaneous APB read and returner write in the same cycle. The `if-else if` chain gives read-clear priority over write-add, so if both occur in the same cycle the accumulator is cleared and the incoming write value is silently lost.

**Impact**: Low probability in practice (requires APB read at exact cycle of returner write), but the lost write means freed credits are permanently dropped, causing credit accounting drift between the pair.

**Recommendation**: Handle the simultaneous case explicitly by clearing the accumulator to the incoming write value (i.e. clear old total but retain the new delta), or use a two-stage handshake to prevent loss.

## Minor

### 9. Fixed 32-bit Data Width

**Location**: All modules — `SYS_DATA_W` parameter exists but SRAM interface and credit arithmetic assume 32-bit words

Although `SYS_DATA_W` is parameterised, the SRAM byte enables are hardcoded to 4 bits (`WREN[3:0]`), the credit-to-bytes conversion is hardcoded as `× 4`, and the SRAM variants are all 32-bit wide. Changing `SYS_DATA_W` would require significant rework.

**Recommendation**: Either remove the parameter (making 32-bit explicit) or fully parameterise the byte enable width and credit arithmetic.

### 10. No Hardware Flow Control on the AHB Slave

**Location**: `tidelink_fifo_mem.sv`

The AHB slave never asserts `hreadyout=0` to back-pressure the bus master. All flow control is software-managed (check credits before writing). A misbehaving or unaware bus master can write at full speed and cause overruns.

**Recommendation**: Consider de-asserting `hreadyout` when `credit_count == 0` to provide hardware-level back-pressure, at least as a configurable option.

### 11. No Identification or Version Register

**Location**: `tidelink_apb_regs.sv`

There is no peripheral ID, component ID, or version register. Software cannot distinguish TideLink from other peripherals at an unknown address, and cannot detect hardware version mismatches.

**Recommendation**: Add standard ARM PID/CID registers (0xFD0–0xFFC) or at minimum a version register.

### 12. `pslverr` Is Hardcoded to 0

**Location**: `tidelink_apb_regs.sv`

Writes to read-only registers and reads from write-only registers silently succeed. There is no APB error signalling for invalid accesses.

**Recommendation**: Assert `pslverr` for writes to RO registers and reads from WO registers.

### 13. Reset Deassertion Pulse Can Fire Spuriously

**Location**: `tidelink_apb_regs.sv` — reset synchroniser

The reset deassertion detector uses a two-stage synchroniser that correctly handles the async-to-sync transition and prevents metastability. However, if `hresetn` bounces during deassertion (goes low-high-low-high), each low-to-high transition resets the pipeline and produces a new deassertion pulse, causing multiple doorbell writes to the pair.

**Impact**: Multiple doorbell responses from the pair, each adding to the accumulator. Software would read an inflated credit count.

**Recommendation**: Add a debounce counter after the synchroniser to filter reset bounce.

### 14. Burst Transfers Accepted But Not Properly Handled

**Location**: `tidelink_fifo_ctrl.sv` — `valid_transfer` check

The `valid_transfer` signal checks only `htrans[1]`, which accepts both NONSEQ (`2'b10`) and SEQ (`2'b11`) transfers. However, the FIFO control logic has no burst-aware address tracking — it treats every beat as an independent single-beat transfer. A DMA engine issuing INCR or WRAP bursts will have its SEQ beats accepted, but the FIFO's completion and metadata logic assumes NONSEQ-only sequencing, which could cause incorrect behaviour.

**Recommendation**: Either add proper burst support (INCR at minimum) for DMA throughput, or explicitly reject SEQ transfers by checking `htrans == 2'b10`.

### 14a. Lane-Mask Handshake — End-to-End Hardware-Driven

**Location**: `tidelink_autoneg.sv` (master FSM), `axi_chiplet_controller.sv` (gate + register block), `Wlink.scala` (`link_lane_mask_hs_result @ 0x21C`, `link_lane_mask_peer @ 0x218`)

**Status (2026-05-08)**: The full hardware-driven peer-mask handshake is in tree and exercised end-to-end in UVM. After winning the I2C claim, the master FSM:
1. Sets the slave's address pointer to `0x0214` via a 2-byte `cmd_write_multiple` (no STOP) — `ST_NEGO_MASK_RD_ADDR` (state 4'd9).
2. Issues 4 `cmd_read` commands (with cmd_start on byte 0 for the repeated start, cmd_stop on byte 3) and pops the 4 bytes from the rd-data FIFO into `peer_{tx,rx}_lane_mask_r` — `ST_NEGO_MASK_RD_DATA` (state 4'd10). Bytes 2/3 are the unused upper half of the 32-bit register and are discarded.
3. Runs the crossover-identity comparator `mask_match = (local.tx == peer.rx) && (local.rx == peer.tx)` — combinational.
4. Writes the verdict byte (0x01 match / 0x02 fail) to peer's `link_lane_mask_hs_result @ 0x21C` via I2C — `ST_NEGO_MASK_RES_TX` (state 4'd8). The verdict byte is sourced from the comb comparator wire so the latch (`mask_hs_local_match_r` / `mask_hs_local_fail_r`) can be deferred to the RES_TX → DONE edge — latching earlier opens the gate while the FSM is still mid-write, which makes the wrapper latch role_lock, deassert nego_driving, and hand the AXIL bus to the bridge before bvalid is captured.

The wrapper-side gate (`mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i`) refuses `role_lock_reg` while the verdict is fail, and the sticky `nego_mask_mismatch` bit (NEGO_STATUS[9]) plus `nego_error_irq` fire on either side (master from its own `mask_hs_local_fail` flag, slave from the I2C-written `hs_result[1]`).

NEGO_CFG[6] = `mask_hs_auto_en` enables this path; with the bit clear the FSM takes the legacy direct POLL → DONE branch (no peer-mask read).

**Verification**:
- `test_top_peer_mask_match` and `test_top_peer_mask_mismatch_refused` — original SW-driven gate (Phase 1), still passing.
- `test_top_peer_mask_auto` — full HW-driven match path (state flow `4→9→10→8→5`, B's hs_result reads 0x01, role_lock asserts on both sides, A→B AHB traffic flows).
- `test_top_peer_mask_auto_mismatch` — full HW-driven fail path. With `B.tx_mask=0x7F` against `A.rx_mask=0xFF`, the comparator returns fail, FSM writes 0x02 to B's hs_result, gate stays closed, `nego_mask_mismatch` sticky on both sides.

**Pre-existing autoneg I2C ACK failure (resolved as part of Phase 2)**: Phase 2 bring-up uncovered three latent bugs in the autoneg ACK path:
1. `i2c_slv_addr_reg` defaulted to `7'd0` at POR — once `role_lock` latched the device-address mux switched mid-transaction from the autoneg `0x7E` to `i2c_slv_addr_reg=0x00` and the slave NACKed. Fixed by defaulting `i2c_slv_addr_reg` to `7'h7E` at POR.
2. The autoneg sequence used `\`uvm_create + \`uvm_send` (which randomizes after we set the txn fields) and `REG_*[14:0]` slicing on 12-bit parameters (returns 0). Both fixed.
3. The AXL drive logic had a stale-`axl_done_r` race plus an unconditional `m_axil_rready=1` drain that ate rvalid before AXL_RD_DATA captured it. Fixed by gating `AXL_IDLE` on `!axl_done_r` and removing the drain. The MASK_RES_TX (state 8) was also missing from `nego_driving`; widened to include states 8/9/10.

**Remaining**: Bring-up on PYNQ FPGA (still uses `mask_hs_bypass_i=1` strap pre-deployment). The pynq stress and `test_top_lane_mask_*` UVM family continue to bypass the gate.

### 14b. Autoneg-Driven Role-Lock Doesn't Carry A→B Traffic in `test_top_autoneg_basic`

**Location**: `test_top_autoneg_basic.sv` (and the FSM-driven role-lock release flow it exercises)

**Status (2026-05-08)**: After the Phase-2 autoneg ACK fixes (item 14a), the autoneg portion of `test_top_autoneg_basic` reports `won=1 / lost=1` correctly and both sides' `ROLE_CFG = 0x02 / 0x03` (lock + master/slave) latch as expected. Wlink's `link_status @ 0x234` reports `0x18` on both sides — `tx_active=1`, `rx_active=1`, `in_error_state=0`. By every observable register, the link is up. *But* the test's A→B AHB packet never reaches B's FIFO; the scoreboard reports `RX=0x00000000` for every payload word.

The same packet flow works identically in `test_top_peer_mask_auto` (which goes through the longer MASK_RD/RES_TX path before role_lock). The difference is the post-`role_lock` window: in peer-mask the test waits ~250 ms; in basic-autoneg it waits 100 µs (`wlink_link_up_wait = 10_000` cycles). Bumping the wait to 5 ms didn't change the outcome — link_status still reads `0x18` and traffic still doesn't flow, so it isn't simply training time.

Likely cause: Wlink's link-up handshake / FCSM credit grant is sensitive to the staggered `wlink_por_reset` release between the two sides. In autoneg-basic, B's role_lock latches ~13.6 ms before A's (B sees SDA-START first; A finishes its CLAIM/POLL later). B's Wlink runs alone through its training cycle while A's PHY is still in reset emitting whatever a held-PHY emits, and may end up in a state that doesn't recover once A comes online.

**Impact**: Autoneg-driven link bring-up cannot currently be validated end-to-end in pre-silicon UVM. Bring-up flows that don't use autoneg (`test_top_single_packet`, `test_top_bidirectional`, `test_top_peer_mask_auto`, etc.) are unaffected.

**Recommendation (deferred)**: Wave-debug the FCSM and PHY training signals from B (the early-locked side) starting at A's role_lock release time. If the FCSM is stuck in a credit-grant retry loop, an explicit `swreset` toggle after role_lock might recover. Alternatively, gate `role_lock_reg` to assert simultaneously on both sides via a sideband sync — out of scope for the current Phase 2 work.

**Reference**: See `test_top_autoneg_basic.sv` — DIAG read of ROLE_CFG/link_status/link_capab is in place to confirm the post-autoneg state. The test currently fails on scoreboard mismatches; the autoneg assertions (won/lost) all pass.

### 15. Credit Release Threshold Cannot Be Changed While Enabled

**Location**: `tidelink_apb_regs.sv`

The release threshold register is freely writable at any time, but changing it while packets are being read could cause inconsistent batching behaviour — a read_complete that was below the old threshold might suddenly exceed the new one, or vice versa.

**Recommendation**: Document that threshold changes should only be made while the FIFO is idle (no in-flight packets), or add gating logic.

## PTP Subsystem

### 16. Idle Gating Adds Variable Wait Time Before PTP TX

**Location**: `tidelink_ptp.sv` — TX path idle gating

The PTP TX path waits for `tx_router_idle` before asserting FC valid and capturing the transmit timestamp. If other FC nodes (AXI channels, mailbox FIFO) are actively transmitting, this wait time is variable and unbounded in the worst case. While this does not affect timestamp accuracy (the capture occurs at the actual TX moment), it increases the total exchange latency and limits the maximum PTP update rate under heavy link traffic.

**Impact**: PTP exchange latency increases proportionally to link utilisation. In pathological cases, a sustained burst of AXI or mailbox traffic could delay PTP exchanges indefinitely.

**Recommendation**: Assign the PTP FC node the highest TX router priority (already done) and consider adding a maximum wait timeout with an error indication.

### 17. RX-Side Jitter Not Eliminated

**Location**: `tidelink_ptp.sv` — RX path timestamp capture

The Wlink RX pipeline (deserialiser, link layer, FC demux) introduces variable latency that cannot be gated from the receiver's perspective. The t2 and t4 timestamps are captured at the FC RX interface output, not at the PHY, so they include this pipeline jitter.

**Impact**: Residual jitter on receive timestamps (t2, t4) limits the achievable synchronisation accuracy. The magnitude depends on the Wlink RX pipeline depth and clock domain crossing stages.

**Recommendation**: Characterise the RX pipeline jitter via the `tidelink_ptp_stress` UVM environment and account for it in the servo loop filter bandwidth.

### 18. Software-Mediated Servo Loop (Tier 1)

**Location**: Software — PTP offset computation and clock discipline

The offset computation, PI filtering, and PHC adjustment are performed entirely in software via interrupt-driven exchanges. This introduces scheduling jitter and limits the servo bandwidth to the software update rate.

**Impact**: Steady-state synchronisation accuracy is bounded by the software loop latency (typically microseconds). A hardware servo (Tier 2) could achieve sub-microsecond accuracy.

**Recommendation**: Acceptable for the current use case. Document the expected accuracy bounds. Consider a hardware servo for future revisions requiring tighter synchronisation.

### 19. PHC hw_capture and Software CAPTURE Share Clock Core

**Location**: PHC — `hw_capture` input and software CAPTURE register

The PHC has a single time counter that is shared between the hardware capture path (`hw_capture` input, writing to HW_CAP registers) and the software capture path (CAPTURE register, writing to CAP registers). If both fire simultaneously, one capture may be lost or the clock core may produce undefined behaviour.

**Impact**: Low probability in practice (requires software CAPTURE at the exact cycle of a PTP hw_capture event), but could corrupt a timestamp if it occurs.

**Recommendation**: This is mitigated by Option B, which provides a second capture register bank (HW_CAP_*) independent of the software capture bank (CAP_*). Ensure software does not issue CAPTURE during an active PTP exchange.

## Servo Optimisation Trade-offs

### 20. Sub-Nanosecond Precision Dropped

**Location**: `tidelink_ptp_servo.sv` — timestamp format reduced from 110-bit to 78-bit

Sub-nanosecond fields have been removed from the timestamp representation. This is acceptable at Cortex-M0 clock rates where the system clock period is much larger than one nanosecond, so the additional precision provided no practical benefit.

**Impact**: None at target clock rates. Would need to be revisited if the design were retargeted to a high-frequency fabric with sub-nanosecond synchronisation requirements.

### 21. PI Controller Latency Increased

**Location**: `tidelink_ptp_servo.sv` — combinational multiplier replaced with iterative shared multiplier

The PI controller now uses an iterative shared multiplier instead of a dedicated combinational multiplier. This adds approximately 64 clock cycles of latency per PTP exchange (two sequential multiply operations). This is negligible compared to the PTP exchange interval (typically milliseconds).

**Impact**: Servo computation takes ~64 extra cycles per exchange. No measurable effect on synchronisation accuracy or convergence rate at expected exchange intervals.

### 22. Large Offset Forces Phase Step

**Location**: `tidelink_ptp_servo.sv` — offset decision logic

When |sec_diff| > 1, the servo forces a phase step (direct PHC set) rather than applying the PI controller. This is correct behaviour for PTP steady-state operation: offsets larger than one second indicate the clocks are too far apart for the PI loop to converge efficiently, so a coarse adjustment is appropriate.

**Impact**: Correct design intent. The PI controller only operates on offsets where it can converge within a reasonable number of exchanges.

## Design Holes

### 23. No End-to-End Packet Integrity Check

**Location**: `tidelink_fc_adapter.sv`, `tidelink_fifo_ctrl.sv` — FC data path

The FIFO data path has no packet-level checksum, CRC, or sequence number. While the Wlink link layer provides CRC/ECC on individual FC transfers, there is no application-layer integrity mechanism to detect higher-level corruption such as a missed FC beat, a duplicated write, or software writing to the wrong FIFO address. The PTP subsystem has a 16-bit sequence number (`hw_seq_num`), but the mailbox FIFO path has none.

**Impact**: A silent data corruption (e.g. from a pointer arithmetic bug or an undetected overrun) would be delivered to the reader as a valid packet. There is no way for the receiver to distinguish a corrupted packet from a correct one.

**Recommendation**: Add an optional packet CRC (computed on write, checked on read) or at minimum a monotonic sequence number in the packet header so the reader can detect gaps or reordering.

### 24. No Hardware Timeout for Stalled Credit Flow

**Location**: `tidelink_fifo_ctrl.sv`, `tidelink_returner.sv` — credit return path

If the remote side stops returning credits (e.g. due to a crash, link failure, or misconfiguration), the local TX path will stall indefinitely with `credit_count == 0`. There is no hardware watchdog or timeout mechanism to detect this condition. Software must poll the credit count and infer a stall, but there is no interrupt or timeout flag to signal the condition.

**Impact**: A unilateral remote failure causes a silent, indefinite stall on the local TX path. In an interrupt-driven flow, the CPU may never be notified that the link is effectively dead.

**Recommendation**: Add a configurable credit stall watchdog timer that asserts an interrupt if `credit_count` remains zero for longer than a programmable threshold.

### 25. Configuration Registers Not Lockable After Initialisation

**Location**: `tidelink_apb_regs.sv` — `pair_base_addr`, `release_threshold`, `pair_credit_counter` registers

Critical configuration registers (pair base address, release threshold) are freely writable at any time, including while the FIFO is active and packets are in flight. An erroneous or malicious software write to `pair_base_addr` mid-stream would redirect returner writes to an arbitrary address, potentially corrupting remote memory.

**Impact**: No protection against accidental reconfiguration during operation. A single stray write can break the credit return path and corrupt remote state.

**Recommendation**: Add a lock bit (write-once after configuration) that prevents modification of critical registers until the next reset, similar to the role lock in `axi_chiplet_controller`.

### 26. FC Adapter TX Arbitration Can Starve Data Path

**Location**: `tidelink_fc_adapter.sv` — TX arbitration (returner > TX aperture)

The returner sideband channel has unconditional priority over the TX aperture data path. While sideband writes are normally infrequent, a pathological scenario (e.g. rapid credit release batches combined with doorbell + reset responses) could produce a sustained burst of returner traffic that blocks the TX aperture indefinitely. There is no fairness counter or maximum-hold limit.

**Impact**: In the worst case, a burst of sideband traffic could delay FIFO data transmission for an unbounded number of cycles, causing the remote reader to time out or starve.

**Recommendation**: Add a maximum consecutive sideband grant counter (e.g. 4–8 beats) after which the TX aperture gets at least one grant, preventing indefinite starvation.

### 27. No Coordinated Reset Protocol Between Paired Chiplets

**Location**: `tidelink_top.sv`, `tidelink_returner.sv` — reset handling

When one chiplet resets, it sends a doorbell (channel 2) to its pair via the returner. However, there is no handshake to ensure the pair has drained its in-flight packets before the resetting side reinitialises. The pair may have packets in the Wlink TX pipeline that arrive after the reset, corrupting the freshly-initialised FIFO state.

**Impact**: A unilateral reset during active traffic can leave the pair in an inconsistent state. The only safe recovery is for both sides to flush and re-handshake, but this is not enforced in hardware.

**Recommendation**: Define a reset protocol: the resetting side should drain its TX pipeline (wait for `tx_router_idle`), send a FLUSH command, wait for acknowledgement, then reset. At minimum, document the required software sequence.

## Verification Gaps

### 28. Error Recovery Path Not Tested End-to-End

**Location**: `cocotb/tidelink_system/`, `uvm/tidelink_system/`

No test exercises the full error recovery sequence: returner `hresp=1` → `master_error` flag set → software detects via STATUS poll → FLUSH → reconfigure → resume normal operation. Individual error flags are tested, but the complete recovery flow is not.

**Impact**: The recovery path described in the user guide has never been validated. A real error event in deployment would rely on untested software sequences.

**Recommendation**: Add an end-to-end error injection test that forces a returner AHB error, verifies the sticky flag, performs the documented recovery procedure, and confirms that normal packet flow resumes without credit accounting drift.

### 29. CDC Multi-Clock Ratio Variations Not Exercised

**Location**: `cocotb/tidelink_ptp/`, `uvm/tidelink_ptp_stress/`

All cocotb tests run with `phc_clk == hclk` or a fixed ratio. No test varies the `phc_clk:hclk` frequency ratio to exercise the CDC handshake paths under different timing relationships. The Spyglass formal CDC run verifies structural correctness but does not exercise functional behaviour under asynchronous clock ratios.

**Impact**: CDC bugs that only manifest at specific frequency ratios (e.g. back-to-back handshake requests where ack returns in the same cycle as a new request) would not be caught.

**Recommendation**: Add parameterised tests with `phc_clk` at 0.5×, 0.7×, 1.3×, and 2× `hclk` to exercise the CDC handshake paths under realistic asynchronous conditions.

### 30. Address Translator Not Tested in tidelink_top Integration Context

**Location**: `cocotb/tidelink_addr_translator/` (standalone), `cocotb/tidelink_top/` (integration)

The address translator has 34 thorough standalone cocotb tests, but it is not exercised in the `tidelink_top` integration or system-level environments. No test verifies that address translation works correctly when traffic is flowing through the full Wlink → XHB500 → address translator → AHB manager path.

**Impact**: Integration-level issues (e.g. address width mismatches at the XHB500 boundary, CAM lookup timing under Wlink backpressure) would not be detected.

**Recommendation**: Add integration tests in `tidelink_top` or `tidelink_system` that configure address translation rules and verify translated addresses arrive correctly at the AHB manager output.

### 31. Pair Credit Counter Underflow Not Tested

**Location**: `cocotb/tidelink_apb_regs/`, `cocotb/tidelink_py_pair/`

No test verifies the behaviour when software writes to the pair credit consume register (0x02C) more times than credits are available. Shortcoming #7 identifies this as a risk, but no regression test confirms whether the counter wraps or saturates, and no test verifies recovery.

**Recommendation**: Add a test that deliberately over-consumes pair credits and verifies the resulting counter value and system behaviour.

### 32. Partial Packet Abandon and Recovery Not Tested

**Location**: `cocotb/tidelink_fifo/`, `cocotb/tidelink_system/`

No test writes a partial packet (e.g. header + 2 of 10 words) and then abandons the write (via reset, disable, or simply stopping). Shortcoming #6 identifies the resulting inconsistent state, but no test verifies what happens to the FIFO pointers, credit count, or subsequent packets after an abandoned write.

**Recommendation**: Add tests for: (a) partial write followed by FLUSH and resume, (b) partial write followed by a new packet write without FLUSH, to characterise the failure mode and verify recovery.

### 33. No Throughput or Latency Characterisation Tests

**Location**: All test environments

No test measures or asserts on performance metrics:
- Maximum sustainable packet throughput (packets/second at various sizes)
- End-to-end latency (TX aperture write to RX FIFO committed IRQ)
- Credit return latency (read_complete to returner write arrival at pair)
- Throughput degradation under bidirectional load

**Impact**: Performance regressions could be introduced without detection. Integration teams have no validated throughput figures to design against.

**Recommendation**: Add a performance characterisation test suite that measures and records these metrics, with regression thresholds to catch degradation.

### 34. PTP Multi-Hop Chaining Not Verified

**Location**: `tidelink_ptp.sv` — `PHC_LOCK_GATE_EN` parameter, `cocotb/tidelink_ptp/`

The PTP module has a `PHC_LOCK_GATE_EN` parameter and `phc_locked` signal intended to support multi-hop PTP chaining (chiplet A → B → C, where B only begins syncing C after B has locked to A). However, no test exercises this feature. No multi-hop testbench exists.

**Impact**: The gating logic may not work correctly. A three-chiplet deployment relying on cascaded PTP synchronisation would be using untested hardware.

**Recommendation**: Add a multi-hop test environment with at least three PTP instances in a chain, verifying that downstream synchronisation only begins after upstream lock is achieved.

### 35. Coordinated Chiplet Reset Sequence Not Tested

**Location**: `cocotb/tidelink_system/`

The `test_reset_recovery` test covers a mid-FIFO reset on a single side, but no test exercises a coordinated reset across both chiplets in a pair. Specifically, no test verifies: (a) what happens when one side resets while the other has packets in the Wlink TX pipeline, (b) whether the doorbell reset notification arrives correctly and the pair recovers, (c) behaviour under simultaneous reset of both sides.

**Recommendation**: Add paired reset tests covering unilateral reset during active traffic, bilateral simultaneous reset, and staggered reset with in-flight packets.

## TideChart / PUF Integration

### 36. PUF SRAM Reads Have Lowest Arbiter Priority

**Location**: `tidelink_fifo_mem.sv` — 3-way SRAM arbiter

PUF reads have the lowest priority in the 3-way SRAM arbiter (FC writes > AHB reads/writes > PUF reads). If the FIFO is receiving heavy incoming traffic at boot time (e.g., the remote chiplet begins transmitting before PUF reads complete), PUF reads may be delayed indefinitely.

**Impact**: PUF entropy collection could take significantly longer than expected under concurrent FIFO traffic. In pathological cases, PUF reads may not complete before firmware enables the FIFO, rendering the PUF data invalid.

**Recommendation**: Complete all PUF SRAM reads before enabling the FIFO (Phase 2 of the bring-up sequence). Document that PUF reads must occur during the boot window when no FIFO traffic is active.

### 37. PUF Data Only Valid Before Software Writes to SRAM

**Location**: `tidelink_fc_adapter.sv` — PUF read FSM, `tidelink_fifo_mem.sv` — shared SRAM

The PUF entropy source relies on uninitialized SRAM contents. Once software enables the FIFO and packets are written, the SRAM contents are overwritten with FIFO data. There is no hardware mechanism to reserve a portion of SRAM for PUF use or to detect that PUF data has been invalidated by a FIFO write.

**Impact**: If PUF reads are issued after FIFO traffic has started, the returned data is deterministic FIFO content, not PUF entropy. Software that relies on this data for key generation or device authentication would use predictable values.

**Recommendation**: Enforce in firmware that PUF reads complete before FIFO enable. Consider adding a hardware lock bit that disables PUF reads after the first FIFO write, providing a clear error indication.

### 38. tc_axis_* Interface Has No Flow Control Credits

**Location**: `tidelink_top.sv` — tc_axis_* ports, `tidelink_fc_adapter.sv` — PKT_EXT TX path

The AXI-Stream interface between TideLink and the TideChart controller relies solely on `tready` backpressure for flow control. There is no credit-based scheme, no packet-level acknowledgement, and no timeout mechanism. If the TideChart controller deasserts `tc_axis_tx_tready` for an extended period, incoming PKT_EXT packets from the FC RX path are stalled, which in turn stalls the FC node and may affect FIFO_DATA and SIDEBAND packet reception on shared FC infrastructure.

**Impact**: A slow or unresponsive TideChart controller can back-pressure the entire FC RX path. This is a head-of-line blocking risk.

**Recommendation**: Add a small elastic FIFO (4-8 entries) on the `tc_axis_tx_*` path to decouple PKT_EXT stalls from the FC RX pipeline. Alternatively, add a configurable timeout that drops stalled PKT_EXT packets and sets an error flag.

## Summary

| # | Severity | Shortcoming |
|---|----------|-------------|
| 1 | Critical | No credit underflow protection (BUG-002) |
| 2 | Critical | Single packet in-flight limitation |
| 3 | Moderate | No hardware packet size validation |
| 4 | Moderate | No AHB error response on overrun/underrun |
| 5 | Moderate | No returner retry on bus error |
| 6 | Moderate | No partial packet write recovery |
| 7 | Moderate | Pair credit counter underflow risk |
| 8 | Moderate | Accumulator read/write race condition |
| 9 | Minor | Fixed 32-bit data width despite parameter |
| 10 | Minor | No hardware back-pressure via hreadyout |
| 11 | Minor | No ID/version register |
| 12 | Minor | pslverr always 0 |
| 13 | Minor | Reset deassertion glitch sensitivity |
| 14 | Minor | Burst transfers accepted but not properly handled |
| 15 | Minor | Threshold change while enabled |
| 16 | Moderate | PTP idle gating adds variable TX wait time |
| 17 | Moderate | PTP RX-side jitter not eliminated |
| 18 | Minor | PTP servo loop is software-mediated (Tier 1) |
| 19 | Minor | PHC hw_capture and software CAPTURE share clock core |
| 20 | Minor | Sub-nanosecond precision dropped (servo optimisation) |
| 21 | Minor | PI controller latency increased (servo optimisation) |
| 22 | Minor | Large offset forces phase step (servo, by design) |
| 23 | Moderate | No end-to-end packet integrity check |
| 24 | Moderate | No hardware timeout for stalled credit flow |
| 25 | Moderate | Configuration registers not lockable after init |
| 26 | Minor | FC adapter TX arbitration can starve data path |
| 27 | Moderate | No coordinated reset protocol between paired chiplets |
| 28 | Moderate | Error recovery path not tested end-to-end |
| 29 | Moderate | CDC multi-clock ratio variations not exercised |
| 30 | Minor | Address translator not tested in integration context |
| 31 | Minor | Pair credit counter underflow not tested |
| 32 | Minor | Partial packet abandon and recovery not tested |
| 33 | Minor | No throughput or latency characterisation tests |
| 34 | Minor | PTP multi-hop chaining not verified |
| 35 | Minor | Coordinated chiplet reset sequence not tested |
| 36 | Minor | PUF SRAM reads have lowest arbiter priority — may be delayed at boot |
| 37 | Moderate | PUF data only valid before software writes to SRAM |
| 38 | Moderate | tc_axis_* interface has no flow control credits |
