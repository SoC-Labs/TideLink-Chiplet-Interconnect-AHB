# Weekend autonomous plan — 2026-07-18/19 (no-David mode)

Runs unattended from srv03335. Dashboard: [STATUS_LIVE.md](STATUS_LIVE.md) (updated every cycle).
Hard constraint: **no board shell access** (password-only) ⇒ zero hardware steps this weekend;
everything drives to "verified, built, packaged, Monday-deployable".

## Safety rails (absolute)
- No deploys, no board pokes, no `git push` to ANY remote, nothing under /research/AAA/**.
- All commits on NEW branches; `integ/consolidation-2026-07` untouched except a final reviewed merge
  is PREPARED (not executed) as a merge-ready branch.
- Never run Vivado builds and `make sim_gate` concurrently (OOM ⇒ fake regressions).
- Never `make -n sim_gate` (writes fake pass files).
- Tag before starting: `pre-weekend-2026-07-17`. Tag every gate pass.
- If anything looks destructive/ambiguous: stop that lane, record in STATUS_LIVE, continue others.

## Branch / tag / worktree scheme
- tidelink: `wip/kr260-recovery-2026-07` (R1–R6 commits, one commit per lane, reviewed) →
  prepared merge branch `merge-ready/kr260-recovery`. Tags: `kr260-recovery-g1` (review+sim_gate
  pass), `kr260-bitstream-<target>-<date>` per verified build.
- tidelink: `feat/ptp-demo-kr260` (Phase P work), `feat/ethernet-chiplet-integration` (Phase E).
- Ethernet: fresh clone of github SoC-Labs/NanoSoC-Ethernet-Chiplet →
  `~/SoCLabs/nanosoc-ethernet-chiplet` (read-only origin; local branch
  `feat/tidelink-chiplet-port`; NO pushes).
- Worktrees for parallel lanes: `~/SoCLabs/worktrees/<branch>` (never /tmp — repo rule).

## Phases (ordered; later phases proceed even if earlier ones block, where independent)
**W0 — Recovery integration (Fri night):** collect R1–R7 diffs; R6 (HARDEN_SWI options doc with a
recommendation, decision deferred to David unless one option is strictly safe); **cherry-pick
`2c32c2b` (capture-clock BUFG parent hoist, RTL+flist — R3 finding: the proven fix never landed on
integ; `USE_SHARED_CAP_BUFG` auto-tracks `USE_CLKBUF=1`, no BD/XDC change) and resolve any
conflicts vs post-b1e1199 HEAD**; adversarial review wave (opus critics per diff, high effort —
the cherry-pick and R1 get the deepest scrutiny); fix findings; commit per-lane onto
`wip/kr260-recovery-2026-07`; `export TIDELINK_PHY_V2=1; make -C fpga package_ip`; run
`make sim_gate` (14/14 required, never with Vivado running); tag g1. Post-route acceptance for W1:
`fpga/docs/verify_capture_clock_kr260.tcl` must PASS (BUFG driver) on every built target.
**W1 — Builds (Sat):** sequential/farm Vivado builds of kr260-pair-nptp, -flip-nptp, -ptp,
-flip-ptp from the recovery branch; verify_build (now WNS-aware) + structural netlist checks
(V2 markers, RETIRE_EN, INIT patterns); archive manifests; stage a deploy package
(bitstreams + kr260_afi.sh + bench checklist) under imp/fpga/output/ + docs/MONDAY_HANDOVER.md.
**W1b — deploy rework (R4 finding):** the kr260 `make deploy` branch is pynq_overlay-style but the
boards have NO pynq (real path: scp + `fpgautil -b <bin> -f Full` + `kr260_afi.sh fix`; .bit→.bin =
strip 127-byte header, never byte-swap; login ubuntu not xilinx). Implement a
`DEPLOY_STYLE=fpgautil` path in the Makefile so Monday's deploy is one command; keep Z2 untouched.
**W2 — Verification masterplan:** the verification-plan agent's
docs/TIDELINK_FPGA_VERIFICATION_PLAN.md gets reviewed, gap list converted into backlog items;
implement the automatable items that need no hardware (instrument-preamble library, statistics
tooling, tidechart report plumbing) on `feat/verif-env`.
**W3 — PTP demo prep (Sat/Sun):** RECON RESULT (2026-07-17): the demo ALREADY EXISTS as the
opt-in `ptp` channel in `fpga/hw_regression/td_v2_channels.sh` (`--channels "data doorbell ptp"`,
`--demo` for banners; KR260-aware via tl39/td_socmap). Success = 4 gates: PHC canary (ns_incr RW
both dies), PHC free-run, GM SYNC seq advance (HW_SYNC_STATUS[17:2]), and hardware
`R_SERVO_OFFSET` (0x…2060) convergence under PTP_TOL_NS=12000. Datapath: SYNC/DELAY_REQ as Wlink
short packets (0x50/0x51, FC-bypass), t1/t4 over FC sideband mailbox, autonomous HW servo
(tidelink_ptp_servo.sv) steering the PHC via hw_set/hw_adj. PHC IP is verification-green;
pair-sim test_ptp_link_sync.py passes. **PTP has NEVER synchronized on hardware** (single 2026-05-23
Z2 attempt died on a link precondition) and **no timing-clean -ptp bitstream exists** (R1 owns it;
BYPASS_CDC+same-net guidance sent). Known hardware gotchas (bake into the runbook): NS_INCR=40 at
25 MHz; HW_SYNC_CTRL force_en (=0x5) mandatory (phc_locked_i is tied 0 in every FPGA build, and
without force_en the PTP TX FSM deadlocks in TX_WAIT_IDLE); gate on SERVO_OFFSET, never phc_locked.
The old bringup_ptp_*.sh / _ptp_common.sh family is Z2-hardcoded /dev/mem — DO NOT USE on KR260.
Weekend scope: (1) re-run the ptp cocotb envs + pair-sim on the recovery branch to prove no
regression; (2) dry-run `td_v2_channels.sh --channels ptp` end-to-end in mock/against-sim where
possible; (3) write docs/PTP_DEMO_RUNBOOK.md (bring-up order: AFI canaries → link G3 → NS_INCR →
force_en → gates → expected numbers); (4) decide/document phc_locked_i wiring as a post-demo
improvement; (5) fold the R1-fixed -ptp targets into the W1 build matrix.
**W4 — Ethernet chiplet scaffolding (Sun):** RECON RESULT (2026-07-17): the GitHub
NanoSoC-Ethernet-Chiplet repo has NO Ethernet MAC (it integrates nanosoc-multicore + tidelink +
tidechart; elaboration-clean, ASIC-leaning, no two-die sim yet); the MAC lives in ethernet-mac-ahb
(AHB-Lite OpenCores wrapper, MII/RMII, HA1588 PTP timestamping, block-level mature) and
ethernet-subsystem-ahb (M0+ subsystem, PicoTCP, MPS3-validated on LAN8720 RMII; PHC variant).
Active clone with populated submodules already at ~/SoCLabs/nanosoc-ethernet-chiplet (HEAD e809fbf,
tidelink pinned at v2026.07.16-chiplet-verified). ATTACH POINT: replace/augment TideLink's
`tidelink_ahb_mng_bram.v` terminus with the subsystem's `eth_ss_0/1` AHB slave ports; peer window
0x8000_0000 (KR260) sub-decoded per chiplet_d2d_decode.sv (0x2E00_0000 window in the chiplet repo).
KR260 PHY REALITY: the J21 header is fully consumed by the TideLink ribbon ⇒ the MAC needs other
pins (PMOD? SFP+? PS-GEM bridge?) — this is a David decision; W4 documents the options.
Weekend scope: (1) docs/ETHERNET_CHIPLET_INTEGRATION.md — architecture, address map, clocking
(4 async domains in the subsystem), PHY options matrix, PTP grandmaster chain (Ethernet/HA1588 →
PHC → TideLink PTP → far die); (2) branch `feat/tidelink-chiplet-port` in the chiplet clone +
`feat/ethernet-chiplet-integration` in tidelink; (3) a cocotb integration smoke: TideLink pair +
ethernet subsystem behind ahb_mng (sim only, no PHY needed); (4) staged patch series for the
GitLab ethernet repos (NO pushes). Note: ethernet-mac-ahb depends on read-only
/research/AAA/ip_library/OpenCores-EthMAC — flist-reference only, never copy-modify upstream.
**W5 — Continuous:** STATUS_LIVE + memory updates each cycle; a final Sunday-night
MONDAY_HANDOVER.md summarizing: what merged, what built, what's deploy-ready, decisions needed,
first-15-minutes bench script for Monday.

## Loop cadence
Self-paced wakeups (~20–30 min) + task-notification-driven continuation; each cycle: harvest agent
results → review/integrate → advance the highest-priority unblocked phase → update STATUS_LIVE →
schedule next wakeup. Vivado builds get a long-fallback watchdog (kill+retry once on hang, then
mark blocked). Stop condition: all phases done/blocked-on-David, then write the handover.
