###-----------------------------------------------------------------------------
### nanosoc_eth_chiplet - Vivado Filelist (parent-repo sources)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### RTL source manifest for packaging nanosoc_eth_chiplet as a Vivado IP.
###
### Unlike fpga/filelist.tcl (which packages the bare tidelink IP from the
### tidelink flist), the eth-chiplet integrates the WHOLE multicore+ethernet
### SoC, which lives in the PARENT repo (nanosoc-ethernet-chiplet). Rather than
### re-implement that repo's flist resolution, we consume the FLATTENED,
### absolute-path source lists the parent's `make elab` already produces:
###
###   $NANOSOC_ETH_CHIPLET_DIR/build/elab/soc_vcs.f       (flatten_soc_flist.py)
###   $NANOSOC_ETH_CHIPLET_DIR/build/elab/tidelink_vcs.f  (resolve_tidelink_flist.py)
###
### These are the SINGLE SOURCE OF TRUTH for the source set. Regenerate them
### with `make -C $NANOSOC_ETH_CHIPLET_DIR elab` (or its flist prep) before
### packaging so this list tracks the current SoC render.
###
### The 3 integration RTL files (chiplet_d2d_decode.sv, tidechart_shim.sv,
### nanosoc_eth_chiplet.sv) and the TideChart sources are already included by
### the parent flist and therefore appear in the flattened lists.
###
### Required environment variables:
###   NANOSOC_ETH_CHIPLET_DIR - Root of the parent nanosoc-ethernet-chiplet repo
###   SOCLABS_TIDELINK_DIR    - Root of the tidelink submodule (for ${TIDELINK_HOME})
###-----------------------------------------------------------------------------

if {![info exists env(NANOSOC_ETH_CHIPLET_DIR)]} {
    error "NANOSOC_ETH_CHIPLET_DIR is not set - point it at the parent repo root."
}
set chiplet_root $env(NANOSOC_ETH_CHIPLET_DIR)

# ${TIDELINK_HOME} appears unsubstituted in the tidelink flattened list's
# +incdir lines; provide it for [subst]. ${TIDECHART_HOME} appears in
# tidechart.flist; derive it from the parent repo layout (submodule).
set TIDELINK_HOME  $env(SOCLABS_TIDELINK_DIR)
set TIDECHART_HOME [file join $chiplet_root tidechart]

# The flattened soc/tidelink lists are the SoC + link only. The master flist
# (flist/nanosoc_eth_chiplet.flist) also pulls the TideChart component flist and
# the 3 integration RTL files — none of which appear in the flattened .f lists,
# so add them explicitly or the top (nanosoc_eth_chiplet) is an unresolved black
# box (package_project tolerates it; synth_design does NOT — Synth 8-439).
set flist_files [list \
    [file join $chiplet_root build elab soc_vcs.f] \
    [file join $chiplet_root build elab tidelink_vcs.f] \
    [file join $TIDECHART_HOME flist tidechart.flist] \
]

# Integration RTL (this repo) — appended after the flists are parsed, below.
set _integration_incdir [file join $chiplet_root src rtl]
set _integration_srcs [list \
    [file join $chiplet_root src rtl chiplet_d2d_decode.sv] \
    [file join $chiplet_root src rtl tidechart_shim.sv] \
    [file join $chiplet_root src rtl nanosoc_eth_chiplet.sv] \
]

set _incdirs {}
set _defines {}
set _sources {}

# ---------------------------------------------------------------------------
# Parse the VCS-style flattened .f lists into Vivado read/property inputs.
#   +libext+...        -> ignored (Vivado infers by extension)
#   +incdir+<path>     -> include dir
#   +define+<NAME[=V]> -> verilog define
#   -f / -y / other    -> not expected in a FLATTENED list; warned + skipped
#   bare path          -> RTL source (.sv read as SystemVerilog)
# ---------------------------------------------------------------------------
foreach f $flist_files {
    if {![file exists $f]} {
        error "Flattened flist not found: $f\n  Run `make -C $chiplet_root elab` first."
    }
    set fh [open $f r]
    foreach raw [split [read $fh] "\n"] {
        # ${VAR} substitution (e.g. ${TIDELINK_HOME}) against this interp's
        # vars; -nocommands keeps any '[' in a path from being run as a command.
        set line [string trim [subst -nocommands $raw]]
        if {$line eq "" || [string match "//*" $line]} { continue }
        if {[string match "+libext*" $line]} { continue }
        if {[string match "+incdir+*" $line]} {
            lappend _incdirs [string range $line 8 end]
            continue
        }
        if {[string match "+define+*" $line]} {
            lappend _defines [string range $line 8 end]
            continue
        }
        if {[string match "-*" $line]} {
            puts "WARNING: nanosoc_eth_chiplet_filelist: skipping unexpected directive: $line"
            continue
        }
        lappend _sources $line
    }
    close $fh
}

# Append the integration RTL (top last) + its include dir.
lappend _incdirs $_integration_incdir
foreach s $_integration_srcs { lappend _sources $s }

# De-duplicate include dirs (order-preserving) — the flattened lists repeat some.
set _seen {}
set _incdirs_uniq {}
foreach d $_incdirs {
    if {![dict exists $_seen $d]} { dict set _seen $d 1; lappend _incdirs_uniq $d }
}

puts "============================================================"
puts [format "  nanosoc_eth_chiplet filelist: %d sources, %d incdirs, %d defines" \
        [llength $_sources] [llength $_incdirs_uniq] [llength $_defines]]
puts "============================================================"

# Read every source. .sv -> SystemVerilog, else plain Verilog.
foreach s $_sources {
    if {![file exists $s]} {
        error "Source file not found: $s"
    }
    if {[string match "*.sv" $s]} {
        read_verilog -sv $s
    } else {
        read_verilog $s
    }
}

# Apply include dirs and defines to the sources fileset so `include and
# preprocessor conditionals resolve during OOC synthesis.
if {[llength $_incdirs_uniq] > 0} {
    set_property include_dirs $_incdirs_uniq [current_fileset]
}
if {[llength $_defines] > 0} {
    set_property verilog_define $_defines [current_fileset]
}
