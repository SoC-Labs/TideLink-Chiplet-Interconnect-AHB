# LIVE STATUS — TideLink KR260 → PTP demo → Ethernet chiplet

> **Protocol:** this file is the single live dashboard. Every working session (human or agent)
> updates the relevant row + the timestamp when state changes. Detail lives in the linked docs;
> keep this file short. Last full update: **2026-07-18 00:1x (continuation wave complete — X-A/B/C/D all landed; loop stopped)**.

## Headline
**KR260 CHIPLET LINK IS UP** (first ever, 2026-07-17): root cause was the PS↔PL AFI port width
(stock Kria firmware = 128-bit, BD = 32-bit) — fixed by devmem poke, no rebuild; `cal=1` both
dies. **The full recovery branch is integrated, reviewed, sim_gate 15/15; 4/4 bitstreams built +
structurally verified; PTP proven in sim; ethernet M0 relay proven in sim. Tags:
`kr260-recovery-g1` / `g2-built` / `weekend-final`. Monday = deploy + demo.**
Plans: [KR260_RECOVERY_PLAN](KR260_RECOVERY_PLAN_2026_07_17.md) · [WEEKEND_PLAN](WEEKEND_PLAN_2026_07_18.md)

## Canaries (run before trusting ANY KR260 reading)
`rd 0x8403_0204`==0x00000001 and `rd 0x8403_0214`==0x0000e4e4 — if 0, re-apply the AFI poke
(`0xFF419000 &= ~0x300`, `0xFD615000 &= ~0x300`); it does NOT survive reboot yet
(kr260_deploy.sh / kr260_afi.sh handle it; boot-path persistence = Monday).

## Current state
| Item | State | Next |
|---|---|---|
| W0 recovery branch `wip/kr260-recovery-2026-07` | ✅ **COMPLETE** — 12 commits (R1-R7 + W2a/W2b + W3/W4 docs + review fixes + cherry-pick 2c32c2b), 2 adversarial reviews passed, package_ip PASS, **sim_gate 15/15**, tagged `kr260-recovery-g1` | David: merge to integ Monday |
| W1 four target builds (nptp/flip-nptp/ptp/flip-ptp) | ✅ **COMPLETE** — 4/4 built rc=0 (~29 min each) AND structurally verified: capture clock on BUFGCE (fanout 496, lottery fix physically in), V2MARK=479, IDELAY=0, setup WNS clean, u_cnt_bufg absence verified-benign. md5s in [MONDAY_HANDOVER](MONDAY_HANDOVER.md) | deploy Monday |
| W3 PTP demo | runbook ✅ [PTP_DEMO_RUNBOOK](PTP_DEMO_RUNBOOK.md); **sims ✅ 45/45 + pair PTP-over-link CONVERGED-AND-HELD 2/2 on the recovery branch**; ⚠️ gate_link ordering gap — manual swreset triplet before gating (durable fix = R6 option (b), unapplied) | first silicon run Monday |
| W4 Ethernet chiplet | architecture ✅ [ETHERNET_CHIPLET_INTEGRATION](ETHERNET_CHIPLET_INTEGRATION.md) — the chiplet SoC ALREADY has MAC+HA1588; port = build/wiring; **M1 = no-PHY frame relay (~1 wk)**; chiplet-repo branch `feat/tidelink-chiplet-port` (2e64919, unpushed) | M0 sim smoke |
| Verification env | masterplan ✅ [TIDELINK_FPGA_VERIFICATION_PLAN](TIDELINK_FPGA_VERIFICATION_PLAN.md); L1 preamble + stats libs committed; **first TideChart co-sim PASS** | execute roadmap (nightly soaks need board keys) |
| 🔴 Finding G1 (TideChart co-sim) | **dual-root election** — link_active precedes data-mode; ASIC integration inherits (nanosoc_eth_chiplet.sv:357) | pre-tapeout triage (Monday) |

## Continuation wave (Fri night, user-directed autonomous)
| Lane | What | State |
|---|---|---|
| X-A | silicon-skew peer-window stall | ✅ **ROOT-CAUSED** (ea5b34d): V2 has no armed whole-word RX corrector (EPOCH knob dead on V2 flist — trap #16); forward data byte-exact, skewed return shears; HW premise contested. Rule: bounded canary before window traffic (runbook's data gate covers it) |
| X-B | ethernet M1 | ✅ **PASS 1/1** — frame through the REAL ethernet_ss_ahb matrix into eth_scratch_rx, 16/16 byte-exact; contract findings: identity map, wait-states honored, single-beat-only, X-init read-before-write hazard (cocotb/eth_tidelink_pair_m1) |
| X-C | TideChart G1/G2 | ✅ **CLOSED** — single-root PASS in data-mode; PKT_EXT crossed both directions (first tc_axis-over-link proof); contract = new `tl_data_mode_o` + one-net swap (docs/TIDECHART_G1_SEQUENCING_CONTRACT.md); committed f3ee7bc |
| X-D | cleanup debt | ✅ **DONE** (c8c9ecf) — 24/25 tools guarded (1 justified skip), verify_build (d) per-target window (4/4 PASS on the batch, genuine-stale still caught), test_ptp_corrected_regs PASS 4/4 |

## Wave Y (Sat, user-directed autonomous)
| Lane | What | State |
|---|---|---|
| Y-A | onchip target (gap F20) | ✅ **BUILT** (eb3a6fd) — first ever bitstream: 54% LUT / 30% FF / 23 BUFGCE / **4 IOB** (LEDs only); **WNS +27.3, WHS +0.010, 0 failing of 141,745** — the −22 ns WHS artifact class is ABSENT (no pads); zero-skew trap netlist-proven; BUFG-per-region risk did not materialise. Capture clock LUT-driven (built pre-cherry-pick in main tree) ⇒ **cleanest A/B vehicle for the BUFG fix** |
| Y-B | Shape-A narrow | ✅ **PASS** — real MAC reset-constants read + HA1588.SCRATCH write/readback across the link through the subsystem matrix; NO full SoC needed (eth_ss_0→ethmac_0 proven). PTP-chain gap now a precise 4-item list |
| Y-C | error-injection matrix (gap F14) | ✅ **DONE** (a19e7d5) — 🔴 **2 TAPEOUT-GATING FINDINGS**: F14-A lane-7 corruption is COMMITTED silently (crc=0, 12/12); F14-B no in-field recovery (both-die POR only) + **fcsm=4 while no data crosses ⇒ fcsm is NOT liveness**; F14-C never POR one die alone |
| Y-D | RX-FIFO TWIN 2 (gap F10) | ✅ **DISPOSITIONED** (9f42712) — real+live, reproduced (+8B/−2 credit, FC-shared ptr), AHB-write-to-RX proven unsupported, 3-hunk default-preserving patch A/B-proven (1/3→3/3). RECOMMEND apply pre-tapeout |

## Wave Z (Sat evening, autonomous)
| Lane | What | State |
|---|---|---|
| Z-A | sim_gate wiring | ✅ **DONE** (0d06d51) — **15→21 suites + 2 defect sentinels** (+6.6 min); found **2 false-green gate bugs** (env SIM_BUILD silently ignored; shared results.xml ⇒ make runs NOTHING and exits 0 — caught by a sentinel, not a normal suite). ⚠️ **CI clone job needs 3 sibling repos before merge** or 6 suites go red |
| Z-B | F14-A sweep + CRC | ✅ **ANSWER: there is NO working integrity check** (1757973) — `disable_crc=1` both dies from reset via a local override present in BOTH ASIC flists; 48/48 cells raised zero errors; F14-A is GENERIC (byte-position, not lane). ⚠️ PKT_WORD_LEN is not a commit indicator — this inverted the original finding |
| Z-C | ethernet M2 | ✅ **HA1588 TIMESTAMPED A REAL MII EVENT, read across the link** (e752d72) — grandmaster capture works. 🔴 PHC hop NOT closed: ethernet_ss_ahb_phc can't even BIND (port-name/width mismatch), servo src1 tied off, never simulated. ~4-6 d to sim-complete chain |
| Z-D | recovery + liveness | ✅ **BIGGEST FINDING** (fc5be83): `calibrated_once_q` (calibrator:606-618) latches on first lock and kills BOTH retrigger edges ⇒ **NO firmware-reachable PHY retrain exists, FPGA *and* ASIC — one-bit fix, unfixable after tapeout**. Corrects F14-B (most disturbances self-heal; only clock dropout wedges). Beacon-recovery REFUTED twice by its own author. Liveness = tagged canary only; no register substitutes |

**GATE RESULT: ✅ 21/21 PASS + both sentinels XFAIL (correct — defect present & unchanged, NOT a
pass).** Getting there took a 3rd gate-plumbing fix: `$(realpath)` returns EMPTY for a missing path,
so a git worktree (two levels deeper than the main checkout) resolved the sibling repos to nothing —
5 suites failed at 0s with a message naming `/flist/...` instead of where it looked. Fixed by
multi-root resolution + exporting the resolved paths (benches use `?=`, so no bench file changed).
**ONCHIP A/B COMPLETE — THE CAPTURE-CLOCK FIX IS PROVEN IN SILICON-BOUND FORM.** Same target, same
tool, only the branch differs: main tree (pre-cherry-pick) = LUT2 driver, fanout 496, **DEFECTIVE
on both dies**; recovery branch (with 2c32c2b) = **BUFGCE on BOTH dies, VERDICT PASS**. verify_build
PASS/0 warnings, WNS +28.306, WHS +0.010, BUFG-per-region OK, zero-skew trap still netlist-proven
(div_0 INIT 3'b000 / div_1 3'b011). Bitstream md5 8f8792c975d3dc27790c5631a042b400.

## ⚠️ BRANCH DIVERGENCE — integ moved while wave Z ran (found 2026-07-19)
`integ/consolidation-2026-07` is now at **a7b68f4, five commits past** the base my branch was cut
from — another session picked up the SAME untracked benches from the shared main tree and committed
them, plus hardened sim_gate independently. **The merge is small and safe, but not a fast-forward:**
- **Identical on both sides** (both took the same shared-tree files) ⇒ merge trivially: all of
  `cocotb/tidelink_error_injection/*` test files, all of `cocotb/fifo_rx_twin2/*`,
  `docs/TIDELINK_FPGA_VERIFICATION_PLAN.md`.
- **Only 2 real conflicts** (`git merge-tree` verified): **`Makefile`** and
  `cocotb/tidelink_error_injection/Makefile`. Cause: BOTH sessions independently added `-n` safety
  to sim_gate (convergent fix for the fake-PASS trap) and both edited the gate region — mine adds
  the 21 suites + 2 sentinels + worktree-robust sibling resolution; theirs adds assert-ification of
  green-but-blind tests. **Resolve by keeping BOTH: they are complementary, not competing.**
- Only-on-my-branch (no conflict): the 5 new bench dirs (`tidechart_tidelink_pair`, `eth_*` ×4).
- Related: integ's **2bd5612 forwards HONEST_MASK_HS in the ASIC dft_wrapper**; my Y-A forwarded it
  in the **FPGA** `tidelink_vivado_wrapper` — **complementary halves of the same fix**, keep both.

## Blocked on David (Monday — nothing blocks the weekend work)
1. Merge `wip/kr260-recovery-2026-07` (tag `kr260-recovery-g1`) to integ; then deploy the
   G2-verified bitstreams via `make deploy_pair_role SOC=kr260` (new fpgautil path runs the AFI
   fix + canaries automatically). Power-cycle → deploy BOTH → bring up.
2. Board ssh keys for srv03335 + populate fpgahub secret `kr260.ssh_password` (or NOPASSWD sudo).
3. R6 sign-off: option (a) HARDEN_SWI_ENABLE=0 per-kr260-target APPLIED (review says safe);
   option (b) NEGO_CFG_RESET=0 unapplied — decide if wanted (fixes the gate_link ordering gap).
4. G1 dual-root election triage for the pre-tapeout list.
5. AFI persistence in the board boot path (systemd unit) + report to the Kria-260 repo.
6. Lease/authorization for the first PTP-demo hardware run (runbook ready).

## Standing safety rails (autonomous operation)
No hardware deploys or board pokes; no pushes to any git remote; no edits under /research/AAA;
never co-schedule Vivado builds with sim_gate; all new work on new branches (never direct on
integ); tags at every gate; this file + memory updated every cycle.
