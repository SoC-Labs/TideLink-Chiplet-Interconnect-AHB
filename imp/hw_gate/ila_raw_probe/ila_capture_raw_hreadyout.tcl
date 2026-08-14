# ila_capture_raw_hreadyout.tcl -- die_a capture of xhb_sub_hreadyout_raw at the
# TL-042 wedge (2026-08-13).
#
# Adapted from imp/hw_gate/ila_capture_tl035.tcl, which is PROVEN to capture
# through the PS deadlock (it produced the round-2 result). Three changes:
#
#  1. PROBE NAMES. The tl035 script globs for `dbg_*`-prefixed probes
#     (dbg_ahb_sub_hreadyout, dbg_wr_hold_r, ...). Those DO NOT EXIST in this
#     build: the 34 probes here are named by their RTL net names under
#     tidelink_design_i/nanosoc_eth_chiplet_0/inst/u_chiplet/u_tidelink/.
#     Globbing for a name that is not there yields an empty probe list, an
#     absent trigger, and a capture that cannot answer the question.
#
#  2. TRIGGER = wr_hold_r == 1 (the wedge state) instead of
#     dbg_ahb_sub_hreadyout == 0 (that probe is absent here). NOTE the glob
#     hazard: *hreadyout* matches BOTH dbg_tx_hreadyout AND
#     xhb_sub_hreadyout_raw, so every glob below is anchored on a substring
#     unique to its intended net.
#
#  3. The force-capture fallback is KEPT, deliberately. At a HELD wedge the
#     probed signals are STATIC, so a forced window reads the frozen state
#     faithfully -- which is exactly what the top-level question needs. If the
#     trigger also fires we additionally get the approach to the wedge.
#
# THE QUESTION THIS ANSWERS (see PREREG_RAW_HREADYOUT_PROBE_2026_08_13.md):
#   xhb_sub_hreadyout_raw == 0 at the wedge (P1) -> XHB500 stalls INDEPENDENTLY
#     of the wrapper hold; clearing wr_hold_r cannot raise ahb_sub_hreadyout, so
#     TL-042 v2 is NECESSARY BUT NOT SUFFICIENT.
#   xhb_sub_hreadyout_raw == 1 at the wedge (P2) -> the derivation is wrong, the
#     mux-priority reading stands, v2 is a COMPLETE fix. Be MOST sceptical here:
#     it is the convenient outcome. Check the vacuity guard before believing it.

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

# Report what we actually got. A missing probe must be caught HERE and not after
# the run, when the CSV turns out not to contain the one signal the test is about.
set allp [get_hw_probes -quiet -of_objects $ila]
puts "ILA_PROBE_COUNT: [llength $allp]"
# The 12 TL-042 probes + the two known-live cross-check signals the vacuity
# guard calls for (dbg_fcsm_state == 4 / dbg_cr_seen == 1, as round-1 used).
foreach want {xhb_sub_hreadyout_raw sub_stall_busy sub_stall_ctr_r wr_hold_r \
              sub_rd_os_r synth_b_pending sub_err1_r sub_err2_r ext_is_nonseq \
              pipe_valid_r rd_pipe_r sub_wr_os_ctr dbg_fcsm_state dbg_cr_seen} {
  set p [get_hw_probes -quiet *${want}* -of_objects $ila]
  if {$p eq ""} { puts "ILA_PROBE_MISSING: $want" } else { puts "ILA_PROBE_OK: $want ([llength $p])" }
}

if {[catch { set_property CONTROL.TRIGGER_POSITION 1024 $ila } e]} { puts "TRIGPOS_WARN: $e" }
if {[catch { set_property CONTROL.DATA_DEPTH 4096 $ila } e]} { puts "DEPTH_WARN: $e" }

# TRIGGER on wr_hold_r == 1 -- the wedge state itself. Trigger position 1024 of
# 4096 keeps ~1k samples of the APPROACH to the wedge and ~3k after it.
# *wr_hold_r* is unique to probe27; nothing else in the probe set contains it.
set tp [get_hw_probes -quiet *wr_hold_r* -of_objects $ila]
if {$tp ne ""} {
  if {[catch { set_property TRIGGER_COMPARE_VALUE eq1'b1 [lindex $tp 0] } e]} {
    puts "TRIGGER_SET_WARN: $e"
  } else { puts "ILA_TRIGGER: wr_hold_r == 1 (on [lindex $tp 0])" }
} else {
  puts "ILA_TRIGGER: NONE (wr_hold_r probe absent) -- force-capture only"
}

if {[catch { run_hw_ila $ila } err]} { fail "arm: $err" }
puts "ILA_ARMED (awaiting /tmp/do_capture)"
exec sh -c "touch /tmp/ila_armed"

set got 0
for {set i 0} {$i < 240} {incr i} { if {[file exists /tmp/do_capture]} { set got 1; break }; after 1000 }
puts "DO_CAPTURE=$got"

# ALWAYS force-capture. Do NOT gate this on get_property CORE_STATUS: that
# property does not exist on hw_ila in Vivado 2025.2 and an UNGUARDED read aborts
# the script (Labtoolstcl 44-155) before the capture ever happens -- which is
# exactly how an earlier attempt of this campaign was lost.
if {[catch { run_hw_ila -trigger_now $ila } e1]} { puts "TRIGGER_NOW_WARN: $e1" }
if {[catch { wait_on_hw_ila -timeout 40 $ila } e2]} { puts "WAIT_WARN: $e2" }

if {[catch {
  upload_hw_ila_data $ila
  write_hw_ila_data -csv_file $CSV [current_hw_ila_data]
} err]} { fail "upload/write: $err" }
# Guarded, best-effort, and AFTER the CSV is safely written.
if {[catch { puts "TRIG_STATUS: [get_property CORE_STATUS $ila]" } e3]} {
  puts "TRIG_STATUS: unavailable (CORE_STATUS not a property on this hw_ila)"
}
exec sh -c "touch /tmp/ila_done"
puts "CAPTURE_DONE csv=$CSV"
