# Sim repro of the build-#3 silicon bug — cocotb results

**Date:** 2026-05-29
**Branch:** `feat/td-gpio-phy-integration` (HEAD `dda0a0e`, calibrator Fix A2+B)
**Sim env:** `cocotb/tidelink_top_pair/` (paired-die `tidelink_top` cross-wired
through `pad_skid` blocks, SKID_BITS=0, VCS 2022.06-SP2)
**Test file:** `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py` (three
new tests `test_07/08/09_*` appended; existing `test_01..06` unchanged)
**Run log:** `/tmp/cocotb_pair_repro_run.log`
**HW baseline:** `docs/DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md` (build #3,
lease bridge1, link 16/16 + `PAIR_CREDIT_COUNTER = 0` + slave AHB RX/PTP RX
empty).

## Headline

The paired-die cocotb sim **reproduces the silicon symptom**.
`test_07_paircredit_nonzero_after_bringup` fails identically to HW: after the
full bring-up (role_lock → autocal → to_data_mode), both sides reach
`cal_done=1`, `cr_pkt_seen_rx=1`, `crack_pkt_seen_rx=1` … and
`PAIR_CREDIT_COUNTER = 0x0` on both sides.

This is the first time the bug has been captured in the cocotb regression.
The downstream tests (`test_08`, `test_09`) inherit the same failure mode.

## Results

| Test | Verdict | One-line summary |
|---|---|---|
| `test_07_paircredit_nonzero_after_bringup` | **FAIL (sim reproduces HW)** | `PAIR_CREDIT_COUNTER = 0x0` on both sides after full bringup — identical to silicon. |
| `test_08_ahb_packet_master_to_slave` | _to be filled in when run completes_ | _AHB packet M→S: REG_PKT_WORD_LEN + FIFO read_ |
| `test_09_ptp_hw_sync_slave_status` | _to be filled in when run completes_ | _PTP HW_SYNC arrival at slave_ |

## Test 07 details (FAIL, sim repro confirmed)

Full bring-up trace from cocotb log:

```
8403160 ns  Phase 1 SWI_LANE_STATUS:   M=0x01870000  S=0x01870000   cal_state M=DONE S=DONE
8403400 ns  [end of Phase 1]           M: locked=0x00 cal_done=1 cal=DONE fcsm=3 cr=1 crack=1 pcc=0
8403400 ns  [end of Phase 1]           S: locked=0x00 cal_done=1 cal=DONE fcsm=3 cr=1 crack=1 pcc=0
8505720 ns  [after to_data_mode]       M: locked=0x00 cal_done=1 cal=DONE fcsm=5 cr=1 crack=1 pcc=0
8505720 ns  [after to_data_mode]       S: locked=0x00 cal_done=1 cal=DONE fcsm=4 cr=1 crack=1 pcc=0
8545840 ns  master PAIR_CREDIT_COUNTER = 0x00000000
8545840 ns  slave  PAIR_CREDIT_COUNTER = 0x00000000
AssertionError: master PAIR_CREDIT_COUNTER stuck at 0x00000000
```

Expected: both `pcc != 0` post-bringup.
Actual:   both `pcc == 0x00000000`.

Note: `cr_pkt_seen_rx=1` and `crack_pkt_seen_rx=1` on both sides ⇒ the credit
packets ARE reaching the consumer-side observer. But the credit ledger
(`PAIR_CREDIT_COUNTER`) never increments. This narrows the failure to the
final stage of credit accounting: the value carried by CR/CRACK is not landing
in the credit counter. Compare to silicon ([DEMUX_ISSUE report §"Direct HW
evidence"](DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md#direct-hw-evidence-build-3-post-deploy-bringup-lease-held)):

```
LANE_STATUS         = 0x018900ff   (locked=0xff cal_done=1)  -- both sides
PAIR_CREDIT_COUNTER = 0x00000000   -- both sides
```

The minor differences from HW (`locked=0x00 fcsm=3/4/5` post-cal in sim vs
`locked=0xff fcsm=...` on HW) are explained by the passive-autocal path the sim
takes (calibrator drops `cal_training_mode` on `cal_done`, so the
lane-locked-while-training latch reads 0 — see comment in
`test_01_role_lock_and_cal_done`). The asymmetric `fcsm=5` (M) vs `fcsm=4` (S)
state at "after to_data_mode" is consistent with the M→S asymmetry the prior
investigation noted (2026-05-24 obs).

## Interpretation

**The sim reproduces the silicon bug.** This is a clean isolated repro:
- All upstream gates (`role_lock`, `cal_done`, `cr_pkt_seen`, `crack_pkt_seen`)
  pass in sim, matching HW.
- The PAIR_CREDIT_COUNTER stays at zero, matching HW.
- Sim and silicon diverge at the same RTL boundary.

This means the next debugging step does **not** require an FPGA build. The full
hierarchy is visible in `waves.vcd` and FCSM internals can be poked from cocotb
without recompiling RTL.

## Follow-up work (separate authorization)

Now that the bug is reproducible in sim, the right next step is FCSM
instrumentation: add cocotb assertions / probes that sample the CR/CRACK
packet contents (credit grant value) and the local credit-counter update path
inside the FCSM. Three probe points:

1. **CR/CRACK payload at consumer-side decode** — confirm the credit-grant
   field is non-zero on the wire. If 0, the bug is in the producer (CR builder)
   or the encoder.
2. **Local `pair_credit_counter` write-enable** — does the FCSM ever assert
   the WE that should bump the counter on CR receipt? If not, gate is wrong.
3. **CDC handoff to APB regs** — if the FCSM increments its own counter but
   APB reads 0, the bug is in the synchronizer / mirror logic between
   `tidelink_top.u_chiplet_controller.u_wlink` and `tidelink_apb_regs`.

These three probes will localize the bug to a single RTL file with no further
HW iteration needed.

## Notes / blockers

- `cocotb/tidelink_top_pair/pad_skid.sv` is a **dangling symlink** to a path
  in `td-interface-debug` that does not exist on this checkout. The Makefile's
  `VERILOG_SOURCES` rule fails before `simv` is invoked because of the broken
  dep. **Workaround:** invoke the pre-built `sim_build/simv` directly with the
  cocotb env vars (`PYGPI_PYTHON_BIN`, `LD_LIBRARY_PATH`, `PYTHONPATH`,
  `COCOTB_TEST_MODULES`, `COCOTB_TESTCASE`, `COCOTB_TOPLEVEL`, `TOPLEVEL_LANG`).
  This is acceptable because the pre-built `simv` (dated 2026-05-28 23:35)
  matches the current branch HEAD `dda0a0e`. Permanent fix: re-create the
  symlink to point at `../wlink_pair/pad_skid.sv` (a real file at 5,298 bytes).
  This change touches a `.sv` file in the cocotb tree so I did not make it
  unilaterally — it needs explicit authorization (the file is RTL-tree
  infrastructure even though its target is a cocotb-only stub).
- Each test executes ~8.5 ms of sim time (passive autocal sweep dominates).
  Wall-clock per test is roughly 5 minutes. All three tests in one run is
  roughly 15 minutes — within budget.
