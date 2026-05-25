# TideLink Interface Debug — Phase 0 Observations

**Date**: 2026-05-24 21:09 UTC
**Bitstream deployed**: b24-rx-decouple (commit c6c56c2, build_date 2026-05-24T20:00Z)
- `tidelink.bin` sha256: `99a39abbd92a91dda3f8fd823e857f887dff123f5a61bfea426a6e3ac1e62917`
- `tidelink-flip.bin` sha256: `62658ea18860065ff89277f7d3eb01cd215a078ad8cbf6f650226914710f1213`
- Lease: bridge1 held by srv03335 until 21:30:58Z (verified granted)
- Master = z2_02 (192.168.4.101), Slave = z2_03 (192.168.6.101)
- Plan: [TIDELINK_INTERFACE_DEBUG_PLAN.md](TIDELINK_INTERFACE_DEBUG_PLAN.md) §2

---

## Headline result

**The TideLink interconnect does NOT transport application-layer data across the ribbon in either direction.** The PTP failure documented in [PHC_PHASE1_HANDOFF.md](PHC_PHASE1_HANDOFF.md) is a downstream symptom, not the bug.

Per the plan's §2.2 decision gate, this triggers the path: *"FAIL → Proceed to Phase 1 with PTP **stubbed out entirely**; treat the bug as a base-link bug."*

---

## 1. Link-layer health (PASS — all green)

`pynq_host/scripts/hwtest/01_wlink_layer.sh` output (truncated at the spurious 1f mask-test that wasn't relevant here):

| Probe | Master | Slave | Verdict |
|---|---|---|---|
| `PHY_ALIGN_ID @ 0x44032100` | `0x50410100` | `0x50410100` | PASS — IP identification OK both sides |
| `SWI_LANE_STATUS @ 0x44032108` | `0x00a500ff` | `0x002300ff` | PASS — 8/8 lanes locked, cal_done=1, fault=0x00 both sides |
| FC header sanity (all 7 channels) | responds | responds | PASS |
| `ECC_COUNTERS @ 0x44032114` | `0x00000000` | `0x00000000` | **PASS — zero corrected, zero corrupted on BOTH sides** |
| `FC_TIDELINK_CRC_Errors @ 0x44031720` | `0x00000000` | `0x00000000` | **PASS — never read before by any script; both clean** |
| `LinkStatus @ 0x44030234` | `0x00000018` | `0x00000018` | `bit[4]=rx_data_valid=1`, `bit[2]=in_error_state=0` — both clean |
| `LinkInterrupts @ 0x44030240` | `0x00020002` | `0x00020002` | bits[17:16] = ECC-event flags; both sides identical, no anomaly |
| `EnableReset @ 0x44030208` | `0x00027f07` | `0x00027f07` | LLRX/LLTX/SWI all enabled, both sides |
| `CREDIT_COUNT @ 0x4403200C` | `0x00001000` | `0x00001000` | 4096 credits available, both sides |

**Implication**: by every link-layer-and-below metric, the ribbon, the PHY, the calibrator, the Wlink frame layer, and the FC node layer are healthy. There are no byte-level bit errors. No FC-layer CRC corruption. **This conclusively rules out hypothesis P1 (P&R skew on master→slave RX fan-out).**

---

## 2. Peer-visibility test (FAIL — bidirectional)

Direct invocation of the same code path as `03_ahb_sub_e2e.sh §3d`, with explicit reads before / after / on both sides:

| Direction | Address | Pattern written | Master read | Slave read | Verdict |
|---|---|---|---|---|---|
| **Master → Slave** | `0x44010000` | `0xDEADBEEF` | `0xdeadbeef` ✓ | `0x00000000` ✗ | FAIL |
| **Master → Slave** | `0x44010100` | `0xCAFEBABE` | `0xcafebabe` ✓ | `0x00000000` ✗ | FAIL |
| **Slave → Master** | `0x44010200` | `0x12345678` | `0x00000000` ✗ | `0x12345678` ✓ | FAIL |

The local-side reads always return the written value (the write is committed locally), but the peer-side read always returns zero. **The same address space is not seen as coherent across the link** — and the bug is **symmetric** (both directions affected, ruling out flip-bitstream-only or master-only or slave-only hypotheses).

> **Note on safety**: No board wedged. Local reads continued to work. AHB SUB (0x4401_0000) is by design HREADY-locally-returned even with link down; this is what the §10 handoff guardrail #1 is preserving by routing the AHB_TX wedge hazard through a different aperture (0x4400_0000). All Phase 0 testing avoided AHB_TX.

---

## 3. PTP-layer observations (collateral, NOT the focus)

| Register | Master | Slave | Notes |
|---|---|---|---|
| `HW_SYNC_STATUS @ 0x44032048` | `0x00037319` (advancing, seq# ≈ 56518) | `0x00000000` (stuck) | Master HW_SYNC FSM healthy; slave never receives — consistent with peer-write failure above |
| `PTP_CTRL @ 0x44032034` | `0x00000001` (enable=1, rx_valid=0) | `0x00000001` (enable=1, rx_valid=0) | Both APB readback OK; slave bit[2] never sets — the handoff's primary symptom |
| `TideLink STATUS @ 0x44032010` | `0x00000004` | `0x00000004` | `bit[2] = fifo_underrun` sticky — set on BOTH sides since last reset. Notable: no fifo_overrun, no master_error. |

**Reading the STATUS = 0x4 on both**: someone attempted a FIFO read with the FIFO empty. This could be a benign startup transient (the AHB returner sees an empty FIFO at boot) or could be evidence that the slave's RX FIFO write never lands, so the consumer reads underrun. **Worth investigating in Phase 4** when we have the new observability registers.

---

## 4. What this changes

### 4.1 Second-pass evidence (post-21:11 supplementary tests)

Per user instruction "deploy multiple agents in the diagnosis", four parallel exploration agents were spawned (RTL data-path trace / sim-repro design / address-translator audit / paired sim infrastructure). The agents flagged a likely test-expectation mismatch on the AHB SUB peer-read interpretation, so two **additional independent tests** were run:

#### Test 2 — Doorbell peer-visibility
- Master writes 8× to `DOORBELL @ 0x44032014`, slave's `DOORBELL_RESPONSE_ACC @ 0x44032024` polled.
  - Expected: `~8`.
  - **Actual: `0x00000000`**.
- Slave writes 8× to its DOORBELL, master's DOORBELL_RESPONSE_ACC polled.
  - Expected: `~8`.
  - **Actual: `0x00000000`**.

#### Test 3 — Pair-credit accounting
- `PAIR_CREDIT_COUNTER @ 0x44032028` on master = `0x00000000`.
- `PAIR_CREDIT_COUNTER @ 0x44032028` on slave = `0x00000000`.
- Per REGISTER_MAP §Region 1: "Running count of available credits on paired side. Incremented by writes to RELEASED_CREDITS_ACC". **Both sides report ZERO peer credits.**

#### Test 4 — cr_pkt_seen_rx
- Master `SWI_LANE_STATUS = 0x00a500ff`: bit[23] = 1 → master **HAS** seen slave's CR packet.
- Slave `SWI_LANE_STATUS = 0x002300ff`: bit[23] = 0 → slave **HAS NEVER** seen master's CR packet (sticky bit, since reset).

### 4.2 Root-cause family identified

Three independent symptoms — peer-AHB-write fail, doorbell fail, PHC SYNC fail — collapse to a single root cause:

**The slave's link-layer Flow-Control State Machine (FCSM) never receives the master's initial Credit-Release (CR) packet, so no credits are exchanged at the application layer, so no application traffic ever leaves the master's TX queue (or arrives at slave's RX demux).**

The "16/16 lane lock + cal_done + ECC=0" telemetry is correct but only describes the **PHY layer**. The application layer never advances out of credit-init.

This is consistent with the handoff §3 row **F** ("CR/CRACK directional asymmetry") but **contradicts the conclusion there.** Agent F asserted FCSM "self-heals via CRACK path"; the live empirical state shows PAIR_CREDIT_COUNTER=0 on both sides, which it would NOT be if the system had self-healed.

**Row F should be re-opened as a PRIMARY hypothesis.**

### 4.3 Hypothesis ranking update

| # | Hypothesis | Pre-Phase 0 | Post-Phase 0 |
|---|---|---|---|
| **P1** | Vivado P&R routes per-lane `pad_rx[n]` skew past calibrator window; byte-level errors | LIVE | **RULED OUT** — ECC=0/0, FC-CRC=0/0 |
| **P2** | Recovered-RX-clock reset race; slave-side FIFO write-pointer X-state | LIVE | DOWNGRADED — would not produce a SYMMETRIC fail with both sides PAIR_CREDIT=0; clock-race normally breaks one direction only |
| **P3** | Synth consumer-replica divergence in PTP cone (b25 target) | LIVE | **RULED OUT** — PTP is a symptom; bug is in the link credit/FCSM layer above PHY but below PTP |
| **★ P-FCSM** | **Slave FCSM never receives master's CR; credit window never opens; ALL application traffic blocked** | n/a | **PRIMARY (95%)** |
| Alt-1 | Master sends CR but slave's `sp2wl` byte aligner doesn't decode it AND the CRACK self-heal path is also broken | n/a | Open (would explain the cr_pkt_seen_rx=0 sticky) |
| Alt-2 | The PHY layer reports 8/8 locked but the actual recovered clock is wrong-phase such that frame headers are misclassified at the FCSM | n/a | Open (compatible with ECC=0 if frame headers happen to pass parity but get dropped) |
| Alt-3 | Master's TX FCSM never SENDS a CR despite link state showing FCSM advanced (sticky on master side might be coincidental) | n/a | Open — would need TX-side counters |

### 4.4 Why this didn't show in sim

The cocotb `wlink_pair/test_credit_handshake_end_to_end.py` exists and reportedly passes. The gap that hides this on HW:
- Sim brings both sides up perfectly synchronous; HW has arbitrary phase between master TX clock and slave recovered RX clock at link-up time.
- Sim's GPIO PHY is a perfect crossover; HW has IDELAYE2 / BUFG / IBUFG insertion delays unique to flip-bitstream.
- Sim's `sp2wl` byte aligner doesn't model the boot-race window where slave's `count` counter is mod-16 and starts wherever role_lock fires.
- **No sim test currently asserts `PAIR_CREDIT_COUNTER != 0` after bringup as a regression gate.** Reproducing the HW finding in sim is now a Plan-blocking item (per user instruction: "build this into any future testing loop").

### 4.5 Plan amendments

Per plan §2.2 decision gate, this is the **FAIL path**:
> Proceed to Phase 1 with PTP **stubbed out entirely**; treat the bug as a base-link bug.

The plan's Phase 3 already lists `STUB_PTP=1` as conditional on the Phase 0 outcome (§5.1). Phase 0 confirms it. Phase 3 will set `STUB_PTP=1` by default in the debug bitstream.

Plan revisions following the FCSM-credit finding:

**Phase 2 observability priorities (REVISED)** — the bug is at the FCSM/credit layer, not the FC demux or FIFO layer. Therefore:

1. **`FCSM_STATE_M` and `FCSM_STATE_S`** — both directions of the slave's FCSM exposed via APB. Currently only encoded in 2 bits of `SWI_LANE_STATUS`; add a full live snapshot. **HIGHEST PRIORITY.**
2. **CR_RX_COUNT / CRACK_RX_COUNT / CR_TX_COUNT / CRACK_TX_COUNT** — counters of credit-release & credit-release-ack packets seen and sent. Closes the "did the CR cross? did the CRACK come back?" question definitively.
3. **`fe_tx_credit_max_loaded` sticky bit** — per Agent F audit, `fe_tx_credit_max` loads on either `pkt_is_cr` OR `pkt_is_crack`. A sticky bit here proves whether the per-direction credit-max was EVER loaded.
4. **Per-lane IDELAY taps**, **RX_CLOCK_LIVENESS**, **non-PTP RX counters** — keep but move to LOWER priority.

**Phase 4 test matrix (REVISED)**:
- tdif-03 — Instrument FCSM with the counters above; verify on HW which packets are seen/sent.
- tdif-04 — Force a CR/CRACK retry / re-init from APB after lane_lock (need new RTL hook + APB register) — test whether the slave's FCSM can recover if poked.
- tdif-05 — If CR is never decoded on slave despite master sending: instrument `sp2wl` byte aligner internals; the bug is at the bit-to-byte boundary.

### 4.6 Sim-regression requirement (user instruction)

Per the user's explicit ask "Please build this in to any future testing loop":

Mandatory new cocotb test in `cocotb/wlink_pair/test_credit_handshake_end_to_end.py` (or new sibling):

```python
@cocotb.test()
async def test_paircredit_nonzero_after_bringup(dut):
    """Post-bringup, PAIR_CREDIT_COUNTER must be non-zero on both sides.

    Regression gate for the HW bug discovered 2026-05-24 where lane_lock 8/8
    and ECC=0 still left PAIR_CREDIT_COUNTER=0 on both sides — i.e. the FCSM
    never opened the credit window.
    """
    pair = await setup_wlink_pair(dut)
    await pair.bringup_links_and_calibrate()
    await ClockCycles(dut.clk, 2000)  # wait for FCSM to converge

    m_pcc = await pair.master_apb_read(0x2028)
    s_pcc = await pair.slave_apb_read(0x2028)
    assert m_pcc != 0, f"Master PAIR_CREDIT_COUNTER stuck at {m_pcc:#010x}"
    assert s_pcc != 0, f"Slave  PAIR_CREDIT_COUNTER stuck at {s_pcc:#010x}"
```

This test goes into the standard `make sim-repro` target and runs **before every HW deploy** in Phase 4 iterations. If a future RTL change breaks PAIR_CREDIT_COUNTER in sim, it's caught before wasting a 45-min farm cycle. **No HW deploy of any tdif-NN bitstream proceeds without `make sim-repro` passing first.**

---

## 5. Phase 1 status

- Worktree created: `/home/dam1n19/SoCLabs/td-bisect/td-interface-debug/`
- Branch: `feat/td-interface-debug` off `main @ f6a7d19`
- Submodule will be pinned to `8a4fcf5` (b22 ILA SHA) in next step.

---

## 6. Next steps (in order)

1. **Update plan §6.1** (Phase 4 test matrix) to reflect the new P4/P5 primary hypotheses.
2. **Pin submodule** in worktree to `8a4fcf5`.
3. **Phase 2**: add observability registers (priority order revised above) + TCL mark_debug.
4. **Phase 3**: streamline RTL with `STUB_PTP=1` default, `STUB_SERVO=1`, `STUB_PERF=1`.
5. **tdif-01 build** with FPGA_INSERT_DEBUG_CORE=1 on farm.
6. **Re-run Phase 0 sweep** on tdif-01 bitstream → expect identical fail (proves debug instrumentation didn't accidentally fix it) + new observability data identifying which layer drops the write.

---

## 7. Memory updates required

- Update `project_tidelink_fpga_bringup` — link layer 8/8 is preserved, but application-layer transport is NEW broken (separate bug class from any documented to date).
- Create new memory: `project_tidelink_interface_bug_2026_05_24.md` — pin this finding for future agents.
- Update `project_phc_phase1_hw_diagnosis_2026_05_24` — note that PHC fix path is paused; root cause is upstream.

---

**End Phase 0.**

---

## 8. Phase 0 follow-up test (2026-05-24 22:30 UTC) — training-mode-release HW test

User asked the decisive question: "Does the lanes actually lock? Does the link-layer leave training mode?"

The RTL evidence (citations in §6 above) showed that `swi_training_mode_r` SW-override is OR-muxed into Wlink's `swi_training_mode_in`, and `bringup_pair_converge.sh:170` settles slot0=0x1 (training=1) and never writes slot0=0x0. The companion script `sw_coord_autocal_region8.sh:65 to_data_mode()` has the missing step but is not called by anything else.

### Test executed
1. Acquired bridge1 lease.
2. Captured pre-test state: **slot0 = 0x00000003 on BOTH sides** (training=1, recal=1 — even more stuck than the expected 0x1).
3. Ran the proper sequence: re-recal (0x3 → 0x1) to lock lanes; then slot0=0x0 + LL swreset bootstrap on both sides (the `to_data_mode()` sequence).
4. Re-read all critical registers + doorbell-cross test.

### Result — partial validation

| Signal | Pre-test | Post-test | Interpretation |
|---|---|---|---|
| `slot0 @ 0x44032100` | `0x3` both sides | `0x0` both sides | Training released ✓ |
| Slave `SWI_LANE_STATUS[23]` `cr_pkt_seen_rx` (sticky) | **0** | **1** | **Slave finally saw master's CR packet — was stuck at 0 for the entire 7-day debug.** |
| Master `cr_pkt_seen_rx` | 1 (unchanged) | 1 | (was already 1 — slave→master CR worked even with training stuck) |
| Slave `crack_pkt_seen_rx` (bit 24) | 0 | **1** | Slave saw master's CRACK |
| Master `crack_pkt_seen_rx` | 0 | **1** | Master saw slave's CRACK |
| `PAIR_CREDIT_COUNTER @ 0x44032028` | 0 both | 0 both | Did NOT advance (no credit-release traffic since handshake) |
| Doorbell crosses (master→slave, slave→master) | No | No | Doorbell traffic still does not propagate |
| `lane_locked[7:0]` (lower byte) | 0xff both | **0x00** both | Lanes "unlocked" because training pattern stopped — `lane_checker` correctly drops lock when training ends. **By design.** Not necessarily a problem. |
| `STATUS @ 0x44032010` | `0x05` (RETURNER_BUSY + UNDERRUN sticky) | `0x04` (UNDERRUN only) | Returner-busy cleared; underrun sticky persists |

### What we learned

**Confirmed at the credit-handshake layer**: the original Phase 0 finding of `cr_pkt_seen_rx=0` on slave was caused by `swi_training_mode` being held HIGH. Releasing it (slot0=0x0 + LL swreset bootstrap) flips this bit. The 7-day PHC fix work (b18-b25) was chasing a downstream symptom of training-mode-stuck.

**NOT yet resolved at the data-traffic layer**: even with credit handshake provably complete (CR + CRACK both latched on BOTH sides), `PAIR_CREDIT_COUNTER` stays at 0 and doorbells do not cross. Candidates for the residual:

- **Per-FC-node handshake**: there are 7 FCSMs per side (tidelink/generalbus/axi-aw/w/b/ar/r/ptp). The `cr_pkt_seen_rx` we read is for ONE channel (likely TideLink data_id). The doorbell may use a DIFFERENT FC channel whose CR/CRACK didn't complete.
- **Lane_checker as data gate**: when training ended, `lane_locked → 0`. If any data-path gate uses `lane_locked` for validation (it shouldn't — lane_checker is observability-only — but worth verifying), traffic would be blocked.
- **Sticky UNDERRUN cleanup**: `STATUS[2]=UNDERRUN` is still set; FLUSH (`CTRL[1]`) might be needed to clear it before fresh traffic can flow.
- **A second config write needed**: the `to_data_mode` sequence may need an additional bit set in a register we haven't surfaced yet to enable the doorbell-specific path.

### Updated hypothesis table

| # | Hypothesis | Status after 22:30 test |
|---|---|---|
| P1 | P&R skew on RX | RULED OUT (ECC=0) |
| P2 | CDC race | RULED OUT (cr_pkt_seen latched once training released) |
| P3 | Synth replication in PTP | RULED OUT (PTP is downstream of credit handshake) |
| P-FCSM (was PRIMARY) | FCSM credit handshake never opens | **PARTIALLY RESOLVED** — handshake completes on ONE channel after training released; need per-channel investigation |
| **★ P-NEW** | **Doorbell + AHB SUB FC path requires per-channel CR/CRACK that's NOT yet covered by the slot0=0x0 + LL swreset sequence** | **PRIMARY** |

### Next-session action plan (no RTL bake required)

1. Re-acquire lease.
2. Re-deploy b24 cleanly.
3. Run the full `sw_coord_autocal_region8.sh` script as-is (proven flow).
4. Wait LONGER (≥5s) after to_data_mode for all 7 FCSMs to complete their handshakes.
5. Check per-channel FC RX counters: read `WL_FC_TIDELK_BASE + 0x10 = 0x44031710` (AckNack_FIFO TideLink), and equivalents for all 7 channels. If most read non-zero, they're handshaking; the one(s) stuck at 0 are the broken channels.
6. If only TideLink-data_id channel is broken: pinpointed RTL bug. If multiple channels stuck: deeper FCSM issue.

### Plan amendment

- The original "FCSM credit handshake never completes" hypothesis was correct but incomplete.
- The real bug is **multi-layer**: training-mode-stuck (Layer 1, NOW RESOLVED via known sequence) AND some additional gate at the per-FC-channel level (Layer 2, NEW PRIMARY).
- Phase 2 RTL observability work in worktree (FCSM bind + counters per channel) is now MORE valuable — it's exactly what's needed to isolate Layer 2.
- The user guide at `docs/TIDELINK_BRINGUP_USER_GUIDE.md` now documents the training-release step as Pitfall #1 so future bringups don't repeat this mistake.

---

## 9. Phase 0 follow-up #2 (2026-05-25) — SMOKING GUN identified in `to_data_mode()`

After dispatching four parallel investigation agents and one paired-cocotb implementation agent, the root cause is now precisely localised. The training-mode release step is necessary but **the script's swreset sequence is itself the bug** that prevents recovery.

### The bug

`pynq_host/scripts/sw_coord_autocal_region8.sh:79-83`:
```python
struct.pack_into("<I", w, wo+0x208, 0x00027f08)  # LL swreset on   ← swi_enable=0 here
struct.pack_into("<I", w, wo+0x208, 0x00027f00)  # LL swreset off  ← swi_enable=0 still
struct.pack_into("<I", w, wo+0x208, 0x00027f07)  # swi+lltx_en+lltx_en_1
```

Bit layout of `0x44030208[3:0]`:
- bit[0] `swi_enable`
- bit[1] `lltx_en`
- bit[2] `lltx_en_1`
- bit[3] `swreset`

The first two writes drop `swi_enable` to 0. Per `wav-wlink-hw/src/main/scala/FC.scala:619-621`:
```scala
when(~en_ff2_tx){
  nstate := WlinkGenericFCState.IDLE
}
```
**When `swi_enable=0`, ALL 7 FCSMs hard-reset to IDLE.** Not pause; not hold. **Reset to state 0.** Also per FC.scala:185-208, the sticky bits `cr_pkt_seen_rx` and `crack_pkt_seen_rx` are likewise cleared when `swi_enable=0`.

5 ms × 2 of `swi_enable=0` = 10 ms / 250k cycles at 25 MHz. Plenty of time for both sides' FCSMs to fully reset.

When `swi_enable` returns to 1 (0x27f07 write), both sides' FCSMs must restart the handshake from IDLE → SEND_CREDITS1 → ... → LINK_DATA from scratch — a **race-prone** sequence where both sides are sending CR packets simultaneously to a peer that may not yet have its receivers enabled.

### Why this explains every Phase-0 observation

| Observation | Old explanation | Now |
|---|---|---|
| `cr_pkt_seen_rx`=1 + `crack_pkt_seen_rx`=1 both sides | "Credit handshake completed" | "Sticky bits re-latched AFTER the 0x27f07 write — they did NOT survive the swi_enable=0 window. So sticky readings prove a CR/CRACK exchange happened SOMETIME after recovery, but don't prove the current FCSM state is LINK_DATA." |
| `PAIR_CREDIT_COUNTER`=0 | "Credit refresh blocked" | "Peer's FCSM may not have reached LINK_DATA — no application traffic, no credit-release packets, counter stays at initial 0." |
| Doorbell doesn't cross | "Unknown second-layer issue" | "FCSM not in LINK_DATA → doorbell SIDEBAND packet enters the link layer but the destination FC node either drops it (FCSM still in IDLE/SEND_CREDITS) or never reaches the consumer." |
| Slave `SWI_LANE_STATUS = 0x01890000`, master `0x23890000` | (couldn't decode FCSM state) | Per Agent 5's decode of FCSM state bits within Region 8 slot 2, the two sides are at different states — desynchronised recovery from the swi_enable=0 reset. Decoding has some ambiguity on exact bit range; either both at LINK_IDLE (state 4) one step short of LINK_DATA, OR master at SEND_CREDITS1 (1) and slave at IDLE (0). Either way, **NOT in LINK_DATA**, which is why the doorbell can't cross. |

### Proposed fix (one-line change in `sw_coord_autocal_region8.sh`)

Change the to_data_mode swreset cycle from:
```python
0x00027f08 → 0x00027f00 → 0x00027f07
```
to one of:

**Option A (keep swi_enable=1 through swreset; preferred — minimal change)**:
```python
0x00027f09 → 0x00027f01 → 0x00027f07
# bit3=swreset, bit0=swi_enable held high throughout
```

**Option B (full symmetry: hold swreset asserted with all enables on, then release)**:
```python
0x00027f0F → 0x00027f07
# swi+lltx+lltx_1+swreset all on, then swreset off
```

**Option A** is the minimal patch. The link layer's swreset should NOT need to take swi_enable down with it — the swreset is for clearing internal FIFO state, not for resetting the FCSM. (Note: the original script was written with a different assumption about what swreset does; this hypothesis needs an RTL check on what swreset actually clears, but Option A is safer than Option B because it doesn't put swi+swreset in a state simultaneous with sweeping in CR packets.)

### Next-session HW test plan

1. Re-acquire bridge1 lease.
2. Re-deploy b24 (clean state).
3. Run `bringup_pair_converge.sh` to lock lanes.
4. Try **Option A**: write the corrected sequence `0x00027f09 → 0x00027f01 → 0x00027f07`.
5. Verify FCSM state via SWI_LANE_STATUS (need to confirm exact bit range — Agent 5's decode has ambiguity).
6. Read PAIR_CREDIT_COUNTER and ring doorbell.
7. If Option A still fails, try Option B.
8. If both fail, the fix is deeper than the script — return to RTL inspection (per-channel FCSM observability from tdif-01 bitstream, which is already implemented in worktree and ready to build).

### Sim status

A paired-`tidelink_top` cocotb test was implemented (`cocotb/tidelink_top_pair/{tb_top.sv, test_tidelink_pair_doorbell.py, Makefile}`) by Agent 6. The TB compiles and elaborates clean in VCS, runs cocotb, but **blocks at role_lock** because `tidelink_top` uses autoneg internally, and autoneg requires APB writes to `NEGO_CFG @ 0x0214 bit[0]=nego_en` to advance out of `ST_BYPASS` state. The standard wlink_pair tests use a `ctrl_reg_*` direct path that `tidelink_top` doesn't expose externally.

**Next sim iteration** (1-line fix): add `await apb_write(dut, 'm', 0x0214, 0x01)` and same for slave inside `do_role_lock()` BEFORE the role-status poll. Then re-run; if `test_05_doorbell_crosses` fails in sim, we have a sim repro of the HW bug. If it passes in sim but fails on HW, the bug is FPGA-specific (timing / clock / IDELAY).

### Memory + docs to update

- This obs doc (done)
- `project_tidelink_interface_fcsm_bug_2026_05_24.md` memory — refine to point at the swi_enable=0 transient as the actual root cause class
- `docs/TIDELINK_BRINGUP_USER_GUIDE.md` Pitfall #1 — note the script bug + the corrected sequence
- `pynq_host/scripts/sw_coord_autocal_region8.sh` — apply the actual one-line fix after HW validation

---

## 10. Phase 0 follow-up #3 (2026-05-25 morning) — swi_enable hypothesis FALSIFIED on HW; new chicken-and-egg diagnosis

Two HW test agents ran on b24 this morning. Both released the lease cleanly. **Decisive results**:

### Test 1 (a3968389021e591ce): FIX script applied
- Applied `sw_coord_autocal_region8_FIX.sh` (corrected to_data_mode with `0x27f09→0x27f01→0x27f07`)
- **POST-FIX**: SWI_LANE_STATUS = `0x00030000` on both sides → `lane_locked=0x00` (lanes UNLOCKED)
- PAIR_CREDIT_COUNTER = 0 still; doorbells don't cross; AHB SUB peer-write doesn't cross
- **Identical outcome to running the ORIGINAL buggy script.** The swi_enable=0 transient is NOT the bug.

### Test 2 (a6792e2366127aee7): doorbell during training + 30s monitoring
- After standard `bringup_pair_converge.sh` (16/16 lanes locked, slot0=0x1 training held)
- **Test A** (doorbell during training held): master rings 8 doorbells → slave `DOORBELL_RESP_ACC = 0x0` unchanged. **FC TX is gated while training_mode=1.**
- **Test B** (30 sec monitoring, training held): All 10 samples byte-identical. cr_pkt_seen sticky never toggles further. **FCSM is parked the entire training-held window.**
- **Test C** (AHB SUB peer-write during training held): slave reads `0x00000000`. Same gate.
- **Test D** (50ms training drop + restore): MID-DROP shows `s_lane = 0x2a850000` — bit[29] `llrx_valid=1` and bit[27] `pkt_is_cr_pkt=1` set transiently. **A cr_pkt DID briefly fly during the drop window** — but the link breaks before handshake completes. POST-RESTORE: FCSM did NOT advance, PCC=0, doorbell-ACC=0.

### The ACTUAL bug class

**Chicken-and-egg between training pattern and FC TX:**
- TX is muxed to training pattern while `swi_training_mode=1` — FC packets cannot leave the wire
- training_mode=0 makes `lane_locked` drop (lane_checker mismatch), and (more importantly) the LL_RX byte aligner loses its alignment maintenance signal
- During the brief training-drop transient, ONE cr_pkt sometimes makes it through (Test D evidence), but the link doesn't stay alive long enough for the full CR/CRACK exchange + LINK_DATA transition.

### Why `cr_pkt_seen_rx=1` was observed earlier

The slave's sticky `cr_pkt_seen_rx=1` (bit 23 of SWI_LANE_STATUS at `0x002300ff` → wait actually `0x00a500ff` for slave per Test 2 baseline) was set **during `bringup_pair_converge.sh`'s recal_cycle transient** (when slot0 momentarily goes 0x3 → 0x1, briefly dropping training_mode), not in steady-state held. Whatever ONE cr_pkt event happened, happened during converge's brief window — same mechanism as Test D's 50ms transient.

### The fix is RTL-level, not SW

The fix surface is NOT in `to_data_mode()` SW sequence (which we patched) — it's in the RTL gating between training_mode and FC TX. Candidate options being investigated by agent a4e32fca99a05d64c:

- **Option A (multiplex)**: interleave training pattern with FC data during transition.
- **Option B (idle pattern)**: emit a known idle pattern after training, before first FC packet, to maintain LL_RX alignment.
- **Option C (asymmetric drop)**: slave holds training while master drops; sequence the drops.
- **Option D (FCSM bypass)**: allow doorbells/AHB to flow even when FCSM is not in LINK_DATA. Risky.
- **Option E (continuous cr_pkt)**: master fires cr_pkt back-to-back until CRACK arrives.
- **Option F (wait-hold)**: master holds a known pattern post-training-drop until handshake completes.

### Hypothesis tracker (corrected)

| # | Hypothesis | Status |
|---|---|---|
| P-swi_enable | swi_enable=0 transient in to_data_mode resets FCSMs | **FALSIFIED on HW (2026-05-25)** |
| P-FCSM-script | bug is in script, not RTL | **FALSIFIED — even with FIX, link breaks** |
| **★ P-TX-mux** | **FC TX gated by training_mode AND lane lock depends on training pattern → mutually exclusive** | **PRIMARY (95%)** |
| Alt-1 | Idle gap between cr_pkts breaks LL_RX alignment | Open — needs ILA |
| Alt-2 | Some clock-domain crossing issue during transition | Open |

### Status of fix-attempt patches

All three SW patches we applied are now KNOWN to be insufficient on their own (but defensive and good hygiene):

- `sw_coord_autocal_region8_FIX.sh` — keeps swi_enable=1 during swreset; doesn't fix the bug but is correct.
- `deploy_pair.sh:351-360` (commit 691916d) — same defensive pattern; deploys every time.
- `mask_milestone.sh:49-56` (commit 691916d) — same pattern.
- `bringup_autocal_i2c.sh` (commit ba59df3) — adds `train_auto_en=1` so autoneg runs ST_TRAIN_EXIT; the RTL path is incomplete (`local_swreset_pulse_w` is `_unused_phase3_a` in axi_chiplet_controller.sv:1199-1202) but the register-clear path may be sufficient.

### What's next

- Farm build of tdif-01 is running (synth done, in Phase 2.4 placement). When complete, deploy and ILA-capture the actual cr_pkt traffic and LL_RX state during the training drop to identify the exact micro-architectural failure.
- TX-mux audit agent (a4e32fca99a05d64c) is investigating exact RTL gates and ranking RTL fix options.
- Tier 2 RTL hardening agent still running (less relevant now since swi_enable wasn't the bug, but still defensive code).

### What we now know with high confidence

The bug is FPGA-bringup-protocol-level. The 7-day PHC chase was at the wrong layer. The "stuck in training mode" finding was correct but the FIX direction was wrong — we can't just write slot0=0x0; we need the WAV TX serializer to keep emitting SOMETHING aligned while the FCSM does its handshake. That's an RTL change.

---

## 11. Final root cause + fix paths (2026-05-25, end of session 2)

After tdif-01 deployed and HW ILA captured + targeted probes, the diagnosis is now LOCKED.

### Headline

**The bug is ASYMMETRIC — only slave's LL_RX is broken; master is fine.** Master decodes slave's CR packets correctly (`llrx/valid=1` constantly post-drop). Slave's `llrx/state=iSTATE` (search for SOP) is STUCK forever; ECC sees bits arriving but no valid packet header is ever detected.

### Root cause mechanism

The per-lane PHY mux at `deps/axi-chiplet-controller/logical/wlink/WavD2DGpioTx.v:43-45` flips MID-WORD when `effective_training_mode` falls 1→0. The transition cycle produces a hybrid 16-bit word: first half = training pattern bytes, second half = FC data bytes. This hybrid is NOT a valid ECC long-packet header. Slave's LL_RX SOP-search FSM misses it. Subsequent valid cr_pkts ALSO can't be decoded because the byte boundary has shifted from POR-established alignment.

### Critical NEW discovery — POR-active state (HW PROBE G)

At fresh POR (immediately after `deploy_pair.sh`, BEFORE any `bringup_pair_converge.sh` runs):
- Slave: `fcsm=4 (LINK_IDLE)`, `cr_seen=0`, `ck_seen=1`, `is_short_pkt=1`, `llrx_valid=1`
- Master: `fcsm=2 (SEND_CREDITS2)`, `cr_seen=1`, `ck_seen=0`

**The link is HALF-HANDSHAKED with byte alignment INTACT at POR.** `bringup_pair_converge.sh` ACTIVELY BREAKS this state. The slot0=0x3 recal cycle re-arms `WavD2DGpioRx.count` phase counter, destroying POR-acquired byte alignment.

### Why all prior hypotheses were wrong

| Hypothesis | Why falsified |
|---|---|
| rx_accept consumer-replica (b18-b25 PHC chain) | Wrong layer — bug is below PTP |
| swi_enable=0 transient in to_data_mode | FIX script applied on HW; no change |
| WlinkTxPstateCtrl deadlock | Proven at unit but FSM never enters state 2 in this scenario |
| FCSM TX router stops post-drop | Instrumented sim: 214 tx_advance pulses post-drop |
| sp2wl dataIdMatch=0 | Correct by design — sp2wl is PTP-only; CR/CRACK route differently |

### Fix candidates (two paths, both being tested)

**Path 1 — SW only (simplest)**: skip `bringup_pair_converge.sh` entirely. Deploy tdif-01, wait for FCSM natural progression, ring doorbells. HW test in flight (`ab27205e520a41250`).

**Path 2 — RTL defensive**: word-aligned mux transition in WavD2DGpio override. Mirror counter mirrors `WavD2DGpioTx.count`. Mux only flips at `count==0`. Committed as `5477e60` on `feat/td-interface-debug`. Farm build tdif-02 in flight.

### Sim status

- Unit test `cocotb/wav_d2d_gpio_tx/test_wav_tx_training_mux.py` (5/5 PASS) — confirmed the mid-word mux flip behavior in isolation
- Unit test `cocotb/wlink_tx_pstate_ctrl/test_wlink_tx_pstate_deadlock.py` (7/7 PASS) — proved theoretical deadlock at unit but not relevant in this scenario
- System test `cocotb/wlink_pair/test_tx_gated_by_training.py` — reproduces the FCSM-stuck symptom; the word-align fix doesn't show FCSM advancement in sim because sim's bit-perfect deserializer doesn't model the HW clock-phase-variance symptom

### HW evidence collected

- Initial Phase 0 obs (§1-9 above)
- HW ILA capture on tdif-01 (slave `llrx/state=iSTATE` stuck, master `llrx/valid=1` constantly)
- HW probe battery (PROBE A-G): config dump, swreset-alone insufficient, write-order doesn't matter, deterministic failure, POR-active discovery
- ECC counters = 0 on both sides (no corrupted bits — no decodable frames)

### Lesson learned for future debug sessions

The training-pattern path is a per-lane-bit-slip calibration tool, NOT a byte-align primitive. Going through training and dropping it without coordinated re-establish destroys byte alignment forever. ALWAYS read POR state first — if the link is alive at POR, do NOT perturb it with a recal cycle.

---

## 12. tdif-02 HW test result (2026-05-25 11:20-11:30 UTC)

tdif-02 (`sha256=335c34db / 5b5b487a`, commit `5477e60` with word-aligned mux fix) deployed and tested.

### Test sequence
1. POR baseline (after fresh deploy, no bringup): identical to tdif-01 — half-handshake stuck
2. bringup_pair_converge.sh: 16/16 lane lock, training held (slot0=0x1)
3. to_data_mode (slot0=0x0 + LL swreset 0x27f08→0x00→0x07)
4. Doorbell test (both directions)
5. 3× iteration of recal+to_data_mode
6. sw_coord_autocal_region8.sh full sequence

### Empirical result — partial improvement, full link NOT up

| Signal | tdif-01 (no fix) | tdif-02 (word-align fix) |
|---|---|---|
| Master `SWI_LANE_STATUS` post-to_data_mode | `0x00030000` (lane=0, fault=0, cal_done=1, no sticky) | `0x00090000` (lane=0, fault=0, cal_done=1, no sticky — bit 19 set) |
| Slave `SWI_LANE_STATUS` post-to_data_mode | `0x01890000` (cr_seen sticky, llrx_valid=0, stuck iSTATE) | **`0x22850000` (cr_seen=1, is_short_pkt=1, llrx_valid=1)** |
| `PAIR_CREDIT_COUNTER` both sides | 0 / 0 | 0 / 0 |
| Doorbell crossing | NO | NO |

**Significant CHANGE on slave**: with the word-align fix, slave's LL_RX is now ACTIVE (`is_short_pkt=1, llrx_valid=1`). On tdif-01 slave was stuck in iSTATE with `llrx_valid=0`. The word-align fix demonstrably helps the slave-side RX framing.

**Master RX is still BLIND**: master `cr_seen=0`, `ck_seen=0`, no sticky activity. Doesn't matter how many recal+to_data_mode iterations we do (3 passes tested, identical result).

### Why master still blind — leading hypothesis

The fix is in `WavD2DGpio.v` local override (both bitstreams have it). The mirror counter `mux_align_count_r` is at the WavD2DGpio level and is supposed to track `WavD2DGpioTx.count` (one per lane). BUT:
- Each of the 8 per-lane WavD2DGpioTx instances has its OWN `count` register
- All 8 lane counters reset to `4'hf` on POR but their relative phase relative to the wrapper-level mirror counter may not be guaranteed identical
- The master uses Y7-MRCC for the RX clock; slave uses Y9-SRCC. Per project memory `project_tidelink_idelay_slaveclk` + `project_tidelink_fpga_bringup`, this pin asymmetry has been a known issue
- Possibility: the fix synchronizes the slave's TX correctly (helping master's RX) but NOT vice versa due to the asymmetric clock path

### What we have proven

1. **The mid-word mux flip IS part of the bug** — fix produced measurable progress on slave's RX
2. **There's an ADDITIONAL asymmetric component** that the word-align fix doesn't address — probably related to the Y7-MRCC vs Y9-SRCC pin asymmetry or per-lane WavD2DGpioTx.count phase
3. **The bringup_pair_converge.sh ARTEFACTS handling is buggy** — it silently picks up parent /tmp/tidelink_deploy/ files even when sub-dir specified

### Recommended next steps

1. **ILA capture on tdif-02 master's RX** — capture `phy_link_rx_*` signals to see what slave's TX is producing at master's RX pads. If slave's TX bytes are misaligned (different from training pattern misalignment), the fix needs to address that too.
2. **Investigate per-lane WavD2DGpioTx.count vs mirror counter sync** — verify the wrapper-level mirror counter actually mirrors each lane's count.
3. **Consider modifying the FIX to be PER-LANE rather than per-bus** — each WavD2DGpioTx instance could have its own latched_training_mode using its own count.
4. **Investigate the asymmetry deeper** — why does the fix help slave's RX but not master's RX?

### Status as of end of session 2 (2026-05-25 11:30 UTC)

- Bug class definitively narrowed to byte-alignment loss at training→FC transition
- Word-align fix is PARTIAL — measurable improvement (slave RX active) but link still not up
- Lease released cleanly; tdif-02 staged + deployed; sim tests + ILA infrastructure all ready
- Next session: address the asymmetric remaining issue (probably ILA-driven)

---

## 13. tdif-03 HW test result (2026-05-25 12:20 UTC) — per-lane mux fix

After tdif-02 ILA capture revealed the asymmetry FLIPPED (master now sees slave's traffic, slave receives ZERO bytes because master's TX serializer went dead), prepared tdif-03 with per-lane mux fix INSIDE `WavD2DGpioTx.v` (each lane uses its own count register for the alignment latch). Commit `aa87881` on `feat/td-interface-debug`.

### tdif-03 HW result — significant further progress

| Signal | tdif-01 | tdif-02 | **tdif-03** |
|---|---|---|---|
| Master `SWI_LANE_STATUS` post-to_data | `0x00030000` | `0x22890000` (sees slave's traffic) | `0x01890000` (sees + ck_seen=1!) |
| Slave `SWI_LANE_STATUS` post-to_data | `0x01890000` (sticky from POR) | `0x00030000` (slave blind) | `0x018f0000` (cr_seen=1, ck_seen=1, llrx_valid implied) |
| Master cr_seen / ck_seen | 0 / 0 | 1 / 0 | **1 / 1** |
| Slave cr_seen / ck_seen | 1 / 0 | 0 / 0 | **1 / 1** |
| FCSM state | unclear | M=IDLE silent | **M=4 LINK_IDLE, S=7 SEND_NACK** |
| `RETURNER_BUSY` (bit[0] of STATUS) | 0 | 0 | **1 / 1** (both returners busy!) |
| `Wlink LinkStatus rx_data_valid` | (unread) | (unread) | **1 / 1** (both sides!) |
| PAIR_CREDIT_COUNTER | 0 / 0 | 0 / 0 | 0 / 0 |
| Doorbell crossing | NO | NO | NO |

### Significance

**The handshake is now COMPLETE in both directions.** Both sides have CR/CRACK exchanged. Both Wlink RX layers see valid data. Master FCSM advanced past credit-init to LINK_IDLE. Slave FCSM is at SEND_NACK (state 7) — actively trying to send a NACK packet, suggesting it received something it can't process at FC layer.

**Remaining blocker**: FCSM doesn't advance to LINK_DATA (state 5). Likely candidates:
1. Slave stuck at SEND_NACK because of ECC error or unexpected packet — can't pulse auto_tx_out_advance to return to LINK_IDLE
2. Credit initialization issue — `fe_tx_credit_max` loading didn't happen or APB PCC mirror is broken
3. The returner is busy (RETURNER_BUSY=1) mid-transfer waiting for hready from FC adapter — possibly stuck in chicken-and-egg with credit window

### Build progression summary

The bug class was correctly identified (byte-alignment loss at mid-word mux flip). The wrapper-level fix (tdif-02) helped one direction. The per-lane fix (tdif-03) helped BOTH directions complete the handshake. The remaining issue is one layer deeper — credit/FCSM advancement after handshake.

### Next session

1. ILA capture both sides' FCSM state + returner state + tl_fc_a2l_ready signals to see what's blocking LINK_IDLE → LINK_DATA
2. Investigate slave at SEND_NACK — what packet caused it?
3. Try a FLUSH (CTRL bit[1]) to clear sticky bits, then re-handshake
4. Possibly tdif-04 with additional RTL change (clear NACK condition, or skip the LINK_IDLE→LINK_DATA gating)
