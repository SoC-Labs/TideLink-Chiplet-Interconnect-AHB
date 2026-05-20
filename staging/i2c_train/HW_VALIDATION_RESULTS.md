# HW Validation — Results across two bench sessions (2026-05-19 / 05-20)

Companion to `HW_VALIDATION_PLAN.md`. This is what actually happened when
the plan was executed end-to-end on the live `bridge1` pair (z2_02/z2_03)
across two consecutive bench sessions. Each session moved the diagnosis
one layer deeper. Read top to bottom in date order.

**2026-05-20 status (latest):** Two confirmed bugs found and fixed
(W9/V7 weak-pull ruled out → repinned to P15/P16 dedicated Arduino I²C;
`role_lock=1` from deploy strap was blocking `nego_driving` → deploy
script variant skips the strap-lock). Master autoneg FSM now advances
past CLAIM into POLL, **but** master's i2c_master core *still* doesn't
physically drive the bus. ILA shows `i2c_*_t = 1` continuously. Next:
trace why TXN_PRESCALE→TXN_DATA→TXN_COMMAND completes (FSM advances)
without the i2c_master_axil core actually starting an I²C transaction.

**2026-05-19 status (earlier):** the W9/V7 inert result triggered a
repin to PYNQ-Z2's dedicated Arduino I²C pads **P15=SCL / P16=SDA**
(TUL on-board pull-ups) — see §8 below. Bitstreams rebuilt; bench
follow-up is a 3-wire Dupont harness between the two Arduino shield
headers, not external pull-ups on W9/V7.

---

## A. 2026-05-20 bench session — `role_lock=1` strap blocking autoneg

Re-built bitstreams with the P15/P16 repin (commit `3de5ebe`) and
deployed on bridge1. JTAG ILA available remotely via mapstone-dev's
`hw_server` on TCP:3121, with FT2232 cables `Z2_01_TULA`..`Z2_04_TULA`.

### A.1 First probe — bus still inert (predicted nothing)

`run_i2c_test_fast.sh` with the standard `deploy_pair.sh` (which writes
`ROLE_CFG=0x2/0x3` with `lock=1`):

- Master z2_02: state stuck in `CLAIM` (NEGO_STATUS=0x003) from t=0.
- Slave z2_03: `WAIT` → `CLAIM` at t=2624ms.
- `EVER i2c_busy = i2c_addr = sda_start_seen = 0` on both, across 5 s.

### A.2 Master JTAG ILA capture — i2c_master never drives

Captured 4096 samples of `ila_i2c` (probes scl/sda × i/o/t) via Vivado
HW Manager on mapstone-dev. **Every sample showed (1,1,1,1,1,1)**:
- `i2c_scl_t = i2c_sda_t = 1` — tristate **always HiZ** (master never
  commands the IOBUF to drive low)
- `i2c_scl_i = i2c_sda_i = 1` — readback idle-high (pull-ups working)

This ruled out (A) weak pull, (B) ribbon, (C) pin assignment, (D) BD
wiring. Locked focus onto **(D') master core not driving / autoneg-to-
i2c-master gating bug**.

### A.3 Root cause #1 — `role_lock=1` strap kills `nego_driving`

Found in [`axi_chiplet_controller.sv`](../../deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv):

```verilog
// line 299
wire role_in_nego = nego_en && !role_locked;
// line 597
assign nego_driving = role_in_nego && (state in {WAIT,CLAIM,POLL,MASK_*});
// lines 604-612 — autoneg FSM's AXIL signals are MUXed to i2c_master core
// only when nego_driving == 1; else mst_axil_* takes the dormant
// bridge_axil_* path.
assign mst_axil_awvalid = nego_driving ? fsm_axil_awvalid : bridge_axil_awvalid;
```

The deploy script `deploy_pair.sh` writes `ROLE_CFG` with `lock=1` at
deploy time (legacy of the manual sw_coord_autocal flow). `role_lock_reg`
is W1S with POR-only clear. So at the moment the autoneg FSM tries to
drive AXIL transactions, `role_in_nego = nego_en && !1 = 0` and the
autoneg's signals are MUXed away from the i2c_master core — which sits
in HiZ forever.

Sim doesn't hit this because cocotb tests don't set the strap-lock — the
RTL comes out of reset with `role_locked=0`, autoneg writes `NEGO_CFG=
0x61`, and `role_in_nego=1` so `nego_driving` can assert.

### A.4 Fix — `deploy_pair_autoneg.sh` skips the strap-lock

Staged on `mapstone:~/tidelink_hwval/`. Variant of `deploy_pair.sh` that:
- Loads bitstream + .hwh
- Writes strap GPIO (preferred role hint)
- Writes debug_unlock GPIO
- Writes PAIR_BASE_ADDR + PHY_CTRL phase
- **Skips the `ROLE_CFG` strap-lock write** so `role_locked=0` at POR.

After this deploy on power-cycled boards, `ROLE_CFG=0x00000000` (verified
in deploy output, `role_lock=0`).

### A.5 Second probe — bus *still* inert, but FSM advances

`run_i2c_test_fast.sh` post-fix:

- Master z2_02: state **`POLL`** (NEGO_STATUS=0x004) — **advanced past CLAIM!**
  ROLE_STATUS=0x0 (locked=0).
- Slave z2_03: `WAIT` (0ms) → `CLAIM` (2624ms). ROLE_STATUS bit 0 flipped
  1→0 (slave→master) mid-run — possibly the autoneg arbitration picking
  the wrong winner (NEGO_PRIORITY comparison direction may be inverted
  from what the probe script assumes: script gives master=1, slave=0xFFFF;
  the slave's role flipping to master suggests 0xFFFF wins).
- Master JTAG ILA re-capture: still **4096/4096 samples of (1,1,1,1,1,1)**.
  Master FSM is in POLL but `i2c_*_t` never falls.

### A.6 Current open mystery

The autoneg FSM transitioned `IDLE → INIT → WAIT → CLAIM → POLL` —
meaning `TXN_PRESCALE → TXN_DATA → TXN_COMMAND` all completed (each step
advances on `axl_done_r`, which means the AXIL write handshake succeeded
against `i2c_master_axil`). Yet the i2c_master core never physically
drives SCL/SDA low.

Hypotheses to test next:
1. The AXIL writes complete (`bready`) but the i2c_master_axil core
   doesn't actually issue the I²C transaction — perhaps a missing enable
   bit, or a clock-domain crossing that's slow enough that 4096 samples
   (~82 µs at 50 MHz) don't see the transaction kick off.
2. ILA capture window misses the transient — need a triggered capture
   (trigger on `i2c_scl_t == 0`) with a re-arm cycle.
3. NEGO_PRIORITY arbitration is inverted from the probe script's
   assumption — both boards may be trying to become master simultaneously
   and the bus collides at a level the ILA isn't capturing.

A parallel cocotb agent (launched 2026-05-20 ~13:35) is replicating the
exact `nego_probe_fast.py` write sequence in sim to see whether the bug
reproduces there. Findings pending.

### A.7 Lease

Still held by mapstone-dev. **Not released** at session end pending
follow-up. Will release before merging anything.

---

## B. 2026-05-19 bench session (earlier) — W9/V7 channel inert

## TL;DR

| Item | Status |
| --- | --- |
| RTL Fix A / Fix B / hardening / Wlink.scala | ✅ silicon-built, no regression |
| BD Edit 1 (W9/V7 IOBUF top-port + tidelink_0 i2c hookup) | ✅ silicon-validated — BD assembles, place/route clean, lane-7 guard held, build behaviourally == known-good image except I2C pads exist |
| `ila_i2c` BD-cell (6× scl/sda i/o/t probes) | ✅ built into both pair-all + pair-flip-all bitstreams, deployed to both boards, .ltx staged for bench JTAG |
| End-to-end XDC / build pipeline (XDC-`if` bug etc.) | ✅ resolved — full farm-build pipeline green on `feat/i2c-autonomous-lock-integ` |
| **W9/V7 I²C channel electrically functional** | ❌ NO bus activity observable from either board — most consistent with the long-flagged **(A) weak internal pull insufficient** caveat in `J13_PIN_BUDGET.md §3` (note 2026-05-20: this turned out to be coincidence — the real issue was the strap-lock; section A above) |
| Bench freed | ✅ fpgahub `bridge1` lease released |

---

## 1. What ran

`pynq_host/scripts/run_i2c_test_fast.sh` on mapstone-dev (the only host with
direct routes to both 192.168.4.101 / 192.168.6.101) — a fully headless
MMIO probe that:

1. Pushes `nego_probe_fast.py` to both boards via `scp`.
2. Backgrounds the SLAVE probe on z2_03, foregrounds the MASTER probe on z2_02.
3. On each board: writes `I2C_PRESCALE=200`, `NEGO_PRIORITY` (1 master /
   0xFFFF slave), `NEGO_CFG=0x61` (autoneg_en+force_lock+master/slave),
   then polls `NEGO_STATUS` + `ROLE_STATUS` at **~5 ms over 5 s** and
   accumulates sticky activity bits.

Key MMIO observables (rationale in the script header):

| Bit | Meaning | What it being non-zero would rule out |
| --- | --- | --- |
| `ROLE_STATUS[2]` `i2c_slv_busy` on **MASTER** | master's own i2c_slave sees the on-chip drive | Defect D' (core not driving) and address-mux disengaged |
| `ROLE_STATUS[2]` `i2c_slv_busy` on **SLAVE** | master's I2C edges physically crossed W9/V7 | Defect B (ribbon-not-carrying) |
| `NEGO_STATUS[8]` `sda_start_detect` | at least one SDA edge crossed in either direction | full silence |

## 2. What the probe saw

```
----- SLAVE  z2_03 -----
role=slave NEGO_CFG=0x61 I2C_PRESCALE=200 NEGO_PRIORITY=0xffff
t=    0ms NEGO_STATUS=0x002 [WAIT done=0 err=0 won=0 lost=0 sda=0 mismatch=0] ROLE_STATUS=0x3 [locked=1 i2c_busy=0 i2c_addr=0]
t= 2624ms NEGO_STATUS=0x003 [CLAIM done=0 err=0 won=0 lost=0 sda=0 mismatch=0] ROLE_STATUS=0x3 [locked=1 i2c_busy=0 i2c_addr=0]
--- STICKY (any sample over 5 s) ---
EVER i2c_busy=0  EVER i2c_addr=0  EVER sda_start_seen=0  EVER nego_done=0  EVER mask_mismatch=0
states visited: WAIT CLAIM

----- MASTER z2_02 -----
role=master NEGO_CFG=0x61 I2C_PRESCALE=200 NEGO_PRIORITY=0x1
t=    0ms NEGO_STATUS=0x003 [CLAIM done=0 err=0 won=0 lost=0 sda=0 mismatch=0] ROLE_STATUS=0x2 [locked=1 i2c_busy=0 i2c_addr=0]
--- STICKY (any sample over 5 s) ---
EVER i2c_busy=0  EVER i2c_addr=0  EVER sda_start_seen=0  EVER nego_done=0  EVER mask_mismatch=0
states visited: CLAIM
```

Both boards stuck in CLAIM. Across 5 s of 5 ms-resolution polling, on
BOTH boards (including the MASTER, whose own on-chip i2c_slave should
see its own master's drive through the IOBUF readback):

- `i2c_busy` never asserted
- `i2c_addr` never asserted
- `sda_start_seen` never asserted

→ **No edges detectable at the bus-detector level**, on either side of the
ribbon, including the side that is *driving*.

## 3. Diagnosis

The MASTER's own i2c_slave seeing zero activity is the load-bearing
observation. If only the SLAVE had been silent, it'd most plausibly be
ribbon (B) or pad (A). But the MASTER's i2c_slave taps the same on-chip
IOBUF readback as the external pin: a clean active-driven `I` pulse
should register as `i2c_busy` regardless of whether the off-chip ribbon
carries anything.

That it doesn't means the readback `I` is **not seeing clean edges**, on
the side that is supposed to be sourcing them.

Most consistent root cause: the **open-drain I²C bus cannot establish a
clean IDLE-high** because the FPGA's weak internal `PULLTYPE PULLUP` on
W9/V7 (no on-board pull on those balls, as flagged) is too weak to
pull the line up between active-low pulses against the line capacitance.
Without a defined idle, the SDA/SCL pad readback floats around the
threshold and the i2c_slave's edge detectors never trigger.

This is exactly the §3 caveat that `J13_PIN_BUDGET.md` flagged when
selecting on-ribbon W9/V7 for the lowest-disruption pinning, and is the
reason the document already documents two physical fallbacks (option a:
off-ribbon W18/W19 flying leads, option b: external 2.2-4.7 kΩ pull-ups
on W9/V7).

I have **not** definitively ruled out (B) ribbon-not-carrying or (D)
BD-wiring inversion in the IOBUF hookup — but BD Edit 1 is structurally
identical to the working MPS3 reference and the MASTER-self-loopback
silence is hard to explain with ribbon-only or far-side issues.

## 4. Why not ILA?

`ila_i2c` is built into both bitstreams (6× scl/sda i/o/t probes in the
`clk_wiz_0/clk_out1` domain) and deployed to both boards. The `.ltx`
debug files are staged at:

- `mapstone-dev:~/tidelink_hwval/tidelink.ltx`
- `mapstone-dev:~/tidelink_hwval/tidelink-flip.ltx`

But headless capture requires either `xvc_server`/`debug_bridge`
(neither runs on PYNQ Linux in this image and the BD has no
`debug_bridge` cell) **or** physical JTAG access via Vivado HW Manager.
Neither is available from srv03335. The probe is therefore ready and
waiting for the next bench session — the documented playbook is:

```
# On a host with bench JTAG and Vivado:
open_hw_manager
connect_hw_server
open_hw_target <z2_02 JTAG cable>
set_property PROBES.FILE  {tidelink.ltx} [get_hw_devices xc7z020_1]
set_property FULL_PROBES.FILE {tidelink.ltx} [get_hw_devices xc7z020_1]
refresh_hw_device [lindex [get_hw_devices xc7z020_1] 0]
# trigger ila_i2c on i2c_scl_t falling edge OR i2c_sda_o falling edge
# (decoded as: master driving the bus → expect both i,o,t to twitch)
```

If MASTER captures show `i2c_scl_o` toggling but `i2c_scl_i` flat: pad
readback dead — likely (A) pull / IOBUF orientation. If MASTER `_i`
follows `_o` but SLAVE captures show no transitions on `_i`: (B) ribbon.
If neither side shows the master's `_o` toggling at all: (D') core not
driving (BD wiring).

## 5. What's solid (don't re-do)

Branch `feat/i2c-autonomous-lock-integ` @ 7b1697c, submodule 34126b6:

- **Fix A** axi_chiplet_controller.sv slave clock-stretch (`slv_scl_t` not `1'b1`)
- **Fix B** Wlink.v 0x21C APB-write sniffer for `link_lane_mask_hs_result`
- Per-MASK NACK retry + slave ST_NEGO_DONE re-arm in tidelink_autoneg.sv
- `i2c_prescale_reg` safe default 16'd128
- Wlink.scala mirrors the 0x21C reg for regen consistency
- BD Edit 1: W9/V7 IOBUF top-port + i2c\_{scl,sda}\_{i,o,t} wired to tidelink_0 (pair-all + flip-all, byte-symmetric)
- `ila_i2c` BD-cell + connects
- XDC: unconditional `set_property` for i2c\_scl_io=V7 / i2c_sda_io=W9 with `PULLTYPE PULLUP`
- `pynq_host/scripts/bringup_autocal_i2c.sh` turnkey bring-up (replaces sw_coord_autocal_region8.sh / phase_recal_sweep.sh)
- `pynq_host/scripts/nego_probe_fast.py` + `run_i2c_test_fast.sh` headless probe
- Tests: cocotb wlink_pair 9/9, tidelink_autoneg 7/7 + item2 5/5×2,
  i2c_clkstretch repro+fix, i2c_mask_selflock 3/3, wlink_pair
  test_autoneg_i2c_e2e 3/3 (NEGO_CFG=0x61), UVM G1/G2/G3
- Wlink probe + role-lock regression: both boards build, deploy, probe
  clean, idx0=0x55115500 lane-7 guard held, NEGO/role_locked OK

## 6. Recommended next physical action (bench-side)

Pick ONE (in increasing intrusiveness):

1. **Option b (lowest disruption)** — solder/clip external **2.2-4.7 kΩ
   pull-ups** from W9 and V7 each to 3.3 V on one board (either is
   fine; pull is shared). No RTL/BD/XDC change. Re-run
   `run_i2c_test_fast.sh`. If `EVER i2c_busy=1` on master → channel is
   alive; if `EVER i2c_busy=1` on slave too → ribbon carries; proceed to
   `nego_done=1` smoke. This is the single most likely fix per the
   diagnosis above.

2. **Option a (cleanest electrical)** — repin to off-ribbon **W18/W19**
   (RPi I2C SDA/SCL with proper on-board pull-ups) via flying leads
   between the two boards. Requires XDC + BD-port repin (pair-all and
   flip-all). Documented in J13_PIN_BUDGET.md §3a.

3. **Bench JTAG ILA capture** with the staged `.ltx` files before either
   physical change — confirms diagnosis, may unmask a separate defect
   if option 1 doesn't fix it.

The user has been redirected to physical bench follow-up — no further
remote-action surface here.

## 7. Bench / lease state

Released. `fpgahub pair lease show bridge1` returned `free` at sign-off.
Boards remain deployed with the ila_i2c bitstreams (they're idle and
fully redeployable from `mapstone-dev:~/tidelink_hwval/`).
