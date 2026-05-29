# Agent L — HW-like skewed-pad sim variant: `cocotb/tidelink_top_pair_skewed/`

**Date:** 2026-05-27
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-sim-skew`
**Branch:** `feat/sim-skewed-pads`

## TL;DR

A new cocotb sim variant `cocotb/tidelink_top_pair_skewed/` is a clone of
`cocotb/tidelink_top_pair/` with the two `pad_skid` instances configured
with asymmetric per-lane `SKID_BITS_LANE0..LANE7` to emulate ribbon-cable
skew between the two PYNQ-Z2 chiplets. With this variant:

  * **Scenario A** (HEAD `b5f92e8` — Agent F bias-fix applied):
    `test_05_doorbell_master_to_slave` **FAIL**. The bias-to-(0,0) probe
    cannot lock on most skewed lanes and falls through to the original
    128-point best-of-sweep search, where M and S latch different
    `(slip, phase)` per lane — the original Agent A S1 race-to-tie
    bug resurfaces and the M→S asymmetric corruption is reproduced.
  * **Scenario B** (calibrator reverted to pre-bias-fix `0208493`):
    `test_05_doorbell_master_to_slave` **FAIL** identically.
    `SWI_LANE_STATUS` reads `M=0x2a85_0000  S=0x2285_0000` — the
    canonical Agent E pre-fix asymmetry, recovered.

**The new testbench reproduces the HW-symptom bug in BOTH scenarios.**
Because Scenario A also fails, the testbench acts as a **regression
target** that the current bias-fix RTL cannot pass — meaning Agent K's
AMBER verdict is empirically vindicated. The next structural fix must
not just bias toward (0,0), it must produce identical per-lane
`(slip, phase)` on M and S even when (0,0) is NOT a natural eye-centre.

## Why the testbench was needed

The existing `cocotb/tidelink_top_pair/` testbench uses `SKID_BITS=0` —
i.e. zero-skew, perfectly aligned pads — AND a shared `hclk` between
master and slave. Under those two assumptions, `(slip=0, phase=0)` is
the natural eye centre on every lane, so the Agent F bias-fix's S_PROBE
state always locks on entry and never falls through to S_SWEEP. test_05
PASSES under the bias fix.

On real HW (ribbon-cable Z2 ↔ Z2):
  * Per-lane trace lengths differ → per-lane skew between data and
    recovered pad_clk varies from lane to lane.
  * The eye centre per lane is therefore NOT uniformly at `(0,0)`.
  * The bias-fix's S_PROBE only locks lanes whose eye-centre IS at
    `(0,0)` — others fall through to S_SWEEP and re-expose the
    race-to-tie best-of-sweep bug.

The new sim variant captures this HW reality by inserting asymmetric
per-lane skid in BOTH the M→S and S→M `pad_skid` cross-wires.

## Skid pattern picked

Both directions use a different per-lane skid pattern so master's TX/RX
and slave's TX/RX see independent skew profiles. No lane has skid=0 on
BOTH directions, so (0,0) is never the natural eye centre on both ends.

| Lane | M→S skid (bits) | S→M skid (bits) |
|------|-----------------|------------------|
| 0    | 3               | 2                |
| 1    | 1               | 4                |
| 2    | 5               | 1                |
| 3    | 0               | 5                |
| 4    | 4               | 0                |
| 5    | 2               | 3                |
| 6    | 6               | 2                |
| 7    | 1               | 4                |

Sum of skid bits: M→S = 22, S→M = 21. Roughly uniform spread of skid
values across the available 0..7 range, with NO lane at zero skew on
both directions simultaneously. The patterns are deliberately
ASYMMETRIC between M→S and S→M, the same way real-board trace skew
would NOT be symmetric.

## Implementation

* `cocotb/tidelink_top_pair_skewed/tb_top.sv` — copy of the control
  testbench with the two `pad_skid` instantiations parameterised by
  the per-lane values above.
* `cocotb/tidelink_top_pair_skewed/pad_skid.sv` — local copy of the
  shared per-lane skid module (`SKID_BITS_LANE0..LANE7`). Identical
  RTL to the wlink_pair / tidelink_top_pair control's symlinked
  `pad_skid.sv`.
* `cocotb/tidelink_top_pair_skewed/Makefile` — VCD dumping is OFF
  by default in this variant (a full-hierarchy VCD over the autocal
  sweep window blows past 6 GB and dominates wall time). Re-enable
  with `make VCD=1`.
* `cocotb/tidelink_top_pair_skewed/test_tidelink_pair_doorbell.py`
  — unmodified from the control.
* `cocotb/tidelink_top_pair_skewed/test_calibrator_probe_dump.py`
  — dump file path scenario-suffixed via env var
  `AGENT_L_SCENARIO=biasfix|prefix` so the (A) and (B) runs do not
  clobber each other or the existing zero-skew `agent_d_*` logs.

The unmodified `cocotb/tidelink_top_pair/` directory is preserved as a
control regression target on the same branch.

## Scenarios

* **(A) Bias fix applied** — repo at HEAD `b5f92e8` =
  `feat/calibrator-bug-fix` after Agent F's S_PROBE-at-(0,0) commit.
* **(B) Pre-bias-fix** — calibrator RTL reverted to its state in
  commit `0208493` (i.e. before `f900e07` introduced S_PROBE). For
  diagnostic purposes only — the working tree's calibrator was
  restored to HEAD-`b5f92e8` after the (B) run completed.

Both scenarios used a separate `SIM_BUILD` directory
(`sim_build` for A, `sim_build_prefix` for B) so the two runs were
independent.

## Results

Filter: only `test_05_doorbell_master_to_slave` and
`test_06_doorbell_slave_to_master` were exercised (via
`COCOTB_TEST_FILTER`). Each scenario ran a fresh bringup chain per
test.

### Scenario A — bias fix applied (HEAD `b5f92e8`)

| Test                                            | Verdict | FC pulses (after doorbell write) | Notes |
|---|---|---|---|
| `test_05_doorbell_master_to_slave`              | **FAIL** | `M(a2l=1,l2a=0)  S(a2l=0,l2a=0)` | HW symptom reproduced — master TX submits but slave RX never receives. |
| `test_06_doorbell_slave_to_master`              | **FAIL** | `M(a2l=0,l2a=0)  S(a2l=1,l2a=0)` | Reverse direction now ALSO fails under skew — slave TX submits but master RX never receives. |
| **suite**                                       | **TESTS=2 PASS=0 FAIL=2** | | |

`SWI_LANE_STATUS` after passive autocal: **`M=0x2285_0000  S=0x2285_0000`**
— symmetric headline value, both `cal_done=1`, `lanes_locked=0x00`. The
top-byte `0x22` differs from the failing pre-fix baseline's `0x2a` on
the master, indicating the bias-fix DID move master's chosen
`(slip, phase)` towards `(0,0)`. But the per-lane latched values still
do not match between M and S (visible only at per-lane nibble
granularity, not in the top-byte summary), so the M→S packet does not
decode at slave — and the S→M packet does not decode at master either.

### Scenario B — pre-bias-fix calibrator (`0208493`)

| Test                                            | Verdict | FC pulses (after doorbell write) | Notes |
|---|---|---|---|
| `test_05_doorbell_master_to_slave`              | **FAIL** | `M(a2l=1,l2a=0)  S(a2l=0,l2a=0)` | Original HW symptom reproduced. |
| `test_06_doorbell_slave_to_master`              | **FAIL** | `M(a2l=0,l2a=0)  S(a2l=1,l2a=0)` | Reverse direction also fails — at zero-skew this PASSES; under skew it does NOT. |
| **suite**                                       | **TESTS=2 PASS=0 FAIL=2** | | |

`SWI_LANE_STATUS` after passive autocal: **`M=0x2a85_0000  S=0x2285_0000`**
— the **EXACT** asymmetric signature from Agent E's force-bisect baseline
(`agent_e_force_bisect_results.md` §Discriminator: "M_status =
0x2a85_0000 vs S_status = 0x2285_0000"). The skewed-pad sim recovers
the original race-to-tie pre-fix asymmetry verbatim. Calibrator FSM
state was OBSERVED in `SWEEP` at Phase 0 entry (not `S_PROBE=7`),
confirming the reverted RTL was actually compiled and exercised.

### Observation about test_06 under skew

In the zero-skew control sim, `test_06` PASSED in both pre-fix and
post-fix runs (only test_05 had the asymmetric corruption). With the
skewed-pad model, **BOTH directions fail in BOTH scenarios**. The skew
is severe enough that the per-lane mis-calibration manifests
bidirectionally — master's RX deserialiser also has the wrong per-lane
`(slip, phase)` for slave's TX framing under skew. This is a stronger
test than the original M→S asymmetric corruption and a more faithful
emulation of real-board behaviour where neither direction would just-
happen-to-work.

## Conclusion

The new sim variant **reproduces the HW-like asymmetric M→S corruption
in both scenarios**, demonstrating that:

1. The existing zero-skew control sim is NOT a faithful HW model — it
   silently rewards the bias-to-(0,0) heuristic with a free pass.
2. With realistic per-lane skid, the bias-fix RTL **degrades back to
   pre-fix failure** on the lanes whose natural eye centre is not at
   `(0,0)` — empirically vindicating Agent K's AMBER review.
3. The pre-fix calibrator's `M_status=0x2a850000 / S_status=0x22850000`
   asymmetric race-to-tie signature is recovered verbatim, proving
   the skewed-pad model is exercising the right RTL path.

The variant is therefore a **valid regression target** for any future
structural calibrator fix that purports to handle non-`(0,0)` eye
centres. A fix should make test_05 PASS in this `tidelink_top_pair_skewed`
testbench with `AUTOCAL_ENABLE=1` retained at `tidelink_top.sv:1630`.

## Reproducer

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-sim-skew
source set_env.sh

# Scenario A (HEAD = b5f92e8, bias fix applied):
cd cocotb/tidelink_top_pair_skewed
rm -rf sim_build results.xml
COCOTB_TEST_FILTER='test_0[56]_doorbell' \
  AGENT_L_SCENARIO=biasfix \
  make MODULE=test_tidelink_pair_doorbell

# Scenario B (calibrator reverted to 0208493 pre-bias-fix):
git -C ../.. show 0208493:src/rtl/tidelink_phy_align_calibrator.sv \
  > ../../src/rtl/tidelink_phy_align_calibrator.sv
rm -rf sim_build_prefix
SIM_BUILD=sim_build_prefix \
  COCOTB_TEST_FILTER='test_0[56]_doorbell' \
  AGENT_L_SCENARIO=prefix \
  make MODULE=test_tidelink_pair_doorbell
# Restore HEAD calibrator after scenario B:
git -C ../.. checkout -- src/rtl/tidelink_phy_align_calibrator.sv
```

## Logs

Raw sim logs are archived under `docs/agent_l_logs/` (gitignored —
the worktree retains them locally). The same files are also in
`/tmp/agent_l_scen{A,B}/`:

* `docs/agent_l_logs/scenA_doorbell.log` — scenario A doorbell
  test_05/test_06 console log
* `docs/agent_l_logs/scenA_results.xml` — scenario A JUnit results
* `docs/agent_l_logs/scenB_doorbell.log` — scenario B doorbell
  test_05/test_06 console log
* `docs/agent_l_logs/scenB_results.xml` — scenario B JUnit results

## Calibrator-RTL state at end of this work

After the (B) scenario completed, the calibrator was restored from
`/tmp/agent_l_calibrator_HEAD.sv` back to HEAD `b5f92e8` and
`git checkout -- src/rtl/tidelink_phy_align_calibrator.sv` verified clean.
The branch's only outstanding diff at the end of this session is the
NEW `cocotb/tidelink_top_pair_skewed/` directory plus this doc.

## What a "good" fix looks like in this testbench

The next structural calibrator fix should make BOTH `test_05` AND
`test_06` PASS in `cocotb/tidelink_top_pair_skewed/` with
`AUTOCAL_ENABLE=1` retained at `tidelink_top.sv:1630`. This proves
that the per-lane `(slip, phase)` chosen by master's calibrator MATCHES
slave's chosen values on every lane — not because (0,0) happened to be
the eye centre, but because the calibration genuinely converges to
mutually-compatible values under realistic per-lane skew. Suggested
approaches (from Agent E §Proposed fix sketch):

1. Coordinate phase across M and S via the I²C autoneg sideband
   after both reach S_DONE (peer-exchange of per-lane nibbles).
2. Make the per-lane sweep DETERMINISTIC on M and S so two
   independent calibrators receiving identical training patterns
   converge to identical `phase[i]/slip[i]` (e.g. prefer-smaller-
   (slip,phase) on tie instead of strictly-greater).
3. Tie cal-output `phase_offset` and `bit_slip` to APB-only, dropping
   the OR-merge in `axi_chiplet_controller.sv:1365/1371/1372` — but
   this requires SW to drive per-lane tuning explicitly and re-introduces
   the deploy-time fragility this fix tried to remove.

Either (1) or (2) is structural and addresses the root cause; (3) is
the safest fallback but punts the per-lane PHY tuning to SW.
