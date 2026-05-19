# HW Validation — Final Results (2026-05-19)

Companion to `HW_VALIDATION_PLAN.md`. This is what actually happened when
the plan was executed end-to-end on the live `bridge1` pair (z2_02/z2_03)
from feat/i2c-autonomous-lock-integ @ **7b1697c** (BD Edit 1 + ila_i2c).

---

## TL;DR

| Item | Status |
| --- | --- |
| RTL Fix A / Fix B / hardening / Wlink.scala | ✅ silicon-built, no regression |
| BD Edit 1 (W9/V7 IOBUF top-port + tidelink_0 i2c hookup) | ✅ silicon-validated — BD assembles, place/route clean, lane-7 guard held, build behaviourally == known-good image except I2C pads exist |
| `ila_i2c` BD-cell (6× scl/sda i/o/t probes) | ✅ built into both pair-all + pair-flip-all bitstreams, deployed to both boards, .ltx staged for bench JTAG |
| End-to-end XDC / build pipeline (XDC-`if` bug etc.) | ✅ resolved — full farm-build pipeline green on `feat/i2c-autonomous-lock-integ` |
| **W9/V7 I²C channel electrically functional** | ❌ NO bus activity observable from either board — most consistent with the long-flagged **(A) weak internal pull insufficient** caveat in `J13_PIN_BUDGET.md §3` |
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
