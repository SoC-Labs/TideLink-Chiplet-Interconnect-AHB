###-----------------------------------------------------------------------------
### nanosoc_compute_chiplet - Vivado Filelist (parent-repo sources)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### RTL source manifest for packaging nanosoc_compute_chiplet as a Vivado IP.
###
### Two-link sibling of nanosoc_eth_chiplet_filelist.tcl. Like the eth chiplet,
### the compute chiplet integrates the WHOLE multicore SoC (here nanosoc_compute_soc)
### which lives in the PARENT repo (NanoSoC-Compute-Chiplet, of which tidelink is a
### submodule). Rather than re-implement that repo's flist resolution, we consume
### the FLATTENED, absolute-path source lists the parent's `make elab` produces:
###
###   $NANOSOC_COMPUTE_CHIPLET_DIR/build/elab/soc_vcs.f       (flatten_soc_flist.py)
###   $NANOSOC_COMPUTE_CHIPLET_DIR/build/elab/tidelink_vcs.f  (resolve_tidelink_flist.py)
###
### These, plus TideChart's own flist and the 3 integration RTL files, are the
### SINGLE SOURCE OF TRUTH captured by flist/nanosoc_compute_chiplet.flist. Regenerate
### the flattened lists with `make -C $NANOSOC_COMPUTE_CHIPLET_DIR elab` (or its flist
### prep) before packaging so this list tracks the current SoC render.
###
### SCOPING-TODO: flist/nanosoc_compute_chiplet.flist is authoritative. This tcl
###   reproduces the same source set from the flattened .f lists (proven eth pattern)
###   rather than parsing the ${VAR}/-f master flist directly. If the master flist
###   grows a component this list does not track, add it here (or teach the parse to
###   consume the master flist under a full env).
###
### Required environment variables:
###   NANOSOC_COMPUTE_CHIPLET_DIR - Root of the parent NanoSoC-Compute-Chiplet repo
###   SOCLABS_TIDELINK_DIR        - Root of the tidelink submodule (for ${TIDELINK_HOME})
###-----------------------------------------------------------------------------

if {![info exists env(NANOSOC_COMPUTE_CHIPLET_DIR)]} {
    error "NANOSOC_COMPUTE_CHIPLET_DIR is not set - point it at the parent repo root."
}
set chiplet_root $env(NANOSOC_COMPUTE_CHIPLET_DIR)

# ${TIDELINK_HOME} appears unsubstituted in the tidelink flattened list's
# +incdir lines; provide it for [subst]. ${TIDECHART_HOME} appears in
# tidechart.flist; derive it from the parent repo layout (submodule).
set TIDELINK_HOME  $env(SOCLABS_TIDELINK_DIR)
set TIDECHART_HOME [file join $chiplet_root tidechart]

# The flattened soc/tidelink lists are the SoC + link only. The master flist
# (flist/nanosoc_compute_chiplet.flist) also pulls the TideChart component flist and
# the 3 integration RTL files — none of which appear in the flattened .f lists,
# so add them explicitly or the top (nanosoc_compute_chiplet) is an unresolved black
# box (package_project tolerates it; synth_design does NOT — Synth 8-439).
# The compute-chiplet is a V2 / ship-config build: it needs the TideLink flist
# resolved from tidelink_fpga_v2.flist (V2 PHY: deps/tidelink-phy, epoch ports,
# v2shims). The parent `make elab` writes a V1 tidelink_vcs.f (sim default), so
# the package_compute_chiplet_ip Makefile goal regenerates the V2 list into
# build/fpga_gen_v2/tidelink_vcs_v2.f. Prefer that; fall back to build/elab.
set _tl_v2 [file join $chiplet_root build fpga_gen_v2 tidelink_vcs_v2.f]
set _tl_flat [expr {[file exists $_tl_v2] ? $_tl_v2 : [file join $chiplet_root build elab tidelink_vcs.f]}]
set flist_files [list \
    [file join $chiplet_root build elab soc_vcs.f] \
    $_tl_flat \
    [file join $TIDECHART_HOME flist tidechart.flist] \
]

# Integration RTL (this repo) — appended after the flists are parsed, below.
# The compute integration top is nanosoc_compute_chiplet.sv (two links), and it
# reuses chiplet_d2d_decode.sv + tidechart_shim.sv (same names as the eth chiplet).
set _integration_incdir [file join $chiplet_root src rtl]
set _integration_srcs [list \
    [file join $chiplet_root src rtl chiplet_d2d_decode.sv] \
    [file join $chiplet_root src rtl tidechart_shim.sv] \
    [file join $chiplet_root src rtl nanosoc_compute_chiplet.sv] \
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
            puts "WARNING: nanosoc_compute_chiplet_filelist: skipping unexpected directive: $line"
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
puts [format "  nanosoc_compute_chiplet filelist: %d sources, %d incdirs, %d defines" \
        [llength $_sources] [llength $_incdirs_uniq] [llength $_defines]]
puts "============================================================"

# Duplicate-BASENAME disambiguation (mirrors the eth / multicore pynq filelist).
# The SoC may carry two files named phc_ahb.sv with DIFFERENT contents:
#   .../src/rtl/wrappers/phc_ahb.sv        (module phc_ahb  — the wrapper)
#   .../ptp-hardware-clock-ahb/.../phc_ahb.sv (module PHC_AHB — the core)
# ipx::package_project -import_files flattens sources into one dir by basename,
# so one clobbers the other -> "module PHC_AHB not found" at IP synth. Copy the
# WRAPPER to a disambiguated basename before reading (module name unchanged, only
# the filename). Harmless if the compute SoC's short phc_ahb has no such duplicate
# (the string match below simply never fires). Other same-basename hits (cmsdk_*,
# xhb500_*) are the SAME file referenced twice and are harmless "already exists".
set _disambig_dir [file join $chiplet_root build fpga_disambig]
file mkdir $_disambig_dir

# V2 PHY shim materialisation (mirrors tidelink fpga/filelist.tcl). The V2 flist
# lists src/rtl/v2shims/v2_*.{v,sv} which are just `define TIDELINK_PHY_V2 +
# `include "<orig>". ipx::package_project -import_files DROPS include-style files
# ("does not exist in the project sources" -> "module Wlink not found" at synth).
# Fix: flatten each shim into a STANDALONE generated source (defines prepended to
# the full body of the included original) and read THAT instead.
set _v2_gen_dir [file join $chiplet_root build fpga_gen_v2]
file mkdir $_v2_gen_dir
proc cc_materialise_v2_shim {shim incdirs gen_dir} {
    set fh [open $shim r]; set shim_text [read $fh]; close $fh
    if { ![regexp {`include\s+"([^\"]+)"} $shim_text -> inc_name] } {
        error "v2 shim $shim has no `include directive"
    }
    set orig ""
    foreach d $incdirs {
        if { [file exists [file join $d $inc_name]] } { set orig [file join $d $inc_name]; break }
    }
    if { $orig eq "" } { error "v2 shim $shim: '$inc_name' not found under incdirs" }
    set out [file join $gen_dir $inc_name]
    set fh [open $orig r]; set body [read $fh]; close $fh
    set fo [open $out w]
    puts $fo "// AUTO-GENERATED (TIDELINK_PHY_V2 build) - DO NOT EDIT. Source: $orig"
    puts $fo "`define TIDELINK_PHY_V2"
    puts $fo "`define TD_AUTO_LANE_MASK_E4"
    puts -nonewline $fo $body
    close $fo
    puts "INFO: materialised v2shim [file tail $shim] -> $out"
    return $out
}

# Read every source. .sv -> SystemVerilog, else plain Verilog.
foreach s $_sources {
    if {![file exists $s]} {
        error "Source file not found: $s"
    }
    if {[string match "*/v2shims/*" $s]} {
        set _mat [cc_materialise_v2_shim $s $_incdirs_uniq $_v2_gen_dir]
        if {[string match "*.sv" $_mat]} { read_verilog -sv $_mat } else { read_verilog $_mat }
        continue
    }
    if {[string match "*/src/rtl/wrappers/phc_ahb.sv" $s]} {
        set _dis [file join $_disambig_dir phc_ahb_wrapper.sv]
        file copy -force $s $_dis
        read_verilog -sv $_dis
        puts "INFO: disambiguated $s -> $_dis (dup-basename phc_ahb.sv)"
        continue
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
