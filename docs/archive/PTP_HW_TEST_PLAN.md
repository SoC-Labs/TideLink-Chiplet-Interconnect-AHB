# TideLink PTP — Hardware Test Plan (bridge1 PYNQ-Z2 Pair)

**Status:** Design document — investigation only; no RTL or BD work in scope of this file.
**Anchor:** `main` @ `9cbb649` (top of branch at write-time; spec quoted commit was `fbdebc2`), submodule `deps/axi-chiplet-controller` @ `2f602d1`.
**Target hardware:** bridge1 PYNQ-Z2 pair — z2_02 @ 192.168.4.101 (die_a / master) ↔ z2_03 @ 192.168.6.101 (die_b / slave), reached only via mapstone-dev, leased through fpgahub.
**Author:** Test-plan investigation, 2026-05-22.

---

## 0. Executive summary

TideLink already ships a complete single-phase PTP RTL stack: `tidelink_ptp` (message TX/RX + hw_capture pulse), `tidelink_ptp_servo` (autonomous GM/Sub PI loop with phase-step + frequency-steer), and `tidelink_phc_cdc` (six CDC paths to/from the external PHC). The hardware sync initiator can fire SYNC autonomously without CPU intervention. Verification at module/system/chain level (cocotb `tidelink_ptp*`, UVM `tidelink_ptp_chain`, `tidelink_ptp_stress`) is in place.

**However: the PHC IP is not instantiated on either FPGA.** Every `pynq-z2-pair*` BD wires the `phc_nanoseconds` / `phc_seconds` / `phc_hw_cap_*` inputs to `xlconstant=0` and the `phc_hw_set_*` / `phc_hw_adj_*` outputs are NOT consumed (no PHC counter to receive them). The BD header explicitly calls this out as "Q4 / PHC tie-off … A proper PHC IP instance will replace these in Q4 once ptp-hardware-clock-ahb is integrated." Without a real PHC the loop is open: hw_capture has nothing to latch, the servo's set_time / NS_INCR_FRAC adjustments go nowhere, and the design behaves like a SYNC/DELAY_REQ packet generator with frozen 0-valued timestamps.

This document therefore plans:
1. Inventory of what already exists on `main` (RTL/regs/scripts/sim collateral).
2. Specifically what BD/wrapper integration is needed before any HW PTP test can produce a meaningful measurement.
3. A capture / measurement mechanism for cross-board offset measurement.
4. The four bring-up scripts (sync, freq-track, offset-step, soak) with prerequisites, sequences, pass criteria.
5. Phased rollout with gating dependencies and risks.

Phases 1–2 (sanity + dual-PHC sync) are gated on the PHC IP integration. Phase 3 (tracking) and Phase 4 (soak) are then incremental.

---

## 1. PHC interface inventory

### 1.1 PHC RTL (sibling repo, `~/SoCLabs/ptp-hardware-clock-ahb`)

- **Top-level module:** `phc` — `src/rtl/phc.sv` (APB slave + two hardware servo source ports + Ethernet capture inputs + PPS output). Designed for 200–250 MHz; `DEFAULT_NS_INCR = 8'd4` (4 ns/cycle at 250 MHz). For our 50 MHz FPGA `hclk` / `phc_clk` the operator MUST program `NS_INCR = 20` (20 ns/cycle = 50 MHz) before the counter will tell real time.
- **APB register file:** `phc_apb_regs` — `src/rtl/phc_apb_regs.sv`, described by `src/rdl/phc_apb_regs.rdl` (also mirrored in tidelink as `src/rdl/phc_regs.rdl`).
- **Software helpers (optional):** `src/sw/phc.c`, `phc.h`, `phc_apb_regs.generated.h` (constants for the bare-metal driver — useful as a reference for /dev/mem ports).

### 1.2 PHC APB register map (RDL anchor: `phc_apb_regs.rdl`)

Base address is **per-board** and depends on the BD memory map (TBD; see §2.1). Offsets are relative to that base:

| Offset | Register | Field | Width | Access | Reset | Purpose |
|---|---|---|---|---|---|---|
| 0x000 | CTRL | EN[0] | 1 | RW | 0 | Clock enable. Counter increments only while 1. |
|  | CTRL | SET_TIME[1] | 1 | W1P-SC | 0 | Self-clearing pulse: atomically loads SET_SECONDS_LO/HI + SET_NANOSECONDS into the counter, clears sub-ns accumulator. |
|  | CTRL | CAPTURE[2] | 1 | W1P-SC | 0 | Self-clearing pulse: latches current time into CAP_* (Region 1). |
| 0x004 | STATUS | RUNNING[0] | 1 | RO | 0 | Mirror of CTRL.EN. |
|  | STATUS | PPS[1] | 1 | RO-rclr | 0 | Sticky PPS, clear-on-read. |
|  | STATUS | ALARM_HIT[2] | 1 | RO | 0 | Alarm comparator match. |
| 0x008 | NS_INCR | NS_INCR[7:0] | 8 | RW | 4 | **Integer ns per cycle.** Programme to 20 for our 50 MHz `phc_clk`. |
| 0x00C | NS_INCR_FRAC | NS_INCR_FRAC[31:0] | 32 | RW | 0 | **Fractional-ns increment per cycle.** This is the frequency-steering knob the software servo writes. Q0.32; +1 LSB ≈ 1/2^32 ns/cycle ≈ 0.0116 ppb at our cycle rate. |
| 0x010 | SET_SECONDS_LO | [31:0] | 32 | RW | 0 | Loaded on SET_TIME pulse. |
| 0x014 | SET_SECONDS_HI | [15:0] | 16 | RW | 0 | Loaded on SET_TIME pulse. |
| 0x018 | SET_NANOSECONDS | [29:0] | 30 | RW | 0 | Loaded on SET_TIME pulse (0–999,999,999). |
| 0x01C | INT_EN | PPS_IRQ_EN, ALARM_IRQ_EN | 1+1 | RW | 0 | Interrupt enables. |
| 0x020 | CAP_SECONDS_LO | [31:0] | 32 | RO | 0 | **Software capture** (CTRL.CAPTURE pulse) — see §3 for measurement use. |
| 0x024 | CAP_SECONDS_HI | [15:0] | 16 | RO | 0 |  |
| 0x028 | CAP_NANOSECONDS | [29:0] | 30 | RO | 0 |  |
| 0x02C | CAP_NS_FRAC | [31:0] | 32 | RO | 0 |  |
| 0x030 | ALARM_SECONDS_LO | [31:0] | 32 | RW | 0 | Alarm match value (lower 32 b sec). |
| 0x034 | ALARM_SECONDS_HI | [15:0] | 16 | RW | 0 |  |
| 0x038 | ALARM_NANOSECONDS | [29:0] | 30 | RW | 0 |  |
| 0x03C | ALARM_CTRL | ARM[0], AUTO_DISARM[1] | 1+1 | RW | 0 | Useful for scheduled cross-board events. |
| 0x040 | HW_CAP_SECONDS_LO | [31:0] | 32 | RO | 0 | **Hardware capture** (latched by tidelink_ptp's `phc_hw_capture` pulse on FC handshake). |
| 0x044 | HW_CAP_SECONDS_HI | [15:0] | 16 | RO | 0 |  |
| 0x048 | HW_CAP_NANOSECONDS | [29:0] | 30 | RO | 0 |  |
| 0x04C | HW_CAP_NS_FRAC | [31:0] | 32 | RO | 0 |  |
| 0x060–0x06C | ETH_RX_CAP_* | … | — | RO | 0 | Ethernet PTP RX capture (not used by TideLink path). |
| 0x080–0x08C | ETH_TX_CAP_* | … | — | RO | 0 | Ethernet PTP TX capture. |
| 0x0A0 | SERVO_CTRL | SRC_SEL[0] | 1 | RW | 0 | 0 = servo source 0 (TideLink PTP), 1 = source 1 (HA1588). Keep at 0. |
|  | SERVO_CTRL | HA1588_SERVO_EN[1] | 1 | RW | 0 | Leave 0 — not wired for FPGA build. |
| 0x0A4 | SYNC_INTERVAL | [29:0] | 30 | RW | 0x3B9AC9FF | Mirrors HW sync interval. |
| 0x0A8 | SERVO_STATUS | LOCKED[0], PHASE_STEP_ACTIVE[1] | 1+1 | RO | 0 |  |

**Units:**
- Integer ns counter (`NS_INCR`) is plain nanoseconds.
- Fractional accumulator (`NS_INCR_FRAC`) is Q0.32 — overflow adds 1 ns. `+1 ppm` of clock period = adjust `NS_INCR_FRAC` by `(2^32 × 1e-6 × cycle_ns) / cycle_ns ≈ 4294.97`. **For a 50 MHz / 20 ns cycle, 1 ppm ≈ 4295 LSBs**; for 100 MHz / 10 ns cycle, 1 ppm ≈ 4295 LSBs (independent of cycle rate because the units cancel — confirm in HW with a controlled drift).

### 1.3 TideLink-side wiring contract (already on `main`)

`src/rtl/tidelink_top.sv` exposes the full PHC interface at the top level (cited line numbers from `git show HEAD:src/rtl/tidelink_top.sv`):

- Lines 82–83: `phc_clk`, `phc_resetn` (clock and reset for the PHC counter — may be separate from `hclk`; CDC bridge handles it).
- Lines 198–207: `ahb_ptp_*` — AHB slave for SYNC/DELAY_REQ TX trigger (4-bit haddr; bit `addr[0]` = msg_type).
- Line 212: `phc_hw_capture` — pulse OUT to PHC `hw_capture_0_i`.
- Lines 217–219: `phc_nanoseconds[29:0]`, `phc_seconds[47:0]`, `phc_pps` — counter outputs IN from PHC (HW sync initiator timing).
- Lines 224–226: `phc_hw_cap_seconds[47:0]`, `phc_hw_cap_nanoseconds[29:0]`, `phc_hw_cap_sub_nanoseconds[31:0]` — latched timestamps IN from PHC `hw_cap_*_0_o`.
- Lines 231–235: `phc_hw_set_time`, `phc_hw_set_seconds[47:0]`, `phc_hw_set_nanoseconds[29:0]`, `phc_hw_adj_valid`, `phc_hw_adj_ns_incr_frac[31:0]` — servo's outputs to PHC `hw_set_*_0_i` / `hw_adj_*_0_i`.
- Line 242: `phc_locked_i` — gate for multi-hop chain (tie 1'b1 for the bridge1 two-board case).
- Line 255: `ptp_irq` — to PS IRQ_F2P[3] (already routed in pair BD).

CDC bridge module `tidelink_phc_cdc` (instanced in `tidelink_top.sv:1054`) has six labelled paths; the only requirement is that `phc_clk` is a sensible clock (need not be phase-aligned to `hclk`). In the bring-up wrapper the two clocks share a single MMCM output so the CDC degenerates to pipeline latency.

### 1.4 TideLink PTP registers (RDL: `src/rdl/tidelink_ptp_regs.rdl`, decode in `src/rtl/fifo/tidelink_apb_regs.sv`)

All offsets are from the TideLink unified APB base. In the pair BD the APB lives at MMIO `0x4403_0000`, so absolute addresses are APB-base + offset.

| Offset | Register | Bits / Field | Purpose |
|---|---|---|---|
| **Region 1 — basic PTP (paddr[7:5]=001, slots 5/6/7)** |
| 0x2034 | PTP_CTRL | [0] enable, [1] clear (W1P), [2] rx_valid (RO), [6:3] rx_msg_type (RO) | Enable PTP. Bits 2/6:3 set on RX. |
| 0x2038 | PTP_RX_PAYLOAD | [31:0] payload (RO) | Reading clears `rx_valid`. |
| 0x203C | PTP_STATUS | [0] tx_idle, [1] tx_pending | tx_router_idle mirror; tx_pending = waiting for idle. |
| **Region 2 — HW sync initiator + servo cfg (paddr[7:5]=010)** |
| 0x2040 | HW_SYNC_CTRL | [0] hw_sync_en, [1] seq_clear (W1C), [2] force_en | Hardware autonomous SYNC generator. Bit[2] bypasses `phc_locked_i` gate. |
| 0x2044 | HW_SYNC_INTERVAL | [29:0] ns | Default 999_999_999 (~1 Hz). Programme to e.g. 7_812_500 (128 Hz) for fast acquisition. |
| 0x2048 | HW_SYNC_STATUS | [0] active, [1] busy, [17:2] seq_num, [18] phc_locked | Phc_locked bit only meaningful when PHC_LOCK_GATE_EN=1. |
| 0x204C | SERVO_CTRL | [0] enable, [1] mode (0=GM, 1=Sub) | Autonomous servo on/off + role select. |
| 0x2050 | SERVO_KP | [31:0] Q0.32 | PI proportional gain. UVM chain test uses 0x0800_0000 (~0.03125). |
| 0x2054 | SERVO_KI | [31:0] Q0.32 | PI integral gain. UVM uses 0x0080_0000 (~0.00195). |
| 0x2058 | SERVO_STEP_THRESH | [31:0] ns | If `|offset| > step_thresh` → phase step via SET_TIME; else frequency steer. UVM uses 1_000_000 (1 ms). |
| 0x205C | SERVO_STATUS | [0] locked, [1] active | RO. |
| **Region 3 — servo status (paddr[7:5]=011, slots 0/1/2)** |
| 0x2060 | SERVO_DELAY | [31:0] ns (RO) | Last computed one-way delay. |
| 0x2064 | SERVO_NS_FRAC | [31:0] (RO) | Current NS_INCR_FRAC the servo is driving. |
| 0x2068 | (SERVO offset readback — `current_frac_r` in RTL) | RO | Plumbed to addr 3'h7 of servo_reg. |
| **Mailbox (paddr[7:5]=011, slots 2..5)** |
| 0x2068 | MBOX_SEC_LO | [31:0] | Cross-board timestamp mailbox written by GM-side SIDEBAND. |
| 0x206C | MBOX_SEC_HI | [15:0] |  |
| 0x2070 | MBOX_NS | [29:0] |  |
| 0x2074 | MBOX_SUB_NS | [31:0] |  |

(Refer to `docs/REGISTER_MAP.md` lines 102–112 and `src/rtl/fifo/tidelink_apb_regs.sv:410–426` for the authoritative decode.)

---

## 2. What is on `main` vs what is missing

### 2.1 What is already on `main`

| Item | Path | State |
|---|---|---|
| `tidelink_ptp` (TX/RX FSM, hw_capture pulse, idle-gating, RX irq) | `src/rtl/tidelink_ptp.sv` | Complete, cocotb-clean. |
| `tidelink_ptp_servo` (GM/Sub PI loop, phase-step + freq-steer) | `src/rtl/tidelink_ptp_servo.sv` | Complete, cocotb `tidelink_ptp_servo` passing. |
| `tidelink_phc_cdc` (6 CDC paths) | `src/rtl/tidelink_phc_cdc.sv` | Complete, cocotb `tidelink_phc_cdc` passing. |
| PHC outputs/inputs threaded through `tidelink_top` | `src/rtl/tidelink_top.sv:82–255, 931–1102` | Complete. |
| PHC IP RTL (separate repo) | `~/SoCLabs/ptp-hardware-clock-ahb/src/rtl/phc.sv` | Complete IP, APB slave. |
| TideLink PTP register decode | `src/rtl/fifo/tidelink_apb_regs.sv:410–426` | Complete. |
| PTP RDL definitions | `src/rdl/tidelink_ptp_regs.rdl`, `src/rdl/phc_regs.rdl` | Complete. |
| `ptp_irq` routed to PS IRQ_F2P[3] | `fpga/targets/pynq-z2-pair/tidelink_design.tcl:441–442` | Wired. |
| AHB PTP TX port routed (4 KB @ 0x4402_0000) | same TCL, lines 396–397; address line 489 | Wired. |
| Cocotb module-level PTP tests | `cocotb/tidelink_ptp/`, `cocotb/tidelink_ptp_servo/`, `cocotb/tidelink_phc_cdc/` | Functional. |
| UVM PTP chain tests | `uvm/tidelink_ptp_chain/tests/test_chain_convergence.sv` etc. (7 chain tests) | Functional. |
| UVM PTP stress | `uvm/tidelink_ptp_stress/tests/ptp_*` | Functional. |
| Spec docs | `docs/PTP_PROTOCOL.md`, `docs/REGISTER_MAP.md` (§3 PHC) | Authoritative. |
| Bring-up scripts (Wlink lock only) | `pynq_host/scripts/bringup_pair_converge.sh`, `wlink_probe.sh`, `deploy_pair*.sh` | Lane-lock + APB observability, NO PTP. |
| Bare /dev/mem MMIO shim | `pynq_host/bare_overlay.py` | Generic — usable for PHC/PTP regs once PHC base is added. |

### 2.2 What is missing — blocking gates

1. **PHC IP not in BD.** `fpga/targets/pynq-z2-pair/tidelink_design.tcl:262–308` instantiates `xlconstant` cells (`xlconst_phc_ns`, `xlconst_phc_sec`, `xlconst_phc_cap_sec`, `xlconst_phc_cap_ns`, `xlconst_phc_cap_subns`) driving the PHC ports of `tidelink_0` with zeros. The header comment at lines 39–49 explicitly flags this as Q4 deferred work. The `phc_hw_set_*` / `phc_hw_adj_*` outputs from `tidelink_top` are left dangling.
   - **Required:** package the `phc` module (`~/SoCLabs/ptp-hardware-clock-ahb/src/rtl/phc.sv`) as a Vivado IP, give it an APB slave on a 6th AXI-Lite-AHB-bridged port (or chain it on the existing AHB-bus master through an APB bridge), and connect:
     - `clk = phc_clk` (clk_wiz clk_out2, 50 MHz), `resetn = peripheral_aresetn`.
     - `hw_capture_0_i ← tidelink_0/phc_hw_capture`.
     - `hw_cap_seconds_0_o → tidelink_0/phc_hw_cap_seconds` (and ns / sub_ns analogues).
     - `hw_set_time_0_i ← tidelink_0/phc_hw_set_time`; `hw_set_seconds_0_i ← phc_hw_set_seconds`; `hw_set_nanoseconds_0_i ← phc_hw_set_nanoseconds`.
     - `hw_adj_valid_0_i ← phc_hw_adj_valid`; `hw_adj_ns_incr_frac_0_i ← phc_hw_adj_ns_incr_frac`.
     - `tidelink_0/phc_nanoseconds ← phc/nanoseconds_o`; `tidelink_0/phc_seconds ← phc/seconds_o`; `tidelink_0/phc_pps ← phc/pps_out`.
     - PHC source-1 inputs tied off (HA1588 not built).
     - `eth_rx_capture` / `eth_tx_capture` tied 0.
     - `phc_locked_i` on tidelink can stay 1'b0 (default in pair wrapper) — `PHC_LOCK_GATE_EN` param is 0 so this signal is don't-care unless `HW_SYNC_CTRL[2]` is needed (and force_en=1 bypasses regardless).
   - **Address-space:** allocate e.g. 4 KB @ `0x4405_0000` for `phc.apb` on the PS7 M_AXI_GP0 map; route a new SmartConnect master → axi-to-apb bridge.
2. **No host-side PTP scripts.** No `bringup_ptp_*.sh` exists in `pynq_host/scripts/`. `bare_overlay.py` lacks `PHC_BASE`. The four scripts proposed in §5 are NEW.
3. **No two-board synchronous capture mechanism on `main`.** `tidelink_design.tcl` lists no GPIO output usable as a "simultaneous PPS / trigger" port between the two boards. Some PMOD pins on the PYNQ-Z2 are free (Pmod B + four LEDs in use; Pmod A is on shared balls W18..U19, NOT usable per the XDC comment lines 78–93). **Pmod B (J5)** is unused and provides a clean LVCMOS33 path. The plan therefore reserves two Pmod-B pins per board for a shared trigger wire (see §3).
4. **No verified mapping of which board has `pps_out` driven externally.** Without a PHC instance there is currently no `pps_out` signal at the top level. After PHC integration, route PHC `pps_out` to an LED (already-free LED2/LED3 reuse), and additionally to a PMOD pin so the peer board can latch it (option B in §3).
5. **`NS_INCR` startup value for 50 MHz** — driver MUST write `NS_INCR = 20` before enabling, otherwise the clock counts in (default 4 ns × 50 MHz × 1 s) = 200 ms per real-time second. No existing software does this on `main`.
6. **(Minor)** `cocotb/tidelink_ptp/test_tidelink_ptp.py` uses internal register addressing (`REG_HW_SYNC_INTERVAL = 0x1` etc.) — these are servo_reg_addr not APB offsets. The absolute APB offsets are computed via region+slot in `tidelink_apb_regs.sv`. The bring-up scripts must use APB-absolute (Table §1.4).

### 2.3 Branches / commits believed to hold PTP-relevant fixes

A scan of `git log --all --oneline` would be needed to pin specifics; the items below are inferred from the on-`main` documentation:

- `IMPLEMENTATION_STATUS.md` notes `tidelink_ptp*` lint-clean and verified. The PHC IP is in a peer repo at HEAD, not folded into the FPGA flow.
- I2C-autonomy branches (`feat/i2c-autonomous-lock-integ`) do NOT touch PTP — they are link-layer (autoneg) fixes only.
- `feat/td-combined` per the memory references is the consolidated lane-lock branch — PTP-orthogonal.
- No "feat/ptp-fpga-integ" exists at the time of writing. The PHC-in-BD integration is the missing piece.

---

## 3. Capture / measurement mechanism (cross-board offset readout)

To **measure** synchronisation we need the host to read both PHC counters at a known "same instant". Three options were considered:

### 3.1 Option A — shared external trigger via PMOD-B (recommended)

- One free PMOD-B pin per board is wired board-to-board with a short jumper wire (e.g. PMOD-B pin 1 on each board joined directly).
- One side drives the trigger (its FPGA pin set as output via an AXI GPIO already in the BD pattern, or by wiring to an unused tidelink_top signal); the other receives.
- Both boards' RTL is augmented so that the trigger edge issues a **software CAPTURE pulse** on the PHC — i.e., the trigger pin OR'd into a one-shot generator that writes 1 to `phc.CTRL.CAPTURE` (or, simpler, route the trigger into PHC's `hw_capture_0_i` alongside the existing `tidelink_0/phc_hw_capture`). On a real edge both PHCs latch their current time into HW_CAP_*.
- Host then reads both boards' `HW_CAP_SECONDS_LO/HI`, `HW_CAP_NANOSECONDS`, `HW_CAP_NS_FRAC` over SSH and computes `delta = T_slave − T_master`.
- Skew bound: the trigger wire is ~few cm, propagation < 1 ns. Synchroniser stages on each side add 2 cycles (40 ns at 50 MHz) — symmetric on both boards, cancels except for relative metastability resolution differences (sub-ns).
- **Net measurement floor: ~5–10 ns** dominated by `phc_clk` quantisation (one ns_incr step = 20 ns at 50 MHz), softened by the 32-b sub-ns fractional. This is well below the expected residual jitter (see §6) so adequate.

**Cost:** BD addition of one xlconcat or direct port; one new top-level input to `tidelink_top` OR a parallel one-shot pulse into the PHC `hw_capture` mux; one PMOD pin assigned in `pynq_z2_tidelink.xdc`; physical jumper wire.

### 3.2 Option B — PPS hop

- After PHC integration, route PHC `pps_out` to a PMOD pin on **one** board (the master), and route the other board's same-numbered PMOD pin as an **input** that drives its PHC `hw_capture_1_i` (servo source 1 is unused so we can repurpose it as the cross-board capture port).
- The slave's PHC then captures the master's seconds-rollover instant. Host reads master's PHC time and slave's HW_CAP_1_* and computes the offset.
- **Asymmetric** — only the slave side has a synchronous-to-master snapshot. To measure the master-side bias of the slave you'd need a 2nd reverse PPS link or fall back to Option A.
- More accurate than A by ~one clock cycle (no host roundtrip to read master) but more BD intrusion.

### 3.3 Option C — Host-side AHB read time-correction

- No HW changes. Host reads PHC.CAP regs from each board via SSH back-to-back, then subtracts a calibrated "host round-trip" delay.
- Calibrated by reading the same board twice and observing the wall-clock delta of the two `CAP_NANOSECONDS` values.
- **Useless for sub-ms accuracy** — SSH RTT through mapstone-dev is ~ms, jitter ~hundreds of µs. Will only show that the boards are within ~1 ms of each other.

### 3.4 Recommendation

**Use Option A.** It is the only one that yields sub-µs measurement on the existing platform. It requires modest BD work (one pin + a 2-input OR on the PHC hw_capture port) and one physical wire. The BD work is naturally bundled with the PHC IP integration (§2.2 gate #1), so the marginal cost is small.

If the test campaign is purely a "boards are within ms of each other" go/no-go, Option C is acceptable for Phase 1 only.

---

## 4. Injection mechanism

### 4.1 Offset step (write the time register directly)

Source-of-truth: `phc_apb_regs.rdl` lines 35–43 (CTRL.SET_TIME field).

Sequence on **slave** (the board whose clock we perturb):

1. Compute target time: `T_now + ΔT` (or replace with arbitrary). Software reads current PHC time via a CAPTURE pulse (CTRL[2]=1 → read CAP_*) to know `T_now`.
2. Write `SET_SECONDS_LO`, `SET_SECONDS_HI`, `SET_NANOSECONDS` (atomic triple).
3. Write `CTRL.SET_TIME = 1` — self-clearing, atomic load.

**FSM / safety considerations** (from `phc_clock_core.sv` / `phc_apb_regs.sv` — read those for line-level cite if needed; phc.sv:21 confirms the singlepulse/swmod attributes):

- `SET_TIME` is `singlepulse + swmod` — one cycle pulse from the APB write. No stalling.
- Race with servo: if the autonomous servo is enabled and a HW `hw_set_time_0_i` pulse arrives the same cycle as the APB `set_time`, the PHC clock-core typically OR-merges (or muxes via SERVO_CTRL.SRC_SEL). **Disable the servo (clear `0x204C` bit[0] on this board) before injecting an offset** to avoid contention, then re-enable after the test confirms re-convergence.
- Sub-ns fractional accumulator clears to zero on SET_TIME (RDL line 50: "Sub-nanosecond accumulator is cleared to zero"). This introduces a ~1 LSB Q0.32 transient — negligible at ns level.
- For a clean step of magnitude `Δ`, ensure `Δ < 999_999_999` ns or programme the seconds field too.

### 4.2 Frequency drift (write NS_INCR_FRAC)

Source-of-truth: `phc_apb_regs.rdl` lines 75–80 + `tidelink_ptp_servo.sv` description.

- `NS_INCR_FRAC` (0x00C) is Q0.32 — fractional ns added per clock cycle.
- **ppm → LSB conversion:** target frac increment per cycle (in ns) = nominal_cycle_ns × (ppm × 1e-6). LSB = 2^-32 ns. So `LSBs_per_ppm = nominal_cycle_ns × 1e-6 × 2^32 / 1 = cycle_ns × 4294.97`.
   - 50 MHz (20 ns cycle): **1 ppm ≈ 85_900 LSBs** (was understated in §1.2 — see correction note: 1 ppm of 20 ns × 50e6 cycle/s = 20 ns/s drift; over one second that's 20 ns/s = 20 ppb-of-time per ppm-cycle. The Q0.32 nanosecond fractional gives 1 LSB ≈ 2.33e-10 ns/cycle, and over 50e6 cycles/s = 1.16e-2 ns/s ≈ 11.6 ps/s. So 1 ppm of clock period ≈ (20 ns × 1e-6) / 2^-32 = 20e-15 × 2^32 = 85_900 LSBs **PER CYCLE drift** which produces 20 ns/s of accumulated drift).
   - The mathematically careful expression: `LSBs_per_ppm = (cycle_ns × ppm × 1e-6) × 2^32 / 1` = cycle_ns × 4_295. For 50 MHz, that is 20 × 4_295 ≈ **85_900 LSBs / ppm of clock-period error**. Confirm empirically — the test scripts log it.
- **Range / safety:** `NS_INCR_FRAC` is 32 bits unsigned. The natural operating range is small perturbations around the "ideal" 0. Wrap-around is fine because the integer NS_INCR catches the overflow. Practical limit: stay within ~ +/- 100 ppm to keep the counter monotonic and the servo loop in linear regime.
- **Lock-loop response time:** governed by KP/KI gains and SYNC interval. UVM chain test uses KP=0.03125, KI≈0.002, sync interval=100 µs → settles in tens of samples = tens of ms. At 1 Hz sync (default) it would be tens of seconds.

### 4.3 Combined servo enable / disable

To inject perturbations the **autonomous servo on the slave must be temporarily disabled** so it doesn't fight the injection. Sequence:

1. `apb_w 0x204C 0x0` (servo disable, mode=GM=0).
2. Inject perturbation (offset or NS_INCR_FRAC write).
3. Sample slave PHC for a baseline duration (e.g., 1 s) to confirm the perturbation took effect with no closed-loop correction.
4. `apb_w 0x204C 0x3` (servo enable + Sub mode) to re-engage the loop.
5. Sample convergence trajectory.

---

## 5. Test procedures — bring-up scripts

Each script runs on a host with mapstone-dev SSH access, lease acquired (`fpgahub pair lease acquire bridge1 ...` — verify `granted`, not `queued`, per memory note). All assume bitstream with PHC IP integrated has already been deployed by `pynq_host/scripts/deploy_pair.sh` and `bringup_pair_converge.sh` has confirmed `lane_locked=0xFF` on both sides. **All scripts MUST NOT write to AHB_TX (0x4400_0000) before lane lock is confirmed — that is the deploy_pair.sh wedge hazard.** PTP TX through `ahb_ptp_*` (0x4402_0000) is the *separate* short-packet TX port — it shares the wedge risk only if the link is down (because then `tx_router_idle` never asserts and the AHB bridge stalls), so each script must verify link health first.

### 5.1 `bringup_ptp_sync.sh` — initial-sync + convergence measurement

**Purpose:** Demonstrate two-board PHCs starting asynchronous, then converging via autonomous PTP exchange.

**Prerequisites:**

- Lease: `bridge1` granted.
- Bitstream: `tidelink-with-phc.bin` already deployed on both boards (PHC IP folded in).
- Link health: `wlink_probe.sh` shows `lane_locked == 0xFF` and `calibration_done == 1` on both boards. CREDIT_PATH_STATUS shows `cr_pkt_seen_rx=1` both directions.
- Trigger jumper installed (Pmod B pin between master and slave) if Option A capture is used.

**Sequence (pseudocode):**

```
PHC_BASE=0x44050000          # tentative — pinned at BD integration time
APB_BASE=0x44030000
NS_INCR=20                   # 20 ns / cycle = 50 MHz phc_clk

for board in master slave:
    # 1. Disable servo on both sides (clean slate)
    apb_w $APB_BASE 0x204C 0x0
    apb_w $APB_BASE 0x2040 0x0          # hw_sync_en = 0

    # 2. Programme PHC for 50 MHz, set distinct initial time, enable counter
    phc_w $PHC_BASE 0x008 $NS_INCR      # NS_INCR
    phc_w $PHC_BASE 0x00C 0             # NS_INCR_FRAC = 0 (nominal)
    if board == master:
        phc_w $PHC_BASE 0x010 100       # SET_SECONDS_LO = 100
    else:
        phc_w $PHC_BASE 0x010 200       # SET_SECONDS_LO = 200 (intentional 100 s skew)
    phc_w $PHC_BASE 0x014 0
    phc_w $PHC_BASE 0x018 0             # SET_NS = 0
    phc_w $PHC_BASE 0x000 0x2           # CTRL.SET_TIME (self-clear)
    phc_w $PHC_BASE 0x000 0x1           # CTRL.EN

# 3. Baseline measurement: capture both boards via the shared trigger,
#    read HW_CAP_*. Verify the 100 s gap is present.
trigger_pulse                            # falling edge on the shared Pmod
read_phc_hw_cap master; read_phc_hw_cap slave
log "T0 offset = $((slave_t - master_t))"

# 4. Configure PTP + servo
for board in master slave:
    apb_w $APB_BASE 0x2034 0x1           # PTP_CTRL.enable = 1
    apb_w $APB_BASE 0x2044 7_812_500     # HW_SYNC_INTERVAL = 128 Hz (fast convergence)

# Master = GM (servo mode 0); slave = Sub (mode 1)
apb_w_master $APB_BASE 0x204C 0x1        # SERVO_CTRL: enable, mode=GM
apb_w_slave  $APB_BASE 0x204C 0x3        # SERVO_CTRL: enable, mode=Sub
apb_w_slave  $APB_BASE 0x2050 0x08000000 # KP
apb_w_slave  $APB_BASE 0x2054 0x00800000 # KI
apb_w_slave  $APB_BASE 0x2058 1_000_000  # STEP_THRESH = 1 ms

# 5. Start the autonomous sync initiator on the master
apb_w_master $APB_BASE 0x2040 0x1        # HW_SYNC_CTRL.enable

# 6. Convergence loop — sample every 250 ms for up to 60 s
for t in 0..60 step 0.25:
    trigger_pulse
    read both PHC HW_CAPs
    offset = slave - master
    locked = apb_r_slave $APB_BASE 0x205C & 0x1
    log "t=$t offset=$offset locked=$locked"
    if locked == 1 and abs(offset) < 100 ns for last 10 samples:
        PASS; break

# 7. Report convergence time, final offset, residual jitter
```

**Pass criteria:**

- Initial offset visible at ~100 s.
- `SERVO_STATUS.locked` asserts within **5 s** of enabling.
- After lock, |offset| < **500 ns** sustained (worst-case bound given RX-side jitter, §1.2 SHORTCOMINGS #17).
- Steady-state residual jitter (1-σ over 100 consecutive samples) < **200 ns**.
- No `SERVO_STATUS.active` bit stuck high (mid-correction never completes).

**Runtime:** ~2 minutes.

**Safety constraints:**

- Do NOT touch AHB_TX (0x4400_0000) at any point.
- PTP TX (0x4402_0000) is safe because `tx_router_idle` asserts as soon as link is up.

### 5.2 `bringup_ptp_track_freq.sh` — frequency-drift tracking

**Purpose:** Demonstrate the servo tracks an injected clock-period error.

**Prerequisites:** Sync test (5.1) passed within last hour, both PHCs converged.

**Sequence:**

```
# Servo running, locked. Slave is being disciplined by master.
# We will inject a frequency error on the MASTER (so the slave has to track up/down).

LSB_PER_PPM=85_900    # 50 MHz cycle, see §4.2

for ppm_step in [+1, +10, +50, -50, -10, -1]:
    delta = ppm_step * LSB_PER_PPM
    # Programme master NS_INCR_FRAC to delta (signed-wrapped Q0.32 around 0)
    current = phc_r_master $PHC_BASE 0x00C
    phc_w_master $PHC_BASE 0x00C $((current + delta))

    # Sample slave's tracking response
    for t in 0..30 step 0.5:
        trigger_pulse; read both PHC HW_CAPs
        offset = slave - master
        ns_frac_slave = apb_r_slave $APB_BASE 0x2064  # SERVO_NS_FRAC
        log "step=${ppm_step}ppm t=$t offset=$offset slave_frac=$ns_frac_slave"
    # Verify slave's SERVO_NS_FRAC trends toward the matching delta
    assert abs(ns_frac_slave - target_frac) within tolerance
```

**Pass criteria:**

- For each step magnitude `m` (in ppm), the tracking error |slave-master| settles to **< max(500 ns, m × 100 ns/ppm)** within `min(30 s, 100 × SYNC_INTERVAL)`.
- `SERVO_NS_FRAC` on the slave moves in the direction predicted by §4.2 (sign agreement).
- Servo stays `locked` throughout — no lock-loss event.

**Runtime:** ~3.5 minutes (6 steps × 30 s + setup).

**Safety:** As §5.1. Bound `ppm_step` to ≤ 100 ppm to keep the loop in linear regime.

### 5.3 `bringup_ptp_track_offset.sh` — offset-step response

**Purpose:** Demonstrate phase-step recovery after an injected offset.

**Sequence:**

```
# Pair is converged.
for offset_step_ns in [+1_000, +1_000_000, -1_000_000, +500_000_000]:
    # Inject on slave
    apb_w_slave $APB_BASE 0x204C 0x0        # disable servo briefly
    # Read current PHC time
    phc_w_slave $PHC_BASE 0x000 0x4         # CTRL.CAPTURE
    cur_sec_lo = phc_r_slave $PHC_BASE 0x020
    cur_ns    = phc_r_slave $PHC_BASE 0x028
    target_ns = (cur_ns + offset_step_ns) mod 1_000_000_000
    target_sec = cur_sec_lo + ((cur_ns + offset_step_ns) / 1_000_000_000)
    phc_w_slave $PHC_BASE 0x010 $target_sec
    phc_w_slave $PHC_BASE 0x018 $target_ns
    phc_w_slave $PHC_BASE 0x000 0x2         # CTRL.SET_TIME
    apb_w_slave $APB_BASE 0x204C 0x3        # re-enable servo (Sub)

    # Sample recovery
    sample_loop until offset < 200 ns or t > 10 s
    record settling time per step
```

**Pass criteria:**

- For `|step| > STEP_THRESH = 1 ms`: servo issues SET_TIME phase step → re-convergence in **< 1 sync interval (~1 s)**.
- For `|step| < STEP_THRESH`: servo handles via frequency-steer → re-convergence in **< 10 s**.
- `SERVO_STATUS.PHASE_STEP_ACTIVE` (PHC reg 0x0A8, bit[1]) asserts during the large-step case.
- No `SERVO_STATUS.locked = 0` for more than 2 sync intervals post-injection.

**Runtime:** ~5 minutes.

### 5.4 `bringup_ptp_soak.sh` — long-soak + recovery

**Purpose:** Multi-hour stability, link-drop recovery, random perturbations.

**Sequence:**

```
# Pair converged.
SOAK_HOURS=4
INJECT_PROB=0.05       # 5% chance per minute of a random perturbation

start_logger writing offset/locked/cr_pkt/lane_status every 5 s to a CSV
for minute in 0..240:
    sleep 60
    if rand < INJECT_PROB:
        choice from {offset_step (50us..50ms), freq_drift (1..20 ppm), link_drop}
        if link_drop:
            apb_w $APB_BASE 0x2080 0x0     # clear role_lock (POR-only — would need pwr-cycle equiv)
            # On bridge1 we can't do a real link drop without a redeploy; use
            # alternative: write Wlink SW_RESET (0x0208 bit[3]) to bounce link.
            apb_w $APB_BASE 0x0208 0x8
            sleep 5
            apb_w $APB_BASE 0x0208 0x0
        else:
            inject the perturbation; log injection event
    monitor: log row
end
analyse CSV: max offset, mean offset, lock count, lock duration histogram
```

**Pass criteria:**

- Mean |offset| over 4 hours < **300 ns**.
- 99th-percentile |offset| < **2 µs**.
- After every link-drop event, servo re-locks within **30 s** of link return.
- No `lane_locked` change during the run (link stays up unless we drop it).
- No silent `SERVO_STATUS.active=1` stuck-busy for > 2 s.
- ECC counters (`SWI_LANE_STATUS` ECC_COUNTERS at 0x2114) do not exceed nominal baseline by > 10×.

**Runtime:** 4 hours (configurable via `SOAK_HOURS`).

**Safety:** Long-running — script must check `SSH OK` after every interval and abort gracefully on failure. Lease may auto-expire mid-soak; lease TTL must be ≥ soak time + 30 min.

---

## 6. Pass criteria (quantitative summary)

| Phase | Metric | Threshold | Rationale |
|---|---|---|---|
| All | Convergence time (initial lock) | ≤ 5 s @ 128 Hz sync | UVM chain test settles within 50k cycles @ 100 µs sync = ~5 s; HW will be slower due to RX-jitter but bounded. |
| All | Steady-state |offset| | ≤ 500 ns | RX-pipeline jitter (SHORTCOMINGS #17) sets the floor. ≈ 5–10 cycles of `phc_clk` (200 ns at 50 MHz). |
| All | Residual 1-σ jitter (100 samples) | ≤ 200 ns | Roughly 1× cycle period. |
| Freq tracking | Tracking error per 1 ppm step | ≤ 100 ns settling | Linear regime of PI loop. |
| Freq tracking | Tracking error per 50 ppm step | ≤ 5 µs settling | Out-of-band; will still re-lock. |
| Offset step | Phase-step recovery (|step| > 1 ms) | ≤ 1 s | Single SET_TIME does it. |
| Offset step | Freq-steer recovery (|step| < 1 ms) | ≤ 10 s | PI integral catches up. |
| Soak | Mean offset (4 h) | ≤ 300 ns | Slightly tighter than steady-state limit because heavy-tail events average out. |
| Soak | 99th %ile offset | ≤ 2 µs | Accommodates 1–2 ECC retries / second. |
| Link recovery | Re-lock after SW_RESET bounce | ≤ 30 s | Link train + 16 servo samples @ 128 Hz. |

**Clock-frequency assumption:** `hclk = phc_clk = 50 MHz` on the bridge1 FPGA rig (clk_wiz output `clk_out1 = clk_out2`). The ASIC target is 100 MHz (per memory `v1 ASIC target`). All ns numbers above scale by 2 for ASIC silicon.

---

## 7. Risks and open design questions

| # | Risk / question | Severity | Mitigation / decision needed |
|---|---|---|---|
| R1 | **PHC IP not in BD on `main`.** All four scripts above are useless without it. | **Blocking** | Decide: (a) integrate `phc` IP into `fpga/targets/pynq-z2-pair/tidelink_design.tcl` (estimated effort ~1 day Vivado work + 2 days rebuild + lock-test); (b) defer PTP HW until v1.1. Recommendation: (a) and gate the campaign on it. |
| R2 | `NS_INCR` default is 4 (250 MHz). At 50 MHz the counter will run at 4× too slow if not reprogrammed. | High | Bring-up scripts MUST `phc_w 0x008 20` before `CTRL.EN`. Also: add `DEFAULT_NS_INCR=20` parameter to the PHC IP when packaging for FPGA wrapper. |
| R3 | `ppm → LSB` conversion calibration (§4.2) hand-computed. | Med | First test (`bringup_ptp_track_freq.sh`) must include a calibration step that measures actual drift vs. injected LSBs and prints the empirical `LSB_PER_PPM` for record. |
| R4 | RX-side timestamp jitter (SHORTCOMINGS #17) limits floor. | Med | Documented in §6 — pass thresholds chosen to be ≥ this floor. UVM `tidelink_ptp_stress` should characterise the distribution to set tighter bounds in v1.1. |
| R5 | Cross-board trigger (Option A) requires another pin + BD signal. | Low | Bundle with R1 integration work. If not possible, fall back to Option C with ~1 ms measurement floor. |
| R6 | `phc_locked_i` semantics. | Low | `PHC_LOCK_GATE_EN=0` (default) → `phc_locked_i` is a don't-care. For the bridge1 two-board case keep `PHC_LOCK_GATE_EN=0`. The 3-chiplet chain plumbing is sim-only for now. |
| R7 | Servo SET_TIME race with APB SET_TIME. | Low | Disable servo before injection (§4.3). |
| R8 | Lease may expire mid-soak. | Low | TTL ≥ soak + 30 min. Check `granted` (not `queued`) before start. |
| R9 | AHB_TX wedge hazard (`docs/wlink_probe.sh` header). | Med | All scripts avoid 0x4400_0000. PTP_TX at 0x4402_0000 is a separate AHB slave — verified safe once link is up. |
| R10 | RTL `unique case` synth-prune risk in calibrator (IMPLEMENTATION_STATUS §1.2) is unrelated to PTP but could destabilise the underlying link during PTP campaign. | Low (orthogonal) | Run `bringup_pair_converge.sh` before each PTP test to confirm 16/16 lane lock baseline. |
| R11 | Two-board NS_INCR_FRAC sign convention may differ from the PI-loop's sign assumption (slave-ahead vs slave-behind). | Med | First test reports both signs; verify §1.2 polarity assertion. |
| R12 | `bringup_ptp_soak.sh` `link_drop` via Wlink SW_RESET (0x0208[3]) — never validated. | Med | First soak run only — verify SW_RESET cleanly drops + recovers the link without wedging credits. If not, fall back to `apb_w 0x201C 0x2` (CTRL.FLUSH on TideLink). |

### Open design questions

- **PHC IP packaging:** Is the PHC IP packaged as a Vivado IP (component.xml) in `~/SoCLabs/ptp-hardware-clock-ahb/`? If not, that is part of R1. Need an AHB-to-APB bridge in the BD (the IP exposes APB only, not AXI-Lite — confirm in `phc.sv:34–43`).
- **PMOD-B pin choice:** Pmod-B header is unused on `pynq-z2-pair*.xdc` — pick e.g. PMOD-B pin 1 (FPGA ball `Y16` per the PYNQ-Z2 v1.0 schematic, board file `raspberry_pi_tri_i_*` does not include it). Cross-check against `/apps/Xilinx/Vivado/2024.1/data/boards/pynq-z2/A.0/part0_pins.xml`. **Uncertain** — confirm in BD integration step.
- **Whether `tidelink-flip` BD needs the same modifications:** Yes — `pynq-z2-pair-flip/tidelink_design.tcl` is structurally identical so the same PHC instantiation patch applies symmetrically.
- **Should the autonomous servo lock-detect threshold be configurable from APB?** The PI loop's `locked` bit is derived inside `tidelink_ptp_servo.sv` — not currently APB-settable. Acceptable for v1.0 HW test campaign.
- **PPS hop (Option B) vs Option A:** decided in favour of Option A. Could revisit if measurement floor of Option A turns out to be insufficient.

---

## 8. Phased rollout

| Phase | Scope | Gated on | Status |
|---|---|---|---|
| **Phase 0** | Plan ratification + PHC IP packaging | Project decision | **Doc complete (this file).** Awaits PHC IP packaging + BD integration. |
| **Phase 1** | Single-PHC sanity on each FPGA: PHC counts up; `CTRL.CAPTURE` returns plausible time; PPS LED blinks at 1 Hz. | PHC IP integrated in pair BD (R1). | NOT STARTED. Already covered by cocotb `phc_*` at module level — this phase is SoC bring-up only. |
| **Phase 2** | Dual-PHC sync (script §5.1). | Phase 1 PASS on both boards + Pmod trigger wired + link 16/16. | NOT STARTED. |
| **Phase 3** | Tracking under perturbation (scripts §5.2 + §5.3). | Phase 2 PASS, KP/KI tuned (initial values from UVM chain test). | NOT STARTED. |
| **Phase 4** | Stress / soak (script §5.4). | Phase 3 PASS, soak duration approved (4 h baseline). | NOT STARTED. |

### Gating summary

- **Phase 1 ↔ Phase 2:** must complete Phase 1 on BOTH boards before starting Phase 2 (so we know which board's PHC, if any, is faulty before debugging "two boards don't sync").
- **Phase 2 ↔ Phase 3:** Phase 2 must demonstrate steady-state lock; otherwise perturbation tests are meaningless.
- **Phase 4 ↔ Phase 3:** soak presumes the tracking & step responses are bounded.

### Estimated effort (rough, for downstream planning)

| Item | Days |
|---|---|
| Package PHC IP for Vivado | 0.5 |
| BD integration on pair (+ flip) | 1.0 |
| Re-run farm builds (both targets) + redeploy | 0.5–1 |
| Pmod trigger wire-in + RTL one-shot for CAPTURE OR | 0.5 |
| Script implementation (`bringup_ptp_sync.sh`) | 0.5 |
| Phase 1 + Phase 2 bring-up | 1.0 (likely iteration on KP/KI) |
| Phase 3 perturbation scripts + characterisation | 1.0 |
| Phase 4 soak (machine time) | 0.5 (script) + 0.5 day/4 h soak |
| **Total (incl. iteration)** | **~6 working days** |

---

## Appendix A — Authoritative file/line references used in this plan

- `src/rtl/tidelink_top.sv:82–83, 198–207, 212, 217–219, 224–226, 231–235, 242, 255, 931–1102` — PTP/PHC top-level wiring.
- `src/rtl/tidelink_ptp.sv:32–80` — PTP module ports.
- `src/rtl/tidelink_ptp_servo.sv:110–180` — servo register addressing, KP/KI/step_thresh.
- `src/rtl/fifo/tidelink_apb_regs.sv:410–426` — APB decode for PTP/HW_SYNC/servo/mbox.
- `src/rdl/tidelink_ptp_regs.rdl` (entire) — PTP_CTRL / PTP_RX_PAYLOAD / PTP_STATUS.
- `src/rdl/phc_regs.rdl:33–90` — PHC CTRL/STATUS/NS_INCR/NS_INCR_FRAC fields.
- `~/SoCLabs/ptp-hardware-clock-ahb/src/rdl/phc_apb_regs.rdl:16–390` — full PHC register definitions (authoritative IP).
- `~/SoCLabs/ptp-hardware-clock-ahb/src/rtl/phc.sv:21–94` — top-level ports of the PHC IP, including servo source-0 / source-1 interfaces.
- `fpga/targets/pynq-z2-pair/tidelink_design.tcl:39–49` (PHC tie-off rationale), `262–308` (xlconstant cells), `441–442` (ptp_irq routing), `489` (ahb_ptp address).
- `fpga/targets/pynq-z2-pair/tidelink_design_wrapper.v:17–18, 122` (PHC tie-off in wrapper).
- `fpga/targets/pynq-z2-pair/pynq_z2_tidelink.xdc:75–117` — pin map; PMOD-A is off-limits, PMOD-B is unused.
- `docs/PTP_PROTOCOL.md` (entire) — protocol-level spec authority.
- `docs/REGISTER_MAP.md:1–460` — register map authority for both TideLink and PHC.
- `docs/IMPLEMENTATION_STATUS.md:1.1` table — RTL maturity.
- `docs/SHORTCOMINGS.md:189–219` — PTP-specific limitations (RX jitter, idle-gating, software-servo bandwidth).
- `pynq_host/bare_overlay.py:24–47` — BD-aware MMIO map (need to add `PHC_BASE` once integrated).
- `pynq_host/scripts/wlink_probe.sh:36–55` — AHB_TX wedge hazard notice.
- `pynq_host/scripts/bringup_pair_converge.sh:1–80` — link-lock baseline script (PTP tests gate on its success).
- `uvm/tidelink_ptp_chain/tests/test_chain_convergence.sv` — KP/KI/step_thresh reference values used in §5.1.
