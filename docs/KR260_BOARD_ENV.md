# KR260 board environment — survival guide

The two Kria KR260 boards are **not** PYNQ boards. They run **plain Ubuntu 22.04**
(the AMD Kria Ubuntu image), with **no PYNQ framework installed**. Everything the
Z2 flow assumes about PYNQ (`from pynq import Overlay`, `/lib/firmware` +
`fpga_manager` firmware poke, the `xilinx` user) is wrong here. This page captures
the board-environment knowledge you need to get a bitstream loaded and the control
plane alive, none of which lives anywhere else in the repo.

Related: `docs/KR260_AFI_CHECK.md` (the bench checklist), `fpga/docs/KR260_PORT.md`
(the address map + build targets), `docs/KR260_RECOVERY_PLAN_2026_07_17.md`
(the multi-lane recovery contract).

## Boards

| Name       | Role         | PS IP          | Login    |
|------------|--------------|----------------|----------|
| `kr260_01` | die_a        | `10.22.24.159` | `ubuntu` |
| `kr260_02` | die_b (flip) | `10.22.24.153` | `ubuntu` |

- Auth is **password** by default. Stage SSH keys first — every step below is
  `ssh`/`scp`, and password prompts break the deploy plumbing (`sudo -S` reads
  the password from stdin). Recommended:
  `ssh-copy-id ubuntu@10.22.24.159` (and `.153`), then key-only.
- These are the **plain-Ubuntu** boards. The `fpgautil` load path (below) is the
  real one; the Makefile's PYNQ `Overlay()` deploy branch does **not** work here
  (no pynq). See "Deploy reality" below.

## CmaTotal / cma=512M — WITHOUT THIS, NO BITSTREAM LOADS

The stock image boots with `cma=1000M` on the kernel command line. On these SOMs
that reservation **fails silently** → `CmaTotal: 0 kB` in `/proc/meminfo` → the
`fpga_manager` driver cannot allocate the DMA buffer for the bitstream → **every**
PL load (`.bit`, `.bin`, any format) fails with `ENOMEM`. This is the first thing
to check on a board that "won't take any bitstream".

Fix: set `cma=512M` (reserves cleanly).

1. Edit `/etc/default/flash-kernel` — set the CMA size in the kernel cmdline to
   `cma=512M` (replace the `cma=1000M` token).
2. Apply it: `sudo flash-kernel` (writes the new cmdline to the boot config).
3. Make it take effect **without `reboot`** — see the next section.

Verify after boot: `cat /proc/meminfo | grep -i cma` → `CmaTotal` should be
non-zero (~512 MB).

## Rebooting — DO NOT `sudo reboot`

- **`sudo reboot` WEDGES a KR260.** It goes down and does not come back over the
  network; recovery is a **JTAG power-on-reset only**, and the `kpor` tool lives
  on **`mapstone-dev`**, not on `farm-host-b`. Do not issue a plain `reboot` unless
  someone is positioned to JTAG-POR the board.
- **`kreboot`** reboots but **reuses the old kernel cmdline** — so it will *not*
  pick up a `cma=` change you just made in `/etc/default/flash-kernel`.
- To apply a **new cmdline** (e.g. the `cma=512M` change) safely, use **`kexec`
  with an explicit `--command-line`**. It re-enters the new kernel + cmdline in
  place (~66 s), no cold reset, no wedge risk:

  ```sh
  # (adjust kernel/initrd/dtb paths + the rest of the cmdline for the board)
  sudo kexec -l /boot/vmlinuz --initrd=/boot/initrd.img \
      --dtb=<board.dtb> \
      --command-line="<existing cmdline with cma=512M>"
  sudo kexec -e
  ```

  Read the *current* cmdline from `/proc/cmdline` and edit only the `cma=` token
  so you keep root=, console=, etc. intact.

## Loading a bitstream — fpgautil, NOT byte-swapped .bin

The real load path on these boards is **`fpgautil`** against the `fpga_manager`:

```sh
sudo fpgautil -b tidelink.bin -f Full
```

Preparing the `.bin`:

- `.bit -> .bin` for ZynqMP `fpgautil` = **strip the 127-byte .bit header, then
  copy the raw payload verbatim**. **DO NOT byte-swap.**
- The repo's `fpga/scripts/bit2bin.py` is **Zynq-7000 only** — it byte-swaps for
  the *zynq-fpga* driver. Feeding a KR260 a byte-swapped `.bin` silently produces
  a **bad PL load** (the design loads but behaves wrong). This is why the KR260
  artefacts in `fpga/fpgahub.toml` deliberately ship **no `.bin`**.

Confirm the load: `cat /sys/class/fpga_manager/fpga0/state` → `operating`.

## Deploy reality — Makefile `pynq_overlay` vs. `fpgautil`

The `fpga/Makefile` `deploy` recipe for `kr260-%` targets loads the PL with
`from pynq import Overlay`. **That assumes PYNQ is installed, which it is not on
these boards.** Treat the Makefile deploy as the Z2 path; on KR260 load the PL
yourself with `fpgautil` (above). This mismatch is a known landmine flagged in
`fpga/fpgahub.toml` (the `deploy_kr260_pair` action) and owned by the deploy-rework
lane — it is **not** fixed here.

What *is* wired in: the **AFI width re-poke** runs after the PL load. When you load
via `fpgautil` (bypassing the Makefile), run the AFI fix yourself right after:

```sh
# on the board, immediately after fpgautil, before any AXI traffic:
sudo sh pynq_host/scripts/kr260_afi.sh fix
# or, from the dev host over ssh:
make -C fpga kr260_afi_fix PYNQ_HOST=ubuntu@10.22.24.159
```

## AFI PS-master-port widths — RE-POKE ON EVERY BOOT

Because the design's `psu_init` never runs on these boards, the **stock SOM
firmware** owns the PS configuration, including the AFI PS-master-port data widths
(`afi_fs` SLCR registers). Our block design drives both ports (`HPM0_LPD` control,
`HPM0_FPD` data) at **32-bit**; if the firmware left either wider, every misaligned
32-bit AXI access reads 0 / drops writes — the **KR260 control-plane defect**
(`0x214` write ignored, PHC ignored, while hardwired `0x200 = 0x88` still reads).

- Fix: `sudo sh pynq_host/scripts/kr260_afi.sh fix` (idempotent).
- **This is not persisted.** The firmware reprograms `afi_fs` on **every boot**,
  and it must be re-poked after **every PL load**. The deploy path calls it
  automatically; a manual `fpgautil` load does not — run it yourself.
- Full detail + the exact devmem commands + canary table: `docs/KR260_AFI_CHECK.md`.

## Per-session gotchas (quick reference)

- No `pynq`; use `fpgautil` + `/dev/mem` (`devmem`) directly.
- `cma=512M` or nothing loads. Verify `CmaTotal` after boot.
- Never `sudo reboot` (wedge → JTAG POR on mapstone-dev). Use `kexec` for a new
  cmdline, `kreboot` only when the cmdline is unchanged.
- `.bit -> .bin`: strip 127-byte header, **no byte-swap** (never `bit2bin.py`).
- Re-poke AFI widths after every PL load / every boot.
- Stage SSH keys — password prompts break `sudo -S` in the plumbing.
