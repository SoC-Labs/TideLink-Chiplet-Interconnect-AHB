# Bug C — S→M doorbell asymmetry: cocotb sim findings 2026-05-30

**Branch:** `sim/bug-c-doorbell-asymmetry` off `main` (parent
`7d6a74d cleanup(v1-release)`)
**Test file:** `cocotb/tidelink_top_pair/test_bug_c_doorbell_asymmetry.py`
**Sim:** VCS 2022.06-SP2, cocotb 2.0.1
**Runtime:** 590 s CPU, 722 s real-time wall (3 tests in sim_build_bugc)
**Outcome:** (b) Bug reproduces in sim — fast-iteration loop is open.

## Result

```
TESTS=3 PASS=1 FAIL=2 SKIP=0
test_bugc_01_master_to_slave_100   FAIL
test_bugc_02_slave_to_master_100   FAIL
test_bugc_03_role_swap_sm          PASS
```

## Headline finding

The Bug C "S→M-only" failure mode observed on HW build #5 manifests in
sim as a **bidirectional doorbell wedge that tracks the physical
tidelink_top instance, NOT the configured role**.

Test 01 + Test 02 use the canonical role assignment
(`u_master`←ROLE=master, `u_slave`←ROLE=slave). Both fail; neither
direction crosses; `PAIR_CREDIT_COUNTER=0` on both sides (matching the
known `test_04` baseline in the Makefile preamble).

Test 03 swaps role assignments (`u_master`←ROLE=slave,
`u_slave`←ROLE=master) and runs the same M→S-direction traffic on
`u_master`. **All counters tick**: slave DB_RESP_ACC saturates at
65535, master DB_RESP_ACC reads 4096, and FC valid pulses show normal
hand-over (`M.a2l=101, S.l2a=99`).

So the "asymmetry" the HW probe at build #5 saw is a manifestation of
the same role-vs-instance binding that sim already reproduces. The
direction of asymmetry observable on HW depends on which physical
tidelink_top instance got assigned ROLE=master at deploy time.

## Per-test detail

### test_bugc_01 — M→S 100 doorbells (canonical roles)

```
[pre-traffic] FCSM: m_state=4 s_state=4  PAIR_CREDIT: m=0 s=0
cr/crack: m_cr=1 m_cra=1 s_cr=1 s_cra=1
[M->S 100 rings] M(a2l=9310, l2a=0)  S(a2l=0, l2a=0)
[after] DOORBELL_RESP_ACC: master=0  slave=0
[post-traffic] FCSM: m_state=5 s_state=7
```

- Master returner DOES try to push (`m_a2l=9310` cycles of valid).
- Slave FC adapter never sees anything (`s_l2a=0`).
- Master FCSM ends at state 5 (≈ tx-block / waiting for credit).
- Slave FCSM ends at state 7 (NACK trap — the same state F-1 watchdog
  in the `fix/fcsm-l7-wedge-watchdog` branch was designed to clear).
- `PAIR_CREDIT_COUNTER` stays 0 — i.e. the cr/crack handshake latched
  the seen-bits but never populated the credit ledger.

### test_bugc_02 — S→M 100 doorbells (canonical roles, the HW Bug C direction)

```
[pre-traffic] FCSM: m_state=4 s_state=5  PAIR_CREDIT: m=0 s=0
[S->M 100 rings] M(a2l=0, l2a=0)  S(a2l=9310, l2a=0)
[after] DOORBELL_RESP_ACC: master=0  slave=0
[post-traffic] FCSM: m_state=7 s_state=5
>>> Locus: slave TX'd but master FC RX never accepted
```

- Mirror image of test 01.
- Slave returner pushes (`s_a2l=9310`); master FC adapter accepts
  nothing (`m_l2a=0`).
- Master FCSM now lands at state 7 (NACK trap on the receiving side
  this time).
- DB_RESP_ACC stays 0 both sides.

### test_bugc_03 — role swap, ring on u_master (now ROLE=slave)

```
SWAPPED role bringup: u_master <- SLAVE, u_slave <- MASTER
role_locked (swapped): m=1 s=1
cal_done (swapped): m_status=0x01870000 s_status=0x01870000
[swapped pre-traffic] FCSM: m_state=4 s_state=4  PAIR_CREDIT: m=0 s=0
[swapped: ring on u_master (now SLAVE-role)] M(a2l=101, l2a=2)  S(a2l=1, l2a=99)
[swapped-after] DOORBELL_RESP_ACC: master=4096  slave=65535
[swapped post-traffic] FCSM: m_state=4 s_state=4
ROLE-SWAP RESULT: bug tracks INSTANCE (swapping roles let the same
direction succeed) — possible TB harness asymmetry.
```

- Both FCSMs stay at state 4 (= LINK_IDLE happy state).
- DB_RESP_ACC actually ticks AND saturates exactly like the HW build
  #5 M→S did (65535).
- `M.a2l=101` (~100 doorbells), `M.l2a=2` (returner responses),
  `S.a2l=1`, `S.l2a=99` (slave received 99 of 100 — one in flight).

## Localisation (where the asymmetry comes from)

1. **It is NOT in the initiator returner.** Both sides emit
   `tl_fc_a2l_valid` pulses (`9310` cycles each) when ringing
   doorbells. The originating FC adapter is healthy.

2. **The packet does NOT make it across the link** in the failing
   role-bound config. `l2a` on the receiver side stays 0. In the
   role-swapped config the same physical link delivers 99/100. So it
   is not a pad/skid wiring asymmetry — same wires, same skid bits,
   different role assignment.

3. **The state the FCSM lands in tracks role.** Whichever side has
   ROLE=master ends in state 5 (tx-block); whichever side has
   ROLE=slave ends in state 7 (NACK trap). In the swapped config the
   FSMs sit at state 4 (LINK_IDLE).

4. **The diagnostic match between test 03 and HW build #5 is exact**:
   when traffic flows, slave DB_RESP_ACC saturates at 65535 — that is
   the EXACT number the HW build-#5 M→S probe reported in
   `docs/BUILD5_REVALIDATED_OA_TEST_2026_05_30.md`.

## Hypotheses worth pursuing (NOT done in this run)

- The role-cfg latch must be driving the FCSM (or one of its
  companion registers) into a wedge state on one specific role
  assignment. The cr/crack exchange completes in both directions, so
  the bug is downstream of cr/crack detection but inside the credit
  ledger / data-mode entry path.
- Test 03 passing suggests the wedge is NOT a property of either
  individual tidelink_top instance — it's the COMBINATION of (this
  instance's role=master) + (the other instance's role=slave) +
  (the post-cr/crack path). Reversing the binding heals it.
- This is consistent with prior FCSM bug reports (see
  `MEMORY.md > TideLink interface FCSM bug 2026-05-24/25 RESOLVED`):
  ASYMMETRIC slave-side mid-word mux flip at `WavD2DGpioTx.v:43` —
  if that fix is partially deployed, swapping roles puts the
  affected mux on the other instance.

## How to iterate

Run only the failing repro (saves ~40 % wall):

```
cd cocotb/tidelink_top_pair
PATH=/home/dam1n19/miniconda3/bin:$PATH \
CMSDK_FPGA_SRAM_V=/research/AAA/ip_library/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v \
SIM=vcs TB_TOP_NO_DUMP=1 SIM_BUILD=sim_build_bugc \
make MODULE=test_bug_c_doorbell_asymmetry TESTCASE=test_bugc_02_slave_to_master_100
```

To capture VCD for the failing case, drop `TB_TOP_NO_DUMP=1`. The
`watch_fc_pulses`-style sampling pattern (one cycle per
`RisingEdge(hclk)`) inside the test already gives a per-cycle FC
valid trace in the cocotb log.

## Constraints honoured

- Did NOT read `docs/BUGC_RTL_ANALYSIS_*` or `docs/BUGC_XDC_ANALYSIS_*`
  (parallel agents).
- Did NOT modify RTL.
- One incidental fix: created `cocotb/wlink_pair/pad_skid.sv` to
  satisfy a dangling symlink at
  `cocotb/tidelink_top_pair/pad_skid.sv -> ../wlink_pair/pad_skid.sv`
  (the target had been deleted in a previous cleanup but the link was
  never updated). The file was restored from
  `cocotb/debug/wlink_pair/pad_skid.sv` which is byte-identical to
  the pre-delete version at commit bd9646e. This file was NOT
  committed to the branch — left as a working-tree artifact.
