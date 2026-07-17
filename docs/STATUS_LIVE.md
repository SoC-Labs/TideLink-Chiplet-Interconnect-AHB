# LIVE STATUS — TideLink KR260 → PTP demo → Ethernet chiplet

> **Protocol:** this file is the single live dashboard. Every working session (human or agent)
> updates the relevant row + the timestamp when state changes. Detail lives in the linked docs;
> keep this file short. Last full update: **2026-07-17 15:4x (assessment session)**.

## Headline
**KR260 CHIPLET LINK IS UP** (first ever, 2026-07-17): root cause of the historic failure was the
PS↔PL AFI port width (stock Kria firmware = 128-bit, BD = 32-bit) — fixed by devmem poke, no
rebuild. `cal=1` both dies. See memory §0 and [KR260_RECOVERY_PLAN_2026_07_17.md](KR260_RECOVERY_PLAN_2026_07_17.md).

## Canaries (run before trusting ANY KR260 reading)
`rd 0x8403_0204`==0x00000001 and `rd 0x8403_0214`==0x0000e4e4 — if 0, re-apply the AFI poke
(`0xFF419000 &= ~0x300`, `0xFD615000 &= ~0x300`); it does NOT survive reboot yet.

## Lanes
| Lane | What | State | Next gate |
|---|---|---|---|
| HW (live session / David) | link bring-up on boards | **cal=1 both dies; master fcsm=2 residual** | HARDEN_SWI fix (needs rebuild) → data test |
| R1 | MMCM/timing fix | **DONE** — phc→clk_out1 same-net in both -ptp tcls; 1673 setup endpoints collapse; hold = benign pad_tx artifact (PHC hold MET) | review (G1) |
| R2 | I2C pull-ups in kr260 XDCs | **DONE** (PULLTYPE PULLUP ×4 XDCs; audit clean) | review (G1) |
| R3 | capture-clock lottery fix port (die_a 1/4) | **DONE** — real fix = RTL cherry-pick `2c32c2b` (added to W0); XDC docs + post-route verify script delivered; defect invisible to WNS | W0 cherry-pick + review (G1) |
| R4 | AFI persistence in deploy path + board docs | **DONE** — kr260_afi.sh + Makefile hook + KR260_BOARD_ENV/AFI_CHECK docs | review (G1) |
| R7 (new) | deploy-rework: kr260 `make deploy` uses pynq_overlay on pynq-less boards (Z2 creds hardcoded) — must be fpgautil-based before Monday | pending | W1 |
| R5 | tooling hardening (Z2-guards, loud-fail, verify_build WNS) | **DONE** — verify_build now FAILS the deployed ptp build (WNS gate); ~25 more unguarded Z2 one-shots listed for a follow-up campaign | review (G1) |
| W2b | TideChart↔TideLink cocotb integration smoke (gap F18) | agent running | review |
| R6 | HARDEN_SWI options + fix | **DONE + APPLIED** — fcsm=2 = CR-seen/no-CRACK (reset-timing, no SW escape exists); `CONFIG.HARDEN_SWI_ENABLE {0}` applied to all 4 kr260 tcls (Z2/ASIC untouched, sim_gate-neutral); fallback (b) NEGO_CFG_RESET=0 documented UNAPPLIED — David sign-off in handover | review (G1) |
| Verif masterplan | tapeout FPGA verification plan | **DONE** — docs/TIDELINK_FPGA_VERIFICATION_PLAN.md (20 features, 10 gaps, 4-layer env) | W2 executes roadmap |
| W2a | instrument-preamble lib + stats lib + merge_guard grep fix | agent running | review |
| Review+sim_gate | adversarial review of R1–R7 + cherry-pick, then sim_gate | pending | G1 |
| Build | rebuild kr260 nptp+ptp (+flips) from clean HEAD | pending (gated G1) | structural verify (G2) |
| PTP recon | what exists for the PTP demo | **DONE** — demo = td_v2_channels `ptp` channel (KR260-aware); PHC IP green; PTP NEVER synced on HW; no timing-clean -ptp bitstream yet | folded into W3 |
| Ethernet recon | ethernet-mac-ahb / NanoSoC-Ethernet-Chiplet state | **DONE** — no MAC in chiplet repo; attach = ahb_mng BRAM→eth_ss_0/1; KR260 PHY pins TBD (David) | folded into W4 |
| Phase P | PTP demo prep (sim + sw + docs) | pending | [WEEKEND_PLAN](WEEKEND_PLAN_2026_07_18.md) |
| Phase E | Ethernet chiplet port scaffolding | pending | [WEEKEND_PLAN](WEEKEND_PLAN_2026_07_18.md) |

## Blocked on David (Monday list — nothing here blocks the weekend work)
1. Deploy the recovery bitstreams (G2-passed) to both boards; re-apply/install AFI persistence.
2. Board ssh keys for srv03335 (currently password-only — blocked all remote hardware work).
3. HARDEN_SWI / NEGO_CFG_RESET design-intent sign-off (R6 will present options).
4. Lease/authorization for the first PTP-demo hardware run.

## Standing safety rails (autonomous operation)
No hardware deploys or board pokes; no pushes to any git remote; no edits under /research/AAA;
never co-schedule Vivado builds with sim_gate; all new work on new branches (never direct on
integ); tags at every gate; this file + memory updated every cycle.
