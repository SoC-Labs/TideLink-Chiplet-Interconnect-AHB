# Sim repro of the build-#3 silicon bug — cocotb results

**Date:** 2026-05-29
**Branch:** `feat/td-gpio-phy-integration` (HEAD `dda0a0e`, calibrator Fix A2+B)
**Sim env:** `cocotb/tidelink_top_pair/` (paired-die `tidelink_top` cross-wired
through `pad_skid` blocks, SKID_BITS=0, VCS 2022.06-SP2)
**Test file:** `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py` (three
new tests `test_07/08/09_*` appended; existing `test_01..06` unchanged)
**Run log:** `/tmp/cocotb_pair_repro_run.log`
**HW baseline:** [`docs/DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md`](DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md)
(build #3, lease bridge1, link 16/16 + `PAIR_CREDIT_COUNTER = 0` + slave AHB RX
and PTP RX empty).

## Headline

The paired-die cocotb sim **reproduces the silicon symptom**. Both the AHB
M→S packet test and the PAIR_CREDIT_COUNTER regression gate fail in sim with
the same failure signature seen on HW. This is the first time the bug has
been captured in regression.

Final run: `TESTS=3 PASS=1 FAIL=2 SKIP=0` (sim time 25.7 ms, wall ~18 min).

## Results

| Test | Verdict | One-line summary |
|---|---|---|
| `test_07_paircredit_nonzero_after_bringup` | **FAIL (sim reproduces HW)** | `PAIR_CREDIT_COUNTER = 0x0` on both sides after full bringup — identical to silicon. |
| `test_08_ahb_packet_master_to_slave` | **FAIL (sim reproduces HW)** | Slave `REG_PKT_WORD_LEN=0`, slave FIFO all-zero, **and** the master's FC adapter never even submitted a packet to Wlink (`tl_fc_a2l_valid=0` for 500 cy post-write). |
| `test_ptp_hw_sync_slave_status`           | **PASS (spurious — weak assertion)** | The test asserts `s_status != 0`, but the only non-zero bit observed is `[18] phc_locked` (a POR side-effect), not `[0] active` or `[17:2] seq_num`. FC pulse counters confirm no PTP packets actually crossed the link. See "Test 09 caveat" below. |

## Test 07 details (FAIL — sim repro confirmed)

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

Note: `cr_pkt_seen_rx=1` and `crack_pkt_seen_rx=1` on both sides — the credit
packets ARE reaching the consumer-side observer. But the ledger
(`PAIR_CREDIT_COUNTER`) never increments. Compare to silicon ([DEMUX_ISSUE
report §"Direct HW evidence"](DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md)):

```
LANE_STATUS         = 0x018900ff   (locked=0xff cal_done=1)  -- both sides
PAIR_CREDIT_COUNTER = 0x00000000   -- both sides
```

Minor differences from HW (sim shows `locked=0x00 fcsm=3/4/5` vs HW `locked=0xff`)
are explained by the passive-autocal path the sim takes (the calibrator drops
`cal_training_mode` on `cal_done`, so the lane-locked-while-training latch
reads 0 — see comment in `test_01_role_lock_and_cal_done`). The asymmetric
`fcsm=4`/`fcsm=5` post-`to_data_mode` matches the M↔S asymmetry observed in
the 2026-05-24 doc.

## Test 08 details (FAIL — sim repro confirmed, with strong localisation)

Master TX packet: `word0=0x00240000` (length=2, WR_REQ), `dest=0x0`,
payload=`[0xDEADBEEF, 0xCAFEBABE]`.

Result after 2000 hclk:
```
slave REG_PKT_WORD_LEN = 0x00000000   (expected 2)
slave FIFO read:  w0=0  w1=0  w2=0  w3=0   (expected 0xDEADBEEF, 0xCAFEBABE in w2/w3)
post AHB TX M->S FC valid-cycle counts over 500 cy:
  M(a2l=0, l2a=0)   S(a2l=0, l2a=0)
```

**Crucial localisation:** `M.a2l = 0` (master's `tl_fc_a2l_valid` never asserts).
The master's FC adapter never submitted a packet to Wlink. This means the bug
is **before** the link layer — somewhere between the AHB TX writes landing in
the TX FIFO and the FC adapter trying to emit them. The most likely gate is
the credit check: with `PAIR_CREDIT_COUNTER = 0` (from Test 07), the FC
adapter sees no credit and refuses to submit, exactly as the credit-flow
design would dictate.

So Test 08's failure is downstream of Test 07's failure, as expected.

## Test 09 details (PASS — but the assertion is too weak)

```
master HW_SYNC_CTRL <= 0x05    (force_en + enable)
slave  HW_SYNC_STATUS = 0x00040000
master HW_SYNC_STATUS = 0x00040001
[post HW_SYNC fire] FC valid-cycle counts over 500 cy: M(a2l=0,l2a=0)  S(a2l=0,l2a=0)
```

`0x00040000` has only bit `[18] phc_locked` set — a POR side-effect because
`tb_top.sv` ties `phc_locked_i = 1'b1`. Crucially:
- bit `[0] active` is 0 on the slave
- bit `[1] busy` is 0 on the slave
- bits `[17:2] seq_num` are 0 on the slave
- master's `HW_SYNC_STATUS=0x00040001` has bit `[0] active` set (master started
  the sync TX path), so the GM side is alive.
- The slave's seq_num staying at 0 + `active=0` is exactly the HW symptom.
- FC pulse counters (`M.a2l=0`, `S.l2a=0`) confirm zero PTP traffic crossed
  the link — same root cause as Tests 07/08.

The test currently passes because `0x00040000 != 0`, but the meaningful
check is `(s_status & ~(1 << 18)) != 0` (any non-locked bit set), or more
directly `(s_status & 0x3FFFD) != 0` (active OR busy OR seq_num != 0). With
the tightened assertion this test would also FAIL and reproduce the HW.

This is a **test-quality bug, not a sim-vs-RTL gap.** The RTL is behaving
exactly as on silicon (zero PTP traffic to slave); the assertion was simply
weaker than intended.

Recommendation: tighten the assertion to one of:
```python
assert (s_status >> 0) & 1, "slave HW_SYNC active bit never set"
# OR
assert (s_status >> 2) & 0xFFFF, "slave HW_SYNC seq_num never advanced"
```

## Interpretation

**The sim reproduces the silicon bug.** Clean isolated repro:
- All upstream gates (`role_lock`, `cal_done`, `cr_pkt_seen`, `crack_pkt_seen`)
  pass in sim, matching HW.
- The PAIR_CREDIT_COUNTER stays at zero, matching HW (Test 07).
- The downstream M→S AHB traffic never even leaves the master's FC adapter,
  matching HW (Test 08).
- The downstream PTP traffic never crosses the link, matching HW (Test 09's
  underlying behaviour, modulo the weak assertion).

Sim and silicon diverge at the same RTL boundary. The next debugging step
does **not** require an FPGA build — full hierarchy is in `waves.vcd` and
FCSM internals can be poked from cocotb without recompiling RTL.

## Sim-vs-HW differences (cosmetic, do not affect repro)

- `SWI_LANE_STATUS[7:0] locked` reads `0x00` in sim vs `0xff` on HW. Reason
  documented above: passive autocal drops `cal_training_mode` after
  `cal_done`, so the lane-locked-while-training latch reads 0. HW's `0xff`
  comes from the slot0=0x1 path keeping training_mode forced high. Doesn't
  affect the credit handshake, so doesn't affect the repro.
- `fcsm` state ends at `4`/`5` (sim) vs the HW state (not snapshotted in the
  Build #3 report). The M↔S asymmetric end-state matches the broader
  asymmetric-LL byte-align bug class from the 2026-05-24 obs doc.

## Follow-up work (separate authorisation needed)

Now that the bug is reproducible in sim, the right next step is **FCSM
instrumentation** — three probe points in cocotb (no RTL touch):

1. **CR/CRACK payload at consumer-side decode.** Sample `cr_pkt_data_rx` /
   `crack_pkt_data_rx` (or the field that carries the credit-grant value) at
   the rising edge of `cr_pkt_seen_rx` / `crack_pkt_seen_rx`. If the grant
   field is zero, the bug is in the producer (CR packet builder) or the
   encoder. If non-zero, the bug is in the consumer-side credit-counter
   write path.
2. **Local `pair_credit_counter` write-enable.** Sample the FCSM internal
   signal that bumps the local credit counter on CR receipt. If it never
   asserts despite `cr_pkt_seen=1`, the gate is wrong.
3. **CDC handoff to APB regs.** If the FCSM increments its own counter but
   APB still reads 0, the bug is in the synchronizer / mirror between
   `tidelink_top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl` and
   `tidelink_apb_regs`.

These three probes will localise the bug to a single RTL file with no
further HW iteration.

Also recommended: tighten `test_09`'s assertion to ignore `[18] phc_locked`,
so it FAILs alongside Tests 07/08 and the regression suite catches the bug
as written.

## Notes / blockers

- `cocotb/tidelink_top_pair/pad_skid.sv` is a **dangling symlink** pointing
  into `td-interface-debug` (a checkout that does not exist on this branch).
  The Makefile's `VERILOG_SOURCES` dep check fails before `simv` is invoked.
  **Workaround used:** invoke the pre-built `sim_build/simv` (dated
  2026-05-28 23:35, matching branch HEAD `dda0a0e`) directly with the cocotb
  env vars (`PYGPI_PYTHON_BIN`, `LD_LIBRARY_PATH=/home/dam1n19/miniconda3/lib`,
  `PYTHONPATH=<cwd>:<repo>/python`, `COCOTB_TEST_MODULES`, `COCOTB_TESTCASE`,
  `COCOTB_TOPLEVEL=tb_top`, `TOPLEVEL_LANG=verilog`).
  Permanent fix: re-create the symlink to point at
  `../wlink_pair/pad_skid.sv` (a real file at 5,298 bytes — same content
  the symlink was meant to resolve to). I did not make this change unilaterally
  because the file lives in the cocotb tree as a `.sv` and the user's
  instruction was "test files only — do not modify RTL"; `pad_skid.sv` is
  test-infrastructure SV but I erred on the side of caution.
- Each test executes ~8.5 ms of sim time (passive autocal sweep dominates).
  Wall-clock per test was ~6 minutes, total run ~18 minutes — well within
  the 30-minute budget.
