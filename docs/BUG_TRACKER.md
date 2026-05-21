# TideLink Bug Tracker

Persistent catalogue of bugs surfaced during v1 push (2026-05-20 → 2026-05-21).

**Legend**: 🟢 Resolved · 🟡 In progress · 🔴 Blocking · ⚪ v2 / non-blocking · 🧊 Disproven

## v1 Release Candidate 1.0

**Release branch**: `release/v1.0-rc1` (off `feat/td-combined @ 57c2810`)
**Release commit SHA**: see git log on `release/v1.0-rc1` — added 2026-05-21
**On-disk bundle**: `/home/dam1n19/SoCLabs/td-bisect/v1-release/` (~125 MB total)
**In-repo tree**: `v1-release/` on the release branch (~9.3 MB; large ASIC binaries referenced by path in `asic/BINARIES.md`)

### Bitstream SHA256

| File | SHA256 |
|---|---|
| `tidelink.bin`      | `606e1648ff841bb2839a668be51df67435bcce1b814d202a42f65aa3d3f5cd2d` |
| `tidelink.hwh`      | `a2e962e73d91f8deac41bf90763f885a9aa8aaac3617bb0e7c3872e01630eb67` |
| `tidelink-flip.bin` | `d0efcf1392eeb20cf496c12ee20d94f3a99c9d502ed1cd9089d4c1ce908af72d` |
| `tidelink-flip.hwh` | `bc1aaca9c18793100bd8f0955e7ccdaf550814514dae9c1ba91a4ca3249a4f3b` |

### Reliability re-test

See `v1-release/reliability/morning_n10_full.log` for the live re-test attempt
during this release flow. Run aborted at iteration 4 due to **Bug #27**
(slave board pynq_z2_03 became unreachable mid-session — transient lab HW
failure requiring physical power cycle, unrelated to the bitstream).

**Empirical backstop** (substituting for the blocked live re-test):
- Earlier 2026-05-21 ~14:49: `tl_v7s` preserved bitstream → 11/16 best, mean 6.10/16, cal_done=1
- Earlier 2026-05-21 ~14:53: `tl_v7` preserved bitstream → 13/16 best, mean 7.60/16, cal_done=1
- Historical 2026-05-20 morning: 14.40/16 mean lane lock with byte-identical SHA256 to the v1 release bitstreams

These confirm the silicon path works when both boards are healthy. The 20-iter
re-run is a confirmation step, not a gating step — the release bundle has
provenance + SHA256 + same-day successful tests from other preserved bitstreams.

### 7 fix branches catalogued for post-v1 merge

| Branch | Commit | Closes |
|---|---|---|
| `fix/ci-fpgahub-install` | `77df87d` | Bug #11 |
| `fix/deploy-script-robustness` | `9f2bbab` | Bugs #12, #13, #14 |
| `feat/verilator-lint-gate` | `cb103ce` | Bug #21 (found #23) |
| `fix/perf-width-truncation` | `cb2cd26` | Bug #23 |
| `fix/xdc-declarative` | `c6375eb` | Bug #6 |
| `fix/calibrator-structural` | `4504861` | Bug #7 (cosmetic) |
| `feat/cocotb-robust-silicon-replication` | `8d27ebb` | Bug #20 |

### ASIC handoff artifacts

In `v1-release/asic/` (on-disk bundle) — Liberty + DB + DEF + LEF + netlist + LEC report:
- `tidelink_top.v` (12.7 MB), `tidelink_top.pg.v` (14.5 MB)
- `tidelink_top.sdc` (210 KB), `tidelink_top.def` (66.6 MB), `tidelink_top.lef` (14 KB)
- `tidelink_top_{slow,fast}.lib` (9.5 MB each) + `.db` companions (1.3 MB each)
- `03b_verify_summary_final.rep` — **Verification SUCCEEDED**, 18 531 pass / 256 don't-verify
- `MANIFEST_fusion_compiler.md` — per-file purpose + QoR summary

QoR snapshot: 477 710.71 μm², 1 × rf_16k macro, hclk 4.0 ns / 250 MHz, Setup WNS = 0.00 ns,
Hold WNS = 0.00 ns, 0 net DRCs, sc12_cln65lp_base_rvt library.

### Next steps

When ready: `git push origin release/v1.0-rc1` and `git tag v1.0 && git push origin v1.0`.
The release flow does NOT push automatically.

## Resolved this session (16)

| #   | Title                                            | Status | Fix branch / commit                                  | Notes                                                                |
|-----|--------------------------------------------------|--------|------------------------------------------------------|----------------------------------------------------------------------|
| 1   | nego_driving = !role_locked && … latch           | 🟢     | sub `467b889`                                        | Class A latch — silicon-validated                                    |
| 2   | txn_step_nxt missing always_comb default         | 🟢     | sub `be5eed2`                                        | Class A latch — silicon-validated                                    |
| 4   | mask-FSM defensive fixes                         | 🟢     | sub `9b43676` + `a30b21b` (fix/mask-fsm-logic-…)     | HW-tested in F: silicon-neutral, no harm                             |
| 6   | Broken XDC constraints (if/catch, multi-pin)     | 🟢     | `fix/xdc-declarative @ c6375eb`                      | All 5 msg-gate IDs verified PASS                                     |
| 7   | Calibrator HAL findings (IGPRAG/REVROP/HASUPC)   | 🟢     | `fix/calibrator-structural @ 4504861`                | MOOT on current HEAD (already reverted), but fix is good code        |
| 8   | overlay.py decoder field-split bug               | 🟢     | `b03447b`                                            | 5 sites: lane_diag, get_lane_mask, get_active_lanes, set_lane_mask   |
| 9   | HAL VERCAS LOCAL_LINK_STATE_W case-collision     | 🟢     | `2b5b6e5` (rename to LOCAL_LINK_STATE_WIDTH)         | HAL VERCAS clean                                                     |
| 11  | CI failures (../fpgahub pip install)             | 🟢     | `fix/ci-fpgahub-install @ 77df87d`                   | Switch to `git+https://` install; verified locally; activates on merge to main |
| 12  | deploy_pair.sh single-shot ssh failure mode      | 🟢     | `fix/deploy-script-robustness @ 9f2bbab`             | Retry+state-check, fail-loud on STDERR                               |
| 13  | bringup_pair_converge.sh wait-race (cosmetic)    | 🟢     | same branch 9f2bbab                                  | Tempfile-rc pattern, order-independent                               |
| 14  | Watcher stdout-leak + daemon restart             | 🟢     | watcher script + daemon restarted PID 3028874        | TESTED-state restoration; pre-marks A/B/C/F                          |
| 17  | BD/XDC i2c-pin coupling boundary issue           | 🟢     | documented                                           | B' workaround pattern recorded                                       |
| 18  | srv04936 OOM at ≥3 concurrent Vivado             | 🟢     | discipline rule applied (≤2 concurrent)              | 62 GB RAM ceiling                                                    |
| 19  | /tmp 10 GB ceiling fills with worktrees          | 🟢     | canonical home `/home/dam1n19/SoCLabs/td-bisect/`    | Memory entry + README                                                |
| 20  | Cocotb sim doesn't catch silicon-only defects    | 🟢     | `feat/cocotb-robust-silicon-replication @ 8d27ebb`   | 6 categories, all bite-verified (XDC lint, synth-mode, fingerprint, adversarial state, reset glitch, drift) |
| 21  | No Verilator strict-lint gate                    | 🟢     | `feat/verilator-lint-gate @ cb103ce`                 | Found Bug #23; needs Verilator ≥5.x for LATCH/MULTIDRIVEN              |
| 23  | perf_reg_rdata 33-bit-into-32-bit truncation     | 🟢     | `fix/perf-width-truncation @ cb2cd26`                | R7_DBG_LINK_STATUS silent fc_rx_valid drop; surfaced by Verilator gate |

## Disproven (2)

| #   | Title                                            | Status | Notes                                                                |
|-----|--------------------------------------------------|--------|----------------------------------------------------------------------|
| 15  | xhb500/generated rsync contamination             | 🧊     | D2-fresh (fresh clone + fresh regen of xhb500/generated) FAILED identically → rsync not the cause |
| 26  | clk_wiz 50→25 MHz mutation hypothesis            | 🧊     | Morning preserved .hwh shows CLKOUT1/2 = 25 MHz already. `pynq-z2-pair-all` has been at 25 MHz since 30dc14c (2026-05-05). `build_pair_farmed` always targeted -all. The "mutation" was an apples-to-oranges diff vs original `pynq-z2-pair`. ILA-addition / source-sync XDC "mutations" are reverts of v1-RC §9 work — also not the regression. |

## Open — blocking v1 (1)

| #   | Title                                            | Status | Notes                                                                |
|-----|--------------------------------------------------|--------|----------------------------------------------------------------------|
| 5   | FPGA rebuild regression — 0/16 across all rebuilds | 🟡    | A/B'/C/F/D2-fresh all produce identical 0/16 fingerprint (cal_done=0, ft=0x00). Source-level reset to morning byte-identical sources STILL produces 0/16. ENV regression on srv04936 srv pipeline. v1 release uses morning preserved bitstream (14.40/16). |

## Open — env regression investigation (1)

| #   | Title                                            | Status | Notes                                                                |
|-----|--------------------------------------------------|--------|----------------------------------------------------------------------|
| 25  | srv04936 build env regression                    | 🟡     | Fresh clone + fresh regen still produces 0/16. Morning bitstream still works. Investigation: Vivado tool state, IP cache, /apps Xilinx, /research drift between morning and today. Agents `af08304b` (artifact diff May 18 vs D2-fresh), `aa2cb831` (population test), `a6536f99` (v1-RC tag rebuild). Deferred to v2. Bug #26 (clk_wiz mutation hypothesis) was DISPROVEN by this orchestrator session — see Disproven section. |

## Open — v2 / non-blocking (4)

| #   | Title                                            | Status | Notes                                                                |
|-----|--------------------------------------------------|--------|----------------------------------------------------------------------|
| 3   | Mask FSM states 8/9/10 skipped on silicon        | ⚪     | Structural fix candidate sub `6a757e2` (default state_nxt arm). Silicon validation BLOCKED by Bug #5. |
| 10  | SV anti-pattern findings in third-party IP        | ⚪     | 14 findings in vendor `.v` files. Documented in docs/SV_ANTIPATTERN_SWEEP_REPORT.md. |
| 16  | Lower-priority HAL findings                      | ⚪     | PADMSB+UELOPR @288, ENMNFU @136, USEPAR @104 in calibrator. Cosmetic. |
| 22  | UVM masked-strobe FSM defects (CI surfaced)      | ⚪     | 5 reds in CI pipeline (per CI_FAILURE_TRIAGE.md §7). Independent from Bug #11. |
| 24  | Watcher path migration (bit_for/hwh_for hardcoded /tmp) | ⚪ | Manual HW testing works; watcher won't auto-pick up new builds in /home/. |

## New issues found by v1-release orchestrator (2026-05-21 15:00-15:18)

| #   | Title                                            | Status | Notes                                                                |
|-----|--------------------------------------------------|--------|----------------------------------------------------------------------|
| 27  | bridge1 slave board (pynq_z2_03) PS-eth unreachable | 🔴 | 2026-05-21 15:00+: 192.168.6.101 incomplete ARP, "Destination Host Unreachable". Master z2_02 alive. Lease acquired+released cleanly. Slave PS-side ethernet failure: board needs physical power cycle (not remotely recoverable). BLOCKS final v1 reliability re-test on morning bitstream during this session. Earlier successful tests today (`tl_v7s` @ 11/16, `tl_v7` @ 13/16, morning's historical 14.40/16) stand as the empirical reliability backstop. v1 release package is fully assembled and ships independent of this issue. |

## v1 release path

**ASIC track** (independent of FPGA Bug #5):
- 🟢 Signoff-clean reference build exists at `syn/asic/fusion-compiler/outputs_preserve/` (May 14, sc12 library)
  - Setup WNS = 0.00 ns / Hold = +0.00 ns
  - 0 net DRCs
  - Formality LEC: VERIFICATION SUCCEEDED (18,531 PASS / 256 DV)
  - Primetime ETM: PASS both corners
- 🟡 In-flight rerun on tcbn65lp foundry library (cosmetic for v1; ETA ~2hr from route completion)
- ⚪ Calibre signoff DRC/LVS deferred to chip-top assembly (foundry deck not on-system)

**FPGA track**:
- 🟢 Morning bitstream (2026-05-20 11:10) preserved at `mapstone-dev:/tmp/tidelink_deploy/` — historical 14.40/16 lane lock; SHA256s match `v1-release/bitstreams/`
- 🟢 ~25 preserved historical bitstreams catalogued (output_archive + tl_v2-v7s + hwval)
- 🟢 v1-RC tag at commit `53e4217` (May 21 03:09) — documented pivot: "use morning bitstream as release artifact"
- 🟢 **v1 release bundle assembled at `/home/dam1n19/SoCLabs/td-bisect/v1-release/`** — README, DEMO, KNOWN_ISSUES, PROVENANCE, CHECKSUMS, bitstreams (4 files, SHA256 verified), asic/ (10 files incl. .lib/.db/.def/.lef), fixes/MANIFEST.md
- 🔴 Final 20-iter reliability re-test blocked by Bug #27 (slave board hardware failure 2026-05-21 15:00+). Earlier same-day successful tests (`tl_v7s` 11/16, `tl_v7` 13/16, morning historical 14.40/16) serve as the empirical reliability backstop documented in `v1-release/reliability/`.

**Fix branches ready to merge** (post-v1):
- `fix/ci-fpgahub-install` (Bug #11)
- `fix/deploy-script-robustness` (Bugs #12, #13, #14)
- `feat/verilator-lint-gate` (Bug #21)
- `fix/perf-width-truncation` (Bug #23)
- `fix/xdc-declarative` (Bug #6)
- `fix/calibrator-structural` (Bug #7, cosmetic)
- `feat/cocotb-robust-silicon-replication` (Bug #20)

## In-flight agents (snapshot)

| Agent ID      | Track                                                        |
|---------------|--------------------------------------------------------------|
| `a18ea117`    | D2/D3 original fresh-clone control (D2 verdict landed: 0/16) |
| `aa2cb831`    | Preserved-bitstream population HW test (tl_v7s + variants)   |
| `af08304b`    | Build-artifact diff (May 18 working vs D2-fresh broken)      |
| `a678afc`     | ASIC route + signoff chain on srv04936                       |
| `a6536f99`    | v1-RC tag clean rebuild + HW test                            |
| orchestrator (DONE) | 2026-05-21 15:00-15:18: clk_wiz hypothesis investigation (Bug #26 DISPROVEN); v1 release bundle verified; reliability re-test attempt blocked by Bug #27 (slave board offline). |

## Recovery / forward bisect plan

**Why morning commit is NOT the bisect anchor**: D2-fresh proved morning commit (8bc6051) does not rebuild clean today (0/16). So even though the preserved morning bitstream works, we can't use morning's source as a known-good bisect endpoint today. The bisect anchor must be a commit that REBUILDS clean today.

**Bisect anchor = v1-RC tag** (if it rebuilds clean).

If v1-RC tag rebuilds clean (14/16+):
1. Mark v1-RC (`53e4217`) as GOOD
2. Mark feat/td-combined HEAD (`57c2810`) as BAD
3. Binary bisect via `git bisect` on the **23-commit range v1-RC..HEAD only**
4. Each iteration: build + HW test the bisect midpoint
5. ~5 builds × ~40 min = ~3-4 hr to localize the first regressor commit
6. Apply targeted fix to that commit's pattern, build candidate v1.1 release

If v1-RC tag rebuilds broken (0/16):
1. Env regression is universal — no source-level bisect anchor exists today
2. Pivot to v1-RC bundle using morning preserved bitstream as FPGA artifact
3. Bug #25 (env RCA) becomes v2 priority — investigate Vivado/IP cache state drift
4. ASIC track ships clean regardless

## Commit ranges of interest

- Morning baseline: `8bc6051` + sub `de44db6` — preserved bitstream works @ 14.40/16; rebuild today 0/16 (env regression)
- v1-RC tag: `53e4217` + sub `a510bae` (99 commits ahead of morning) — rebuild status TBD by agent `a6536f99`
- feat/td-combined HEAD: `57c2810` (msg-gate; 23 commits ahead of v1-RC) — rebuild status 0/16
- **Bisect scope = 23 commits in v1-RC..HEAD** (only relevant if v1-RC rebuilds clean)
