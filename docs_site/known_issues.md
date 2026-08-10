# Known Issues

TideLink tracks defects in a machine-readable registry, `docs/BUG_REGISTRY.yaml`,
rendered as a browsable page by `python3 scripts/gen_bug_registry_html.py`
(output `docs/bug_registry.html`; `python3 scripts/serve_bug_registry.py` serves a
live-reloading version).

This page is **not** a restatement of that registry. It is the registry's
self-reported fields checked against the tree, because an audit on 2026-08-10
found that the prose in the registry is honest while several of its
machine-readable verification fields are not survivable. Where the two disagree,
this page reports the audited state and says so.

:::{danger}
**Nothing on this branch is fixed.** Every verified fix lives on
`integ/tidelink-consolidated-2026-08-07`. On the checked-out branch
`fix/z2-drop-park-hook` (@`9eaafb7`) and on `main` (@`18491ef`),
`git grep -c wr_hold_r|synth_b_pending|ext_data_pend_r|mbox_reg_write_fc_only`
over `src/rtl` returns **0 files at HEAD** — no F-1/F-2 backstop, no Fix K, no
header-ECC restore, no PTP mailbox write-protect, no txgen hijack fix.

`docs/BUG_REGISTRY.yaml` is **not even tracked** on this branch
(`git ls-files --error-unmatch docs/BUG_REGISTRY.yaml` → *did you forget to git
add?*). A fresh clone of `main` or of this branch gets a TideLink with the fixes
missing **and** no bug registry at all.
:::

## The structural picture first

| Fact | Evidence (checked 2026-08-10) |
|---|---|
| `main` @`18491ef` is 95 commits behind the integ line | `git rev-list --count main..integ/tidelink-consolidated-2026-08-07` = 95 |
| This branch is **not** a descendant of `main` | fork point `328cec8`; `git rev-list --count fix/z2-drop-park-hook..main` = 12 |
| None of the 29 registry-cited fix SHAs is on `main` or on this branch | `git merge-base --is-ancestor <sha> main` false for all 29 |
| The registry file is untracked here; 17 entries on disk vs 34 committed on integ | `git ls-files`; `grep -c '^  - id: TL-'` |
| The live hardware line is a different checkout | `git cat-file -t 28409f5` → *fatal: Not a valid object name* |

That last row matters for every claim below: hardware from 2026-08-01 onwards ran
from `nanosoc-ethernet-chiplet/tidelink`, whose commits are not fetchable from
this repo. See {doc}`build_registry` for which bytes ran where.

## How to read the verification columns

The registry's own `status` field (`open` → `root_caused` → `fix_built` →
`sim_proven` → `hw_proven` → `signed_off`) describes intent. These three columns
describe what a fresh clone would actually get:

| Column | Means |
|---|---|
| **Sim test** | a reproduce-first cocotb/UVM test exists *and is tracked in git* |
| **Gated** | the suite is in `SIM_GATE_ALL_SUITES` **and** invoked by the `sim_gate` aggregate **in a commit** — not in a dirty worktree |
| **HW evidence** | a retained artefact on disk proves the hardware claim. Prose in a commit message, a tag body or a handover doc is **not** HW evidence |

*Verdict* is the audited disposition: **closed** (fix + committed gate + real
assertions), **sim-only**, **open**, or **overclaimed** (at least one
machine-readable field does not survive checking).

## Tracked bugs

*Registry says* is the `status` field as recorded on
`integ/tidelink-consolidated-2026-08-07` (34 committed entries, TL-001..TL-034;
TL-035 exists only as an uncommitted edit). Unless a row says otherwise, any fix
referred to exists **only** on that integ line — not on `main`, not here.

| ID | Title | Sev | Registry says | Sim test | Gated | HW evidence | Verdict |
|---|---|---|---|---|---|---|---|
| TL-001 | Peer-write DATA drop — calibrator framing lottery | rank-1 | root_caused | partial (transient deps mirror) | no | none retained | **open** — honest |
| TL-002 | Standalone-IP early HREADYOUT on peer write (`wr_hold_r`) | high | sim_proven | yes | yes | n/a | **partial** — only the ordering invariant runs; the data-landing test is `skip=True` |
| TL-003 | Fix K — XHB500 hazard-list BID write-wedge | high | hw_proven | yes (A/B pair) | yes | **no log retained** | **overclaimed** (HW half) |
| TL-004 | F-1 — recovery path drives illegal AHB ERROR | high | sim_proven | yes | yes | n/a | **closed (sim)**, integ only |
| TL-005 | F-2 — I5 backstop asserts but never restores | high | hw_proven | yes | yes | **no log retained** | sim closed; **HW overclaimed** |
| TL-006 | W-byte-0 header-ECC restore (`WlinkEccSyndrome`) | high | sim_proven | yes (6 tests) | yes | HW run FAILED (blocked by TL-009) | sim closed on integ; **structurally open here** — both flists on this branch point at the deps bypass |
| TL-007 | synth-B must emit OKAY, not SLVERR | high | hw_proven | **none named** (`pending_agent:2`) | no | none retained | **overclaimed** — the project's own `registry_coverage.py` flags it |
| TL-008 | txgen ownership-mux hijack (`ext_data_pend_r`) | high | hw_proven (here) | test file **untracked** here | integ yes; here the gate target is uncommitted | none | **overclaimed on this branch** |
| TL-009 | die_a PS wedge — per-write write-stall cascade | high | root_caused | none | no | 0x21F8 leak witness only | **open — dominant HW blocker** |
| TL-010 | PTP mailbox not read-only from APB | high | fix_built | test file **untracked** here | integ yes; phantom on a fresh clone | no | **partial/overclaimed**; the gated test is also single-sided |
| TL-011 | PHY BIST unwired on silicon | high | deferred | in `deps/tidelink-phy` only | no (`grep phy_bist Makefile` = 0) | no | **open tapeout risk**; this branch's registry calls it "(passes, unwired)" — the integ copy records 1 PASS / 10 FAIL |
| TL-012 | `_generate_xhb500` false success (pipefail) | high | fix_built | n/a | n/a | n/a | landed **integ only** |
| TL-013 | V1 flist missing obs modules | med | fix_built | n/a | n/a | n/a | landed **integ only** |
| TL-014 | Duplicate gpio-phy submodule | low | deferred | n/a | n/a | n/a | open — honest |
| TL-015 | Integration pins never landed on `main` | high | deferred | n/a | n/a | n/a | **open — this is the top-line risk** |
| TL-016 | SSH URLs in `.gitmodules` | med | fix_built | n/a | n/a | n/a | landed **integ only** |
| TL-017 | `tl_data_mode_o` downstream lint break | fyi | wontfix | n/a | n/a | n/a | closed |
| TL-018 | ASIC CRC-on vs FPGA CRC-off never co-run | med | root_caused | none | no | no | **open and understated** — see [CRC](#the-axi-channels-ship-with-crc-checking-off) |
| TL-019 | ASIC flist pins FCSM 0–4 to deps (no `socl_` recovery hooks) | high | root_caused | none | no | no | **open tapeout risk** |
| TL-020 | ASIC flist hygiene (obs modules / dup / a2l landmine) | high | sim_proven | 3 elab suites | yes (all PASS) | n/a | **closed (sim)** on integ |
| TL-021 | First-silicon obs gaps (Region D/F unreachable over I²C) | high | root_caused | none | no | no | open — honest, spec-ready |
| TL-022 | `rf_16k` RX FIFO never functionally simulated | med | sim_proven | yes (`make randinit`, 42/42) | yes | bound script cannot run on the named rig | sim closed; **`in_hw_gate` overclaimed** |
| TL-023 | `WavMultibitSync_18` raw-rptr slot-select ICG hazard | low | open | none | no | no | open — honest |
| TL-024 | FIX1/FIX2 regress 14 blocking suites | rank-1 | root_caused (ratified) | 12/14 fixed, 2 pinned | sentinel XFAIL | wrong vehicle (see below) | **partial** — weak HW binding |
| TL-025 | tc_pair `.device_strap` undefined port | med | root_caused/deferred | yes | yes — and **still failing** | no | **open; the gate is red because of this** |
| TL-026 | `pair_credit_next` critical-path pipeline | med | sim_proven | equivalence harness | no (coverage GAP) | no | open — honest |
| TL-027 | a2l replay nodes `_1/_3/_5` ship without CDC self-heal | high | root_caused | yes | **no — the cited targets exist in no commit** | no | **overclaimed** — a netlist-affecting flist re-point landed ungated |
| TL-028 | Unconstrained /16 RX word clock (no CTS) | high | root_caused | n/a | no | no | **open tapeout risk** |
| TL-029 | F14-B data-mode wedge (waiver) | med | deferred | sentinel | yes (XFAIL) | no | open — waiver **unsigned** |
| TL-030 | Epoch shipping-corrector sentinel flipped XCHG | med | open | sentinel | yes | no | **stale** — the sentinel contract was silently re-baselined in a dirty worktree |
| TL-031 | No SW-readable eye/BER margin at end of bring-up | med | open | none | no | no | open — honest |
| TL-032 | Calibrator run-tracker splits a wrap-straddling eye | high | sim_proven | yes — but against the **deps twin**, not the shipping file | **no commit** | no | **overclaimed x3** — twin-only proof, submodule pin never bumped, gate uncommitted |
| TL-033 | `credit_count` 13-bit unconditional decrement wraps | high | open | none | no | no | open (migrated `SHORTCOMINGS.md` #1) |
| TL-034 | TideChart `force_root` unconsumed / vacuous dual-root gate | med | open | suite exists but is vacuous **and failing** | yes (failing) | no | open — honest |
| TL-035 | State-7 NACK watchdog dead after the first CRC error | high | root_caused | none in-tree | no | silicon witness only | **open** — exists only in an uncommitted registry |

### Audited totals

| Disposition | Count |
|---|---|
| Closed end-to-end (sim **and** a re-checkable HW artefact) | **0 of 34** |
| Closed on the sim axis — integ only, committed gate, real assertions | 11 |
| Materially overclaimed in at least one machine-readable field | 14 |
| Honestly open | 14 committed, plus TL-035 (uncommitted) |
| Closed on `main` or on this branch | **0 of 34** |

These categories overlap: a bug can be sim-closed *and* overclaimed on its
hardware field (TL-003, TL-005 and TL-006 all are), so the column does not sum to
34.

## The items that matter most

### TL-001 + TL-009 — the rank-1 pair

`TL-001` (cross-die write address crosses, payload lands as zero) and `TL-009`
(die_a PS wedge after ~4–20 sustained writes) are the two genuinely open
hardware blockers and they interact: TL-009 blocks the HW validation of the
TL-006 ECC fix. Both are honestly recorded. Neither has a fix that has survived
a hardware A/B.

### The AXI channels ship with CRC checking off

`out_prepend_swi_disable_crc` resets to `1'h1` (**checking OFF**) in
`src/rtl/local_overrides/WlinkGenericFCSM{,_1,_2,_3,_4}.v` (line 700 on this
branch, 713 on the integ copy) — the comment reads *"SoC Labs (Bug-C): CRC-off
default at GPIO speed"* — and to `1'h0` (ON) in `WlinkGenericFCSM_6.v:1194` and
in every `deps/` copy. On the **integ FPGA-V2 flist**
(`flists/tidelink_fpga_v2.flist:300-304`) the five AXI nodes *are* those local
overrides, so AW/W/B/AR/R come up at POR with no link CRC.

The blocking `f14a_crc_catch` suite that declares this class closed runs only
`MODULE=test_ei_lane7_repro` (`Makefile:1043`), which drives the FIFO_DATA path
through FCSM_6 — the one node that resets CRC **on** — so it structurally cannot
see the AXI exposure. The integ line's own test says the polarity out loud
(`cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_recovery.py:367-376`,
a directory that does **not** exist on this branch): the same payload error with
CRC off is *"silently accepted … the mis-delivered wrong-BID beat that hard-wedges
the PS"*. No bring-up or deploy script in `pynq_host/` ever writes the enable.

:::{note}
The exposure is **FPGA-specific**: the ASIC-V2 flist and this branch source all
five FCSMs from `deps/`, where CRC is on.
:::

### Five gates pass only in one engineer's working tree

| Gate / claim | What is missing |
|---|---|
| `sim_gate_txgen_ext_hijack` (this branch) | test file untracked, gate target uncommitted, guarded RTL uncommitted |
| `sim_gate_v2_mbox_writeprotect` (this branch) | same three |
| `sim_gate_a2l_replay_cdc_{1,3,5}` (TL-027) | named in commit `1037a63`'s message; exists in **no commit** in repo history |
| `calibrator_wrap` (TL-032) | in `SIM_GATE_ALL_SUITES` only in an uncommitted Makefile; submodule fix unpushed |
| epoch sentinel re-baseline (TL-030) | new grep contract only in the worktree Makefile |

A gate that passes only in a dirty tree is worse than no gate: it reports green
on the thing it does not test.

### The sim gate is not green, and this branch's result is stale

| Line | Result (counted 2026-08-10) |
|---|---|
| integ (`imp/sim_gate/`, 53 status files, every line stamped `3f037c04e725-dirty`) | **48 PASS / 2 FAIL / 3 XFAIL** — `tc_pair_smoke` and `tc_pair_election_datamode` both `FAIL 5s` at elaboration (TL-025), so `sim_gate_summary` exits non-zero. The three XFAILs are `xfail_f14b_datamode_wedge`, `xfail_epoch_shipping_corrector` and `v2_mask_hs_regress` |
| this branch (`imp/sim_gate/`, 45 status files, dated Jul 31 11:26) | 43 PASS / 2 XFAIL, **no tip stamp at all** — 10 days and 4 commits behind HEAD |

The integ result is itself stamped `-dirty`, and the branch tip has since moved
past `3f037c0`, so neither line has a gate result reproducible from a committed
SHA. Treat
`verification.in_sim_gate` / `in_hw_gate` / `status` as untrusted until
`make sim_gate` is re-run from a clean checkout of a committed SHA and its
tip-stamp recorded. See {doc}`verification` for the run procedure and the
`make -n` fake-pass trap.

### No hardware evidence is retained anywhere

Every log cited as proof for an `hw_proven` bug — `hw_fix3`, `hw_purewrite.log`,
`hw_regionf_soak.log`, `hw_diea_dmesg.log`, `*ecc_hwverify*.log` — is absent from
disk. The only retained hardware artefact in any TideLink tree is
`onchip_landrate.log` (4/4 PORs, 500/500 byte-exact each), and it is on the
lottery-free `kr260-pair-onchip` vehicle where TL-001 and TL-009 cannot occur.
`pynq_host/scripts/hwtest_gate.sh` emits `imp/hw_gate/verdict.json`; no such
directory exists in any tree, so the gate has never run. (That script is on the
integ line only — it is not present on this branch.)

The live line's own newest commit states it: *"every silicon claim this project
has made is unreproducible by construction. '128/128', '16/16', '11/11' — none of
them has a surviving artefact."*

### TL-024's hardware gate is bound to the wrong vehicle

`hwtest_gate.sh` is scoped `TARGET=kr260-pair-onchip`, described in its own
header as *"one board, two dies — the lottery-free vehicle"*. TL-031 records that
this vehicle does **not** exhibit the framing lottery, and `onchip_landrate.log`
is 4/4 and 500/500 before and after. A land-rate soak that is saturated cannot
detect a regression in the threshold FIX-2 changed, which was measured on the
two-board eth-chiplet pair.

## Structural shortcomings

`docs/reference/SHORTCOMINGS.md` is a separate, older document: **38 design
limitations** from code review, two of them marked Critical. It uses its own
numbering and contains **no TL ids at all** (`grep -c 'TL-0'` = 0), so the two
documents cannot be reconciled by reading either one.

| # | Severity | Item | Registry state |
|---|---|---|---|
| 1 | Critical | No credit underflow protection (BUG-002) | migrated → **TL-033** |
| 2 | Critical | Single packet in-flight — writing address 0 overwrites `packet_word_length`, so a second packet cannot begin until the first completes | **never migrated** — no TL id, no test, no waiver |
| 28 | Moderate | Error-recovery path never tested end to end | untracked |
| 29 | Moderate | CDC clock-ratio variations never exercised | untracked |
| 34 | Minor | PTP multi-hop chaining (`PHC_LOCK_GATE_EN`) never verified | untracked |

Other recurring themes in that document, none of them registry-tracked: no
hardware packet-size validation (#3), no AHB error response on overrun/underrun
(#4), configuration registers not lockable after init (#25), no coordinated reset
protocol between paired chiplets (#27), and `tc_axis_*` having no flow-control
credits — a head-of-line blocking risk on the FC RX path (#38).

## Open tapeout risks

| Risk | Registry | State |
|---|---|---|
| PHY BIST unwired on silicon; no first-silicon go/no-go metric | TL-011 | deferred, ungated, unmitigated |
| ASIC flist pins FCSM 0–4 to `deps/` — the `socl_` recovery hooks (L6/L7 emit floors, NACK watchdog) are **absent from the tapeout netlist** | TL-019 | root_caused, unmitigated |
| Unconstrained ÷16 RX word clock — no clock tree synthesised for it | TL-028 | root_caused, unmitigated |
| `credit_count` unconditional 13-bit decrement can wrap | TL-033 | open |
| State-7 NACK watchdog permanently disarmed after the first CRC error, which makes the `nack_wedge_recovery` gate meaningful only for the first CRC error of a reset cycle | TL-035 | open, registry entry uncommitted |
| AXI-channel CRC checking off at POR on the shipping FPGA vehicle | TL-018 | understated as a "config divergence" |

Two further items sit in the registry as decisions rather than risks: F13 (PTP,
TL-010) is `fix_built` with the two-board convergence half open, and the ECC
header restore (TL-006) is not present in either flist on this branch.

## Working with the registries

| Task | Command |
|---|---|
| Render both registry pages | `python3 scripts/gen_bug_registry_html.py` |
| Live-reloading bug page | `python3 scripts/serve_bug_registry.py` (default `http://127.0.0.1:8765`) |
| CI staleness check | `python3 scripts/gen_bug_registry_html.py --check` |
| Registry ↔ test wiring check | `TIDELINK_HOME=$PWD python3 scripts/ci/registry_coverage.py` |

:::{warning}
`scripts/ci/` does not exist on this branch — the coverage checker is on the
integ line only. Where it does run, `registry_coverage.py` walks the
**filesystem**, not the git index, so it cannot
see any of the four gating defects listed above: an untracked test file, a fix
that landed while the registry still says `in_sim_gate: false`, a gate target
that exists only in an uncommitted Makefile, or an RTL fix that is a worktree
edit. It also prints `RESULT: COVERAGE OK` while listing gaps, and exits 0.
:::

Related pages: {doc}`build_registry` (which bytes ran on which board),
{doc}`verification` (the gate and its traps), {doc}`hardware_tests` (the numbered
HW suite and its safety gates).
