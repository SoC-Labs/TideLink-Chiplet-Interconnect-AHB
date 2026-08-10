# Boards

TideLink is validated on two FPGA rigs: a **PYNQ-Z2 pair** joined by a 40-pin
RPi GPIO ribbon, and a **Kria KR260 pair** (which also has a single-board
two-dies-in-one-bitstream variant). They share almost no operating procedure.
This page is the rig reference: who is who, how to take a board, how to reset
one without destroying it, and how to prepare a bitstream that will actually
load.

The procedures that use these boards are in [Bring-Up](bringup.md) and
[Hardware Tests](hardware_tests.md).

:::{danger}
**The four rules that have each cost a real session.**

1. **Never `sudo reboot` a KR260.** It goes down and does not come back over
   the network; recovery is a JTAG power-on-reset only
   (`docs/KR260_BOARD_ENV.md`, "Rebooting — DO NOT `sudo reboot`").
2. **Never reload the PL on a live link.** The peer keeps `role_lock`
   (W1S, POR-only clear) while your die loses it.
3. **Never byte-swap a KR260 `.bin`.** ZynqMP `fpgautil` wants a
   header-stripped payload; the Zynq-7000 byte-swap silently produces a bad PL
   load that behaves wrong rather than failing.
4. **Verify your lease is `granted`, not queued**, before flashing anything.
   A queued lease looks alive and deploys over whoever actually holds the
   boards.
:::

## Where the authoritative board list lives

The repository deliberately keeps **site network topology out of the published
tree**. Board addresses used by the FPGA Makefile come from
`fpga/site.local.mk`, which is gitignored; the committed template is
`fpga/site.local.mk.example`:

```make
# copy to fpga/site.local.mk (gitignored) and fill in for your rig
KR260_DIEA_IP ?= 192.0.2.1
KR260_DIEB_IP ?= 192.0.2.2
FARM_HOST     ?= my-farm-host
```

Without `fpga/site.local.mk`, `make -C fpga deploy_pair_role SOC=kr260 …` has no
default host and you must pass `KR260_HOST=<user@ip>` explicitly
(`fpga/Makefile:758-800`).

The **SoC Labs lab rig** is documented in three committed places, and they do
not fully agree — the most recently verified one wins:

| Source | Covers | Verified |
|---|---|---|
| `docs/KR260_BOARD_ENV.md` | KR260 pair: names, IPs, login, survival rules | current |
| `docs/BOARD_DEPLOY_RUNBOOK.md` §1 | PYNQ-Z2 topology and the only network route | 2026-06-11 |
| `docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md` §11 | **corrected** Z2 pairing + lease CLI | 2026-07-24, live |
| `docs/HANDOVER_Z2_PICKUP_2026_07_30.md` §8 | Z2 rig + traps, POR behaviour | 2026-07-30/31 |
| `fpga/fpgahub.toml` | artefact manifest and per-target `.bin`/`.hwh` paths | — |

## The PYNQ-Z2 rig ("bridge1")

### Topology and the only route in

```text
  your dev box
        │  ssh david@mapstone-dev        ← the ONLY route to the boards
        ▼
  mapstone-dev (10.22.27.178)
        │  ssh xilinx@<board>            (password: xilinx, or $TIDELINK_BOARD_PASS)
        └─ hw_server tcp::3121           FT2232H JTAG to z2_01 … z2_04
```

Your dev box **cannot** reach the per-board `/24` networks. A bare
`ssh xilinx@192.168.4.101` that times out is host routing, not a dead board.
The deploy scripts therefore run **on `mapstone-dev`**, against its own checkout
at `/home/david/SoCLabs/tidelink` and its artefact store at
`/home/david/tidelink_artefacts/` (`docs/BOARD_DEPLOY_RUNBOOK.md` §1).

JTAG on `:3121` is the independent second channel: it survives any SSH or PS
state and is what the `rst -system` rescue uses.

### Which boards are actually on the ribbon

:::{warning}
**This changed, and stale defaults are still in the scripts.**

| Role | Board | IP | Status |
|---|---|---|---|
| die_a / master strap | `z2_02` | `192.168.4.101` | on the ribbon |
| die_b / slave strap | **`z2_01`** | **`192.168.2.101`** | on the ribbon (verified live 2026-07-24) |
| — | `z2_03` | `192.168.6.101` | **spare, NOT on the ribbon** |

`192.168.6.101` (`z2_03`) is still the built-in default in
`pynq_host/scripts/hwtest/lib/lib_hwtest.sh:74` and in
`bringup_pair_converge.sh`. A run against it trains die_a normally while "die_b"
reads flat zeros the whole time — indistinguishable from a dead link, and it has
burned sessions twice. **Always pass `MASTER_IP` / `SLAVE_IP` (or the script's
board arguments) explicitly.**

Sources: `docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md:320-321`,
`docs/HANDOVER_Z2_PICKUP_2026_07_30.md:218-221, 308-310`.
:::

Older documents — `docs/BOARD_DEPLOY_RUNBOOK.md` §1 and
`docs/reference/TIDELINK_BRINGUP_USER_GUIDE.md` — still name `z2_03` as die_b.
They predate the 2026-07-24 verification.

### Board environment

- OS: the PYNQ image; user `xilinx`, password `xilinx` (or
  `$TIDELINK_BOARD_PASS`).
- **`devmem` is NOT installed on the Z2 boards.** Use a *staged* Python `mmap`
  helper — `pynq_host/scripts/unjam_fc_node.sh` is the canonical pattern.
  Triple-nested shell quoting of an inline `python3 -c` through two `ssh` hops
  plus `sudo` **will** silently mangle
  (`docs/BOARD_DEPLOY_RUNBOOK.md` §6).
- Board `/tmp` is cleared on reboot, so staged helpers vanish; the scripts
  re-stage them.
- The boards **hard-hang when idle**: `z2_02` was found dead (hub port on, no
  route) after a week idle and needed a hub power-cycle
  (`docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md:329-331`).

### Preserved golden bitstreams

A known-good pair is preserved on `mapstone-dev` at
`~/tidelink_artefacts/golden-z2-20260717/` — `tidelink.bin` (die_a),
`tidelink-flip.bin` (die_b), the two `.hwh`, a `SHA256SUMS` and a README. They
are **not** the same build as anything in `/tmp/tidelink_deploy`; always deploy
golden from the preserved directory with `--expect-sha256`
(`docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md:333-338`).

## The KR260 rig

| Name | Role | PS IP | Login |
|---|---|---|---|
| `kr260_01` | die_a | `10.22.24.159` | `ubuntu` |
| `kr260_02` | die_b (flip) | `10.22.24.153` | `ubuntu` |

Source: `docs/KR260_BOARD_ENV.md`, "Boards"; the same addresses appear in
`fpga/Makefile:1040` (`make -C fpga help`).

**These are not PYNQ boards.** They run plain **Ubuntu 22.04** (the AMD Kria
Ubuntu image) with **no PYNQ framework installed**. Everything the Z2 flow
assumes — `from pynq import Overlay`, the `/lib/firmware` + `fpga_manager`
firmware poke, the `xilinx` user — is wrong here.

There is also a **single-board on-chip variant**, `kr260-pair-onchip`: two dies
in one bitstream on one board, no ribbon. `die_a` APB sits at `0x8403_0000` and
`die_b` at `0x8C03_0000` (a uniform `+0x0800_0000`), with `TIDELINK_PAIR_BASE`
set to `0x8C032000` / `0x84032000` respectively
(`fpga/targets/kr260-pair-onchip/tidelink_design.tcl:332-367`). Because it
removes the ribbon and the pin lottery, it is the lottery-free vehicle and the
one the consolidation branch's `hwtest_gate.sh` targets.

### KR260 survival rules

Every one of these is a trap the project has already hit
(`docs/KR260_BOARD_ENV.md`):

**`cma=512M` or nothing loads.** The stock image boots with `cma=1000M`, which
fails *silently* on these SOMs → `CmaTotal: 0 kB` in `/proc/meminfo` → the
`fpga_manager` driver cannot allocate the DMA buffer → **every** PL load fails
with `ENOMEM`. This is the first thing to check on a board that "won't take any
bitstream". Fix: set `cma=512M` in `/etc/default/flash-kernel`, run
`sudo flash-kernel`, then apply it with `kexec` (below). Verify with
`cat /proc/meminfo | grep -i cma`.

**Stage SSH keys.** `ssh-copy-id ubuntu@10.22.24.159` (and `.153`). Password
prompts break `sudo -S` in the deploy plumbing.

**Load the PL with `fpgautil`, not PYNQ:**

```sh
sudo fpgautil -b tidelink.bin -f Full
cat /sys/class/fpga_manager/fpga0/state       # must read: operating
```

The `fpga/Makefile` `deploy` recipe now routes `kr260-%` targets through
`DEPLOY_STYLE=fpgautil` → `pynq_host/scripts/kr260_deploy.sh`, which does this
for you (`fpga/Makefile:803-812`). The older `pynq_overlay` branch is retained
only for a hypothetical PYNQ-imaged ZynqMP board and no current target selects
it.

**Re-poke the AFI PS-master-port widths after every PL load and every boot.**
See below — this is not optional.

## The AFI width re-poke (KR260 only)

Because the design's `psu_init` never runs on Kria, the stock SOM firmware owns
the AFI PS-master-port data widths. The block design drives both ports —
`HPM0_LPD` (control) and `HPM0_FPD` (data) — at 32-bit; if the firmware left
either wider, misaligned 32-bit AXI accesses read 0 and drop writes, and roughly
three quarters of the control plane silently dies.

```sh
# turnkey, idempotent — on the board, immediately after fpgautil,
# before any AXI traffic
sudo sh pynq_host/scripts/kr260_afi.sh fix

# or from the dev host
make -C fpga kr260_afi_fix PYNQ_HOST=ubuntu@10.22.24.159
```

Manual check (`docs/KR260_AFI_CHECK.md` §1–2): bits `[9:8]` of `0xFF419000`
(LPD/control) and `0xFD615000` (FPD/data) must read `00`; if not, write back
`val & ~0x300`, leaving `[11:10]` (HPM1) untouched.

**The canaries — run these first, on every board, every boot:**

| Canary | Expected | Meaning |
|---|---|---|
| `0x8403_0204` | `0x00000001` | role register reads through the control plane |
| `0x8403_0214` | `0x0000E4E4` | lane-mask register reads through the control plane |
| `0x8405_0008` write 40 → read | `0x28` | data plane accepts a 32-bit write + read-back |
| `0x8403_0200` | `0x00000088` | **negative control** — hardwired, decodes even with the AFI wrong |

:::{warning}
If `0x8403_0204 != 1` or `0x8403_0214 != 0xE4E4`, **STOP — the AFI is wrong and
every other reading is a lie.** Do not debug anything else until they read
correctly (`docs/KR260_FIRST_SESSION_RUNBOOK.md` §2). If the widths read `00`
but the canaries still fail, the AFI was not the (only) cause — escalate to the
BD/SmartConnect trace rather than poking `afi_fs` again.

The fix **does not persist**: the firmware reprograms `afi_fs` on every boot and
it must be re-poked after every PL load. `make -C fpga deploy` runs it
automatically; a manual `fpgautil` load does not.
:::

## Lease and contention protocol

The lab uses **fpgahub** to arbitrate the shared boards. The single
non-negotiable rule is that a lease must be **granted, not queued** — fpgahub
queues your request when someone else holds the boards, and a queued lease looks
alive but deploys against the holder's session
(`docs/BOARD_DEPLOY_RUNBOOK.md` §2.1, §7.5).

```sh
fpgahub status          # both board rows must show YOUR lease
```

:::{warning}
**The lease CLI changed and the repository has not fully caught up.**

`docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md:325-327` records, from a live session,
that the pair-scoped form no longer exists and leases are now **per board
group**:

```sh
fpgahub board lease acquire pynq_z2_02 --ttl <s>      # and pynq_z2_01
fpgahub board lease heartbeat <board> --token <tok>
fpgahub board lease release   <board> --token <tok>
```

The token is printed **once**, by `acquire`.

Meanwhile `pynq_host/scripts/hwtest/run_all.sh:74,83` still shells out to
`/opt/fpgahub/bin/fpgahub pair lease acquire bridge1 …` /
`pair lease release bridge1`, and `docs/TESTING.md` §3.5 and `README.md:47`
still document the pair form. **Which form your installed fpgahub accepts is
site-dependent and not verifiable from this repository** — check with
`fpgahub --help` before relying on `HWTEST_ACQUIRE_LEASE=1`, and acquire the
lease yourself if the pair form is gone.
:::

**Etiquette, from `docs/TESTING.md` §3.5 and the runbooks:**

- Run `show`/`status` **first**, then `acquire` as its **own** command — never
  chain a lease acquisition with board operations in one shell invocation.
- Verify the answer says *granted*.
- Release when idle; never leave a keepalive running.
- The `fpga/hw_regression/` scripts take and release the lease themselves unless
  given `--no-lease`.
- Do not deploy over a live investigation. If another session holds the boards,
  coordinate.

:::{caution}
Restarting `fpgahubd` (for example to load a config change) **drops every active
lease fleet-wide**. Check that nobody is mid-deploy anywhere before doing it
(`docs/HANDOVER_Z2_PICKUP_2026_07_30.md:191-194`).
:::

## Power-cycle and POR

A power-on reset is required before every deploy — `role_lock` is W1S with
POR-only clear, so a role change or a retry needs the part to actually come out
of reset.

### PYNQ-Z2

| Method | Command | Reliability |
|---|---|---|
| **Hub power-cycle** | `fpgahub hub power-cycle <NAME>` (see caveat) or a physical cycle | **Reliable** — recovered both boards every time it was tried, within ~15–45 s |
| JTAG SLCR reset | `fpgahub board reset pynq_z2_0{1,2} --method jtag` | **Unreliable** — twice left both boards unresponsive to ARP for 2+ minutes after reporting success |
| UART reboot | `fpgahub board reset … --method uart` | Documented fallback; **did not recover** the board once when tried |
| JTAG `rst -system` rescue | `xsdb` on mapstone-dev → `connect -url tcp:localhost:3121` → `targets -set -filter {jtag_cable_name =~ "*Z2_02*" && name =~ "APU*"}` → `rst -system`, wait ~45 s | The rescue for a PS hard-wedge |

Source: `docs/HANDOVER_Z2_PICKUP_2026_07_30.md` §6.2 and §8,
`docs/BOARD_DEPLOY_RUNBOOK.md` §7.6.

:::{warning}
**Treat power-cycle, not `--method jtag`, as the reliable POR for the Z2 rig**
until the JTAG behaviour is separately understood. If you do use JTAG and a
board has not returned within ~30–45 s, go straight to a power-cycle rather than
waiting longer or trying `--method uart`.

`fpgahub hub power-cycle <NAME>` exists, but **its `NAME` argument scoping
(whole-hub vs specific port) was not established with confidence** during the
2026-07-30/31 session, and a wrong guess risks cutting power to unrelated boards
on the same switch. Resolve that before scripting it. Known hub entries:
`pynq_z2_02_ps` (rshtech port 3), `pynq_z2_01_pl` (rshtech port 2),
`pynq_z2_03_ps` (z2_fanout port 1).

Note also that `--method default` can silently resolve to an *unrelated
project's* manifest action if one happens to be bound to that board; check
`fpgahub manifest show <target>` if a reset fails with an unexpected
secret or error.
:::

### KR260

| Situation | Do this | Do NOT |
|---|---|---|
| Board wedged / no SSH | `~/bin/kpor kr260-01 --wait` (or `kr260-02`) **on `mapstone-dev`** | `sudo reboot` |
| Apply a **new** kernel cmdline (e.g. the `cma=512M` change) | `sudo kexec -l /boot/vmlinuz --initrd=/boot/initrd.img --dtb=<board.dtb> --command-line="<current cmdline with cma=512M>"` then `sudo kexec -e` (~66 s, no cold reset) | `kreboot` — it reuses the old cmdline |
| Ordinary reboot with an unchanged cmdline | `kreboot` | `sudo reboot` |
| Clean power removal | `sudo poweroff` or a real power-cycle — both fine | — |

Read the *current* cmdline from `/proc/cmdline` and edit only the `cma=` token,
so `root=`, `console=` etc. stay intact.

:::{danger}
**`sudo reboot` wedges a KR260.** It does not come back on the network and the
only recovery is a JTAG power-on-reset. The `kpor` tool lives on
`mapstone-dev`, not on `farm-host-b`. Do not issue a plain `reboot` unless
someone is positioned to JTAG-POR the board
(`docs/KR260_BOARD_ENV.md`, "Rebooting").
:::

## Bitstream handling

### `.bit` → `.bin` is platform-specific, and getting it wrong is silent

| Platform | Converter | What it does | Loader |
|---|---|---|---|
| Zynq-7000 (PYNQ-Z2) | `python3 fpga/scripts/bit2bin.py <in>.bit <out>.bin` | strips the header **and byte-swaps** for the `zynq-fpga` driver | `/lib/firmware` + `/sys/class/fpga_manager/fpga0/firmware` |
| ZynqMP (KR260) | `python3 fpga/scripts/bit2bin_zynqmp.py <in>.bit <out>.bin` | strips the 127-byte header **only — never byte-swap** | `sudo fpgautil -b <bin> -f Full` |

The `fpga/Makefile` `$(BITBIN)` rule picks the converter automatically from a
`kr260-%` filter on `TARGET` (`fpga/Makefile:638-648`), so
`make -C fpga deploy TARGET=kr260-…` always gets the right one. If you convert by
hand, pick deliberately.

:::{warning}
Feeding a KR260 a **byte-swapped** `.bin` produces a PL that *loads* and then
behaves wrong — there is no error. This is why the KR260 artefacts in
`fpga/fpgahub.toml` deliberately ship **no `.bin`**, and why the two `.bin`
flavours are never interchangeable
(`docs/KR260_BOARD_ENV.md`, "Loading a bitstream"; `fpga/fpgahub.toml` KR260
artefact block).
:::

### Stale `.bin` is the classic trap

The farm build flow **stops at `.bit`**. Stale `.bin` files from earlier builds
may still be sitting in the output directories, and boards flash the `.bin`, not
the `.bit` — so a rebuilt `.bit` with a stale `.bin` deploys yesterday's image.
Always regenerate the `.bin` and compare `sha256`/`md5` against the previous
version (`docs/BOARD_DEPLOY_RUNBOOK.md` §3, `docs/TESTING.md` §3.3).
`fpga/scripts/verify_build.sh` check (f) warns on any `tidelink.bin` older than
its `tidelink.bit`.

### The `.hwh` files are not optional (Z2)

A deployable artefact directory needs **all** of:

```text
~/tidelink_artefacts/vNN/
├── tidelink.bin                      # die_a
├── tidelink.hwh                      # die_a hardware handoff  ← REQUIRED
├── tidelink-flip.bin                 # die_b
├── tidelink-flip.hwh                 # die_b hardware handoff  ← REQUIRED
├── tidelink.bin.manifest.json
└── tidelink-flip.bin.manifest.json
```

`deploy_pair.sh` scp's the `.hwh` before flashing and gives up without it —
the failure surfaces as `DEPLOY-FAIL: scp .hwh … GIVING UP` followed by
`board NOT in 'operating' state` (`docs/BOARD_DEPLOY_RUNBOOK.md` §2.3, §7.1).

Use a persistent `~/tidelink_artefacts/vNN/` directory, **not**
`/tmp/tidelink_deploy/` — volatile `/tmp` staging is how a stale bitstream once
got flashed by mistake, which is why the provenance gate exists.

### Provenance manifests

```sh
bash pynq_host/scripts/make_bitstream_manifest.sh <bitstream>.bin \
    --label "vNN-<short-desc>" --commit "$(git rev-parse --short HEAD)" \
    --target pynq-z2-pair-all --lock-min 8
```

`deploy_pair.sh` then refuses to flash on a hash mismatch. The escape hatches
are `--expect-sha256 <hex>`, `--manifest <path>`, `--no-verify` (loud), and
`--check-only` (read back the loaded bitstream's MD5 and compare without
flashing). An unverified deploy aborts with exit 5 by design.

:::{note}
For `bringup_pair_converge.sh` the no-manifest fallback is the **environment
variable** `DEPLOY_PAIR_NOVERIFY=1`. Passing `--no-verify` as an *argument* to
the converge script does nothing, and every per-iteration deploy then aborts
with `rc=5` — 12 iterations were once burned on exactly this
(`docs/BOARD_DEPLOY_RUNBOOK.md` §5, §7.3).
:::

### Staging between hosts

`rsync` and often `scp` **fail between the dev hosts** (protocol
incompatibility). Use a tar-over-ssh pipe, or `cat`-over-ssh for single files:

```sh
tar -C /tmp/stage -cf - . | ssh david@mapstone-dev \
    'mkdir -p ~/tidelink_artefacts/vNN && tar -C ~/tidelink_artefacts/vNN -xf - \
     && sha256sum ~/tidelink_artefacts/vNN/*.bin'
```

Then check the printed hashes against your local `sha256sum`
(`docs/BOARD_DEPLOY_RUNBOOK.md` §3.4, §7.8).

### Boot-time PL reload

On the PYNQ boards, a board reboot leaves the PL **unprogrammed**, so a PL read
right after a reboot is a bus error — not a fault, just deploy
(`docs/BOARD_DEPLOY_RUNBOOK.md` §7.9). Separately, the PYNQ boot machinery can
reprogram the PL with its own base overlay some time after boot, so an image
deployed too early can be silently replaced; deploy *after* the board has
settled and confirm `fpga_manager/state` reads `operating` afterwards.

## Address apertures per platform

The full map is in [Register Map](register_map.md); this is the board-facing
summary of what your host scripts must target.

### PYNQ-Z2 (GP1 control/data split, 2026-06-12 onwards)

| Aperture | Address | PS port |
|---|---|---|
| `ahb_sub` (transparent peer window) | `0x4000_0000` | M_AXI_GP0 — **must stay on GP0** |
| `ahb_ptp` | `0x4402_0000` | GP0 |
| APB (Wlink `0x4403_0xxx`, TideLink `0x4403_2xxx`) | `0x4403_0000` | GP0 |
| role strap GPIO | `0x4404_0000` (bit 0) | GP0 |
| debug-unlock GPIO | `0x4404_1000` (bit 0) | GP0 |
| PHC | `0x4405_0000` | GP0 |
| `ahb_tx` | **`0x8400_0000`** (was `0x4400_0000`) | M_AXI_GP1 |
| `ahb_fifo` (RX FIFO window) | **`0x8401_0000`** (was `0x4401_0000`) | M_AXI_GP1 |

Against a GP1-split image, export
`TIDELINK_TX_BASE=0x84000000 TIDELINK_RXFIFO_BASE=0x84010000`. Host scripts
still default to the old data addresses. A read or write to `0x4400_xxxx` on a
GP1-split image hits an unmapped GP0 hole (DECERR/SIGBUS), and `0x8400_xxxx` on
an old image likewise — **match the bases to the bitstream generation**
(`docs/BOARD_DEPLOY_RUNBOOK.md` §6,
`fpga/targets/kr260-pair-nptp/tidelink_design.tcl:40-61`).

GP0 (control) and GP1 (data) are independent PS7 ordering domains, which is the
point of the split: a wedged `ahb_tx` write on GP1 can no longer stall APB polls
on GP0.

### KR260 (ZynqMP)

The control plane relocates by `+0x4000_0000`; the data plane moves into the
FPD window and is listed explicitly below. The single source of truth for the
relocation is the aperture table in `fpga/hw_regression/td_socmap.sh:31-42`
(and its Python twin `pynq_host/tl_socmap.py`):

| Aperture | Z2 canonical | KR260 | Size |
|---|---|---|---|
| `ahb_sub` | `0x4000_0000` | `0x8000_0000` | 64 MB |
| `ahb_ptp` | `0x4402_0000` | `0x8402_0000` | 4 KB |
| APB | `0x4403_0000` | `0x8403_0000` | 32 KB |
| strap GPIO | `0x4404_0000` | `0x8404_0000` | 4 KB |
| debug-unlock GPIO | `0x4404_1000` | `0x8404_1000` | 4 KB |
| PHC APB | `0x4405_0000` | `0x8405_0000` | 4 KB |
| `ahb_tx` | `0x8400_0000` | **`0xA400_0000`** | 64 KB |
| `ahb_fifo` | `0x8401_0000` | **`0xA401_0000`** | 64 KB |

:::{warning}
**The KR260 data-aperture base is a documented trap, and the repository
contradicts itself.**

- `fpga/targets/kr260-pair-nptp/tidelink_design.tcl:48-61` still describes the
  **Zynq-7000 PS7 GP0/GP1** numbering (`ahb_tx = 0x8400_0000`,
  `ahb_fifo = 0x8401_0000`) even though the actual PS is ZynqMP with
  `M_AXI_HPM0_LPD` on a `0x8000_0000` window and `M_AXI_HPM0_FPD` on a
  `0xA000_0000` window (same file, `:191-192`). That header block is inherited
  text.
- `pynq_host/scripts/kr260_data_rx.py:16-20` states the PS-visible apertures are
  `0xA400_0000` / `0xA401_0000` and that **writing `0x8400_0000` hard-wedges the
  PS**, recoverable only by a JTAG POR.
- `fpga/hw_regression/td_v2_channels.sh:264-275` passes the **Z2-canonical**
  `0x8400_0000` / `0x8401_0000` to `tl39.py`, which performs the *single* remap
  to the KR260 physical address. Exporting `TIDELINK_TX_BASE=0xA4000000` there
  is explicitly rejected with a loud abort, because it would double-remap.

**Rule:** with the `tl39`-based harnesses, hand them **Z2-canonical**
addresses and let `tl_socmap` relocate. With raw `devmem`/`tl_poke.py`, use the
**absolute** KR260 addresses (`0xA400_0000` / `0xA401_0000`). `tl39.py` takes
Z2-canonical addresses and remaps internally while `tl_poke.py` takes absolute
addresses — mixing them silently targets the wrong address
(`docs/KR260_FIRST_SESSION_RUNBOOK.md`, "Recovery / traps").

If in doubt, use the cheap disambiguation the runbook prescribes: the RX FIFO
window is also a local SRAM, so write-then-read one word locally on the slave —
whichever base round-trips is the real one. Do not assume.
:::

:::{danger}
**Undecoded apertures on ZynqMP have no bus timeout.** An unrelocated Z2 control
literal (`0x4403_xxxx`) issued on a KR260 is an undecoded AXI access that hard-
hangs the PS; a power-cycle is the only recovery. This is exactly why
`lib_hwtest.sh` refuses to run when `TIDELINK_SOC` names anything but a Z2, and
why `td_socmap.sh` fails loudly rather than falling back to a default map.
:::

## Tooling staging

`tl39.py` must be staged **mirrored** on the board —
`~/td/scripts/tl39.py` alongside `~/td/tl_socmap.py`. Without the sibling
`tl_socmap.py`, `tl39` exits silently and every read returns 0, which is
indistinguishable from a dead link
(`docs/KR260_FIRST_SESSION_RUNBOOK.md`, "Recovery / traps";
`pynq_host/scripts/tl39.py:48-64`).

## Next

- [Bring-Up](bringup.md) — build, deploy, POR, link-up, first data crossing.
- [Hardware Tests](hardware_tests.md) — the numbered suite and its gates.
- [Known Issues](known_issues.md) — tracked defects and the diverging-branch
  caveat.
