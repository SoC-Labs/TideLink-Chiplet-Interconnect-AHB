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
set_property PARAM.FREQUENCY 15000000 [current_hw_target]
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

## Vivado 2025.2 gotchas (reference_insert_debug_core.md §4-§6):
##   CONTROL.MAX_DATA_DEPTH is REMOVED in 2025.2 (IP-creation only).
##   CONTROL.CAPTURE_MODE   is READ-ONLY in 2025.2 (IP-creation only).
## Do NOT call set_property CONTROL.DATA_DEPTH / CAPTURE_MODE — they raise
## "Invalid argument" or silent failure. TRIGGER_POSITION is still runtime-OK.
catch { set_property CONTROL.TRIGGER_POSITION 256 $ila }

## Pick trigger probe.
set trig_probe ""
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
        if { [string match -nocase *${probe_glob}* $p] } { set trig_probe $p; break }
    }
}

if { $trig_probe ne "" } {
    ## Multi-bit FSM trigger support — env $TIDELINK_TRIGGER_VALUE (e.g. 0x2 for
    ## HW_SYNC_FIRE). Falls back to rising-edge on single-bit nets when unset.
    set tv ""
    if { [info exists ::env(TIDELINK_TRIGGER_VALUE)] } {
        set tv $::env(TIDELINK_TRIGGER_VALUE)
    }
    if { $tv ne "" } {
        ## Discover probe width to format the compare value.
        set probe_obj [get_hw_probes $trig_probe -of_objects $ila]
        set w 1
        catch { set w [get_property WIDTH $probe_obj] }
        ## Strip 0x prefix; format as <width>'h<hex> match for any-state eq.
        set raw $tv
        if { [string match -nocase 0x* $raw] } { set raw [string range $raw 2 end] }
        set cmp "eq${w}'h${raw}"
        puts "Trigger: value match on $trig_probe == ${cmp}"
        set_property TRIGGER_COMPARE_VALUE $cmp $probe_obj
    } else {
        puts "Trigger: rising edge on $trig_probe"
        set_property TRIGGER_COMPARE_VALUE eq1'bR \
            [get_hw_probes $trig_probe -of_objects $ila]
    }
} else {
    puts "WARN: no matching trigger probe ('$probe_glob') — capturing any state"
}

run_hw_ila $ila
puts "ILA armed. Polling STATUS.HW_ILA up to ${arm_timeout}s for trigger ..."
## Vivado 2025.2 gotcha §6: wait_on_hw_ila against an auto-inserted dbg_hub
## raises "corrupted waveform". Poll get_property STATUS.HW_ILA instead and
## upload defensively (catch + retry once).
set t0 [clock seconds]
while { [expr {[clock seconds] - $t0}] < $arm_timeout } {
    refresh_hw_device -update_hw_probes false $fpga
    set st [get_property STATUS.HW_ILA $ila]
    if { ![string match -nocase *RUNNING* $st] && ![string match -nocase *ARM* $st] } {
        puts "  STATUS.HW_ILA = $st (trigger fired or stopped)"
        break
    }
    after 200
}
set fst [get_property STATUS.HW_ILA $ila]
puts "Final STATUS.HW_ILA = $fst"

## Upload with one retry on the well-known "corrupted waveform" error.
set up_rc [catch { upload_hw_ila_data $ila } up_err]
if { $up_rc } {
    puts "WARN: upload_hw_ila_data first attempt: $up_err — retrying once after refresh"
    catch { refresh_hw_device -update_hw_probes false $fpga }
    after 500
    set up_rc [catch { upload_hw_ila_data $ila } up_err]
    if { $up_rc } {
        puts "ERROR: upload_hw_ila_data failed twice: $up_err"
    }
}
set wdb [current_hw_ila_data]
file mkdir [file dirname $out_prefix]
write_hw_ila_data -force "${out_prefix}.ila" $wdb
write_hw_ila_data -force -csv_file "${out_prefix}.csv" $wdb
## VCD requires a separate flag; CSV is the always-works fallback.
catch { write_hw_ila_data -force -vcd_file "${out_prefix}.vcd" $wdb }
puts "Wrote ${out_prefix}.{ila,csv,vcd?}"

puts "==================== PROBE SUMMARY ===================="
foreach p $probes {
    if { [catch { set tr [get_hw_probe_transitions $wdb \
            -of_objects [get_hw_probes $p -of_objects $ila]] } e] } {
        set tr "n/a"
    }
    puts [format "  %-50s %s" $p $tr]
}
puts "======================================================="

close_hw_target
disconnect_hw_server
close_hw_manager
