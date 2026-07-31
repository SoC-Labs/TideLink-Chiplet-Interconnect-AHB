# Weekend soak-CI harness — KR260 eth-chiplet pair

Autonomous, detached, reproducible weekend soak of the two-board KR260 eth-chiplet
TideLink pair. Runs on **mapstone-dev** (the host that owns the fpgahub socket and
reaches both boards). Every iteration is a randomised cross-die corner derived
purely from a seed, run wedge-safely, and folded into a live dashboard.

## Files

| File | Role |
|---|---|
| `weekend_campaign.sh` | Detached outer driver: leases + keepalive, per-iter POR→deploy→bring-up→iter→dashboard, clean-stop + park handling. |
| `campaign_iter.py` | One iteration state machine. `derive_plan(seed)` is pure; the whole iter replays from `--seed S`. Wedge-safe soak in ~200-beat chunks + flight recorder. |
| `por_recover.sh` | JTAG-POR one board at a time (global `flock`), 3× cable retry, bounded ping/ssh wait, PARK + `ALERT_*.txt` after `MAX_POR`. |
| `dashboard.py` | Folds `iterations.jsonl` (+ `failures/*.json`) → `DASHBOARD.txt` (atomic). MTBF, beats-without-wedge, coverage, wedge-node taxonomy, park banner. |

Depends on companion scripts in the parent dir (created separately):
`xfer_corners_lib.py` (`golden_base`/`snap_health`/`classify_wedge`) and
`health_snapshot.py` (on-board RO one-shot). The harness imports/calls them and
falls back to `kr260_eth_xfer.py`'s proven `fc_health`/`link` modes if the
companion API differs, so a mismatch never kills the weekend run.

## Ground truth

- die_a = `ubuntu@10.22.24.159` = fpgahub `kr260_01` = image `kr260-eth-chiplet`.
- die_b = `ubuntu@10.22.24.153` = fpgahub `kr260_02` = image `kr260-eth-chiplet-flip`.
- Board password default `soclabs2026`.
- PS reaches the SoC ONLY via the `eth_ss_0` backdoor (`0x4_0000_0000 + addr`); the
  AXI data plane wedges the PS bus with **no** timeout, so every peer access is
  subprocess-timeout-wrapped (a timeout == WEDGE), and the soak verify is always a
  **local** read (`kr260_eth_soak_fwd.py verify`) — never a peer read.
- Recovery is **JTAG-POR only** (`por_recover.sh`), never `sudo reboot`.

## Friday-kickoff (run these on mapstone-dev)

```bash
# 0. one-time: land the branch's scripts on both boards (deploy stages ~/td/scripts/)
cd /home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet
W=tidelink/pynq_host/scripts/weekend

# 1. sanity (no boards touched): plan is reproducible, dashboard renders
python3 $W/campaign_iter.py --seed 1 --print-plan
python3 $W/campaign_iter.py --seed 1 --print-env

# 2. confirm leases are free, then launch DETACHED for the weekend (~58h budget)
fpgahub status                      # kr260_01 / kr260_02 should be free
cd $W
setsid nohup env BUDGET_H=58 BASE_SEED=1 KR260_PASSWORD=soclabs2026 \
    bash weekend_campaign.sh > weekend.boot.log 2>&1 &
echo "launched pid $!"

# 3. watch it (OUT is printed in weekend.boot.log / driver.log)
OUT=$(ls -dt runs/weekend_* | head -1)
tail -f "$OUT/logs/driver.log"      # live driver log
watch -n30 cat "$OUT/DASHBOARD.txt"  # live dashboard
```

### Stopping / recovery

```bash
touch "$OUT/STOP"                    # clean stop: finishes the current iter, then exits
# A parked board writes OUT/ALERT_<target>.txt; the run aborts only if BOTH park.
# Manual single-board POR (also what por_recover.sh drives):
ssh mapstone-dev "curl -s --unix-socket /run/fpgahub/fpgahub.sock -X POST \
  http://localhost/api/v1/targets/kr260_01/reset -H 'Content-Type: application/json' \
  -d '{\"method\":\"default\",\"confirm\":true}'"
```

### Reproduce a failure

Each `failures/iterN_seedS.json` carries the plan, both dies' last-good health
snapshots, the surviving-die snapshot, the wedge-node taxonomy, and a one-line
repro:

```bash
python3 campaign_iter.py --seed S --out /tmp/repro_S   # replays that exact corner
```

## Two assumptions to CONFIRM at kickoff

1. **fpgahub lease semantics.** There is no documented `lease renew` verb, so the
   keepalive **re-acquires** (`fpgahub lease acquire`) every `KEEPALIVE_S` (default
   1800s, i.e. TTL/2 assuming a ~1h TTL). Confirm the real lease TTL and that
   re-`acquire` on a lease you already hold is a no-op refresh (not a conflict) —
   adjust `KEEPALIVE_S` to ≤ TTL/2. Also confirm `fpgahub lease release` is the
   correct teardown verb.
2. **CAM must be armed before the soak.** `kr260_eth_soak_fwd.py write` does **not**
   program the address-translator CAM; `campaign_iter.py` issues one arming access
   (`kr260_eth_xfer.py --mode sender` for the 0x2F→0x2D SRAM path, `--mode
   mbox_send` for 0x2F→0x23) after bring-up, before the first chunk. Confirm this
   single arming write is sufficient for a whole soak (CAM state persists until the
   next `poresetn` / re-arm) and that `sram`/`mailbox`/`mixed` re-arming order is
   correct on silicon.

## Safety rules baked in

- In-window addresses only (all board access goes through the proven
  `kr260_eth_*` tools; the harness never pokes a raw address).
- Bring-up only on freshly-POR'd + reflashed dies; never re-bring-up a live link.
- Teardown between iters = JTAG-POR; POR is `flock`-serialised, bounded, and parks
  (never infinite-spins).
- Known non-gating bugs are logged, not fatal: eth_ss_0 boot-ROM **bit-27** drop,
  `sram_rtt` peer-read wedge-proneness (readback probe is rare + opt-in),
  tidechart election convergence.
- Leases released on exit; final dashboard written on exit.
