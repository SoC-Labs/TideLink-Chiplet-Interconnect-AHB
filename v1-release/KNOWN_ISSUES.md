# Known Issues — TideLink v1.0-rc2

Open items at the v1 RC2 cut-off and their status. Full historical context is in
the source repo at `docs/BUG_TRACKER.md`, `docs/reference/LANE_LOCK_ROOT_CAUSE.md`, and
`docs/RTL_FREEZE_CHECKLIST.md`.

## FPGA artifact: lock rate (read this first)

The v1 FPGA deliverable is the **`72c280b` (sub `17160eb`) source build**:
**16/16 bidirectional lane lock**, `cal_done=1`, `fault=0x00`, HW-validated on the
`bridge1` pair 2026-05-22. The N-deploy reliability distribution is in
`reliability.log`. Routed-netlist evidence (8× BUFG capture clocks, 8× IDELAYE2,
`Place 30-568` = 0, WHS +0.051 ns) is summarised in
`docs/reference/LANE_LOCK_ROOT_CAUSE.md`.

## Resolved since rc1 (the big ones)

### rc1 Bug #5 / #25 — "FPGA rebuild regression to 0/16" — RESOLVED (root-caused)

rc1 could not rebuild its own bitstream: source rebuilds on the farm produced a
0/16 bitstream (`cal_done=0`), so rc1 shipped a preserved `tl_v7` instead. This
was **not** an environment regression. Root cause: commit `51b5169` ("no
idelay_*/USE_*") had **stripped the `USE_CLKBUF`/`USE_IDELAY` RTL clock-structure
fix** from the FPGA build path, so Vivado placed the GPIO-PHY recovered capture
clock on a LUT-driven net (`Place 30-568`) → hold violation → `cal_done=0` →
0/16. rc2 is branched from `72c280b`, which carries the fix; its source rebuilds
a 16/16 bitstream. Full writeup: `docs/reference/LANE_LOCK_ROOT_CAUSE.md`.

### rc1 Bug #34 / #35 — "mislabelled / unidentified 14.40-16 build" — MOOT

rc1 chased a "14.40/16 morning build" that turned out mislabelled (the blob it
pointed to was 0/16) and a "true 14.40 build" that was never found. Both are moot:
`72c280b` is the real deterministic winning build at **16/16**. There is no longer
a missing artifact to recover.

### rc1 Bug #28 — suspected ribbon-cable damage — DISPROVEN

The hardware is healthy; lock reproduces 16/16 on the same physical pair.

### rc1 Bug #27 — slave board PS-eth unreachable — TRANSIENT, RESOLVED

A transient lab-network failure on 2026-05-21; the board is reachable and the
2026-05-22 reliability sweep ran on it cleanly.

## RTL-freeze work (NOT shipped in rc2 — tracked for the freeze)

rc2 ships the proven 16/16 build, but `72c280b` **predates** several RTL
bug-fixes authored later on the rc1 lineage. Re-basing them onto rc2 (without
re-stripping `USE_CLKBUF`) and HW-re-validating is the path to RTL freeze. See
`docs/RTL_FREEZE_CHECKLIST.md` for the 13-job checklist. Summary of the gap:

- **Bug #3** — Mask FSM states 8/9/10 silicon validation (candidate fix `6a757e2`).
  The 16/16 lock implies the calibrator/mask path completes (`cal_done=1`), but
  the mask phase is not yet ILA-instrumented on a locking bitstream.
- **Bug #4** — Mask-FSM defensive fixes (`9b43676`+`a30b21b`); re-validate on the
  locking build (prior test was on a 0/16 bitstream → not meaningful).
- **Bug #9 / #16 / #23** — HAL rename, calibrator HAL cosmetics, `perf_reg_rdata`
  33→32-bit truncation; sim-validated, need to land on the freeze branch.
- **Bug #22** — UVM masked-strobe FSM reds; run the regression on the unified branch.
- **Bug #30** — `tidelink_phy_align_calibrator` TB/RTL port drift (testbench fix).

## v2 / non-blocking

- **`clkfreq-check` + build-ID register** (`feat/clkfreq-check`): the permanent
  runtime guard against the wrong-bitstream / mismatched-clock class of error.
  cocotb 5/5 green; integrate into `tidelink_top` + APB regs in v2.
- **Bug #10** — SV anti-pattern findings in third-party IP (cosmetic).
- **Bug #24** — watcher path migration (cosmetic).
- AHB end-to-end on HW, PTP single-phase silicon validation, TideChart protocol,
  fpgahub CLI/daemon, Verilator ≥5.x, CI integration phase 1.

## Prevention guards built (so the rc1 confusion can't recur)

1. **Deploy-provenance guard** — `deploy_pair.sh` SHA256-verifies the bitstream
   before flashing (aborts on mismatch).
2. **`td-artifact` content-addressed store** — immutable blobs + deploy-by-label
   + lock history; makes "stale /tmp clobbered the bitstream" structurally
   impossible.
3. **Vivado msg gate** (`57c2810`) — fail-fast on silent constraint-drop CRITICAL
   WARNINGs (the class that let `51b5169` strip the fix unnoticed).
4. **Verilator strict-lint gate** — synth-class bug gate (found Bug #23).
5. **`clkfreq-check`** (pending integration) — runtime link clock-freq cross-check.
