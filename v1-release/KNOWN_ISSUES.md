# Known Issues — TideLink v1.0-rc1

This document lists all open items at v1 RC1 cut-off and their deferred-to-v2
status. Full historical context is in the source repo at `docs/BUG_TRACKER.md`.

## FPGA artifact: honest lock rate (read this first)

The v1 FPGA deliverable is the **`tl_v7`** bitstream: **13/16 best lane lock**,
`cal_done=1`, HW-validated both before and after a power cycle on 2026-05-22.
It is NOT a 16/16 build and we do not claim one.

**The "14.40/16" figure is retired (Bug #34).** Earlier bundle drafts attributed
14.40/16 to a "morning-v1" build (artifact-store blob md5 `86aa3a95` / sha256
`40f6477c`). On 2026-05-22 that exact blob measured **0/16 on healthy hardware**;
its `.bit` build-date is 2026-05-20 **23:41 (evening)**, not the 11:10 morning
build. It has been relabelled `hwval-eve-NONLOCKING` in the artifact store and its
false lock history retracted.

**The true 14.40/16 build is currently UNIDENTIFIED (Bug #35).** A separate
provenance investigation will try to recover it (most likely by rebuilding the
best-known commit on srv03335, which builds clean). Until then, `tl_v7` (13/16)
is what ships. 14.40/16 is aspirational, not a shipped number.

## Blocking-but-mitigated for v1 (2)

### Bug #27 — bridge1 slave board (pynq_z2_03) PS-eth unreachable (transient lab HW failure)

**Symptom** (2026-05-21 15:00+): The slave PYNQ-Z2 board's PS-side ethernet
(`192.168.6.101`) became unreachable mid-session: ARP entry is "incomplete",
ping reports "Destination Host Unreachable". The master board (`192.168.4.101`,
z2_02) remains fully alive and reachable. The fpgahub lease was acquired and
released cleanly — this is **not** a lease or harness issue.

**Impact**: Blocked the planned 20-iter v1 reliability re-test of the morning
bitstream during this session. The release bundle itself is fully assembled
and verifiable; only the live re-run-with-fresh-data row of the reliability
log could not be produced.

**Empirical backstop** (now superseded by the 2026-05-22 power-cycle retest):
- 2026-05-21 ~14:49: `tl_v7s` → 11/16 best, mean 6.10/16 (cal_done=1).
- 2026-05-21 ~14:53: `tl_v7` → 13/16 best (cal_done=1).
- 2026-05-22: `tl_v7` re-confirmed **13/16 best, cal_done=1 after a full power
  cycle** — identical to the pre-cycle result. This is the shipped artifact and
  is the definitive backstop; it also closes Bug #28 (the suspected ribbon
  damage was a false alarm — the HW is healthy).
- The previously-cited "14.40/16 morning baseline" has been WITHDRAWN (Bug #34):
  the blob it referred to is non-locking (0/16). See the honest-lock-rate note
  at the top of this file.

These empirically confirm the bitstream + FSM + calibrator path lock on real
silicon when the boards are healthy.

**Mitigation for v1**: ship the release bundle as-is; the bitstreams have
provenance + checksums + same-day successful tests from other preserved
historical bitstreams. The 20-iter re-run is a confirmation step, not a
gating step.

### Bug #5 — FPGA rebuild regression on srv04936 (mitigated by morning bitstream)

**Symptom**: source-level rebuilds on srv04936 produce an FPGA bitstream that
converges 0/16 lanes (`cal_done=0`, `ft=0x00`) every deploy, byte-different from
the morning preserved bitstream.

**Mitigation in v1**: ship the preserved `tl_v7` bitstream (`bitstreams/*.bin/.hwh`)
as the FPGA deliverable. `tl_v7` re-tested 2026-05-22 at **13/16 best, cal_done=1**,
confirmed pre- and post-power-cycle — it is known-good (honest 13/16, not 16/16).

**Status**: deferred to v2 (root-cause investigation tracked as Bug #25, still open).

### Bug #25 — srv04936 build-environment regression (root cause investigation)

**Hypothesis space**: Vivado tool state drift, IP cache pollution, /apps Xilinx
mount inconsistency, /research drift between morning and today.

**What was eliminated** (2026-05-20 → 2026-05-21):
- Source content (D2-fresh: fresh clone + fresh xhb500 regen still fails).
- xhb500 generated rsync contamination (Bug #15, disproven by D2-fresh).
- clk_wiz 50→25 MHz mutation hypothesis (Bug #26, **disproven**: `pynq-z2-pair-all`
  has been at 25 MHz since `30dc14c` on 2026-05-05 — apples-to-oranges diff).
- Recent code changes (v1-RC tag at `53e4217` also produces 0/16 on rebuild).

**Status**: deferred to v2.  Investigation will resume against a fresh build host
or a clean Vivado workspace.

## v2 / non-blocking (4)

### Bug #3 — Mask FSM states 8/9/10 skipped on silicon

`NEGO_CFG[6]` / `mask_hs_auto_en` reads back as 1 but the mask-phase states never
fire on silicon. Same defect class as the latch fixes (Bugs #1/#2): synth-prune
of a path that should be retained. Candidate structural fix at sub `6a757e2`
(default state_nxt arm). Silicon validation **blocked** by Bug #5 (no clean
rebuild path on srv04936). Reverts to v2 when the env regression is resolved.

### Bug #10 — SV anti-pattern findings in third-party IP

14 findings in vendor `.v` files (Wlink, ahb-wb-bridges, etc.). Documented in
`docs/SV_ANTIPATTERN_SWEEP_REPORT.md` in the source repo. Cosmetic / readability;
none of them affect functionality on the v1 morning bitstream.

### Bug #16 — Lower-priority HAL findings

PADMSB+UELOPR @288, ENMNFU @136, USEPAR @104 in the calibrator. Cosmetic.

### Bug #22 — UVM masked-strobe FSM defects (CI surfaced)

5 reds in the CI pipeline (per `docs/CI_FAILURE_TRIAGE.md §7`). Independent from
Bug #11 (the CI install fix). Deferred — UVM masked-strobe is a v2 feature
anyway.

### Bug #24 — Watcher path migration (bit_for/hwh_for hardcoded /tmp)

Manual HW testing works fine; the watcher daemon won't auto-pick up new builds
placed under `/home/dam1n19/SoCLabs/td-bisect/`. Cosmetic; trivial path-string
fix for v2.

## Disproven (2)

### Bug #15 — xhb500 generated rsync contamination

D2-fresh test (fresh clone + fresh regen of `xhb500/generated`) reproduced the
0/16 failure identically. Rules out rsync state as the cause.

### Bug #26 — clk_wiz 50→25 MHz mutation hypothesis

Confirmed by inspecting the morning preserved `.hwh`: CLKOUT1/2 are 25 MHz. The
`pynq-z2-pair-all` target (the actual target used by `build_pair_farmed`) has
been at 25 MHz since commit `30dc14c` (2026-05-05). The 50→25 MHz "mutation"
seen in some diffs was an apples-to-oranges comparison between the original
`pynq-z2-pair` and the `-all` variant. Other "mutations" (ILA additions,
source-sync XDC) are reverts of v1-RC §9 work back to `feat/td-combined`
ILA-debug state — also confirmed not the regression by D2-fresh.

## Already-resolved (16) — these are **not** issues at release

These are all the bugs that landed during the v1 push and are merged in the
release-branch ancestry or sit on the 7 fix branches catalogued in
`fixes/MANIFEST.md`. See `docs/BUG_TRACKER.md` for the full table.

Class A latches (HW-validated): #1, #2, #4.
XDC + RTL hygiene: #6, #7.
Decoder / case-collision: #8, #9.
CI / scripts / discipline: #11, #12, #13, #14, #17, #18, #19.
Cocotb + Verilator gates (catch the silicon-only ones next time): #20, #21, #23.
