# TideLink Interface Bringup Debug Plan

**Date**: 2026-05-24 (Plan v1: 21:00 UTC, **v2 revision: 21:13 UTC** after Phase 0 outcome)
**Status**: **Phase 0 + Phase 1 EXECUTED**. Root cause class identified as link-credit-handshake (FCSM). PTP fix work paused. Plan revised below.
**Author**: Multi-agent synthesis (4 + 4 explore agents + handoff doc + memory + repo audit + live HW tests)
**Predecessor**: [docs/PHC_PHASE1_HANDOFF.md](PHC_PHASE1_HANDOFF.md)
**Phase 0 outcome doc**: [docs/TIDELINK_PHASE0_OBS_20260524_2109.md](TIDELINK_PHASE0_OBS_20260524_2109.md)
**Working branch**: `feat/td-interface-debug` in worktree `/home/dam1n19/SoCLabs/td-bisect/td-interface-debug/` (created off `main @ f6a7d19`)

---

## A. Phase 0 outcome (2026-05-24 21:00-21:13 UTC) — read this first

Phase 0 was executed on the b24 bitstream (commit c6c56c2, the bitstream already deployed on bridge1). Three independent live-HW tests:

1. **AHB SUB peer-write (`hwtest/03_ahb_sub_e2e.sh §3d`)** — master writes `0xDEADBEEF` to `0x44010000`, slave reads same → reads `0x00000000`. Bidirectional fail.
2. **Doorbell peer-visibility (`hwtest/04` pattern)** — master rings `DOORBELL @ 0x44032014` 8 times → slave's `DOORBELL_RESPONSE_ACC @ 0x44032024` stays at `0`. Same in reverse. No traffic crosses the link at the application layer.
3. **Pair-credit accounting** — `PAIR_CREDIT_COUNTER @ 0x44032028` reads `0x00000000` on BOTH sides. No application-layer credits ever exchanged.

Yet PHY is fully clean: 8/8 lanes locked, cal_done=1, ECC=0/0, FC CRC=0/0, LinkStatus rx_data_valid=1.

The deciding bit: **slave's `SWI_LANE_STATUS[23] = cr_pkt_seen_rx = 0` (sticky)** — slave has never seen master's CR (Credit Release) packet. The credit handshake never completes; therefore the credit window never opens; therefore no application traffic can flow. PHC, AHB SUB, doorbell all fail for the **same** reason.

Implications:
- **PTP debug (b18-b25) was chasing the wrong symptom.** All those fixes can be reverted; the bug is one layer below PTP.
- **The handoff §3 row F ("CR/CRACK asymmetry, ruled out as red herring") needs re-opening.** Agent F asserted the FCSM self-heals via CRACK; empirical state (PAIR_CREDIT_COUNTER=0 both sides) shows it does NOT.
- **The handoff §4 evidence of "Master `sp2wl/tx_valid` fires" + "Slave `sp2wl/rx_pkt_valid` fires for data_id=0x50"** is real but only proves PHC SP packets get classified — it does NOT prove the link's *credit* path works. The PHC short packets in the ILA capture may have been arriving INTO a closed credit window and being silently dropped at the FC layer above the byte/frame layer.

---

---

## 0. Executive summary

We have spent ~10 build cycles (b18→b25) hunting a PHC-layer fix and the bug still isn't closed. Every fix has assumed the bug lives in `tidelink_ptp.sv`. The handoff describes the symptom as "PTP_CTRL[2] never sets" — but we have **never independently verified that the TideLink interconnect actually transports a non-PTP payload across the ribbon at the application layer**. The current `bringup_pair_converge.sh` only proves lane training, not application-layer data movement.

This plan steps back from PTP entirely:

1. **Establish ground truth on the existing b25 bitstream** with non-PTP tests we already own (`hwtest/03_ahb_sub_e2e.sh`) — answers "does the interconnect move data at all?" in ≤30 min, no rebuild.
2. **Set up a parallel debug worktree** off `main` (NOT off the b25 chain) so the active b25 farm/release path is untouched.
3. **Add maximum observability** — registers and ILA hooks — for signals we currently can't see (per-lane IDELAY taps, RX-clock liveness, per-data_id RX counters, FC CRC errors).
4. **Streamline the RTL** — temporarily stub non-essential modules (servo, perf, optionally PTP itself) behind compile-time parameters so the bitstream's debug surface area is minimal and the implicated cones are isolated.
5. **Build with `FPGA_INSERT_DEBUG_CORE=1`** on the concurrent farm with manifest provenance.
6. **Systematic HW iteration** — one variable per build, decision gates after each.

The output is either (a) a fix lands in mainline OR (b) we have evidence that pins the root cause to a specific physical layer (P&R skew / CDC / pin map) at which point we know the right escalation.

> **PTP is explicitly out of scope for this plan.** PTP fixes resume once the underlying TideLink interface is proven solid (or proven broken with a concrete root-cause hypothesis).

---

## 1. Problem framing — what we know and don't

### 1.1 What's proven on HW
- Link layer reports `lane_locked=0xff` both sides, `cal_done=1`, FCSM=2, `ECC_COUNTERS=0` on slave (per b25 handoff §4).
- Master `sp2wl/tx_valid` ILA fires (master IS transmitting short packets).
- Slave `sp2wl/rx_pkt_valid` ILA fires with `data_id=0x50` (slave's link layer DOES classify valid SP packets).
- Slave `PHC_HW_CAP` advances on b24 (proves `rx_accept` IS firing at the PHC consumer).
- Slave `ptp_rx_valid_r` never sets to 1 (the latch consumer's view of `rx_accept` is permanently 0).

### 1.2 What we have NEVER verified on HW
- **Whether the TideLink (data_id=0xa1) general AHB packet path works at all on HW** — i.e. a master AHB write that lands in slave-side memory and reads back the same value.
- Whether `FC_TIDELINK_CRC_Errors @ 0x1720` is 0 (no script reads this register).
- Whether the per-lane IDELAY taps are mid-range or pinned at 0/31 (calibrator owns these but does not surface them).
- Whether the recovered RX-clock has *ever* been valid since reset (`llrx_valid` is a snapshot, not sticky).
- Whether non-PTP `data_id` packets arrive on slave with the right counts.

### 1.3 The class of bug (from SIM_HW_GAP_ANALYSIS.md + history)
Three hypotheses survive after the b18→b25 elimination:

| # | Hypothesis | Layer | Cheap to falsify? |
|---|---|---|---|
| **P1** | Vivado P&R routes per-lane `pad_rx[n]→IBUF→IDELAYE2` skew past the calibrator's ±15-tap window. Calibrator locks (eye at boundary) but RX deserialiser silently drops/garbles bits. **Asymmetric in flip-bitstream** because Y7-MRCC↔Y9-SRCC swap reroutes clock distribution. | Physical | YES via per-lane IDELAY tap dump + ECC count + `FC_TIDELINK_CRC_Errors` |
| **P2** | Recovered-RX-clock domain reset race — slave-side write-domain reset deasserts before first master clock edge; `sp2wl.rx_fifo` write pointer X-state propagates and a downstream FF latches X. | CDC | YES via sticky `ll_rx_ever_valid` + 16-bit RX-clock tick counter |
| **P3** | Consumer-replica synth divergence (b25's primary hypothesis) — but `(* keep *)(* dont_touch *)` on the FF doesn't stop synth replicating the LUT feeding it. | Synth | b25 farm result tells us; if b25 fails, P3 alone is insufficient |

All three are consistent with current evidence. They are **not mutually exclusive** — one or more may be active simultaneously. The plan is structured so each phase rules in or out one hypothesis.

### 1.4 Why this didn't appear in sim
- Verilator/cocotb model `IDELAYE2` as a passthrough or fixed-tap delay; sim never sees the bitstream-routed skew distribution.
- Sim clocks are perfectly synchronous from `t=0`; recovered-RX-clock liveness is never absent.
- Sim doesn't replicate FFs; one wire = one storage element by definition.
- Sim's flip-bitstream is identical to the non-flip (only pin map changes; no clock-region-mapping consequence in behavioural sim).

---

## 2. Phase 0 — Pre-flight ground truth (≤30 min, no rebuild, no RTL change)

> **Goal**: determine whether the bug is PTP-specific or interconnect-wide *using the b25 bitstream already built or building*. Cost: a single lease window + register reads. Outcome: a concrete decision gate.

### 2.1 Steps
1. Acquire `fpgahub pair lease acquire bridge1 --ttl 5400`; verify `granted` state (not queued).
2. If b25 farm has completed, deploy b25; otherwise deploy the previous known-good bitstream from `/tmp/tidelink_deploy/` after sha256-verifying provenance.
3. Run `bringup_pair_converge.sh` — confirm 16/16 (sanity check).
4. **Run `pynq_host/scripts/hwtest/01_wlink_layer.sh`** with master/slave IPs. Capture:
   - `SWI_LANE_STATUS @ 0x44032108` both sides (lane_locked, llrx_valid, llrx_state, is_short_pkt, cr_pkt_seen_rx)
   - `ECC_COUNTERS @ 0x44032114` both sides (`ecc_corrected[31:16]`, `ecc_corrupted[15:0]`)
   - **`FC_TIDELINK_CRC_Errors @ 0x44031720`** both sides — **never read before by any script**.
   - `LinkInterrupts @ 0x44030240` both sides (ECC event flags)
5. **Run `pynq_host/scripts/hwtest/03_ahb_sub_e2e.sh`**:
   - Master writes patterns to AHB SUB aperture `0x44010000`
   - Slave reads back at same offset (peer-visibility test, lines 89-102)
   - This exercises the FC node 0xa1 (TideLink) general AHB transport.
6. Dump all values into a fresh `docs/TIDELINK_PHASE0_OBS_<timestamp>.md`.

### 2.2 Decision gate

| Outcome of step 5 (`03_ahb_sub_e2e.sh`) | Interpretation | Action |
|---|---|---|
| **PASS** (slave reads back master's pattern) | TideLink general AHB path works. PTP is isolated to short-packet RX consumer logic. | Proceed to Phase 1, but the b25 cone-replication hypothesis is more likely; debug worktree can stay PTP-aware. |
| **FAIL** (slave reads `0x00000000` or stale data) | TideLink interconnect is broken at the application layer; PTP failure is a downstream symptom. | Proceed to Phase 1 with PTP **stubbed out entirely**; treat the bug as a base-link bug. |
| **PARTIAL** (some pattern bits land, others don't) | Bit-level corruption on the link — consistent with P&R skew hypothesis (P1). | Proceed to Phase 1; prioritise per-lane IDELAY tap observability. |
| **ECC_COUNTERS non-zero on slave** in step 4 | Link is corrupting frames at the byte level. P1 confirmed. | Skip RTL phases; jump to physical-layer investigation (XDC constraints, post-route timing). |
| **FC_TIDELINK_CRC_Errors non-zero on slave** | FC-layer packets are corrupted before they reach demux. | Same as ECC non-zero — physical layer issue. |

### 2.3 Why this phase is decisive
We have spent 7 days assuming the link is healthy because lane_locked=0xff. The hwtest scripts existed all along — they were never run during the PHC debug. 30 min here either confirms the link is healthy (validating all prior assumptions) OR demolishes them (in which case we never needed any PTP-specific fix).

---

## 3. Phase 1 — Parallel debug worktree setup (≤30 min, no build yet)

### 3.1 Worktree layout
```
/home/dam1n19/SoCLabs/td-bisect/td-interface-debug/   ← new
├── branch: feat/td-interface-debug
├── parent: main @ f6a7d19 (current HEAD, NOT the b25 chain)
└── submodule: deps/axi-chiplet-controller @ 8a4fcf5 (b22 ILA SHA — keep)
```

**Rationale for branching off `main`, not b25**:
- The b25 chain is in active farm/test cycle; don't disturb it.
- b25 carries PTP-specific RTL changes that we want to *isolate* from this experiment. We want the cleanest possible substrate.
- The b22 submodule ILA hooks (master TX side) are needed; the submodule SHA stays.

### 3.2 Create the worktree
```bash
cd /home/dam1n19/SoCLabs/tidelink
git worktree add -b feat/td-interface-debug \
    /home/dam1n19/SoCLabs/td-bisect/td-interface-debug main
cd /home/dam1n19/SoCLabs/td-bisect/td-interface-debug
git submodule update --init --recursive
# Verify submodule on b22 SHA
git -C deps/axi-chiplet-controller rev-parse HEAD  # expect 8a4fcf5...
```

### 3.3 Establish a build naming convention
Builds in this worktree are tagged `tdif-NN` (TideLink interface, build NN). Manifests:
- `--label tdif-NN-<short-desc>`
- `--commit <short-sha>`
- Staging dir on mapstone-dev: `/tmp/tidelink_deploy/td-interface-debug/` (separate from b25's staging to avoid mixup).

### 3.4 Update memory + cleanup_proposal
- Add a `project_tidelink_interface_debug.md` memory pointing at this plan + worktree.
- Update `cleanup_proposal.md` to NOT prune `td-interface-debug/`.

### 3.5 Exit criteria
- Worktree created, submodule pinned, builds compile (`make -C fpga package_ip` succeeds, no RTL changes yet).
- New build target `tdif-00-baseline` produces a bitstream byte-identical to main@f6a7d19 baseline (proves environment is clean before any modifications).

---

## 4. Phase 2 — Add maximum observability (REVISED post-Phase-0)

> **Goal**: surface every signal we currently can't see, focused on the **FCSM credit handshake layer** since that's where the bug lives. All additions gated by `DEBUG_OBS_EN` parameter (default 0 in IP wrapper, set to 1 in tidelink_vivado_wrapper.v via component.xml override).

### 4.1 New APB registers (Region 8 spare slots, slave-decode known-working)
Add to `src/rtl/tidelink_phy_align_regs.sv` (Region 8 lives there; slots `0x2118+` are available per Agent 4):

| Offset | Name | Width | Source | What it tells us | Priority |
|---|---|---|---|---|---|
| `0x2118` | `FCSM_STATE` | 32 | `[3:0]` master-FCSM-state, `[7:4]` slave-FCSM-state, `[15:8]` master rx_byte_aligner_locked, `[23:16]` slave rx_byte_aligner_locked, `[31:24]` reserved | **PRIMARY** — direct readout of the credit-handshake state machine that's currently stuck. Solves "is FCSM in S_NEED_CR vs S_NEED_CRACK vs S_RUNNING?" instantly. | **CRITICAL** |
| `0x211C` | `CR_CRACK_COUNTS` | 32 | `[7:0]` CR_RX_count, `[15:8]` CR_TX_count, `[23:16]` CRACK_RX_count, `[31:24]` CRACK_TX_count (all saturating) | **PRIMARY** — counts of credit packets seen and sent. Tells us if slave EVER received any CR (current sticky bit only tells "ever"; this tells "how many"). | **CRITICAL** |
| `0x2120` | `FCSM_STICKY` | 32 | `[0]` fe_tx_credit_max_loaded_master, `[1]` fe_tx_credit_max_loaded_slave, `[2]` ever_seen_pkt_is_cr_master, `[3]` ever_seen_pkt_is_crack_master, `[4]` ever_seen_pkt_is_cr_slave, `[5]` ever_seen_pkt_is_crack_slave, others reserved | **PRIMARY** — sticky bits proving whether each FCSM-internal trigger has EVER fired. | **CRITICAL** |
| `0x2124` | `RX_DATA_ID_LAST` | 32 | `[7:0]` last_data_id sticky (set every `ptp_sp_rx_valid` pulse, W1C), `[31:16]` non-PTP-data_id RX counter (saturating) | SECONDARY — tells us what data_ids actually reach the slave's classifier, regardless of credit state. | Medium |
| `0x2128` | `RX_CLOCK_LIVENESS` | 32 | `[31:16]` 16-bit saturating RX-clock tick counter (2-FF synced to APB clk), `[0]` sticky "RX clock ever valid" | TERTIARY — rules out a clock-domain race (downgraded post-Phase-0 since both sides see clean PHY metrics). | Low |
| `0x212C` | `IDELAY_TAP_LANES_PACKED` | 32 | calibrator's 8×4-bit tap values packed | TERTIARY — keep but no longer the primary lever since ECC=0/0 rules out byte-level skew. | Low |

**RTL cost**: ~120 lines across 2-3 files (`tidelink_phy_align_regs.sv` + Wlink FCSM module + calibrator). The FCSM module lives in the submodule `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_*.v`. **This may require a submodule bump if the FCSM RTL doesn't already expose the right signals.**

**Hook out a force-recal-FCSM register** (`0x2130 CMD_FCSM_RETRY`, W1C, RTL adds a re-init pulse to the slave FCSM): lets us probe whether a re-init can rescue the link, OR whether the bug is in the first-cycle CR detection vs persistent.

### 4.2 TCL-level mark_debug additions (no RTL change)
Extend `fpga/insert_debug_core.tcl` after line 25 with explicit nets:

```tcl
set extra_debug_nets {
    "tidelink_design_i/u_tidelink/u_fc_adapter/rx_state_r*"
    "tidelink_design_i/u_tidelink/u_fc_adapter/rx_pkt_type*"
    "tidelink_design_i/u_tidelink/u_fc_adapter/rx_is_fifo"
    "tidelink_design_i/u_tidelink/u_fc_adapter/fc_rx_fifo_valid"
    "tidelink_design_i/u_tidelink/u_tidelink_fifo/rx_commit_valid"
    "tidelink_design_i/u_tidelink/u_chiplet_controller/sp2wl_*"
    "tidelink_design_i/u_tidelink/u_chiplet_controller/llrx_state*"
}
foreach pat $extra_debug_nets {
    set nets [get_nets -hierarchical -quiet $pat]
    foreach n $nets { set_property MARK_DEBUG TRUE $n }
    if {[llength $nets] > 0} { lappend debug_nets {*}$nets }
}
```

**Cost**: ~15 lines TCL, no RTL changes.

### 4.3 New observability dump function
Add `pynq_host/scripts/tidelink_obs_dump.sh` — single function that reads all of the above + existing diagnostic registers + writes a timestamped markdown observation file. Called at every test gate. Modelled on the dump template at PHC_PHASE1_OBSERVABILITY_MAP.md §10.

### 4.4 Build tdif-01 and validate
```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-interface-debug
make -C fpga build_pair_farmed FARM_HOST=srv04936 FPGA_INSERT_DEBUG_CORE=1
# Manifest, stage, deploy as usual
```

### 4.5 Exit criteria
- New APB registers readable from both sides; values plausible (taps non-zero, ticks counting).
- ILA shows the new mark_debug'd nets.
- No regression in lane_lock (16/16 still works).

---

## 5. Phase 3 — Streamline RTL (~1 hour RTL + ~45 min farm = build tdif-02)

> **Goal**: shrink the bitstream's RTL surface area to the bare minimum that still exercises the TideLink interconnect. Reduce the cone count synth has to handle, reduce P&R freedom, eliminate red-herring debug paths.

### 5.1 Stub list (all gated by `STREAMLINE_EN` parameter, threaded via component.xml)

| Module | Action | Param | Rationale |
|---|---|---|---|
| `u_servo` (`tidelink_ptp_servo`) | Replace with stub: `assign servo_locked = 0; assign phc_adj_* = 0;` | `STUB_SERVO=1` | 669 lines of logic that aren't on the bringup data path. Removes a large cone class from synth. |
| `u_perf` (`tidelink_perf`) | Stub: tie all 524 lines of perf counters to zero | `STUB_PERF=1` | Profiling-only; removes hundreds of FFs. |
| `u_addr_translator` | Bit-exact passthrough (`translated_haddr = haddr`) | `BYPASS_ADDR_XLAT=1` | The CAM/lookup table is irrelevant for a single-pair link; passthrough removes 208 lines. |
| **`u_ptp` (`tidelink_ptp`)** | Optional: stub if Phase 0 decision gate says "interconnect-wide bug". Otherwise leave. | `STUB_PTP=1` (default 0) | If Phase 0 proved data crosses the link via `03_ahb_sub_e2e.sh`, leave PTP in to see if it's now fixed by streamlining alone. If it didn't, stub PTP and test pure AHB-over-FC path. |

### 5.2 Param threading
Each stub is a `generate` block in `tidelink_top.sv`:
```systemverilog
generate
if (STUB_SERVO) begin : g_servo_stub
    assign servo_locked = 1'b0;
    assign phc_adj_freq = '0;
    assign phc_adj_phase = '0;
end else begin : g_servo_real
    tidelink_ptp_servo u_servo ( ... );
end
endgenerate
```

Per memory `project_tidelink_v1_asic_target` and prior USE_CLKBUF threading: parameter must be carried in `component.xml` to reach OOC synth. Don't use ``ifdef`` (Vivado strips them at IP packaging).

### 5.3 Important: keep the link layer pristine
**Do NOT touch**:
- `u_chiplet_controller` (Wlink)
- `u_phy_align_calibrator`
- `u_fc_adapter` (the demux — Agent 2 confirmed this is essential)
- `u_tidelink_fifo`
- XDC constraints
- IDELAYE2 / BUFG instances

The streamlining is around the link, not on it.

### 5.4 Build tdif-02 and compare
```bash
make -C fpga build_pair_farmed FARM_HOST=srv04936 FPGA_INSERT_DEBUG_CORE=1 \
    STREAMLINE_EN=1
```
Compare utilization report vs tdif-01: expect ~10-20% fewer LUTs/FFs.

### 5.5 Exit criteria
- Bitstream builds clean with all stubs active.
- Lane lock 16/16 still works (the streamlining didn't break the link).
- AHB SUB e2e test passes (or fails identically to phase 0 — meaning streamlining hasn't masked the bug).

---

## 6. Phase 4 — Systematic HW iteration (REVISED post-Phase-0)

> **Goal**: with the high-debug, streamlined bitstream, isolate WHERE in the FCSM credit-handshake the bug lives. One variable per build. Decision gate after each. **Discipline: every tdif-NN build MUST be preceded by `make sim-repro` passing (see §8 below).**

### 6.1 Test matrix (run in this order, post-Phase-0 revision)

| Build | What | Tests run | Pass criteria |
|---|---|---|---|
| **tdif-02 (base)** | Phase 2 observability registers + Phase 3 streamlining only. No fix attempted. | `01_wlink_layer.sh`, doorbell-peer test (lib helper), `tidelink_obs_dump.sh`, ILA on FCSM signals | Confirms the bug reproduces in the streamlined bitstream; reads the new FCSM_STATE/CR_CRACK_COUNTS registers to localize: did slave see ANY CR? How many? Did master send any CRACK? |
| **tdif-03 (FCSM re-init)** | Pulse the new `CMD_FCSM_RETRY` register (or `swi_swreset` bit 3 sequenced differently) after lane_lock+cal_done. Does the FCSM re-init catch the CR this time? | Doorbell test pre- and post-retry pulse | If post-retry doorbell crosses: bug is **first-cycle CR detection race** (byte-aligner not locked yet when master sends initial CR). Solution: gate master's CR until slave lane_locked+aligned. |
| **tdif-04 (RX byte aligner sticky-lock)** | Add `(* keep *)` + sticky-OR on the slave's `sp2wl` byte aligner output; ensure slave's CR detector receives a stable byte stream from the moment lane_locked goes high | Doorbell + AHB-SUB + ILA on `pkt_is_cr` at slave | If doorbell crosses: bug is in the sp2wl byte-aligner first-byte handling. |
| **tdif-05 (CRACK self-heal)** | If tdif-04 still fails: instrument and force the CRACK self-heal path. Per Agent F's claim it should rescue; verify or refute. | Same | Determinative: is the system "supposed to" self-heal or not? |
| **tdif-06 (master TX CR retransmit)** | If slave never receives any CR, have master periodically retransmit CR (every N cycles, gated until slave acks via CRACK). Simple "keep ringing the doorbell until peer answers" pattern. | Same | Highest-confidence fix if other diagnoses inconclusive. |

### 6.2 Iteration discipline
1. **One change per build.** No multi-fix builds. If two changes are bundled and the build passes, we don't know which one fixed it.
2. **Full observation dump every deploy.** Save to `docs/tdif/tdif-NN-obs-<timestamp>.md`.
3. **ILA capture every deploy.** Even if the AHB SUB test passes, capture for regression baseline.
4. **Cleanup discipline.** Each test releases the lease and pkills any orphan deploy trees (per memory `feedback_lease_grant_before_deploy`).

### 6.3 Per-build runtime budget
- Farm build: ~45 min concurrent on srv04936.
- Manifest + stage: ~5 min.
- Deploy + bringup + test: ~10-15 min.
- ILA capture + analysis: ~10-20 min.
- **Total per cycle: ~80-90 min worst case.** Plan for 3-4 cycles per day.

### 6.4 Decision gates
After tdif-02 baseline:
- **AHB SUB e2e PASSES**: streamlining alone fixed the bug → the issue was synth surface area / specific module interaction. Bisect by re-enabling stubs one at a time to find the culprit.
- **AHB SUB e2e FAILS, IDELAY taps at edge**: jump straight to tdif-03 (P1 fix).
- **AHB SUB e2e FAILS, IDELAY taps mid-range, RX_CLOCK_LIVENESS sticky=0**: jump to tdif-04 (P2 fix).
- **AHB SUB e2e FAILS, all observability healthy except FC_TIDELINK_RX_COUNT=0 on slave**: the demux is dropping packets → ILA on `fc_adapter.rx_state_r` for evidence.

---

## §X. Sim-regression discipline (NEW — per user instruction post-Phase-0)

> **Rule**: every HW deploy iteration in Phase 4 MUST be preceded by `make sim-repro` passing in the worktree. No exceptions.

### §X.1 The minimum sim-repro test

In `cocotb/wlink_pair/test_paircredit_handshake.py` (new file):

```python
@cocotb.test()
async def test_paircredit_nonzero_after_bringup(dut):
    """REGRESSION GATE — HW bug discovered 2026-05-24."""
    pair = await setup_wlink_pair(dut)
    await pair.bringup_links_and_calibrate()
    await ClockCycles(dut.clk, 2000)

    m_pcc = await pair.master_apb_read(0x2028)
    s_pcc = await pair.slave_apb_read(0x2028)

    # Both sides must see peer credits after bringup
    assert m_pcc != 0, f"Master PAIR_CREDIT_COUNTER stuck at {m_pcc:#010x}"
    assert s_pcc != 0, f"Slave  PAIR_CREDIT_COUNTER stuck at {s_pcc:#010x}"

@cocotb.test()
async def test_doorbell_crosses_link(dut):
    """REGRESSION GATE — master doorbell must accumulate on slave DOORBELL_RESPONSE_ACC."""
    pair = await setup_wlink_pair(dut)
    await pair.bringup_links_and_calibrate()
    await pair.slave_apb_read(0x2024)  # clear

    for _ in range(8):
        await pair.master_apb_write(0x2014, 0x1)
        await ClockCycles(dut.clk, 50)
    await ClockCycles(dut.clk, 1000)

    acc = await pair.slave_apb_read(0x2024)
    assert acc >= 8, f"slave DOORBELL_RESPONSE_ACC = {acc} (expected ≥ 8)"

@cocotb.test()
async def test_cr_pkt_seen_rx_both_sides(dut):
    """REGRESSION GATE — slave must see master's CR packet (sticky bit)."""
    pair = await setup_wlink_pair(dut)
    await pair.bringup_links_and_calibrate()
    await ClockCycles(dut.clk, 5000)

    m_lane_status = await pair.master_apb_read(0x2108)
    s_lane_status = await pair.slave_apb_read(0x2108)
    assert (m_lane_status >> 23) & 1, f"master cr_pkt_seen_rx = 0; {m_lane_status:#010x}"
    assert (s_lane_status >> 23) & 1, f"slave  cr_pkt_seen_rx = 0; {s_lane_status:#010x}"
```

### §X.2 Makefile target

Add to root `Makefile`:

```makefile
.PHONY: sim-repro
sim-repro:
	@echo "Running TideLink interface sim-repro tests..."
	$(MAKE) -C cocotb/wlink_pair TEST_MODULES=test_paircredit_handshake
	$(MAKE) -C cocotb/wlink_pair TEST_MODULES=test_credit_handshake_end_to_end
	@echo "sim-repro PASS — safe to deploy HW"
```

### §X.3 Mandatory deploy gate

Phase 4 deploy scripts (or a Makefile dependency) gate on `sim-repro`:

```makefile
deploy-tdif: sim-repro
	# only runs if sim-repro PASSED
	...
```

If `sim-repro` PASSES today (i.e., the sim doesn't reproduce the bug despite HW failing), that itself is a critical finding: it means the HW bug is something the sim model doesn't capture. Then the priority is to **modify the sim model** until it reproduces the bug. Candidates (per §4.4 of Phase-0-obs):
- Inject random sub-byte phase between master TX and slave RX clocks at bringup
- Model the `sp2wl` byte-aligner's mod-16 free-running counter starting at a random offset
- Model IDELAYE2 / IBUFG insertion delay variance with a randomized per-lane skew

The sim model must reproduce the HW bug before we trust any sim-passes verdict on a fix.

---

## 7. Phase 5 — Fix integration into mainline

> **Goal**: once a root cause is identified and a clean fix lands in `feat/td-interface-debug`, port it to `main` without the debug instrumentation.

### 7.1 Steps
1. Identify the minimal RTL change that fixes the bug (likely 1-50 lines).
2. Create a clean branch off `main`: `feat/td-interface-fix-<short-desc>`.
3. Cherry-pick *only* the fix commits, not the observability/streamlining.
4. Run all sim regressions: `make -C cocotb test` + UVM smoke tests.
5. Run lint regressions: `make -C cocotb/lint test`.
6. Build a non-debug bitstream and rerun Phase 0 hwtest suite — verify the fix works without the debug crutches.
7. Open PR with full investigation history referenced (Phase 0 obs file, all tdif-NN obs files, ILA captures).
8. Update memory:
   - Update `project_phc_phase1_*` to mark the bug as RESOLVED (or as moved to next layer).
   - Update `project_tidelink_fpga_bringup_state` with the final root cause.
   - Add a `feedback_*` memory if the bug class is reusable knowledge.
9. Update `docs/BUG_TRACKER.md` with the bug number and classification.

### 7.2 Worktree disposition
- Keep `td-interface-debug/` worktree for one week post-fix for regression reference.
- After one week, prune via `cleanup_proposal.md`.

---

## 8. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Streamlining stubs break the link layer accidentally | Medium | Phase 2 (observability-only) build runs first; if it passes lane_lock 16/16, the substrate is proven. Phase 3 stubs only touch modules NOT on the link path. |
| Adding APB registers breaks slave-side address decode (like the parked `feat/phc-rx-counters` branch) | Medium | Use Region 8 (slave-decode known-working per Agent 4's finding); test the new registers on master FIRST, only then expect them to work on slave. |
| Vivado 2025.2 / dbg_hub corruption recurs | Medium | Agent K's `C_CLK_INPUT_FREQ_HZ` auto-derive fix is already in `insert_debug_core.tcl` (per memory `reference_insert_debug_core`). Verify `FPGA_INSERT_DEBUG_CORE=1` is honoured (per handoff §10 guardrail). |
| Build farm contention (srv04936) blocks parallel exploration | Low | Builds serialise gracefully; worst case +45 min wait per build. |
| Lease contention with other developers | Low | bridge1 lease is exclusive; the `granted` vs `queued` check (per memory `feedback_lease_grant_before_deploy`) handles this. |
| AHB_TX wedge during test 03 | **HIGH if mishandled** | `03_ahb_sub_e2e.sh` uses AHB SUB aperture (0x4401_0000), NOT AHB_TX (0x4400_0000). DO NOT WRITE 0x4400_0000 per handoff §10 guardrail #1. If a board wedges, recover via power cycle (operator needed). |
| The bug is genuinely an FPGA vendor issue (Vivado 2025.2 bug) | Low | If Phase 4 exhausts P1/P2/P3 without resolution, escalate to a Xilinx case with the minimal failing example. |
| Time sink: this plan takes >5 days | Medium | Budget = 3-4 builds/day × 3 days = 9-12 builds. If we exceed 12 builds without convergence, escalate to architecture review (per handoff §8 step 5). |

---

## 9. Critical guardrails (inherited from handoff §10)

1. **DO NOT WRITE TO `0x4400_0000` (AHB_TX)** — wedge hazard, requires power cycle to recover.
2. **DO NOT bump the submodule** beyond `8a4fcf5` (b22 ILA SHA).
3. **DO NOT use `boot_hw_device`** in xsdb/Vivado — wipes DONE bit, requires redeploy.
4. **DO NOT skip `FPGA_INSERT_DEBUG_CORE=1`** for any debug build.
5. **DO NOT trust `wait_on_hw_ila -timeout`** under Vivado 2025.2 — use STATUS polling (already in `phc_ila_capture.tcl`).
6. **DO use `bash --noprofile --norc -c '...'`** for ssh-to-mapstone-dev wrapped commands.
7. **DO acquire lease via `fpgahub pair lease acquire bridge1 --ttl 5400`** before deploying; verify "granted" state, not "queued".
8. **NEW: DO NOT TOUCH the b25-rx-accept-reg worktree** or its branch. That's the parallel PHC track; this plan operates strictly in `td-interface-debug/`.

---

## 10. Exit criteria (the plan is "done" when)

One of the following:

- **A**. AHB SUB e2e test (`03_ahb_sub_e2e.sh`) passes reliably (≥99% of deploys) on a stripped-down non-debug bitstream built from `main + fix`. The fix has been cherry-picked into mainline. Memory + BUG_TRACKER updated.
- **B**. Phase 4 has run 6+ builds covering P1/P2/P3 hypothesis classes and the bug is *not* reproduced in the streamlined+debug bitstream. We then know the bug is something specific to the un-streamlined mainline (modulo flip-bitstream) and the path forward is bisecting which stub re-introduces it.
- **C**. We have collected enough physical-layer evidence (per-lane IDELAY tap values, oscilloscope traces on slave's `pad_clk_rx` / `pad_rx[n]`, post-route timing reports) to file a Xilinx case with high signal-to-noise.

Failure mode (none of A/B/C after 12 builds): escalate to architecture review with the user; do NOT keep iterating beyond budget.

---

## 11. File paths and resources

| Path | Purpose |
|---|---|
| `/home/dam1n19/SoCLabs/td-bisect/td-interface-debug/` | The new worktree (post-approval) |
| `src/rtl/tidelink_phy_align_regs.sv` | Phase 2 new APB registers |
| `src/rtl/tidelink_phy_align_calibrator.sv` | Phase 2 IDELAY tap snapshot |
| `src/rtl/tidelink_top.sv` | Phase 3 generate-block stubs |
| `imp/fpga/tidelink_ip/component.xml` | Phase 3 param threading |
| `fpga/insert_debug_core.tcl` | Phase 2 TCL mark_debug additions |
| `pynq_host/scripts/hwtest/01_wlink_layer.sh` | Phase 0 link health check |
| `pynq_host/scripts/hwtest/03_ahb_sub_e2e.sh` | Phase 0 AHB end-to-end test (CRITICAL) |
| `pynq_host/scripts/tidelink_obs_dump.sh` | Phase 2 new — full register dump |
| `pynq_host/scripts/phc_ila_capture.{sh,tcl}` | Reuse — ILA capture pipeline |
| `pynq_host/scripts/_ptp_common.sh` | Reuse — APB helpers |
| `docs/PHC_PHASE1_OBSERVABILITY_MAP.md` | Reference — register offsets |
| `docs/SIM_HW_GAP_ANALYSIS.md` | Reference — hypothesis basis |
| `docs/BUG_TRACKER.md` | Phase 5 — record outcome |

---

## 12. TL;DR (REVISED post-Phase-0)

**Phase 0 done**. Root cause: **the slave's link-layer FCSM never receives master's CR packet → credit window never opens → ALL application-layer traffic (PTP, doorbell, AHB SUB peer-write) silently fails.** The PHC fixes b18-b25 were chasing a downstream symptom.

**Now:**

1. **Phase 1 done** — worktree `/home/dam1n19/SoCLabs/td-bisect/td-interface-debug/` exists on `feat/td-interface-debug`.
2. **NEW: Sim-repro first** — write `cocotb/wlink_pair/test_paircredit_handshake.py` asserting PAIR_CREDIT_COUNTER ≠ 0 + doorbell crosses + cr_pkt_seen_rx=1 on both sides. If sim PASSES while HW FAILS, modify sim model until it reproduces (sub-byte phase, byte-aligner counter mod-16 start, IDELAYE2 variance).
3. **Phase 2 (revised)**: Add FCSM observability registers (FCSM_STATE, CR_CRACK_COUNTS, FCSM_STICKY, CMD_FCSM_RETRY). May require submodule bump for Wlink FCSM signal exposure.
4. **Phase 3**: Streamline RTL — STUB_SERVO=1, STUB_PERF=1, STUB_PTP=1 (confirmed by Phase 0). STUB_ADDR_XLAT optional.
5. **Phase 4 (revised, max 12 builds)**: Iterate tdif-02 (baseline) → tdif-03 (FCSM re-init pulse) → tdif-04 (sp2wl byte-aligner sticky-lock) → tdif-05 (CRACK self-heal probe) → tdif-06 (master CR retransmit fallback). One variable per build, sim-repro must pass first.
6. **Phase 5**: Cherry-pick the minimal fix into mainline.

Wall-time budget: **3 days** with 3-4 builds/day. Exit if not converged by day 4.

---

## 13. Phase 0 progress log (live)

| Time UTC | Action | Outcome |
|---|---|---|
| 21:01 | Lease verify (bridge1) | Held by srv03335 until 21:30:58Z, 29 min remaining |
| 21:02 | Verify b24 deployed via SWI_LANE_STATUS reads | M=0xa500ff S=0x2300ff → 8/8 lanes both sides |
| 21:03 | Run `hwtest/01_wlink_layer.sh` | PHY/ECC clean both sides; 1f mask test failed (separate concern, noted) |
| 21:04 | Run `hwtest/03_ahb_sub_e2e.sh §3a` | Local r/w on master PASS |
| 21:05 | Manual 3d peer-visibility test (both directions) | **FAIL both directions** |
| 21:06 | Full observability sweep (8 registers) | FC_TIDELINK_CRC=0, EnableReset=0x27f07, STATUS[2]=fifo_underrun sticky |
| 21:07 | Deploy 4 parallel diagnosis agents | Reports compiled |
| 21:11 | Doorbell peer test + PAIR_CREDIT_COUNTER read | **Both sides PAIR_CREDIT=0; doorbell does not cross** |
| 21:12 | Decode SWI_LANE_STATUS bit 23 (cr_pkt_seen_rx) | **slave cr_pkt_seen_rx = 0** → root cause class identified |
| 21:13 | Release lease cleanly | Verified free, no orphans |
| 21:13+ | Plan v2 revision (this doc) + Phase 0 obs doc finalized | Next: implement sim-repro and Phase 2 RTL |

