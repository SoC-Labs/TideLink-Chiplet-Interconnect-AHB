# Monday handover — 2026-07-20 (weekend autonomous run, written Fri 19:35)

Everything below was produced on branch **`wip/kr260-recovery-2026-07`** (worktree
`~/SoCLabs/worktrees/wip-kr260-recovery`), tagged **`kr260-recovery-g1`**, 12 reviewed commits.
Dashboard: [STATUS_LIVE.md](STATUS_LIVE.md). Nothing was deployed, nothing was pushed.

## What you're inheriting (all verified)
- **KR260 link root cause FOUND AND FIXED on hardware** (Friday, with the live session): stock
  Kria firmware leaves the PS↔PL AFI ports at 128-bit vs our 32-bit BD ⇒ 3/4 of every APB window
  dead since first light. Fix = devmem poke (now scripted + in the deploy path). cal=1 both dies.
- **Recovery branch**: capture-clock BUFG hoist (cherry-pick 2c32c2b), MMCM/phc same-net fix,
  I2C pull-ups, `HARDEN_SWI_ENABLE=0` (kr260 targets only), fpgautil deploy path + AFI
  persistence, tooling hardening (loud-fail instruments, ZynqMP guards, WNS-gating verify_build),
  L1 instrument-preamble + stats libs, TideChart co-sim bench, all docs.
- **Gates**: 2 adversarial reviews (no build-breakers; all findings fixed/accepted), package_ip
  PASS, **sim_gate 15/15**, PTP sims 45/45 + pair PTP-over-link **CONVERGED AND HELD** (2/2).
- **Four fresh bitstreams built from g1 and structurally verified** (capture clock on BUFGCE
  fanout-496 — the lottery fix is physically in; V2MARK=479; IDELAY=0; setup WNS ≥ +0.745;
  the u_cnt_bufg absence is verified-benign — its winscan consumers don't exist at USE_IDELAY=0):

| target | .bit md5 | routed WNS |
|---|---|---|
| kr260-pair-nptp (die_a) | 436e33572389e3ed8982eabc16a97e3e | +0.745 |
| kr260-pair-flip-nptp (die_b) | 60164ed348b220ace98aab5bda89bb91 | +1.355 (intermediate; final in rpt) |
| kr260-pair-ptp (die_a) | b221e071d17e7f4651fee7a25e1ccd52 | see rpt (setup clean) |
| kr260-pair-flip-ptp (die_b) | 551b9acb0c51b8aa9e5b649b6bc985e8 | see rpt (setup clean) |

WHS ≈ −22 ns everywhere = the known benign source-synchronous artifact (not gated, documented).

## First 15 minutes on Monday
1. **Merge**: review `git log d19b0da..kr260-recovery-g1` in the worktree; merge onto
   `integ/consolidation-2026-07`. (Or deploy straight from the worktree — the artifacts are there.)
2. **Deploy both boards** (power-cycle first; NEVER `reboot` a KR260):
   `make -C fpga deploy_pair_role SOC=kr260 PTP=1 ROLE=die_a` then `ROLE=die_b`
   (needs `KR260_PASSWORD=...` until ssh keys are staged). This stages tooling mirrored, loads via
   fpgautil, and runs `kr260_afi.sh fix` + canaries automatically.
3. **Canaries** (before believing anything): `0x8403_0204==0x1`, `0x8403_0214==0xE4E4`.
4. **Link bring-up + data**: follow [PTP_DEMO_RUNBOOK.md](PTP_DEMO_RUNBOOK.md) §2 — note the
   manual swreset-triplet escape before `gate_link` (the harness orders the cure after the gate).
5. **PTP demo**: runbook §2.5 → `td_v2_channels.sh --demo --channels "data doorbell ptp"` with the
   KR260 env overrides listed in §0 (defaults are Z2!).

## Decisions needed from you
1. **R6 option (b)** (`NEGO_CFG_RESET=0` on kr260 targets): restores the cold-boot calibrator
   trigger and removes the runbook's manual-triplet step, at the cost of zero-poke autonomy POR on
   the two-board targets. Option (a) is already in. See [R6_HARDEN_SWI_OPTIONS.md](R6_HARDEN_SWI_OPTIONS.md).
2. **G1 dual-root election** (TideChart co-sim finding): `link_active` precedes data-mode ⇒ both
   dies elect root; the ASIC integration inherits it (`nanosoc_eth_chiplet.sv:357`). Needs a
   sequencing contract before tapeout. Evidence: `cocotb/tidechart_tidelink_pair/README.md`.
3. **AFI persistence style**: per-boot poke via deploy (current) vs a systemd unit on the boards
   (recommended; also report to the Kria-260 repo as an issue — our psu_init never runs).
4. **fpgahub secret** `kr260.ssh_password` (or stage ssh keys + NOPASSWD and skip it).
5. **Ethernet M1**: approve the no-PHY frame-relay demo shape + PMOD-RMII-at-M2 direction
   ([ETHERNET_CHIPLET_INTEGRATION.md](ETHERNET_CHIPLET_INTEGRATION.md)); the chiplet-repo plan
   branch `feat/tidelink-chiplet-port` (2e64919) is local-only, push/PR at your discretion.

## Late addition (Fri night): Ethernet M0 sim smoke — PASS
`cocotb/eth_tidelink_pair/` (commit ce1f6ca, tag `kr260-recovery-weekend-final`): a 16-word frame
written on die_a crossed the link and landed byte-exact in the real `nanosoc_region_sram`
eth-scratch component behind die_b's ahb_mng — the frame-relay datapath skeleton is proven in sim.
Next (M1): swap in the full `ethernet_ss_ahb` via `eth_ss_0` to surface the matrix hready/burst
contract. Known inherited gap: `EPOCH_PROFILE=silicon` stalls the peer-window B-response —
IDENTICALLY in the unmodified pair_v2 bench (`test_v2_xhb_window`) — a pre-existing PHY-lane
item, now precisely characterized.

## Loose ends (tracked, none urgent)
- ~25 more Z2-literal one-shot scripts still unguarded (list in the R5 report; guard idiom ready).
- verify_build check (d) false-positives when verifying mid-batch (bit vs next build's
  package_ip.log timestamp) — cosmetic, worth a follow-up tweak.
- `test_ptp_corrected_regs.py` (pair bench) not re-run this weekend (not in the gate).
- The Z2 pair still runs the June-18 build; any future Z2 rebuild inherits the capture-clock RTL
  (validated config, but re-certify with the N=40 soak when convenient).
