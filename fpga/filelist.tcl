###-----------------------------------------------------------------------------
### TideLink Chiplet Subsystem - Vivado Filelist
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### RTL source manifest for IP packaging. Reads flists/tidelink_fpga.flist
### (created by Agent A2) via SOCLABS_TIDELINK_DIR.
###
### Required environment variables:
###   SOCLABS_TIDELINK_DIR - Root of tidelink repository
###   CMSDK_DIR            - Root of Arm CMSDK / Corstone-101 BP210 package
###   XHB500_IP_DIR        - Root of Arm XHB-500 IP (for XHB500 bridge sources)
###-----------------------------------------------------------------------------

# Names match the placeholders the flist actually uses (${TIDELINK_HOME},
# ${CMSDK_DIR}, ${XHB500_IP_DIR}). The [subst] in the parser below relies
# on these TCL variables existing.
set TIDELINK_HOME        $env(SOCLABS_TIDELINK_DIR)
set SOCLABS_TIDELINK_DIR $env(SOCLABS_TIDELINK_DIR)
set CMSDK_DIR            $env(CMSDK_DIR)
set XHB500_IP_DIR        $env(XHB500_IP_DIR)
# CMSDK_FPGA_SRAM_V: path to cmsdk_fpga_sram.v. Set explicitly so the flist's
# ${CMSDK_FPGA_SRAM_V} placeholder resolves under [subst]. set_env.sh derives
# this from CMSDK_DIR when not set; we mirror the same fallback here so the
# flist works under any invocation that has CMSDK_DIR set.
if { [info exists env(CMSDK_FPGA_SRAM_V)] && $env(CMSDK_FPGA_SRAM_V) ne "" } {
    set CMSDK_FPGA_SRAM_V $env(CMSDK_FPGA_SRAM_V)
} else {
    set CMSDK_FPGA_SRAM_V [file join $CMSDK_DIR logical models memories cmsdk_fpga_sram.v]
}

# Flist selection. Default = the V1 list. TIDELINK_PHY_V2=1 in the
# environment selects the V2 (deps/tidelink-phy shared component) list —
# same knob as cocotb/tidelink_top_pair. (Also fixes the flist/->flists/
# rename, which this file-join form silently missed.)
set _phy_v2 0
if { [info exists ::env(TIDELINK_PHY_V2)] && $::env(TIDELINK_PHY_V2) == 1 } { set _phy_v2 1 }
set _flist_name [expr { $_phy_v2 ? "tidelink_fpga_v2.flist" : "tidelink_fpga.flist" }]

# ââ ASIC FILE-SET BUILD (TD_ASIC_FILESET=1, 2026-09-01) ââââââââââââââââââââ
# Packages the TAPEOUT file list - flists/tidelink_top_full_asic_v2.flist -
# instead of the FPGA one. This is the Vivado twin of the ASIC_FLIST=1 knob in
# cocotb/tidelink_top_pair_v2/Makefile (which does the same swap for VCS), and
# it exists for the same reason: the two flists resolve TEN module files to
# DIFFERENT sources, five of them the AXI flow-control state machines
# WlinkGenericFCSM{,_1.._4} whose FPGA copies carry five named recovery
# features (L6 CR-emit gate, L7 CRACK-emit gate, sticky-NACK bring-up forgive,
# TL-033 state-7 watchdog, periodic re-ACK) that the tapeout copies DO NOT.
# Every FPGA image ever built has carried the recovery-bearing FPGA copies, so
# nothing that tapes out has ever run on hardware.
#
# TWO deliberate deviations from the ASIC flist, both narrow and both loud in
# the log (see the ASIC FILE-SET banner emitted below):
#   1. rf_16k. The ASIC tidelink_sram.sv instantiates the TSMC65 rf_16k
#      compiled macro, which has NO RTL in the ASIC file set at all (FC binds
#      it from the memory compiler). fpga/asic_fileset/rf_16k_fpga.v supplies a
#      port-identical BRAM-inferring model. tidelink_sram.sv ITSELF is compiled
#      verbatim from src/rtl/fifo/asic/ - the substitution is the leaf macro,
#      not the wrapper.
#   2. .svh header lines. The ASIC flist lists tidelink_sync_word.svh as a
#      SOURCE (VCS compiles the whole flist as one compilation unit, so its
#      $unit-scope localparams are visible everywhere). Vivado compiles each
#      source file separately and the header is `include-guarded, so reading it
#      standalone is at best a no-op and at worst a $unit-scope parse error,
#      while the modules that `include it resolve it through the +incdir+ the
#      same flist already carries. Headers define no modules: zero netlist
#      impact either way.
# Nothing else is swapped, added or removed.
set _asic_fileset 0
if { [info exists ::env(TD_ASIC_FILESET)] && $::env(TD_ASIC_FILESET) == 1 } { set _asic_fileset 1 }
if { $_asic_fileset } {
    if { !$_phy_v2 } {
        error "TD_ASIC_FILESET=1 requires TIDELINK_PHY_V2=1 -\
               flists/tidelink_top_full_asic_v2.flist is a V2 file list and carries\
               +define+TIDELINK_PHY_V2 inline. Export TIDELINK_PHY_V2=1."
    }
    set _flist_name "tidelink_top_full_asic_v2.flist"
}

# Files in the ASIC flist that contain `ifdef TIDELINK_PHY_V2 / TD_AUTO_LANE_MASK_E4
# and therefore MUST be materialised with those defines textually prepended.
# The FPGA flist delivers the same defines to the same three modules through
# src/rtl/v2shims/; the ASIC flist delivers them as a flist-level +define+,
# which is one of the FOUR mechanisms proven (2026-06-11) NOT to survive
# ipx::package_project into the packaged IP's OOC synthesis. Materialising is
# the only mechanism that does. Derived, not guessed: these are exactly the
# files in the ASIC flist that grep TIDELINK_PHY_V2 / TD_AUTO_LANE_MASK_E4 as a
# live `ifdef (src/rtl/fifo/tidelink_apb_regs.sv mentions TIDELINK_PHY_V2 only
# in a comment at :612 - its Region-10 decode is unconditional - so it is
# correctly NOT in this list, exactly as on the FPGA path).
set _asic_materialise {
    tidelink_top.sv
    Wlink.v
    axi_chiplet_controller.sv
}

# ── 8-LANE KNOB (2026-07-17) ─────────────────────────────────────────────────
# TD_AUTO_LANE_MASK_E4 gates the 0xE4 (4-lane, bridge1 good-lane) POR default
# for the Wlink tx/rx lane masks in local_overrides/Wlink.v. It USED to be
# injected unconditionally below; it is now env-gated so the 8-lane (0xFF)
# config is buildable without editing this file.
#   TD_AUTO_LANE_MASK_E4=0 -> no define -> LANE_MASK_RESET = 8'hFF (8 lanes).
#   unset / =1             -> define    -> LANE_MASK_RESET = 8'hE4 (4 lanes).
# DEFAULT REMAINS 1 so every existing build/CI path is bit-identical.
# Rationale for wanting 0xFF: the 0xE4 default was chosen when 4 lanes were
# believed dead. The raw post-deskew slices (0x212C-0x2138) since showed all 8
# conduct in both directions; the "dead" lanes were merely UNTRAINED, because a
# masked lane gets lane_off=0 (tidelink_lane_deskew_v2.sv:1491). Wlink derives
# bytesPerCycle = popcount(lane_mask)*2 (Wlink.v:996-1014 -> LinkLayer.scala
# 658), so 0xFF is also the 2x-bandwidth knob.
set _lane_mask_e4 1
if { [info exists ::env(TD_AUTO_LANE_MASK_E4)] && $::env(TD_AUTO_LANE_MASK_E4) == 0 } { set _lane_mask_e4 0 }

# ── LOUD V1/V2 selection banner (2026-06-30) ─────────────────────────────────
# The V1/V2 split is carried SOLELY by the TIDELINK_PHY_V2 env var. When this
# file is sourced from package_tidelink_ip.tcl, that one var decides whether the
# packaged IP contains the V2 RTL (deskew, autonomous-winscan FSM, V2 SYNC
# ports) or silently degrades to V1. A missing/!=1 var during package_ip was the
# 8705a99 root cause: the IP was packaged V1, so the `ifdef TIDELINK_PHY_V2
# winscan FSM was preprocessed out (0 cells) and the bitstream came out
# byte-identical to the prior build. Make the selection impossible to miss in
# the package_ip / build_design logs so a silent V1 fallback is caught by eye.
puts "============================================================"
if { $_asic_fileset } {
    puts "  *** ASIC FILE SET *** TD_ASIC_FILESET=1"
    puts "  This build packages flists/tidelink_top_full_asic_v2.flist -"
    puts "  the TAPEOUT sources - NOT the FPGA file list. The five"
    puts "  WlinkGenericFCSM{,_1..4} copies here carry NO socl_ recovery."
    puts "  Substituted (not ASIC-sourced): rf_16k  <- fpga/asic_fileset/rf_16k_fpga.v"
    puts "  Skipped (headers, define no modules): *.svh flist entries"
}
puts [format "  TIDELINK filelist: %s  (TIDELINK_PHY_V2=%s -> %s)" \
        [expr {$_phy_v2 ? "V2 (PHY-v2 / autonomous-winscan FSM PRESENT)" \
                        : "V1 (PHY-v1 / NO autonomous-winscan FSM)"}] \
        [expr {[info exists ::env(TIDELINK_PHY_V2)] ? $::env(TIDELINK_PHY_V2) : "<unset>"}] \
        $_flist_name]
if { $_phy_v2 } {
    # Same "impossible to miss" treatment as the V1/V2 split: the lane-mask POR
    # decides bytesPerCycle (popcount*2), i.e. the link's bandwidth. A silent
    # 0xE4 in a build meant to be 8-lane looks exactly like a working build that
    # merely fails to go faster.
    puts [format "  TIDELINK lane mask: LANE_MASK_RESET = 8'h%s  (%d lanes, bytesPerCycle=%d)  TD_AUTO_LANE_MASK_E4=%s" \
            [expr {$_lane_mask_e4 ? "E4" : "FF"}] \
            [expr {$_lane_mask_e4 ? 4 : 8}] \
            [expr {$_lane_mask_e4 ? 8 : 16}] \
            [expr {[info exists ::env(TD_AUTO_LANE_MASK_E4)] ? $::env(TD_AUTO_LANE_MASK_E4) : "<unset> (default 1)"}]]
}
if { !$_phy_v2 } {
    puts "  WARNING: V1 flist selected. If this is an IP-package step for a V2"
    puts "           build, the autonomous-winscan FSM and all `ifdef"
    puts "           TIDELINK_PHY_V2 RTL will be ABSENT from the packaged IP."
    puts "           Export TIDELINK_PHY_V2=1 before 'make package_ip'."
}
puts "============================================================"

###-----------------------------------------------------------------------------
### V2 shim materialisation (Vivado-only; VCS consumes the shims directly).
###
### NO project-level define mechanism survives ipx::package_project into the
### packaged IP's OOC synthesis — all four were proven dropped (2026-06-11,
### feat/phy-v2-integration):
###   1. fileset verilog_define          — not baked into IP-XACT (same class
###                                        as the 2026-05-19 IDELAY lesson).
###   2. synth-run -verilog_define       — run recreated from the IP, option lost.
###   3. is_global_include header        — dropped by -import_files.
###   4. per-file `define+`include shims — the compile-order scanner attributes
###      the modules to the INCLUDED files (imported isIncludeFile=true) and
###      drops the shims from the packaged file set entirely, so OOC synth
###      compiles the bare originals with TIDELINK_PHY_V2 undefined
###      (Synth 8-439 'tidelink_eye_regs' at tidelink_top.sv:804).
###
### Fix: materialise each src/rtl/v2shims/ entry into a STANDALONE generated
### source — full text of the included original with `define TIDELINK_PHY_V2
### prepended — under imp/fpga/gen_v2/, and feed THAT to Vivado. The generated
### file is a plain source defining real modules: zero include/packaging
### subtleties. Regenerated on every package_ip; imp/ is gitignored.
###-----------------------------------------------------------------------------
proc tidelink_materialise_v2_shim {shim incdirs gen_dir} {
    # _lane_mask_e4 is set at file scope (8-lane knob); a proc does not see
    # globals implicitly in Tcl.
    global _lane_mask_e4
    set fh [open $shim r]; set shim_text [read $fh]; close $fh
    if { ![regexp {`include\s+"([^\"]+)"} $shim_text -> inc_name] } {
        error "v2 shim $shim has no `include directive"
    }
    # Resolve the bare include name against the flist's +incdir+ list, in
    # order — identical semantics to the VCS compile of the shim itself.
    set orig ""
    foreach d $incdirs {
        if { [file exists [file join $d $inc_name]] } {
            set orig [file join $d $inc_name]
            break
        }
    }
    if { $orig eq "" } {
        error "v2 shim $shim: '$inc_name' not found under incdirs: $incdirs"
    }
    set out [file join $gen_dir $inc_name]
    set fh [open $orig r]; set body [read $fh]; close $fh
    set fo [open $out w]
    puts $fo "// AUTO-GENERATED by fpga/filelist.tcl (TIDELINK_PHY_V2 build) — DO NOT EDIT."
    puts $fo "// Source: $orig"
    puts $fo "// Shim:   $shim"
    puts $fo "`define TIDELINK_PHY_V2"
    # Build-only knob: activates the 0xE4 autonomous Wlink lane-mask POR default
    # (bridge1 good lanes 2,5,6,7) in local_overrides/Wlink.v. Injected HERE (not
    # in a v2shim) so it reaches only the FPGA build, never the sims — keeping the
    # V2 8-lane sim oracles green. Now env-gated (see _lane_mask_e4 above):
    # TD_AUTO_LANE_MASK_E4=0 omits the define -> LANE_MASK_RESET = 8'hFF = 8 lanes
    # = the sim default = popcount 8 -> bytesPerCycle 16.
    if { $_lane_mask_e4 } {
        puts $fo "`define TD_AUTO_LANE_MASK_E4"
    } else {
        puts $fo "// TD_AUTO_LANE_MASK_E4 OMITTED (TD_AUTO_LANE_MASK_E4=0) -> LANE_MASK_RESET = 8'hFF (8 lanes)"
    }
    puts -nonewline $fo $body
    close $fo
    puts "INFO: tidelink V2: materialised $inc_name -> $out"
    return $out
}

###-----------------------------------------------------------------------------
### ASIC file-set define materialisation.
###
### Same problem and same fix as tidelink_materialise_v2_shim above, but driven
### from a plain source path instead of a `include shim: emit a standalone copy
### of the ASIC source with `define TIDELINK_PHY_V2 (+ the FPGA-only 0xE4 lane
### mask knob) textually prepended. The generated file is byte-identical to the
### ASIC source below the prepended lines, and the header records the source
### path so `grep "Source:"` on imp/fpga/gen_v2/ proves what was copied.
###-----------------------------------------------------------------------------
proc tidelink_materialise_asic_source {src gen_dir} {
    global _lane_mask_e4
    set out [file join $gen_dir [file tail $src]]
    set fh [open $src r]; set body [read $fh]; close $fh
    set fo [open $out w]
    puts $fo "// AUTO-GENERATED by fpga/filelist.tcl (TD_ASIC_FILESET=1 build) - DO NOT EDIT."
    puts $fo "// Source: $src"
    puts $fo "// Body below this header is a VERBATIM copy of that ASIC-file-set source."
    puts $fo "`define TIDELINK_PHY_V2"
    if { $_lane_mask_e4 } {
        puts $fo "`define TD_AUTO_LANE_MASK_E4"
    } else {
        puts $fo "// TD_AUTO_LANE_MASK_E4 OMITTED (TD_AUTO_LANE_MASK_E4=0) -> LANE_MASK_RESET = 8'hFF (8 lanes)"
    }
    puts -nonewline $fo $body
    close $fo
    puts "INFO: tidelink ASIC file set: materialised [file tail $src] -> $out"
    puts "INFO:   from $src"
    return $out
}

if { $_phy_v2 } {
    set _v2_gen_dir [file join $TIDELINK_HOME imp fpga gen_v2]
    file delete -force $_v2_gen_dir
    file mkdir $_v2_gen_dir
}
set fpga_flist [file join $TIDELINK_HOME flists $_flist_name]
if { ![file exists $fpga_flist] } {
    error "$_flist_name not found at $fpga_flist"
}

# Include paths: CMSDK and XHB500 verilog headers
set_property include_dirs [list \
    $CMSDK_DIR/logical/models/cells/verilog \
    $XHB500_IP_DIR/logical/xhb500/verilog \
] [current_fileset]

# Parse flist — supports:
#   +incdir+<path>   → added to include_dirs (appended to the list above)
#   <path>           → read_verilog -sv
# Comment markers: '#' and '//' (the FPGA flist uses Verilog-style '//').
# ${VAR} references are TCL-substituted via [subst] so the flist can carry
# literal references to ${TIDELINK_HOME}, ${CMSDK_DIR}, ${XHB500_IP_DIR}.
set fh [open $fpga_flist r]
set extra_incdirs {}
set extra_defines {}
set _asic_materialised {}
set _asic_skipped_headers {}
while { [gets $fh line] >= 0 } {
    set line [string trim $line]
    if { $line eq "" } { continue }
    if { [string index $line 0] eq "#" } { continue }
    if { [string range $line 0 1] eq "//" } { continue }

    set resolved [subst $line]
    if { [string match "+incdir+*" $resolved] } {
        set incdir [string range $resolved 8 end]
        lappend extra_incdirs $incdir
    } elseif { [string match "+define+*" $resolved] } {
        # e.g. +define+TIDELINK_PHY_V2 (the V2 flist carries its define
        # inline) -> verilog_define on the fileset.
        lappend extra_defines [string range $resolved 8 end]
    } elseif { $_phy_v2 && [string match "*/v2shims/*" $resolved] } {
        # Replace the VCS-facing shim with a materialised standalone copy
        # (see tidelink_materialise_v2_shim above). The +incdir+ lines sit at
        # the top of the flist, so extra_incdirs is fully populated by the
        # time the first shim entry appears.
        read_verilog -sv [tidelink_materialise_v2_shim $resolved $extra_incdirs $_v2_gen_dir]
    } elseif { $_asic_fileset && [string equal [file extension $resolved] ".svh"] } {
        # Header, not a module. See the TD_ASIC_FILESET note at the top.
        puts "INFO: tidelink ASIC file set: SKIPPED header (reached via +incdir+): $resolved"
        lappend _asic_skipped_headers $resolved
    } elseif { $_asic_fileset && [lsearch -exact $_asic_materialise [file tail $resolved]] >= 0 } {
        read_verilog -sv [tidelink_materialise_asic_source $resolved $_v2_gen_dir]
        lappend _asic_materialised $resolved
    } else {
        read_verilog -sv $resolved
    }
}
close $fh

# ---------------------------------------------------------------------------
# ASIC file set: supply the ONE leaf the tapeout file list cannot provide - the
# rf_16k compiled macro (a hard macro; no RTL exists for it anywhere in the
# ASIC sources). Added AFTER the flist so it can never mask a same-named file
# the flist itself provided.
# ---------------------------------------------------------------------------
if { $_asic_fileset } {
    set _rf16k_sub [file join $TIDELINK_HOME fpga asic_fileset rf_16k_fpga.v]
    if { ![file exists $_rf16k_sub] } {
        error "TD_ASIC_FILESET=1: rf_16k FPGA substitute not found at $_rf16k_sub"
    }
    read_verilog -sv $_rf16k_sub
    puts "INFO: tidelink ASIC file set: SUBSTITUTED rf_16k (TSMC65 compiled macro,\
 no RTL in the ASIC file set) -> $_rf16k_sub"

    puts "============================================================"
    puts "  ASIC FILE SET - SUBSTITUTION / DEVIATION LEDGER"
    puts "    ASIC sources materialised with `define (byte-identical body):"
    foreach f $_asic_materialised { puts "      $f" }
    puts "    Headers skipped (define no modules):"
    foreach f $_asic_skipped_headers { puts "      $f" }
    puts "    Modules NOT from the ASIC file set:"
    puts "      rf_16k  <- $_rf16k_sub"
    puts "    EVERYTHING ELSE is compiled verbatim from"
    puts "      flists/tidelink_top_full_asic_v2.flist"
    puts "============================================================"
}

# Apply any +define+ entries found in the flist
if { [llength $extra_defines] > 0 } {
    set existing_defs [get_property verilog_define [current_fileset]]
    set_property verilog_define [concat $existing_defs $extra_defines] [current_fileset]
}

# Append any +incdir+ entries found in the flist
if { [llength $extra_incdirs] > 0 } {
    set existing_incdirs [get_property include_dirs [current_fileset]]
    set_property include_dirs [concat $existing_incdirs $extra_incdirs] [current_fileset]
}
