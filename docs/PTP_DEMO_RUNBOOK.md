# PTP demo runbook — first hardware PTP sync on the KR260 pair

> **Status: first silicon.** PTP has **never** synchronized on hardware (the single
> 2026-05-23 Z2 attempt died on a link precondition, before PTP ran). No timing-clean
> `-ptp` bitstream had ever existed until the R1 recovery build. Treat every "expected
> number" below as a *sim-derived prediction*, not a measured hardware value — this run
> is what turns predictions into measurements.
>
> Everything here is grounded in the actual scripts. Line numbers and register values
> were verified against source on 2026-07-17; deviations from the recon summary are
> listed in the closing **Script vs. recon: inconsistencies** section.

The demo already exists as the opt-in `ptp` channel in
`fpga/hw_regression/td_v2_channels.sh`. You do **not** write new bring-up code. You:
deploy the recovery `-ptp` bitstreams → verify the instrument → bring the link to a
bilateral healthy state → run one command:

```
TD_MASTER_IP=10.22.24.159 TD_SLAVE_IP=10.22.24.153 \
TD_BOARD_USER=ubuntu TD_TL39=/home/ubuntu/td/scripts/tl39.py \
TIDELINK_SOC=kr260 \
./fpga/hw_regression/td_v2_channels.sh --demo --channels "data doorbell ptp"
```

…and read the four PTP gates it reports.

---

## 0. Board / topology facts (KR260 pair)

| Role | Board | die | PS IP | Login | servo role |
|---|---|---|---|---|---|
| master | `kr260_01` | die_a | `10.22.24.159` | `ubuntu` | **Grandmaster (GM)** |
| slave  | `kr260_02` | die_b (flip) | `10.22.24.153` | `ubuntu` | **Subordinate** |

- `td_v2_channels.sh` default IPs/board-names/login are **Z2** values
  (`192.168.4.101` / `192.168.2.101`, `z2_02`/`z2_01`, user `xilinx`,
  `/home/xilinx/tl39.py` — lines 144–152, 285–288). For KR260 you **must** override
  `TD_MASTER_IP TD_SLAVE_IP TD_BOARD_USER TD_TL39`, and export `TIDELINK_SOC=kr260`
  (the script forwards it across the ssh hop via `td_soc()`, line 297 — without it
  tl39 pokes Z2 literals on ZynqMP and hangs the PS).
- `master` in this script = die_a = GM. `slave` = die_b = Subordinate. This matches
  "die_a master = GM" and the servo-role writes in `gate_ptp`
  (`m … SERVO_GM`, `s … SERVO_SUB`, line 684).
- **Two address vocabularies — do not mix them:**
  - **Canonical (Z2) literals** — everything handed to `tl39.py`. The APB cfg block is
    `0x4403_2000`, PHC is `0x4405_0000`. tl39 owns the single relocation to the real
    SoC. Never pre-relocate a canonical literal (double-remap = undecoded = bus hang;
    td_v2_channels.sh:130–135, 264–276).
  - **Absolute KR260 addresses** — only for raw `devmem` / `tl_poke.py` / `kr260_afi.sh`.
    Control block `0x8403_2xxx`, neg block `0x8403_0xxx`, PHC `0x8405_0xxx`. Mapping is
    `0x4403→0x8403`, `0x4405→0x8405`.

---

## 1. Prerequisites

1. **Recovery `-ptp` bitstreams, deployed to BOTH boards.** These are the R1
   timing-clean `-ptp` targets built with `CONFIG.HARDEN_SWI_ENABLE {0}` (R6, applied
   to all four kr260 pair tcls — STATUS_LIVE R6 row; `docs/R6_HARDEN_SWI_OPTIONS.md`
   §7). HARDEN_SWI=0 is what re-enables the `0x208` swreset triplet the bring-up
   needs — see the trap in §4. Targets: `kr260-pair-ptp` (and `-flip-ptp` on the flip
   board). On a **non-ptp** bitstream the `ptp` channel auto-SKIPs (it is not a
   failure), so confirm you deployed a `-ptp` target.

2. **Deploy via the fpgautil path**, one command per board
   (`pynq_host/scripts/kr260_deploy.sh`, driven by `make -C fpga deploy`
   `DEPLOY_STYLE=fpgautil`). It:
   - stages the `.bin` + tooling in a **mirrored** layout under `~/td/`
     (`~/td/tidelink.bin`, `~/td/tl_socmap.py`, `~/td/scripts/*` incl. `tl39.py`,
     `tl_poke.py`, `kr260_afi.sh`) so tl39's parent-dir import of `tl_socmap`
     resolves (kr260_deploy.sh:127–141);
   - loads the PL with `fpgautil -b ~/td/tidelink.bin -f Full` and verifies
     `/sys/class/fpga_manager/fpga0/state == operating` (kr260_deploy.sh:146–160);
   - **runs the AFI fix automatically** (`kr260_afi.sh fix`) right after the load
     (kr260_deploy.sh:165–176). The `.bin` must come from `bit2bin_zynqmp.py`
     (header-strip, **no byte-swap**; never `bit2bin.py`).
   - **Pair safety (kr260_deploy.sh:122–124):** power-cycle → deploy **BOTH** dies →
     bring up → test. Never PL-reload one side of a live link. Never `sudo reboot` a
     KR260 (it wedges; JTAG-POR only, from mapstone-dev).

3. **Power-cycle-fresh boards.** A fresh POR leaves the RX FIFO empty and the FCSM in
   reset — the deterministic recipe assumes this. Remote power-cycle is available
   (`fpgahub hub power-cycle …`); do not ask for a bench trip.

4. **`cma=512M` in effect.** Without it `CmaTotal=0` → `fpga_manager` ENOMEM → no
   bitstream of any format loads (`docs/KR260_BOARD_ENV.md`). Verify:
   `cat /proc/meminfo | grep -i Cma` → non-zero (~512 MB).

5. **Instrument preamble green — BEFORE trusting any register read.**
   `fpga/hw_regression/lib/instrument_preamble.sh`. This is the L1 self-check that
   defends against the "the instrument was broken, not the DUT" failure class
   (the campaign's repeated burn). Run it per board with a reader that takes
   **absolute physical addresses** (tl_poke.py / devmem style — **NOT** tl39, which
   relocates and would double-map; see the lib header, lines 47–61):

   ```sh
   # on the board (or via ssh), after AFI fix, before any DUT verdict:
   source ~/td/scripts/instrument_preamble.sh   # if staged; else source from repo
   preamble_run_all kr260 kr260_01 \
       "sudo python3 ~/td/scripts/tl_poke.py rd" \
       "sudo python3 ~/td/scripts/tl_poke.py wr"
   ```

   All seven checks must pass (reader self-test, width probe, **AFI check (step 3,
   reuses kr260_afi.sh)**, control canaries, RW-scratch litmus at `+0x2160`, V2
   retired-register trust guard, wedge-safety envelope). On the first failure it
   prints exactly one `PREAMBLE_FAIL: <NAME>` line and aborts — do not proceed.

---

## 2. Step-by-step

### 2.1 AFI canaries (every board, every PL load)

`kr260_deploy.sh` runs the AFI fix automatically, but re-verify by hand if you loaded
the PL any other way (`docs/KR260_AFI_CHECK.md`, `pynq_host/scripts/kr260_afi.sh`).
The AFI width poke is **not persisted** and must be re-applied after every PL load /
every boot, on **both** boards, **before any AXI traffic**:

```sh
sudo sh ~/td/scripts/kr260_afi.sh fix     # RMW [9:8]->00 on LPD+FPD, then canaries
```

Pass criteria (kr260_afi.sh:189–211, KR260_AFI_CHECK.md §3), on each board:

| Canary (absolute) | Expected | Meaning |
|---|---|---|
| `0x8403_0204` | `0x0000_0001` | role reg reads through the control plane |
| `0x8403_0214` | `0x0000_E4E4` | lane-mask POR (active lanes 2,5,6,7) |
| `0x8405_0008` write `40` → read | `40` (`0x28`) | **PHC** data plane accepts a 32-bit RW |
| `0x8403_0200` | `0x0000_0088` | negative control (hardwired; INFO, **not** a gate) |

If widths read `00` but canaries still fail → AFI was not the (only) cause; **stop**,
do not keep poking `afi_fs`, escalate to the SmartConnect/BD trace.

### 2.2 Link bring-up to a bilateral healthy link

`td_v2_channels.sh` does this in `gate_link` (line 419) using `bringup_manual`
(line 377, `--mode manual`, the default and the deterministic recipe). Key mechanics:

- **Training-mode escape.** Both dies POR with the training-mode trap latched
  (`swi_training_mode`, R8 bit0). The escape is `0x210C = 0` (NEGO_TRAIN_CFG) **then**
  `R8 = 0x1C` (bit0 CLEAR) — order matters. `bringup_manual` writes `R_NEGO_TRAIN
  (0x…210C) = 0x0` first, then the R8 `0x1C → 0x1E(recal) → 0x1C` sequence
  (lines 379, 385–387). R8 bit0 set was the silent `S_HOLD` coin-flip; `0x1C` is the
  deterministic base.
- **swreset triplet — now that HARDEN_SWI is OFF.** Data-mode entry (`handoff`,
  line 406) issues the FC/LL bootstrap triplet `0x0002_7f09 → 0x0002_7f01 →
  0x0002_7f07` to `R_FCCTRL (0x…0208)` on both dies with a 0.2 s dwell per step
  (FC_TRIPLET, line 279; handoff loop 408–410). `0x…7f09` asserts `swi_swreset`
  (bit3); on the recovery build (HARDEN_SWI=0) that bit reaches Wlink and gives both
  LL framers a fresh, overlapping reset — the R6 cure for the master's stuck fcsm=2.
- **Gate on the right things.** `gate_link` (lines 434–441) asserts **`cal=1` AND
  `fcsm=4` on BOTH dies** (`R_STATUS 0x…2108`: [16]=cal, [19:17]=fcsm, 4=bilateral).
  Do **not** gate on `lane_locked` — it reads `0x00` even on a healthy link (obs-regs
  reference; instrument_preamble is_trustworthy_reg note on 0x2108).
- **EPOCH anchored + byte-exact data both directions** complete "healthy" per the G3
  criterion (recovery plan G3): EPOCH `0x…2140`[0]=anchored, and `gate_data`
  (line 516) proves protocol-legal 28-word frames land **byte-exact** A→B and B→A
  (frame_compare, line 492). `gate_data` runs before `ptp` in the fixed wedge-safe
  order (main loop, line 876: `data → doorbell → ptp → xhb`).

> **Ordering caveat (see §4 finding #1):** `gate_link` **aborts** if it does not see
> bilateral `fcsm=4` from the R8 recipe alone (main, line 866), but the swreset
> triplet that clears the master's fcsm=2 lives in `handoff()` inside `gate_data` —
> *after* that abort. If `gate_link` aborts with **master fcsm=2, slave fcsm=4**, run
> the swreset triplet by hand on both dies with overlapping HIGH windows, then re-run:
>
> ```sh
> # both dies, overlapping: assert swreset (…7f09) on BOTH, hold, then release
> tl39: wr 0x44030230 0x0    (FC quiesce, both)
> tl39: wr 0x44030208 0x00027f09   (both dies)   # swreset HIGH — hold ~0.25 s
> tl39: wr 0x44030208 0x00027f01   (both dies)                 # release
> tl39: wr 0x44030208 0x00027f07   (both dies)
> # re-check R_STATUS: master fcsm should walk 2 -> 4
> ```
>
> (These are canonical literals for tl39; it relocates to `0x8403_0208`/`0230`.)
> This is exactly what `handoff()` does; it is only an ordering gap that `gate_link`
> doesn't invoke it. Issue the triplet **only while the link is quiescent** (pre-data)
> — a swreset during live peer-window traffic re-exposes the PS-wedge HARDEN_SWI
> guarded (R6 §3). Bring-up is quiescent, so it is safe here.

**Lottery-aware:** a single failed bring-up proves nothing. The anchor is a placement
lottery; require **N≥8** bring-ups per die before declaring the build good or bad
(recovery plan G3). One master-fcsm=2 on one attempt is a sample, not a verdict.

### 2.3 PHC setup on both dies

Handled inside `gate_ptp` (function at line 587), but understand what it does:

- **PHC presence canary** (STEP 0, lines 590–624): read+readback-verify the RW
  `ns_incr` register (8-bit, POR=4). No/implausible answer → the channel **SKIPs**
  (rc=77), never FAILs, and touches nothing else. This is the guard against firing a
  PHC-aperture read on a mis-selected non-PTP bitstream (DECERR → SIGBUS).
- **NS_INCR = 40** (`TD_PHC_NS_INCR`, default at line 167). phc_clk = clk_wiz
  `clk_out2` = **25 MHz** in both `pynq-z2-pair-all` and `kr260-pair-ptp`
  `tidelink_design.tcl` → 40 ns/cycle. **The R1 clock fix kept phc_clk at 25 MHz.**
  The PHC core POR is 4 (250 MHz ASIC target), so NS_INCR **must** be written or the
  counter runs 10× slow. `gate_ptp` writes it and requires the readback to stick
  (lines 615–624). (The "50 MHz" in the tcl header comments and the
  phc_vivado_wrapper.v operator note are **stale** — the live clk_wiz CONFIG is
  authoritative.)
- **PHC free-run — anti-tie-off** (STEP 1, lines 626–668): enables the PHC, samples
  each die's software-captured `{sec,ns}` twice with a 2 s dwell, and requires the
  counter to **strictly advance** (delta>0). A tied-off/absent PHC reads a frozen
  constant. The implied ns/s rate is reported as a **diagnostic only** — the host
  sleep over ssh cannot resolve a clock rate, so the gate is strictly delta>0.

### 2.4 force_en — why it is mandatory

`gate_ptp` arms the master initiator with `HW_SYNC_CTRL = 0x5`
(`HW_SYNC_FORCE`, line 245; write at line 696). `0x5` = [2] `force_en` | [0] `enable`.

**Why force_en is not optional:**
1. `phc_locked_i` is **tied 0 in every FPGA bitstream** — the BD never connects
   `tidelink_0/phc_locked_i` (td_v2_channels.sh:80–84, 234–236; R_HW_SYNC_STATUS[18]
   note). Without force_en the initiator would wait forever on a lock that can never
   assert.
2. Without force_en the PTP TX FSM **deadlocks in `TX_WAIT_IDLE`**.

force_en makes the initiator re-arm and re-fire continuously while held, which is what
we want for a bounded ssh-paced dwell (the ~1 s `HW_SYNC_INTERVAL` alternative would
make the channel minutes long). `gate_ptp` **stops** the free-running initiator
(`HW_SYNC_CTRL = 0x0`, line 714) before returning, so the later XHB gate sees a quiet
link.

### 2.5 Roles + run the `ptp` channel

Roles are set by `gate_ptp` (line 684): `R_SERVO_CTRL` = `SERVO_GM (0x1)` on master,
`SERVO_SUB (0x3)` on slave; then `R_PTP_CTRL = 0x1` on both (short-packet engine),
then arm. Ordering mirrors the sim `_setup_ptp`: step-threshold + roles **before**
ptp_enable, ptp_enable **before** arming the initiator.

Run:

```
TD_MASTER_IP=10.22.24.159 TD_SLAVE_IP=10.22.24.153 \
TD_BOARD_USER=ubuntu TD_TL39=/home/ubuntu/td/scripts/tl39.py \
TIDELINK_SOC=kr260 \
./fpga/hw_regression/td_v2_channels.sh --demo --channels "data doorbell ptp"
```

`--demo` adds banners + a summary table and changes **nothing** about what is tested or
the exit code. It acquires a lease automatically (disable with `--no-lease`).

**Expected gate-by-gate output (the four things the `ptp` channel proves):**

1. **PHC canary** — `PHC canary OK on both dies (ns_incr=40 readback verified)`.
2. **PHC free-run** — `PHC master free-running (+N ns …)` and slave likewise; the
   `[phc] … advanced N ns over ~2s` diagnostic lines.
3. **GM emitted SYNCs** — `PTP GM emitted SYNCs (seq S0 -> S1, +k)` — HW_SYNC seq_num
   ([17:2] of `R_HW_SYNC_STATUS 0x…2048`) advanced.
4. **Round trip complete** — `PTP round trip complete (slave servo computed a real
   offset in n/6 rounds)` — a non-zero hardware-computed `R_SERVO_OFFSET` (signed ns,
   `0x…2060`) is only reachable if SYNC t1→t2→DELAY_REQ t3→t4→FC-sideband t1/t4 all
   crossed the link.
5. **Convergence** — `PTP servo converged (final |offset|=X ns <= 12000 ns …)`.

**SERVO_OFFSET convergence criterion** (`PTP_TOL_NS`, default **12000 ns**, line 184;
gate at lines 749–757): the gate passes iff **final |offset| ≤ 12000 ns**. The servo
takes a coarse `SET_TIME` phase step above `PTP_STEP_NS = 12000` (line 181), then rides
the fine PI frequency steer below it.

**Expected actual convergence values — UNKNOWN (first silicon).** State this plainly in
the demo. The plausible range from the sim:

- `cocotb/tidelink_top_pair/test_ptp_link_sync.py` does **not** hardcode an expected
  offset. It computes the initial skew dynamically and gates on:
  `worst |offset| ≤ SERVO_STEP_THRESH_NS (12000 ns)` (test line 262) and
  `worst |skew| ≤ 3×12000 = 36000 ns` (test line 270).
- The `PTP_TOL_NS` comment (td_v2_channels.sh:187–189) records the sim behaviour:
  **init skew ~20000 ns → steady |skew| ~4290 ns**, gate worst |offset| ≤ 12000.
- **Hardware caveat, baked into the script (lines 190–196, 752–756):** `PTP_TOL_NS` is
  **UNCALIBRATED on silicon**. The FPGA link runs far slower than the sim, so real
  t1..t4 latency — and thus the irreducible residual — may be **larger** than the sim's
  ~4290 ns. **If the first run fails ONLY this gate while the printed round-by-round
  offsets are clearly shrinking, that is a tolerance calibration, not a DUT
  regression:** record the measured floor and re-run with `TD_PTP_TOL_NS` raised.

Exit code: 0 = every selected channel PASS (SKIP is not a failure); 1 = any FAIL.

---

## 3. Reading the result

### 3.1 Registers to dump for the demo narrative

All canonical for tl39; absolute KR260 in the last column for a raw `devmem`/`tl_poke`
dump. **Never** probe `0x21AC/0x21B0/0x21B4` (CPU hard-stall — see §4).

| What | Canonical | KR260 abs | Decode |
|---|---|---|---|
| Link status | `0x4403_2108` | `0x8403_2108` | [16]=cal, [19:17]=fcsm (4=bilateral), [23]=cr |
| EPOCH anchor | `0x4403_2140` | `0x8403_2140` | [0]=anchored (sticky), [6:1]=span (smaller better) |
| HW_SYNC_STATUS | `0x4403_2048` | `0x8403_2048` | [0]=active [1]=busy **[17:2]=seq_num** [18]=phc_locked (**tied 0 — ignore**) |
| **SERVO_OFFSET** | `0x4403_2060` | `0x8403_2060` | **signed 32-bit ns** — the instrument; last_offset_r |
| SERVO_DELAY | `0x4403_2064` | `0x8403_2064` | last_delay_r (ns) |
| SERVO_STATUS | `0x4403_205C` | `0x8403_205C` | [0]=servo_locked (corroboration only) [1]=active |
| PHC ns_incr | `0x4405_0008` | `0x8405_0008` | [7:0] ns/cycle (should read 40) |
| PHC cap sec | `0x4405_0020` | `0x8405_0020` | SW-captured seconds[31:0] (region-1 capture) |
| PHC cap ns | `0x4405_0028` | `0x8405_0028` | SW-captured nanoseconds[29:0] |

- **SERVO_OFFSET signed-ns decode:** it is 32-bit two's-complement. A read of
  `0xFFFF_FF00` = −256 ns, not 4.29 billion. The script's `s32()` helper does exactly
  this (td_v2_channels.sh:356–357): if bit31 set, value − 2³².
- **HW_SYNC_STATUS seq counter:** `(status >> 2) & 0xFFFF` (lines 688, 710). It must
  **advance** between before-arm and after the dwell — that is the "GM actually fired"
  proof.
- **PHC capture banks:** pulse `PHC_CTRL = 0x5` (en|capture, self-clearing) then read
  `{cap_sec, cap_ns}`. This is the **region-1 software** capture, explicitly
  independent of the region-2 HW captures the PTP datapath uses, so sampling it cannot
  perturb the servo (td_v2_channels.sh:256–262, 577–585).

### 3.2 A healthy convergence trace

The `[ptp] round i/6: slave servo last_offset = … ns` lines (from the loop at 699–708)
should show:

- round 1–2: a **large** offset (the cold t1..t4 pipeline / the initial PHC skew), or a
  coarse SET_TIME step;
- rounds 3–6: the magnitude **shrinking and settling** toward a small residual;
- final `[ptp] |offset|: first=… worst=… final=… ns (tol=12000)` with `final ≤ 12000`;
- `GM SYNCs +k` with k>0; `servo_locked=1` is nice-to-have corroboration but **not the
  gate** (its threshold is uncalibrated for this link speed).

Healthy = seq advanced, offset non-zero in ≥1 round, final |offset| within tol (or
clearly converging with a documented floor).

### 3.3 Failure decision tree

| Symptom | Likely cause | Next debug |
|---|---|---|
| **PHC canary SKIP** (channel skips, rc=77) | non-ptp bitstream, or PHC aperture not decoding | Confirm you deployed a `-ptp` target. Re-check AFI + `0x8405_0008` write-40 canary (KR260_AFI_CHECK §3). |
| **Gate 1/2 fail: PHC free-run FROZEN (delta=0)** | PHC dead / tied-off / clock issue (clk_wiz clk_out2 not toggling) | Verify NS_INCR readback stuck at 40; check the R1 MMCM/clk_wiz build; confirm PL `state=operating`. This is a clock/PHC-instantiation fault, not a link fault. |
| PHC free-run **BACKWARDS (delta<0)** | bad read or a stray `set_time` | Not a wrap (phc_now_ns folds seconds); re-sample; check nothing else is writing PHC_CTRL. |
| **GM seq stuck** (`PTP GM never fired`) | initiator never armed / force_en not set / TX_WAIT_IDLE deadlock | Confirm `HW_SYNC_CTRL=0x5` (force_en) landed; confirm data mode (`R8=0x10`) and link still fcsm=4/cal=1. |
| **Offset stuck at 0** all rounds | SYNCs not crossing the link — one of SYNC RX(t2) / DELAY_REQ TX(t3)/RX(t4) / FC-SIDEBAND t1,t4 delivery failed | The datapath broke: re-verify `data` channel byte-exact both directions first; a passing `data` gate but 0 offset points at the PTP short-packet path (0x50/0x51 FC-bypass) or the FC sideband mailbox, not the raw link. |
| **Offset huge / oscillating**, not settling | servo gains / step-threshold vs. link latency | Servo tuning: it is exchanging (seq advances, offset non-zero) but not converging. Inspect round-by-round trend; consider SERVO_STEP tuning. **Not** a link or PHC fault. |
| **Offset converging but final > 12000** | tolerance calibration, not a regression | Raise `TD_PTP_TOL_NS`, record the measured floor (td_v2_channels.sh:190–196). |

---

## 4. Known traps (verify each — sources cited)

1. **`gate_link` aborts before the swreset triplet runs (ordering gap).**
   `gate_link` requires bilateral `fcsm=4` from the R8 recipe alone and `main` aborts
   otherwise (td_v2_channels.sh:441, 866), but the swreset triplet that clears the
   master's fcsm=2 is inside `handoff()`/`gate_data` (lines 406–411, 518) — *after* the
   abort. On the KR260 recovery build (HARDEN_SWI=0, but NEGO_CFG_RESET still 0x61 —
   only R6 option (a) was applied, option (b) is UNAPPLIED per STATUS_LIVE) the master
   may POR into `fcsm=2` (`docs/R6_HARDEN_SWI_OPTIONS.md` §1.2). **If gate_link aborts
   with master fcsm=2 / slave fcsm=4, issue the swreset triplet by hand (§2.2 box) with
   overlapping HIGH windows on both dies, then re-run.** Do it only while the link is
   quiescent.

2. **Z2-era `bringup_ptp_*.sh` / `_ptp_common.sh` are `/dev/mem` Z2-hardcoded — NEVER
   on KR260.** They poke Z2 absolute addresses directly; on ZynqMP those land on the
   undecoded `0x4403_xxxx` aperture and **hang the PS with no timeout**. The KR260 path
   is `td_v2_channels.sh` + `tl39` (SoC-relocating) only. (Recon summary; address-map
   reference; instrument_preamble refuses `0x4403_xxxx` on kr260, lines 204–208.)

3. **`phc_locked` never asserts on FPGA — gate on SERVO_OFFSET only.**
   `phc_locked_i` is tied 0 in every FPGA bitstream (BD never connects it), and
   `PHC_LOCK_GATE_EN=0`. `HW_SYNC_STATUS[18]` reads 0 even on a fully working link.
   Reading it as a pass would re-import the exact "spurious tied-off pass" the sim test
   `test_phc_locked_is_real_not_tied` (test line 148) was written to kill.
   (td_v2_channels.sh:80–84, 234–236.)

4. **Never probe `0x21AC / 0x21B0 / 0x21B4` — CPU hard-stall.** These offsets stall the
   CPU thread; the instrument preamble refuses them (`PRE_WEDGE_OFFSETS`,
   instrument_preamble.sh:87, 193–202; address-map reference). They are not on any path
   in this runbook — keep it that way.

5. **`0x2160` is the RW-scratch litmus register, NOT the servo lock threshold and NOT
   "just scratch" to clobber.** The preamble writes/reads it with a per-nibble 0x7 mask
   and **restores it exactly** (instrument_preamble.sh:307–339). In `td_v2_channels.sh`
   the bring-up uses `R_LOCKTHR = 0x…2160 = 0x5555_5555` as the per-lane Hamming lock
   threshold (line 216, 382). Do not treat it as free scratch during a live link — set
   it to `0x5555_5555` for bring-up and leave it.

6. **Lottery-aware statistics.** A single failed bring-up or a single high offset proves
   nothing — the anchor is a placement lottery (memory; recovery plan G3). Require
   **N≥8** bring-ups per die before concluding the build/link is good or bad. Report the
   pass count, not a single trial.

7. **`--demo` never changes the verdict.** It is presentation only (banners + summary),
   same tests, same order, same exit code (td_v2_channels.sh:89–92, 789–793). Safe to
   leave on for the record.

---

## 5. Evidence to archive (certification record)

Save under the run's evidence dir (e.g. `imp/fpga/output/<target>/ptp-demo-<date>/`):

1. **Full `td_v2_channels.sh --demo` console log** — captures every gate, the
   round-by-round `[ptp] round i/6 … last_offset = … ns` trace, the final
   `MEASURED:` metric lines, and the exit code. This is the primary artefact.
2. **Instrument-preamble log** for both boards (`preamble_run_all` output) — proves the
   instrument was verified before any DUT verdict (defends against the "broken
   instrument" retraction class).
3. **AFI fix + canary output** for both boards (`kr260_afi.sh fix`) — proves the
   control/data planes decoded 32-bit at run time.
4. **Register dumps** (canonical + absolute), captured at the converged state:
   `R_STATUS (0x2108)`, `EPOCH (0x2140)`, `HW_SYNC_STATUS (0x2048)` before/after arm
   (to show seq advance), `SERVO_OFFSET (0x2060)`, `SERVO_DELAY (0x2064)`,
   `SERVO_STATUS (0x205C)`, PHC `ns_incr (0x…0008)` and two `{cap_sec,cap_ns}` samples
   per die (to show the free-run advance).
5. **Bitstream provenance** — target name, build tag (`kr260-bitstream-<target>-<date>`),
   md5 of the deployed `.bin`, and confirmation `HARDEN_SWI_ENABLE=0` /
   `TIDELINK_FPGA_PTP=1` are in the netlist (structural verify).
6. **N≥8 bring-up statistics** — pass/fail per attempt per die, so the result carries a
   confidence interval, not a single lucky/unlucky trial. Record any manual
   swreset-triplet interventions (trap #1).
7. **The measured convergence floor** — first-silicon `worst`/`final |offset|` and
   `|skew|`, and whether `TD_PTP_TOL_NS` had to be raised. This calibrates the (currently
   sim-only) tolerance for the next run.

---

## Script vs. recon: inconsistencies found

These are **findings, not blockers** — the scripts are authoritative; the recon summary
line numbers/values drifted:

1. **`gate_ptp` line number.** Recon said "gate_ptp at ~:554". Actual: the `ptp` channel
   comment block starts at line 571 and the **`gate_ptp` function is at line 587**.
   Line 555 is `gate_doorbell`. (NS_INCR at ~167 ✓ was correct.)

2. **`PTP_TOL_NS` line number.** Recon said "PTP_TOL_NS ~:240". Actual: `PTP_TOL_NS` is
   defined at **line 184**; line 240 is `R_SERVO_OFFSET`. (Value 12000 ns ✓ correct.)

3. **`R_SERVO_OFFSET` address.** Recon wrote "`R_SERVO_OFFSET (0x…2060)`" ✓ — matches
   `0x4403_2060` canonical / `0x8403_2060` KR260 absolute.

4. **The cocotb test does not encode a specific expected offset.**
   `test_ptp_link_sync.py` computes the initial skew dynamically and asserts only the
   *bounds* (`worst |offset| ≤ 12000`, `worst |skew| ≤ 36000`). The concrete "init
   20000 → steady ~4290 ns" figures live in a **comment** in `td_v2_channels.sh`
   (lines 187–189), not as test literals. So the honest first-silicon statement is "gate
   is ≤12000 ns; sim steady ~4290 ns; hardware residual may be larger and is
   uncalibrated" — which §2.5 states.

5. **Ordering gap between `gate_link` and the swreset triplet** (trap #1). This is the
   most material finding: the recon's bring-up order ("link G3 → NS_INCR → force_en →
   gates") assumes `gate_link` reaches bilateral fcsm=4 on its own, but on the KR260
   recovery build (R6 option (a) only) the master can stick at fcsm=2, and the triplet
   that fixes it (`handoff()`) runs *after* the `gate_link` abort. The runbook adds the
   manual-triplet escape (§2.2) to cover this. If HW shows the master routinely
   fcsm=2-stuck, the durable fix is R6 option (b) (`NEGO_CFG_RESET {7'h00}`, a rebuild),
   which is documented UNAPPLIED pending David's sign-off.

6. **Board identity must be overridden for KR260.** `td_v2_channels.sh` defaults are Z2
   (IPs, board names, `xilinx` login, `/home/xilinx/tl39.py`). The recon summary calls
   the demo "KR260-aware via tl39/td_socmap" — true for *address* relocation, but the
   *board/topology* env (`TD_MASTER_IP`, `TD_SLAVE_IP`, `TD_BOARD_USER`, `TD_TL39`,
   `TIDELINK_SOC=kr260`) still has to be set explicitly (see §0/§2.5). Not a bug, but an
   easy Monday foot-gun worth calling out.
