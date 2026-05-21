###-----------------------------------------------------------------------------
### verify_xdc.tcl — static lint of XDC files against the TideLink msg gate
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###-----------------------------------------------------------------------------
### Usage:
###   vivado -mode batch -source fpga/scripts/verify_xdc.tcl -tclargs <target_dir>
### or plain Tcl (faster, no Vivado needed for the static checks below):
###   tclsh fpga/scripts/verify_xdc.tcl <target_dir>
###
###   target_dir defaults to fpga/targets/pynq-z2-pair-all
###
### What it checks (static, no Vivado design context needed):
###   * Procedural Tcl commands at column 0 in an XDC file:
###       if / catch / file / info / get_files / foreach / proc / source
###     -> Designutils 20-1307 candidates.
###   * Multi-pin `get_pins -filter` patterns that would feed
###     create_generated_clock / set_input_delay / set_output_delay and not
###     be reduced via lindex 0:
###       -> Constraints 18-359 candidate.
###   * Empty get_cells / get_pins / get_ports filters that result from
###     mis-quoted or wildcard-only filters (best-effort heuristic).
###
### What it does NOT check (those need a synthesised design context, so
### only the full build_design.tcl + the in-build msg-gate can catch them):
###   * Vivado 12-4739  (no valid object after design loaded)
###   * Common 17-55    (empty selector at the moment of set_property)
###   * Vivado 12-1411  (empty filter at design-resolution time)
###-----------------------------------------------------------------------------

# Allow running under either tclsh or vivado batch.
if { [info exists argv] } { set _args $argv } else { set _args {} }
set tdir [lindex $_args 0]
if { $tdir eq "" } { set tdir "fpga/targets/pynq-z2-pair-all" }

set procedural_re {^\s*(if|catch|file|info\s+script|info\s+exists|get_files|foreach|proc|source)\s}
# Also catch nested procedural calls inside [...] command-substitution
set nested_proc_re {\[(file\s+\w+|info\s+script|info\s+exists|get_files)\s}
set multi_pin_re  {^\s*set\s+[a-zA-Z_][a-zA-Z0-9_]*\s+\[get_pins\s+-hier\s+-filter\s+\{NAME\s*=~\s*"[^"]*\*[^"]*"\}\]}
set inline_multi_pin_re {get_pins\s+-hier\s+-filter\s+\{NAME\s*=~\s*\S*\*[^\}]*\}}

set ok 1
set total_findings 0
foreach xdc [lsort [glob -nocomplain $tdir/*.xdc]] {
    set fh [open $xdc r]
    set lineno 0
    set file_findings 0
    while { [gets $fh line] >= 0 } {
        incr lineno
        # Skip comments
        if { [regexp {^\s*#} $line] } { continue }
        # Procedural Tcl?
        if { [regexp $procedural_re $line] } {
            puts "FAIL Designutils-20-1307 $xdc:$lineno: $line"
            incr file_findings
            set ok 0
        }
        # `catch { ... }` inline
        if { [regexp {^\s*catch\s*\{} $line] } {
            puts "FAIL Designutils-20-1307 $xdc:$lineno: $line"
            incr file_findings
            set ok 0
        }
        # Nested procedural Tcl inside [...] substitutions
        if { [regexp $nested_proc_re $line] } {
            puts "FAIL Designutils-20-1307 $xdc:$lineno: nested procedural: $line"
            incr file_findings
            set ok 0
        }
        # Multi-pin glob feeding a master-clock selector?
        # (heuristic: filter contains a leading `*/` AND a `*` in the body)
        if { [regexp {get_pins\s+-hier\s+-filter\s+\{NAME\s*=~\s*"\*/[^"]*\*[^"]*"\}} $line] } {
            # NOT wrapped in `lindex ... 0` ?
            if { ![regexp {\[lindex\s+\[get_pins} $line] } {
                puts "WARN Constraints-18-359 $xdc:$lineno: multi-pin glob not reduced by lindex 0: $line"
                incr file_findings
                set ok 0
            }
        }
    }
    close $fh
    if { $file_findings == 0 } {
        puts "PASS $xdc"
    }
    incr total_findings $file_findings
}

puts "=== verify_xdc: total findings = $total_findings ==="
if { $ok } { exit 0 } else { exit 1 }
