# LIVE STATUS — TideLink KR260 → PTP demo → Ethernet chiplet

> **Protocol:** this file is the single live dashboard. Every working session (human or agent)
> updates the relevant row + the timestamp when state changes. Detail lives in the linked docs;
> keep this file short. Last full update: **2026-07-17 21:0x (weekend autonomous loop — ALL PHASES COMPLETE, loop stopped)**.

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
