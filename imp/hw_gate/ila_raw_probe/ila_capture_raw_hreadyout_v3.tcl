# ila_capture_raw_hreadyout_v3.tcl -- round 3 of the die_a xhb_sub_hreadyout_raw
# capture (2026-08-13).
#
# WHAT V1 AND V2 GOT WRONG, so it is not repeated:
#
#  V1 (= the inherited ila_capture_tl035.tcl behaviour) ONLY force-captures.
#     `run_hw_ila -trigger_now` RE-ARMS the core, so a window the trigger had
#     already captured is DISCARDED unread. Its result was a wrapper that is
#     completely idle (wr_hold_r=0, sub_stall_ctr_r=0, 0 transitions on all 14
#     probes) roughly a minute after the stimulus -- VOID against the
#     pre-registered guard, which requires wr_hold_r=1 and a real counter ramp.
#
#  V2 tried to detect a trigger with `wait_on_hw_ila -timeout 1`. That call
#     RETURNED IMMEDIATELY AND SUCCESSFULLY on a core that had not triggered
#     (stale/idle status), the subsequent upload logged
#     `WARNING: [Labtools 27-157] hw_ila stopped. No data to upload.` and wrote a
#     2-line header-only CSV -- and the harness reported "TRIGGER FIRED". A
#     status-shaped answer that is not backed by data is exactly the kind of
#     false positive this campaign cannot afford. Worse, poking the core that
#     early may itself have stopped it, leaving nothing armed for the stimulus.
#
# V3 THEREFORE:
#   * touches the core ONCE to arm it and then NOT AGAIN until the shell says the
#     stimulus is over -- no status reads, no waits, no uploads in between;
#   * decides "did the trigger fire?" from CONTENT, not status: it uploads, writes
#     the CSV, and calls it a real capture only if the file is substantially
#     larger than the ~3.3 KB header-only file V2 produced;
#   * still force-captures afterwards, so a HELD wedge is read faithfully even if
#     the trigger never fires.
#
# Outputs:
#   /tmp/ila_capture_trig.csv -- the TRIGGERED window (wr_hold_r == 1), if any
#   /tmp/ila_capture.csv      -- the forced window (current frozen state)
#   /tmp/ila_trigged          -- touched ONLY when the triggered CSV has real data

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

if {[catch { set_property CONTROL.TRIGGER_POSITION 512 $ila } e]} { puts "TRIGPOS_WARN: $e" }
if {[catch { set_property CONTROL.DATA_DEPTH 4096 $ila } e]} { puts "DEPTH_WARN: $e" }

# *wr_hold_r* is unique to probe27. (*hreadyout* would match BOTH
# dbg_tx_hreadyout and xhb_sub_hreadyout_raw -- every glob here is anchored on a
# substring unique to its intended net.)
set tp [get_hw_probes -quiet *wr_hold_r* -of_objects $ila]
if {$tp eq ""} { fail "wr_hold_r probe absent -- cannot arm the registered trigger" }
if {[catch { set_property TRIGGER_COMPARE_VALUE eq1'b1 [lindex $tp 0] } e]} {
  fail "trigger set: $e"
}
puts "ILA_TRIGGER: wr_hold_r == 1 (on [lindex $tp 0])"

if {[catch { run_hw_ila $ila } err]} { fail "arm: $err" }
puts "ILA_ARMED (hands off the core until /tmp/do_capture)"
exec sh -c "touch /tmp/ila_armed"

# ---- hands off. Poll only the filesystem. ---------------------------------
set got 0
for {set i 0} {$i < 400} {incr i} { if {[file exists /tmp/do_capture]} { set got 1; break }; after 1000 }
puts "DO_CAPTURE=$got after ${i}s"

# ---- did the trigger fire? Decide from CONTENT, not status. ---------------
set trigged 0
set tsize -1
if {[catch { upload_hw_ila_data $ila } ue]} {
  puts "TRIG_UPLOAD_NOTE: $ue"
} else {
  if {[catch { write_hw_ila_data -csv_file $CSVT [current_hw_ila_data] } we]} {
    puts "TRIG_WRITE_NOTE: $we"
  } else {
    set tsize [file size $CSVT]
    # V2's header-only artefact was ~3.3 KB; a real 4096-sample window is ~360 KB.
    if {$tsize > 20000} { set trigged 1; exec sh -c "touch /tmp/ila_trigged" }
  }
}
puts "TRIGGERED=$trigged TRIG_CSV_BYTES=$tsize"

# ---- always force-capture as well ----------------------------------------
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
puts "CAPTURE_DONE csv=$CSV trigged=$trigged"
