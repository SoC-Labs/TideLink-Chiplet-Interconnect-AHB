#-----------------------------------------------------------------------------
### phc_ila_fire_detect.tcl - STATUS-only ILA trigger-fire detector
###
### Background:
###   The b22 bitstream's dbg_hub was synthesised with
###   C_CLK_INPUT_FREQ_HZ = 300_000_000 (Vivado's default for
###   create_debug_core), but the actual clk_wiz_0/clk_out1 (hclk) runs
###   at 25 MHz. The 12x mismatch corrupts the dbg_hub's BSCAN frame
###   counter during waveform readback, producing:
###       ERROR: [Xicom 50-38] No trigger mark in any sample in window: 0
###       ERROR: [Xicom 50-41] Waveform data ... is corrupted
###   and worse, leaves the ILA core in a state where every subsequent
###   wait_on_hw_ila hangs indefinitely (the user observed this in the
###   first b22 capture attempt).
###
###   This script avoids the broken codepath entirely by polling
###   CORE.STATUS (a small JTAG read that does NOT trigger the
###   sample-buffer readback) and reporting only fire-or-not per probe.
###   That is enough to localise PHC bugs (see plan: 4 triggers x
###   fire/no-fire matrix narrows the slave RX path defect set).
###
### Usage:
###   vivado -mode batch -source phc_ila_fire_detect.tcl -tclargs \
###       <hw_url> <target_glob> <ltx_path> <out_log> \
###       <probe1>[,<probe2>...] [arm_timeout_s] [tck_hz]
###
### Example:
###   vivado -mode batch -source phc_ila_fire_detect.tcl -tclargs \
###       localhost:3121 *Z2_03* /tmp/tidelink_deploy/tidelink-flip.ltx \
###       /home/david/agentk/phc_fire.log \
###       rx_pkt_valid,rx_fifo_io_winc,rx_fifo_io_wfull,ptp_rx_valid_r \
###       15 5000000
#-----------------------------------------------------------------------------

if { [llength $argv] < 5 } {
    puts "ERROR: usage: -tclargs <hw_url> <target_glob> <ltx|NONE> <out_log> <p1\[,p2..]> \[timeout_s\] \[tck_hz\]"
    exit 1
}
set hw_url       [lindex $argv 0]
set target_glob  [lindex $argv 1]
set ltx_file     [lindex $argv 2]
set out_log      [lindex $argv 3]
set probe_csv    [lindex $argv 4]
set arm_timeout  [expr {[llength $argv] >= 6 ? [lindex $argv 5] : 15}]
set tck_hz       [expr {[llength $argv] >= 7 ? [lindex $argv 6] : 5000000}]

set probe_list [split $probe_csv ","]

proc log_both {msg out} {
    puts $msg
    if {$out ne ""} { puts $out $msg; flush $out }
}

set logfh ""
if {$out_log ne "NONE" && $out_log ne ""} {
    file mkdir [file dirname $out_log]
    set logfh [open $out_log w]
}

log_both "===========================================" $logfh
log_both " PHC ILA fire-detect (STATUS-poll mode)"     $logfh
log_both " hw_server  : $hw_url"                       $logfh
log_both " target glob: $target_glob"                  $logfh
log_both " probes(ltx): $ltx_file"                     $logfh
log_both " out log    : $out_log"                      $logfh
log_both " probes     : [join $probe_list { , }]"      $logfh
log_both " arm-timeout: ${arm_timeout}s   TCK=${tck_hz} Hz" $logfh
log_both "===========================================" $logfh

if { $ltx_file ne "NONE" && ![file exists $ltx_file] } {
    log_both "ERROR: ltx not found: $ltx_file" $logfh
    exit 1
}

open_hw_manager
connect_hw_server -url $hw_url

set targets [get_hw_targets]
set match   [lsearch -all -inline $targets $target_glob]
if { [llength $match] == 0 } {
    log_both "ERROR: no target matches '$target_glob' in [$targets]" $logfh
    disconnect_hw_server; close_hw_manager; exit 1
}
set tgt [lindex $match 0]
log_both "target: $tgt" $logfh
current_hw_target $tgt
set_property PARAM.FREQUENCY $tck_hz [current_hw_target]
catch {close_hw_target}
open_hw_target

set fpga ""
foreach d [get_hw_devices] {
    if { [string match -nocase *xc7z* $d] } { set fpga $d; break }
}
if { $fpga eq "" } {
    log_both "ERROR: no xc7z device on chain" $logfh
    close_hw_target; disconnect_hw_server; close_hw_manager; exit 1
}
current_hw_device $fpga
log_both "device: $fpga" $logfh

if { $ltx_file ne "NONE" } {
    set_property PROBES.FILE      $ltx_file $fpga
    set_property FULL_PROBES.FILE $ltx_file $fpga
}
refresh_hw_device -update_hw_probes false $fpga
if { $ltx_file ne "NONE" } { refresh_hw_device $fpga }

set ilas [get_hw_ilas -of_objects $fpga]
if { [llength $ilas] == 0 } {
    log_both "ERROR: no hw_ila on device — bitstream/ltx mismatch" $logfh
    close_hw_target; disconnect_hw_server; close_hw_manager; exit 1
}
set ila [lindex $ilas 0]
log_both "ILA: $ila" $logfh
set probes [get_hw_probes -of_objects $ila]
log_both "available probes ([llength $probes]):" $logfh
foreach p $probes { log_both "  - $p" $logfh }

# Per-arm config that does NOT change between iterations (also harmless to
# re-apply each loop — kept inside the loop for clarity).

# Result table:  probe -> { result fire_time_s status final_status }
array set results {}

foreach req_probe $probe_list {
    set req_probe [string trim $req_probe]
    log_both "" $logfh
    log_both "---- probe: $req_probe ----" $logfh

    # Resolve probe (substring/glob match on simple name)
    set trig_probe ""
    foreach p $probes {
        if {[string match -nocase *${req_probe}* $p]} { set trig_probe $p; break }
    }
    if {$trig_probe eq ""} {
        log_both "  WARN: no probe matches '$req_probe' — SKIP" $logfh
        set results($req_probe) [list "NO_PROBE" "-" "-" "-"]
        continue
    }
    log_both "  resolved: $trig_probe" $logfh

    # Hard-reset ILA state before re-arming. reset_hw_ila is the documented
    # way to flush a stuck Armed/Triggered FSM; it ALSO clears stale capture
    # buffer references on the host side.
    if {[catch {reset_hw_ila $ila} rr]} {
        log_both "  WARN: reset_hw_ila: $rr" $logfh
    }

    # Re-apply ILA control properties (harmless if unchanged).
    catch { set_property CONTROL.DATA_DEPTH       4096 $ila }
    catch { set_property CONTROL.TRIGGER_POSITION 256  $ila }

    # Clear any previous trigger compare on ALL probes first — otherwise
    # leftover compares from a prior loop AND-into this arm.
    foreach p $probes {
        catch { set_property TRIGGER_COMPARE_VALUE eq1'bX \
                    [get_hw_probes $p -of_objects $ila] }
    }
    # Arm on rising edge of selected probe.
    set_property TRIGGER_COMPARE_VALUE eq1'bR \
        [get_hw_probes $trig_probe -of_objects $ila]

    set t0 [clock milliseconds]
    if {[catch {run_hw_ila $ila} re]} {
        log_both "  ERROR: run_hw_ila: $re" $logfh
        set results($req_probe) [list "ARM_FAIL" "-" "-" "-"]
        continue
    }

    # Use wait_on_hw_ila -timeout for fire detection. Vivado 2025.2 hw_ila
    # exposes NO live status property (no CORE.STATUS / TRIGGER.STATUS) and
    # removed refresh_hw_ila — wait_on_hw_ila is the only public API.
    # It returns 0 on trigger; raises a Tcl error on timeout.
    # Crucially we do NOT call upload_hw_ila_data afterwards — that is the
    # call that hits [Xicom 50-38/41] under the b22 dbg_hub clock mis-config
    # and would wedge JTAG for the rest of the session.
    set wrc [catch {wait_on_hw_ila -timeout $arm_timeout $ila} werr]
    set fire_ms [expr {[clock milliseconds] - $t0}]
    set fire_s  [format "%.2f" [expr {$fire_ms / 1000.0}]]

    set fired 0
    if {$wrc == 0} {
        set fired 1
    }

    if {$fired} {
        log_both "  FIRED at ${fire_s}s  (wait_on_hw_ila rc=0)" $logfh
        set results($req_probe) [list "FIRED" $fire_s "fired" "fired"]
    } else {
        log_both "  TIMEOUT after ${fire_s}s  (rc=$wrc err='$werr')" $logfh
        set results($req_probe) [list "TIMEOUT" "-" "no-fire" "no-fire"]
    }

    # Always end the arm cleanly. We do NOT call upload_hw_ila_data — that
    # is precisely the operation that fails with [Xicom 50-38/41] under
    # this build's clock mis-config and leaves subsequent JTAG hung.
    catch { reset_hw_ila $ila }
}

log_both "" $logfh
log_both "==================== FIRE MATRIX ====================" $logfh
log_both [format "  %-40s %-10s %-8s %s" "probe" "result" "t_fire" "status"] $logfh
foreach req_probe $probe_list {
    set req_probe [string trim $req_probe]
    if {[info exists results($req_probe)]} {
        set r $results($req_probe)
        log_both [format "  %-40s %-10s %-8s %s" $req_probe \
            [lindex $r 0] [lindex $r 1] [lindex $r 2]] $logfh
    }
}
log_both "=====================================================" $logfh

close_hw_target
disconnect_hw_server
close_hw_manager
if {$logfh ne ""} { close $logfh }
