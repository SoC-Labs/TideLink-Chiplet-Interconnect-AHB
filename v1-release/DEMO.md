# DEMO — How to bring up a TideLink pair on PYNQ-Z2

Tested 2026-05-22 against the bridge1 pair (`pynq_z2_02_pl` + `pynq_z2_03_pl`)
with the shipped `tl_v7` bitstream.
Result: **13 / 16 lanes best lock** (mean ~8/16, cal_done=1), confirmed both
pre- and post-power-cycle. (Note: an earlier "14.40/16" figure was attributed to
a different build that is now known to be non-locking — see KNOWN_ISSUES.md.)

## Prereqs

- Two PYNQ-Z2 boards wired as a TideLink pair (16-lane source-synchronous link
  between PMOD JA/JB). Network: master `192.168.4.101`, slave `192.168.6.101`.
- A staging host with `sshpass` + `ssh` reachability to both boards
  (e.g. `mapstone-dev` via fpgahub `pair lease`).
- `fpgahub` CLI (`pip install git+https://...`) for lease management.

## Step 1 — Stage the bitstream

Both boards run with the **same** `.bin/.hwh` pair conventionally; the optional
"flip" pair (`tidelink-flip.bin/.hwh`) carries the opposite pin assignment when
you want to interchange master and slave wiring without changing the BD.

```bash
# From this v1-release/ tree, on a host that can reach mapstone-dev
scp bitstreams/tidelink.bin  bitstreams/tidelink.hwh  \
    bitstreams/tidelink-flip.bin bitstreams/tidelink-flip.hwh \
    mapstone-dev:/tmp/tidelink_deploy/

# Verify checksums
sha256sum -c CHECKSUMS.sha256
```

## Step 2 — Acquire bridge1 lease

```bash
ssh mapstone-dev "fpgahub pair lease acquire bridge1"
# Sanity-check
ssh mapstone-dev "fpgahub pair lease show bridge1"
```

## Step 3 — Bring-up the pair (closed-loop convergence)

The script does coordinated parallel `recal_cycle` re-arms on both boards and
settle-then-read until both ends report all 8 lanes locked (or `MAX_RETRIES`).

```bash
ssh mapstone-dev "cd /home/david/SoCLabs/tidelink && \
  MAX_RETRIES=20 STABLE=3 \
  ./pynq_host/scripts/bringup_pair_converge.sh"
```

Expected: per-iteration lock/fault/cal_done line; convergence within a couple
of iterations on a good day; PASS at `total=16`.

## Step 4 — Statistical reliability characterisation (optional)

Re-deploys N times without early-exit to gather per-deploy lock distribution.

```bash
ssh mapstone-dev "cd /home/david/SoCLabs/tidelink && \
  N_DEPLOYS=20 \
  ./pynq_host/scripts/bringup_reliability.sh"
```

Today's run against this bitstream is in `reliability.log` — see that file
for the empirical distribution.

## Step 5 — Release the lease

```bash
ssh mapstone-dev "fpgahub pair lease release bridge1"
```

## Troubleshooting

- **0/16 every deploy after a fresh rebuild**: this is **Bug #5/#25** (env
  regression on srv04936). The v1 release deliberately ships the morning
  pre-built bitstream because source-level rebuilds on srv04936 currently
  produce a non-converging artifact even from byte-identical sources.
  Use this bundle's `tidelink.bin/.hwh` — do not re-synth for v1.

- **Stuck `cal_done=0`**: typically a deploy-skew lottery; re-run `bringup_pair_converge.sh`.
  The S_HOLD + IDELAYE2 + T3 re-sweep mechanisms in the morning bitstream are
  designed to ride out ms-scale role_lock skew, but recal re-arms still help.

- **Lease shows `held` by another holder**: don't kill — coordinate. Leases
  auto-expire (typical 30 min). If suspected stale, contact the holder before
  forcing a release.

## ASIC bring-up

This bundle ships ASIC chip-top integration artifacts in `asic/`. See
`asic/MANIFEST_fusion_compiler.md` for the integration recipe (read_lef +
read_def + read_sdc, plus `FC_PRESERVE_WLINK_FCSM=on` if you want zero LEC
residuals on the Wlink FCSM cones). LEC verdict is in
`asic/03b_verify_summary_final.rep`.
