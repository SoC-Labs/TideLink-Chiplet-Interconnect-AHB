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
