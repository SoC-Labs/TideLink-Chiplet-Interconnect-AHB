# TideLink build #3 — handoff report

**Author session:** 2026-05-29 (Claude Code session, mapstone-dev)
**Build:** #3 (commit `dda0a0e88bfb`, calibrator Fix A2+B + AUTOCAL_ENABLE=1)
**Branch:** `feat/td-gpio-phy-integration`
**Lease state at writing:** bridge1 held by mapstone-dev until 16:09 BST 2026-05-29
**This report's purpose:** complete enough that the next engineer (or future-me) can pick up without re-deriving today's findings.

## 1. Where build #3 landed (the headline)

| Capability | Status | Where verified |
|---|---|---|
| FPGA bitstream builds | ✅ build_pair_farmed completes in ~55 min | `imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit` |
| Provenance-checked deploy | ✅ sha256 manifest enforced | `deploy_pair.sh --manifest` |
| AUTOCAL fires from pure deploy | ✅ `cal_done=1` both sides immediately | Empirical (this session, no bringup script) |
| Link converges 16/16 | ✅ Iter 1 of `bringup_pair_converge.sh` | [BUILD3_HW_VALIDATION_2026_05_29.md](BUILD3_HW_VALIDATION_2026_05_29.md) |
| Doorbells bidirectional | ✅ M→S and S→M both bump resp_acc | Sandwich loop iter 1-6 |
| AHB N=1 TX no wedge | ✅ HREADY returns 0.17 ms | Sandwich loop |
| AHB packet RX at slave | ❌ slave FIFO empty | **Bug A** |
| PTP HW_SYNC at slave | ❌ slave HW_SYNC_STATUS=0 | **Bug B** |

**Net:** Fix A2+B silicon-validated the calibrator (the headline goal). The link is physically up. Two separate bugs remain at the FC-application layer.

## 2. Current bugs (the handover)

### Bug A — AHB packet M→S delivery fails

- **Symptom**: master writes packet to AHB_TX (0x4400_0000, words = N + N data words), local HREADY returns ~0.17 ms with `returner_busy` clearing. Slave reads `REG_PKT_LEN` (0x44032008) = 0 and AHB_FIFO (0x44010000) empty.
- **Evidence link is up**: slave's `REG_DOORBELL_RESP_ACC` (0x44032024) bumps by ~20480 (=0x5000) each master AHB write. Something crosses the wire, but it doesn't land in AHB_FIFO.
- **Not the wedge primitive**: build #3 returns HREADY cleanly — the wedge that killed z2_02 in earlier builds is gone.
- **Earlier hypothesis (now ruled out)**: `PAIR_CREDIT_COUNTER=0` is not the cause — that register is purely SW-managed observability (see §6).

### Bug B — PTP HW_SYNC M→S delivery fails

- **Symptom**: master `HW_SYNC_CTRL=0x05` (force_en | enable), master `HW_SYNC_STATUS` becomes non-zero (0x1e0d under full bringup; 0x01 after a single write). Slave `HW_SYNC_STATUS` (0x44032048) stays at 0.
- **Tested today**: writing slave `PTP_CTRL=0x01` (ptp_enable_r=1, opens `ptp_sp_rx_accept` gate at [tidelink_ptp.sv:288](src/rtl/tidelink_ptp.sv#L288)) — slave HW_SYNC_STATUS still 0. So `ptp_enable_r` isn't the gate.
- **Architectural note**: PTP short packets use a **dedicated port** on the chiplet controller ([tidelink_top.sv:1955-1956](src/rtl/tidelink_top.sv#L1955-L1956)) wired through [ShortPacketToWlink.v](deps/axi-chiplet-controller/logical/wlink/ShortPacketToWlink.v), which has NO credit logic. Just tx_fifo + rx_fifo + valid/ready handshakes. So Bug B is NOT a credit issue.
- **Likely family**: PHC Phase-1 (memory entry `project_phc_phase1_hw_diagnosis_2026_05_24.md`). Active on this branch already.

### Bugs A and B might be independent

- Bug A is on the TideLink FC node (50-bit packed bus, AHB packets).
- Bug B is on the PTP short-packet port (separate 26-bit packed bus, no credit gating).
- Doorbell works (sideband — proves PHY layer fine).
- See §10 for diagnostic agent output (when available).

## 3. Autocal-from-deploy finding (most useful operational change today)

**Build #3 doesn't need `bringup_pair_converge.sh` anymore.** A pure `deploy_pair.sh` produces `cal_done=1` on both sides immediately. To bring lane_locked to 0xFF, one APB write per side is sufficient:

```
APB write 0x44032100 := 0x01   # SWI_TRAINING_MODE on each board
# wait ~2 seconds
APB read  0x44032108 → bits[7:0] = 0xff (lock), bit 16 = 1 (cal_done)
```

`td_set_train.py` on mapstone-dev does this in one step per board. The historic iterative re-deploy loop (`bringup_pair_converge.sh`) was needed for prior builds with the sticky-low calibrator bug — Fix A2+B made it obsolete.

**Implication for ASIC**: this is the first concrete proof-point that ASIC autonomous bringup is viable on this RTL. See [I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md](I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md) for the gap analysis.

## 4. Simulation validation procedure

### 4.1 What's covered today

Per the explorer agent's audit (full table in [DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md §3](DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md)):

| Env | Tests | Covers |
|---|---|---|
| `tidelink_top_pair` | `test_tidelink_pair_doorbell.py` (6 tests) | Link bringup + doorbell signaling — explicitly NOT AHB packets |
| `tidelink_fc_adapter` | 35+ tests | FC TX/RX demux + returner (single-side only) |
| `tidelink_ahb` | 14 tests | AHB wrapper + bridge (single-side) |
| `tidelink` | 30+ tests | FIFO + returner + regs (single-side) |
| `phc_pair` | `test_phc_hw_sync_pair.py` (1 test) | M→S sync packet RX FIFO check (does NOT assert slave APB HW_SYNC_STATUS) |

### 4.2 Gaps the next engineer must close

Three new paired-die tests are required (skeletons in [DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md §5](DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md)):

1. `test_paircredit_nonzero_after_bringup` — regression gate for the credit deadlock
2. `test_ahb_packet_master_to_slave` — Bug A reproducer in sim
3. `test_ptp_hw_sync_slave_status` — Bug B reproducer in sim

**Agent (running at handoff time):** dispatched to implement and run these. Output will land at `docs/SIM_REPRO_RESULTS_2026_05_29.md`. Next engineer should check that path first — if FAIL in sim matching HW, root-cause is in design RTL. If PASS in sim while HW FAILs, there's a sim-vs-RTL gap (likely SIM-only `ifdef` shortcuts or clock-phase initialization) — much harder problem.

### 4.3 How to run the existing paired-die sim

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/verif/cocotb/tidelink_top_pair
make                              # runs default test
make TEST=test_tidelink_pair_doorbell.test_05_credit_accept  # one test
# Wave dump on by default; check sim_build/dump.fst
```

(Paths in the agent output will confirm; this is the cocotb convention.)

## 5. Hardware validation procedure (this session's recipe)

### 5.1 Build

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ
make -C fpga build_pair_farmed FARM_HOST=srv04936
# Master local + slave farmed concurrently, ~55 min wall
# Outputs: imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit
```

### 5.2 Convert + stage

```bash
python3 fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-all/tidelink.bit imp/fpga/output/pynq-z2-pair-all/tidelink.bin
python3 fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin

# Manifests need sha256 (deploy_pair.sh refuses unverified deploys)
# Use the format in /tmp/tidelink_deploy/tidelink.bin.manifest.json.b22-bak as the template.

# Stage via cat-pipe (rsync hits ssh-agent banner protocol mismatch):
cat imp/fpga/output/pynq-z2-pair-all/tidelink.bin | ssh mapstone-dev "cat > /tmp/tidelink_deploy/tidelink.bin"
# Repeat for tidelink-flip.bin, *.hwh, *.manifest.json
```

### 5.3 Deploy

```bash
ssh mapstone-dev "cd /tmp/tidelink_deploy && bash deploy_pair.sh 192.168.4.101 z2_02 die_a"
ssh mapstone-dev "cd /tmp/tidelink_deploy && bash deploy_pair.sh 192.168.6.101 z2_03 die_b"
```

### 5.4 Bring link up

For build #3 (Fix A2+B), bringup is now ONE APB write per side:

```bash
ssh mapstone-dev "for IP in 192.168.4.101 192.168.6.101; do \
  sshpass -p xilinx ssh -o StrictHostKeyChecking=no xilinx@\$IP \
    'echo xilinx | sudo -S python3 /tmp/td_set_train.py'; done"
# Wait 2s; lane_locked=0xff and cal_done=1 should both hold
```

For older builds: `bringup_pair_converge.sh` (re-deploy loop, ~5 min per converge).

### 5.5 Run sandwich

```bash
ssh mapstone-dev "ITERS=6 HEALTH_STREAK=2 SLEEP=1.5 bash /tmp/td_overnight_scripts/td_sandwich_iter.sh"
```

Per iteration: link state read, doorbell M→S, doorbell S→M, PTP HW_SYNC pulse + status read, AHB N=1 packet (gated by HEALTH_STREAK).

### 5.6 PTP convergence

```bash
ssh mapstone-dev "DURATION=20 SAMPLE_PERIOD=0.5 bash /tmp/td_overnight_scripts/bringup_ptp_sync.sh"
```

Expects link up (cal_done=1 both sides). Writes PTP_CTRL, HW_SYNC_CTRL; pulses PMOD-B trigger; reads PHC HW_CAP on both sides. **Today this fails** because slave HW_SYNC_STATUS stays 0 (Bug B).

## 6. Corrected understanding (things I had wrong earlier today)

A handoff is worth nothing if it propagates errors. These three I caught and corrected during the session:

1. **`PAIR_CREDIT_COUNTER` is NOT the application-credit gate.** Reading [tidelink_apb_regs.sv:195-225](src/rtl/tidelink_apb_regs.sv#L195) showed the counter is APB-write-managed (increments on writes to 0x020 in region 1, decrements on writes to 0x034). No TX-gating logic consumes it. It's status observability only. PAIR_CREDIT_COUNTER=0 just means "SW never wrote to it" — not a deadlock.

2. **PTP doesn't share the AHB credit pool.** PTP has its own port on the chiplet controller; ShortPacketToWlink has zero credit logic. So Bug B is NOT credit-starvation. (My demux report had this wrong initially — corrected.)

3. **cal_done is bit 16 of SWI_LANE_STATUS, not bit 8.** Sandwich script was using bit 8 and showing spurious "link down" reports. Fixed in-flight.

4. **Slave's lane_locked drops to 0 once training_mode clears** — expected, NOT a regression. lane_checker only matches the training pattern. cal_done is the correct post-training health gate.

## 7. fpgahub functionality that matters

Discovered/confirmed during this session:

### Lease management
```
fpgahub pair lease show bridge1          # who holds it, when expires
fpgahub pair lease acquire bridge1 --ttl 3600
fpgahub pair lease release bridge1
fpgahub pair lease heartbeat bridge1     # extend TTL
```

### Deploy
```
fpgahub board program <name> <bitstream> --method linux   # via PYNQ overlay
# Bypasses staging dir; use deploy_pair.sh in the staged tree for the standard flow
```

### Power-cycle (the answer to "z2_02 is wedged")

```
fpgahub hub power-cycle pynq_z2_02 --yes --off 3.0
fpgahub hub power-cycle pynq_z2_03 --yes --off 3.0
```

- uhubctl-driven USB-port power cycle of the upstream hub port
- Accepts board names (`pynq_z2_02_pl`) or chassis names (`pynq_z2_02`)
- `--off 3.0` gives PSU caps time to drain (default 1.0 s often too short for full DDR reset)
- Wait ~30 s after re-power for Linux to boot
- Use this when SSH is gone — the brute force option. Wedge recovery cost: ~1 min vs ~5 min for physical reach-around to the board.

### Software-level reset (if SSH still works)

```
fpgahub chassis reset pynq_z2_02 --yes         # default = manifest:reset
fpgahub chassis reset pynq_z2_02 --method uart # PS-side uart reboot
fpgahub chassis reset pynq_z2_02 --list        # show available methods per member
```

### Inspection
```
fpgahub board show <name>           # config + lease state
fpgahub pair list                   # all pairs with member roles
fpgahub chassis list                # all chassis
fpgahub hub list                    # uhubctl hubs + ports
fpgahub board status <name>         # synthesised status
```

## 8. Scripts and utilities created/staged today

### New, on the local working tree

- [docs/BUILD1_LESSONS_LEARNED_2026_05_29.md](BUILD1_LESSONS_LEARNED_2026_05_29.md) — what we carried forward from the overnight build
- [docs/BUILD3_HW_VALIDATION_2026_05_29.md](BUILD3_HW_VALIDATION_2026_05_29.md) — build #3 silicon results
- [docs/DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md](DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md) — the Bug A + Bug B reproduction story (corrected)
- [docs/I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md](I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md) — ASIC autonomy gap analysis
- [docs/CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md](CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md) — calibrator sticky-low bug audit (earlier today)
- [docs/PER_LANE_PHASE_CAPABILITY_AUDIT_2026_05_29.md](PER_LANE_PHASE_CAPABILITY_AUDIT_2026_05_29.md) — RTL capability for auto/manual phase setting
- [docs/BUG_DIAGNOSES_2026_05_29.md](BUG_DIAGNOSES_2026_05_29.md) — diagnostic agent output (**TBD when agent returns**)
- [docs/SIM_REPRO_RESULTS_2026_05_29.md](SIM_REPRO_RESULTS_2026_05_29.md) — cocotb regression test results (**TBD when agent returns**)
- `pynq_host/scripts/stress_toolkit/` — web GUI for stress tests on port 8089 (~3.4 KLoC, 36 unit tests pass)
- `pynq_host/scripts/eye_toolkit/` — eye/lane-phase visualization GUI (renamed from "live-eye" to "live-lane-phase")

### Staged on mapstone-dev `/tmp/td_overnight_scripts/`

| Script | Purpose | Wedge-safe? |
|---|---|---|
| `deploy_pair.sh` | Hash-checked bitstream deploy, sequential master+slave | Yes |
| `bringup_pair_converge.sh` | Iterative re-deploy loop (now mostly obsolete with build #3) | Yes |
| `bringup_ptp_sync.sh` | PTP HW_SYNC convergence; writes PTP_CTRL, HW_SYNC_CTRL | Yes (no AHB_TX) |
| `_ptp_common.sh` | Shared helpers for PHC + APB writes via SSH+sudo+python | n/a |
| `td_set_train.py` | One-shot: write SWI_TRAINING_MODE=1 | Yes |
| `td_clear_train.py` | One-shot: write SWI_TRAINING_MODE=0 + report status | Yes |
| `td_doorbell_test.py` | APB doorbell ring + read resp_acc | Yes |
| `td_gpio_phy_apb_read.py` | Dump tidelink_gpio_phy_apb_regs region | Yes |
| `td_ahb_stress.py` | AHB_TX packet TX + RX | **NO** — can wedge if link unhealthy |
| `td_read_cal_state.py` | Read calibrator FSM state | Yes |
| `td_apply_phase_override.py` | Per-lane SWI_PHASE_OFFSET / SWI_BIT_SLIP write | Yes |
| `td_sandwich_iter.sh` | Iterative PTP+AHB sandwich loop with health gate on N=1 AHB | Mostly yes |
| `wlink_probe.sh` | Per-channel Wlink counter probe | Yes |

**Wedge-safety rule:** anything that writes AHB_TX (0x4400_0000) can lock the PS in build #1/#2. In build #3 the wedge primitive is gone, but the rule still stands as belt-and-braces.

## 9. Bug diagnoses (from dedicated diagnostic agent)

**Full hypothesis bank with concrete experiments:** [docs/BUG_DIAGNOSES_2026_05_29.md](BUG_DIAGNOSES_2026_05_29.md). 173 lines, technical. Read it before opening RTL.

### Three independent FC channels confirmed

1. **TideLink FC node** (`tl2wl`, data_id≈0xa1) — AHB packets. 48-bit packed: `pkt_type[47:46]` + `addr_offset[45:32]` + `payload[31:0]`. **No application-level TX credit gate.**
2. **ShortPacketToWlink** (data_ids 0x50=SYNC, 0x51=DELAY_REQ) — PTP. RX hard-filter on `dataIdMatch` at line 57.
3. **AXI initiator/target** — XHB500 remote bursts.

### Bug A leading hypothesis (60%) — A-1: FC RX FSM rx_pkt_type misdecode

Slave's `rx_pkt_type = rx_fc_word_r[47:46]` may be picking up `SIDEBAND` (01) instead of `FIFO_DATA` (00) on AHB packets. That would explain:
- AHB packets are getting routed to `fc_rx_cfg_*` (APB writes) instead of `fc_rx_fifo_*`
- The 0x5000 bumps at slave 0x024 may be **misrouted FIFO_DATA word 0** masquerading as sideband
- Master HREADY returns cleanly because TX skid drains normally (slave accepts at link layer)

**ILA experiment** to confirm or refute: probe slave `tidelink_top.u_fc_adapter.{rx_fc_word_r[47:46], rx_pkt_type, fc_rx_fifo_valid, fc_rx_cfg_psel, fc_rx_cfg_paddr}` while master writes AHB N=1. Expected ~2h wall.

Other A-candidates ranked: A-2 packet_active_r race (25%), A-3 master TX address-clipping (10%), A-4 reset-glitch FSM wedge (5%).

### Bug B: WE'VE BEEN READING THE WRONG REGISTER

Critical finding: **`HW_SYNC_STATUS` at offset 0x048 on the slave is `hw_sync_en_r`** — the **initiator-side enable**, not a receive counter. Slave never enabled HW_SYNC, so `HW_SYNC_STATUS=0` is **expected behaviour**, not a bug.

For slave-RX visibility, read instead:
- `PTP_STATUS` at offset 0x03C bit[2] = `ptp_rx_valid_r`
- `PTP_RX_PAYLOAD` at offset 0x038 — the received sync payload

This means **the sandwich script's `HW_SYNC_STATUS` poll on the slave was a false-positive bug indicator**. The actual question is whether `PTP_STATUS[2]` and `PTP_RX_PAYLOAD` change on slave during master HW_SYNC. **Re-test required** before declaring Bug B exists at all — could be a measurement bug.

(If Bug B does exist on re-test, the ShortPacketToWlink path is the next candidate: `rx_fifo_io_winc = rx_pkt_valid & ~rx_fifo_io_wfull` at line 57, gated by dataIdMatch. Probe master's `tx_fifo_io_wfull`, master's `tx_valid`, slave's `rx_pkt_valid`, slave's `rx_fifo_io_winc`.)

### A and B may share a root cause

If A-1 is real (FC RX FSM rx_pkt_type misdecode), it could ALSO affect short-packet decoding if the ShortPacket dataId arrives at the same RX demux pre-filter. But ShortPacket and FC node are split BEFORE rx_pkt_type decode (separate Wlink lanes), so probably independent. The agent gives them as independent.

### Recommended experiment ordering (max info gain first)

1. **Re-measure Bug B with the right register** (`PTP_STATUS` 0x03C bit[2], `PTP_RX_PAYLOAD` 0x038). Effort: 10 min. May eliminate Bug B entirely.
2. **ILA for A-1 (rx_pkt_type misdecode)**. Effort: ~2 h. Highest probability hypothesis.
3. **Sim instrumentation of FCSM** (already-failing sim test_07/08 gives ~6 min iteration loop). Could catch A-1 in sim if probes added in the same place.

## 10. Open questions for the next engineer

1. **Should we build an ILA image targeted at the credit / CR packet observability signals?** The chiplet controller already exposes `obs_cr_pkt_seen_rx_w` and `obs_pkt_is_cr_pkt_w`. ~60 min build, very high ROI vs more static analysis.

2. **Should we cherry-pick the I2C training-mode coordination FSM** from `feat/i2c-autonomous-lock-integ` into this branch as Phase B of the autonomy roadmap? Skeleton RTL exists at `staging/i2c_train/tidelink_autoneg_train_states.sv`. ~3-5 days.

3. **Is Phase A (fix Bug A + Bug B in RTL) gated on the sim regression agent's output?** Probably yes — sim repro is the fastest path to root cause.

4. **Holding the lease**: bridge1 is held until 16:09 BST. Decide whether to keep it for further HW debug or release. The diagnostic agent's recommendations should inform this.

5. **PTP_CTRL bit 2 vs bit 3 asymmetry**: master uses bit 3 = GM-mode initiator. Slave should not set this. Document explicitly in the deploy script so future runs are repeatable.

## 11. Memory entries worth updating before close-out

- `project_tidelink_fpga_bringup.md` — promote build #3 silicon validation
- `project_tidelink_v1_asic_target.md` — promote autocal-from-deploy finding
- `feedback_sim_gate_before_hw_deploy.md` — reinforce: Bug A and B should have been sim-caught
- `reference_tidelink_address_map.md` — add the correction that PAIR_CREDIT_COUNTER is SW-managed (not link)

## Appendix A — APB address map quick reference

All offsets relative to `PAIR_BASE_ADDR = 0x44032000`.

| Offset | Width | Name | Direction | Notes |
|---|---|---|---|---|
| 0x008 | 32b | REG_PKT_LEN | RO | Slave packet word length |
| 0x00c | 32b | CRED | RO | Current free credits |
| 0x010 | 32b | REG_STATUS | RO | bit 0 = returner_busy |
| 0x014 | 32b | REG_DOORBELL | WO | Ring doorbell to peer |
| 0x020 | 32b | REG_RELEASED_ACC | W=add R=clear | Released credits accumulator |
| 0x024 | 32b | REG_DOORBELL_RESP_ACC | W=add R=clear | Doorbell RX counter (also bumps on inbound FC bytes) |
| 0x028 | 32b | PAIR_CREDIT_COUNTER | RO (SW-managed) | NOT consumed by TX gating; observability only |
| 0x034 | 32b | PTP_CTRL | RW | bit 0 = ptp_enable_r, bit 3 = GM (master only) |
| 0x040 | 32b | HW_SYNC_CTRL | RW | bit 0 = enable, bit 2 = force_en |
| 0x048 | 32b | HW_SYNC_STATUS | RO | Slave status stays 0 (Bug B) |
| 0x05c | 32b | SERVO_STATUS | RO | Servo state |
| 0x080 | 32b | ROLE_CFG | RW | bit 0 = role (0=master), bit 1 = lock |
| 0x100 | 32b | SWI_TRAINING_MODE | RW | Write 1 to drive training pattern |
| 0x108 | 32b | SWI_LANE_STATUS | RO | bits[7:0] = lane_locked, bit 16 = cal_done |

External regions:
- 0x44000000 = AHB_TX (DO NOT WRITE if link unhealthy — wedge hazard in pre-build #3)
- 0x44010000 = AHB_RX FIFO (slave reads here for incoming packets)
- 0x44050000 = PHC (local, doesn't traverse link)

## Appendix B — Build #3 provenance

| Artefact | sha256 | md5 | Built |
|---|---|---|---|
| master `tidelink.bin` | `d15adec0…b4dd…9a1c718a` | `3ee2149d50d5a718cbcbbc8adb994d05` | srv03335 @ 12:58:19 BST |
| slave `tidelink-flip.bin` | `b02cecc9…fd51…30c456e8b` | `ab87ca05ec650bdfc8bf080e1df21082` | srv04936 @ 12:27 BST |
| Source commit | `dda0a0e88bfb25284c1d125687b638b3862c9524` | — | feat/td-gpio-phy-integration |

Includes:
- Calibrator Fix A2 (revert score predicate to `lane_locked[i]` — undoes sticky-low pathology)
- Calibrator Fix B (phase-INNER iteration restored per §9.11 spec)
- AUTOCAL_ENABLE = 1'b1 ([tidelink_top.sv:1895](src/rtl/tidelink_top.sv#L1895))
- Stress GUI commit (operational, not link-affecting)
- Eye GUI "live-lane-phase" rename + in-app help

## Appendix C — Memory entries used to compile this report

- `project_tidelink_wlink.md`
- `project_tidelink_ptp.md`
- `project_tidelink_fpga_bringup.md`
- `project_tidelink_v1_asic_target.md`
- `project_phc_phase1_hw_diagnosis_2026_05_24.md`
- `project_tidelink_calibrator_fix_2026_05_27.md`
- `project_tidelink_bug_isolated_2026_05_26.md`
- `project_tidelink_sim_repro_2026_05_26.md`
- `project_tidelink_i2c_autonomy.md`
- `reference_tidelink_address_map.md`
- `reference_tidelink_role_lock.md`
- `reference_phc_ila_capture.md`
- `feedback_lease_grant_before_deploy.md`
- `feedback_sim_gate_before_hw_deploy.md`
- `feedback_research_ip_library_readonly.md`
