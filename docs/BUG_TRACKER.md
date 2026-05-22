# TideLink Bug Tracker

Persistent catalogue of bugs surfaced during v1 push (2026-05-20 → 2026-05-21).

**Legend**: 🟢 Resolved · 🟡 In progress · 🔴 Blocking · ⚪ v2 / non-blocking · 🧊 Disproven

## v1 Release Candidate 1.0

**Release branch**: `release/v1.0-rc1` (off `feat/td-combined @ 57c2810`)
**Release commit SHA**: see git log on `release/v1.0-rc1` — added 2026-05-21
**On-disk bundle**: `/home/dam1n19/SoCLabs/td-bisect/v1-release/` (~125 MB total)
**In-repo tree**: `v1-release/` on the release branch (~9.3 MB; large ASIC binaries referenced by path in `asic/BINARIES.md`)

### Bitstream SHA256 — FPGA artifact = `tl_v7` (13/16 confirmed)

> ✅ **REBUILT (2026-05-22, Bugs #31/#33/#34):** the v1 bundle now ships the
> `tl_v7` bitstream — the highest *confirmed-locking* build we possess
> (**13/16 best, cal_done=1**, validated pre- and post-power-cycle 2026-05-22).
> The earlier bundle shipped the phase-v2 KNOWN-BAD `188ebdd8`/`606e1648` build
> (Bug #33) and the docs falsely attributed a "14.40/16 morning" lock rate to a
> blob (`86aa3a95`/`40f6477c`) that actually measures **0/16 on healthy HW**
> (Bug #34 — that blob's `.bit` build-date is 2026-05-20 23:41 *evening*, and it
> is now relabelled `hwval-eve-NONLOCKING` in the artifact store). The TRUE
> 14.40/16 build is **UNIDENTIFIED** (Bug #35). We do **not** claim 14.40/16 for
> `tl_v7`; its honest, measured lock rate is **13/16 best**.

| File | SHA256 (tl_v7) | MD5 | Provenance |
|---|---|---|---|
| `tidelink.bin`      | `3cedd3ba42ccb5e65f6419dcb414255c401e128ec5764743d2e8289a5377e033` | `b0633476` | ✅ tl_v7 master — 13/16 confirmed |
| `tidelink.hwh`      | `9860f4f39ee76ed2dbcd8c603556029531e21d8f34e61b84e5bf38e74b98c13a` | `98f2a48d` | ✅ tl_v7 BD memory map |
| `tidelink-flip.bin` | `60b84430a5da24dd208cfacd01fa29e1d6161e5743f294f98298afb01870e0e7` | `d5f42180` | ✅ tl_v7 slave (mirrored pin map) |
| `tidelink-flip.hwh` | `0b6b17d041ddbce266399843fff08fd1f9463cde8060325fd3a0abc27bd115c7` | `33cd0261` | ✅ tl_v7 flip map |

Deploy-guard manifests `tidelink.bin.manifest.json` / `tidelink-flip.bin.manifest.json`
(label `tl_v7`, `expected_lock_min=12`) ship alongside the bins. Artifact-store
tag: `tl_v7` (`td-artifact show tl_v7`).

### Reliability — confirmed FPGA lock rate

**Shipped artifact `tl_v7`: 13/16 best, cal_done=1 — confirmed pre + post power-cycle (2026-05-22).**
This is the authoritative, honest lock rate for the v1 FPGA deliverable.

| Build | Best | Mean | cal_done | Status |
|---|---|---|---|---|
| `tl_v7`  (md5 `b0633476`) | **13/16** | ~8/16 | 1 | ✅ SHIPPED — confirmed pre (14:53) + post power-cycle |
| `tl_v7s` (md5 `8c6e16d1`) | 11/16 | ~6/16 | 1 | ✅ confirmed locking (sibling) |
| `phase-v2` (md5 `188ebdd8`) | 0/16 | 0 | 0 | ❌ KNOWN-BAD — was wrongly bundled (Bug #33) |
| `hwval-eve` (md5 `86aa3a95`) | 0/16 | 0 | 0 | ❌ NON-LOCKING — was mislabelled "morning-v1 14.40/16" (Bug #34) |
| true 14.40/16 build | ? | 14.40 | ? | ⬜ UNIDENTIFIED (Bug #35) |

**Bug #28 (suspected ribbon damage) was a 🧊 FALSE ALARM.** A series of post-power-cycle
and post-ribbon-repair runs (2026-05-21 16:19 → 2026-05-22 09:57) showed 0/16 and were
mis-diagnosed as physical HW damage. The decisive disambiguation: re-deploying `tl_v7`
on the same rig AFTER the power-cycle reproduced its pre-cycle **13/16** exactly
(NORMAL best 13/16 mean 8.5; SWAP=1 best 13/16 mean 9.1; cal_done=1 every iter, no
directional-dead or board-stuck pattern). The hardware is fine — the 0/16 runs were a
*bitstream-specific* failure of the non-locking `phase-v2`/`86aa3a95` builds, not damage.
No physical repair or continuity check is needed.

**Consequence:** the build that carried the "14.40/16 morning-v1" label
(`86aa3a95`/`40f6477c`) locks 0/16 on healthy HW, so it is NOT the 14.40/16 build —
it was misattributed (Bug #34, now relabelled `hwval-eve-NONLOCKING`). The TRUE
14.40/16 build is unidentified (Bug #35). v1 therefore ships `tl_v7` (13/16), the best
*confirmed*-locking build we actually have.

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

## Resolved this session (20)

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
| 32  | Volatile shared `/tmp/tidelink_deploy` staging → wrong-bitstream mixup | 🟢 | `feat/td-artifact-store` (`pynq_host/td_artifact.py` + `scripts/td-artifact` + `ARTIFACT_STORE.md`) **+** deploy-provenance-guard (`fix/deploy-provenance-guard` `deploy_pair.sh --expect-sha256/--manifest`) | **Root cause**: deploys read whatever `.bin` was sitting in the shared, volatile `/tmp/tidelink_deploy/`. A population test left a known-bad 0/16 May-6 phase-v2 build there and it was captured BLINDLY into the v1 release bundle. **Proof of the mixup**: v1 release `tidelink.bin` SHA256 `606e1648…cd2d` (MD5 `188ebdd8`) is **byte-identical** to what is now labelled `phase-v2-KNOWN-BAD`; the v1 FPGA artifact was repointed to a *different* blob — see Bug #34: the `40f6477c` blob originally labelled `morning-v1` "14.40/16" is actually non-locking (0/16) and is now relabelled `hwval-eve-NONLOCKING`. **Fix**: content-addressed artifact store on `mapstone-dev:~/tidelink-artifacts/` — write-once `blobs/<sha256>/`, mutable `tags/<label>` symlinks, "deploy by label not path", sha256 re-verified at deploy time, and `deploy` composes with the guard by writing a `<bin>.manifest.json` sidecar + passing `--expect-sha256`. Current tags (post Bug #34 correction): `tl_v7` (13/16 ✓ confirmed best), `tl_v7s` (11/16 ✓), `phase-v2-KNOWN-BAD` (0/16, DO NOT SHIP), `hwval-eve-NONLOCKING` (0/16, ex-`morning-v1` mislabel). The known-bad builds are permanently labelled so they can never be confused for a good one again. CLI selftest 42/42 PASS. |

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
| 28  | Post-cycle ribbon HW damage — link dead bidirectional | 🧊 | **FALSE ALARM (closed 2026-05-22).** A run of post-power-cycle / post-ribbon-repair tests (2026-05-21 16:19 → 2026-05-22 09:57) returned 0/16 and were mis-diagnosed as physical RPi-GPIO ribbon damage. DISPROVEN: re-deploying `tl_v7` (md5 `b0633476`) on the same rig AFTER the power-cycle reproduced its pre-cycle **13/16 EXACTLY** (NORMAL best 13/16 mean 8.5; SWAP=1 best 13/16 mean 9.1; cal_done=1 every iter; no directional-dead/board-stuck pattern). The hardware is healthy — the 0/16 runs were a *bitstream-specific* failure of the non-locking `phase-v2` (`188ebdd8`) and mislabelled `hwval-eve` (`86aa3a95`) builds, NOT damage. No ribbon swap / continuity check needed. This false alarm is what motivated Bug #34 (mislabelled artifact) and Bug #35 (true 14.40/16 unidentified). |
| 32  | Volatile staging dir has no provenance guard — WRONG bitstream deployed | 🟢 | **RESOLVED 2026-05-22 on `fix/deploy-provenance-guard` (off `feat/td-combined`).** ROOT CAUSE: the v1-release bundle + all post-cycle HW tests deployed the WRONG bitstream — the May-6 phase-v2 known-0/16 build (MD5 `188ebdd8`, sha256 `606e1648…`) left in the shared volatile staging path `/tmp/tidelink_deploy/` by a population test. `deploy_pair.sh` copied it BLINDLY with no hash verification, so a stale bin masqueraded as the morning-v1 14.40/16 build for hours. CONFIRMED: `td-bisect/v1-release/bitstreams/tidelink.bin` on disk IS the contaminated `188ebdd8` build, NOT the morning-v1 `86aa3a95`. MECHANISM (4 layers): **(1)** `deploy_pair.sh` gains `--expect-sha256 <hex>` + `--manifest <path>` (+ auto-discovery of a sibling `<bin>.manifest.json`); it `sha256sum`s the staged `.bin` before flashing and prints `DEPLOY-ABORT: bitstream SHA mismatch — expected X, got Y (refusing to flash wrong bitstream)` to STDERR + exit 4 on mismatch; an unverified deploy (no manifest/hash) prints loud `WARNING: UNVERIFIED DEPLOY` lines (back-compat preserved, escape hatch `--no-verify`). **(2)** `make_bitstream_manifest.sh` emits `<bin>.manifest.json {sha256,source_commit,build_host,build_date,target,expected_lock_min,label}` at build time. **(3)** `bringup_pair_converge.sh` prints a PROVENANCE banner (sha256[:12] + manifest label/commit/lock-min) before the deploy loop, and `deploy_pair.sh` appends a per-deploy `deployed.json` ledger entry `{timestamp,board,sha256,source_path,label}` so "what is loaded now" is always answerable. **(4)** `verify_deployed.sh` / `deploy_pair.sh --check-only` reads back the on-board `/lib/firmware/tidelink.bin` MD5 and cross-checks vs manifest WITHOUT redeploying. VERIFIED in throwaway temp dir (NOT `/tmp/tidelink_deploy`, owned by re-test agent): wrong hash → ABORT rc=4; correct hash/manifest/auto-discovery → proceed rc=0; `--check-only` with mismatched on-board MD5 → ABORT rc=5. Morning-v1 manifest template committed at `pynq_host/manifests/tidelink.bin.manifest.json` (label `morning-v1`, lock-min 14, MD5 `86aa3a95`; sha256 to be filled by running the generator on mapstone-dev where the real bin lives — see `pynq_host/manifests/README.md`). All scripts `bash -n` clean. **2026-05-22 update:** the `86aa3a95` build the guard would have whitelisted as the "14.40/16" reference is itself non-locking (0/16 on healthy HW — Bug #34). The shipped manifests now reference `tl_v7` (`expected_lock_min=12`, honest 13/16 best). The provenance guard prevents the *wrong* bitstream from shipping; the *right* bitstream (`tl_v7`) is confirmed-locking, so the guard + a real locking artifact now compose correctly. |
| 31/33 | v1-release bundle shipped the WRONG (phase-v2 0/16) bitstream — rebuilt with tl_v7 | 🟢 | **RESOLVED 2026-05-22.** The shipped bundle had `tidelink.bin` = MD5 `188ebdd8` / SHA256 `606e1648…` = the **phase-v2 KNOWN-BAD 0/16** build. Rebuilt both the on-disk bundle (`td-bisect/v1-release/`) and the in-repo tree (`v1-release/`) with the **`tl_v7`** artifact: `tidelink.bin` MD5 `b0633476` / SHA256 `3cedd3ba…`, `tidelink-flip.bin` MD5 `d5f42180` / SHA256 `60b84430…`, plus matching tl_v7 `.hwh` (BD memory map) and deploy-guard `*.manifest.json` sidecars (label `tl_v7`, lock-min 12). Files copied via `ssh 'cat'` (scp broken on mapstone-dev), 18-byte agent-banner prefix stripped, every file re-verified byte-for-byte against the tl_v7 blob. `CHECKSUMS.sha256` regenerated and `sha256sum -c` passes. README/PROVENANCE/KNOWN_ISSUES corrected to state the honest **13/16 confirmed** lock rate (NOT 14.40/16). The phase-v2/86aa3a95 false claims are retracted. |
| 34  | morning-v1 / `86aa3a95` mislabelled (0/16, not 14.40/16) — corrected in artifact store | 🟢 | **NEW + RESOLVED 2026-05-22.** The artifact-store tag `morning-v1` pointed at blob `40f6477c` (master md5 `86aa3a95`) with a FALSE "14/14.40" lock history. On healthy HW this blob measures **0/16, cal_done=0**, and its `.bit` build-date is 2026-05-20 **23:41 (evening)**, not the 11:10 morning build — so the 14.40/16 attribution was wrong. Correction (via staged `td_artifact.py` on `mapstone-dev:~/.td-artifact-bin/`): `untag morning-v1`; re-added the blob under `hwval-eve-NONLOCKING`; manually rewrote the blob `results.jsonl` (originals backed up as `results.jsonl.PRE-BUG34-BAK`) to RETRACT the false 14/14.40 entries (lock numbers nulled so `td-artifact list` max() cannot surface 14) and append the TRUE record `best 0/16, cal_done=0, "0/16 on healthy HW 2026-05-22; mislabelled as morning-v1; build-date 05-20 23:41 evening; NOT the 14.40/16 build"`; corrected the blob `manifest.json` (`expected_lock_min` 14→0, `label`, added note). `td-artifact list` now shows `tl_v7` (13/16) as the highest confirmed-locking build and NO false 14.40/16 claim. |
| 35  | true 14.40/16 build UNIDENTIFIED — open provenance investigation | 🔴 | **NEW 2026-05-22 (OPEN).** Both builds that were ever attributed 14.40/16 — phase-v2 (`188ebdd8`) and the `86aa3a95` "morning-v1" blob — are non-locking (0/16) on healthy HW. The actual build that produced the historical 14.40/16 mean is not currently identified by hash. The best *confirmed*-locking artifact we possess is `tl_v7` (13/16). v1 ships `tl_v7`; 14.40/16 is aspirational, not shipped. **Next:** rebuild the best-known commit on srv03335 (which builds clean — see Bug #25) and hash/HW-test candidates to recover the true 14.40/16 blob, OR accept `tl_v7` 13/16 as the v1 deliverable. |

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
- 🟢 FPGA artifact = **`tl_v7`** (md5 `b0633476` / sha256 `3cedd3ba…`) — confirmed **13/16 best, cal_done=1**, pre + post power-cycle 2026-05-22; preserved at `mapstone-dev:/tmp/tl_v7*` + artifact-store tag `tl_v7`
- 🟢 ~25 preserved historical bitstreams catalogued (output_archive + tl_v2-v7s + hwval)
- 🟢 v1-RC tag at commit `53e4217` (May 21 03:09) — documented pivot: "use preserved bitstream as release artifact"
- 🟢 **v1 release bundle REBUILT with tl_v7** at `/home/dam1n19/SoCLabs/td-bisect/v1-release/` and in-repo `v1-release/` — README, DEMO, KNOWN_ISSUES, PROVENANCE, CHECKSUMS, bitstreams (4 files + 2 manifests, SHA256 verified), asic/ (10 files), fixes/MANIFEST.md
- 🟢 Lock rate honestly documented as 13/16 (Bugs #31/#33). The historical 14.40/16 build is UNIDENTIFIED (Bug #35); the `86aa3a95` build that claimed it is non-locking (Bug #34).

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
| orchestrator (DONE) | 2026-05-21 16:05-16:35: autonomous v1 closure — Bug #27 RESOLVED; 20-iter + 5-iter SWAP=1 re-test on morning bitstream both 0/16 (Bug #28 NEW: ribbon HW damage); alt-host build on srv03335 SUCCEEDED EXIT=0 (4045683 bytes, MD5 `81f61c4c`) supporting Bug #25 env-regression diagnosis; consolidation merge agent `a6883a062` completed (feat/v1.1-fixes @ b4f0846 incl. sub a55d346 with Bug #3 fix 6a757e2); ASIC route agent `a678afc` still running undisturbed on srv04936; bridge1 lease released cleanly. Phase 6 (mask FSM HW) + Phase 7 (AHB/PTP/TideChart e2e HW) both BLOCKED by Bug #28 (no link). _[SUPERSEDED 2026-05-22: Bug #28 was a FALSE ALARM — HW is healthy; see Bug #28 row and the FALSE-ALARM note above.]_ |

## Autonomous v1 closure final state (2026-05-21 16:35)

**Verdict on v1 release readiness (updated 2026-05-22)**: 🟢 **READY** with an honest 13/16 FPGA lock rate.

- v1 release bundle (on-disk `td-bisect/v1-release/` + in-repo `v1-release/`) now ships
  the **`tl_v7`** bitstream — confirmed **13/16 best, cal_done=1**, pre + post power-cycle.
  SHA256 + provenance + deploy-guard manifests verified; `sha256sum -c` passes.
- ASIC handoff is independent and clean (Verification SUCCEEDED, WNS 0.00, 0 DRCs).
- Bug #28 (suspected ribbon damage) is a 🧊 FALSE ALARM — the HW is healthy; the earlier
  0/16 runs were the non-locking phase-v2/`86aa3a95` builds, not damage.
- The historical 14.40/16 figure is NOT shipped: that build is unidentified (Bug #35),
  and the artifact that claimed it (`86aa3a95`) is non-locking (Bug #34, relabelled
  `hwval-eve-NONLOCKING`). v1 ships the honest best confirmed build, `tl_v7` 13/16.

**Per-bug status snapshot**:
- Resolved (23): Bugs 1, 2, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 23, 24, **27**, **31/33**, **32**, **34**
- Disproven / false alarm (3): Bugs 15, 26, **28**
- Open (3): Bug 5 (FPGA rebuild regression, deferred v2), Bug 22 (UVM tests, pending sim run),
  Bug 25 (srv04936 env RCA, deferred v2)
- Open / new (1): Bug **35** (true 14.40/16 build unidentified — provenance investigation)
- v2 / non-blocking (1): Bug 3 (mask FSM HW validation; structural fix already in feat/v1.1-fixes)

**HW is HEALTHY (Bug #28 was a FALSE ALARM, 2026-05-22)**:
- `tl_v7` re-deploy confirmed 13/16 post-power-cycle, identical to pre-cycle — the rig
  links fine. The earlier "ribbon damage" / "STILL BLOCKED after reseat" entries were
  diagnosing the non-locking phase-v2/`86aa3a95` bitstreams, not hardware.
- Phase 6 (Bug #3 mask-FSM HW validation) and Phase 7 (AHB/PTP/TideChart e2e) are no
  longer HW-blocked; they now only need a FRESH build that includes the Bug #3 fix
  (alt-host srv03335 build did not include it; srv04936 still 0/16 — Bug #25).

**Things done this session (2026-05-22)**:
- Bug #28 disproven (🧊 false alarm) via tl_v7 pre/post-cycle 13/16 reproduction.
- Artifact store corrected (Bug #34): `morning-v1` → `hwval-eve-NONLOCKING` (0/16);
  `tl_v7` promoted with confirmed 13/16 lock history.
- v1 bundle rebuilt with `tl_v7` (Bugs #31/#33): bins + hwh + manifests + CHECKSUMS,
  byte-verified, docs corrected to honest 13/16.

**Items needing user input before v1 ship**:
- Ship decision: `tl_v7` (13/16 confirmed) is the shippable FPGA artifact NOW. The
  14.40/16 figure is unidentified (Bug #35) and aspirational — decide whether to ship
  `tl_v7` as v1 or hold to hunt the true 14.40/16 build (rebuild best commit on srv03335).
- Whether to tag v1.0 and push (`git push origin release/v1.0-rc1` + `git tag v1.0`).

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

- Morning baseline: `8bc6051` + sub `de44db6` — historically cited @ 14.40/16, but the blob bearing that label (`86aa3a95`) is non-locking 0/16 (Bug #34); the true 14.40/16 build is unidentified (Bug #35). Rebuild today 0/16 (env regression). The shipped FPGA artifact is `tl_v7` (13/16).
- v1-RC tag: `53e4217` + sub `a510bae` (99 commits ahead of morning) — rebuild status TBD by agent `a6536f99`
- feat/td-combined HEAD: `57c2810` (msg-gate; 23 commits ahead of v1-RC) — rebuild status 0/16
- **Bisect scope = 23 commits in v1-RC..HEAD** (only relevant if v1-RC rebuilds clean)
