# ila_capture_tl035.tcl -- die_a XHB500 synth-B arming capture (2026-08-13).
#
# Derived from imp/hw_gate/ila_2026_08_12/ila_capture.tcl, which is proven to
# capture through a PS deadlock. Two changes, both deliberate:
#
#  1. TRIGGER on dbg_ahb_sub_hreadyout LOW (the PS-facing stall = "die_a is
#     hung") instead of dbg_a2l_wedged. The old trigger CANNOT FIRE for this
#     wedge class -- it self-clears on app_rdy, which is 1 at the wedge -- which
#     is why the 08-12 capture read dbg_a2l_wedged=0 across all 4096 samples and
#     its harness logged "ILA capture timeout". Triggering on a signal that can
#     actually assert is the point.
#
#  2. Keep the force-capture fallback. At a HELD wedge the probed signals are
#     STATIC, so a forced window reads the frozen state faithfully -- which is
#     all the top-level question needs (does synth_b_pending assert or not).
#     If the trigger fires we get the approach to the wedge as well; if it does
#     not, we still get the frozen state. Either way the capture is attributable,
#     unlike an untriggered window whose position is arbitrary.
#
# THE QUESTION THIS ANSWERS:
#   synth_b_pending == 0 at the wedge -> synth-B never ARMED. The
#     `|| sub_axi_progress` term at tidelink_top.sv:1667 keeps rearming the
#     stuck write's age timer via reads and SIBLING write-Bs. Fix = a separate
#     head-of-line write-age timer.
#   synth_b_pending == 1 at the wedge -> synth-B ARMED and the synthetic B did
#     not retire die_a's PS write. Different defect, different fix.
#   sub_osr_ctr_r's VALUE discriminates further: near 0 => recently reset (the
#     starvation story); near threshold => it was counting and something else
#     blocked. sub_r_done vs sub_b_done are probed SEPARATELY so we can see
#     which completion did the resetting.

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

# Report what we actually got, so a missing probe is caught HERE and not after
# the run when the CSV turns out not to contain the signal the whole test is about.
set allp [get_hw_probes -quiet -of_objects $ila]
puts "ILA_PROBE_COUNT: [llength $allp]"
foreach want {synth_b_pending sub_osr_ctr_r sub_wr_os_ctr sub_axi_progress sub_r_done sub_b_done sub_wr_stuck_fire dbg_ahb_sub_hreadyout} {
  set p [get_hw_probes -quiet *${want}* -of_objects $ila]
  if {$p eq ""} { puts "ILA_PROBE_MISSING: $want" } else { puts "ILA_PROBE_OK: $want" }
}

set_property CONTROL.TRIGGER_POSITION 1024 $ila
set_property CONTROL.DATA_DEPTH 4096 $ila

# Trigger on the PS-facing stall going LOW. Trigger position 1024 of 4096 keeps
# ~1k samples of the APPROACH to the wedge and ~3k after it.
set tp [get_hw_probes -quiet *dbg_ahb_sub_hreadyout* -of_objects $ila]
if {$tp ne ""} {
  if {[catch { set_property TRIGGER_COMPARE_VALUE eq1'b0 [lindex $tp 0] } e]} {
    puts "TRIGGER_SET_WARN: $e"
  } else { puts "ILA_TRIGGER: dbg_ahb_sub_hreadyout == 0" }
} else {
  puts "ILA_TRIGGER: NONE (probe absent) -- force-capture only"
}

if {[catch { run_hw_ila $ila } err]} { fail "arm: $err" }
puts "ILA_ARMED (awaiting /tmp/do_capture)"
exec sh -c "touch /tmp/ila_armed"

set got 0
for {set i 0} {$i < 200} {incr i} { if {[file exists /tmp/do_capture]} { set got 1; break }; after 1000 }
puts "DO_CAPTURE=$got"

# ALWAYS force-capture. Do NOT gate this on get_property CORE_STATUS: that
# property does not exist on hw_ila in Vivado 2025.2 and an UNGUARDED read aborts
# the script (Labtoolstcl 44-155) before the capture ever happens — which is
# exactly how the first attempt of this run was lost. The 08-12 script issues the
# same invalid call, but at the very END after the CSV is written, where it is
# harmless; moving it earlier makes it fatal.
# Forcing unconditionally is also correct on the merits: at a HELD wedge the
# signals are static, so a forced window reads the frozen state faithfully, and
# if the trigger did fire we lose nothing by re-capturing the same held state.
if {[catch { run_hw_ila -trigger_now $ila } e1]} { puts "TRIGGER_NOW_WARN: $e1" }
if {[catch { wait_on_hw_ila -timeout 40 $ila } e2]} { puts "WAIT_WARN: $e2" }

if {[catch {
  upload_hw_ila_data $ila
  write_hw_ila_data -csv_file $CSV [current_hw_ila_data]
} err]} { fail "upload/write: $err" }
# Guarded: CORE_STATUS is not a valid hw_ila property here (Labtoolstcl 44-155).
# Kept only as best-effort information, and AFTER the CSV is safely written.
if {[catch { puts "TRIG_STATUS: [get_property CORE_STATUS $ila]" } e3]} {
  puts "TRIG_STATUS: unavailable (CORE_STATUS not a property on this hw_ila)"
}
exec sh -c "touch /tmp/ila_done"
puts "CAPTURE_DONE csv=$CSV"
