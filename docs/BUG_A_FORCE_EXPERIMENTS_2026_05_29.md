# Bug A — interventional force/release experiments

**Date:** 2026-05-29
**Test file:** `cocotb/tidelink_top_pair/test_fc_tx_force_experiments.py`
**Sim build:** `sim_build_fc_force` (TB_TOP_NO_DUMP=1)
**Harness:** VCS T-2022.06-SP2_Full64 via cocotb v2.0.1
**Per-test wall-clock cap:** `timeout 600` on `make` (≤ 10 min)
**Per-test sim-time cap:** `cocotb.test(timeout_time=25 ms)` — bringup alone consumes ~8.5 ms

All 5 tests **PASS** their assertions. The diagnostic verdict is captured in the per-test log line; pass/fail is intentionally loose because this is an interventional probe sweep, not a regression gate.

---

## 1. Results table

Constants observed at the start of every test (post `run_bringup_full`):

| signal | value | meaning |
|---|---|---|
| master `cal_done` | 1 | PHY calibrated |
| slave  `cal_done` | 1 | PHY calibrated |
| master FCSM `state` | **5** (`LINK_DATA`) | master has entered data mode |
| slave  FCSM `state` | **4** (`LINK_IDLE`) | **slave never reaches data mode** |
| master / slave `cr_pkt_seen_rx` | 1 / 1 | CR exchange happened |
| master / slave `crack_pkt_seen_rx` | 1 / 1 | CRACK exchange happened |
| master / slave `PAIR_CREDIT_COUNTER` (APB 0x028) | 0 / 0 | Bug A observability symptom |
| master `tl_fc_a2l_valid` (idle) | 0 | no TX |
| master `skid_valid_r` (idle) | 0 | skid empty |

Per-test force outcomes:

| # | Test | What forced | M.skid_valid_r | M.tl_fc_a2l_valid | M.arb_valid | S.tl_fc_l2a_valid | S.REG_PKT_WORD_LEN |
|---|---|---|---|---|---|---|---|
| 1 | `test_force_tx_data_phase_r_high` | `M.tx_data_phase_r=1` for 100 cy | **100/100** | **100/100** | 100/100 | n/a | n/a |
| 2 | `test_force_skid_can_accept_high` | `M.skid_can_accept=1` + AHB pkt | 4 cy | **4 cy** (= packet word count) | 4 cy | n/a | n/a |
| 3 | `test_force_direct_a2l_injection` | `M.tl_fc_a2l_valid=1`+`data=0x0024deadbeef` 1 cy | n/a | (forced) | n/a | **0** in 2000 cy | n/a |
| 4 | `test_force_release_hygiene` | each force in sequence + release | — | — | — | — | M.doorbell_resp_acc=0 (APB live, no wedge) |
| 5 | `test_force_combined_bypass` | `M.tx_data_phase_r=1` + `M.skid_can_accept=1` + AHB pkt | n/a | **2126 cy** sustained | n/a | **0** | **0** |

Per-test verdict log line:

| # | Log verdict |
|---|---|
| 1 | `T1 VERDICT: H-A1 confirmed — block was tx_data_phase_r latch` |
| 2 | `T2 VERDICT: H-A2 confirmed — backpressure was block` |
| 3 | `T3 VERDICT: Wlink/PHY downstream block — slave never saw the forced packet` |
| 4 | `T4 release hygiene completed — no wedge observed` |
| 5 | `T5 VERDICT: master a2l_valid drives but slave never receives — Wlink/PHY downstream block` |

---

## 2. Localisation verdict

### **Wlink / PHY downstream — specifically the FCSM `state==4 (LINK_IDLE)` asymmetry on the slave**

**Reasoning (the chain that resolves T1+T2 against T3+T5):**

* T1 says "force `tx_data_phase_r=1` and skid loads, a2l_valid asserts." That looks like the AHB→FC handoff is the block.
* T2 says "force `skid_can_accept=1` and the 4-word packet flows end-to-end through the master adapter." That looks like skid backpressure is the block.
* But T1 and T2 only observe **master-side** signals. Neither test checks whether the slave receives anything.
* T3 forces `tl_fc_a2l_valid=1` directly at the master's tidelink_top boundary for one cycle and watches the slave's `tl_fc_l2a_valid`. **Slave: 0 pulses in 2000 cy.** Single-cycle inject not seen, but Wlink should at least pipeline / queue it.
* **T5 is the smoking gun.** Combined force of both `tx_data_phase_r` and `skid_can_accept` produces a **sustained 2126-cycle assertion of `M.tl_fc_a2l_valid`** at the master output — yet the slave's `tl_fc_l2a_valid` stays **0** and slave `REG_PKT_WORD_LEN` reads **0x00000000**. The master is driving valid FC data into Wlink; Wlink is consuming it (the `_ready` was holding hi otherwise the skid couldn't have drained that long); the slave never sees it.

* The pre-test state snapshot is the matching mechanism: **master FCSM = 5 (`LINK_DATA`), slave FCSM = 4 (`LINK_IDLE`).** Per the L7 comment block in `src/rtl/local_overrides/WlinkGenericFCSM_6.v:12`, this is exactly the asymmetric-FCSM symptom the L7 fix targets. The slave's `LINK_IDLE` state cannot consume `data_id`-carrying packets — it sits waiting to leave SEND_NACK (or, here, the inverse: it never armed RX framing for data-mode after CR/CRACK).

* H-A1 (T1) and H-A2 (T2) verdicts are **true but proximate**: they would let local master flow proceed, but neither escapes the slave-side LINK_IDLE block. The earlier ranking that pointed at fc_adapter is falsified by T5.

* Why doesn't T2's 4-cycle natural-flow window contradict this? With `skid_can_accept` held high, the master can keep loading the skid and Wlink CAN drain it (FCSM `state==5` on master means TX framer is active). The Wlink TX serdes will then emit those bytes onto the lane. But the slave's RX framer is still in `LINK_IDLE` — it discards (or fails to forward) any data_id traffic. So the master's `a2l_valid` looks like "the link works" from the master's vantage point, while the slave never gates the data through its RX-side `l2a_valid`.

### Secondary observation — `PAIR_CREDIT_COUNTER` is the wrong oracle

The APB-mirror `PAIR_CREDIT_COUNTER` (0x028) reads 0 on both sides, but this is the SW-managed observability register (per `HANDOFF_ERRATA_2026_05_29.md`). The real credit ledger `fe_rx_credit_max` was 0x1f on both dies in earlier probes. Bug A is **not** a credit-starvation symptom — it is the slave RX framer never leaving LINK_IDLE.

---

## 3. RTL signal + file:line for the smoking gun

| Concept | File:line | Signal | Observed |
|---|---|---|---|
| Slave FCSM never reaches `LINK_DATA` | `src/rtl/local_overrides/WlinkGenericFCSM_6.v` (comments at lines 12, 46 establish `state==4` = LINK_IDLE, `state==5` = LINK_DATA) | `dut.u_slave.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state` | **stuck at 4** for the entire 8.5 ms post-bringup window |
| Master FCSM in LINK_DATA | same file | `dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state` | reaches **5** but cannot drag peer with it |
| Master TX path proves it IS offering data | `src/rtl/tidelink_top.sv:495`, `:1188-1189` | `dut.u_master.tl_fc_a2l_valid` / `tl_fc_a2l_data` | **2126 cy of sustained valid** (T5) |
| Slave RX path proves nothing arrives | `src/rtl/tidelink_top.sv:498-499` | `dut.u_slave.tl_fc_l2a_valid` / `tl_fc_l2a_data` | **0 cy in 2000 cy** (T3, T5) |
| L7 fix already targets this class | `src/rtl/local_overrides/WlinkGenericFCSM_6.v:1-70` (header comment) | `socl_l7_reached_link_data`, `socl_l7_bringup_forgive` | L7 is the **producer-side / NACK-clear** fix. Bug A is the **consumer-side analogue**: slave needs an equivalent "bring me to LINK_DATA when the peer is sending data" gate, NOT a NACK-clear gate. |

The proximate root-cause hypothesis is the **slave FCSM transition `LINK_IDLE → LINK_DATA` never fires** in this pair-sim configuration, even though CR/CRACK exchange completed. The exact gate condition for that transition lives in the upstream generated Verilog (FC.scala synthesised state-machine), most likely on the `state == 3'h4` branch in `WlinkGenericFCSM_6.v`. The next agent should inspect the `_GEN_104` / `_GEN_171` chain (state-4 next-state logic at line 416) and identify which input never asserts on the slave.

---

## 4. ILA probe list (when this is taken to HW)

Capture-clock: `hclk` (master domain). Mirror probes on slave domain using `hclk` of the slave die.

| # | Signal (master & slave) | RTL anchor | Bits | Why |
|---|---|---|---|---|
| 1 | `u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state` | `WlinkGenericFCSM_6.v` | 3 | Direct view of LINK_IDLE/LINK_DATA asymmetry |
| 2 | `u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx` | `WlinkGenericFCSM_6.v` | 1 | Confirms CR exchange completed |
| 3 | `u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx` | same | 1 | Confirms CRACK exchange completed |
| 4 | `tl_fc_a2l_valid` / `tl_fc_a2l_ready` | `tidelink_top.sv:495-497` | 1+1 | Master TX offering / Wlink draining |
| 5 | `tl_fc_a2l_data[47:46]` (pkt_type) | `tidelink_top.sv:496` | 2 | Confirm FIFO_DATA vs SIDEBAND |
| 6 | `tl_fc_l2a_valid` / `tl_fc_l2a_accept` | `tidelink_top.sv:498-500` | 1+1 | Slave RX firing / consumer accept |
| 7 | `tl_fc_l2a_data[47:46]` (pkt_type) | `tidelink_top.sv:499` | 2 | Confirm correct demux at slave |
| 8 | `u_fc_adapter.skid_valid_r` / `skid_can_accept` | `tidelink_fc_adapter.sv:376,380` | 1+1 | Skid backpressure live | 
| 9 | `u_fc_adapter.tx_data_phase_r` | `tidelink_fc_adapter.sv:179` | 1 | AHB address-phase latch |
| 10 | `u_fc_adapter.arb_valid` / `sideband_grant` | `tidelink_fc_adapter.sv:369,368` | 1+1 | Arbiter health |
| 11 | `u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.send_nack_req` | `WlinkGenericFCSM_6.v` | 1 | Confirm L7 fix took effect (should be 0 in steady state) |
| 12 | `u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.socl_l7_reached_link_data` | `WlinkGenericFCSM_6.v` (L7 fix) | 1 | Should be 1 on master, **should be 1 on slave but bug = 0** |

Trigger condition: `master.state == 5 && slave.state == 4` (asymmetric FCSM) — captures the bug onset.
Depth: ≥ 4096 samples to span CR/CRACK exchange + first AHB packet write.

---

## 5. Reproduction commands

```bash
source /home/dam1n19/SoCLabs/tidelink/set_env.sh
cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair

# Build once, run any of the 5 tests:
for tc in test_force_tx_data_phase_r_high \
          test_force_skid_can_accept_high \
          test_force_direct_a2l_injection \
          test_force_release_hygiene \
          test_force_combined_bypass; do
  timeout 600 make MODULE=test_fc_tx_force_experiments \
    SIM_BUILD=sim_build_fc_force TB_TOP_NO_DUMP=1 TESTCASE=$tc
done
```

Wall-clock per test: ~8 minutes (compile + 8.5 ms of bringup).
