# TideLink silicon baseline — 2026-06-23

Known-good, validated-on-silicon reference state. **If something regresses, compare against the
pins, SHAs, and recipes here.** This is the regression anchor — tag `v1-silicon-baseline-2026-06-23`.

Rig: **bridge1** = z2_02 (die_a/master, mgmt 192.168.4.101) ↔ z2_01 (die_b/slave, mgmt 192.168.2.101),
RPi-header ribbon, 8-lane mask 0xff, ~4.687 MHz link. Reached via `mapstone-dev` (user `david`).

## What is proven on silicon (2026-06-23)

| Capability | Status | Evidence |
|---|---|---|
| V1 8-lane link-up (bilateral) | ✅ | fcsm=4 + cr + crack + cal_done both dirs |
| **V1 B→A data delivery** | ✅ | unique payloads cross die_b→die_a byte-exact; `td_v1_b2a_proof.sh` **7/7 PASS** |
| die_b RX eye (A→B), clean clock | ✅ **OPEN** | PHY-BIST: all 8 lanes sy=0xFF lu=1 @ (w13,p3), ~9e-6, 782k words |
| Bilateral link-up (PHY-BIST) | ✅ **SUSTAINED** | both dies sy=0xFF lu=1, ~1e-5, 3×2s holds |
| V1 A→B data delivery (production) | ❌ BLOCKED | die_b flip-build LUT-margin pad_clk_rx; **fix = flip-XDC BUFG rebuild (confirmed by BIST)** |

## Pins — the regression anchors

### V1 production link (B→A proven)
- **RTL:** commit `142a7ca` = tag `v1-silicon-b2a-2026-06-23`
- **Build:** `flists/tidelink_fpga.flist` — V1 PHY in `src/rtl/local_overrides`, **NO `TIDELINK_PHY_V2`**
- **Targets:** `pynq-z2-pair-all` (die_a) + `pynq-z2-pair-flip-all` (die_b)
- **Submodules:** axi-chiplet-controller@`efe5623`, tidelink-gpio-phy@`6ee8418`
- **Bitstream .bit sha256:** die_a=`b039a9b0…`, die_b=`a5e23e6e…`

### PHY-BIST (die_b-eye-good reference — proves eye-vs-logic)
- **Submodule pin:** `deps/tidelink-phy` @ `e92902d` ("basin park — bilateral link_up on silicon")
- **Build:** `make -C flows/fpga TARGET=pynq-z2-phy-bist-pair[-flip] all` (in the submodule; self-contained, ~8 min)
- **Targets:** `pynq-z2-phy-bist-pair` (die_a) + `pynq-z2-phy-bist-pair-flip` (die_b)
- **Bitstream .bit.bin md5:** pair=`ca9a2d9c015c101ad1853f48b87d2ed8`, flip=`2c2182d9c8600c36ac5c1a2b81a5ac49` (4045568 B each)
- **Timing:** WNS +3.5/+4.0, WHS +0.02/+0.05 (closed). 14 build ERROR/CRITICAL = pre-existing word_handoff.xdc name skips (inherent to e92902d, non-fatal).
- **Worktree:** `td-bisect/phy-bist-e92902d` (detached @ e92902d)

## Reproduce / regression-test

### V1 B→A (the headline test)
```sh
# on mapstone-dev — ONE command: programs both, rolls to a clean link, proves a FRESH B→A delivery
pynq_host/scripts/td_v1_b2a_proof.sh --program
#   exit 0 = B→A delivered byte-exact (fresh random payload, so no stale-FIFO false positive)
#   --dir AtoB = A→B acceptance test (PASS only after the die_b BUFG rebuild)
#   --rolls N / -v = more lottery rolls / verbose
```

### PHY-BIST (die_b eye re-characterization)
```sh
# build both halves from e92902d (worktree td-bisect/phy-bist-e92902d), bootgen .bit -> .bit.bin,
# stage as phy_bist.bin / phy_bist-flip.bin to mapstone-dev:/tmp/phy_bist_deploy, then:
exp_park_basin.sh 192.168.4.101 192.168.2.101 /tmp/phy_bist_deploy
#   die_b winscan best (w=13,p=3) -> park both + hold -> bilateral sy=0xFF lu=1
#   (NOT bringup_phy_bist_eyescan.sh — that experimental FIX-J path hits NEEDS-RETRAIN)
```

## Regression comparison points
- **B→A breaks** → compare RTL to `v1-silicon-b2a-2026-06-23` (`142a7ca`); `td_v1_b2a_proof.sh` is the gate. Link-up is a marginal-eye lottery — the script re-rolls (up to N).
- **die_b eye looks bad** → re-run the PHY-BIST from `e92902d` (SHAs above). BIST also fails → real physical/ribbon change. BIST passes → issue is upstream (production clock routing / calibrator basin).
- **die_b A→B fix path** → BIST proved die_b's eye is GOOD with a BUFG clock. Production fix = flip-XDC `pad_clk_rx`→BUFG rebuild of `pynq-z2-pair-flip-all`; acceptance = `td_v1_b2a_proof.sh --dir AtoB` PASS. Caveat: die_b's basin (w13,p3) ≠ die_a's (1,15) and is narrow — confirm the production calibrator finds die_b's basin.

## Key silicon reg map (devmem2)
- APB ctrl base `0x44032000`; LANE_STATUS `0x44032108` ([7:0]lane_locked [16]cal_done [19:17]fcsm [23]cr [24]crack); ROLE_CFG `0x44032080` (W1S bit1=role_lock); apb_debug_unlock GPIO `0x44041000`.
- Data apertures (GP1): TX `0x84000000`, RX FIFO `0x84010000` (GP0 0x44xxxxxx data hangs).
- PHY-BIST APB (separate bitstream): base `0x44060000` (ID `0x7868B157`), role strap `0x44040000`.

## Memory cross-refs
`project_v1_silicon_b2a_delivery_2026_06_23`, `project_phy_bist_die_b_eye_confirmed_2026_06_23`,
`project_phy_harness_landscape`, `project_v1_sync_beacon_dormant_2026_06_22`.
