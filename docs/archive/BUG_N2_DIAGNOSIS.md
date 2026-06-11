# Bug N2 — Slave SWI_TRAINING_MODE Never Written by Master's I²C Transaction

**Date:** 2026-05-29
**Branch:** `feat/td-autonomy`
**HEAD:** `5a87158` (Bug N1 fixes — `mask_hs_in_progress` + i2c_prescale POR)
**Probe:** `cocotb/tidelink_top_pair/test_15_bug_n2_slave_apb_write_probe.py`
**Status:** Diagnosed — structural RTL gap, NOT a transient timing bug

---

## Symptom (from `test_10_autonomous_train_post_por`)

```
t=1665 µs   Master ST_TRAIN_ENTER (state 12), slave ST_NEGO_DONE (state 5)
            Master swi_training_mode_r = 0       (will pulse next)
            Slave  swi_training_mode_r = 0       ← should latch 1 after I²C write

t=2313 ms   state 12 → 13  (Master advances to ST_TRAIN_RUN — peer ACK'd)
            Master swi_training_mode_r = 1       ← local set strobe fired
            Slave  swi_training_mode_r = 0       ← never updated

t=14461 µs  Master ST_TRAIN_FAIL (state 17) after 15 polls
            peer_lane_locked = 0x00              ← slave never trained
            peer_cal_done    = 0
            Slave  swi_training_mode_r = 0       ← still
```

Master's autoneg FSM (`deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv:911-953`)
in `ST_TRAIN_ENTER`:
1. Pushes 6 bytes (`0x21, 0x00, train_value, 0x00, 0x00, 0x00`) into i2c_master's
   TX FIFO, then issues `cmd_start | cmd_write_multiple | cmd_stop`.
2. Polls i2c_master STATUS; when not-busy + MISS_ACK==0 (peer ACK'd) →
   pulses `local_train_set_pulse_r` (master's own SWI_TRAINING_MODE := 1)
   and advances to ST_TRAIN_RUN.
3. The slave's `swi_training_mode_r` *should* have been written to 1 by
   the I²C-driven APB write that targeted address `0x2100` (SWI_TRAINING_MODE,
   Region 8 offset 0x100).

The slave's `swi_training_mode_r` is read-only to anything outside the
chiplet-controller; the **only** producers are:
- `local_training_mode_set_w` / `local_training_mode_clr_w` (FSM-internal, only
  asserted while the slave's own autoneg walks the training sub-flow — which
  it doesn't, because slaves park in ST_NEGO_DONE).
- `region8_write && ctrl_reg_addr[2:0] == 3'h0` (APB write to SWI_TRAINING_MODE
  via `tidelink_apb_regs` → `ctrl_reg_write`/`ctrl_reg_addr`).

So the question is: **does the master's I²C write to peer 0x2100 ever turn
into a `ctrl_reg_write` on the slave?**

---

## Probe (`test_15_bug_n2_slave_apb_write_probe.py`)

The probe traces, on the slave side during `ST_TRAIN_ENTER`:

| Layer | Signal | Module |
|---|---|---|
| I²C pins | `i2c_scl`, `i2c_sda`, per-side tristate enables | top |
| I²C-slave core | `state_reg`, `bus_addressed`, `busy` | `i2c_slave_inst` |
| Slave AXIL master | `m_axil_aw{valid,ready,addr}`, `m_axil_w{valid,data}`, `m_axil_bvalid` | `u_i2c_slave` |
| AXIL→APB bridge | `slv_apb_{psel,paddr,penable,pwrite,pwdata}` | `u_axil2apb` |
| APB gate | `slv_apb_active` (=`slv_apb_psel && !role_is_master`) | `axi_chiplet_controller` |
| Wlink APB mux | `wl_apb_{psel,paddr,pwrite,pready}` | `axi_chiplet_controller` |
| Chiplet ctrl bus | `ctrl_reg_write`, `ctrl_reg_addr`, `ctrl_reg_wdata`, `region8_write` | `axi_chiplet_controller` |
| Target reg | `swi_training_mode_r` | `axi_chiplet_controller` |

---

## Root cause — STRUCTURAL RTL GAP

**The slave's I²C-driven APB ingress is routed solely to the Wlink core; it
is NOT routed to the `tidelink_apb_regs` decoder that drives `ctrl_reg_write`
for the chiplet-controller's internal Region 8 registers.**

### File:line evidence

In `src/rtl/local_overrides/axi_chiplet_controller.sv`:

- **L1166-1204**: `u_i2c_slave` (i2c_slave_axil_master) drives
  `slv_axil_{awaddr,awvalid,wdata,wvalid,bvalid,...}`.
- **L1220-1254**: `u_axil2apb` (mkaxil2apb_bridge) converts the slave AXIL bus
  into `slv_apb_{psel,paddr,penable,pwrite,pwdata,...}`.
- **L1391**: `wire slv_apb_active = slv_apb_psel && !role_is_master;`
- **L1393-1432**: The `wl_apb_*` mux: when `slv_apb_active=1`, the slave's
  I²C-driven APB drives the **Wlink** APB port (`wl_apb_*`). There is no
  fan-out to anything else.
- **L1691-1700**: `wl_apb_*` feeds **only** `u_wlink.apbport_0_*`.
- **L1098 / L1866** (`src/rtl/tidelink_top.sv`): `ctrl_reg_write` /
  `ctrl_reg_addr` / `ctrl_reg_wdata` are sourced from `u_apb_regs`
  (`tidelink_apb_regs`), which is driven exclusively by the **external**
  APB (`apbs_*` from the CPU/AHB→APB bridge in `tidelink.sv:142-186`).

So the I²C-driven write reaches only Wlink's APB port. Region 8 (SWI_TRAINING_MODE)
lives **inside `axi_chiplet_controller`**, decoded from `ctrl_reg_write` /
`ctrl_reg_addr[3]==1` (see `tidelink_apb_regs.sv:443-445` and
`axi_chiplet_controller.sv:785, 828-832`). The two address spaces are not
crosswired.

### Secondary issue: address truncation

`i2c_slave_axil_master` is instantiated at **L1167** with `ADDR_WIDTH=13`.
The master writes a 16-bit pointer `0x2100` MSB-first (`0x21`, `0x00`). The
core writes the first byte into `addr_reg[15:8]` (Verilog left-truncated
into a 13-bit `addr_reg`), so:
- bits [12:8] keep only `0x21 & 5'h1F = 5'h01`
- bits [7:0] take `0x00`
- result: `addr_reg = 13'h0100` → `m_axil_awaddr = 13'h0100`

Coincidentally, `paddr[8:5] = 4'b1000` (= `apb_region == 4'b1000` = Region 8)
and `paddr[4:2] = 3'h0` (SWI_TRAINING_MODE slot). If `slv_apb_*` were routed
into `tidelink_apb_regs`, this would actually hit the right register. So
the address-truncation bug is silent here — but it confirms the path is
half-wired regardless.

### Why master's FSM still sees a peer-ACK

`i2c_slave_axil_master` ACKs every byte it accepts into its internal AXIL
master FIFO, independently of whether the AXIL write retires successfully
through the downstream APB bridge. The peer ACK observed by master's
`i2c_master_axil` only proves the slave-side AXIL master accepted the bytes.
The bytes then either:
- get forwarded as an AXIL write to Wlink at `awaddr=0x0100` (where Wlink
  presumably either accepts an unrelated write at that paddr or asserts
  `pslverr`), or
- get dropped on Wlink's APB if Wlink does not decode paddr=0x100.

Either way, **the chiplet-controller's `ctrl_reg_write` is never asserted
on the slave**, so the slave's `swi_training_mode_r` never moves.

---

## Confidence ranking

| Hypothesis | Confidence | Evidence |
|---|---|---|
| **H1: structural — slv_apb_* not routed to ctrl_reg_write decoder** | **HIGH** | RTL search exhausts all producers of `ctrl_reg_write` (one assign in `tidelink_apb_regs.sv:443`), driven only by external APB. `slv_apb_*` fan-out is `wl_apb_*` only (L1405-1411). No other path exists. |
| H2: i2c_slave_axil_master ADDR_WIDTH=13 truncates the 0x21 MSB to 0x01 | MEDIUM | Confirmed via parameter math, but is silent here because Region 8 still decodes correctly after truncation. Worth fixing during H1 patch (set ADDR_WIDTH=16). |
| H3: `apb_debug_unlock_i` gate suppresses slave APB writes | LOW | Gate at L1412-1422 only OPENS additional access (external APB write-thru in slave mode); it does not block `slv_apb_active`. Tie-to-0 in production has no effect on the I²C path. |
| H4: `slv_apb_active = slv_apb_psel && !role_is_master` is wedged low | LOW | Sim shows `role_is_master=0` on slave, so the gate is open. Probe will confirm `slv_apb_active` does pulse during the write. |
| H5: I²C-slave core misses the 7-bit device-address ACK | DISPROVEN | Master's FSM transitioned 12→13 (ACK seen), which already disproves this on this branch. |

The probe is expected to show:
- I²C bytes serialised on the bus (scl/sda toggling, slave bus_addressed=1).
- `slv_axil_awvalid` and `slv_apb_psel` BOTH firing (write IS reaching APB).
- `wl_apb_psel` firing on Wlink (the only fan-out).
- **`ctrl_reg_write` NEVER firing on the slave**, **`region8_write` NEVER firing**,
  **`swi_training_mode_r` change-count = 0**.

That fingerprint pins root cause to H1: the slave's I²C APB write hits Wlink
instead of the chiplet-controller Region 8 decoder.

### Probe verification (test_15 run @ HEAD 5a87158)

Probe log (`/tmpdir/.../bkmag3rf4.output`) captures the exact moment the
slave-side AXIL master drives the inbound write, **t=2310480 ns** (cycle
+31949), master in `ST_TRAIN_ENTER` (state 12), txn cycling
TXN_POLL/TXN_CHECK while the I²C transaction completes on the wire:

```
+31949 t=2310480ns | M.st=12 tx=3 axl=5 done=0 bcnt=5 | I2CM.st= 0 mack=0 |
       scl=1 sda=1 (M_t=1/1 S_t=1/1) | I2CS.st= 0 addr=0 busy=1 |
       S.AXIL: aw_v=1 aw_r=1 aw_addr=0x0100 w_v=1 w_d=0x1 b_v=0 |
       S.APB: act=0 sel=0 pen=0 pwr=1 addr=0x021c wd=0x1 |
       S.WL : sel=0 pwr=0 pry=0 addr=0x0000 |
       S.ctrl_w=0 ctrl_addr=0x0 reg8_w=0 swi_tm=0

+31951 t=2310520ns | ... S.AXIL: aw_v=0 aw_r=1 aw_addr=0x0100 w_v=0 w_d=0x1 b_v=0 |
       S.APB: act=1 sel=1 pen=0 pwr=1 addr=0x0100 wd=0x1 |
       S.WL : sel=1 pwr=1 pry=1 addr=0x0100 |
       S.ctrl_w=0 ctrl_addr=0x0 reg8_w=0 swi_tm=0

+31952 t=2310540ns | ... S.APB: act=1 sel=1 pen=1 pwr=1 addr=0x0100 wd=0x1 |
       S.WL : sel=1 pwr=1 pry=1 addr=0x0100 |
       S.ctrl_w=0 ctrl_addr=0x0 reg8_w=0 swi_tm=0
```

Then at **t=2313040 ns** (cycle +32077): `M.state 12 → 13` — master FSM
exits ST_TRAIN_ENTER and advances into ST_TRAIN_RUN (the i2c_master saw
the peer ACK on its TX FIFO drain and pulses `local_train_set_pulse_r`).

**Smoking gun**:

| Signal | Observed | Meaning |
|---|---|---|
| `S.AXIL aw_v=1, aw_addr=0x0100, w_v=1, w_d=0x1` | **YES** for 1 cycle | i2c_slave_axil_master correctly decoded the I²C bytes into an AXIL write of `0x1` (training_value) at AXIL address `0x0100`. |
| `S.APB sel=1, pwrite=1, paddr=0x0100, pwdata=0x1`, `act=1` | **YES** for 2 cycles | The slave AXIL→APB bridge (`mkaxil2apb_bridge`) successfully converted the AXIL write into a single-beat APB write at `paddr=0x100`. |
| `S.WL sel=1, pwr=1, paddr=0x100, pready=1` | **YES** for 2 cycles | The APB write was muxed to Wlink (`wl_apb_*`) and **Wlink immediately PREADY'd it**. |
| `S.ctrl_w`, `reg8_w` | **0 throughout** | The chiplet-controller's Region 8 decoder (which gates `swi_training_mode_r`) was **never** signalled. |
| `swi_training_mode_r` | stuck at `0` | Confirmed Bug N2 endpoint. |

So Wlink accepted the inbound APB write at paddr `0x100` and asserted PREADY
(so the AXIL master sees a clean BVALID and returns to IDLE — the master
i2c_master sees no MISS_ACK, so the FSM proceeds 12→13). But the write
content is now lost inside Wlink (Wlink at offset `0x100` is likely a
benign-side-effect / RAZ-WI register from Wlink's own register map; it
certainly does NOT update the chiplet-controller's SWI_TRAINING_MODE).

The chiplet-controller's `ctrl_reg_write` decoder is fed by `tidelink_apb_regs`,
which itself is driven only by the **external** APB (`apbs_*`, sourced from
the CPU/AHB→APB bridge). The slave-side `slv_apb_*` bus has zero fan-out
into that decoder — so the I²C-driven write to SWI_TRAINING_MODE has no
physical path to reach the register.

### Corroborating evidence — also kills the READ side

Once the master FSM advances to ST_TRAIN_POLL_PEER (state 14) it issues
**reads** of peer's SWI_LANE_STATUS @ 0x2108. The probe captures the
same pathology, from t=2762640 ns onward:

```
+54557 ... M.st=14 ... | S.AXIL aw_v=0 aw_r=1 aw_addr=0x0108 |
       S.APB act=1 sel=1 pen=0 pwr=0 addr=0x0108 wd=0 |
       S.WL sel=1 pwr=0 pry=1 addr=0x0108 |
       S.ctrl_w=0 ctrl_addr=0x0 reg8_w=0 swi_tm=0

+54558 ... | S.APB act=1 sel=1 pen=1 pwr=0 addr=0x0108 wd=0 |
       S.WL sel=1 pwr=0 pry=1 addr=0x0108 ...
```

The READ also hits Wlink at paddr=0x108 (Wlink PREADYs with rdata=0x0),
which is why `peer_lane_locked_r` stays 0x00 across all 15 poll attempts
and the master FSM eventually times out into ST_TRAIN_FAIL. Both
directions (write SWI_TRAINING_MODE, read SWI_LANE_STATUS) require
landing on the chiplet-controller's Region 8 decoder — neither does
today.

### Why post-Bug-N1 nego/mask-handshake works

Bug N1's mask-handshake (states 8/9/10) uses **the master's local APB
to push its own mask** into the master's own Wlink (and then I²C-reads
the peer's mask back). The peer-mask register `link_lane_mask_peer` at
Wlink offset `0x218` lives **inside Wlink's APB space**, so the
peer-side I²C-write of that mask DOES land in the right place — Wlink's
register file. That's why the mask-handshake completes but the
Region-8 training-mode writes (which need to land in
`axi_chiplet_controller`, not Wlink) silently disappear.

This makes the bug class: "any Phase 3 register that the autoneg FSM
expects to be written on the *peer* lives in Region 8 of
`axi_chiplet_controller` — but the I²C-slave's APB ingress is wired
only to Wlink." SWI_TRAINING_MODE @ 0x2100 and SWI_LANE_STATUS @ 0x2108
are the two registers Phase 3 exercises; both are silently broken.

---

## Candidate fix sketch (DO NOT APPLY — for the fix agent)

The slave's `slv_apb_*` must additionally drive (or be muxed into) the
chiplet-controller's internal register-write decode. Two shapes:

- **Shape A (preferred):** Route `slv_apb_*` into a *second* port on
  `tidelink_apb_regs` (or a tiny local decoder) so I²C-driven writes can
  reach Region 4 + Region 8 the same way external APB writes do. Mux
  `ctrl_reg_write` / `ctrl_reg_addr` between the two sources.

- **Shape B:** Decode `slv_apb_paddr[8:5]` inside `axi_chiplet_controller`.
  When `paddr[8]==1` (Region 8) **and** `slv_apb_active` **and**
  `slv_apb_pwrite`, drive `ctrl_reg_write` locally with
  `ctrl_reg_addr={1'b1, slv_apb_paddr[4:2]}` and
  `ctrl_reg_wdata=slv_apb_pwdata`. When `paddr[8]==0` (Region 0..7),
  forward to Wlink as today.

Either way, **also widen `i2c_slave_axil_master` to ADDR_WIDTH=16** (or
mask the 5-bit upper-address truncation by carrying paddr[8] explicitly).
This avoids a latent bug if any future Region 8+ address has paddr[12:8]
bits other than `5'h10` after truncation.

---

## Files touched by this diagnosis

- `cocotb/tidelink_top_pair/test_15_bug_n2_slave_apb_write_probe.py` — new probe
- `docs/BUG_N2_DIAGNOSIS.md` — this file

No RTL touched.
