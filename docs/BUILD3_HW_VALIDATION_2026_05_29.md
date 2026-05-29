# Build #3 HW validation — Fix A2+B lands; new gap surfaces

**Date:** 2026-05-29 13:00-13:15 BST
**Build SHA:** `dda0a0e` (includes calibrator commit 85f0e48 Fix A2+B + AUTOCAL_ENABLE=1)
**Bitstream sha256 master:** `d15adec0…` slave: `b02cecc9…`
**Lease:** bridge1 held by mapstone-dev until 16:09 BST
**Result:** Calibrator fix proven on silicon; AHB-packet / PTP-sync delivery to slave is a new, separate gap

## Headline

| Capability | Build #1 (overnight) | Build #3 |
|---|---|---|
| Link converge 16/16 | Reported but raw data corrupt | **YES, iter 1, clean** |
| `cal_done=1` both sides | Asserted but on (0,0) trivially | **YES, persists across iters** |
| Doorbell M→S (APB) | Worked with retries | **WORKS** |
| Doorbell S→M (APB) | Worked with retries | **WORKS bidirectional** |
| AHB N=1 TX wedge | Hung kernel | **NO WEDGE — HREADY 0.17ms** |
| AHB N=1 RX delivered | RX empty | RX empty (separate bug) |
| PTP HW_SYNC reaches slave | RX empty | RX empty (separate bug) |

**Calibrator Fix A2+B is silicon-validated.** The sticky-low `dwell_min_dist` pathology that made the calibrator pick (0,0) every time no longer occurs.

## What changed at silicon level

- bringup_pair_converge.sh converged on **iteration 1 of 8** (vs build #1: iter 1 but on junk phase; build #2: NORMAL never converged)
- After `td_clear_train.py`, both sides hold `cal_done=1` — chosen phases survive training-mode drop
- The wedge primitive is **gone**: HREADY returns within 0.17 ms even with no end-to-end RX

## Sandwich loop summary (6 iterations)

```
trace: . A A A A A
link_down=0 doorbell_fail=0 ptp_fail=0 ahb_fail=5 pass=1
```

- "A" = doorbell + PTP-status passed, AHB N=1 RX read returned `n=0`
- Master `resp_acc` bumps 0 → 20480 (= 0x5000) each iter; suggests `REG_DOORBELL_RESP_ACC` counts inbound FC traffic broadly. **Evidence that FC layer reliably delivers M→S packets** — they just don't land at AHB_RX FIFO or PTP HW_SYNC RX.

## New gap: slave-side packet demux

Works: FC link, doorbell channel, AHB_TX HREADY.
Doesn't work: AHB packet RX at slave 0x44010000, PTP HW_SYNC slave RX (status=0 while master=0x1e0d initiator-active).

Hypothesis: slave-side FC adapter / returner does not route inbound FC packets to AHB_FIFO / PHC HW_SYNC RX endpoints. Packets cross the wire (counter evidence) but get dropped or mis-routed at slave demux. Independent of Fix A2+B — a wrapper/integration bug, likely in `tidelink_top.sv` glue or `axi-chiplet-controller` returner. Same family as memory entry `project_tidelink_bug_isolated_2026_05_26.md`.

## Concrete next steps (need user authorization)

1. Static analysis of slave-side returner / fc_adapter for FC-channel → RX-endpoint mapping. No HW change needed.
2. Compare doorbell vs AHB FC node IDs via `wlink_probe.sh` per-channel counters.
3. PTP-specific check: master `PTP_CTRL=0x0d` vs slave `0x05` — bit 2 differs. May matter for RX accept.
4. Loopback bring-up bisect: confirm slave demux works in self-loopback.

## Operational notes

- bit2bin.py at `fpga/scripts/` converts .bit → .bin
- Manifests use full sha256 + label; deploy_pair.sh rejects unverified deploys
- `cal_done` lives at **bit 16** of `SWI_LANE_STATUS` (not bit 8)
- Slave `lane_locked` reads 0 after training_mode clear (expected — lane_checker can't match FC payload to pattern). `cal_done` is the correct post-training gate.
