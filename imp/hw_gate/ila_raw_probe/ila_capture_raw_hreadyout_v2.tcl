# ila_capture_raw_hreadyout_v2.tcl -- round 2 of the die_a xhb_sub_hreadyout_raw
# capture (2026-08-13).
#
# WHY A V2. Round 1 produced a window in which wr_hold_r was 0 across all 4096
# samples and sub_stall_ctr_r never left 0 -- i.e. NOT the wedge state -- so it
# was VOID on the pre-registered vacuity guard, even though the design was
# demonstrably live (dbg_fcsm_state=4, dbg_cr_seen=1 on every sample) and
# xhb_sub_hreadyout_raw read 1 (the "convenient" P2 value).
#
# The structural defect in round 1 (inherited from ila_capture_tl035.tcl): it
# ONLY ever force-captures. `run_hw_ila -trigger_now` RE-ARMS the core, so if the
# trigger HAD fired earlier while armed, that triggered window is DISCARDED
# unread and replaced by the current state. A transient wedge -- one that sets
# wr_hold_r, hangs the PS, and then lets the wrapper drain while the PS stays
# hung -- is therefore invisible to it: you get a recovered wrapper and no way
# to tell that from a wedge that never happened.
#
# V2 CAPTURES BOTH WINDOWS:
#   /tmp/ila_capture_trig.csv  -- the TRIGGERED window (wr_hold_r == 1), uploaded
#                                 BEFORE any re-arm. This is the window that can
#                                 answer the question at the wedge.
#   /tmp/ila_capture.csv       -- the forced window (frozen current state), the
#                                 round-1 behaviour, kept as the fallback that
#                                 reads a HELD wedge faithfully.
# /tmp/ila_trigged is touched as soon as the trigger fires, so the driving shell
# can tell "wedge captured" from "stimulus produced no wr_hold_r" WHILE the board
# is still able to take more stimulus.
#
# NOTE on wait_on_hw_ila: its -timeout is in MINUTES, so the trigger poll below
# has ~1-minute granularity. That is why the shell touches /tmp/do_capture and
# then waits patiently rather than assuming an instant response.

set TGT localhost:3121/xilinx_tcf/Xilinx/XFL1MHS3ZB1PA
set LTX /tmp/tidelink_design_wrapper.ltx
set CSV /tmp/ila_capture.csv
set CSVT /tmp/ila_capture_trig.csv
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
foreach want {xhb_sub_hreadyout_raw sub_stall_busy sub_stall_ctr_r wr_hold_r \
              sub_rd_os_r synth_b_pending sub_err1_r sub_err2_r ext_is_nonseq \
              pipe_valid_r rd_pipe_r sub_wr_os_ctr dbg_fcsm_state dbg_cr_seen} {
  set p [get_hw_probes -quiet *${want}* -of_objects $ila]
  if {$p eq ""} { puts "ILA_PROBE_MISSING: $want" } else { puts "ILA_PROBE_OK: $want ([llength $p])" }
}

if {[catch { set_property CONTROL.TRIGGER_POSITION 1024 $ila } e]} { puts "TRIGPOS_WARN: $e" }
if {[catch { set_property CONTROL.DATA_DEPTH 4096 $ila } e]} { puts "DEPTH_WARN: $e" }

# *wr_hold_r* is unique to probe27; nothing else in the 34-probe set contains it.
# (*hreadyout* would match BOTH dbg_tx_hreadyout and xhb_sub_hreadyout_raw --
# every glob here is anchored on a substring unique to its intended net.)
set tp [get_hw_probes -quiet *wr_hold_r* -of_objects $ila]
if {$tp ne ""} {
  if {[catch { set_property TRIGGER_COMPARE_VALUE eq1'b1 [lindex $tp 0] } e]} {
    puts "TRIGGER_SET_WARN: $e"
  } else { puts "ILA_TRIGGER: wr_hold_r == 1 (on [lindex $tp 0])" }
} else {
  puts "ILA_TRIGGER: NONE (wr_hold_r probe absent) -- force-capture only"
}

if {[catch { run_hw_ila $ila } err]} { fail "arm: $err" }
puts "ILA_ARMED (trigger armed; awaiting wr_hold_r==1 or /tmp/do_capture)"
exec sh -c "touch /tmp/ila_armed"

# ---- poll for a REAL trigger, ~1 minute per iteration ----------------------
set trigged 0
for {set i 0} {$i < 10} {incr i} {
  if {![catch { wait_on_hw_ila -timeout 1 $ila } e]} { set trigged 1; break }
  if {[file exists /tmp/do_capture]} { break }
}
puts "TRIGGERED=$trigged (after [expr {$i+1}] poll(s))"

if {$trigged} {
  # Upload the TRIGGERED window BEFORE anything re-arms the core.
  if {[catch {
    upload_hw_ila_data $ila
    write_hw_ila_data -csv_file $CSVT [current_hw_ila_data]
  } err]} { puts "TRIG_UPLOAD_WARN: $err" } else {
    puts "TRIG_CSV_WRITTEN: $CSVT"
    exec sh -c "touch /tmp/ila_trigged"
  }
}

# ---- wait for the shell's go-ahead, then ALWAYS force-capture --------------
set got 0
for {set i 0} {$i < 300} {incr i} { if {[file exists /tmp/do_capture]} { set got 1; break }; after 1000 }
puts "DO_CAPTURE=$got"

# Do NOT gate this on get_property CORE_STATUS: that property does not exist on
# hw_ila in Vivado 2025.2 and an UNGUARDED read aborts the script
# (Labtoolstcl 44-155) before the capture ever happens.
if {[catch { run_hw_ila -trigger_now $ila } e1]} { puts "TRIGGER_NOW_WARN: $e1" }
if {[catch { wait_on_hw_ila -timeout 2 $ila } e2]} { puts "WAIT_WARN: $e2" }
if {[catch {
  upload_hw_ila_data $ila
  write_hw_ila_data -csv_file $CSV [current_hw_ila_data]
} err]} { fail "upload/write: $err" }
if {[catch { puts "TRIG_STATUS: [get_property CORE_STATUS $ila]" } e3]} {
  puts "TRIG_STATUS: unavailable (CORE_STATUS not a property on this hw_ila)"
}
exec sh -c "touch /tmp/ila_done"
puts "CAPTURE_DONE csv=$CSV trig_csv=[expr {$trigged ? $CSVT : {none}}]"
