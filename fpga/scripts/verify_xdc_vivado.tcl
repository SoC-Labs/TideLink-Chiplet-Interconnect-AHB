# Minimal Vivado XDC reader — checks XDC dialect compliance without
# requiring a synthesised design. Uses read_xdc which parses but does not
# evaluate object queries.
set_msg_config -id "Designutils 20-1307" -new_severity ERROR
set_msg_config -id "Constraints 18-359"  -new_severity ERROR
set_msg_config -id "Vivado 12-4739"      -new_severity ERROR
set_msg_config -id "Common 17-55"        -new_severity ERROR
set_msg_config -id "Vivado 12-1411"      -new_severity ERROR

# Minimal in-memory project for read_xdc to operate against
create_project -in_memory -part xc7z020clg400-1

foreach t {pynq-z2-pair-all pynq-z2-pair-flip-all} {
    set tdir fpga/targets/$t
    puts ""
    puts "================ $tdir ================"
    foreach xdc [lsort [glob -nocomplain $tdir/*.xdc]] {
        puts "--- read_xdc $xdc ---"
        if { [catch { read_xdc -unmanaged -ref {} $xdc } err] } {
            puts "  ERR: $err"
        }
    }
}
set err_count [get_msg_config -count -severity {ERROR}]
puts ""
puts "================ Result: ERROR=$err_count ================"
exit $err_count
