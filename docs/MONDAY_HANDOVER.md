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
000. 🔴🔴 **THE LINK-LAYER CRC IS DISABLED BY DEFAULT — in both ASIC flists.** `disable_crc=1` on
   both dies out of reset: a local override deliberately flips the POR default, and the Chisel
   forces `crc_corrupt=false`. The override's own comment says why — a real header-CRC bug on GOOD
   traffic was worked around by turning the check off — and notes die_b's control register may be
   hardware-unwritable, so software may not be able to re-enable it. Consequence, measured across
   48/48 injection cells: **zero error indications ever raise, and corrupted packets on two lanes
   are committed silently and are indistinguishable from good ones while the link stays usable.**
   Decide: root-cause and re-enable, or ship with an explicit "no link-layer integrity, end-to-end
   checksum mandatory" contract **plus a software-visible status bit**. Shipping silently-disabled
   integrity with no indication to software is the part that shouldn't survive review.
   Evidence: [ERROR_INJECTION_FINDINGS.md](ERROR_INJECTION_FINDINGS.md).
00. 🔴🔴 **HIGHEST — a one-bit RTL fix that becomes unfixable at tapeout.** `calibrated_once_q`
   (`tidelink_phy_align_calibrator.sv:606-618`) latches on first lock and permanently gates BOTH
   calibrator re-trigger edges, so **`SWI_RECAL` is a no-op after first lock and there is NO
   firmware-reachable PHY retrain — in the FPGA image and the ASIC path**. The RTL comment already
   proposes the remedy (a dedicated W1P); nobody built it. Sim-proven, measured directly.
   Evidence: [LINK_RECOVERY_MECHANISM.md](LINK_RECOVERY_MECHANISM.md).
   Same doc corrects the earlier "any disturbance wedges the link" claim (most self-heal; only a
   clock dropout truly wedges) and establishes that **the only trustworthy liveness check is moving
   tagged data — every status register reads identical healthy vs wedged**.
0. 🔴 **NEW, HIGHEST: two tapeout-gating error-injection findings** ([ERROR_INJECTION_FINDINGS.md](ERROR_INJECTION_FINDINGS.md)).
   **F14-A** a corrupted lane 7 is COMMITTED as a valid packet with no error flagged (silent data
   corruption — SW consumes 13 garbage words); **F14-B** no in-field recovery path (any transient
   disturbance wedges the link; only a both-die POR clears it) — and **fcsm=4 reads healthy on both
   dies while no data crosses, so every fcsm-based liveness gate can pass on a dead link**. These
   need triage/ownership before tapeout; they are sim-proven, not yet hardware-confirmed.
1. **R6 option (b)** (`NEGO_CFG_RESET=0` on kr260 targets): restores the cold-boot calibrator
   trigger and removes the runbook's manual-triplet step, at the cost of zero-poke autonomy POR on
   the two-board targets. Option (a) is already in. See [R6_HARDEN_SWI_OPTIONS.md](R6_HARDEN_SWI_OPTIONS.md).
2. **G1 dual-root election — now with a proven fix proposal**: gating the election on data-mode
   yields single-root + the first PKT_EXT-over-link proof (test committed). Proposal: export
   `tl_data_mode_o` (FCSM>=4, already CDC-synced in axi_chiplet_controller) and swap one net in
   `nanosoc_eth_chiplet.sv:809` + the FPGA BD; TideChart RTL unchanged. Unfixed = silent
   multi-die dual-root at bring-up (respin-class). Approve + apply:
   [TIDECHART_G1_SEQUENCING_CONTRACT.md](TIDECHART_G1_SEQUENCING_CONTRACT.md).
3. **AFI persistence style**: per-boot poke via deploy (current) vs a systemd unit on the boards
   (recommended; also report to the Kria-260 repo as an issue — our psu_init never runs).
4. **fpgahub secret** `kr260.ssh_password` (or stage ssh keys + NOPASSWD and skip it).
5. **TWIN 2 patch sign-off** (NEW, Y-D): the last chip-killer is dispositioned — real, reproduced,
   intent proven (AHB-write-to-RX unsupported anywhere), fix is a default-preserving 3-hunk patch
   with an A/B-proven gate test. Apply docs/proposals/twin2_fix.patch + add sim_gate_fifo_twin2.
   Evidence: [RXFIFO_TWIN2_DISPOSITION.md](RXFIFO_TWIN2_DISPOSITION.md).
6. **Ethernet M1**: approve the no-PHY frame-relay demo shape + PMOD-RMII-at-M2 direction
   ([ETHERNET_CHIPLET_INTEGRATION.md](ETHERNET_CHIPLET_INTEGRATION.md)); the chiplet-repo plan
   branch `feat/tidelink-chiplet-port` (2e64919) is local-only, push/PR at your discretion.

## Late additions (Fri night / Sat 00:1x): continuation wave — all four lanes landed
- **X-A silicon-skew stall ROOT-CAUSED** (ea5b34d + docs/XHB_WINDOW_SKEW_ROOTCAUSE.md): V2 has no
  armed whole-word RX corrector (the EPOCH knob is a dead no-op on the V2 flist — trap #16);
  forward data lands byte-exact, only the skewed-direction response shears. Whole-word HW skew
  premise is CONTESTED — measure before treating as live. Rule: bounded canary write+readback
  before any transparent-window traffic (the runbook's data gate covers it).
- **X-C TideChart G1+G2 CLOSED** (f3ee7bc): single-root in data-mode + first PKT_EXT-over-link
  proof; fix = export `tl_data_mode_o`, one-net swap (see decision 2 above).
- **X-B ethernet M1 PASS** (cocotb/eth_tidelink_pair_m1): frame through the REAL ethernet_ss_ahb
  matrix into eth_scratch_rx, 16/16 byte-exact; contract findings: peer→eth map is IDENTITY,
  matrix wait-states honored end-to-end, path is single-beat-only today, X-init scratch means
  write-before-read is a firmware contract. Next: Shape A (full multicore SoC) → MAC/HA1588 regs.
- **X-D cleanup debt CLOSED** (c8c9ecf): 24/25 Z2 tools guarded, verify_build batch fix,
  test_ptp_corrected_regs PASS 4/4.

## Late addition (Fri night): Ethernet M0 sim smoke — PASS
`cocotb/eth_tidelink_pair/` (commit ce1f6ca, tag `kr260-recovery-weekend-final`): a 16-word frame
written on die_a crossed the link and landed byte-exact in the real `nanosoc_region_sram`
eth-scratch component behind die_b's ahb_mng — the frame-relay datapath skeleton is proven in sim.
Next (M1): swap in the full `ethernet_ss_ahb` via `eth_ss_0` to surface the matrix hready/burst
contract. Known inherited gap: `EPOCH_PROFILE=silicon` stalls the peer-window B-response —
IDENTICALLY in the unmodified pair_v2 bench (`test_v2_xhb_window`) — a pre-existing PHY-lane
item, now precisely characterized.

## NEW TARGET: kr260-pair-onchip is buildable and built (Y-A, eb3a6fd)
Two TideLink dies in ONE xck26 bitstream — no ribbon, no link pins (4 IOB = LEDs), one board.
54% LUT / 30% FF / 23 BUFGCE; **WNS +27.3 ns, WHS +0.010, zero failing endpoints of 141,745**
(the ~−22 ns source-synchronous WHS class simply does not exist without pads). Bitstream is in
the MAIN tree at `imp/fpga/output/kr260-pair-onchip/`, built before the capture-clock cherry-pick,
so its capture clock is still LUT-driven — **rebuilding it on this branch gives the BUFG version,
making this the cleanest possible A/B for the bring-up-lottery fix, with the ribbon and the pin
lottery removed from the experiment**. Smoke path: `make -C fpga deploy TARGET=kr260-pair-onchip`
(fpgautil + mandatory AFI re-poke) then `kr260_onchip_smoke.py`, then `kr260_onchip_autonomy.py`.
Apertures: die_a APB `0x8403_0000` / die_b `0x8C03_0000` (uniform +0x0800_0000).
Two shared-file changes rode along, both verified backward-compatible (divider-glob superset;
`HONEST_MASK_HS` wrapper param defaulting to the legacy behaviour) — but note the main tree's
packaged IP was regenerated, so **re-run `make -C fpga package_ip` on this branch before builds
that need `CONFIG.HONEST_MASK_HS`**.

## ⚠️ CI CHANGE REQUIRED BEFORE THE BRANCH MERGES
`.gitlab-ci.yml`'s `sim-gate` job (`allow_failure: false`) clones tidelink only, but six of the new
suites need the sibling repos `tidechart`, `nanosoc-ethernet-chiplet` and `ethernet-subsystem-ahb`.
A per-suite `SIM_GATE_REQUIRE` guard fails only its own suites with an actionable message (never a
silent skip), but **the clone job must fetch those three or six suites go red on the first CI run.**

## ✅ THE CAPTURE-CLOCK FIX IS PROVEN (onchip A/B, Sat night)
Same target, same tool, only the branch differs — this is the cleanest evidence the bring-up-lottery
fix has ever had, on the one platform with no ribbon and no pin lottery:
| build | capture-clock driver | verdict |
|---|---|---|
| main tree (pre-cherry-pick) | LUT2, fanout 496 | DEFECTIVE, both dies |
| **recovery branch (2c32c2b)** | **BUFGCE, fanout 496** | **PASS, both dies** |
verify_build PASS (0 warnings), WNS +28.306, WHS +0.010, BUFG-per-region OK, zero-skew trap
netlist-proven. Bitstream `8f8792c975d3dc27790c5631a042b400` in the worktree at
`imp/fpga/output/kr260-pair-onchip/`. **This is the single-board vehicle to deploy first on Monday**
— one board, no ribbon, and if bring-up is now reliable where it was a 1-in-4 lottery, that is the
fix confirmed on hardware.

## Loose ends (tracked, none urgent)
- ~~25 Z2-literal scripts unguarded~~ CLOSED (c8c9ecf): 24 guarded, 1 justified skip
  (stress_lib.py — injected-transport only, no /dev/mem).
- ~~verify_build (d) batch false-positive~~ CLOSED (c8c9ecf): per-target build-window compare.
- ~~test_ptp_corrected_regs not run~~ CLOSED: PASS 4/4.
- The Z2 pair still runs the June-18 build; any future Z2 rebuild inherits the capture-clock RTL
  (validated config, but re-certify with the N=40 soak when convenient).
