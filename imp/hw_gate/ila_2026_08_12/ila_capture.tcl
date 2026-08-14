# ila_capture.tcl (v2) -- mapstone-dev Vivado 2025.2 hw_manager.
# Opens die_a JTAG, loads .ltx, arms the ILA, signals ARMED, then WAITS for the host to
# confirm the wedge (/tmp/do_capture) and FORCE-captures the persistent frozen state (no
# trigger dependency; the wedge is held with NO POR so the debug hub stays alive). Writes CSV.
set TGT localhost:3121/xilinx_tcf/Xilinx/XFL1MHS3ZB1PA
set LTX /tmp/tidelink_design_wrapper.ltx
set CSV /tmp/ila_capture.csv
file delete -force /tmp/ila_armed /tmp/ila_done /tmp/ila_fail /tmp/do_capture $CSV
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
# arm continuously (any trigger; we FORCE-capture after the wedge is confirmed)
set_property CONTROL.TRIGGER_POSITION 2048 $ila
set_property CONTROL.DATA_DEPTH 4096 $ila
set wp [get_hw_probes -quiet *dbg_a2l_wedged* -of_objects $ila]
if {$wp ne ""} { catch { set_property TRIGGER_COMPARE_VALUE eq1'b1 [lindex $wp 0] } }
if {[catch { run_hw_ila $ila } err]} { fail "arm: $err" }
puts "ILA_ARMED (awaiting /tmp/do_capture)"
exec sh -c "touch /tmp/ila_armed"
# wait for the host to confirm the wedge (die_a hung) and request the force-capture
set got 0
for {set i 0} {$i < 200} {incr i} { if {[file exists /tmp/do_capture]} { set got 1; break }; after 1000 }
puts "DO_CAPTURE=$got"
# FORCE an immediate capture of the current (frozen-wedge) window, whether or not any trigger fired
if {[catch { run_hw_ila -trigger_now $ila } e1]} { puts "TRIGGER_NOW_WARN: $e1" }
if {[catch { wait_on_hw_ila -timeout 40 $ila } e2]} { puts "WAIT_WARN: $e2" }
if {[catch {
  upload_hw_ila_data $ila
  write_hw_ila_data -csv_file $CSV [current_hw_ila_data]
} err]} { fail "upload/write: $err" }
puts "TRIG_STATUS: [get_property CORE_STATUS $ila]"
exec sh -c "touch /tmp/ila_done"
puts "CAPTURE_DONE csv=$CSV"
