# TideLink Board Deploy Runbook — z2_02 / z2_03 (bridge1)

**Audience:** anyone (human or agent) deploying TideLink bitstreams to the
PYNQ-Z2 bridge pair. Every failure mode in §7 was hit for real during the
2026-06-09→11 sessions; the fixes are verified.

**Last verified end-to-end: 2026-06-11** (v33 `--no-verify` and v34
`--manifest` flows, both boards, four-for-four).

---

## 1. Topology — who can reach what

```
  you (srv03335 / dev box)
        │  ssh david@mapstone-dev          ← the ONLY route to the boards
        ▼
  mapstone-dev (10.22.27.178)
        │  ssh xilinx@192.168.4.101        z2_02 = die_a = master-strap board
        │  ssh xilinx@192.168.6.101        z2_03 = die_b = slave-strap board
        │  (password: xilinx, or $TIDELINK_BOARD_PASS)
        └─ hw_server tcp::3121             FT2232H JTAG to all of z2_01..z2_04
```

- **Your dev box cannot reach `192.168.4.x` / `192.168.6.x` directly.** If a
  bare `ssh xilinx@192.168.4.101` times out, that is host routing, not a dead
  board. Always go through mapstone-dev (interactively or `-J`).
- The deploy scripts therefore **run on mapstone-dev**, against its own
  checkout at `/home/david/SoCLabs/tidelink` and artefact store at
  `/home/david/tidelink_artefacts/`.
- JTAG (xsdb / Vivado HW manager on `:3121`) is the independent second
  channel — survives any SSH/PS state, used for ILA capture and for the
  `rst -system` rescue (§7.6).

## 2. Prerequisites checklist

Run through ALL of these before blaming the deploy flow:

1. **Lease is GRANTED, not queued.**
   ```bash
   fpgahub status        # on your dev box or mapstone-dev
   ```
   Both `pynq_z2_02…` and `pynq_z2_03…` rows must show your lease. fpgahub
   QUEUES when someone else holds the boards — a queued lease looks alive
   but deploys against the holder's session. If another agent/session holds
   them, coordinate; do not deploy over a live investigation.

2. **Boards answer SSH and fpga_manager is sane.**
   ```bash
   ssh david@mapstone-dev
   sshpass -p xilinx ssh -o StrictHostKeyChecking=no xilinx@192.168.4.101 \
       'hostname; cat /sys/class/fpga_manager/fpga0/state'
   # expect: pynq-z2-02  /  "operating" (or "unknown"/blank after a reboot —
   # that just means no bitstream is loaded yet; deploy proceeds normally)
   ```
   If SSH itself hangs/dies on one board → it is PS-wedged → §7.6 first.

3. **The artefact set is COMPLETE.** A deployable version directory on
   mapstone-dev needs **all four** of these per image, named exactly:
   ```
   ~/tidelink_artefacts/vNN/
   ├── tidelink.bin                      # die_a (non-flip) bitstream, bit2bin'd
   ├── tidelink.hwh                      # die_a hardware handoff  ← REQUIRED
   ├── tidelink-flip.bin                 # die_b (flip) bitstream
   ├── tidelink-flip.hwh                 # die_b hardware handoff  ← REQUIRED
   ├── tidelink.bin.manifest.json        # provenance (preferred; see §4)
   └── tidelink-flip.bin.manifest.json
   ```
   **The `.hwh` files are not optional.** `deploy_pair.sh` scp's the `.hwh`
   before flashing and gives up ("board NOT in 'operating' state") if it is
   missing — this exact gap broke the first v34 deploys (§7.1).

## 3. Producing and staging artefacts (build host → mapstone-dev)

From a repo checkout on the build host:

```bash
# 1. Build both halves of the pair (concurrent, ~22 min on a quiet host):
cd fpga && make build_pair_concurrent
# outputs: imp/fpga/output/pynq-z2-pair-all/tidelink.bit (+ .hwh, .ltx)
#          imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit (+ ...)

# 2. The farm flow STOPS AT .bit — you must convert explicitly.
#    Stale .bin files from earlier builds may be sitting in the output dirs;
#    ALWAYS regenerate (and compare sha256 against the previous version to
#    prove you are not staging an old image — this bit us once):
python3 fpga/scripts/bit2bin.py \
    imp/fpga/output/pynq-z2-pair-all/tidelink.bit \
    imp/fpga/output/pynq-z2-pair-all/tidelink.bin
python3 fpga/scripts/bit2bin.py \
    imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit \
    imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin

# 3. Generate provenance manifests (lets deploys verify instead of --no-verify):
bash pynq_host/scripts/make_bitstream_manifest.sh \
    imp/fpga/output/pynq-z2-pair-all/tidelink.bin \
    --label "vNN-<short-desc>" --commit "$(git rev-parse --short HEAD)" \
    --target pynq-z2-pair-all --lock-min 8
bash pynq_host/scripts/make_bitstream_manifest.sh \
    imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin \
    --label "vNN-<short-desc>" --commit "$(git rev-parse --short HEAD)" \
    --target pynq-z2-pair-flip-all --lock-min 8

# 4. Stage to mapstone-dev. NOTE: rsync and often scp FAIL between the dev
#    hosts (protocol incompatibility). Use a tar-over-ssh pipe:
cd imp/fpga/output
mkdir -p /tmp/stage
cp pynq-z2-pair-all/tidelink.{bin,hwh}                 /tmp/stage/
cp pynq-z2-pair-all/tidelink.bin.manifest.json         /tmp/stage/
cp pynq-z2-pair-flip-all/tidelink.bin                  /tmp/stage/tidelink-flip.bin
cp pynq-z2-pair-flip-all/tidelink.hwh                  /tmp/stage/tidelink-flip.hwh
cp pynq-z2-pair-flip-all/tidelink.bin.manifest.json    /tmp/stage/tidelink-flip.bin.manifest.json
tar -C /tmp/stage -cf - . | ssh david@mapstone-dev \
    'mkdir -p ~/tidelink_artefacts/vNN && tar -C ~/tidelink_artefacts/vNN -xf - && sha256sum ~/tidelink_artefacts/vNN/*.bin'

# 5. Verify the printed sha256s match your local `sha256sum */tidelink.bin`.
```

Use a persistent `~/tidelink_artefacts/vNN/` directory, **not**
`/tmp/tidelink_deploy/` — /tmp staging is volatile and is how a stale
bitstream once got flashed by mistake (the provenance gate exists because
of that incident).

## 4. The standard deploy — `deploy_pair.sh` (one board at a time)

Run **on mapstone-dev**:

```bash
# Preferred — manifest-verified (refuses to flash if sha256 mismatches):
bash ~/SoCLabs/tidelink/pynq_host/scripts/deploy_pair.sh \
    192.168.4.101 z2_die_a die_a ~/tidelink_artefacts/vNN \
    --manifest ~/tidelink_artefacts/vNN/tidelink.bin.manifest.json

bash ~/SoCLabs/tidelink/pynq_host/scripts/deploy_pair.sh \
    192.168.6.101 z2_die_b die_b ~/tidelink_artefacts/vNN \
    --manifest ~/tidelink_artefacts/vNN/tidelink-flip.bin.manifest.json

# Escape hatch when no manifest exists (e.g. legacy v33):
bash ... deploy_pair.sh 192.168.4.101 z2_die_a die_a ~/tidelink_artefacts/v33 --no-verify
```

Argument meanings: `<BOARD_IP> <LABEL> <ROLE: die_a|die_b> <ARTEFACT_DIR>`.
The ROLE selects the bitstream (`die_b` → `tidelink-flip.bin`) and the role
strap/ctrl pokes.

**What it does, in order** (so you can tell where a failure happened):
1. scp `tidelink[-flip].bin` → board `/tmp/`
2. scp `tidelink[-flip].hwh` → board `/tmp/`   ← fails here if .hwh missing
3. `cp /tmp/tidelink.bin /lib/firmware/` + `echo tidelink.bin >
   /sys/class/fpga_manager/fpga0/firmware` (the actual flash)
4. Out-of-band re-read of `fpga_manager/state` — must be `operating`
5. Post-load APB pokes: `PHY_CTRL` (per-board IDELAY phase; override with
   env `PHASE_OVERRIDE=0x...`), `PAIR_BASE_ADDR=0x44032000`,
   `ROLE_CFG` (0x2 die_a / 0x3 die_b, lock bit set)

**Success looks like:**
```
==== z2_die_a @ 192.168.4.101 — role=die_a strap=0 ctrl=0x2 bitstream=tidelink.bin ====
  fpga_manager: operating
  PHY_CTRL       = 0x00000000 (swi_phase_offset=0)
  PAIR_BASE_ADDR = 0x44032000
  ROLE_CFG       = 0x02 (lock=1, cfg=0)
==== z2_die_a done (sha256=… label=vNN-…) ====
```

**v34+ note:** images with POR autonomy (NEGO_CFG_RESET=0x61) start
arbitrating over I2C the moment they are flashed. The ROLE_CFG read-back may
show the **arbitrated** role rather than the one the script wrote (boot
order beats strap under skew — known, documented behaviour, not a deploy
failure).

## 5. The full bring-up — `bringup_pair_converge.sh` (the normal path)

Deploy-only gets you two configured dies; the **link** needs the
calibration/converge loop. This is the tool that closes it:

```bash
ssh david@mapstone-dev
ARTEFACTS=~/tidelink_artefacts/v33 \
DEPLOY_PAIR_NOVERIFY=1 \
MAX_RETRIES=12 SETTLE=2 BESTOF=3 \
bash ~/SoCLabs/tidelink/pynq_host/scripts/bringup_pair_converge.sh
```

**CRITICAL GOTCHA:** the converge script's no-manifest fallback is gated on
the **environment variable `DEPLOY_PAIR_NOVERIFY=1`**. Passing `--no-verify`
as an *argument* to the converge script does nothing — every per-iteration
deploy then aborts with `rc=5` (provenance gate) and you burn all
MAX_RETRIES learning nothing. (12 iterations were wasted on exactly this.)
If manifests exist next to the bins, neither is needed — it auto-uses them.

It re-deploys BOTH boards per iteration (re-rolls the word-counter skew
lottery), polls lane lock/cal_done, and on 16/16 runs `sync_bootstrap`
(CTRL_DIS → CTRL_FULL → clear `swi_training_mode` — the M12 fix) unless the
link is already up. Success ends with:

```
RESULT: CAL CONVERGED — full 16/16 bidirectional cal+lock at iteration 1
  die_a FCSM=4  die_b FCSM=4
  LINK_IDLE (state 4) BILATERAL — FCSM handshake complete.
```

Convergence is usually iteration 1–2 but is a genuine lottery on marginal
eyes; a run that ends `FCSM not yet at LINK_IDLE` (e.g. fs2/fs1) is not a
deploy failure — just re-run.

## 6. Verifying a deploy beyond "operating"

```bash
# Lane/link status — decode of SWI_LANE_STATUS @ 0x44032108:
#   [7:0] lane lock  [15:8] fault  [16] cal_done  [20:17] FCSM
#   [23] cr_seen  [24] crack_seen  [30] a2l_lnk  [31] fe_full
bash ~/SoCLabs/tidelink/pynq_host/scripts/wlink_probe.sh 192.168.4.101

# v34+ image canary: Region C magic
#   python mmap read of 0x44032190 == 0x4F420100 proves the v34 register
#   set is live (and Region 4 @0x44032094 = NEGO_STATUS shows arbitration).
```

Interpretation notes that save hours:
- **`lk=0x00` after training is EXPECTED** once `swi_training_mode` clears —
  the lane checker only matches training patterns. Judge link health by
  FCSM + cr/ck, not lane lock (criterion B in `hwtest/lib/lib_hwtest.sh`).
- `devmem` is NOT installed on the boards. Use a staged python mmap helper
  (see `pynq_host/scripts/unjam_fc_node.sh` for the canonical pattern —
  stage a real .py file; triple-nested shell quoting of inline `python3 -c`
  through ssh×2 + sudo WILL silently mangle).

## 7. Failure modes — all field-verified

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 7.1 | `DEPLOY-FAIL: scp .hwh … GIVING UP … board NOT in 'operating' state` | artefact dir missing `tidelink[-flip].hwh` | stage the `.hwh` from `imp/fpga/output/<target>/` (§2.3, §3) |
| 7.2 | `DEPLOY-ABORT: UNVERIFIED DEPLOY` (exit 5) | neither `--manifest` nor `--no-verify` given | pass one of them; prefer manifests |
| 7.3 | converge loop: every iteration `deploy rc=5`, table full of `?/?` | `--no-verify` passed as ARG to converge | it must be env: `DEPLOY_PAIR_NOVERIFY=1` (§5) |
| 7.4 | `DEPLOY-ABORT: staged sha256 mismatch vs manifest` | stale/wrong .bin in the artefact dir | re-run bit2bin + manifest from the intended build; never reuse /tmp staging |
| 7.5 | deploys "succeed" but you're flashing over someone's session | lease held by another principal (fpgahub queues yours) | `fpgahub status` first; coordinate (§2.1) |
| 7.6 | board SSH dead / `/dev/mem` Bus error | PS hard-wedge (Bug-A class: blocked AHB write → PS AXI deadlock; pre-`4c0a51a` images) | JTAG: `xsdb` on mapstone-dev → `connect -url tcp:localhost:3121` → `targets -set -filter {jtag_cable_name =~ "*Z2_02*" && name =~ "APU*"}` → `rst -system`; then wait ~45 s for Linux, redeploy. Images with the fc_adapter stall-timeout (≥`4c0a51a`) degrade to a bus error instead — reboot/reflash clears |
| 7.7 | link up then data path jams: FCSM=5 + `0x108[30]`=1 + `0x108[31]`=0 | un-ACKed long packet (residual #6) | `pynq_host/scripts/unjam_fc_node.sh <IP>`, or full re-converge |
| 7.8 | `rsync error: protocol incompatibility` / scp failures host→host | dev-host ↔ mapstone-dev transport mismatch | tar-over-ssh pipe (§3.4) or base64-encode small files |
| 7.9 | board boots but PL reads Bus-error right after reboot | PL simply unprogrammed (reboot clears it) | not a fault — deploy |
| 7.10 | `/tmp/rd.py` style helpers missing after reboot | board `/tmp` cleared on reboot | re-stage helpers (scripts do this themselves) |

## 8. Golden path, end to end (copy-paste)

```bash
# on the build host, repo root, after a green sim gate:
cd fpga && make build_pair_concurrent && cd ..
python3 fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-all/tidelink.bit imp/fpga/output/pynq-z2-pair-all/tidelink.bin
python3 fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin
bash pynq_host/scripts/make_bitstream_manifest.sh imp/fpga/output/pynq-z2-pair-all/tidelink.bin --label vNN --commit $(git rev-parse --short HEAD) --target pynq-z2-pair-all --lock-min 8
bash pynq_host/scripts/make_bitstream_manifest.sh imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin --label vNN --commit $(git rev-parse --short HEAD) --target pynq-z2-pair-flip-all --lock-min 8
# ... stage per §3.4 ...

# on mapstone-dev:
fpgahub status                      # lease GRANTED on both z2_02/z2_03 rows?
ARTEFACTS=~/tidelink_artefacts/vNN MAX_RETRIES=12 SETTLE=2 BESTOF=3 \
    bash ~/SoCLabs/tidelink/pynq_host/scripts/bringup_pair_converge.sh
# expect: CAL CONVERGED 16/16 + "LINK_IDLE (state 4) BILATERAL"
bash ~/SoCLabs/tidelink/pynq_host/scripts/wlink_probe.sh 192.168.4.101   # sanity
```

## 9. Policy reminders

- **Sim gate before HW deploy** is standing policy: the integrated paired-die
  cocotb suite must pass before a farm build is kicked (a sim-discoverable
  bug once burned 75 minutes of farm+deploy time).
- AHB_TX writes to a not-fully-up link are the historical board-killer; use
  the hwtest gating (`tt_gate_ahb_tx`) rather than raw pokes.
- The remote tidelink checkout on mapstone-dev (`/home/david/SoCLabs/tidelink`)
  drifts from your branch — when a deploy behaves differently from your
  reading of the script, diff the remote copy first.
