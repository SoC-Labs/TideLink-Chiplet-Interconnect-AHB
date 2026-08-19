# ila_capture_wnode.tcl -- die_a W-NODE wedge capture (2026-08-19, debug bitstream).
# Successor to ila_capture_awready.tcl. Same proven structure (arm ONCE, hands off
# until /tmp/do_capture, decide "triggered?" from CSV CONTENT not status, ALWAYS
# force-capture because the wedge is HELD).
#
# WHY A NEW TRIGGER: the previous capture's trigger (awvalid & ~awready) never
# fired -- awready is HIGH throughout. This build probes the W channel, which the
# diagnosis deduced is the starved one. Trigger is deliberately the SYMPTOM plus
# activity, NOT the hypothesis: (ahb_sub_hreadyout==0 && s_axi_wvalid==1) fires for
# W-node-full, XHB500-starved, or any other cause, and cannot false-fire on idle.
set TGT localhost:3121/xilinx_tcf/Xilinx/XFL1MHS3ZB1PA
set LTX /tmp/tidelink_wnode.ltx
set CSV /tmp/ila_wnode.csv
set CSVT /tmp/ila_wnode_trig.csv
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
if {[catch { set_property PROBES.FILE $LTX $dev
             set_property FULL_PROBES.FILE $LTX $dev
             refresh_hw_device $dev } err]} { fail "refresh: $err" }

set ila [lindex [get_hw_ilas -quiet -of_objects $dev] 0]
if {$ila eq ""} { fail "no ILA on device" }
puts "ILA_CORE: $ila  PROBES: [llength [get_hw_probes -quiet -of_objects $ila]]"

# Presence check, die_a only. NOTE the W-node glob: "axiwFC" is NOT a substring of
# "axiawFC", so *axiwFC* selects the W node cleanly.
foreach want {s_axi_wready s_axi_wvalid s_axi_wlast ahb_sub_hreadyout \
              wlink_axiwFC*a2l_full wlink_axiawFC*a2l_full \
              sub_stall_ctr_r sub_osr_ctr_r wr_hold_r synth_b_pending \
              xhb_sub_hreadyout_raw sub_wr_os_ctr ahb_sub_htrans dbg_freerun_ctr} {
  set p [get_hw_probes -quiet *tidelink_0*${want}* -of_objects $ila]
  if {$p eq ""} { puts "ILA_PROBE_MISSING: $want" } else { puts "ILA_PROBE_OK: $want ([llength $p])" }
}

# 50% pre-trigger: bracket the event with context on BOTH sides (handback 5.2).
if {[catch { set_property CONTROL.TRIGGER_POSITION 2048 $ila } e]} { puts "TRIGPOS_WARN: $e" }
if {[catch { set_property CONTROL.DATA_DEPTH 4096 $ila } e]} { puts "DEPTH_WARN: $e" }

set ph [get_hw_probes -quiet *tidelink_0*ahb_sub_hreadyout -of_objects $ila]
set pw [get_hw_probes -quiet *tidelink_0*s_axi_wvalid     -of_objects $ila]
if {[llength $ph] != 1} { fail "hreadyout glob matched [llength $ph]: $ph" }
if {[llength $pw] != 1} { fail "wvalid glob matched [llength $pw]: $pw" }
if {[catch { set_property TRIGGER_COMPARE_VALUE eq1'b0 [lindex $ph 0]
             set_property TRIGGER_COMPARE_VALUE eq1'b1 [lindex $pw 0] } e]} { fail "trigger set: $e" }
puts "ILA_TRIGGER: (ahb_sub_hreadyout==0 & s_axi_wvalid==1) on die_a"

if {[catch { run_hw_ila $ila } err]} { fail "arm: $err" }
puts "ILA_ARMED (hands off until /tmp/do_capture)"
exec sh -c "touch /tmp/ila_armed"

set got 0
for {set i 0} {$i < 900} {incr i} { if {[file exists /tmp/do_capture]} { set got 1; break }; after 1000 }
puts "DO_CAPTURE=$got after ${i}s"

set trigged 0; set tsize -1
if {[catch { upload_hw_ila_data $ila } ue]} { puts "TRIG_UPLOAD_NOTE: $ue" } else {
  if {[catch { write_hw_ila_data -csv_file $CSVT [current_hw_ila_data] } we]} {
    puts "TRIG_WRITE_NOTE: $we" } else {
    set tsize [file size $CSVT]
    if {$tsize > 20000} { set trigged 1; exec sh -c "touch /tmp/ila_trigged" } } }
puts "TRIGGERED=$trigged TRIG_CSV_BYTES=$tsize"

if {[catch { run_hw_ila -trigger_now $ila } e1]} { puts "TRIGGER_NOW_WARN: $e1" }
if {[catch { wait_on_hw_ila -timeout 2 $ila } e2]} { puts "WAIT_WARN: $e2" }
if {[catch { upload_hw_ila_data $ila
             write_hw_ila_data -csv_file $CSV [current_hw_ila_data] } err]} { fail "upload/write: $err" }
exec sh -c "touch /tmp/ila_done"
puts "CAPTURE_DONE csv=$CSV trigged=$trigged"
