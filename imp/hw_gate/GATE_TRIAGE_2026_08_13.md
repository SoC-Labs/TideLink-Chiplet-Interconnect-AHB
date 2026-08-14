# sim_gate RED triage — 2026-08-13

**Repo:** `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink` (the off-repo clone)
**Branch:** `integ/tidelink-consolidated-2026-08-07`
**Gate stamp:** `d317c98242f9-dirty`
**Outcome:** **GREEN** — `RESULT: ALL SUITES PASS @ d317c98242f9-dirty`, 3 known-defect sentinels XFAIL (unchanged).
**Nothing was committed. No shipping RTL was modified. No sentinel was added, and no test was weakened or deleted.**

---

## Headline

All three assigned failures had **one shared root cause**, and it is **not a bug in
the DUT and not a bug that needs a sentinel**: the 2026-08-01 **RX-FIFO TWIN 3 fix**
split the FIFO controller's single shared packet-metadata tracker into independent
write-side and read-side registers, and **two testbenches were never re-pointed at
the new names**. Both are stale-probe failures. Both were fixed on the TESTBENCH
side, as instructed.

Along the way the triage turned up two further things worth more than the gate fix:

1. **TL-033 is already fixed in the shipping RTL** and the registry entry calling it
   `status: open` / `sim_test: none` is **stale**. Proven by A/B, not by inspection.
2. The **TL-033 non-vacuity instrument had silently rotted** — it was failing for the
   wrong reason, i.e. it was a red that proved nothing. Regenerated and re-proven.

The other 5 red lines in the on-disk run (`tc_pair_*`, `eth_*`) were **not** RTL
failures either — they are wrong `*_HOME` defaults in this clone's directory layout.
Explained and resolved below.

---

## The shared root cause

`src/rtl/fifo/tidelink_fifo_ctrl.sv`, RX-FIFO TWIN 3 fix (2026-08-01), landed in the
consolidation as `5fb4e7b`:

| pre-TWIN-3 (one shared register) | post-TWIN-3 (independent trackers) |
| --- | --- |
| `packet_active_r` | `write_packet_active_r` **+** `read_packet_active_r` |
| `packet_word_length_r` | `write_packet_word_length_r` **+** `read_packet_word_length_r` |
| `target_addr_r` | `write_target_addr_r` **+** `read_target_addr_r` |

The rename is **legitimate and correct** — it is the fix itself, not collateral. The
split closes a real defect: an inbound FC packet header arriving mid-drain clobbered
the in-progress read's own `read_target_addr_r`/length, because the FC-write-start
branch had no guard analogous to the AHB side's `ahb_pkt_start_ok`. The two sides are
genuinely independent by design (the RX FIFO's whole purpose is concurrent
"FC adapter RX writes + CPU reads").

Critically, the external port `packet_word_length` was **deliberately** re-mapped to
the **read** side (`tidelink_fifo_ctrl.sv:612`), with a comment explaining why: its
only external consumer is `tidelink_apb_regs.sv`'s `credit_delta_data_comb`, captured
"on each `read_complete`" — it is the returner-facing signal describing the packet
just **drained**. So the port still exists and still reads cleanly; it just answers a
different question now. **A stale probe against it returns 0 rather than erroring** —
which is exactly how failure #1/#2 disguised itself as a DUT problem.

I checked this both directions before touching either testbench: the rename is not
wrong, and neither testbench was papered over.

---

## Failure #3 — `fifo_rx_twin2` / `test_01_ahb_clear_write_is_noop`

### Root cause
Stale testbench reference. `cocotb/fifo_rx_twin2/test_fifo_rx_twin2.py:56` probed
`u_fifo_ctrl.packet_active_r`, which the TWIN-3 split removed. cocotb even named the
successor in the error text.

The testbench file is dated 2026-07-24; the split is 2026-08-01. The sibling suite
`cocotb/tidelink_fifo` **was** updated at the time (see `test_07`'s docstring:
*"RX-FIFO TWIN 3 FIX (2026-08-01): probes the internal write-side register
directly"*) — `fifo_rx_twin2` was missed, plausibly because the Makefile header marks
it `SUPERSEDED — DO NOT PROMOTE`.

### Disposition
**Fix the testbench.** This is a stale probe, not a broken rename. `test_00` and
`test_02` — the two tests that exercise the actual TWIN-2 datapath — passed
throughout; only the whitebox `packet_active` assertion died.

### What I changed
`cocotb/fifo_rx_twin2/test_fifo_rx_twin2.py` — the `packet_active()` helper only.
The faithful successor of a single shared "is a packet armed?" register is the **OR
of the two trackers**, so the assertion `packet_active(dut) == 0` keeps its exact
original meaning (and is strictly stronger than probing the write side alone). The
helper **falls back to the pre-split name** when the split registers are absent,
because `FIFO_SRC=unfixed` compiles the frozen pre-TWIN-3 `*.UNFIXED.sv` copies —
that is the negative control, and without the fallback `make ab` would report its red
as a stale-probe `AttributeError` instead of as the defect.

**No test logic, threshold, or assertion was relaxed.** The X/Z→0 behaviour of the
original helper is preserved.

### Evidence

Before:
```
   340.00ns WARNING  ...test_01_ahb_clear_write_is_noop tb_top.u_dut.u_fifo_ctrl contains no child object named packet_active_r
        AttributeError: tb_top.u_dut.u_fifo_ctrl contains no child object named packet_active_r. Did you mean: 'read_packet_active_r'?
** test_fifo_rx_twin2.test_01_ahb_clear_write_is_noop                FAIL         190.00           0.02       8674.03  **
** TESTS=3 PASS=2 FAIL=1 SKIP=0                                                   650.00           0.20       3303.45  **
fifo_rx_twin2                FAIL      6s d317c98242f9-dirty
```

After:
```
** test_fifo_rx_twin2.test_01_ahb_clear_write_is_noop                PASS         190.00           0.00      41099.42  **
** TESTS=3 PASS=3 FAIL=0 SKIP=0                                                   650.00           0.16       4013.87  **
fifo_rx_twin2                PASS      7s d317c98242f9-dirty
```

Non-vacuity re-proven (`make -C cocotb/fifo_rx_twin2 ab`) — the negative control
still has teeth:
```
=================== A: UNFIXED RTL (expect FAIL) ===================
  UNFIXED: 1/3 passed, 2 failed  ->  CORRECT (bug reproduced)
============= B: TREE (real shared RTL, expect PASS) ===============
  TREE:    3/3 passed, 0 failed  ->  CORRECT (fix holds in the tree)
```

### Note on gate scoring
`fifo_rx_twin2` is **not** in `SIM_GATE_ALL_SUITES` — the aggregate invokes it
(`Makefile:1464`) and records a `.status`, but the summary scores only the
tree-truthful replacement `fifo_rx_twin2_tree` (which passed all along). So this
failure printed a red line in the run **without** contributing to `SIM_GATE_EXIT=2`.
It was still worth fixing: an unscored permanent red is exactly the rot the sentinel
contract in this Makefile is written to prevent.

---

## Failures #1 / #2 — `fifo_rx_phantom_pop` and `fifo_rx_randinit` / `test_43`

Both suites are the same 43-test module (`cocotb/tidelink_fifo`), the second under
adversarial `TIDELINK_SRAM_RAND_INIT`. Both failed the same test for the same reason.

### Root cause
**Also a stale probe — and the failure was in the test's own PRECONDITION, not in its
credit assertion.** `test_tidelink_fifo.py:1913` read
`dut.u_dut.packet_word_length`, which post-TWIN-3 maps to the **read**-side register,
while the test arms the **write** side:

```
2143440.04ns WARNING ..dit_underflow_saturates_whitebox precondition: header length capture failed (got 0, want 8)
   File ".../cocotb/tidelink_fifo/test_tidelink_fifo.py", line 1914, in test_43_credit_underflow_saturates_whitebox
     assert captured_len == L, \
 AssertionError: precondition: header length capture failed (got 0, want 8)
```

`got 0` — not a wrapped credit counter, not a large value. **The credit assertions
were never reached.** The test aborted 300ns before the underflow event it exists to
observe.

### Was this written in advance of the TL-033 fix, or did it regress?
**Neither, exactly — and this matters for the disposition.** Answering the question
as asked, from history:

- `test_43` landed **2026-08-10** in `c4f9f9e` (*"wip(consolidation): drain the trunk
  worktree — 08-09/08-10 test work"*).
- `git show c4f9f9e:src/rtl/fifo/tidelink_fifo_ctrl.sv | grep -c write_packet_word_length_r` → **0**.
  The TWIN-3 split was **not** in the tree on that line.
- `git merge-base --is-ancestor 5fb4e7b c4f9f9e` → **NO**. The TWIN-3 split
  (`5fb4e7b`) and `test_43` (`c4f9f9e`) came from **two different worktrees** and
  first met in the 08-10 consolidation.

So `test_43` **passed on the worktree it was authored on** (where `packet_word_length`
*was* the shared write-side register) and was **broken by the merge** that folded in
the other worktree's TWIN-3 rename. It is a **consolidation merge artifact** — a
regression, but of the testbench, not of the RTL, and not a test documenting an open
bug.

### Disposition
**Fix the testbench probe. Do NOT convert to an XFAIL sentinel.**

I want to be explicit that I considered the sentinel route and rejected it on
evidence. A sentinel would have been actively wrong here, twice over:

1. The test does not fail on the defect it names. It fails on its own setup. A
   sentinel signature matched against that would have locked in a *broken test* as
   "the documented defect, unchanged" — the precise failure mode the Makefile's own
   F14-B comment warns about (*"a comfortable XFAIL for the WRONG cause"*).
2. **The defect it documents is already fixed.** See below.

### What I changed
`cocotb/tidelink_fifo/test_tidelink_fifo.py` — one probe, line 1913, now
`u_fifo_ctrl.write_packet_word_length_r`. This is not an invention: it is the
convention the **same file** already uses in `test_07`, `test_39` and `test_40`, all
of which were updated at TWIN-3 time and all of which pass. The adjacent
`write_target_addr` probe needed no change (that port still maps to
`write_target_addr_r`). No assertion was touched.

### Evidence

Before (isolated repro, so it is not a cross-test pollution artifact):
```
** test_tidelink_fifo.test_43_credit_underflow_saturates_whitebox   FAIL         130.00           0.17        753.85  **
** TESTS=1 PASS=0 FAIL=1 SKIP=0                                                  130.00           0.22        584.32  **
```
Gate statuses before: `fifo_rx_phantom_pop FAIL 67s`, `fifo_rx_randinit FAIL 62s`.

After — the test now runs to completion and the credit assertions actually execute:
```
[TL-033] armed L=8 packet_delta=10; deposited credit_count_r=9 (< 10) => the consume MUST underflow
[TL-033] post-consume credit_count=0  (guard PASS=0 ; BUG-002 WRAP=8191=0x1FFF)
[TL-033] credit underflow SATURATED at 0 — guard proven (else-branch precondition hit; non-vacuous)
** test_tidelink_fifo.test_43_credit_underflow_saturates_whitebox       PASS         450.00           0.01      41271.69  **
```
Full suites, both configs:
```
fifo_rx_phantom_pop  ** TESTS=43 PASS=43 FAIL=0 SKIP=0 **     ->  PASS     64s d317c98242f9-dirty
fifo_rx_randinit     ** TESTS=43 PASS=43 FAIL=0 SKIP=0 **     ->  PASS     62s d317c98242f9-dirty
```

---

## Task C — TL-033: no patch is needed, because the fix already ships

**I did not write `imp/hw_gate/tl033/tl033_proposed.patch`, and I want to be direct
about why: writing one would have been fabricating a fix for a bug that is already
closed in RTL.** The task's precondition ("assess whether TL-033 is cheaply fixable:
guard/saturate the credit decrement so it cannot underflow") describes a change that
is **already present in `src/rtl/fifo/tidelink_fifo_ctrl.sv:443-449`**:

```systemverilog
    // BUG-002 fix: saturate at zero to prevent unsigned underflow wrap
    wire [RAM_ADDR_W-2:0] credit_after_write =
        write_complete
            ? ((credit_count_r >= (RAM_ADDR_W-1)'(write_packet_delta))
                ? credit_count_r - (RAM_ADDR_W-1)'(write_packet_delta)
                : '0)
            : credit_count_r;
```

Added **2026-04-06** in `ce2f2c9` (*"Fixing CDC issues, adding RTL fixes..."*) — four
months before the registry entry was written. `docs/BUG_REGISTRY.yaml` TL-033 was
**migrated verbatim from `docs/reference/SHORTCOMINGS.md` BUG-002**, and its claim
that credit "is decremented UNCONDITIONALLY on write_complete" describes RTL that no
longer exists. `status: open`, `sim_test: none`, `in_sim_gate: false` are all stale.

### The A/B that proves it (not inspection)

`cocotb/tidelink_fifo/run_redgreen_tl033.sh` / `make noguard` already existed for
exactly this. Running it uncovered a second problem first:

**The non-vacuity instrument had rotted.** `tidelink_fifo_ctrl_noguard.sv` was a copy
of the **pre-TWIN-3** RTL, so the RED leg failed on `AttributeError:
write_packet_word_length_r` — a red for the wrong cause, i.e. a non-vacuity proof
that proved nothing. Captured in
`imp/hw_gate/tl033/03_ab_RED_noguard_STALE_INSTRUMENT_wrong_cause.log`.

I regenerated it from the current shipping RTL with **only** the guard removed
(`diff` confirms a single hunk delta) and added a staleness warning to its banner.
This is a test-only artifact, selected only by `tidelink_fifo_noguard.flist`; it is
never synthesised and never shipped.

With a sound instrument:

| leg | RTL | result |
| --- | --- | --- |
| **GREEN** | shipping `src/rtl/fifo/tidelink_fifo_ctrl.sv` | `post-consume credit_count=0` → **PASS** |
| **RED** | `tidelink_fifo_ctrl_noguard.sv` (guard removed) | `post-consume credit_count=8191` → **FAIL** |

```
GREEN: [TL-033] post-consume credit_count=0     (guard PASS=0 ; BUG-002 WRAP=8191=0x1FFF)   -> PASS
RED:   [TL-033] post-consume credit_count=8191  (guard PASS=0 ; BUG-002 WRAP=8191=0x1FFF)
       AssertionError: BUG-002 UNDERFLOW WRAP: credit_count=8191 (0x1FFF). credit 9 -
       packet_delta 10 underflowed the 13-bit counter instead of saturating.          -> FAIL
```

Non-vacuity precondition is asserted inside the test and was hit
(`credit_count_r=9 < packet_delta=10`), so the guard's `else` branch genuinely
executed. **TL-033's underflow-wrap is fixed, and is now non-vacuously gated** by
`sim_gate_fifo` + `sim_gate_fifo_randinit` (two independent SRAM init configs).

### Netlist impact
**None from this work.** No RTL changed, so no rebuild is required and no HW claim is
affected. (Had a patch been needed it would have been netlist-affecting per the
registry — recording that for the reader, not as a live caveat.)

### What genuinely remains open under TL-033
The registry's fix approach has two clauses. The first (saturate) ships. The second —
**"flag an oversize packet"** — does **not**, and I am not closing it:

- `ahb_pkt_start_ok` gates admission on `credit_count_r >= MIN_PKT_CREDIT`, and
  `MIN_PKT_CREDIT` is **2** (the smallest legal header), *not* the packet's own
  length. A 100-word packet is therefore admitted with 3 credits available.
- The FC write path (`fc_write_addr0`) has **no** credit check at all.
- The sticky `overrun_r` flag fires only on `credit_count_r == '0'` at a valid beat,
  so the saturating case sets nothing. `test_32` already documents this in-line:
  *"the overrun flag checks credit_count == 0 per individual AHB beat, not whether
  the entire packet fits... overrun may not be set."*

So the counter no longer **wraps**, but an oversize packet is still accepted and the
accounting error is **silently absorbed** rather than reported. That is a real
residual and it is a different bug from the one TL-033's title names. I did **not**
write RTL for it: an admission check plus a sticky flag needs APB exposure to be
useful, which is netlist-affecting on a tapeout trunk and is not mine to land
unilaterally.

**Registry follow-up needed (I did not edit `docs/BUG_REGISTRY.yaml` — it already has
uncommitted changes from other in-flight work and I did not want to collide):**
1. Split TL-033. Mark the underflow-wrap half `sim_proven` with
   `sim_test: cocotb/tidelink_fifo test_43_credit_underflow_saturates_whitebox`,
   `in_sim_gate: true`, `commit: ce2f2c9`, and the red/green evidence below.
2. Re-file the oversize-packet admission/flag half as its own **open** entry with a
   title that matches what is actually broken.

Until (1) lands, `registry_coverage.py` will keep reporting TL-033 as an untested
open bug while two gate suites test it every run. Coverage currently reports
`HARD FAILURES: 0 / RESULT: COVERAGE OK`, with 3 pre-existing FIXED-but-ungated gaps
(TL-007, TL-026, TL-041) that are unrelated to this triage.

---

## The other 5 red lines — environment, not code

The on-disk 20:xx run had **8** reds, not 3. The other five were failing in ~0-1s:

```
tc_pair_smoke                FAIL      0s      sim_gate: MISSING DEPENDENCY /src/rtl/tidechart_shim.sv
tc_pair_election_datamode    FAIL      0s      sim_gate: MISSING DEPENDENCY /src/rtl/tidechart_shim.sv
eth_relay_m0                 FAIL      1s      sim_gate: MISSING DEPENDENCY /set_env.sh
eth_relay_m1                 FAIL      0s      sim_gate: MISSING DEPENDENCY /set_env.sh
eth_regs_shape_a             FAIL      0s      sim_gate: MISSING DEPENDENCY /set_env.sh
```

Root cause: the `*_HOME` defaults assume the **primary** repo's layout
(`/home/dam1n19/SoCLabs/tidelink`, with `nanosoc-ethernet-chiplet`, `tidechart` and
`nanoSoC-refactor` as **siblings**). In this clone tidelink is a **submodule of** the
chiplet, so `$(TIDELINK_HOME)/../nanosoc-ethernet-chiplet` and
`$(TIDELINK_HOME)/../nanoSoC-refactor/...` do not exist, `realpath` returns empty, and
the required path collapses to the bare suffix — which is exactly what the error
message shows. This is why the reference run described in the task saw ~39 PASS / 3
FAIL while this clone saw 8: those three suites are **not** comparable across the two
checkouts. `SIM_GATE_REQUIRE` behaved correctly; it declared a missing dependency
rather than faking a pass.

Correct invocation in this clone (**`TIDECHART_HOME`'s default is already right here** —
`../tidechart` resolves to the chiplet's own pinned submodule):

```bash
make sim_gate \
  CHIPLET_HOME=/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet \
  ETH_SS_HOME=/home/dam1n19/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb
```

All five then pass:
```
tc_pair_smoke                PASS      7s d317c98242f9-dirty
tc_pair_election_datamode    PASS      6s d317c98242f9-dirty
eth_relay_m0                 PASS     30s d317c98242f9-dirty
eth_relay_m1                 PASS     40s d317c98242f9-dirty
eth_regs_shape_a             PASS     45s d317c98242f9-dirty
```

### One caution, from my own mistake
My first attempt also overrode `TIDECHART_HOME=/home/dam1n19/SoCLabs/tidechart` (the
standalone dev clone). That made `tc_pair_*` fail *harder* — it compiled and then
errored:

```
Error-[UPIMI-E] Undefined port in module instantiation
/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/src/rtl/tidechart_shim.sv, 184
  Port "device_strap" is not defined in module 'tidechart_controller' defined
  in "/home/dam1n19/SoCLabs/tidechart/src/rtl/tidechart_controller.sv", 20
```

That is a real cross-repo fact worth recording: the chiplet shim has required
`tidechart_controller.device_strap` since chiplet commit `640b700` (2026-08-06, *"fix:
strap the root election"* — without it both dies can claim root), and the standalone
`/home/dam1n19/SoCLabs/tidechart` clone **does not have `device_strap` on any ref**
(`git log --all -S device_strap -- src/rtl` → empty; it sits on
`add-subtree-and-irqc-axis` @`b5102b2`). The chiplet's pinned submodule
(`nanosoc-ethernet-chiplet/tidechart` @`7a6dc35`) does. So **do not point
`TIDECHART_HOME` at the standalone clone** — and someone should check whether the
tidechart side of the 08-06 strap fix was ever landed upstream, or only exists inside
the chiplet's submodule.

---

## Final gate state

```
  gate stamp: d317c98242f9-dirty
  [52 blocking suites]              ALL PASS
-------------------------------------------------------
  KNOWN-DEFECT SENTINELS (XFAIL = defect present, UNCHANGED —
  this is NOT a pass; XCHG = behaviour changed, INVESTIGATE)
  xfail_f14b_datamode_wedge      XFAIL     55s d317c98242f9-dirty
  xfail_epoch_shipping_corrector XFAIL     35s d317c98242f9-dirty
  v2_mask_hs_regress             XFAIL    597s d317c98242f9-dirty
-------------------------------------------------------
  RESULT: ALL SUITES PASS @ d317c98242f9-dirty  (logs: imp/sim_gate/)
          (known defects still present as recorded)
```

`GATE_STAMP` is `<sha>-<dirty>` and is insensitive to *which* files are dirty, so the
re-run suites carry the same stamp as the rest of the cohort and the summary reports
no STALE/FOREIGN warnings. **Two caveats, stated plainly, and the second is serious.**

**Caveat 1 — it is a composite.** The untouched suites are from the 20:xx run; the 8
re-run suites are from ~21:30. Nothing in *this triage* can affect the others (no RTL
changed here).

**Caveat 2 — the working tree was being edited by another session while I worked, and
`GATE_STAMP` cannot see it.** These files changed mid-session and **I did not touch
any of them**:

```
2026-08-13 21:35  docs/BUG_REGISTRY.yaml
2026-08-13 21:44  src/rtl/tidelink_top.sv                          <-- shipping RTL
                  cocotb/tidelink_axi_datanode_recovery/Makefile
                  cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_writehold.py
                  cocotb/tidelink_axi_datanode_recovery/tidelink_fpga_v2_fcsm_local.flist
```

`ps` shows several concurrent Claude Code sessions on this host. `src/rtl/tidelink_top.sv`
was modified at **21:44 — after every suite in the cohort had already run**. Every
suite that compiles `tidelink_top.sv` (`v2_*`, `t3*`, `axi_datanode_*`, `eth_*`,
`tc_pair_*`) therefore holds a status that **predates the current contents of the
tree**. The FIFO suites do not compile it, so failures #1/#2/#3 and the TL-033 A/B are
unaffected — but **the green summary above must not be read as "the tree as it stands
right now is green."**

This also exposes a real limitation of the stamp mechanism, worth recording
independently of this triage: `GATE_STAMP = <sha>-<dirty>` collapses *all* dirty
states to the single token `dirty`, so a concurrent working-tree edit **cannot**
trip the STALE/FOREIGN check that exists precisely to stop a green summary being
claimed for code it did not run against. A content hash over the tracked-file diff
would close that hole.

**Required before this green is quoted anywhere:** re-run the aggregate end to end,
on a quiesced tree, with the two `*_HOME` overrides above.

---

## Files changed (working tree only — NOT committed)

| file | change |
| --- | --- |
| `cocotb/tidelink_fifo/test_tidelink_fifo.py` | `test_43` probe → `u_fifo_ctrl.write_packet_word_length_r` (post-TWIN-3 convention already used by `test_07`/`test_39`/`test_40`) |
| `cocotb/fifo_rx_twin2/test_fifo_rx_twin2.py` | `packet_active()` → OR of the split trackers, with pre-split fallback so the `unfixed` negative control still resolves |
| `cocotb/tidelink_fifo/tidelink_fifo_ctrl_noguard.sv` | regenerated from current shipping RTL, guard-removal as the only delta, staleness warning added |

**No file under `src/rtl/` was touched by this triage.** (`src/rtl/tidelink_top.sv`,
`src/rtl/local_overrides/*` and `docs/BUG_REGISTRY.yaml` show as modified — those are
pre-existing uncommitted changes from other work in this clone, present before this
triage started.)

Evidence logs: `imp/hw_gate/tl033/01..05_*.log`.

---

## Honest residue

- **Not resolved (deliberately):** the TL-033 oversize-packet admission/flag residual.
  Real, still open, netlist-affecting, needs David.
- **Not done (deliberately):** the `docs/BUG_REGISTRY.yaml` TL-033 correction. The
  file already carries other uncommitted edits and I did not want to collide with
  in-flight work. This is the highest-value follow-up here — the registry currently
  understates the RTL's health and overstates the bug.
- **Evidence lost:** re-running `sim_gate_fifo_randinit` overwrote its original
  failing log in place. The `.status` line (`FAIL 62s`) and the isolated repro
  (`imp/hw_gate/tl033/01_before_stale_probe_FAIL.log`) stand, and it failed the same
  `test_43` on the same probe, but the original full-suite log is gone.
- **Not verified:** whether the primary repo `/home/dam1n19/SoCLabs/tidelink` carries
  the same two stale probes. It almost certainly does (same branch), but I worked only
  in this clone as instructed and did not check.
- **Not attempted:** a full clean `make sim_gate` end-to-end run (~40 min). The green
  result above is a composite, as described.
- **Outside my control:** another session edited `src/rtl/tidelink_top.sv` at 21:44,
  after the whole cohort had run. See Caveat 2 above. The green summary is valid for
  the tree *as each suite ran against it*, not for the tree as it stands now. If this
  clone is meant to be a single-writer triage workspace, it currently is not.
