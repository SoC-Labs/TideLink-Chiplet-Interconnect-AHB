# Fix branches ready to merge post-v1

These 7 branches were authored during the v1 push but are **not** required for
RC1 (the morning preserved FPGA bitstream already converges without them).
They are catalogued here so they can be merged into `main` in any order after
v1.0 is tagged.

All commit SHAs are pinned. Branches live in the source repo.

| # | Branch | Commit | Closes | Risk | Description |
|---|---|---|---|---|---|
| 1 | `fix/ci-fpgahub-install` | `77df87d` | Bug #11 | Low | CI installs `fpgahub` from `git+https://` URL instead of the broken relative `../fpgahub` path. Activates on merge to `main`. Verified locally. |
| 2 | `fix/deploy-script-robustness` | `9f2bbab` | Bugs #12, #13, #14 | Low | `deploy_pair.sh` gains retry + state-check + fail-loud on STDERR; `bringup_pair_converge.sh` uses tempfile-rc pattern (order-independent wait); watcher daemon stdout-leak fixed and restarted with TESTED-state pre-marks. |
| 3 | `feat/verilator-lint-gate` | `cb103ce` | Bug #21 | Low | Adds Verilator strict-lint gate to the build to catch synth-class bugs (latch inference, multi-driven nets, width truncation). Needs Verilator ≥5.x for LATCH/MULTIDRIVEN. Found Bug #23 the first time it ran. |
| 4 | `fix/perf-width-truncation` | `cb2cd26` | Bug #23 | Low | Fix 33→32 bit truncation in `perf_reg_rdata` concatenation that silently dropped `fc_rx_valid` from `R7_DBG_LINK_STATUS`. Surfaced by the Verilator gate (#3 above). |
| 5 | `fix/xdc-declarative` | `c6375eb` | Bug #6 | Medium | Declarative XDC rewrite to pass the Vivado fail-fast message gate. Removes `if/catch` and multi-pin constructs. All 5 msg-gate IDs verified PASS. **Re-run msg-gate after merge.** |
| 6 | `fix/calibrator-structural` | `4504861` | Bug #7 (cosmetic) | Low | Replace `unique case` with `case`+default; remove cross-process blocking assigns in the calibrator. MOOT on current HEAD (already reverted on `feat/td-combined`) but the structural pattern is good code and worth landing. |
| 7 | `feat/cocotb-robust-silicon-replication` | `8d27ebb` | Bug #20 | Low | Cocotb adversarial silicon-replication suite covering 6 defect classes: XDC lint, synth-mode, fingerprint, adversarial state, reset glitch, drift. All bite-verified against the failure modes seen during v1 push. |

## Recommended merge order (post-v1.0 tag)

1. `fix/ci-fpgahub-install` first — unblocks CI for everything else.
2. `feat/verilator-lint-gate` + `fix/perf-width-truncation` together — the gate
   expects the fix to exist or it fails CI immediately.
3. `feat/cocotb-robust-silicon-replication` — independent, no rebuilds needed.
4. `fix/deploy-script-robustness` — independent.
5. `fix/xdc-declarative` — re-run Vivado msg-gate on the merged tip and re-run
   a HW bringup_pair_converge before declaring done. **This one is the most
   load-bearing because it touches the FPGA build path that hit Bug #5.**
6. `fix/calibrator-structural` — last; cosmetic. Optional.

After all 7 are in `main`, re-tag `v1.0` if no source-of-record change is
needed; otherwise cut `v1.1`.

## Why none of these go into RC1

The morning preserved bitstream **predates all 7** and is the artifact being
shipped. Adding any of these would (a) require a new FPGA build, which today
produces a 0/16 artifact on srv04936 (Bug #5/#25, deferred), and (b) change the
provenance of the deliverable. RC1 deliberately freezes on the known-good
bitstream and catalogues the fixes for the follow-on release.
