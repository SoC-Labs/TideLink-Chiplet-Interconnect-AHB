#-----------------------------------------------------------------------------
### phc_ila_capture.tcl - batch-mode HW Manager ILA capture for PHC debug.
###
### Pairs with the feat/phc-ila-debug bitstream (master+slave) — connects to
### a running hw_server, picks the target whose name matches the requested
### Z2 board, opens the device, associates the .ltx probe file (if given),
### arms the ILA on a rising edge of a chosen probe (default: slave_ll_rx_*),
### waits N seconds, and dumps the capture as .ila + .csv + .wdb.
###
### IMPORTANT: this script does NOT program the device — PYNQ Linux already
### loaded the bitstream via fpga_manager, and re-programming over JTAG would
### blow away the PS-side setup. We only attach the probes file.
###
### Usage:
###   vivado -mode batch -source phc_ila_capture.tcl -tclargs \
###       <hw_url>  <target_glob>  <ltx_or_NONE>  <out_prefix> \
###       <trigger_probe_glob_or_AUTO>  [arm_timeout_s]
###
### Example:
###   vivado -mode batch -source phc_ila_capture.tcl -tclargs \
###       localhost:3121 *Z2_03*  /path/debug_nets.ltx  \
###       /home/dam1n19/td_milestone_stage/phc_ila_20260523 \
###       slave_ll_rx_valid_sop  60
#-----------------------------------------------------------------------------
if { [llength $argv] < 5 } {
    puts "ERROR: usage: -tclargs <hw_url> <target_glob> <ltx|NONE> <out_prefix> <probe_glob|AUTO> \[timeout_s\]"
    exit 1
}
set hw_url       [lindex $argv 0]
set target_glob  [lindex $argv 1]
set ltx_file     [lindex $argv 2]
set out_prefix   [lindex $argv 3]
set probe_glob   [lindex $argv 4]
set arm_timeout  [expr {[llength $argv] >= 6 ? [lindex $argv 5] : 60}]

puts "==========================================="
puts " PHC ILA capture"
puts " hw_server  : $hw_url"
puts " target glob: $target_glob"
puts " probes(ltx): $ltx_file"
puts " out prefix : $out_prefix"
puts " trig probe : $probe_glob   timeout: ${arm_timeout}s"
puts "==========================================="

if { $ltx_file ne "NONE" && ![file exists $ltx_file] } {
    puts "ERROR: ltx not found: $ltx_file"; exit 1
}

open_hw_manager
connect_hw_server -url $hw_url

set targets [get_hw_targets]
puts "Available targets:"
foreach t $targets { puts "  - $t" }
set match [lsearch -all -inline $targets $target_glob]
if { [llength $match] == 0 } {
    puts "ERROR: no target matches '$target_glob'"
    disconnect_hw_server; close_hw_manager; exit 1
}
set tgt [lindex $match 0]
puts "Using target: $tgt"
current_hw_target $tgt
set_property PARAM.FREQUENCY 5000000 [current_hw_target]
catch {close_hw_target}
open_hw_target

set devs [get_hw_devices]
puts "Devices on chain: $devs"
## Pick an xc7z (Zynq) device — Zynq exposes both arm_dap and xc7z*; we want PL.
set fpga ""
foreach d $devs {
    if { [string match -nocase *xc7z* $d] } { set fpga $d; break }
}
if { $fpga eq "" } {
    puts "ERROR: no xc7z device on chain $devs"
    close_hw_target; disconnect_hw_server; close_hw_manager; exit 1
}
current_hw_device $fpga
puts "FPGA device: $fpga"

if { $ltx_file ne "NONE" } {
    set_property PROBES.FILE       $ltx_file $fpga
    set_property FULL_PROBES.FILE  $ltx_file $fpga
}
refresh_hw_device -update_hw_probes false $fpga
if { $ltx_file ne "NONE" } { refresh_hw_device $fpga }

set ilas [get_hw_ilas -of_objects $fpga]
if { [llength $ilas] == 0 } {
    puts "ERROR: no hw_ila visible on $fpga"
    puts "  -> the bitstream was probably built WITHOUT an ILA core,"
    puts "     or the .ltx file is missing/stale."
    close_hw_target; disconnect_hw_server; close_hw_manager; exit 1
}
set ila [lindex $ilas 0]
puts "ILA: $ila"
set probes [get_hw_probes -of_objects $ila]
puts "Probes:"
foreach p $probes { puts "  - $p" }

## Vivado 2025.2: CONTROL.MAX_DATA_DEPTH was removed; use the build-time depth.
set_property CONTROL.DATA_DEPTH       4096 $ila
set_property CONTROL.TRIGGER_POSITION 256 $ila
## Vivado 2025.2: CONTROL.CAPTURE_MODE is read-only; BASIC is the default.

## Pick trigger probe.
set trig_probe ""
## Strip trigger-type prefix from probe_glob for the matching logic below.
set probe_match $probe_glob
if {[string match "L:*"  $probe_glob]} { set probe_match [string range $probe_glob 2 end] }
if {[string match "L0:*" $probe_glob]} { set probe_match [string range $probe_glob 3 end] }
if {[string match "F:*"  $probe_glob]} { set probe_match [string range $probe_glob 2 end] }

if { $probe_glob eq "AUTO" } {
    ## Try common PHC/sync probes in priority order.
    foreach pat {*slave_ll_rx_valid_sop* *rx_valid_sop* *ll_rx_valid* *valid_sop* *sop*} {
        foreach p $probes {
            if { [string match -nocase $pat $p] } { set trig_probe $p; break }
        }
        if { $trig_probe ne "" } { break }
    }
} else {
    foreach p $probes {
        if { [string match -nocase *${probe_match}* $p] } { set trig_probe $p; break }
    }
}

if { $trig_probe ne "" } {
    # Allow probe_glob to encode trigger type: prefix "L:" = level=1, "L0:" = level=0,
    # "F:" = falling edge, default (no prefix) = rising edge.
    set trig_cmp eq1'bR
    set trig_desc "rising edge"
    if {[string match "L:*" $probe_glob]} { set trig_cmp eq1'b1; set trig_desc "level=1" }
    if {[string match "L0:*" $probe_glob]} { set trig_cmp eq1'b0; set trig_desc "level=0" }
    if {[string match "F:*" $probe_glob]}  { set trig_cmp eq1'bF; set trig_desc "falling edge" }
    puts "Trigger: $trig_desc on $trig_probe (compare=$trig_cmp)"
    set_property TRIGGER_COMPARE_VALUE $trig_cmp \
        [get_hw_probes $trig_probe -of_objects $ila]
} else {
    puts "WARN: no matching trigger probe ('$probe_glob') — capturing any state"
}

## Reset ILA state before arming. Without this, a previous failed capture
## (e.g. corrupted-readback from the dbg_hub C_CLK_INPUT_FREQ_HZ mis-config
## in b22 builds) can leave the core in a half-state that causes
## wait_on_hw_ila to hang indefinitely.
catch { reset_hw_ila $ila }

run_hw_ila $ila
puts "ILA armed. Polling CORE.STATUS up to ${arm_timeout}s for trigger ..."

## Use wait_on_hw_ila for fire detection. Vivado 2025.2 hw_ila exposes
## NO live status property (no CORE.STATUS) and removed refresh_hw_ila;
## wait_on_hw_ila is the only public API. It returns 0 on trigger fire,
## raises a Tcl error on timeout. The wedge problem in the user's prior
## attempt was caused by upload_hw_ila_data corruption polluting JTAG
## state — we now guard that call below.
set t0 [clock milliseconds]
set wrc [catch {wait_on_hw_ila -timeout $arm_timeout $ila} werr]
set arm_ms [expr {[clock milliseconds] - $t0}]
set fired 0
set core_status "unknown"
if {$wrc == 0} {
    set fired 1
    set core_status "fired"
} else {
    set core_status "timeout/$werr"
}
if {$fired} {
    puts "FIRED after ${arm_ms} ms"
} else {
    puts "TIMEOUT after ${arm_ms} ms  ($core_status)"
}

## Waveform readback is the failure point under the b22 clock mis-config.
## Wrap upload + writes in a catch so we still write a status summary
## even if the dbg_hub returns corrupted samples. Recovery on failure:
## reset_hw_ila + close/reopen the target to flush JTAG state.
set readback_ok 0
file mkdir [file dirname $out_prefix]
set rc [catch { upload_hw_ila_data $ila } uerr]
if {$rc} {
    puts "WARN: upload_hw_ila_data FAILED: $uerr"
    puts "WARN: (likely [Xicom 50-38/41] dbg_hub C_CLK_INPUT_FREQ_HZ mis-config)"
    puts "WARN: resetting ILA and JTAG target to recover ..."
    catch { reset_hw_ila $ila }
    catch { close_hw_target }
    catch { open_hw_target }
    catch { refresh_hw_device -update_hw_probes false $fpga }
} else {
    set wdb [current_hw_ila_data]
    if {[catch { write_hw_ila_data -force "${out_prefix}.ila" $wdb } we1]} {
        puts "WARN: write .ila: $we1"
    } else { set readback_ok 1 }
    catch { write_hw_ila_data -force -csv_file "${out_prefix}.csv" $wdb }
    catch { write_hw_ila_data -force -vcd_file "${out_prefix}.vcd" $wdb }
    puts "Wrote ${out_prefix}.{ila,csv,vcd?}"
}

# Always write a status sidecar so a downstream script can read fire/no-fire
# even when waveform readback fails.
set sidecar "${out_prefix}.fire.txt"
if {[catch {
    set fh [open $sidecar w]
    puts $fh "probe=$trig_probe"
    puts $fh "fired=$fired"
    puts $fh "arm_ms=$arm_ms"
    puts $fh "core_status=$core_status"
    puts $fh "readback_ok=$readback_ok"
    close $fh
} se]} {
    puts "WARN: sidecar write: $se"
} else {
    puts "Wrote $sidecar"
}

puts "==================== PROBE SUMMARY ===================="
if {$readback_ok && [info exists wdb]} {
    foreach p $probes {
        if { [catch { set tr [get_hw_probe_transitions $wdb \
                -of_objects [get_hw_probes $p -of_objects $ila]] } e] } {
            set tr "n/a"
        }
        puts [format "  %-50s %s" $p $tr]
    }
} else {
    puts "  (waveform readback failed — fire-state only: fired=$fired)"
}
puts "======================================================="

close_hw_target
disconnect_hw_server
close_hw_manager
