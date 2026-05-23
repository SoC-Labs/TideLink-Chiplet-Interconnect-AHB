# PHC Phase-1 Slave-RX — Historical Bisect

**Date:** 2026-05-23
**Branch:** `main` @ `b61c84a` (+ this doc commit)
**Author:** dam1n19 (agent run)
**Scope:** Determine whether the slave-side PHC HW_SYNC RX path has ever
worked on bridge1 hardware, and if so, identify the breaking commit.

---

## Top-line verdict

**ALWAYS BROKEN ON HW — never observed working on silicon.** PHC RTL has
been in the codebase since `72f6bf6` (2026-04-04, "Adding PTP support to
tidelink") and the IP was only first wired into the *production* `-all`
deploy targets on 2026-05-23 (commits `5cbbc0f` + `9b96525`, merge
`caf1079`). Every single HW capture of slave `HW_SYNC_STATUS` since the
IP became physically deployable shows `0x0000_0000`. There is no
historical record — staged log, archived bitstream manifest, or git
commit message — claiming a non-zero slave `HW_SYNC_STATUS` on bridge1.

The PHC slave-RX path is **NOT a regression**. It is a never-validated
path that was integrated, deployed, and immediately found broken on first
HW try (build #7, 2026-05-23 ~10:48 BST), and has stayed broken across
13 build cycles.

---

## Timeline of PHC IP integration commits

| Date (UTC+1) | Commit | What landed | -all targets affected? |
|---|---|---|---|
| 2026-04-04 | `72f6bf6` | "Adding PTP support to tidelink" — first `src/rtl/tidelink_ptp.sv` (284 LoC), RDL + UVM `tidelink_ptp_stress` + `tidelink_ptp_sync` envs + cocotb `tidelink_ptp/` env | NO — RTL-only, no FPGA target carried PHC IP yet |
| 2026-04-?? | `bb6565c` | "Adding support for hardware ptp servo" | NO |
| 2026-04-?? | `541786d` | "Adding w-link chaining functionality to allow multiple PTP hops" | NO |
| 2026-05-22 | `200666e` | "fpga: integrate PHC IP into pair + pair-flip BD (PTP HW test prereq)" — packaged PHC IP for IPI + BD edits on **base** (non-`-all`) pair targets only | NO — only `pynq-z2-pair/`, `pynq-z2-pair-flip/`. Production `-all` BDs untouched. |
| 2026-05-22 | `b5e9d75` | "pynq_host + ci: PHC PTP bring-up scripts + manual CI job" — `bringup_ptp_sync.sh` / `…_track_freq.sh` / `…_track_offset.sh` / `…_soak.sh` | NO (scripts only) |
| 2026-05-22 | `308be87` | "fpga(pair): USE_IDELAY=0 on base targets + PHC dev log" | NO |
| 2026-05-23 00:55 | `20c1eaa` | **Merge `feat/phc-hw-test`** — all of the above onto `main`. Merge commit explicitly states "Production -all targets' BD unchanged, so their bitstreams stay byte-identical to validated 976341f1/06d6a29a." | NO |
| 2026-05-23 01:13 | `5cbbc0f` | "fpga(pair-all): mirror PHC IP + PMOD-B trigger onto -all variant" — SmartConnect 7→9, PHC on M07, pmod_trig on M08, +0x4404_2000 + 0x4405_0000, XDC adds Y16 pad | **YES — pair-all first carries PHC IP** |
| 2026-05-23 01:21 | `9b96525` | "fpga(pair-flip-all): mirror PHC IP + PMOD-B trigger onto -flip-all variant" | **YES — pair-flip-all first carries PHC IP** |
| 2026-05-23 01:30 | `caf1079` | "Merge feat/phc-all-mirror: PHC IP integration on production -all targets" | YES (merge of above two) |
| 2026-05-23 ~08:08 | build #7 | First production bitstreams carrying PHC IP. md5 `65ad6caf…` / `e4f4e48f…`. | YES — first HW deploy of PHC |
| 2026-05-23 10:48 | First HW PHC test | `bringup_ptp_sync.sh` run — link drift to 14/16 masked PHC test (precondition fail); PHC APB region read clean at `0x4405_0000` on both boards, `PHC_STATUS=0x0`, `PHC_CTRL=0x0`. **No PHC traffic test executed.** | — |
| 2026-05-23 11:58 | build #8 v2 | First real B1 PHC test (link 16/16, manifest-verified). **slave HW_SYNC_STATUS = 0x0**. Master = 0x3 (stuck in TX_WAIT_IDLE). | First slave-RX evidence: **0x0** |
| 2026-05-23 ~15:00 | `b61c84a` | "rtl(ptp)+sw: force_en bypasses tx_router_idle gate — closes PHC sync deadlock" — master TX FSM was deadlocked on `tx_router_idle`. | RTL: `tidelink_ptp.sv` master TX gate |
| 2026-05-23 18:08 | build #9 retry | After `b61c84a`: master HW_SYNC_STATUS 0x3→0x4815 (FSM advancing). **slave HW_SYNC_STATUS still 0x0**. | First time master is provably TXing; slave still 0x0 |
| 2026-05-23 19:18 | build #9 retry #3 | Bug-#3-style discriminator (`4367a71`) proves slave `PTP_CTRL=0x1` mid-test → APB-write OK, FF not pruned. **slave HW_SYNC_STATUS still 0x0**. | |
| 2026-05-23 20:08 | build #11 | `feat/phc-rx-counters` adds RX_DIAG counters. Master counters plausible; slave-side counters read 8388608 / 1000000 / 0 (nonsense, address-decode broken). **slave HW_SYNC_STATUS still 0x0**. | |
| 2026-05-23 ~22:00 | build #13 | `feat/phc-slave-rx-fix` (`167923a`) adds `(* dont_touch *) (* keep *)` on slave `ptp_enable_r`. **slave HW_SYNC_STATUS still 0x0**; Bug-#3 replica-prune theory disproven. | |

---

## Per-commit blast radius

| Commit | RTL files touched (PHC-relevant) | Blast-radius assessment |
|---|---|---|
| `72f6bf6` | +`src/rtl/tidelink_ptp.sv` (NEW, 284 LoC), `src/rtl/tidelink_top.sv` (+127 LoC instantiating PTP), `src/rtl/fifo/tidelink_apb_regs.sv` (+18 LoC PTP regs) | PHC RTL born. Sim-only at this point — IP not yet in any FPGA BD. Tested by `cocotb/tidelink_ptp/` (single-IP) and UVM `tidelink_ptp_stress` / `tidelink_ptp_sync`. **NEVER exercised against a real Wlink-chained slave in sim at this point.** |
| `bb6565c` | `src/rtl/tidelink_ptp.sv` HW-servo additions | Sim-only. |
| `541786d` | `src/rtl/tidelink_ptp.sv` chaining functionality | Sim-only. |
| `200666e` + `5cbbc0f` + `9b96525` | **Zero RTL changes** — pure BD/XDC/wrapper integration. Drops the *existing* PHC IP into the pair / pair-flip / pair-all / pair-flip-all Vivado block designs. Adds `axi_apb_phc` bridge, address map `0x4405_0000`, PMOD-B trig GPIO, +Y16 XDC, +IOBUF in wrapper. | First HW carrier of PHC. This is the dividing line: *before* = "no PHC on HW at all"; *after* = "PHC on HW with no record of ever working". |
| `b61c84a` | `src/rtl/tidelink_ptp.sv` master-side `tx_router_idle` bypass + sw write to set FORCE_EN bit | Fixed master TX. **Did not affect slave RX path** (per `docs/PHC_PHASE1_HW_REPORT.md` §"Build #9 retry" — master 0x3→0x4815, slave 0x0→0x0). |
| `5a6ccab` / `e50983c` / `5c12f4f` | Forward-declaration shuffle of `hw_sync_force_en_r` in `tidelink_ptp.sv` (build-failure repairs from `b61c84a`) | Cosmetic — no behavioural change. |
| `804cfcc` | RX_DIAG counter add (`feat/phc-rx-counters`) | Adds diagnostic counters; slave-side wiring broken on HW (per build #11). Not merged. |
| `167923a` | `dont_touch+keep` on `tidelink_ptp.sv` slave `ptp_enable_r` / `rx_accept` | Disproven on HW (build #13). Not merged. |

---

## Has any prior build EVER shown slave HW_SYNC_STATUS != 0x0?

**No.** Direct grep of every PHC HW log staged on mapstone-dev:

```
mapstone-dev:~/td_milestone_stage$ grep 'HW_SYNC_STATUS' phc.*.log b13.*.log
phc.b11.counters.log:  slave  HW_SYNC_STATUS = 0x00000000
phc.b11.diag.log:      HW_SYNC_STATUS (slave):  0x00000000
phc.b9.retry4.log:     HW_SYNC_STATUS (slave):  0x00000000
phc.full.b8v2.log:     HW_SYNC_STATUS (slave):  0x00000000
phc.full.b9.retry.log: HW_SYNC_STATUS (slave):  0x00000000
b13.test.log:          HW_SYNC_STATUS (slave):  0x00000000
b13.toggle_full.log:   HW_SYNC_STATUS (slave):  0x00000000
b13.toggle.log:        HW_SYNC_STATUS master=0x5 slave=0x1   ← see note
```

The single `slave=0x1` line in `b13.toggle.log` was the workaround
PTP_CTRL toggle reading back the just-written PTP-enable bit, NOT actual
sync packet reception — re-running the full chain (`b13.toggle_full.log`)
from the same bitstream immediately reverts to `slave HW_SYNC_STATUS =
0x0`, with no offset convergence, no `ns_frac` update, no servo lock
(documented in `docs/PHC_PHASE1_HW_REPORT.md` §"Build #13 + Proposal #3").

The earliest PHC HW log on file is `phc.b1.sync.log` from 11:36 BST
2026-05-23 — the precondition-failure build #7 run. **There is no
pre-`caf1079` HW log** because there was no PHC on the production
bitstream to test.

---

## Was there a working `cocotb` test of PHC end-to-end before HW integration?

**No end-to-end pair test existed until 2026-05-23 (commit `86e45bb`).**
The chronology of cocotb PHC coverage:

| Date | Commit | What it tested |
|---|---|---|
| 2026-04-04 | `72f6bf6` | `cocotb/tidelink_ptp/` — single-IP DUT (`tidelink_ptp` alone, no Wlink, no slave). Exercises the PTP register interface + servo math; does NOT exercise the FC/Wlink short-packet RX path that fails on HW. |
| 2026-05-23 | `86e45bb` | `cocotb/phc_pair/test_phc_hw_sync_pair.py` — **first** end-to-end PHC sync test with two `axi_chiplet_controller` instances cross-wired through GPIO PHY pads. Added `expect_fail=True` because it reproduced the HW bug. |
| 2026-05-23 | `609482f` | Found the cocotb-side bug: TB-helper write race — fixed `ptp_reg_write` to hold over two rising edges. Test then PASS, `expect_fail=True` removed. |
| 2026-05-23 | `c29ffb2` | `cocotb/phc_pair/` extended with `USE_FPGA_MODELS=1` (IDELAYE2 / IDELAYCTRL / BUFG) — **also PASS**. Sim exonerates the RTL functional path entirely (per `docs/SIM_HW_GAP_ANALYSIS.md`). |

**Conclusion:** there is no cocotb regression record from 30/60/90 days
ago showing PHC sync working — because the pair-mode test didn't exist
until ~6 h before this analysis. The single-IP `cocotb/tidelink_ptp/`
test has always passed but exercises a different code path than the one
broken on HW.

---

## Bisect candidates — analytical narrowing

Since the bug has been present from the first deployable build, the
"breaking commit" question reduces to: **which commit *introduced* the
slave-RX path that is now broken**, not "which commit broke a previously
working path". The candidate set is therefore:

| Rank | Commit | Why it's a candidate | How to verify (sim, no HW) |
|---|---|---|---|
| 1 | **`72f6bf6`** | First-ever `tidelink_ptp.sv` — the RX path (`ptp_sp_rx_valid` & `ptp_enable_r` gate feeding `rx_accept`) was authored here. If a wiring/decode bug exists in the RX path it landed here. | Sim has already exonerated this RTL — `cocotb/phc_pair/test_phc_diag.py` shows 7968 RX-packets-accepted on the slave with `USE_FPGA_MODELS=1`. Bug is not in this RTL. |
| 2 | **submodule `221824d`** ("Updating wlink to allow for hardware ptp servo" — `wav-wlink-hw/src/main/scala/ShortPacket.scala`) | Only chiplet-controller commit touching the short-packet path that carries PHC sync. If the Wlink RX-side `ptp_out` decode (data_id 0x50 match) was authored here and has a HW-only edge case, this is where it landed. | Sim run with `USE_FPGA_MODELS=1` already covers this code path through the unisim primitives — passes. |
| 3 | **`200666e` + `5cbbc0f` + `9b96525`** (BD edits) | First time the PHC IP was placed onto a real Vivado floorplan with real I/O constraints. The slave-side master→slave fan-out routing is a *per-build* artefact of these BDs. | Cannot verify in sim — this is the P&R / XDC realm. The dominant suspicion (per `docs/SIM_HW_GAP_ANALYSIS.md` §4-(1)) is build-lottery routing skew on slave's RX fan-out past IDELAY tap range. |
| 4 | `b61c84a` (master `tx_router_idle` bypass) | Unblocked the master TX. **Did not change the slave RX path one line.** Per HW data master 0x3→0x4815, slave 0x0→0x0 — strict orthogonal proof that this commit does not regress or improve slave RX. | N/A — orthogonal. |

**The smallest set of commits that could have introduced the bug is
{`72f6bf6`, `221824d`, `caf1079`}** — i.e. (a) the RTL that authored
the slave RX path, (b) the Wlink-side short-packet RX decode, (c) the
BD/XDC integration that first put them on silicon. Of these, (a) and
(b) are sim-exonerated. (c) — the BD/XDC/P&R layer — is the live suspect
and is *not addressable by a git-blame bisect* because the failure mode
is "build-time routing landed outside the calibrator's tap range",
which is a per-build random variable, not a per-commit deterministic
change.

---

## What evidence (or lack of evidence) supports ALWAYS-BROKEN

**Direct evidence of never-worked:**

1. **Zero non-zero slave HW_SYNC_STATUS observations** across 13 build
   cycles + 6 B1 HW runs spanning ~10 hours of HW-test wall-clock
   (`docs/PHC_PHASE1_HW_REPORT.md` builds #7 / #8 / #8v2 / #9 / #9-retry
   / #9-retry#2 / #9-retry#3 / #11 / #13). Every run logs `slave =
   0x00000000`. The lone `0x1` was the PTP-enable mirror, not a sync
   reception event.

2. **The PHC IP was deployable on `-all` targets for the first time
   2026-05-23 01:13 BST** (`5cbbc0f`). The first HW test was 09:47 BST
   the same morning. There was no opportunity window before that for the
   path to have ever worked on a production bitstream.

3. **`v1-release/bitstreams/tidelink.bin.manifest.json` is from `72c280b`
   (2026-05-22)**, which predates `caf1079` (2026-05-23 01:30). The v1
   reference bitstream **does not carry the PHC IP** — slave HW_SYNC_STATUS
   on it would read back as an unmapped APB region, not a 0x0 from a
   silent RX. So even the v1 reference is not a "working baseline" to
   compare against; it is a "PHC-absent baseline".

4. **Sim only acquired pair-mode PHC coverage 6 hours before this
   analysis** (`86e45bb`, 2026-05-23 ~17:00 BST). The bug was instantly
   visible in sim (test added with `expect_fail=True`) until Agent N's
   TB-helper race fix (`609482f`) — at which point sim flipped to PASS.
   HW remained at FAIL through this entire window, demonstrating the
   sim PASS does not reflect HW reality.

**Absence-of-evidence that would have indicated "worked then regressed":**

- No mapstone-dev log file contains `slave  HW_SYNC_STATUS = 0x[1-f]` or
  `SERVO_STATUS (slave): 0x[1-f]` or `locked_streak >= 1` for any HW
  bringup-script run.
- No `bringup_ptp_track_freq.sh` / `…_track_offset.sh` / `…_soak.sh` log
  exists on mapstone-dev — they are all gated on B1 PASS and have never
  run on bridge1 silicon. Their absence is itself evidence: if PHC had
  ever worked, B2-B4 logs would exist.
- No git commit message in `git log --grep PHC` claims "slave RX working"
  or "first PHC sync lock" — only the diagnostic-progression chain
  documented above.

---

## What this means for next-tier debug

Per `docs/SIM_HW_GAP_ANALYSIS.md` §5, the discriminator that has not yet
been run is an **oscilloscope on slave `pad_clk_rx` + `pad_rx[n]` at the
Raspberry Pi header** while master is firing HW_SYNC. The "always broken"
verdict here strengthens that recommendation: there is no commit to
revert, no parent-of-`caf1079` bitstream that worked and can be diffed
against to narrow the BD/XDC delta. The closeout requires either:

  a. Confirming a P&R routing fault via scope (then fix in XDC, not RTL),
  b. Working ChipScope ILA on slave `ll_rx` (the `feat/phc-rx-counters`
     attempt failed because the slave-side APB decode broke; an ILA
     bypasses APB), or
  c. A focused human review of the chiplet-controller RX FSM correctness
     against the `ShortPacket.scala` `ptp_out` decode path on a fresh
     pair of eyes.

None of these are git-bisect operations. The bisect concludes here:
**the path has never worked, there is no breaking commit, and the next
investigation tier is HW-physical, not git-historical.**

---

## Cross-references

- `docs/PHC_PHASE1_HW_REPORT.md` — full per-build HW evidence chain.
- `docs/SIM_HW_GAP_ANALYSIS.md` — what sim covers vs what HW exposes
  (with USE_FPGA_MODELS=1).
- `docs/SIGN_OFF_STATUS.md` — gate-level summary including this status.
- `cocotb/phc_pair/test_phc_diag.py` — per-cycle slave RX-path probe
  (exonerates RTL).
- `cocotb/phc_pair/test_phc_hw_sync_pair.py` — end-to-end PHC sync pair
  test (sim PASS, HW FAIL — same external signature, different root
  cause per §3 of SIM_HW_GAP_ANALYSIS.md).
- mapstone-dev:`~/td_milestone_stage/phc.*.log` + `b13.*.log` — raw HW
  capture chain.
