###-----------------------------------------------------------------------------
### TideLink Chiplet Subsystem - Build Provenance & Packaged-IP Integrity helpers
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### WHY THIS EXISTS
###
### The 2026 bring-up campaign lost multiple days to build-integrity failures
### that NOTHING caught at build time and that only manifested on silicon:
###
###   * silent-V1        - a V2 build silently packaged the V1 PHY IP (the
###                        TIDELINK_PHY_V2 env var was unset during package_ip),
###                        so the bitstream came out byte-identical to a V1 build
###                        and the "new" RTL was simply absent (root cause 8705a99).
###   * stale packaged IP - RTL under src/rtl was edited but `make package_ip`
###                        was NOT re-run, so build_design synthesised the OLD
###                        copy sitting in imp/fpga/tidelink_ip/src/ (see memory
###                        project_farm_package_ip_stale_2026_07_02 - on-silicon
###                        obs read all-zeros because the instrument was never
###                        actually synthesised).
###   * dropped-XDC /    - a constraint / combinational loop that an idealised
###     comb-loop          sim passed but that broke on silicon (cb33c9f).
###
### These helpers turn each of those into a BUILD-TIME artefact or a BUILD-TIME
### hard failure:
###
###   tl_write_manifest        - emits a provenance manifest next to the .bit so
###                              you can always answer "exactly what did this
###                              bitstream come from?" (git SHA + submodule pin +
###                              V1/V2 marker + resolved flist + target + host +
###                              timestamp). Kills the silent-V1 blind spot: the
###                              V-marker is recorded in the shipped artefact.
###   tl_verify_packaged_ip    - fails the build BEFORE synth if any flist-
###                              referenced RTL source differs from the copy that
###                              was imported into the packaged IP. Kills the
###                              stale-packaged-IP trap.
###
### They are pure-Tcl (exec git / exec sha256sum / file / env only - no Vivado
### design-database commands), so they run under both `vivado -mode batch` and a
### plain `tclsh`, which lets them be unit-tested without a full FPGA build.
###-----------------------------------------------------------------------------

# --- small utilities --------------------------------------------------------

# Repo root. Prefer the env the Makefile exports; fall back to walking up from
# this script (fpga/scripts/build_provenance.tcl -> repo root is ../../..).
proc tl_repo_root {} {
    if { [info exists ::env(SOCLABS_TIDELINK_DIR)] && $::env(SOCLABS_TIDELINK_DIR) ne "" } {
        return $::env(SOCLABS_TIDELINK_DIR)
    }
    return [file normalize [file join [file dirname [info script]] .. ..]]
}

# sha256 of a file's contents (via coreutils sha256sum - always present on the
# Linux build hosts; the packaged-IP src copies and the RTL originals are
# compared purely by content so line-ending / mtime differences are irrelevant).
proc tl_sha256 {path} {
    if { ![file exists $path] } { return "" }
    set out [exec sha256sum $path]
    return [lindex [split $out] 0]
}

# git SHA of the MAIN tree, with a "-dirty" suffix when the working tree has
# uncommitted changes. "-dirty" is the single most useful provenance flag: a
# dirty bitstream can never be reproduced from a commit, so it must be visible.
proc tl_git_sha {root} {
    if { [catch { exec git -C $root rev-parse HEAD } sha] } {
        return "unknown"
    }
    set dirty ""
    if { ![catch { exec git -C $root status --porcelain } st] && [string trim $st] ne "" } {
        set dirty "-dirty"
    }
    return "${sha}${dirty}"
}

# Recorded submodule pin (the gitlink SHA in the tree). This is the commit the
# superproject PINS, independent of whether the submodule is checked out - so it
# is the correct provenance value even on a host that never ran `submodule
# update`. Returns "-" if the path is not a gitlink / not present.
proc tl_submodule_pin {root subpath} {
    if { [catch { exec git -C $root rev-parse HEAD:$subpath } pin] } {
        return "-"
    }
    return [string trim $pin]
}

# V1/V2 marker + the flist name that WILL be resolved. Mirrors the selection
# logic in fpga/filelist.tcl EXACTLY (TIDELINK_PHY_V2==1 -> V2) so the manifest
# records the same flist the packaging step consumed. Returns {marker flist}.
proc tl_phy_marker {} {
    set v2 0
    if { [info exists ::env(TIDELINK_PHY_V2)] && $::env(TIDELINK_PHY_V2) == 1 } { set v2 1 }
    # TD_ASIC_FILESET=1 (fpga/filelist.tcl) packages the TAPEOUT file list
    # instead of the FPGA one. Before this branch tl_phy_marker returned
    # "tidelink_fpga_v2.flist" unconditionally on any V2 build, which made this
    # proc fail OPEN in the most damaging possible way for an ASIC-file-set
    # image: the manifest would have NAMED THE WRONG FILE LIST - asserting the
    # image contained the recovery-bearing FPGA FCSMs when it contains the
    # recovery-stripped tapeout ones - and tl_verify_packaged_ip (which resolves
    # its comparison set through this same proc) would have hash-compared the
    # packaged ASIC copies against the FPGA sources and hard-failed the build as
    # "stale IP". The marker is what names the artefact, so it must be distinct.
    set asic 0
    if { [info exists ::env(TD_ASIC_FILESET)] && $::env(TD_ASIC_FILESET) == 1 } { set asic 1 }
    if { $asic } {
        if { !$v2 } {
            error "TD_ASIC_FILESET=1 without TIDELINK_PHY_V2=1 - refusing to stamp\
                   a marker for a combination fpga/filelist.tcl rejects."
        }
        return [list "V2-ASICFILESET" "tidelink_top_full_asic_v2.flist"]
    }
    if { $v2 } {
        return [list "V2" "tidelink_fpga_v2.flist"]
    }
    return [list "V1" "tidelink_fpga.flist"]
}

# Basenames that fpga/filelist.tcl MATERIALISES on the ASIC-file-set path (a
# standalone copy with `define TIDELINK_PHY_V2 prepended, because no
# project-level define survives ipx::package_project into the IP's OOC synth).
# The packaged copy therefore legitimately differs from the on-disk source, in
# exactly the same way and for exactly the same reason as the */v2shims/* lines
# tl_flist_sources already skips on the FPGA path. Without this they would
# false-positive as STALE and block every ASIC-file-set build.
proc tl_asic_materialised_basenames {} {
    return [list tidelink_top.sv Wlink.v axi_chiplet_controller.sv]
}

# Resolve the flist to the list of REAL on-disk RTL source files it references.
# Mirrors fpga/filelist.tcl's parser (same ${VAR} substitution, same comment
# markers) but WITHOUT read_verilog, so it needs no Vivado project. Skips
# +incdir/+define directives and the V2 shim lines (those are materialised /
# generated, so their packaged copy legitimately differs from the on-disk shim
# and would false-positive the integrity compare).
proc tl_flist_sources {root} {
    # Variables the flist ${...} placeholders expand against - same names as
    # fpga/filelist.tcl.
    set TIDELINK_HOME        $root
    set SOCLABS_TIDELINK_DIR $root
    set CMSDK_DIR            [expr {[info exists ::env(CMSDK_DIR)]      ? $::env(CMSDK_DIR)      : ""}]
    set XHB500_IP_DIR        [expr {[info exists ::env(XHB500_IP_DIR)]  ? $::env(XHB500_IP_DIR)  : ""}]
    if { [info exists ::env(CMSDK_FPGA_SRAM_V)] && $::env(CMSDK_FPGA_SRAM_V) ne "" } {
        set CMSDK_FPGA_SRAM_V $::env(CMSDK_FPGA_SRAM_V)
    } else {
        set CMSDK_FPGA_SRAM_V [file join $CMSDK_DIR logical models memories cmsdk_fpga_sram.v]
    }

    lassign [tl_phy_marker] _marker flist_name
    set flist [file join $root flists $flist_name]
    if { ![file exists $flist] } {
        error "tl_flist_sources: flist not found: $flist"
    }

    set sources {}
    set fh [open $flist r]
    while { [gets $fh line] >= 0 } {
        set line [string trim $line]
        if { $line eq "" } { continue }
        if { [string index $line 0] eq "#" } { continue }
        if { [string range $line 0 1] eq "//" } { continue }
        # -nocommands: expand ${VAR} only, never evaluate [..] in a path.
        set resolved [subst -nocommands $line]
        if { [string match "+incdir+*" $resolved] } { continue }
        if { [string match "+define+*" $resolved] } { continue }
        if { [string match "*/v2shims/*" $resolved] } { continue }
        if { [info exists ::env(TD_ASIC_FILESET)] && $::env(TD_ASIC_FILESET) == 1 &&
             [lsearch -exact [tl_asic_materialised_basenames] [file tail $resolved]] >= 0 } {
            # Materialised on the ASIC path - see tl_asic_materialised_basenames.
            continue
        }
        lappend sources $resolved
    }
    close $fh
    return $sources
}

# --- integrity check #2: packaged IP matches source ------------------------
#
# Compares every flist-referenced RTL source against the copy that
# ipx::package_project imported into <ip_root>/src/ (import_files copies the
# actual file CONTENT in, so a stale packaged IP shows up as a content hash
# mismatch on the basename). FAILS THE BUILD (exit 1) on any mismatch.
#
# Match policy (deliberately conservative to avoid false positives):
#   - packaged copy present & hash EQUAL   -> ok
#   - packaged copy present & hash DIFFERS -> STALE  (hard fail)
#   - packaged copy ABSENT                 -> skipped+reported (vendor files that
#                                             package under a different name, or
#                                             `include-only headers, are not a
#                                             stale-edit signal on their own)
# The stale-edit trap this guards (edit src/rtl, forget package_ip) always
# produces a present-but-differing basename, which is exactly the hard-fail case.
proc tl_verify_packaged_ip {ip_root} {
    set src_dir [file join $ip_root src]
    puts "\[tl_ip_verify\] packaged-IP integrity check against $src_dir"
    if { ![file isdirectory $src_dir] } {
        puts "==========================================="
        puts " TideLink packaged-IP integrity check FAILED"
        puts " Packaged IP src dir not found: $src_dir"
        puts " -> run 'make package_ip' before build_design."
        puts "==========================================="
        exit 1
    }

    set root [tl_repo_root]
    set sources [tl_flist_sources $root]

    # index packaged copies by basename
    set packaged {}
    foreach f [glob -nocomplain -directory $src_dir *] {
        dict set packaged [file tail $f] $f
    }

    set n_ok 0
    set n_skip 0
    set missing {}
    set mismatches {}
    foreach s $sources {
        if { ![file exists $s] } {
            # A flist entry that does not resolve to a real file is a separate
            # (flist / unset-env) issue, NOT the stale-IP trap. The stale-edit
            # trap this gate guards ALWAYS manifests as a present-in-package
            # basename whose content DIFFERS - never as a missing source. Treat
            # missing-on-disk as a reported WARNING, not a hard fail, so an
            # env-resolution artefact in the verify context (e.g. CMSDK_DIR /
            # XHB500_IP_DIR resolving to a vendor path that is absent here)
            # cannot false-positive and block every build.
            lappend missing $s
            continue
        }
        set base [file tail $s]
        if { ![dict exists $packaged $base] } {
            incr n_skip
            continue
        }
        set pkg [dict get $packaged $base]
        set hs [tl_sha256 $s]
        set hp [tl_sha256 $pkg]
        if { $hs eq $hp } {
            incr n_ok
        } else {
            lappend mismatches [list $s "packaged copy $pkg is STALE (source sha $hs != packaged sha $hp)"]
        }
    }

    puts "\[tl_ip_verify\] checked [llength $sources] flist sources: $n_ok match, $n_skip not-in-package (skipped), [llength $missing] unresolved (warn), [llength $mismatches] STALE"
    if { [llength $missing] > 0 } {
        puts "\[tl_ip_verify\] WARNING: [llength $missing] flist source(s) did not resolve to a file in this context (not the stale-IP class; check flist / *_IP_DIR env):"
        foreach s [lrange $missing 0 7] { puts "\[tl_ip_verify\]   ? $s" }
        if { [llength $missing] > 8 } { puts "\[tl_ip_verify\]   ... and [expr {[llength $missing]-8}] more" }
    }

    if { [llength $mismatches] > 0 } {
        puts "==========================================="
        puts " TideLink packaged-IP integrity check FAILED"
        puts " The packaged IP under $src_dir does NOT reflect current RTL."
        puts " This is the stale-packaged-IP trap (edited RTL, forgot"
        puts " 'make package_ip'): build_design would synthesise the OLD"
        puts " sources. Offending files:"
        foreach m $mismatches {
            puts "   - [lindex $m 0]"
            puts "       [lindex $m 1]"
        }
        puts "-------------------------------------------"
        puts " Fix: re-run 'make package_ip' (with the SAME TIDELINK_PHY_V2"
        puts " setting as this build) so the packaged IP is regenerated"
        puts " from current sources, then rebuild."
        puts "==========================================="
        exit 1
    }
    puts "\[tl_ip_verify\] OK - packaged IP reflects current RTL."
}

# --- provenance manifest #1 -------------------------------------------------
#
# Emit a JSON provenance manifest alongside the build outputs. Field names reuse
# pynq_host/scripts/make_bitstream_manifest.sh where sensible (sha256 /
# source_commit / build_host / build_date / target / label) and ADD the fields
# the campaign proved were load-bearing: the V1/V2 marker, the resolved flist,
# and the submodule pins. Generated INSIDE build_design.tcl (via the call site)
# so it cannot be forgotten the way the post-hoc shell script could be.
proc tl_write_manifest {out_path target {bit_path ""}} {
    set root [tl_repo_root]
    set sha  [tl_git_sha $root]
    set dirty [expr {[string match "*-dirty" $sha] ? "true" : "false"}]
    lassign [tl_phy_marker] marker flist
    set phy_pin  [tl_submodule_pin $root deps/tidelink-phy]
    set gpio_pin [tl_submodule_pin $root deps/tidelink-gpio-phy]
    set host [expr {[info exists ::env(HOSTNAME)] && $::env(HOSTNAME) ne "" ? $::env(HOSTNAME) : "unknown"}]
    if { $host eq "unknown" } {
        catch { set host [exec hostname] }
    }
    # clock format is available in Vivado's Tcl and plain tclsh alike.
    set date [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]

    set bit_sha "-"
    if { $bit_path ne "" && [file exists $bit_path] } {
        set bit_sha [tl_sha256 $bit_path]
    }

    # Low 32 bits of the (clean) git SHA - the value stamped into the bitstream
    # USR_ACCESS register (see build_design.tcl). Recorded here too so the
    # on-silicon USR_ACCESS read-back can be cross-checked against the manifest.
    set clean_sha [string map {"-dirty" ""} $sha]
    set usr_access "-"
    if { [regexp {^[0-9a-fA-F]{8,}} $clean_sha] } {
        set usr_access "0x[string range $clean_sha end-7 end]"
    }

    set fo [open $out_path w]
    puts $fo "\{"
    puts $fo "  \"schema\":          \"tidelink-build-manifest/1\","
    puts $fo "  \"sha256\":          \"$bit_sha\","
    puts $fo "  \"source_commit\":   \"$sha\","
    puts $fo "  \"git_dirty\":       $dirty,"
    puts $fo "  \"phy_marker\":      \"$marker\","
    puts $fo "  \"flist\":           \"$flist\","
    puts $fo "  \"submodule_pins\": \{"
    puts $fo "    \"deps/tidelink-phy\":      \"$phy_pin\","
    puts $fo "    \"deps/tidelink-gpio-phy\": \"$gpio_pin\""
    puts $fo "  \},"
    puts $fo "  \"usr_access\":      \"$usr_access\","
    puts $fo "  \"target\":          \"$target\","
    puts $fo "  \"build_host\":      \"$host\","
    puts $fo "  \"build_date\":      \"$date\","
    puts $fo "  \"label\":           \"$target-$marker\""
    puts $fo "\}"
    close $fo

    puts "\[tl_manifest\] wrote $out_path"
    puts "\[tl_manifest\]   commit=$sha marker=$marker flist=$flist"
    puts "\[tl_manifest\]   phy_pin=$phy_pin target=$target host=$host usr_access=$usr_access"
}
