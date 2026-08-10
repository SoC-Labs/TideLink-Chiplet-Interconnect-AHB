# Bring-Up

First light on a board, start to finish: build a bitstream, stage it, take the
rig, POR, deploy, bring the link up, prove a byte-exact data crossing, then run
the regression suite.

The two platforms share almost no procedure, so this page has two lanes —
[PYNQ-Z2](#lane-a-pynq-z2-pair) and [KR260](#lane-b-kr260) — followed by a
[troubleshooting decision tree](#troubleshooting-decision-tree) that applies to
both.

Read [Boards](boards.md) first for the rig inventory, the lease protocol and
the POR procedures. Register semantics are in [Register Map](register_map.md).

:::{important}
**Sim gate before hardware is standing policy.** `make sim_gate` must be green
before a farm build is kicked and before any hardware deploy — a
sim-discoverable bug once burned 75 minutes of farm plus deploy time
(`docs/BOARD_DEPLOY_RUNBOOK.md` §9). See [Verification](verification.md).
:::

## Step 0 — preconditions

```{list-table}
:header-rows: 1
:widths: 30 70

* - Check
  - How
* - Environment sourced
  - `source ./set_env.sh` from the repo root. Without it every simulation suite
    fails in 4–5 s in a way that looks exactly like RTL breakage.
* - V2 selected (if building a V2 image)
  - `export TIDELINK_PHY_V2=1` **before** `package_ip`. Without it the flow
    silently packages the V1 flist — check the banner in
    `imp/fpga/run/package_ip.log` every time.
* - Sim gate green
  - `make sim_gate` exits 0. `make sim_gate_inventory` lists the suites without
    running anything.
* - Farm gate green (before a farm build)
  - `make farm_gate` — refuses a farm build on a Tier-0 lint regression or a
    Tier-1 silicon-fingerprint sim failure. `make farm_gate_fast` is lint-only.
* - Lease granted
  - `fpgahub status` shows **your** lease on both board rows — *granted*, not
    queued. See [Boards](boards.md) for the current CLI caveat.
* - Boards answer
  - SSH works and `/sys/class/fpga_manager/fpga0/state` is readable.
```

## Lane A: PYNQ-Z2 pair

### A1. Build both halves

```sh
source ./set_env.sh
export TIDELINK_PHY_V2=1        # for a V2 image

# Both halves in parallel on this host (~22 min for the z2 pair)
make -C fpga build_pair_concurrent

# …or offload the slave half to a farm host
make -C fpga build_pair_farmed FARM_HOST=farm-host-a

# …or fan out explicitly
make -C fpga farm_build FARM_JOBS="pynq-z2-pair-all@local pynq-z2-pair-flip-all@farm-host-a"
```

`build_pair_concurrent` defaults to `PAIR_A=pynq-z2-pair-all` /
`PAIR_B=pynq-z2-pair-flip-all` (`fpga/Makefile:499-519`). Outputs land at
`imp/fpga/output/<TARGET>/tidelink.bit` plus `.hwh` and `.ltx`.

A single target is `make -C fpga build_design TARGET=<target>`, and
`make -C fpga all TARGET=<target>` runs the whole flow (`all: build_design`,
`fpga/Makefile:344`). `make -C fpga package_ip` is the IP-packaging step and is
guarded by `fpga/scripts/check_wrapper_params.sh`, which catches the class of
regression where wrapper parameters are stripped from the IP face. The `-all`
targets additionally need `make -C fpga package_phc_ip` (requires
`PHC_REPO_DIR`, default `$HOME/SoCLabs/ptp-hardware-clock-ahb`). Run
`make -C fpga farm_check` before trusting a farm host.

:::{note}
**Two parameters on the `-all` Z2 targets are env-gated and OFF by default.**
`fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:435,451` only apply
`CONFIG.TRAIN_ENTRY_FALLBACK {1'b1}` and `CONFIG.EPOCH_ANCHOR_EN {1'b1}` when
`TL_TRAIN_ENTRY_FALLBACK=1` / `TL_EPOCH_ANCHOR_EN=1` are exported. A plain
build of those targets has **both off** — which matters for the all-zeros
failure mode below. Note also that `EXTREFCLK=1` / `EPOCH_ANCHOR=1` are **not**
forwarded by `build_farm.sh`, so those variants need a direct
`make -C fpga build_design` (`fpga/Makefile:497-498`).

See [Parameters](parameters.md) for what each knob does.
:::

### A2. Verify the build before it touches a board

```sh
bash fpga/scripts/verify_build.sh --targets "pynq-z2-pair-all pynq-z2-pair-flip-all"
```

This is the post-build provenance gate. It checks the **V2 banner** in the
newest `package_ip` log, that the generated `Wlink.v` and
`axi_chiplet_controller.sv` carry the expected V2 defines and autonomy signals,
that every target's `.bit` exists and is newer than the run start, that no two
targets share an md5 (identical = one half was not rebuilt), that no `.bin` is
older than its `.bit`, that no XDC constraint was silently dropped, that no
non-benign sequential element was pruned in out-of-context synthesis, and that
routed **WNS ≥ 0**. Exit 0 = all checks pass.

### A3. Convert, sign and stage

```sh
python3 fpga/scripts/bit2bin.py \
    imp/fpga/output/pynq-z2-pair-all/tidelink.bit \
    imp/fpga/output/pynq-z2-pair-all/tidelink.bin
python3 fpga/scripts/bit2bin.py \
    imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit \
    imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin

bash pynq_host/scripts/make_bitstream_manifest.sh \
    imp/fpga/output/pynq-z2-pair-all/tidelink.bin \
    --label "vNN-<desc>" --commit "$(git rev-parse --short HEAD)" \
    --target pynq-z2-pair-all --lock-min 8
bash pynq_host/scripts/make_bitstream_manifest.sh \
    imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin \
    --label "vNN-<desc>" --commit "$(git rev-parse --short HEAD)" \
    --target pynq-z2-pair-flip-all --lock-min 8
```

Stage to `mapstone-dev` with a tar-over-ssh pipe into a **persistent**
`~/tidelink_artefacts/vNN/` — the directory must contain `tidelink.bin`,
`tidelink.hwh`, `tidelink-flip.bin`, `tidelink-flip.hwh` and both manifests.
See [Boards](boards.md) for the pipe and the "`.hwh` is not optional" rule.

### A4. Take the rig and POR

Acquire the lease as its **own** command, then power-cycle. Use a hub or
physical power-cycle, not `fpgahub board reset --method jtag` — see
[Boards](boards.md).

### A5. Deploy

Run **on `mapstone-dev`**, one board at a time:

```sh
bash ~/SoCLabs/tidelink/pynq_host/scripts/deploy_pair.sh \
    192.168.4.101 z2_die_a die_a ~/tidelink_artefacts/vNN \
    --manifest ~/tidelink_artefacts/vNN/tidelink.bin.manifest.json

bash ~/SoCLabs/tidelink/pynq_host/scripts/deploy_pair.sh \
    192.168.2.101 z2_die_b die_b ~/tidelink_artefacts/vNN \
    --manifest ~/tidelink_artefacts/vNN/tidelink-flip.bin.manifest.json
```

Arguments are `<BOARD_IP> <LABEL> <die_a|die_b> <ARTEFACT_DIR>`. The role
selects the bitstream (`die_b` → `tidelink-flip.bin`) and the strap/ctrl pokes.
Use the **current** die_b address — see the pairing warning in
[Boards](boards.md).

What it does, in order, so you can tell where a failure happened:

1. scp `tidelink[-flip].bin` to the board's `/tmp/`
2. scp `tidelink[-flip].hwh` — **fails here if the `.hwh` is missing**
3. copy to `/lib/firmware` and echo the name into
   `/sys/class/fpga_manager/fpga0/firmware`
4. out-of-band re-read of `fpga_manager/state` — must be `operating`
5. post-load APB pokes: `PHY_CTRL`, `PAIR_BASE_ADDR = 0x44032000`, `ROLE_CFG`
   (`0x2` die_a / `0x3` die_b, lock bit set)

Success looks like:

```text
==== z2_die_a @ 192.168.4.101 — role=die_a strap=0 ctrl=0x2 bitstream=tidelink.bin ====
  fpga_manager: operating
  PHY_CTRL       = 0x00000000 (swi_phase_offset=0)
  PAIR_BASE_ADDR = 0x44032000
  ROLE_CFG       = 0x02 (lock=1, cfg=0)
==== z2_die_a done (sha256=… label=vNN-…) ====
```

:::{note}
On images with POR autonomy (`NEGO_CFG_RESET = 0x61`) the dies start
arbitrating over I²C the moment they are flashed, so the `ROLE_CFG` read-back
may show the **arbitrated** role rather than the one the script wrote. Boot
order beats strap under skew. This is documented behaviour, not a deploy
failure (`docs/BOARD_DEPLOY_RUNBOOK.md` §4).
:::

### A6. Bring the link up

Deploy alone gets you two configured dies. The **link** needs the converge
loop, which re-deploys both boards per iteration (re-rolling the word-counter
skew lottery), polls lane lock and `cal_done`, and runs `sync_bootstrap` on a
16/16:

```sh
# on mapstone-dev
MASTER_IP=192.168.4.101 SLAVE_IP=192.168.2.101 \
ARTEFACTS=~/tidelink_artefacts/vNN \
DEPLOY_PAIR_NOVERIFY=1 \
MAX_RETRIES=12 SETTLE=2 BESTOF=3 \
bash ~/SoCLabs/tidelink/pynq_host/scripts/bringup_pair_converge.sh
```

Success ends with:

```text
RESULT: CAL CONVERGED — full 16/16 bidirectional cal+lock at iteration 1
  die_a FCSM=4  die_b FCSM=4
  LINK_IDLE (state 4) BILATERAL — FCSM handshake complete.
```

Convergence is usually iteration 1–2 but is a genuine marginal-eye lottery. A
run that ends `FCSM not yet at LINK_IDLE` is not a deploy failure — re-run.

:::{danger}
Two traps, both of which have cost whole runs:

- **`DEPLOY_PAIR_NOVERIFY=1` is an environment variable.** Passing
  `--no-verify` as an *argument* to the converge script does nothing; every
  per-iteration deploy then aborts with `rc=5` and all `MAX_RETRIES` are burned.
  (If manifests exist beside the bins, neither is needed — it auto-uses them.)
- **The default `SLAVE_IP` is the wrong board.** Pass `MASTER_IP`/`SLAVE_IP`
  explicitly. See [Boards](boards.md).
:::

### A7. Verify link-up — what good looks like

```sh
bash ~/SoCLabs/tidelink/pynq_host/scripts/wlink_probe.sh 192.168.4.101
```

Known-good values for a V2, zero-poke-era image with the reduced lane mask
`0xE4` (`docs/TESTING.md` §5 — measured, not aspirational):

| Register | Address | Known-good | Meaning |
|---|---|---|---|
| `NEGO_CFG` | `0x4403_2090` | `0x61` | `nego_en` + `force_lock` + `mask_hs_auto_en` |
| `NEGO_TRAIN_CFG` | `0x4403_210C` | `0x0001` | `train_auto_en` — write nothing else |
| `ROLE_STATUS` | `0x4403_2084` | bit 1 = 1 on both | `role_locked` (W1S, POR-only clear) |
| `SWI_TRAINING_MODE` (R8) | `0x4403_2100` | `0x1D` in SYNC → `0x15` in data mode (autonomous path) | `[0]` train `[1]` recal `[2]` insert `[3]` force `[4]` robust |
| `SYNCTOL` | `0x4403_2128` | `0x0000_05E4` | tol 5, lane mask `0xE4` |
| `LANEMASK` | `0x4403_0214` | `0x0000_E4E4` | rx/tx lane mask |
| lock threshold | `0x4403_2160` | `0x5555_5555` | per-lane Hamming threshold 5 |
| `SWI_LANE_STATUS` | `0x4403_2108` | `lk ⊇ 0xE4`, `cal=1`, `fcsm=4`, `cr=1`, `crack=1` | `fcsm[19:17]=4` bilateral = link data |
| `OBSCAL cstate` | `0x4403_2198` | `[3:0] = 4` | training exit walks 6 → 4 |
| `sync_seen` | `0x4403_215C` | `[7:0]=0xE4`, marker `0x5F` | all four active lanes armed |
| `SWI_EPOCH_STATUS` | `0x4403_2140` | bit 0 = 1 | deskew anchor engaged |
| `WINSCAN_OBS` | `0x4403_21B8` | `0x570000n1` | `[0]` done, `[1]` degenerate=0, `[2]` anchor-timeout=0, `[7:4]` abort count |
| `OBS_FC_CREDIT` | `0x4403_219C` | marker `0xFC`, `credit_max ≈ 0x1F`, ≠ 0 | **read credit by value** |
| `FCCTRL` | `0x4403_0208` | `0x0002_7F07` | after the bootstrap walk `0x27F09 → 0x27F01 → 0x27F07` |
| RX slices (force-SYNC) | `0x4403_212C`–`38` | L2 `0x5B4C`, L5 `0xB5A6`, L6 `0xD3C4`, L7 `0xF1E2` | byte-exact ⇒ the eye/PHY is good |

:::{warning}
**`fcsm = 4` on both dies is not proof the link works.** Every APB-reachable
status register reads identical on a healthy link and a wedged one — see the
measured table in [Hardware Tests](hardware_tests.md), "Interpreting a failure".
The only trustworthy liveness check is moving uniquely-tagged data and reading
it back byte-exact. Also: `lane_locked` dropping to 0 after `swi_training_mode`
clears is **expected**, not a fault, and `0x4403_20D4` (`RXW`) is the FC-replay
pointer, **not** delivered application data.
:::

### A8. First data crossing

Committed A→B data lands in the **GP1 RX aperture at `0x8401_0000`**, and the
test packet the milestone confirmed is header `0x00240000` followed by
`0xcafe0001`, `0xcafe0002` (`docs/TESTING.md` §5,
`fpga/hw_regression/README.md`).

```sh
# on a host that can reach the pair (e.g. mapstone-dev)
cd fpga/hw_regression && ./td_v2_regress.sh
# or stage + run from the repo:
fpga/hw_regression/stage_and_run.sh mapstone-dev
```

`td_v2_regress.sh` runs the real datapath once and asserts each stage:

| # | Test | Asserts |
|---|---|---|
| 01 | `link_up` | both dies reach `fcsm=4` (bilateral) |
| 02 | `phy_rx_clean` | die_b's post-deskew RAWWORD (`0x212C/30/34/38`) equals the golden per-lane SYNC slice, byte-exact |
| 03 | `deskew_align` | `reanchored` (`0x4403_2140[0]`) = 1 **and** `sync_seen_vec` (`0x4403_215C`) = `0xE4` |
| 04 | `data_a2b` | after `txburst`, the GP1 RX aperture equals the sent header + payload |

Flags: `--no-deploy` (faster, but a stale GP1 FIFO can false-PASS test 04 —
deploy for a trustworthy run), `--no-lease`, `--keep`, `--rolls N` (bring-up POR
retries, default 6).

:::{caution}
**The GP1 RX aperture pops on read** — each read consumes one FIFO word. Read
every word exactly once; do not dump and then re-assert the same word. And
`tl39.py rd` needs a **hex** address string (`0x84010000`), not a bash-arithmetic
decimal.
:::

### A9. Run the test suite

```sh
MASTER_IP=192.168.4.101 SLAVE_IP=192.168.2.101 \
    ./pynq_host/scripts/hwtest/run_all.sh
```

See [Hardware Tests](hardware_tests.md) for the categories, the AHB_TX gate and
the exit codes.

## Lane B: KR260

### B1. Build

```sh
source ./set_env.sh
export TIDELINK_PHY_V2=1

make -C fpga all TARGET=kr260-pair-nptp
make -C fpga all TARGET=kr260-pair-flip-nptp
# or:  make -C fpga build_pair_concurrent PAIR_SOC=kr260 PAIR_PTP=0

bash fpga/scripts/verify_build.sh --targets "kr260-pair-nptp"
```

`PAIR_SOC=kr260 PAIR_PTP=1` selects `kr260-pair-ptp` / `kr260-pair-flip-ptp`
instead (`fpga/Makefile:499-513`). For the single-board vehicle, build
`TARGET=kr260-pair-onchip`.

:::{note}
The on-disk KR260 bitstreams are frequently stale — the first-session runbook
opens by insisting on a rebuild
(`docs/KR260_FIRST_SESSION_RUNBOOK.md` §0). Do not co-run a Vivado build and a
bench session on the same host (OOM).
:::

### B2. Deploy

```sh
make -C fpga deploy_pair_role SOC=kr260 PTP=0 ROLE=die_a KR260_PASSWORD=…   # -> die_a
make -C fpga deploy_pair_role SOC=kr260 PTP=0 ROLE=die_b KR260_PASSWORD=…   # -> die_b
```

This converts `.bit` → `.bin` with `bit2bin_zynqmp.py` (header-strip only,
**never** byte-swap), scp's it, runs `fpgautil -b … -f Full`, verifies
`fpga_manager state = operating`, **then runs `kr260_afi.sh fix` automatically**
and prints the canaries. Board addresses come from `fpga/site.local.mk`, or pass
`KR260_HOST=<user@ip>` explicitly. `make -C fpga deploy_kr260_both PTP=0` does
both dies; `make -C fpga deploy_kr260 TARGET=… KR260_HOST=…` does one.

Power-cycle → deploy **both** → then bring up.

### B3. AFI canaries — the first read on every board, every boot

```sh
sudo devmem 0xFF419000        # LPD/control AFI — [9:8] must read 0
sudo devmem 0xFD615000        # FPD/data  AFI  — [9:8] must read 0
sudo devmem 0x84030204        # MUST read 0x00000001  (hardwired const)
sudo devmem 0x84030214        # MUST read 0x0000e4e4  (lane mask)
```

:::{danger}
**If `0x8403_0204 != 1` or `0x8403_0214 != 0xE4E4`, STOP.** The AFI is wrong and
every other reading is a lie. Fix it with
`sudo sh pynq_host/scripts/kr260_afi.sh fix` (or
`make -C fpga kr260_afi_fix PYNQ_HOST=ubuntu@<ip>`) and re-check. Do not debug
anything else first. Full detail: [Boards](boards.md) and
`docs/KR260_AFI_CHECK.md`.
:::

### B4. Bring the link up — the certified harness

```sh
cd fpga/hw_regression
TIDELINK_SOC=kr260 MASTER=<die_a ip> SLAVE=<die_b ip> \
    ./td_v2_channels.sh --channels "data doorbell"
```

This encodes the whole recipe and is the certified path. If you hand-drive
instead, the constants are in `fpga/hw_regression/td_v2_channels.sh:278-281`:

```text
R8_SYNC = 0x1C     R8_RECAL = 0x1E     R8_DATA = 0x10
FC_TRIPLET = 0x00027f09  0x00027f01  0x00027f07
NEGO_ARM   = 0x61
```

Sequence (APB base `0x8403_0000`, `R8 = 0x8403_2100`,
`FC/LL bootstrap = 0x8403_0208`):

1. write `0x1C` to R8 on **both** dies (bit 0 clear — the training-mode escape)
2. master pulses `0x1E` while the slave holds `0x1C`; sleep 0.03; both back to
   `0x1C`
3. write the FC/LL bootstrap triplet `0x00027f09`, `0x00027f01`, `0x00027f07`
   to `0x8403_0208` on both dies — this is what `HARDEN_SWI_ENABLE=0` unblocks
   (bit 3, `swreset`, now lands)
4. data-mode entry: write `0x10` to R8 on both; sleep 0.5

:::{warning}
**Issue the triplet regardless of the `fcsm` reading.** `gate_link`
historically aborts on `fcsm != 4` *before* the triplet runs, which is the wrong
order when the triplet is what unsticks the master
(`docs/KR260_FIRST_SESSION_RUNBOOK.md` §3).
:::

### B5. First data crossing

:::{danger}
**The KR260 TX aperture has NO hardware backpressure.** An AHB write issued when
the peer RX FIFO has no room does **not** bus-error and does **not** time out —
it hangs the PS bus and hard-wedges the board (JTAG POR only). Firmware **must**
gate every write on available credit
(`pynq_host/scripts/kr260_credit_tx.py:3-10`).

The software flow-control contract:

| Register | Address (die_a) | Use |
|---|---|---|
| `PAIR_CREDIT_COUNTER_EN` | `0x8403_2030` | set to 1 to enable pair-credit tracking |
| `PAIR_CREDIT_COUNTER` | `0x8403_2028` | peer's available credit — **read before every send** |
| `PAIR_CREDIT_CONSUME` | `0x8403_202C` | after sending `len+2` words, write that delta |
| `RELEASED_CREDITS_ACC` | `0x8403_2020` | raw released-credit accumulator |
:::

**Read the RX FIFO strided, never at a fixed offset.** It is a streaming FIFO:
packet *k*'s payload lands at `ahb_fifo + 0x10*k + 8`. A fixed-offset reader
sees only packet 0 and reports every later packet as dropped — a multi-day
phantom "intermittent delivery / lottery" that was purely a receiver artefact.
Corrected on hardware 2026-07-22; measured with the correct reader, delivery was
**12/12 byte-exact, in order**
(`pynq_host/scripts/kr260_data_rx.py:4-14`).

```sh
# on the board, as root
python3 kr260_data_rx.py dump 16
python3 kr260_data_rx.py check 0xda7a0001,0xda7a0002,…
```

**Pass = byte-exact payload on the receiver, in both directions, over a burst of
at least 12 packets** — not a one-shot. Confirm the data aperture base first;
see the KR260 aperture warning in [Boards](boards.md).

### B6. On-chip (single-board) variant

```sh
# on the board, as root
sudo python3 pynq_host/scripts/kr260_onchip_smoke.py       # plumbing only
sudo python3 pynq_host/scripts/kr260_onchip_autonomy.py    # the autonomy proof
sudo python3 pynq_host/scripts/kr260_onchip_soak.py smoke1 # one packet A->B
sudo python3 pynq_host/scripts/kr260_onchip_soak.py soak 500
```

`kr260_onchip_smoke.py` proves only that a real two-instance image is loaded
(both APB apertures respond, straps read opposite) — it says nothing about
link-up, eye, autoneg or data. `kr260_onchip_soak.py` is credit-gated end to
end: it sets die_b's `RELEASE_THRESHOLD = 0` so the credit loop recycles (the
POR default of 20 starves small drains) and stalls the sender rather than ever
blind-writing.

Session exit criteria (`docs/KR260_FIRST_SESSION_RUNBOOK.md`): AFI canaries pass
on both boards; the link reaches data mode; **byte-exact data crosses both
directions over a ≥12-packet burst**; and, for the on-chip leg, bring-up is
reliable across ≥8 fresh attempts. Record the bitstream md5 and the raw register
dumps.

## Troubleshooting decision tree

### Nothing loads at all

| Symptom | Platform | Cause | Fix |
|---|---|---|---|
| Every PL load fails with `ENOMEM`; `CmaTotal: 0 kB` | KR260 | stock `cma=1000M` fails silently on these SOMs | set `cma=512M` in `/etc/default/flash-kernel`, `sudo flash-kernel`, apply with `kexec` — **never** `sudo reboot` |
| `DEPLOY-FAIL: scp .hwh … GIVING UP`, then `board NOT in 'operating' state` | Z2 | the artefact directory is missing `tidelink[-flip].hwh` | stage the `.hwh` from `imp/fpga/output/<target>/` |
| `DEPLOY-ABORT: UNVERIFIED DEPLOY` (exit 5) | Z2 | neither `--manifest` nor `--no-verify` given | pass one; prefer manifests |
| `DEPLOY-ABORT: staged sha256 mismatch vs manifest` | Z2 | stale or wrong `.bin` in the artefact directory | re-run `bit2bin` + manifest from the intended build; never reuse `/tmp` staging |
| Deploys "succeed" but you are flashing over someone's session | both | lease held by another principal (yours is queued) | `fpgahub status` first; coordinate |
| PL loads but the design behaves wrong | KR260 | the `.bin` was byte-swapped | re-convert with `bit2bin_zynqmp.py` |

### Board unreachable / PS wedge

| Symptom | Cause | Recovery |
|---|---|---|
| Board SSH dead, `/dev/mem` gives `Bus error` (Z2) | PS hard-wedge — a blocked AHB write deadlocked the PS AXI (pre-`4c0a51a` images) | JTAG: `xsdb` on mapstone-dev → `connect -url tcp:localhost:3121` → `targets -set -filter {jtag_cable_name =~ "*Z2_02*" && name =~ "APU*"}` → `rst -system`; wait ~45 s, redeploy. Images carrying the fc_adapter stall-timeout (≥ `4c0a51a`) degrade to a bus error instead, which a reflash clears |
| KR260 unresponsive after a `reboot` | `sudo reboot` wedges these boards | `~/bin/kpor kr260-01 --wait` on `mapstone-dev` |
| KR260 PS hangs the instant you touch an address | an undecoded ZynqMP aperture (no bus timeout), e.g. an unrelocated Z2 literal or the wrong data base | power-cycle / JTAG POR; then fix the address map — see [Boards](boards.md) |
| PS wedges under sustained cross-die writes | ungated `ahb_tx` writes outrunning credit | gate every write on `PAIR_CREDIT_COUNTER`; use `kr260_credit_tx.py` / `kr260_onchip_soak.py` |
| PL reads bus-error right after a reboot | the PL is simply unprogrammed | deploy — not a fault |

### The link never trains

Work down this list in order.

1. **Is the instrument right?** Correct board IPs, correct aperture bases for
   the bitstream generation, AFI canaries passing on KR260. A "dead link" that
   is really the spare `z2_03` reads flat zeros forever.
2. **Did `role_lock` actually latch?** `ROLE_STATUS` (`0x4403_2084`) bit 1 must
   be 1 on both dies. `role_lock` is W1S with POR-only clear, so a retry needs a
   real POR — a redeploy without one does not clear it. Until `role_lock` sets,
   `wlink_por_reset` holds the whole Wlink in reset, so nothing downstream can
   train.
3. **Is the mask-handshake gate open?** `role_lock` only latches when
   `mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i`
   (`axi_chiplet_controller.sv:711` — `apb_debug_unlock_i` was **removed** from
   that OR on 2026-07-24; documentation repeating the three-term form is
   stale). On FPGA builds the wrapper's `HONEST_MASK_HS = 1'b0` ties
   `mask_hs_bypass_i` to `1'b1` (`tidelink_top.sv:2512`), which is what forces
   the gate open — and `DEBUG_UNLOCK_DEFAULT = 1'b1` separately discards the
   `apb_debug_unlock_i` pin, which is why the BD's 0-strap is decorative. See
   [Parameters](parameters.md). If you set `HONEST_MASK_HS=1` and the die cannot
   reach `mask_hs_match=1`, the gate stays closed, the software role-lock is
   blocked, Wlink stays in reset and the link is **dead by construction**.
4. **NEGO NACK park (dead I²C bus).** If the I²C sideband is dead, negotiation
   NACKs. With `ROLE_FROM_STRAP = 1'b1` (the default) the terminal role and the
   timeout fallback both derive from `role_strap_i`, so a (master, slave) strap
   survives it. At `1'b0` an I²C NACK makes **both** dies slave and autonomy is
   structurally dead. The training-side completion is
   `TRAIN_ENTRY_FALLBACK` (default **OFF**): at 1 the training entry starts from
   the strap so the link can self-start without a peer I²C ACK. On the Z2 `-all`
   targets it is only compiled in when `TL_TRAIN_ENTRY_FALLBACK=1` was exported
   at build time.
5. **Do not add a training-EXIT PARK hook.** The fourth (PARK) hook was
   reverted: on a dead-I²C rig it holds `training_mode = 1` forever waiting for
   a master I²C write that can never arrive, parking the calibrator in `S_HOLD`
   (`cal=0`) and holding the RX framer in reset (`fcsm=1`)
   (`docs/HANDOVER_Z2_PICKUP_2026_07_30.md:29-32`).
6. **Plateau at 12–15/16 lanes across many re-deploys** is the marginal-eye
   signature, not a software regression. 57 re-deploys across three runs never
   reached 16/16 while repeating near-identical lock masks; the converge
   script's own interpretation guide names this shape ("per-lane sub-UI /
   IDELAYE2-tap ceiling"). Reads as a physical condition on the rig — cable
   reseat, connector wear, environmental drift. **Do not re-chase it as an
   `EPOCH_ANCHOR_EN` issue**; it reproduces identically regardless of which
   corrector is selected.
7. **Remember there is no firmware PHY retrain.** `SWI_RECAL` is a measured
   no-op after first lock — `calibrated_once_q` gates both re-trigger edges off
   forever and only a POR clears it. If training is genuinely stuck, POR both
   dies.

### The link says it is up but the data is all zeros

This is the best-understood failure in the project, and it is **not** an eye
problem. The complete chain, every link verified
(`docs/HANDOVER_Z2_PICKUP_2026_07_30.md` §3):

1. `swi_delay_cycles` is forced from `16'h6a4` to `16'h0` (a deliberate fix for
   a real PSTATE deadlock in the training→FC handoff).
2. ⇒ `|io_swi_delay_cycles` is false ⇒ PSTATE never leaves state 0 ⇒
   `io_link_tx_tx_en ≡ 1`.
3. ⇒ `postcount` only decrements when `~tx_en`, and reloads to `8'h7` ⇒
   `postcount ≡ 7`, never 0.
4. ⇒ `tx_sync_en_w = ~por & insert_en & (force_always | (tx_idle & postcount==0))`
   collapses to `insert_en & force_always` ⇒ **the idle-gated SYNC beacon can
   never fire.**
5. ⇒ the shipping deskew corrector (`SYNC_REANCHOR_EN=1`) never arms, because it
   only arms on a live SYNC beacon that the pair bring-up leaves off.
6. ⇒ under real inter-lane skew, words never reassemble ⇒ all zeros.

**The fix is to select the *other* corrector**: `EPOCH_ANCHOR_EN = 1` compiles
the training-EXIT, content-only anchor instead of the beacon re-anchor. It is
proven in simulation
(`make -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=silicon EXTRA_DEFINES="+define+TB_TOP_EPOCH_ANCHOR_EN" MODULE=test_v2_pair_data`
→ `TESTS=3 PASS=3 FAIL=0`, including the `test_03_packet_slave_to_master` case
that fails by default with exactly the all-zeros signature).

**Diagnosis on hardware:**

| Read | Healthy | All-zeros case |
|---|---|---|
| `SWI_EPOCH_STATUS` `0x4403_2140[0]` (`anchored`) | 1 on **both** dies | 0 |
| `0x4403_2114[31:16]` (`sync_detected`) | > 0 | 0 |
| `0x4403_2108` (`fcsm`) | 4 | **also 4** — tells you nothing |

`anchored = 1` on both dies simultaneously is the hardware analogue of the
simulation banner `(deskew: m=1 s=1)` — direct proof the corrector is engaged.

:::{caution}
`EPOCH_ANCHOR_EN` is a **real netlist change** and it is `1'b0` by default
everywhere: `tidelink_top.sv`, the FPGA IP wrapper, and every committed FPGA
target. On the Z2 `-all` targets it is applied only under
`TL_EPOCH_ANCHOR_EN=1`. A `+define+` will **not** reach a packaged IP's
out-of-context synthesis — it has to be an IP-face parameter. Verify
structurally (grep the packaged IP), not by md5. See [Parameters](parameters.md).
:::

:::{note}
**There is no `AUTO_ANCHOR_EN` parameter in this repository.** The TideLink name
for this knob is `EPOCH_ANCHOR_EN`. `AUTO_ANCHOR_EN` is the sibling
eth-chiplet RTL's name for the same thing and appears here only as prose in
`docs/BUILD_REGISTRY.yaml` — see
[Parameters §6.1](parameters.md#61-epoch_anchor_en-and-the-auto_anchor_en-naming-correction).
:::

### Data crosses but drops packets

1. **Prove it is not the reader.** On KR260, read the RX FIFO **strided**
   (`ahb_fifo + 0x10*k + 8`). A fixed-offset reader manufactures a fake
   "intermittent delivery lottery". On Z2, the GP1 RX aperture **pops on read**
   — reading a word twice consumes two entries.
2. **Read the credit by value, not the full flag.** `OBS_FC_CREDIT`
   (`0x4403_219C`) exposes `fe_rx_credit_max` in `[7:0]`. `0x2108[31]`
   (`fe_rx_is_full`) only flags credit **== 0**; a credit garbled to a small
   non-zero passes the send gate and exhausts after one to four packets. That is
   the documented CR-credit-decode failure mode. A `0x00000000` read here means
   an older image without the observability.
3. **Correlate with the lane status.** The rank-1 peer-write data-drop
   investigation found landing correlated with `SWI_LANE_STATUS = 0x27` and
   dropping with `0x05`, and concluded the dominant cause was a **physical
   marginal eye**, not RTL — the logical fix was necessary but not sufficient.
   See [Known Issues](known_issues.md).
4. **Check the a2l replay backlog**, then run a tagged canary — the two-stage
   liveness recipe in
   [Hardware Tests](hardware_tests.md), "Interpreting a failure".
   Re-probe several times: single-lane stuck-1 self-heals after about one retry
   round and all-lane corruption after about three, so a single failed canary is
   not a wedge.
5. **If the FC node has jammed** — `FCSM=5` with `0x2108[30]=1` and
   `0x2108[31]=0`, i.e. an un-ACKed long packet — run
   `pynq_host/scripts/unjam_fc_node.sh <IP>` or do a full re-converge.

### The link wedged and nothing recovers it

Measured recovery, from `docs/LINK_RECOVERY_MECHANISM.md` §2:

| Disturbance | Minimal recovery | Field-recoverable? |
|---|---|---|
| Single-lane stuck-1 | none — self-heals after ~1 retry round | yes |
| All-lane corruption | none — self-heals after ~3 retry rounds | yes |
| **Link-clock dropout** | **POR of BOTH dies** | **no — power cycle** |

The clock-dropout class survived ten firmware-reachable rungs: `SWI_RECAL`,
SYNC beacon bursts at three strengths, a tolerance-opened beacon, link-layer
`swreset` on either and both dies, a full PHY retrain, and a single-die POR.

:::{caution}
Do **not** write a beacon-based recovery routine. The beacon is non-causal for
the classes that recover, and a forced beacon **destroyed a still-working
direction** in one measured case (a W2 master→slave path that was healthy
through three rungs died at the first `SWI_SYNC_FORCE_ALWAYS` burst).
:::

## Related pages

- [Boards](boards.md) — rig inventory, leases, POR, bitstream handling.
- [Hardware Tests](hardware_tests.md) — the numbered suite, its gates and
  failure interpretation.
- [Register Map](register_map.md) — full APB map, including the registers that
  must never be probed.
- [Parameters](parameters.md) — `EPOCH_ANCHOR_EN`, `TRAIN_ENTRY_FALLBACK`,
  `ROLE_FROM_STRAP`, `DEBUG_UNLOCK_DEFAULT`, `HARDEN_SWI_ENABLE`.
- [Verification](verification.md) — the sim gate that must be green first.
- [Known Issues](known_issues.md) — tracked defects and branch divergence.
