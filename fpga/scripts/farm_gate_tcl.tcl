###-----------------------------------------------------------------------------
### TideLink FPGA — farm_gate Tcl dispatcher (pure-Tcl, no Vivado)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### WHY THIS EXISTS
###
### fpga/scripts/build_provenance.tcl already carries the campaign-hardened
### build-integrity procs (tl_verify_packaged_ip = the stale-IP / silent-V1
### content-hash gate; tl_write_manifest = the git-SHA + dirty + V1/V2 marker
### provenance stamp). Those procs were written pure-Tcl on purpose so they run
### under a plain `tclsh` as well as inside `vivado -mode batch`.
###
### build_design.tcl invokes them at BUILD time. This thin CLI lets the
### PRE-build gate (fpga/farm_gate.sh) invoke the SAME procs — one source of
### truth for "does the packaged IP reflect current RTL?" and "what did this
### tree come from?" — with no EDA licence, in seconds, so the stale-IP /
### silent-V1 classes turn red BEFORE an hours-long farm build launches.
###
### Subcommands (argv):
###   verify_ip <ip_root>          tl_verify_packaged_ip: content-hash every
###                                flist RTL source against the packaged copy;
###                                exit 1 on any STALE mismatch (else exit 0).
###   manifest  <out_path> <tgt>   tl_write_manifest: emit the provenance JSON
###                                (git SHA + -dirty + V1/V2 marker + flist +
###                                submodule pins + host + date) — no bitstream.
###   marker                       print "<V1|V2> <flist_name>" for the current
###                                TIDELINK_PHY_V2 selection (mirrors filelist.tcl).
###   flist_sources                print each resolved on-disk flist RTL source,
###                                one per line (used for the V2-source presence
###                                check).
###
### It is deliberately side-effect-light: `marker` / `flist_sources` never exit
### non-zero on content (only on a genuinely broken flist), so the shell gate
### decides pass/fail from their output. `verify_ip` keeps tl_verify_packaged_ip's
### own exit-1-on-stale contract so the gate can consult $?.
###-----------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
source [file join $here build_provenance.tcl]

if { [llength $argv] < 1 } {
    puts stderr "usage: farm_gate_tcl.tcl <verify_ip|manifest|marker|flist_sources> \[args...\]"
    exit 2
}

set cmd [lindex $argv 0]
switch -- $cmd {
    verify_ip {
        if { [llength $argv] < 2 } { puts stderr "verify_ip needs <ip_root>"; exit 2 }
        # tl_verify_packaged_ip prints its own report and exit 1's on a STALE
        # mismatch or a missing packaged-IP src dir.
        tl_verify_packaged_ip [lindex $argv 1]
    }
    manifest {
        if { [llength $argv] < 3 } { puts stderr "manifest needs <out_path> <target>"; exit 2 }
        tl_write_manifest [lindex $argv 1] [lindex $argv 2]
    }
    marker {
        lassign [tl_phy_marker] m f
        puts "$m $f"
    }
    flist_sources {
        # tl_repo_root prefers SOCLABS_TIDELINK_DIR, else walks up from the
        # sourced build_provenance.tcl (fpga/scripts -> repo root).
        foreach s [tl_flist_sources [tl_repo_root]] { puts $s }
    }
    default {
        puts stderr "farm_gate_tcl.tcl: unknown subcommand '$cmd'"
        exit 2
    }
}
