# DEMO — How to bring up a TideLink pair on PYNQ-Z2

Tested 2026-05-22 against the bridge1 pair (`pynq_z2_02_pl` + `pynq_z2_03_pl`)
with the shipped `72c280b` bitstream pair.
Result: **16 / 16 lanes** (cal_done=1, fault=0x00). Reliability distribution in
`reliability.log`.

## Prereqs

- Two PYNQ-Z2 boards wired as a TideLink pair (16-lane source-synchronous link
  over the RPi-GPIO ribbon). Network: master `192.168.4.101`, slave `192.168.6.101`.
- A staging host with `sshpass` + `ssh` reachability to both boards
  (e.g. `mapstone-dev` via fpgahub `pair lease`).
- `fpgahub` CLI for lease management.

## Step 1 — Stage the bitstream (two-bitstream layout)

The master runs `tidelink.bin` (die_a) and the slave runs `tidelink-flip.bin`
(die_b, mirrored RPi-GPIO pin map) when using a straight-through ribbon.

```bash
# From this v1-release/ tree. Use cat|ssh (NOT scp) to mapstone-dev — the
# ssh-agent profile banner corrupts scp of binaries.
mkdir -p stage
for f in tidelink.bin tidelink.hwh tidelink-flip.bin tidelink-flip.hwh; do
  cat bitstreams/$f | ssh mapstone-dev "cat > ~/td_stage/$f"
done
# Verify on the staging host BEFORE deploy
ssh mapstone-dev 'cd ~/td_stage && md5sum *.bin'
#   expect: e2bd4d9ff308db8c0c46c0000b143f25  tidelink.bin
#           0f752a059557779a584400138cff8098  tidelink-flip.bin
sha256sum -c CHECKSUMS.sha256   # local self-check of the bundle
```

The deploy path also SHA256-verifies the bitstream against its
`*.bin.manifest.json` sidecar before flashing (deploy-provenance guard) and
aborts on mismatch.

## Step 2 — Acquire bridge1 lease

```bash
ssh mapstone-dev "fpgahub pair lease acquire bridge1"
ssh mapstone-dev "fpgahub status"   # confirm 'held' by you BEFORE deploy
```

## Step 3 — Bring-up the pair (closed-loop convergence)

```bash
ssh mapstone-dev "cd ~/td_stage && \
  MAX_RETRIES=20 STABLE=3 ARTEFACTS=~/td_stage \
  bash scripts/bringup_pair_converge.sh"
```

Expected: per-iteration lock/fault/cal_done line; convergence to `total=16`.

## Step 4 — Statistical reliability characterisation (optional)

```bash
ssh mapstone-dev "cd ~/td_stage && \
  N_DEPLOYS=20 ARTEFACTS=~/td_stage bash scripts/bringup_reliability.sh"
```

This bundle's run is in `reliability.log`.

## Step 5 — Release the lease

```bash
ssh mapstone-dev "fpgahub pair lease release bridge1"
```

## Troubleshooting

- **0/16 every deploy after a fresh rebuild**: confirm the build carries the
  `USE_CLKBUF`/`USE_IDELAY` fix. Check the routed reports for `Place 30-568`
  count = 0 and `IDELAYE2`/`BUFG` presence; a LUT-driven capture clock (`Place
  30-568` > 0, negative WHS) means the fix was stripped (this is the rc1 root
  cause — see `docs/reference/LANE_LOCK_ROOT_CAUSE.md`). Do not try to fix it in XDC;
  the fix is RTL.

- **Stuck `cal_done=0`**: deploy-skew lottery; re-run `bringup_pair_converge.sh`.
  The S_HOLD + IDELAYE2 + recal re-sweep mechanisms ride out role_lock skew.

- **Lease shows `held` by another holder**: don't kill — coordinate. Leases
  auto-expire. If suspected stale, contact the holder before forcing a release.

- **HAZARD**: never write `AHB_TX` (0x4400_0000) from the PS until the link is
  verified up — it can wedge the board and require a physical power-cycle. All
  bring-up scripts here are safe-ops only.

## ASIC bring-up

This bundle ships ASIC chip-top integration artifacts in `asic/`. See
`asic/MANIFEST_fusion_compiler.md` for the integration recipe (read_lef +
read_def + read_sdc, plus `FC_PRESERVE_WLINK_FCSM=on` for zero LEC residuals on
the Wlink FCSM cones). LEC verdict is in `asic/03b_verify_summary_final.rep`.
