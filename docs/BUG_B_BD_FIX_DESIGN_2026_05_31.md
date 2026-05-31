# Bug B — BD-Level `phc_nanoseconds` Wiring Fix Design (2026-05-31)

Branch: `fix/bug-b-phc-saturation-build9`
Author: Bug-B parallel agent (sim+BD lane)
Related: `docs/BUG_B_FIX_PLAN_2026_05_29.md`, `docs/BUG_B_FIX_VERIFICATION_2026_05_29.md`,
`docs/BUG_B_PROPOSED_FIX_2026_05_29.patch`

## 1. Why a BD fix is needed even after the RTL patch

The RTL patch on `src/rtl/tidelink_ptp.sv:398-415` adds
`hw_sync_force_en_r` as an OR-term in `phc_time_reached`. That unblocks
the SW recipe `HW_SYNC_CTRL = 0x05` (`force_en | enable`) — the FSM
now leaves `HW_SYNC_ARMED` and the master emits SYNC short packets.

But `force_en = 1` is a **fire-now / bypass-all-gates** knob; if SW
holds it high the FSM re-arms and re-fires every 12-30 hclk cycles
(~3.6 Mpps @ 100 MHz, ~900 kpps @ 25 MHz). The verification doc
(BUG_B_FIX_VERIFICATION_2026_05_29.md §4) measured this on patched RTL.

The **natural time-scheduled path** (`HW_SYNC_CTRL = 0x01`, enable only)
still cannot fire on any target whose BD ties
`phc_nanoseconds = 30'h0`, because then `target_ns_r` (loaded to
`phc_nanoseconds + hw_sync_interval_r` on IDLE→ARMED) is permanently
unreachable.

The fix is to replace the `xlconstant` tie-off cells (`xlconst_phc_ns`,
`xlconst_phc_sec`) with the already-packaged PHC IP
(`soclabs.org:user:phc_vivado_wrapper:1.0`) for every remaining target.

## 2. Current state across targets

```
TARGET                                        PHC WIRING
--------------------------------------------- ------------------
pynq-z2-pair-all                              HAS PHC IP        (reference)
pynq-z2-pair-flip-all                         HAS PHC IP
pynq-z2-pair-flip                             HAS PHC IP
pynq-z2-pair                                  HAS PHC IP
pynq-z2-pair-mmcmbypass-all                   HAS PHC IP
pynq-z2-pair-mmcmbypass-flip-all              HAS PHC IP
pynq-z2-pair-mmcmbypass-oddr-all              HAS PHC IP
pynq-z2-pair-mmcmbypass-oddr-flip-all         HAS PHC IP
--------------------------------------------- ------------------
pynq-z2-single                                TIE-OFF -> needs fix
pynq-z2-loopback                              TIE-OFF -> needs fix
pynq-z2-pair-slow                             TIE-OFF -> needs fix
pynq-z2-pair-flip-slow                        TIE-OFF -> needs fix
pynq-z2-pair-ila                              TIE-OFF -> needs fix
pynq-z2-pair-flip-ila                         TIE-OFF -> needs fix
```

The ILA targets (`pair-ila`, `pair-flip-ila`) are the priority — they
are what bring-up uses for silicon debug, including the Bug B repro.

## 3. Reference recipe — what the working targets do

Drawn from `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`.

### 3.1 Instantiate the PHC IP (the IP is already packaged at
       `fpga/vivado_ip/phc/`, VLNV
       `soclabs.org:user:phc_vivado_wrapper:1.0`)

```tcl
# Replaces the xlconstant tie-offs.
set phc [create_bd_cell -type ip \
    -vlnv soclabs.org:user:phc_vivado_wrapper:1.0 phc_0]
```

### 3.2 Wire counters into tidelink

```tcl
connect_bd_net [get_bd_pins phc_0/nanoseconds_o] \
               [get_bd_pins tidelink_0/phc_nanoseconds]
connect_bd_net [get_bd_pins phc_0/seconds_o] \
               [get_bd_pins tidelink_0/phc_seconds]
connect_bd_net [get_bd_pins phc_0/pps_o] \
               [get_bd_pins tidelink_0/phc_pps]

# HW capture readouts (drive the previously-tied-off cap_* ports)
connect_bd_net [get_bd_pins phc_0/hw_cap_seconds_0_o] \
               [get_bd_pins tidelink_0/phc_hw_cap_seconds]
connect_bd_net [get_bd_pins phc_0/hw_cap_nanoseconds_0_o] \
               [get_bd_pins tidelink_0/phc_hw_cap_nanoseconds]
connect_bd_net [get_bd_pins phc_0/hw_cap_sub_nanoseconds_0_o] \
               [get_bd_pins tidelink_0/phc_hw_cap_sub_nanoseconds]

# Servo phase/freq steer (reverse direction)
connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_time] \
               [get_bd_pins phc_0/hw_set_time_0_i]
connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_seconds] \
               [get_bd_pins phc_0/hw_set_seconds_0_i]
connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_nanoseconds] \
               [get_bd_pins phc_0/hw_set_nanoseconds_0_i]
connect_bd_net [get_bd_pins tidelink_0/phc_hw_adj_valid] \
               [get_bd_pins phc_0/hw_adj_valid_0_i]
connect_bd_net [get_bd_pins tidelink_0/phc_hw_adj_ns_incr_frac] \
               [get_bd_pins phc_0/hw_adj_ns_incr_frac_0_i]

# hw_capture
connect_bd_net [get_bd_pins tidelink_0/phc_hw_capture] \
               [get_bd_pins phc_0/hw_capture_0_i]
```

### 3.3 Clock/reset/APB

```tcl
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins phc_0/clk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins phc_0/resetn]

# A dedicated AXI4-Lite -> APB bridge for the PHC (separate from the
# unified TideLink config APB so the 12-bit address space decodes
# independently).
set phc_apb_bridge [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_apb_bridge:3.0 axi_apb_phc]
set_property -dict [list \
    CONFIG.C_APB_NUM_SLAVES  {1} \
    CONFIG.C_M_APB_PROTOCOL  {apb4} \
] $phc_apb_bridge
connect_bd_intf_net [get_bd_intf_pins axi_apb_phc/APB_M] \
                    [get_bd_intf_pins phc_0/apb]
# AXI-side: extend AXI SmartConnect by one master port and route it here.
```

### 3.4 Address map

```tcl
assign_bd_address \
    -offset 0x44050000 -range 0x00001000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs {phc_0/apb/Reg}]
```

## 4. Per-target TCL diff (declarative, Vivado-tool-ready)

Apply the same edit to each of these six TCLs:

* `fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl`  (priority — ILA bring-up)
* `fpga/targets/pynq-z2-pair-ila/tidelink_design.tcl`
* `fpga/targets/pynq-z2-pair-slow/tidelink_design.tcl`
* `fpga/targets/pynq-z2-pair-flip-slow/tidelink_design.tcl`
* `fpga/targets/pynq-z2-loopback/tidelink_design.tcl`
* `fpga/targets/pynq-z2-single/tidelink_design.tcl`

### 4.1 DELETE the xlconstant cells (lines ~262-300 in each file)

```tcl
# Delete these blocks:
set const_ns [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_ns]
set_property -dict [list CONFIG.CONST_WIDTH {30} CONFIG.CONST_VAL {0}] $const_ns

set const_sec [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_sec]
set_property -dict [list CONFIG.CONST_WIDTH {48} CONFIG.CONST_VAL {0}] $const_sec

# (Optionally keep xlconst_phc_cap_* if hw-cap is not yet wired.)
```

### 4.2 INSERT the PHC IP instance + AXI bridge (after the existing
       IP instantiations, ~line 300):

```tcl
# PHC Hardware Clock IP — replaces phc_nanoseconds / phc_seconds /
# phc_pps tie-offs. See docs/BUG_B_BD_FIX_DESIGN_2026_05_31.md.
set phc [create_bd_cell -type ip \
    -vlnv soclabs.org:user:phc_vivado_wrapper:1.0 phc_0]

set phc_apb_bridge [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_apb_bridge:3.0 axi_apb_phc]
set_property -dict [list \
    CONFIG.C_APB_NUM_SLAVES  {1} \
    CONFIG.C_M_APB_PROTOCOL  {apb4} \
] $phc_apb_bridge
```

### 4.3 REPLACE the `connect_bd_net` lines at ~480 / ~446 / ~512

```diff
- connect_bd_net [get_bd_pins xlconst_phc_ns/dout]  [get_bd_pins tidelink_0/phc_nanoseconds]
- connect_bd_net [get_bd_pins xlconst_phc_sec/dout] [get_bd_pins tidelink_0/phc_seconds]
+ connect_bd_net [get_bd_pins phc_0/nanoseconds_o]  [get_bd_pins tidelink_0/phc_nanoseconds]
+ connect_bd_net [get_bd_pins phc_0/seconds_o]      [get_bd_pins tidelink_0/phc_seconds]
+ connect_bd_net [get_bd_pins phc_0/pps_o]          [get_bd_pins tidelink_0/phc_pps]
+
+ connect_bd_net [get_bd_pins clk_wiz_0/clk_out2]   [get_bd_pins phc_0/clk]
+ connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins phc_0/resetn]
+
+ # Servo phase/freq steer (reverse direction; safe to leave hw_cap_* tied
+ # for ILA targets that don't yet exercise capture).
+ connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_time]      [get_bd_pins phc_0/hw_set_time_0_i]
+ connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_seconds]   [get_bd_pins phc_0/hw_set_seconds_0_i]
+ connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_nanoseconds] [get_bd_pins phc_0/hw_set_nanoseconds_0_i]
+ connect_bd_net [get_bd_pins tidelink_0/phc_hw_adj_valid]     [get_bd_pins phc_0/hw_adj_valid_0_i]
+ connect_bd_net [get_bd_pins tidelink_0/phc_hw_adj_ns_incr_frac] [get_bd_pins phc_0/hw_adj_ns_incr_frac_0_i]
+ connect_bd_net [get_bd_pins tidelink_0/phc_hw_capture]       [get_bd_pins phc_0/hw_capture_0_i]
```

### 4.4 Extend AXI SmartConnect by 1 master port and route to APB bridge

```tcl
# Bump CONFIG.NUM_MI by 1 on the existing axi_smc cell, then
connect_bd_intf_net [get_bd_intf_pins axi_smc/M0N_AXI] \
                    [get_bd_intf_pins axi_apb_phc/AXI4_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_apb_phc/APB_M] \
                    [get_bd_intf_pins phc_0/apb]

# Address segment
assign_bd_address \
    -offset 0x44050000 -range 0x00001000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs {phc_0/apb/Reg}]
```

### 4.5 Update the TCL header comment block

Replace the `NOTE (Q4 / PHC tie-off)` block with the
`NOTE (PHC integration — 2026-05-22 feat/phc-hw-test, ...)` block from
`pair-all/tidelink_design.tcl:42-59`.

## 5. Verification recipe (per target, post-edit)

1. `cd fpga/targets/<target> && make project`  — rebuilds the BD;
   the new connectivity must validate cleanly (`validate_bd_design`).
2. `make bitstream`  — full synth/impl run.
3. On silicon: program NS_INCR=20 before CTRL.EN (FPGA at 50 MHz takes 20-ns
   increments to keep ns wall-time accurate; see PTP_HW_TEST_PLAN.md §7 R2).
4. Repeat the Bug B repro:
   * Write `HW_SYNC_INTERVAL = 1000` (1 µs).
   * Write `HW_SYNC_CTRL = 0x01` (enable only, **no** force_en).
   * Wait 10 µs.
   * Read `HW_SYNC_STATUS` — `hw_seq_num` MUST be incrementing.
   * Read slave `PTP_CTRL @ 0x034` bit[2] — MUST be 1.

## 6. SW saturation note (mandatory mitigation, complement to RTL fix)

With BD wired AND RTL fix applied:

* `HW_SYNC_CTRL = 0x01` (no force_en): SYNC packets emit on the
  `hw_sync_interval_r` cadence. Use this for normal operation.
* `HW_SYNC_CTRL = 0x05` (force_en | enable): SYNC packets emit
  back-to-back at ~3.6 Mpps. **Use as a one-shot only** — write 0x05,
  observe `hw_seq_num` increment, clear to 0x01 (or 0x00) immediately.
  Holding force_en high will saturate the link.

## 7. Sim coverage

A new regression test
`cocotb/tidelink_top_pair/test_bug_b_phc_saturation.py` reproduces both
the BD tie-off symptom (`phc_time_reached` permanently asserted with
force_en, equivalent to BD tie-off + RTL fix only) and the post-fix
healthy behaviour (`phc_time_reached` asserts only when the counter
genuinely reaches the target).

## 8. Sim run logs

### 8.1 RTL-patch non-regression on `cocotb/tidelink_ptp` (full 7-test set)

```
** test_tidelink_ptp.test_hw_sync_enable_disable    PASS         230.00 ns
** test_tidelink_ptp.test_hw_sync_basic_fire        PASS         230.00 ns
** test_tidelink_ptp.test_hw_sync_seq_increment     PASS         520.00 ns
** test_tidelink_ptp.test_hw_sync_seq_clear         PASS         440.00 ns
** test_tidelink_ptp.test_hw_sync_status_readback   PASS         200.00 ns
** test_tidelink_ptp.test_hw_sync_sw_coexistence    PASS         320.00 ns
** test_tidelink_ptp.test_hw_sync_second_rollover   PASS         230.00 ns
** TESTS=7 PASS=7 FAIL=0 SKIP=0                               2170.01 ns
```

Wall-clock: 0.07 s on the host workstation, 2026-05-31 23:28.

### 8.2 New regression `test_bug_b_phc_saturation.py`

Branch: `fix/bug-b-phc-saturation-build9`, RTL commit `11c077c`.
Wall-clock 2026-06-01 00:39 + 00:42.

```
** test_phc_time_reached_saturation_with_tieoff                            PASS  8 563 140 ns  201.5 s
**   post-write probe: hw_sync_en_r=1 hw_sync_force_en_r=1 hw_sync_state_r=3
**   500cy probe: phc_time_reached high=500/500 ARMED=36/500 FIRE=36/500
**   post-arm master HW_SYNC_STATUS=0x000402f7 seq=189 (delta=189)
**   SATURATION SYMPTOM REPRODUCED — RTL patch correct.

** test_phc_time_reached_only_when_counter_genuinely_reaches_target        PASS  8 529 580 ns  201.1 s
**   phase A (counter held @ 500):  phc_time_reached_high=0/200  seq=0
**   phase B (counter bumped 1600): seq=1 (delta=1)
**   phase C (counter held @ 1600): seq 1 -> 1 (delta=0)
**   POST-BD-FIX BEHAVIOUR VALIDATED — natural cadence honours counter.
```

Both tests PASS only on the patched RTL. Test 1 fails (FSM wedges
in ARMED, seq stays 0) on un-patched RTL — it is the explicit
RTL-patch regression witness.

## 9. Out of scope / follow-up

* `mps3` target uses a different naming scheme (`phc_ns_const` not
  `xlconst_phc_ns`); audit + same fix for that target deferred until
  the ASIC bring-up needs PTP wall-clock.
* Removing the residual `xlconst_phc_cap_*` cells (HW capture path is
  optional in the ILA bring-up) — track separately.
* The `force_en` saturation behaviour itself is intentional ("fire
  now, bypass everything"). If SW wants a single-shot semantic, the
  cleanest future RTL improvement is to auto-clear `hw_sync_force_en_r`
  after one fire — but that breaks existing tests that hold force_en
  high deliberately. Defer.
