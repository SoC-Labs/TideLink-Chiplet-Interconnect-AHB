# KR260 first-session runbook — deploy the recovery build & prove data crossing

**Purpose:** exact, register-by-register sequence for the first bench session on a KR260 pair (or
single onchip board) with the freeze-branch fixes. Goal of the session, in order: (1) deploy a
*rebuilt* bitstream, (2) confirm the capture-clock fix makes bring-up reliable, (3) bring the link
to data mode, (4) **cross byte-exact data both directions — the thing no KR260 has ever done.**

Grounded in: `fpga/hw_regression/td_v2_channels.sh`, `pynq_host/scripts/kr260_afi.sh`,
`kr260_deploy.sh`, the target tcls, and memory (AFI fix, R8 recipe, liveness-is-a-canary).
Every ⚠️ is a real trap this project has already hit — do not skip them.

---
## 0. Preconditions (do these BEFORE touching a board)

- **Boards:** `kr260_01 = 10.22.24.159 = die_a`, `kr260_02 = 10.22.24.153 = die_b`. Login `ubuntu`.
- **Auth:** stage an SSH key (`ssh-copy-id ubuntu@<ip>`) or export `KR260_PASSWORD`. Non-interactive
  runs need the key — password prompts will hang.
- **Rebuild first — the on-disk bitstreams are STALE (pre-fix).** From the freeze branch:
  ```
  source ./set_env.sh; export TIDELINK_PHY_V2=1
  make -C fpga all TARGET=kr260-pair-nptp        # primary data vehicle; +1.3ns, has BUFG hoist
  make -C fpga all TARGET=kr260-pair-flip-nptp
  # (onchip / ptp variants: build if you're doing those legs — §6/§7)
  ```
  Verify each: `bash fpga/scripts/verify_build.sh --targets "kr260-pair-nptp"` → PASS, WNS ≥ 0.
- ⚠️ **NEVER `sudo reboot` a KR260** — it wedges the board; only a JTAG POR (`kpor` on mapstone-dev)
  recovers it. `sudo poweroff`/power-cycle is fine.
- ⚠️ **Do not co-run a Vivado build and this session** on the same host (OOM).

---
## 1. Deploy (fpgautil path — the boards run plain Ubuntu, NOT PYNQ)

```
make -C fpga deploy_pair_role SOC=kr260 PTP=0 ROLE=die_a KR260_PASSWORD=...   # -> 10.22.24.159
make -C fpga deploy_pair_role SOC=kr260 PTP=0 ROLE=die_b KR260_PASSWORD=...   # -> 10.22.24.153
```
This: converts `.bit`→`.bin` (strip 127-byte header, **never** byte-swap), scp + `fpgautil -b … -f
Full`, verifies `fpga_manager state = operating`, **then runs `kr260_afi.sh fix` automatically** and
prints the canaries. Power-cycle → deploy BOTH → then bring up.

---
## 2. 🔴 AFI canary — THE FIRST READ ON EVERY BOARD, EVERY BOOT

Our `psu_init` never runs on Kria; stock firmware leaves the PS↔PL ports at 128-bit vs our 32-bit
BD, so 3/4 of the control plane silently drops. The deploy step fixes it, but **verify** — and
re-apply after any reboot (the poke does not persist yet):

```
devmem 0xFF419000                 # LPD/control AFI  — [9:8] must read 0 (32-bit)
devmem 0xFD615000                 # FPD/data   AFI  — [9:8] must read 0
# if either [9:8] != 0:  devmem 0xFF419000 32 <val & ~0x300> ; devmem 0xFD615000 32 <val & ~0x300>

devmem 0x84030204                 # MUST be 0x00000001  (hardwired const)
devmem 0x84030214                 # MUST be 0x0000e4e4  (lane mask)
```
⚠️ **If 0x0204≠1 or 0x0214≠0xe4e4, STOP — the AFI is wrong and every other reading is a lie.**
Do not debug anything else until these read correctly.

---
## 3. Bring-up (the deterministic manual recipe — pair targets)

APB base `0x8403_0000`. Key registers: `R8 = 0x8403_2100`, `cal/fcsm = 0x8403_2108`,
`EPOCH = 0x8403_2140`, `TX-obs = 0x8403_2120`, `FC/LL bootstrap = 0x8403_0208`.
R8 values (from `td_v2_channels.sh:280`): `SYNC=0x1C  RECAL=0x1E  DATA=0x10`.

Use the harness — it encodes the whole recipe and is the certified path:
```
cd fpga/hw_regression
TIDELINK_SOC=kr260 MASTER=10.22.24.159 SLAVE=10.22.24.153 \
  ./td_v2_channels.sh --channels "data doorbell"
```
If driving by hand instead, the SYNC+recal core is (m=master, s=slave):
```
m/s  wr 0x8403_2100 0x1C          # R8_SYNC on both (bit0 CLEAR — the training-mode escape)
m    wr 0x8403_2100 0x1E ; s wr 0x8403_2100 0x1C ; sleep 0.03   # master pulses recal
m/s  wr 0x8403_2100 0x1C
```
Then the **FC/LL bootstrap triplet** at 0x0208 (this is what `HARDEN_SWI_ENABLE=0` in the rebuild
unblocks — bit[3] swreset now lands):
```
m/s  wr 0x8403_0208 0x00027f09
m/s  wr 0x8403_0208 0x00027f01
m/s  wr 0x8403_0208 0x00027f07
```
Then data-mode entry: `m/s wr 0x8403_2100 0x10` (R8_DATA strips SYNC_EN bit2), `sleep 0.5`.

⚠️ **Ordering gap (if not using the harness):** `gate_link` historically aborts on `fcsm≠4`
*before* the triplet runs. With `HARDEN_SWI_ENABLE=0` in the rebuild the triplet should now land and
the master should leave `fcsm=2` — but if you hand-drive, issue the triplet regardless of the fcsm
reading.

---
## 4. 🔴 Liveness — DO NOT TRUST fcsm

Proven in sim and consistent with silicon: **every status register (`fcsm`, `cal_done`, `cr/crack`,
EPOCH, SYNC counters) reads IDENTICAL on a healthy link and a wedged one.** `fcsm=4` on both dies
while zero data crosses is a real state. **The only trustworthy liveness check is moving tagged
data and reading it back byte-exact (§5).** Read `cal/fcsm 0x8403_2108` and `EPOCH 0x8403_2140`
for context, but never *conclude* the link is up from them.

---
## 5. 🎯 THE MILESTONE — byte-exact data crossing (never done on KR260)

> 🔴 **CORRECTED 2026-07-22 (hardware): the RX FIFO is a STREAMING FIFO — read it STRIDED, not
> fixed-offset.** Packet k lands at `ahb_fifo + 0x10*k + 8`. A fixed-offset read sees only packet 0
> and FALSELY reports "intermittent delivery / lottery" — a multi-day phantom bug that was purely a
> receiver artifact. Use `pynq_host/scripts/kr260_data_rx.py dump|check` (the correct reader).
> Measured with it: **12/12 byte-exact, in order — delivery is RELIABLE.** Data aperture is
> `0xA400_0000` (tx) / `0xA401_0000` (fifo); writing the wrong base (`0x8400_0000`) wedges the PS.

⚠️ **CONFIRM THE DATA APERTURE BASE FIRST.** The target tcl header lists `ahb_tx = 0x8400_0000` /
`ahb_fifo = 0x8401_0000` (relocated from Z2's 0x4400/0x4401), but the FPD data window is documented
as `0xA000_0000` and an earlier note referenced `0xA400_0000`. **These disagree — verify before
trusting.** Cheap check: the RX FIFO window is also a local SRAM, so write-then-read one word
locally on the slave; whichever base round-trips locally is the real one. (This ambiguity has burned
a session before — resolve it, don't assume.)

Once the base `B_TX`/`B_RX` is confirmed and the link is bilateral-healthy:
```
# die_a (master) writes a length-2 packet to ahb_tx:
m wr <B_TX>+0x0  0x00240000        # word0: len=2 header
m wr <B_TX>+0x4  0x00000000        # dest = 0 (local RX FIFO on the peer)
m wr <B_TX>+0x8  0xDA7A0001        # payload0
m wr <B_TX>+0xC  0xBEEF0001        # payload1
# die_b (slave) reads it back from ahb_fifo at the matching offsets:
s rd <B_RX>+0x8                    # expect 0xDA7A0001
s rd <B_RX>+0xC                    # expect credit/payload — see caveat
```
**Pass = byte-exact payload on the slave.** Then reverse roles (B→A) and repeat — both directions
must pass. Do a small burst (≥12 packets) to confirm it holds, not a one-shot.
⚠️ Wedge hazard: writing `ahb_tx` on a *degraded* link hangs the PS-AXI (bus error). Only send on a
confirmed-bilateral link, and re-flash to recover if it wedges (PS stays alive).

---
## 6. Optional: PTP demo leg (needs the -ptp rebuild)

Rebuild `kr260-pair-ptp`/`-flip-ptp` (R1 fixes the −2.4 ns MMCM failure). Follow
`docs/PTP_DEMO_RUNBOOK.md`: NS_INCR=40 at 25 MHz, `HW_SYNC_CTRL` force_en=0x5 (phc_locked_i is
tied 0; gate on `R_SERVO_OFFSET`, not phc_locked), then `td_v2_channels.sh --channels "... ptp"`.

## 7. Optional: onchip single-board leg (no ribbon — the cleanest capture-clock A/B)

Rebuild `kr260-pair-onchip` on the freeze branch (the on-disk build is the pre-BUFG one). Deploy to
ONE board. `die_a` APB `0x8403_0000`, `die_b` APB `0x8C03_0000` (uniform +0x0800_0000). Run
`kr260_onchip_smoke.py` then `kr260_onchip_autonomy.py`. **This is the cleanest test of the
bring-up-lottery fix** — if bring-up is reliable here where die_a was previously ~1-in-4, the
capture-clock fix is confirmed on silicon with no ribbon and no pin lottery in the way.

---
## Session exit criteria (what "it worked" means)
1. AFI canaries pass on both boards. 2. Link reaches data mode. 3. **Byte-exact data crosses both
directions, ≥12-packet burst.** 4. (onchip) bring-up reliable across ≥8 fresh attempts. Record the
bitstream md5 and the raw register dumps for the certification archive.

## Recovery / traps quick list
- Board wedged / no ssh → JTAG POR: `~/bin/kpor kr260-01` on **mapstone-dev** (not srv03335).
- Never `reboot`. AFI poke doesn't survive reboot — re-run §2 after any power event.
- `tl39.py` takes Z2-canonical addresses and remaps internally; `tl_poke.py` takes ABSOLUTE —
  mixing them silently targets the wrong address.
- Stage tooling MIRRORED (`~/td/scripts/tl39.py` + `~/td/tl_socmap.py`) or tl39 exits silently and
  every read returns 0 — indistinguishable from a dead link.
