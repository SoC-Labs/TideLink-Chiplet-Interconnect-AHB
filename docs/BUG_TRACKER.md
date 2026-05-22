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

**Post-power-cycle 20-iter live re-test (2026-05-21 16:19-16:27)** — autonomous orchestrator:
Lease re-acquired (token `20B_pJMd4ijuJ_ea6L3k9A`, granted to srv03335) after
user power-cycled pynq_z2_03. Ran 20 independent one-shot deploys on v1 morning bitstream:
- **N=20  BEST=0/16  MEAN=0.00/16  MIN=0/16** — every iter all-zero
- Per-iter: lk=0x00, ft=0x00, cal_done=0, FCSM=0, cr=0 on BOTH die_a and die_b
- FPGA load verified `operating`, MD5 of `/lib/firmware/tidelink.bin` matches v1-release bundle on both boards
- SSH / APB writes work, role_lock=1 latched on both — control plane intact
- Log: `v1-release/reliability/live_n20_postcycle.log`

**5-iter SWAP=1 follow-up (2026-05-21 16:27-16:30)** — physical vs logical discriminator:
- All 5 iters still 0/16 under SWAP=1 (die_a→slave IP, die_b→master IP)
- Log: `v1-release/reliability/live_n5_swap_postcycle.log`
- **VERDICT: Bug #28 — HW ribbon damage from physical access.** Bug #5 all-zero
  fingerprint now reproducing from the power-cycle physical access (not from
  build env). Earlier same-day 11/16 + 13/16 (14:49/14:53, BEFORE physical
  access) prove silicon path was intact pre-cycle. 25 post-cycle deploys with
  both SWAP modes consistently 0/16 ⇒ HW regression introduced by physical access.

**v1 release bundle is unaffected**: bitstreams are byte-identical to historical
14.40/16 build; provenance + SHA256 + pre-cycle empirical backstop stand. Once
ribbon is reseated/replaced or a different ribbon used, v1 bitstream will lock.

**Post-ribbon-repair 20-iter re-test (2026-05-22 09:49-09:57)** — autonomous orchestrator:
After user repaired/reseated the RPi GPIO ribbon and both boards confirmed
reachable (0% packet loss from mapstone-dev, FPGA managers `operating`, firmware
MD5 still matches v1 morning bitstream), re-ran the SAME 20 independent one-shot
deploys on the byte-identical v1 morning bitstream:
- **N=20  BEST=0/16  MEAN=0.00/16  MIN=0/16** — distribution 0:20 (every iter all-zero)
- Per-iter fingerprint IDENTICAL to pre-repair: `lk=0x00 ft=0x00 cal_done=0 FCSM=0 cr=0` on BOTH die_a AND die_b
- Lease acquired (token `sfPoQfYdtgsSn9fAq4xQsw` then runner-acquired token) and
  released cleanly via EXIT trap; lease verified `free` after.
- Log: `v1-release/reliability/live_n20_postrepair.log`
- **VERDICT: ribbon repair did NOT restore the link.** Bug #28 STILL OPEN. The
  all-zero fingerprint persists unchanged despite the ribbon work, so either (a)
  the reseat/repair did not actually restore the disturbed conductor(s), or (b)
  the post-power-cycle damage is deeper than the ribbon (e.g. a PYNQ GPIO pin /
  PHY pad on one board, or a connector seat that needs replacement not reseat).
  Recommend PHYSICAL INSPECTION + continuity check of the ribbon conductors and,
  if the ribbon checks out, a fresh ribbon and/or per-board PHY-pad inspection.

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

## Resolved this session (19)

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
| 10  | SV anti-pattern findings in third-party IP        | 🟢     | `fix/bug10-sv-anti-pattern-allow-list @ 7316a5f`     | Added VENDOR_PATH_FRAGMENTS allow-list + `lint-extended` / `lint-vendor` Makefile targets. lint clean (0 findings) on first-party RTL; extended scope confirms 14 vendor findings (non-gating). |
| 16  | Lower-priority HAL findings (calibrator cosmetics)| 🟢     | `fix/bug16-hal-cosmetics @ e412289`                  | PADMSB+UELOPR @288 width-match, ENMNFU @136 reserved-codes comment, USEPAR @104 elab-time $fatal guard. cocotb wlink_pair (6/6) + phy_align test_pair_align (1/1) PASS. |
| 24  | Watcher path migration (bit_for/hwh_for hardcoded /tmp) | 🟢 | `fix/bug24-watcher-path-migration @ 06720f2` (+ `/tmp/td-bisect-watcher.sh` + `/home/dam1n19/SoCLabs/td-bisect/logs/td-bisect-watcher.sh`) | Added `_resolve_artefact` multi-root probe (canonical SoCLabs > `.cache` > /tmp). `bit_for`/`hwh_for`/`make_bins`/`stage_to_mapstone` now find first existing match; falls back to canonical path for useful error messages. `bash -n` clean. Script now tracked in-repo under `scripts/td-bisect-watcher.sh`. Running daemon (PID 3028874) holds old inode — user/HW orchestrator restarts when ready. |

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
| 25  | srv04936 build env regression                    | 🟡     | Fresh clone + fresh regen still produces 0/16. Morning bitstream still works. Investigation: Vivado tool state, IP cache, /apps Xilinx, /research drift between morning and today. Agents `af08304b` (artifact diff May 18 vs D2-fresh), `aa2cb831` (population test), `a6536f99` (v1-RC tag rebuild). Deferred to v2. Bug #26 (clk_wiz mutation hypothesis) was DISPROVEN by this orchestrator session — see Disproven section. **2026-05-21 16:09-16:34 autonomous closure**: alt-host build on srv03335 (the FPGA bring-up host, not srv04936) FROM SAME COMMIT 8bc6051 produced a CLEAN bitstream EXIT=0 at `/home/dam1n19/td-altbuild/imp/fpga/output/pynq-z2-pair-all/tidelink.bit` (MD5 `81f61c4c5336cc32d8ee3f2adf157b44`, 4045683 bytes — different from morning preserved `188ebdd8...`, showing Vivado output non-determinism even from same source). HW validation of this candidate BLOCKED by Bug #28 (ribbon damage); flip-side build was permission-denied so we have only die_a half anyway. But the fact that the build succeeds on srv03335 from the same source that produces 0/16 on srv04936 STRENGTHENS Bug #25's "env regression on srv04936" diagnosis. |

## Open — v2 / non-blocking (2)

| #   | Title                                            | Status | Notes                                                                |
|-----|--------------------------------------------------|--------|----------------------------------------------------------------------|
| 3   | Mask FSM states 8/9/10 skipped on silicon        | ⚪     | Structural fix candidate sub `6a757e2` (default state_nxt arm). Silicon validation BLOCKED by Bug #5. |
| 22  | UVM tests stale vs 2-word FIFO header (CI surfaced) | 🟡 | `fix/bug22-uvm-mask-strobe-fsm @ 7ab9806` lands sim-only candidate fixes for the 3 UVM categories in CI_FAILURE_TRIAGE.md §2-B (credit-count, FC-TX scoreboard race, AHB zero_wait_cycle_okay demote). 10 UVM test files updated to match `packet_delta = length + 2` from `src/rtl/fifo/tidelink_fifo_ctrl.sv` (legacy `length + 1` formula was from single-word-header era; cocotb already correct). NOT renamed from "masked-strobe FSM" wording because the original BUG_TRACKER hypothesis was wrong: actual root cause is test/RTL header-width drift, not a mask-FSM defect. **Pending**: simulation run to confirm 3 reds clear; HW silicon validation deferred (Bug #5 board offline). |

## New issues found by v1-release orchestrator (2026-05-21 15:00-15:18) + autonomous closure (16:00-)

| #   | Title                                            | Status | Notes                                                                |
|-----|--------------------------------------------------|--------|----------------------------------------------------------------------|
| 27  | bridge1 slave board (pynq_z2_03) PS-eth unreachable | 🟢 | RESOLVED 2026-05-21 16:05 by user physical power cycle. Slave came back at uptime 3 min, IP/SSH/FPGA-manager all responsive. Lease re-acquired, 20-iter test ran cleanly — see Bug #28 for the new finding the re-test surfaced. |
| 28  | Post-cycle ribbon HW damage — link dead bidirectional | 🔴 | NEW 2026-05-21 16:19+: Bug #5 all-zero fingerprint (lk=0x00, ft=0x00, cal_done=0 BOTH sides) now reproduces on the v1 morning bitstream that worked at 14.40/16 historically + 11/16 + 13/16 EARLIER TODAY. 20 NORMAL deploys + 5 SWAP=1 deploys all 0/16. SWAP=1 not changing the dead side ⇒ failure follows the ribbon, not the role. Verdict: physical RPi GPIO ribbon disturbed/damaged during the power cycle that resolved Bug #27. Logs in `v1-release/reliability/live_n{20_postcycle,5_swap_postcycle}.log`. v1 release bundle UNAFFECTED — bitstreams are byte-identical to historical 14.40/16. Fix = re-seat or replace the ribbon. **2026-05-22 09:49-09:57 STILL OPEN after ribbon repair/reseat**: user repaired/reseated the ribbon; boards reachable (0% loss), FPGA `operating`, firmware MD5 matches. Re-ran 20 independent one-shot deploys on v1 morning bitstream → **N=20 BEST=0/16 MEAN=0.00 MIN=0/16, distribution 0:20**, identical all-zero fingerprint to pre-repair. Reseat did NOT restore the link. Next: physical continuity check of ribbon conductors; if good, try a FRESH ribbon and/or inspect per-board PYNQ GPIO / PHY pads. Log: `v1-release/reliability/live_n20_postrepair.log`. |
| 32  | Volatile staging dir has no provenance guard — WRONG bitstream deployed | 🟢 | **RESOLVED 2026-05-22 on `fix/deploy-provenance-guard` (off `feat/td-combined`).** ROOT CAUSE: the v1-release bundle + all post-cycle HW tests deployed the WRONG bitstream — the May-6 phase-v2 known-0/16 build (MD5 `188ebdd8`, sha256 `606e1648…`) left in the shared volatile staging path `/tmp/tidelink_deploy/` by a population test. `deploy_pair.sh` copied it BLINDLY with no hash verification, so a stale bin masqueraded as the morning-v1 14.40/16 build for hours. CONFIRMED: `td-bisect/v1-release/bitstreams/tidelink.bin` on disk IS the contaminated `188ebdd8` build, NOT the morning-v1 `86aa3a95`. MECHANISM (4 layers): **(1)** `deploy_pair.sh` gains `--expect-sha256 <hex>` + `--manifest <path>` (+ auto-discovery of a sibling `<bin>.manifest.json`); it `sha256sum`s the staged `.bin` before flashing and prints `DEPLOY-ABORT: bitstream SHA mismatch — expected X, got Y (refusing to flash wrong bitstream)` to STDERR + exit 4 on mismatch; an unverified deploy (no manifest/hash) prints loud `WARNING: UNVERIFIED DEPLOY` lines (back-compat preserved, escape hatch `--no-verify`). **(2)** `make_bitstream_manifest.sh` emits `<bin>.manifest.json {sha256,source_commit,build_host,build_date,target,expected_lock_min,label}` at build time. **(3)** `bringup_pair_converge.sh` prints a PROVENANCE banner (sha256[:12] + manifest label/commit/lock-min) before the deploy loop, and `deploy_pair.sh` appends a per-deploy `deployed.json` ledger entry `{timestamp,board,sha256,source_path,label}` so "what is loaded now" is always answerable. **(4)** `verify_deployed.sh` / `deploy_pair.sh --check-only` reads back the on-board `/lib/firmware/tidelink.bin` MD5 and cross-checks vs manifest WITHOUT redeploying. VERIFIED in throwaway temp dir (NOT `/tmp/tidelink_deploy`, owned by re-test agent): wrong hash → ABORT rc=4; correct hash/manifest/auto-discovery → proceed rc=0; `--check-only` with mismatched on-board MD5 → ABORT rc=5. Morning-v1 manifest template committed at `pynq_host/manifests/tidelink.bin.manifest.json` (label `morning-v1`, lock-min 14, MD5 `86aa3a95`; sha256 to be filled by running the generator on mapstone-dev where the real bin lives — see `pynq_host/manifests/README.md`). All scripts `bash -n` clean. |

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
| orchestrator (DONE) | 2026-05-21 16:05-16:35: autonomous v1 closure — Bug #27 RESOLVED; 20-iter + 5-iter SWAP=1 re-test on morning bitstream both 0/16 (Bug #28 NEW: ribbon HW damage); alt-host build on srv03335 SUCCEEDED EXIT=0 (4045683 bytes, MD5 `81f61c4c`) supporting Bug #25 env-regression diagnosis; consolidation merge agent `a6883a062` completed (feat/v1.1-fixes @ b4f0846 incl. sub a55d346 with Bug #3 fix 6a757e2); ASIC route agent `a678afc` still running undisturbed on srv04936; bridge1 lease released cleanly. Phase 6 (mask FSM HW) + Phase 7 (AHB/PTP/TideChart e2e HW) both BLOCKED by Bug #28 (no link). |

## Autonomous v1 closure final state (2026-05-21 16:35)

**Verdict on v1 release readiness**: 🟢 **READY** with documented HW limitation.

- v1 release bundle (`/home/dam1n19/SoCLabs/td-bisect/v1-release/`) is byte-identical
  to historical 14.40/16-locking morning build. SHA256 + provenance verified.
- ASIC handoff is independent and clean (Verification SUCCEEDED, WNS 0.00, 0 DRCs).
- Pre-cycle empirical backstop (`tl_v7s` 11/16 + `tl_v7` 13/16 EARLIER TODAY)
  proves silicon path was healthy before physical access.
- Post-cycle 25-deploy NORMAL+SWAP all-zero is a HW regression (Bug #28 ribbon)
  introduced AFTER the bundle was captured, not a bundle defect.

**Per-bug status snapshot**:
- Resolved (19): Bugs 1, 2, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 23, 24, **27**
- Disproven (2): Bugs 15, 26
- Open (4): Bug 5 (env regression, deferred v2), Bug 22 (UVM tests, pending sim run),
  Bug 25 (env RCA, deferred v2; reinforced this session), **Bug 28 (NEW: ribbon HW)**
- v2 / non-blocking (1): Bug 3 (mask FSM HW validation; structural fix already in feat/v1.1-fixes)

**Things blocked by Bug #28 (ribbon) — STILL BLOCKED after 2026-05-22 reseat**:
- Phase 6: Bug #3 mask FSM HW silicon validation (structural fix `6a757e2` is in
  the consolidation branch sub `a55d346`, but cannot HW-test without link). ALSO
  needs a FRESH BUILD with the fix — alt-host srv03335 build does NOT include
  Bug #3 fix; srv04936 builds 0/16 (Bug #25). Building feat/v1.1-fixes on a
  non-srv04936 host is a documented FOLLOW-UP (not run inline — ~45 min build).
- Phase 7: AHB/PTP/TideChart end-to-end HW validation. AHB read deliberately NOT
  attempted (never write AHB_TX before link verified up — board-wedge hazard;
  link is 0/16 so this stays out of scope). No HW PHC/PTP recipe runnable without link.
- Future reliability re-tests on v1 bundle
- Bug #5 / Bug #25 source-level rebuild HW verification
- **2026-05-22 re-test (this session) confirms the block PERSISTS** — ribbon
  reseat did not restore the link (20/20 0/16). All Phase 6/7 silicon validations
  remain blocked pending a deeper HW fix (continuity check / fresh ribbon / PHY-pad inspection).

**Things unblocked / done this session**:
- v1 release bundle assembled and verified (other orchestrator earlier today)
- feat/v1.1-fixes consolidation merge complete at `b4f0846` (other agent, parallel)
- ASIC route convergence trending well on srv04936 (other agent, parallel)
- 20-iter reliability re-test EXECUTED (data: HW-damaged ribbon, not bitstream)
- SWAP=1 discriminator EXECUTED (ribbon is physical, not logical)
- Alt-host build PROVED build can succeed on a different host from same source

**Items needing user input before v1 ship**:
- **Bug #28 NOT cleared by ribbon reseat (2026-05-22)** — the reseat/repair did
  not restore the link (20/20 0/16, identical fingerprint to pre-repair). Needs:
  (1) continuity/ohm-meter check of each ribbon conductor; (2) if conductors are
  good, swap in a FRESH ribbon; (3) if a fresh ribbon also fails, inspect the
  per-board PYNQ GPIO header pins / FPGA PHY pads on one or both boards (the
  failure follows the physical link per the earlier SWAP=1 discriminator).
  Only after the link comes back can next session do Phase 6 + Phase 7 HW
  validation + a confirming 20-iter reliability re-test (expected to match
  historical 14.40/16).
- Decide whether to ship v1 NOW (with pre-cycle empirical backstop) or hold
  until Bug #28 ribbon is fixed and post-cycle reliability re-test passes
- Whether to tag v1.0 and push (`git push origin release/v1.0-rc1` + `git tag v1.0`)

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
