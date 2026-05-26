# tidelink_top_pair — paired-die regression sim

Two full `tidelink_top` instances cross-wired through GPIO PHY pads via
`pad_skid` (default SKID_BITS=0 = passthrough). The testbench mirrors the
real-HW topology: per-side APB unified config, AHB TX aperture, AHB FIFO
read port, separate role straps + priorities. Six cocotb tests walk the
bringup chain.

## What this reproduces

After fixes (commit `0a538de`), this sim **deterministically reproduces the
HW state observed on tdif-13/15** post-bringup:

- Bilateral LINK_IDLE (Wlink FCSM `state=4` both sides)
- Symmetric `cr_pkt_seen` + `crack_pkt_seen`
- `PAIR_CREDIT_COUNTER = 0` on both sides
- Asymmetric doorbell crossing — M→S stuck, S→M works

Iteration time is ~6 min wall-clock vs ~50 min for an FPGA build, so this
should be sim-gated before any HW deploy that touches the link layer.

## How to run

```
source set_env.sh
make sim-regression
# or, directly:
cd cocotb/tidelink_top_pair && make
```

The Makefile uses VCS (`SIM=vcs`). cocotb 2.0+ required.

## Expected baseline results (current RTL state)

| Test | Result | Meaning |
|---|---|---|
| `test_01_role_lock_and_cal_done` | PASS | `role_lock=1`, `cal_done=1` on both sides via the W1S ROLE_CFG path + the calibrator's auto-arm on `role_locked_rise` |
| `test_02_training_held_pre_release` | PASS | `slot0` reads back as expected |
| `test_03_to_data_mode_cr_crack_latch` | PASS | After LL bootstrap, both sides latch cr+crack — bilateral LINK_IDLE achieved |
| `test_04_pair_credit_counter_nonzero` | **FAIL** | `PAIR_CREDIT_COUNTER = 0` — the HW symptom locked in |
| `test_05_doorbell_master_to_slave` | **FAIL** | M→S doorbell stuck — the HW asymmetry |
| `test_06_doorbell_slave_to_master` | PASS | S→M doorbell crosses — also matches HW |

Any RTL fix that resolves the credit-path bug should flip test_04 + test_05
to green. The FC-pulse counters logged by `watch_fc_pulses` in test_05
localize the cut:

- `M.a2l = 0` → master's FC adapter never submits the packet (returner /
  credit / skid path bug)
- `M.a2l > 0, S.l2a = 0` → packet dropped on the wire (Wlink TX/RX, lane
  decode)
- `S.l2a > 0, RESP_ACC stays 0` → slave's RX consumer dropping the packet
  (sideband decode → APB regs)

## Two non-obvious sim-vs-HW gotchas

1. **Natural autoneg does NOT converge in sim.** `nego_cfg_reg <= 7'd0` at
   POR (`axi_chiplet_controller.sv:397`) keeps the autoneg FSM in
   `ST_BYPASS` forever. The fix is to write ROLE_CFG at APB offset 0x2080
   directly (master = `0x02`, slave = `0x03`) — same W1S path used by
   `deploy_pair.sh` on HW (`axi_chiplet_controller.sv:427-430`).

2. **The slot0=0x3 recal pulse RESETS the calibrator mid-sweep**
   (`tidelink_phy_align_calibrator.sv:428`: `S_SWEEP → S_CANCEL` on
   `swreset`). The calibrator already auto-arms on `role_locked_rise` and
   completes the 128-point sweep autonomously. Don't call
   `do_hold_training` unless you're specifically testing recal-pulse
   behavior. This finding corroborates `bringup_pair_passive.sh`'s
   hypothesis that the standard SW recal-pulse actively breaks
   POR-aligned link.

## Hierarchical probes provided by `PairTB`

```python
tb.cal_state_name(side)       # IDLE/ARM/SWEEP/FINISH/DONE/CANCEL/HOLD
tb.fcsm_state(side)           # Wlink FCSM state 0..7
tb.fcsm_cr_pkt_seen(side)
tb.fcsm_crack_pkt_seen(side)
tb.fc_a2l_valid(side)         # FC adapter TX submit valid
tb.fc_a2l_ready(side)
tb.fc_l2a_valid(side)         # FC adapter RX receive valid
tb.fc_skid_valid(side)
tb.watch_fc_pulses(n, label)  # counts FC valid pulses per side over n cycles
```

`side` is `"m"` or `"s"` (master / slave).

## Related

- `cocotb/wlink_pair/` — Wlink-layer-only paired tests; predates this one
- `cocotb/tidelink_system/` — FC-adapter-only loopback (no Wlink); useful
  for FIFO/returner unit-level work but bypasses the actual Wlink stack
- `pynq_host/scripts/deploy_pair.sh` — the HW analog of `do_role_lock`
- `pynq_host/scripts/bringup_pair_passive.sh` — the HW analog of the
  passive-autocal flow this test uses
