# Bug A — Cross-Env Static Diff at the FC Adapter Boundary

Date: 2026-05-29 — Static (no sim runs)
Author: cross-env diff agent

## Scope

Single-side unit env `cocotb/tidelink_fc_adapter/` shows **10/10 PASS** on the
fc_adapter. Paired-die integrated env `cocotb/tidelink_top_pair/` shows
`test_08_ahb_packet_master_to_slave` **FAIL** (slave `REG_PKT_WORD_LEN` reads
0, FIFO data reads return 0).

The fc_adapter RTL is identical in both — what changes is the *environment
around it*. This document inventories every boundary signal that is
sourced/sinked differently between the two TBs, so we can localize the
bug class without running anything.

Sources read (static):
- `cocotb/tidelink_fc_adapter/Makefile` + `tb_top.sv` + `test_tidelink_fc_adapter.py`
- `cocotb/tidelink_top_pair/Makefile` + `tb_top.sv` + `test_tidelink_pair_doorbell.py`
- `src/rtl/tidelink_top.sv` (the integrated fc_adapter instance @ line 1115)
- `src/rtl/tidelink_fc_adapter.sv` (the DUT itself)
- `src/rtl/local_overrides/axi_chiplet_controller.sv` (role lock semantics)
- `flist/tidelink_fpga.flist` (the pair env's compile list)

---

## §1 Signal-Level Diff at fc_adapter Boundary

The fc_adapter has **45 distinct boundary signals** (counting bus directions
once). Both envs are formally instantiating the same RTL with identical
parameters (`SYS_ADDR_W=32 SYS_DATA_W=32 RAM_ADDR_W=14 APB_ADDR_W=12
FC_DATA_W=48`). The deltas live in **who drives/sinks each port**.

| fc_adapter port            | Unit env (`tb_top.sv`)                  | Pair env (via `tidelink_top` glue)                |
|----------------------------|------------------------------------------|----------------------------------------------------|
| `hclk`                     | testbench driven                         | shared `hclk` (both DUTs)                          |
| `hresetn`                  | testbench, 5-cy assert                   | testbench, `poresetn` first, then `hresetn` after 5 cy |
| **TX aperture AHB slave**  | testbench AHB master (raw)               | `m_/s_ahb_tx_*` from cocotb signal-level helper    |
| `ahb_tx_haddr` width       | `RAM_ADDR_W=14` (testbench drives 14b)   | `RAM_ADDR_W=14` (`m_ahb_tx_haddr[13:0]`)           |
| `ahb_tx_hready` (in)       | TB drives const `1`                      | **loopback** `m_ahb_tx_hready_loop = m_ahb_tx_hready` (hreadyout fed back in) |
| **Returner AHB slave**     | TB-driven `rtn_*`                        | **driven by `tidelink_returner` inside `axi_chiplet_controller`** — TB cannot touch |
| `rtn_haddr` width          | `SYS_ADDR_W=32` (TB drives full 32b)     | `SYS_ADDR_W=32`, sourced from `returner.ahbm_haddr`; high bits are `TIDELINK_PAIR_BASE=0x44032000` |
| **Servo FC injection**     | tied `valid=0`, `data=0`                 | live from `tidelink_ptp_servo` (gen_servo_real)    |
| **TideChart AXIS TX**      | TB-driven (test #11+ uses it)            | `tc_axis_tx_tvalid=0`, `tc_qos_priority=0`         |
| **TideChart AXIS RX**      | TB sinks                                 | `tc_axis_rx_tready=1`, output dangling             |
| `tc_qos_priority`          | TB sets per-test                         | const `3'h0` both sides                            |
| **PUF SRAM read**          | TB models                                | wired into the FIFO/PUF SRAM inside controller     |
| **FC node TX/RX**          | TB drives `a2l_ready`, sinks; TB drives `l2a_valid` | **goes into `u_chiplet_controller.u_wlink` packed bus** — Wlink FCSM is the consumer |

The first three boldface entries are the entire ground for behavioural
divergence. Everything else is identical at the port level.

### Critical observation: the Returner is gone in the unit env

In `tidelink_top.sv:1048-1049` the `rtn_haddr`/`rtn_hwdata` pair is sourced
from `u_returner.ahbm_*`, i.e. `tidelink_returner.sv`. The returner is the
piece that issues credit-return and doorbell-response SIDEBAND packets *back
to the peer when the local RX consumes a packet*. In the unit env the
testbench drives `rtn_*` synthetically (see `rtn_write()` at line 389).

That makes the returner a **silent dependency** of the test: in the pair env
the returner is the consumer side of a sideband loop — it watches local FC
RX traffic land in the FIFO (via `fc_rx_fifo_*`), and then *responds* to the
peer with a credit/doorbell SIDEBAND. None of that happens in the unit env.

---

## §2 Reset / Clock Diff

### Clocks

| Clock     | Unit env                | Pair env                         |
|-----------|--------------------------|----------------------------------|
| `hclk`    | 10 ns (100 MHz)          | 20 ns (50 MHz)                   |
| `ref_clk` | n/a (not a fc_adapter port) | 8 ns (125 MHz, Wlink PLL ref) |

The fc_adapter is **single-clock on `hclk`** — `ref_clk` only matters because
it feeds the Wlink PLL inside the pair env, and Wlink is what consumes
the fc_adapter's TX FC stream. If `ref_clk` is wrong or wedged on either
side the Wlink FCSM cannot exchange CR/CRACK and so `tl_fc_a2l_ready` never
drains — but Phase 3 of `test_08`'s bringup verifies `cr_pkt_seen_rx` is
high, so Wlink IS clocking. This is **not the cause**.

### Resets

| Reset     | Unit env                                          | Pair env                                        |
|-----------|----------------------------------------------------|-------------------------------------------------|
| `hresetn` | 5-cy assert, 5-cy deassert                         | 20-cy POR window, `poresetn` rises +5cy before `hresetn` (line 320-327 of test) |
| `poresetn`| n/a                                                | feeds Wlink + role_lock_reg only                |

Both reach a clean deasserted state before any traffic is driven. **Not a
plausible bug source.**

---

## §3 Aperture / Address-Map Diff

### TX aperture (CPU → FC TX FIFO_DATA)

Same RTL, same width. Unit env writes addresses 0x0000/0x0004/0x0008…
**directly** as `ahb_tx_haddr[13:0]`. Pair env does the same (cocotb helper
masks with `((1<<14)-1)`). **Identical.**

### Returner address (rtn_haddr) — pair env only

In the pair env the returner sits behind a 32-bit AHB master. The returner
writes to `TIDELINK_PAIR_BASE + offset` where `PAIR_BASE = 0x44032000` (see
`tb_top.sv:64-65`). The fc_adapter extracts `rtn_haddr[13:0]` (line 221 of
`tidelink_fc_adapter.sv`):

```sv
wire [13:0] rtn_addr_offset = rtn_haddr[13:0];
```

So PAIR_BASE bits [31:14] are silently masked off. The unit env writes the
low 14 bits directly and gets identical behaviour. **Not a divergence at the
fc_adapter; the returner upstream is unconfigured in the unit env so this
codepath is not exercised at all there.**

### Slave RX FIFO read aperture (test_08 oracle)

`test_08` reads slave's RX FIFO via `s_ahb_fifo_haddr` with offsets 0x00,
0x04, 0x08, 0x0C. The unit env's `fc_rx_fifo_*` is a synthetic direct-write
port — there is no AHB FIFO read path tested at all. The pair env routes
the RX path through the *actual* TideLink FIFO SRAM + AHB FIFO mux *inside
`u_chiplet_controller`*. This is a real path that the unit env never
exercises.

**This is the first concrete divergence directly bearing on test_08.**

---

## §4 Config-Register / Default Diff

### Role lock / nego_en

- Unit env: no `axi_chiplet_controller`, so no `role_lock` concept at all.
  fc_adapter just runs.
- Pair env: at POR `nego_en=0` and `role_lock_reg=0`. The test explicitly
  drives `APB_ROLE_CFG = 0x2080` with `0x02` (master) and `0x03` (slave) to
  W1S `role_lock_reg` — gated by `mask_hs_bypass_i=1'b1` (tb_top.sv:82-83)
  and `apb_debug_unlock_i=1'b1` (line 78-79). **Both straps tied high → gate
  is open from POR. OK.**

### swi_* / training_mode / SWI_RECAL

- Unit env: irrelevant.
- Pair env: test_08 sequence is full bringup → `do_to_data_mode()` writes
  `slot0=0` (training off) → LL bootstrap `0x27f08/0x27f00/0x27f07` → then
  another `slot0=0` explicit reassert → 200 cy gap → AHB TX. By that point
  Wlink is in data mode and FCSM has latched `cr_pkt_seen_rx=1`.

### PHC / tie-offs

- `phc_locked_i` tied `1'b1` in pair env (line 321, 532). Affects PTP only.
- `tc_qos_priority=0` in pair env on both sides — so the QoS-boost path in
  fc_adapter arbiter (line 362-365 of `tidelink_fc_adapter.sv`) is disabled.
  TX aperture FIFO_DATA wins by default. **OK.**

### Mask handshake bypass

`mask_hs_bypass_i=1'b1` in tb (line 82-83). Without this the role-lock W1S
would be blocked (axi_chiplet_controller line 447 — `mask_hs_gate_open`).
**Equivalent of a "skip autoneg mask" — OK as configured.**

---

## §5 Downstream FC Consumer Diff (the big one)

In the unit env:

```
fc_adapter.tl_fc_a2l_valid -> testbench captures it; tl_fc_a2l_ready forced 1
fc_adapter.tl_fc_l2a_valid <- testbench drives synthetic 48-bit words
fc_adapter.tl_fc_l2a_accept -> testbench monitors
```

i.e. the fc_adapter's FC node is a **loopback to a Python-side queue**. No
flow control, no skid, no CR/CRACK, no PAIR_CREDIT_COUNTER, no FCSM state
machine, no Wlink LL framing, no PHY pads.

In the pair env (tidelink_top.sv:1955-1957):

```
.tidelink_in  ({tl_fc_a2l_valid, tl_fc_a2l_data, tl_fc_l2a_accept}),
.tidelink_out ({tl_fc_a2l_ready, tl_fc_l2a_valid, tl_fc_l2a_data}),
```

The FC port enters `axi_chiplet_controller.u_wlink` — the entire Wlink
TideLink FC node FSM (FCSM) gates the TX side via `tl_fc_a2l_ready` based
on **credit availability**. If the FCSM has `fe_rx_credit_max=0` (the
"PAIR_CREDIT_COUNTER=0" symptom) the peer's TX never advances and the
fc_adapter sits with `tl_fc_a2l_valid=1` indefinitely.

**This is structurally why the unit env cannot catch the bug.** The unit env's
fc_adapter is hand-fed credits implicitly (a2l_ready=1 always). The pair env
exposes the credit-flow-controlled gate.

---

## §6 Top-3 Suspect Deltas (ranked)

### #1 — `tl_fc_a2l_ready` is **gated by Wlink FCSM credit** in pair env, **forced 1** in unit env

This is the dominant structural delta. The fc_adapter passes its unit tests
because the FC TX skid drains unconditionally. Once we put Wlink in front,
TX drain is gated by `fe_rx_credit_max != 0` on the *peer side*, populated
by the CR/CRACK exchange.

`test_07` in the pair test (`test_07_fcsm_rx_credit_max_nonzero_after_bringup`)
is the diagnostic gate for exactly this — if it reports
`fe_rx_credit_max=0x00`, the master's fc_adapter cannot inject FIFO_DATA
words into Wlink, the words sit in the skid forever, and `s_pkt_len`
remains 0. This is a one-to-one match for the observed symptom.

**Why this is most likely the bug class:** memory note
`project_tidelink_sim_repro_2026_05_26` and
`project_tidelink_bug_isolated_2026_05_26` already isolated the bug to the
"tidelink_top wrapper" / "returner/fc_adapter/glue" — *not* Wlink or the
FCSM RTL. The wrapper-level glue around the fc_adapter is what changes
between envs, and the FCSM credit handshake is the load-bearing piece of
that glue.

### #2 — Returner is silent in unit env; in pair env it issues SIDEBAND back to peer

`tidelink_returner` in `axi_chiplet_controller` watches local FIFO writes
(via the AHB master) and issues credit-return + doorbell-response SIDEBANDs
back to the peer. That feedback loop is *entirely absent* from the unit
env (the unit env's `rtn_*` is a TB-driven stub). If the returner is
mis-decoding the slave's `TIDELINK_PAIR_BASE` and writing the wrong 14-bit
offset into the FC sideband, the credit handshake on the *peer* side never
unwedges. This is the source of `fe_rx_credit_max=0`.

Memory `reference_tidelink_address_map` confirms this class is real: "Peer
aperture is 0x40000000 (ahb_sub); 0x44010000 is LOCAL RX FIFO". If the
returner writes a 0x40… vs 0x44… aperture and the fc_adapter's `[13:0]`
extraction silently aliases, the SIDEBAND `addr_offset` no longer matches
the peer's expected RELEASED_ACC / DOORBELL_RESP_ACC register offset.

### #3 — Synthetic RX FIFO consumer in unit env vs real `fc_rx_fifo_mux` + AHB read path in pair env

`test_08`'s pass criterion is reading the slave's FIFO via AHB. The unit
env never exercises this — its `fc_rx_fifo_*` is a synthetic direct-write
monitor. In the pair env the slave RX FIFO write goes through the actual
FIFO SRAM + AHB read mux inside `u_chiplet_controller`. A bug in the FIFO
write-pointer maintenance or the address-decode of the AHB FIFO read port
would show up only here. Lower likelihood than #1 because if credits never
arrived in the first place (#1), the FIFO is empty regardless — #3 only
becomes the dominant cause if #1 is falsified.

---

## §7 Falsification Plan for #1

**Hypothesis:** `tl_fc_a2l_ready` is held low on the master in test_08
because the FCSM `fe_rx_credit_max` is 0 on the master (peer/slave never
issues a CR packet that lands).

### Plan (static analysis only — no sim runs requested by parent agent)

**Step 1 — Confirm test_07 passes or fails in the same run as test_08.**
If `test_07` (FCSM `fe_rx_credit_max` non-zero) already passes, hypothesis
#1 is falsified, drop to #2. If it fails, #1 is confirmed.

**Step 2 — Probe `tl_fc_a2l_valid` and `tl_fc_a2l_ready` on master across the
2000 cy `watch_fc_pulses("post AHB TX M→S")` window in test_08.**
- `m_a2l > 0, s_l2a > 0`: data crossed — bug is in slave RX FIFO write
  (drops to #3).
- `m_a2l > 0, s_l2a == 0`: TX submitted but never landed (PHY / Wlink RX).
- `m_a2l == 0`: fc_adapter cannot drain — #1 confirmed at the boundary.

The pair-env testbench already prints these counts on failure (line 909+
of `test_tidelink_pair_doorbell.py`). The next sim run should record the
M/S a2l/l2a counts at test_08 failure point.

**Step 3 — If `m_a2l == 0`, hierarchically probe master's `fe_rx_credit_max`
just before the AHB TX write.**
- `0` → confirms #1; the CR/CRACK exchange did populate `cr_pkt_seen_rx`
  but not the actual credit count. Bug is the symptom from build #3 HW.
- non-zero → fc_adapter is wedged for a different reason (returner / skid).

**Step 4 — Static cross-check the returner-side credit injection.**
Read `src/rtl/fifo/tidelink_returner.sv` and verify the address bits it
drives onto `rtn_haddr` — if the high bits matter for any internal decode
(they should not, only `[13:0]` is consumed by fc_adapter), this is the
return-feedback misroute that explains the missing credit replenishment.

### Concrete next action for the parent agent

Run `make MODULE=test_tidelink_pair_doorbell TESTCASE=test_07` and capture
the logged `fe_rx_credit_max` value on both dies. That is a 5-minute sim
that decisively gates #1 vs #2. The decision tree above then dictates the
next probe.

---

## Appendix — File:Line References Used

- `cocotb/tidelink_fc_adapter/Makefile:7-15` — flist of unit env (just
  `tidelink_fc_adapter.sv` + TB).
- `cocotb/tidelink_top_pair/Makefile:23` — `-f flist/tidelink_fpga.flist`
  (full integrated DUT).
- `cocotb/tidelink_fc_adapter/tb_top.sv:130-132` — TX TB drives `a2l_ready=1`.
- `cocotb/tidelink_top_pair/tb_top.sv:142-143` — AHB hready loopback.
- `cocotb/tidelink_top_pair/tb_top.sv:78-79,82-83` — `apb_debug_unlock_i`
  and `mask_hs_bypass_i` tied `1'b1`.
- `cocotb/tidelink_top_pair/tb_top.sv:321,532` — `phc_locked_i=1'b1`.
- `cocotb/tidelink_top_pair/tb_top.sv:344-350,552-558` — `tc_axis_tx`
  tied off, `tc_qos_priority=0`.
- `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py:858-921` —
  test_08 body.
- `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py:793-855` —
  test_07 FCSM credit probe.
- `src/rtl/tidelink_top.sv:1115-1194` — fc_adapter instance.
- `src/rtl/tidelink_top.sv:1955-1957` — FC node into Wlink.
- `src/rtl/tidelink_fc_adapter.sv:175-204` — TX aperture FC word formation.
- `src/rtl/tidelink_fc_adapter.sv:218-247` — Returner SIDEBAND formation.
- `src/rtl/tidelink_fc_adapter.sv:380-399` — Skid drain gated by
  `tl_fc_a2l_ready`.
- `src/rtl/local_overrides/axi_chiplet_controller.sv:427-465` —
  role_lock W1S gate.

---
