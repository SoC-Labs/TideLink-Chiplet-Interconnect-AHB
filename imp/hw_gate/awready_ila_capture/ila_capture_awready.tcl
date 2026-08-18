# ila_capture_awready.tcl -- die_a (tidelink_0) AW-node wedge capture (2026-08-18).
# Adapted from ila_capture_raw_hreadyout_v3.tcl (its V1/V2 lessons preserved):
#   * arm the core ONCE, then HANDS OFF until the shell touches /tmp/do_capture
#     (no status reads / waits / uploads in between -- those re-arm or stop it);
#   * decide "did the trigger fire?" from CSV CONTENT (size), not status
#     (CORE_STATUS is not a property on hw_ila in Vivado 2025.2);
#   * ALWAYS force-capture too -- the awready wedge is HELD (persistent until POR),
#     so the frozen state is read faithfully even if the edge trigger is missed.
#
# Trigger = the MECHANISM-AGNOSTIC symptom on die_a: s_axi_awvalid==1 & s_axi_awready==0
# (a write is offered but the AW-node won't accept it). Fires for H1, H2, or any cause.
# ahb_sub_hreadyout (PS-facing hang) is captured too as a corroborator, not the trigger.
#
# Outputs on mapstone-dev:
#   /tmp/ila_awready_trig.csv -- the TRIGGERED window (awvalid&~awready), if any
#   /tmp/ila_awready.csv      -- the forced window (current frozen wedge state)
#   /tmp/ila_trigged          -- touched ONLY when the triggered CSV has real data

set TGT localhost:3121/xilinx_tcf/Xilinx/XFL1MHS3ZB1PA
set LTX /tmp/tidelink_design_wrapper.ltx
set CSV /tmp/ila_awready.csv
set CSVT /tmp/ila_awready_trig.csv
file delete -force /tmp/ila_armed /tmp/ila_done /tmp/ila_fail /tmp/do_capture \
                   /tmp/ila_trigged $CSV $CSVT
proc fail {msg} { puts "ILA_FAIL: $msg"; exec sh -c "echo '$msg' > /tmp/ila_fail"; exit 1 }

if {[catch {
  open_hw_manager
  connect_hw_server -url localhost:3121
  current_hw_target [get_hw_targets $TGT]
  set_property PARAM.FREQUENCY 2000000 [current_hw_target]
  open_hw_target
} err]} { fail "connect/open: $err" }

set dev ""
foreach d [get_hw_devices] { if {[string match -nocase *xck26* $d]} { set dev $d } }
if {$dev eq ""} { set dev [lindex [get_hw_devices] end] }
current_hw_device $dev
puts "ILA_DEV: $dev"

if {[catch {
  set_property PROBES.FILE      $LTX $dev
  set_property FULL_PROBES.FILE $LTX $dev
  refresh_hw_device $dev
} err]} { fail "refresh: $err" }

set ila [lindex [get_hw_ilas -quiet -of_objects $dev] 0]
if {$ila eq ""} { fail "no ILA on device" }
puts "ILA_CORE: $ila"

set allp [get_hw_probes -quiet -of_objects $ila]
puts "ILA_PROBE_COUNT: [llength $allp]"
# Presence check on the die_a decode + symptom set (anchored on tidelink_0 so we
# never accidentally read tidelink_1's copy).
foreach want {s_axi_awvalid s_axi_awready ahb_sub_hreadyout a2l_full \
              ack_nack_fifo_io_rdata ack_nack_fifo_io_rempty isAckPacket isNackPacket \
              crcCorruptSeen swi_enable state socl_l7_wdog_cnt link_addr_to_app_clk} {
  set p [get_hw_probes -quiet *tidelink_0*${want}* -of_objects $ila]
  if {$p eq ""} { puts "ILA_PROBE_MISSING: $want" } else { puts "ILA_PROBE_OK: $want ([llength $p])" }
}

# 1/8 pre-trigger (512 of 4096) -> ~3584 post-trigger, per the plan (this wedge may
# run long; front-loading loses the tail).
if {[catch { set_property CONTROL.TRIGGER_POSITION 512 $ila } e]} { puts "TRIGPOS_WARN: $e" }
if {[catch { set_property CONTROL.DATA_DEPTH 4096 $ila } e]} { puts "DEPTH_WARN: $e" }

# ---- Trigger: die_a s_axi_awvalid==1 AND s_axi_awready==0 (basic AND of the two).
# Each glob MUST resolve to exactly ONE probe (tidelink_0 only) -- assert it.
set pv [get_hw_probes -quiet *tidelink_0*s_axi_awvalid -of_objects $ila]
set pr [get_hw_probes -quiet *tidelink_0*s_axi_awready -of_objects $ila]
if {[llength $pv] != 1} { fail "awvalid glob matched [llength $pv] probes (need 1): $pv" }
if {[llength $pr] != 1} { fail "awready glob matched [llength $pr] probes (need 1): $pr" }
if {[catch {
  set_property TRIGGER_COMPARE_VALUE eq1'b1 [lindex $pv 0]
  set_property TRIGGER_COMPARE_VALUE eq1'b0 [lindex $pr 0]
} e]} { fail "trigger set: $e" }
puts "ILA_TRIGGER: (awvalid==1 & awready==0) on die_a  [lindex $pv 0] / [lindex $pr 0]"

if {[catch { run_hw_ila $ila } err]} { fail "arm: $err" }
puts "ILA_ARMED (hands off the core until /tmp/do_capture)"
exec sh -c "touch /tmp/ila_armed"

# ---- hands off. Poll only the filesystem for the shell's stimulus-over signal. --
set got 0
for {set i 0} {$i < 900} {incr i} { if {[file exists /tmp/do_capture]} { set got 1; break }; after 1000 }
puts "DO_CAPTURE=$got after ${i}s"

# ---- did the edge trigger fire? Decide from CONTENT (file size), not status. -----
set trigged 0
set tsize -1
if {[catch { upload_hw_ila_data $ila } ue]} {
  puts "TRIG_UPLOAD_NOTE: $ue"
} else {
  if {[catch { write_hw_ila_data -csv_file $CSVT [current_hw_ila_data] } we]} {
    puts "TRIG_WRITE_NOTE: $we"
  } else {
    set tsize [file size $CSVT]
    if {$tsize > 20000} { set trigged 1; exec sh -c "touch /tmp/ila_trigged" }
  }
}
puts "TRIGGERED=$trigged TRIG_CSV_BYTES=$tsize"

# ---- always force-capture the HELD wedge state as well ----------------------------
if {[catch { run_hw_ila -trigger_now $ila } e1]} { puts "TRIGGER_NOW_WARN: $e1" }
if {[catch { wait_on_hw_ila -timeout 2 $ila } e2]} { puts "WAIT_WARN: $e2" }
if {[catch {
  upload_hw_ila_data $ila
  write_hw_ila_data -csv_file $CSV [current_hw_ila_data]
} err]} { fail "upload/write: $err" }
exec sh -c "touch /tmp/ila_done"
puts "CAPTURE_DONE csv=$CSV trigged=$trigged"
