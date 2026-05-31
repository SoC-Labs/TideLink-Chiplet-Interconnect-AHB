# Bug C — Role-Asymmetry Forensic Investigation (2026-05-31 / 2026-06-01)

Branch: `sim/bugc-role-forensic` (forensic) / target `fix/bug-c-tx-starvation`.

## Headline

**The task brief premise — that `fe_rx_credit_max` / `fe_tx_credit_max` stay at 0 because of a role-asymmetric initialisation gap — is FALSIFIED by sim probe data.** The Wlink FC credit ledger DOES populate to `0x1f` symmetrically on both sides after `do_to_data_mode()`. The "PAIR_CREDIT_COUNTER=0" observation in the failing tests refers to a DIFFERENT counter (`pair_credit_counter` in `tidelink_apb_regs.sv:320`) — an SW-driven application-level FIFO doorbell counter, NOT the Wlink credit ledger. That counter stays 0 because nothing has written to it (Bug C-adjacent SW path), not because the link credits failed.

The actual M-side `state=5` (LINK_DATA tx-blocked) + S-side `state=7` (SEND_NACK) wedge that defines the symptom is **downstream of credit handshake** — most consistent with the "slave RX framer NACK-worthy decode" hypothesis already recorded in memory under `★★★ Bug A root cause 2026-05-29 evening`. Bug C and Bug A may be the same wedge under different labels.

## What the probe actually shows

`cocotb/tidelink_top_pair/test_bugc_credit_probe.py` (committed on this branch) instruments every cycle around the `do_to_data_mode()` 0x208 bootstrap and dumps `fe_rx_credit_max`, `fe_tx_credit_max`, `en_ff2_rx_demet_io_out`, `io_app_enable`, `pkt_is_cr_pkt`, `auto_rx_in_word_count`, and the FCSM `state` on both `u_master` and `u_slave`.

### Timeline excerpt (probe output, ns scaled to cycles)

| time (ns)  | event                                            | m state    | s state    | m fe_rx_cmax | s fe_rx_cmax |
| ---------- | ------------------------------------------------ | ---------- | ---------- | ------------ | ------------ |
| 8403400    | end of Phase 1 (passive autocal)                 | 3          | 3          | 0x1f         | 0x1f         |
| 8403920    | post slot0=0                                     | 4          | 5          | 0x1f         | 0x1f         |
| 8404840    | post SWRESET_ON  (0x00027f08 — Tier 2 masks)     | 4          | 6          | 0x1f         | 0x1f         |
| 8405100    | SWRESET_OFF cy+6 — **swi_enable dipped LOW**     | (en=0)     | (en=0)     | 0x1f         | 0x1f         |
| 8405220    | SWRESET_OFF cy+12 — **credit ledger ZEROED**     | (en=0)     | (en=0)     | **0x00**     | (lag)        |
| 8405280    | SWRESET_OFF cy+15                                | (en=0)     | (en=0)     | 0x00         | **0x00**     |
| 8405760    | post SWRESET_OFF settled — FCSM regressed        | **0**      | **0**      | 0x00         | 0x00         |
| 8405880    | post ENABLE (0x00027f07)                         | 0 → 1      | 0 → 1      | 0x00         | 0x00         |
| 8407520    | final cy+41 — **master re-loads credit_max**     | 1          | 1          | **0x1f**     | 0x1f (next)  |
| 8408220    | final cy+76 — slave re-loads credit_max          | 1 → 2      | 1 → 2      | 0x1f         | **0x1f**     |
| 8506680    | end of probe — both at state 4, credit healthy   | **4**      | **4**      | **0x1f**     | **0x1f**     |

Source: `/tmp/bugc_probe.log` (preserved this session). Filter:
```
grep -E "phase1-end|post-slot0|SWRESET|ENABLE|final |Credit ledger" /tmp/bugc_probe.log
```

### Key conclusions from the probe

1. **The credit ledger DOES populate** on both sides bilaterally to `0x1f` (= `word_count[15:8]` of the `0x1f1f` CR packet payload, per `WlinkGenericFCSM_6.v:931`/`979`). Hypothesis "credit ledger never loads" is FALSIFIED.
2. There IS a transient dip during the bootstrap: `swi_enable` drops to 0 for ~30 cycles during the SWRESET_OFF → ENABLE window. `en_ff2_rx_demet_io_out` follows, and the synchronous clear path `_fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out` (FCSM_6.v:367, 928-929, 976-977) zeroes both `fe_rx_credit_max` and `fe_tx_credit_max`. The FCSM also regresses to `state=0` (LINK_DEFAULT) during this window.
3. After the ENABLE write re-asserts `swi_enable=1`, the FCSM walks back through state 1 (LINK_INIT) emitting CR packets at `word_count=0x1f1f`, the L6 emit-count gate eventually fires, and the credit ledger re-populates symmetrically. **This is a self-recovering transient, NOT a permanent wedge.**

## Re-interpretation of the original test 01 failure

The reported failure log from `test_bug_c_doorbell_asymmetry.test_bugc_01_master_to_slave_100`:

```
[pre-traffic]  FCSM: m_state=4 s_state=4  PAIR_CREDIT: m=0 s=0  cr=1 crack=1 (both)
[M->S 100 rings] counts={m_a2l: 9310, m_l2a: 0, s_a2l: 0, s_l2a: 0}
[post-traffic] FCSM: m_state=5 s_state=7  PAIR_CREDIT: m=0 s=0  cr=1 crack=1
```

is **not** explained by credit_max=0. Rather:

- `pre-traffic` shows both at `state=4` (LINK_IDLE), credit_max almost certainly already 0x1f (the test does NOT probe fe_rx_credit_max — the `PAIR_CREDIT` here is the application FIFO counter, which is unrelated).
- Master rings 100 doorbells: master FC adapter offers data → `tl_fc_a2l_valid` asserts 9310 cycles → master FCSM advances to `state=5` (LINK_DATA TX). This requires fe_rx_credit_max > 0, consistent with our probe.
- But **the slave Wlink RX framer never delivers any packet to its FC adapter** (`s_l2a=0`). After ~9k cycles of attempted data, slave's FCSM lands in `state=7` (SEND_NACK) — meaning the slave is reacting to RX-side packet decode failures (CRC errors or NotExpPacket).
- Master sees the slave's NACK responses, can't advance its TX window, stays at `state=5` blocked.

This is the **NACK-decode wedge** already documented in memory: see `★★★ Bug A root cause 2026-05-29 evening` and `★★★ Sim repro 2026-05-26`. The mechanism is in `tidelink_top` link-layer glue, not in the Wlink FCSM credit logic.

## The role-swap test 03 "PASS" is misleading

Reading `test_bug_c_doorbell_asymmetry.py:298-319`:

```python
crossed = (m_db_after > m_db_before) or (s_db_after > s_db_before)
if not crossed:
    tb.log.info("  ROLE-SWAP RESULT: bug tracks ROLE=slave ...")
else:
    tb.log.info("  ROLE-SWAP RESULT: bug tracks INSTANCE ...")
# This test does NOT assert pass/fail — it's purely diagnostic
assert int(tb.dut.m_role_locked.value) == 1, ...
assert int(tb.dut.s_role_locked.value) == 1, ...
```

The only assertions in test 03 are `role_locked == 1` on both instances. The cocotb-level "PASS" tells us nothing about whether the doorbell crossed — it only tells us the swapped-role bringup didn't crash. The "test 03 PASS proves role-swap fixes the bug" reading in the task brief is **not supported by the test's pass criteria**.

To actually establish role-vs-instance, test 03 needs to be re-run and the cocotb log inspected for the `ROLE-SWAP RESULT` line. Without that data, we cannot localise to "role-asymmetric initialisation".

## Where the real bug-C lever may live

Two candidate loci, both downstream of credit_max:

1. **Slave RX framer NACK-decode** (`Wlink.v` → `WavWlinkLLRx_*` paths). The bringup-recal sequence (`slot0=0x3`) was previously documented as causing the slave's LL_RX byte alignment to lose mid-word mux state at the `WavD2DGpioTx.v:43` boundary. This is the "★★ TideLink interface FCSM bug 2026-05-24/25" lineage. The original "F-1" state-7 watchdog (committed `f5633f1`) addresses the SYMPTOM (clear send_nack_req after timeout) but not the upstream cause.

2. **Master FCSM state-5 → state-7 trap.** When master sees the slave's NACK return, it may transition to state 7 itself. Or it may stay at state 5 forever because `auto_tx_out_advance` is gated by some other peer-driven signal that never comes back true.

A non-RTL-touching follow-up: add explicit probes for `send_nack_req`, `pkt_is_data_pkt`, `isExpPacket`, `pkt_is_nack_pkt`, and `valid_rx_pkt_crc_err` on the slave FCSM during a doorbell run. That captures the NACK-decode question directly.

## Patch design

**There is no minimal RTL patch to recommend at this time.** The original hypothesis (role-asymmetric credit-ledger init) is falsified by the probe data. Recommending a fix without a confirmed root cause is the same mistake F-1.5 and F-2 made (and both failed for the same reason — they treated symptoms, not causes).

Recommended path before any RTL patch:
1. Run a probe variant that captures `send_nack_req`, `pkt_is_*`, `last_good_pkt_from_rx` on slave during the failing doorbell window of test 01.
2. Compare slave-RX behaviour cycle-by-cycle against master-TX to find the first NACK-worthy decoded packet.
3. ONLY then design a patch — likely in the link-layer byte-align / framer path (deps/axi-chiplet-controller), not in `WlinkGenericFCSM_6.v`.

If a defensive watchdog is acceptable (defence in depth, not fix), the existing F-1 state-7 watchdog already handles the recovery. F-1.5 / F-2 archived for cause.

## Sim verification recipe

To reproduce the probe data above:

```bash
cd cocotb/tidelink_top_pair
PYGPI_PYTHON_BIN=/home/dam1n19/miniconda3/bin/python \
  CMSDK_FPGA_SRAM_V=/research/AAA/ip_library/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v \
  LD_LIBRARY_PATH=/home/dam1n19/miniconda3/lib:$LD_LIBRARY_PATH \
  COCOTB_TEST_MODULES=test_bugc_credit_probe \
  COCOTB_TOPLEVEL=tb_top \
  TOPLEVEL_LANG=verilog \
  PYTHONPATH=$(pwd) \
  sim_build_bugc/simv 2>&1 | tee /tmp/bugc_probe.log
```

Expected: ~3 min wall time, ends with `Credit ledger populated: m=0x1f s=0x1f`.

If the simv doesn't exist yet, build with:
```bash
CMSDK_FPGA_SRAM_V=/research/AAA/ip_library/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v \
  make MODULE=test_bugc_credit_probe SIM_BUILD=sim_build_bugc TB_TOP_NO_DUMP=1 PYTHONPATH=$(pwd)
```

## Status

- ASYMMETRIC SIGNAL: not localised — original hypothesis falsified
- ROLE GATE: not applicable (no role-dependent credit-init path found)
- PATCH DESIGN: deferred — premature without root cause
- SIM CONFIDENCE: HIGH that the credit-ledger hypothesis is wrong; HIGH that the actual wedge is downstream (state-5/state-7); LOW on exact RTL locus
