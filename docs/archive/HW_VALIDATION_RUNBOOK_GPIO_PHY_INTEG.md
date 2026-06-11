# Hardware Validation Runbook — tidelink-gpio-phy Integration

**Branch:** `feat/td-gpio-phy-integration`
**Submodule pins:** `tidelink-gpio-phy@d23a8cd` (main), `axi-chiplet-controller@c0a69ff` (`feat/td-gpio-phy-integration`)
**Parent HEAD:** `886e28f` (post-verification + cr_pkt_seen_i/min_lock_dwells_i reconnect fix)
**Target hardware:** pynq-z2 pair via fpgahub (mapstone-dev ProxyJump per [reference_pynq_boards](../../.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/reference_pynq_boards.md))

**Pre-conditions** — every item below MUST be green before scheduling a Vivado build (Vivado synth ≈ 45-60 min × 2 builds for the pair; do not burn it on a broken sim):

- [ ] `make lint` (Verilator) PASS across parent + both submodules
- [ ] Existing tidelink cocotb regression PASS (`make sim-regression`)
- [ ] `tidelink-gpio-phy` cocotb unit tests PASS (lane_checker_single + lane_checker_8lane)
- [ ] Integrated paired-die sim (`cocotb/tidelink_top_pair/`) PASS — sim gate per [feedback_sim_gate_before_hw_deploy](../../.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/feedback_sim_gate_before_hw_deploy.md)
- [ ] UVM smoke regression PASS (or documented exclude)
- [ ] Pattern-search regression deterministic (`bash deps/tidelink-gpio-phy/scripts/run_search.sh` + `git diff --exit-code results/`)
- [ ] All 3 integration branches pushed to their remotes

---

## Phase 1 — FPGA build (Vivado)

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ

# Concurrent farm build per project_tidelink_concurrent_farm memory
make build_pair_farmed \
    TARGET=pynq-z2-pair-flip-ila \
    SUBMOD_TIDELINK_GPIO_PHY=$(git -C deps/tidelink-gpio-phy rev-parse HEAD) \
    SUBMOD_AXI_CHIPLET=$(git -C deps/axi-chiplet-controller rev-parse HEAD)
```

Expected runtime: ~50 min wall-clock, two bitstreams produced under `fpga/builds/<sha>/{master,slave}/`.

**Gate check before deploy:** Vivado reports must show:
- Timing met (WNS ≥ 0 on all paths)
- No critical warnings in the new `tidelink_gpio_phy_apb_regs`, `tidelink_lane_checker`, `tidelink_lane_checker_single`, `tidelink_popcount16` instances
- `USE_T3A` constant-folded to 0 in the 8 RX instances (post-synth schematic check)

---

## Phase 2 — Lease + deploy

Per [reference_pynq_boards](../../.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/reference_pynq_boards.md) — lease MUST be **granted**, not queued (per [feedback_lease_grant_before_deploy](../../.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/feedback_lease_grant_before_deploy.md)).

```bash
# Lease a z2 pair (master + slave)
fpgahub lease z2_pair_flip_ila --duration 90m

# Verify lease is GRANTED (not queued)
fpgahub status | grep -i granted   # MUST show your pair

# Deploy paired bitstream — coordinated parallel via S_HOLD bridge
bash pynq_host/scripts/deploy_pair_with_retry.sh \
    --build <sha> \
    --pair z2_03,z2_04 \
    --max-retries 5
```

**Gate check:** deploy_pair script must report **both** boards programmed and `role_locked=1` on each.

---

## Phase 3 — APB readback verification (NEW SLAVE)

The new APB slave is at relative `0x160` on `tl_apb_paddr[8:5]==4'b1011`. Absolute address depends on the SoC base — derive from the existing eye_regs offset:

```bash
# Find eye_regs base; new slave is at eye_regs_base + 0x20
EYE_BASE=$(grep -E 'EYE_LANE_CRC_0\b' src/sw/include/tidelink_addr_map.h | awk '{print $3}')
GPIO_PHY_BASE=$((EYE_BASE + 0x20))   # 0x160 - 0x140 = 0x20

# Read the 8 new registers via APB
ssh mapstone-dev "cd ~/pynq_host && ./apb_read.sh z2_03 \
    $((GPIO_PHY_BASE + 0x00)) \
    $((GPIO_PHY_BASE + 0x04)) \
    $((GPIO_PHY_BASE + 0x08)) \
    $((GPIO_PHY_BASE + 0x0C)) \
    $((GPIO_PHY_BASE + 0x10)) \
    $((GPIO_PHY_BASE + 0x14)) \
    $((GPIO_PHY_BASE + 0x18)) \
    $((GPIO_PHY_BASE + 0x1C))"
```

**Expected values:**

| Offset | Name | Expected |
|---|---|---|
| `+0x00` | `SWI_LANE_THRESH` | `0x33333333` (each 4-bit slot's low 3 bits = 3, default) |
| `+0x04` | `SWI_LANE_NOISE_RAW_LO` | `0x00000000` initial, populates after first training window |
| `+0x08` | `SWI_LANE_NOISE_RAW_HI` | same |
| `+0x0C` | `SWI_LANE_NOISE_VOTED_LO` | same |
| `+0x10` | `SWI_LANE_NOISE_VOTED_HI` | same |
| `+0x14` | `SWI_LANE_NOISE_MODE` | `0x00000002` (default = mean) |
| `+0x18` | `SWI_LANE_WIRING_STATUS` | initial `0x0000`; post-S_DONE all `WIRE_OK` (0x5555) |
| `+0x1C` | `SWI_LANE_CANARY_STATUS` | `canary_valid[15:8]=0xFF`, `canary_pass[7:0]=0xFF` after first training window |

**FAIL conditions:**
- `SWI_LANE_CANARY_STATUS[7:0] != 0xFF` after canary_valid=0xFF → bit-order is reversed somewhere. Likely PCB or serialiser. Abort. Do NOT proceed.
- `SWI_LANE_WIRING_STATUS` shows any `WIRE_SWAPPED` or `WIRE_DEAD` → cable swap or dead PHY. Investigate.
- `SWI_LANE_NOISE_VOTED_*` shows distance ≥ 4 on any lane in steady state → noise floor too high; channel is noisy. Document.

---

## Phase 4 — Functional bring-up

Run the existing convergence script with the new bitstream:

```bash
ssh mapstone-dev "bash ~/pynq_host/scripts/bringup_pair_converge.sh \
    --pair z2_03,z2_04 \
    --max-recal-loops 16"
```

**Expected outcome:**
- `lane_locked == 8'hFF` on both boards within ≤ 4 recal loops
- `calibration_done == 1` on both
- `cr_pkt_seen == 1` (FCSM credit handshake completed)
- AUTOCAL_ENABLE = 1 (NOT the AUTOCAL=0 workaround)

**FAIL conditions:**
- `lane_locked < 8'hFF` after 16 recal loops → S_PROBE bias didn't help, sim/HW gap. Capture ILA, escalate.
- Master/slave `(slip, phase)` asymmetry on any lane → S_PROBE didn't bias both ends to (0,0). Check `dwell_min_dist` register values.

---

## Phase 5 — ILA capture (debug data for the record)

```bash
ssh mapstone-dev "cd ~/pynq_host && ./scripts/phc_ila_capture.sh \
    --board z2_03 --board z2_04 \
    --depth 32k \
    --probes lane_locked,wire_status,canary_pass,canary_valid,dist_voted[39:0],cur_state[3:0]"
```

Archive captures to `pynq_host/ila_dumps/integration_<date>/`.

---

## Phase 6 — PHC sync soak (functional gate)

The integration is gated on PHC sync still working — the new lane_checker must not regress the timing-critical sync packet path.

```bash
ssh mapstone-dev "bash ~/pynq_host/scripts/bringup_ptp_soak.sh \
    --pair z2_03,z2_04 \
    --duration 30m \
    --target-jitter-ns 50"
```

**Pass criteria:**
- Mean offset < 100 ns
- Jitter (1σ) < 50 ns
- No re-sync events during the 30 min window
- All 8 lanes stay locked throughout (no `lane_locked` glitches)

---

## Phase 7 — Eye-toolkit GUI sanity (documented break)

The eye-toolkit web GUI (`eye-toolkit-web` lease at HEAD `b9d1afc`) reads the OLD `EYE_LANE_CRC_*` registers, which now return 0. This is **expected** per [INTEGRATION_GUIDE.md §6.2](../deps/tidelink-gpio-phy/docs/INTEGRATION_GUIDE.md). Verify:

- [ ] GUI shows lane error count = 0 on all 8 lanes (was previously a saturating counter)
- [ ] Document the GUI's MMIO read targets that need updating to `SWI_LANE_NOISE_VOTED_*` at `0x160` family
- [ ] File follow-up task to update `eye-toolkit-web` consumer

**This is NOT a regression** — it's the planned removal per spec §10. Confirm the consumer migration is on the punch list.

---

## Phase 8 — Tear-down + report

```bash
# Release lease
fpgahub release

# Generate validation report
python3 pynq_host/scripts/gen_validation_report.py \
    --capture-dir pynq_host/ila_dumps/integration_<date>/ \
    --output docs/HW_VALIDATION_REPORT_GPIO_PHY_<date>.md
```

Report MUST include:
- All Phase 3 register reads, observed vs expected
- All Phase 4 lock-time histogram
- Phase 6 PHC sync statistics
- Phase 7 GUI break confirmation
- PASS/FAIL verdict per phase
- Any anomalies + photographs of cabling if WIRE_SWAPPED hit

---

## Abort matrix

| Phase | Failure | Action |
|---|---|---|
| 1 | Vivado timing fail on new RTL | Open critical-warning report → fix in submodule → re-run Phase 1 |
| 2 | Lease never granted | Retry; if persistent, escalate to lab admin |
| 2 | Deploy `role_locked == 0` | Check JTAG cable, board power, FT2232H mapping |
| 3 | `canary_pass != 0xFF` | **STOP** — bit-order issue. Check ribbon wiring, serialiser order |
| 3 | `WIRE_SWAPPED` | Document which pair; recable; re-run Phase 4 |
| 4 | `lane_locked < 0xFF` after 16 loops | Capture ILA + escalate; do NOT proceed to Phase 6 |
| 5 | ILA capture fails | Skip; document for offline debug |
| 6 | PHC jitter exceeds budget | **STOP** — regression vs `feat/td-wedge-fix` baseline. Open bug |
| 7 | GUI shows non-zero error | unexpected — investigate |

---

## Sign-off

This branch is sign-off-ready when:
- All phases PASS (or Phase 7 is the documented expected-break)
- HW validation report committed under `docs/`
- Integration branches pushed to all 3 remotes
- Eye-toolkit-web migration follow-up filed
