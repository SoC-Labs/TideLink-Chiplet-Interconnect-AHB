# Link-decay-after-converge bisect across the PHC integration window

**Date:** 2026-05-23
**Operator:** dam1n19 (agent run)
**Rig:** bridge1 = pynq_z2_02 (master, 192.168.4.101) + pynq_z2_03 (slave, 192.168.6.101)
**Repo HEAD at bisect:** `main @ d08c27e`
**Lease:** bridge1 token `heVRB8muEs6FtqfRqv2JDQ` (granted 2026-05-23T11:43Z, released cleanly)

## TL;DR

**Verdict: NO REGRESSION. The link-decay attributed to build #8 in
`docs/PHC_PHASE1_HW_REPORT.md` was a PROVENANCE MIX-UP — the failing PHC
pre-flight reads (`lk=0xf5/0x7e`, `lk=0xf5/0xef`) ran against the
**rc2 / 72c280b** bitstream still cached in `/tmp/tidelink_deploy/` on
mapstone-dev, NOT against the today rebuild (build #8, commit `034376f`).
The actual build #8 bins are rock-solid 0xff/0xff stable across both
immediate and +30 s hold-polls, AND through a full 60 s PHC-sync probe.**

The PHC pre-flight gate (`check_link_up` in `_ptp_common.sh`) was reading a
*real but pre-existing* rc2 wobble, mis-attributed to a fresh build.
Bug #32 (wrong-bitstream guard) is exactly the class of failure that just
re-bit us — `bringup_pair_converge.sh` already warned `UNVERIFIED DEPLOY`
on every run and was ignored.

## Bitstreams under test

| Label | Source commit | tidelink.bin sha256 (12) | tidelink-flip.bin sha256 (12) | Era |
| --- | --- | --- | --- | --- |
| **rc2 / v1-release** | `72c280b` (2026-05-22) | `dd54203bc871…` | `b50553bfc260…` | **PRE-PHC** (before 20c1eaa/5cbbc0f/9b96525) |
| **build #8** | `034376f` (2026-05-23) | `a25534465e5c…` | `5951958085fd…` | **POST-PHC** |

Both pairs exist as files on mapstone-dev:
- `~/td_rc2_stage/tidelink{,-flip}.bin` → rc2
- `~/td_milestone_stage/tidelink{,-flip}.bin` → build #8
- `/tmp/tidelink_deploy/` is the live staging directory `deploy_pair.sh`
  reads from — **had rc2 cached when the original PHC test ran**, never
  refreshed when build #8 landed.

The repo's `v1-release/bitstreams/tidelink{,-flip}.bin` are byte-identical to
the rc2 set on mapstone-dev (cross-checked locally).

## Method

For each bitstream pair (rc2, build #8):

1. `cp` the chosen pair into `/tmp/tidelink_deploy/` on mapstone-dev.
2. `bringup_pair_converge.sh` (default `MAX_RETRIES=12 STABLE=3 BESTOF=3`),
   record the iteration of first convergence.
3. **5-sample hold-poll immediately after convergence** (5 × 0.5 s).
4. Sleep 25 s, then **a second 5-sample hold-poll** to characterise drift over
   the ~30 s window in which PHC pre-flight typically runs.
5. (Build #8 only) chain a full `bringup_ptp_sync.sh` to verify the failure
   mode reported in `PHC_PHASE1_HW_REPORT` does NOT reproduce on the real
   build #8 bins.

Hold-poll reads SWI_LANE_STATUS (`0x44032108`) via the same /dev/mem path
the operational scripts use — no extra protocol.

## Raw evidence

### rc2 — pre-PHC (commit 72c280b)

```
PROVENANCE — tidelink.bin sha256 dd54203bc871…  tidelink-flip.bin sha256 b50553bfc260…
1    | 0xff/0x00 8 1 fs4 cr1          | 0xff/0x00 8 1 fs4 cr0          | 16
RESULT: CONVERGED — full 16/16 bidirectional link at iteration 1

Hold-poll T+0s (5 samples × 2 sides, 0.5 s gap):
 0.00 | die_a | 0xff pc8     1.04 | die_b | 0xfe pc7
 2.64 | die_a | 0xff pc8     3.71 | die_b | 0xff pc8
 5.29 | die_a | 0xff pc8     6.34 | die_b | 0xfe pc7
 8.09 | die_a | 0xff pc8     9.16 | die_b | 0xfe pc7
10.78 | die_a | 0xfd pc7    11.82 | die_b | 0xff pc8
  → per-side mean ≈ 7.6/8;  pair total ≈ 15.2/16 with single-lane bounce

Hold-poll T+30s (5 samples × 2 sides):
 0.00 | die_a | 0xff pc8     1.09 | die_b | 0xff pc8
 ... 9/10 reads 0xff pc8; one die_b 0xfe pc7 at t=11.79
  → per-side mean ≈ 7.95/8;  pair total ≈ 15.9/16 — *less* drift than T+0
```

### build #8 — post-PHC (commit 034376f)

```
PROVENANCE — tidelink.bin sha256 a25534465e5c…  tidelink-flip.bin sha256 5951958085fd…
1    | 0xff/0x00 8 1 fs2 cr1          | 0xff/0x00 8 1 fs1 cr0          | 16
RESULT: CONVERGED — full 16/16 bidirectional link at iteration 1

Hold-poll T+0s (5 × 2): every single read 0xff pc8 (10/10)
Hold-poll T+30s (5 × 2): every single read 0xff pc8 (10/10)

Chained converge → bringup_ptp_sync.sh → hold-poll:
  PHC pre-flight: link: master lk=0xff cd=1  slave lk=0xff cd=1   ← PASSES
  60 s convergence loop ran to completion (servo did not lock — different issue,
  but link health was preserved throughout).
  Post-PHC hold-poll: 10/10 reads 0xff pc8 — no decay.
```

## Decay characterisation summary

| Bitstream | Converge iter | T+0 5-sample mean (per-side / 8) | T+30 5-sample mean (per-side / 8) | Verdict |
| --- | --- | --- | --- | --- |
| rc2 (pre-PHC) | 1 | 7.6 | 7.95 | bouncy but stable around 15.2–15.9/16; single-lane TIE-flap |
| build #8 (post-PHC) | 1 | 8.00 | 8.00 | rock-solid 16/16 — strictly better than rc2 |

The numbers are bounded reads, but the qualitative picture is unambiguous:
**build #8 is the same as or better than rc2 on link stability.** The
"decay to lk=0xf5/0x7e" never happens on build #8 bins; the read in
`PHC_PHASE1_HW_REPORT` is what rc2 occasionally shows when a deeper
calibrator transient catches the snapshot.

## Root cause of the original mis-attribution

The previous chain was:

1. **2026-05-22 evening**: rc2 (`72c280b`) staged at `/tmp/tidelink_deploy/`
   on mapstone-dev for v1-release validation, deployed many times
   (deployed.json shows 30+ deploys 2026-05-22T23:35–23:43 with sha
   `df0c5d…` / `eb89d5…` — that is the literal scp'd-onto-board sha,
   different from the staging sha because the board re-pads the .bin —
   point is, source-of-record was rc2 in `/tmp/tidelink_deploy/`).
2. **2026-05-23 morning**: build #8 bitstreams produced locally
   (`/home/dam1n19/td_milestone_stage/` md5 `65ad6c…` / `e4f4e4…`), pushed
   to mapstone-dev `~/td_milestone_stage/`. **Nothing touched
   `/tmp/tidelink_deploy/`.**
3. `bringup_pair_converge.sh` reads from `/tmp/tidelink_deploy/`, prints the
   sha (`dd54203bc871…` — rc2), and warns `UNVERIFIED DEPLOY` four times.
   The warnings were ignored. Both `converge.build8.log` and `phc.b1.sync.log`
   on mapstone-dev show the rc2 sha in their provenance banner.
4. `bringup_ptp_sync.sh::check_link_up` caught rc2's transient drift, exited
   3, and the operator/agent wrote up the failure as a "build #8 regression."

Build #8 was never actually deployed in that session.

## Recommended next-step debug actions

1. **Immediate**: re-run `bringup_pair_converge.sh` + `bringup_ptp_sync.sh`
   chain on mapstone-dev with the correct build #8 bins in
   `/tmp/tidelink_deploy/`. Result is already known (this report) but should
   be re-run by the human operator to overwrite the bad log set. The PHC
   pre-flight will pass; the actual PHC convergence work can then proceed.
2. **Process**: amend `pynq_host/scripts/bringup_pair_converge.sh` to make
   `UNVERIFIED DEPLOY` a hard abort by default, with `--no-verify` to
   explicitly opt out. The warning has now been ignored at least twice
   (Bug #32 and this incident). Cost is trivial; benefit is closing this
   class permanently.
3. **Process**: amend the operator brief / `PHC_PHASE1_HW_REPORT` workflow
   to require an explicit `md5sum /tmp/tidelink_deploy/*.bin` print as
   step 0 of any HW characterisation; cross-check against the manifest in
   `pynq_host/manifests/` or the local source `td_milestone_stage`.
4. **`docs/PHC_PHASE1_HW_REPORT.md` correction**: mark the "Build #8 attempt"
   section as **SUPERSEDED — wrong bitstream cached; build #8 link is stable;
   see `LINK_DECAY_BISECT.md`**. Do not delete (audit trail).
5. **Optional**: investigate the rc2 single-lane TIE-flap (~2/10 reads show
   one lane dropped) as a separate, pre-existing minor stability item. Not
   urgent — does not block PHC bring-up.

## Bisect window if a regression *had* been confirmed

For completeness, recording the commit window between rc2 and build #8 so
future bisects start with the right scope. **No regression was found, so no
bisect is needed.**

- `72c280b` (rc2) → `d08c27e` (HEAD) = 98 commits.
- Key FPGA/PHC-domain commits in that window:
  - `200666e` integrate PHC IP into pair + pair-flip BD
  - `5cbbc0f` / `9b96525` mirror PHC IP onto -all / -flip-all
  - `20c1eaa` Merge feat/phc-hw-test
  - `caf1079` Merge feat/phc-all-mirror
  - `d46412e` set_false_path on ila_rx PROBE_PIPE (post-PHC hold fix)
  - `99fa930` ila_rx hold-path XDC retarget
  - `034376f` replace vestigial ila_rx waiver with dbg_hub BSCAN TCK
    false_path
  - `dab4955` (post-build) SpyGlass CDC §3.1/§3.2 — *RTL change post-build #8,
    NOT in build #8 binary; would only matter on a rebuild*

If a future build does show a real decay regression, the PHC IP integration
chain (`200666e` → `caf1079`) is the largest functional delta and should be
bisected first.

## Hardware time

- Lease acquired: 2026-05-23T11:43Z, GRANTED on both pynq_z2_02_pl and
  pynq_z2_03_pl.
- Tests run: 3 deploy/converge cycles (rc2, build #8, build #8 + PHC chain).
- Lease released cleanly: 2026-05-23T11:51Z.
- Total HW time: ~8 min. No rebuilds performed (per brief).

---

*A joint work commissioned on behalf of SoC Labs, under Arm Academic
Access license. David Mapstone (d.a.mapstone@soton.ac.uk).
Copyright (C) 2026, SoC Labs (www.soclabs.org).*
