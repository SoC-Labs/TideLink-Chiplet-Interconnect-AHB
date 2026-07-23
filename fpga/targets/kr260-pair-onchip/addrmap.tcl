###############################################################################
# addrmap.tcl  --  Canonical, machine-checkable address spec for the
#                  kr260-pair-onchip target (two full TideLink instances in
#                  one xck26 bitstream).  WORKSTREAM W2.
#
# This is the SINGLE SOURCE OF TRUTH for the dual-instance address map.
#   * W5 (BD tcl) sources this file and calls  tl_emit_assign_bd_address
#     to produce the 12 assign_bd_address commands (or copies them verbatim).
#   * W8 (host runners) reads  tl_addr_inst0 / tl_addr_inst1 / tl_pair_base
#     as its INST map.
#
# It contains NO Vivado commands, so it is safe to `source` under plain tclsh
# (which runs the self-check below and PASSES) and equally safe to `source`
# inside vivado -mode batch (the self-check runs at source time and aborts the
# build early if any invariant is violated).
#
# ---------------------------------------------------------------------------
# CANONICAL TABLE (plan KR260_PAIR_ONCHIP_PLAN.md sec 3.2)
#
#   inst0 = tidelink_0 = die_a (role-strap 0, master-by-priority)
#   inst1 = tidelink_1 = die_b (role-strap 1, slave-by-priority)
#
#   Uniform scheme:  inst1 = inst0 + 0x0800_0000  on EVERY aperture, so the
#   host convention  inst1_addr = inst0_addr | 0x0800_0000  holds for every
#   base (all inst0 bases have bit-27 clear, so OR == ADD -- asserted below).
#
#   aperture   inst0 (die_a)   inst1 (die_b)   range           PS window
#   --------   -------------   -------------   -------------    ---------
#   ahb_sub    0x8000_0000     0x8800_0000     0x0400_0000 64M  HPM0_LPD
#   apb        0x8403_0000     0x8C03_0000     0x0000_8000 32K  HPM0_LPD
#   strap GPIO 0x8404_0000     0x8C04_0000     0x0000_1000  4K  HPM0_LPD
#   debug GPIO 0x8404_1000     0x8C04_1000     0x0000_1000  4K  HPM0_LPD
#   ahb_tx     0xA400_0000     0xAC00_0000     0x0001_0000 64K  HPM0_FPD
#   ahb_fifo   0xA401_0000     0xAC01_0000     0x0001_0000 64K  HPM0_FPD
#
#   PAIR_BASE bake:  inst0 -> 0x8C03_2000   inst1 -> 0x8403_2000
#     == the OTHER instance's apb base + 0x2000  (asserted below).
#
#   inst0 rows are byte-identical to kr260-pair-ptp/tidelink_design.tcl:900-921
#   so existing single-instance host tooling and docs stay valid.
#
# ---------------------------------------------------------------------------
# OUT OF SCOPE FOR PHASE 1:
#   PTP / PHC apertures (ahb_ptp 0x8402_0000, phc apb 0x8405_0000 on the
#   single-die target) are NOT mapped here -- kr260-pair-onchip builds with
#   FPGA_TIDELINK_PTP=0 (plan sec 3.1).  Phase-2 skew-inject regs
#   (0x8404_2000, W11) are likewise not part of this phase-1 spec.
#
# ---------------------------------------------------------------------------
# ZynqMP (xck26) PS master window limits -- established from the repo, not
# guessed.  kr260-pair-ptp/tidelink_design.tcl:883-885 documents them verbatim:
#     "M_AXI_HPM0_LPD window (0x8000_0000, 512 MB)"
#     "M_AXI_HPM0_FPD window (0xA000_0000, 256 MB)"
#   These are the Vivado address-editor defaults for the ZynqMP low PL
#   aperture (UG1085 / PG247): the 1 GB PL region 0x8000_0000-0xBFFF_FFFF is
#   partitioned LPD=lower 512 MB, FPD-HPM0=next 256 MB, FPD-HPM1=top 256 MB.
#     HPM0_LPD : 0x8000_0000 .. 0x9FFF_FFFF   (512 MB)  <- all control plane
#     HPM0_FPD : 0xA000_0000 .. 0xAFFF_FFFF   (256 MB)  <- all data plane
#   MPSoC DDR low region 0x0000_0000..0x7FFF_FFFF and PS-register region
#   >= 0xFD00_0000 are explicitly proven clear in the self-check.
###############################################################################

# ---- Window / region constants (all inclusive limits) ----------------------
set TL_HPM0_LPD_BASE   0x80000000   ;# control-plane master aperture
set TL_HPM0_LPD_LIMIT  0x9FFFFFFF   ;#   512 MB
set TL_HPM0_FPD_BASE   0xA0000000   ;# data-plane master aperture
set TL_HPM0_FPD_LIMIT  0xAFFFFFFF   ;#   256 MB

set TL_DDR_BASE        0x00000000   ;# MPSoC DDR low region ...
set TL_DDR_LIMIT       0x7FFFFFFF   ;#   ... must not be touched
set TL_PS_PERIPH_BASE  0xFD000000   ;# PS registers/peripherals -- keep below

set TL_INST_STRIDE     0x08000000   ;# inst1 = inst0 + this (== bit-27)
set TL_PAIR_OFFSET     0x00002000   ;# PAIR_BASE = peer apb base + this

# ---------------------------------------------------------------------------
# The aperture table.  One row per aperture; off0 is the inst0 (die_a) base,
# range is shared by both instances, seg0/seg1 are the get_bd_addr_segs paths
# W5 will target.  inst1 offset is DERIVED (off0 | stride) and asserted equal
# to (off0 + stride) so the host OR-convention is provably safe.
# ---------------------------------------------------------------------------
set tl_aper [dict create \
  ahb_sub  [dict create plane ctrl range 0x04000000 off0 0x80000000 \
                seg0 {tidelink_0/ahb_sub/Reg}          seg1 {tidelink_1/ahb_sub/Reg}] \
  apb      [dict create plane ctrl range 0x00008000 off0 0x84030000 \
                seg0 {tidelink_0/apb/Reg}              seg1 {tidelink_1/apb/Reg}] \
  strap    [dict create plane ctrl range 0x00001000 off0 0x84040000 \
                seg0 {axi_gpio_strap/S_AXI/Reg}        seg1 {axi_gpio_strap_1/S_AXI/Reg}] \
  debug    [dict create plane ctrl range 0x00001000 off0 0x84041000 \
                seg0 {axi_gpio_debug_unlock/S_AXI/Reg} seg1 {axi_gpio_debug_unlock_1/S_AXI/Reg}] \
  ahb_tx   [dict create plane data range 0x00010000 off0 0xA4000000 \
                seg0 {tidelink_0/ahb_tx/Reg}           seg1 {tidelink_1/ahb_tx/Reg}] \
  ahb_fifo [dict create plane data range 0x00010000 off0 0xA4010000 \
                seg0 {tidelink_0/ahb_fifo/Reg}         seg1 {tidelink_1/ahb_fifo/Reg}] \
]

# ===========================================================================
# Helpers
# ===========================================================================
proc tl_hx {v} { return [format "0x%08X" [expr {$v & 0xFFFFFFFF}]] }

# inst1 base for a given inst0 base, defined by the OR convention.
proc tl_inst1_off {off0} {
    global TL_INST_STRIDE
    return [expr {$off0 | $TL_INST_STRIDE}]
}

# Flatten the table into a segment list: {name start end plane seg} x 12.
proc tl_segments {} {
    global tl_aper
    set segs {}
    dict for {name a} $tl_aper {
        set off0 [dict get $a off0]
        set off1 [tl_inst1_off $off0]
        set rng  [dict get $a range]
        lappend segs [list ${name}@i0 $off0 [expr {$off0 + $rng - 1}] \
                           [dict get $a plane] [dict get $a seg0]]
        lappend segs [list ${name}@i1 $off1 [expr {$off1 + $rng - 1}] \
                           [dict get $a plane] [dict get $a seg1]]
    }
    return $segs
}

# PAIR_BASE bake for an instance: the OTHER instance's apb base + 0x2000.
#   inst 0 (die_a) bakes peer(=inst1) apb + off ; inst 1 (die_b) bakes inst0 apb + off.
# (No inline ';#' comments inside a braced switch/if body: Tcl parses them as
#  spurious patterns -- use plain if.)
proc tl_pair_base {inst} {
    global tl_aper TL_INST_STRIDE TL_PAIR_OFFSET
    set apb0 [dict get [dict get $tl_aper apb] off0]
    set apb1 [tl_inst1_off $apb0]
    if {$inst == 0} {
        return [expr {$apb1 + $TL_PAIR_OFFSET}]
    } elseif {$inst == 1} {
        return [expr {$apb0 + $TL_PAIR_OFFSET}]
    }
    error "tl_pair_base: inst must be 0 or 1, got '$inst'"
}

# Per-instance name->base dict for host tooling (W8 consumes these).
proc tl_addr_map {inst} {
    global tl_aper
    set m [dict create]
    dict for {name a} $tl_aper {
        set off0 [dict get $a off0]
        if {$inst == 0} {
            dict set m $name [tl_hx $off0]
        } else {
            dict set m $name [tl_hx [tl_inst1_off $off0]]
        }
    }
    return $m
}

# ===========================================================================
# SELF-CHECK  --  errors loudly on ANY violation.  Runs at source time.
# ===========================================================================
proc tl_addr_selfcheck {} {
    global tl_aper TL_INST_STRIDE TL_PAIR_OFFSET
    global TL_HPM0_LPD_BASE TL_HPM0_LPD_LIMIT TL_HPM0_FPD_BASE TL_HPM0_FPD_LIMIT
    global TL_DDR_BASE TL_DDR_LIMIT TL_PS_PERIPH_BASE

    set nfail 0
    set fail {}

    set segs [tl_segments]

    # --- (1) OR-convention: inst1 == inst0 + stride == inst0 | stride, and
    #         every inst0 base has bit-27 (the stride bit) clear. --------------
    dict for {name a} $tl_aper {
        set off0 [dict get $a off0]
        if {[expr {$off0 & $TL_INST_STRIDE}] != 0} {
            incr nfail
            lappend fail "OR-convention: inst0 '$name' base [tl_hx $off0] has\
                          stride bit [tl_hx $TL_INST_STRIDE] SET; inst1|inst0 != inst1+stride"
        }
        set or_off  [expr {$off0 | $TL_INST_STRIDE}]
        set add_off [expr {$off0 + $TL_INST_STRIDE}]
        if {$or_off != $add_off} {
            incr nfail
            lappend fail "OR-convention: '$name' OR=[tl_hx $or_off] != ADD=[tl_hx $add_off]"
        }
    }

    # --- (2) No overlap between ANY two of the 12 segments. -------------------
    set n [llength $segs]
    for {set i 0} {$i < $n} {incr i} {
        set A [lindex $segs $i]
        lassign $A an as ae ap asg
        for {set j [expr {$i + 1}]} {$j < $n} {incr j} {
            set B [lindex $segs $j]
            lassign $B bn bs be bp bsg
            if {($as <= $be) && ($bs <= $ae)} {
                incr nfail
                lappend fail "OVERLAP: $an \[[tl_hx $as]..[tl_hx $ae]\] intersects\
                              $bn \[[tl_hx $bs]..[tl_hx $be]\]"
            }
        }
    }

    # --- (3) Reachability: ctrl within HPM0_LPD, data within HPM0_FPD. --------
    #         (base reachable AND the whole range fits inside the window.)
    foreach S $segs {
        lassign $S sn ss se sp ssg
        if {$sp eq "ctrl"} {
            set wb $TL_HPM0_LPD_BASE ; set wl $TL_HPM0_LPD_LIMIT ; set wn HPM0_LPD
        } else {
            set wb $TL_HPM0_FPD_BASE ; set wl $TL_HPM0_FPD_LIMIT ; set wn HPM0_FPD
        }
        if {($ss < $wb) || ($se > $wl)} {
            incr nfail
            lappend fail "UNREACHABLE: $sn ($sp) \[[tl_hx $ss]..[tl_hx $se]\] not inside\
                          $wn \[[tl_hx $wb]..[tl_hx $wl]\]"
        }
    }

    # --- (4) No collision with MPSoC DDR or PS peripheral windows. ------------
    foreach S $segs {
        lassign $S sn ss se sp ssg
        if {($ss <= $TL_DDR_LIMIT) && ($TL_DDR_BASE <= $se)} {
            incr nfail
            lappend fail "DDR COLLISION: $sn \[[tl_hx $ss]..[tl_hx $se]\] hits DDR\
                          \[[tl_hx $TL_DDR_BASE]..[tl_hx $TL_DDR_LIMIT]\]"
        }
        if {$se >= $TL_PS_PERIPH_BASE} {
            incr nfail
            lappend fail "PS-PERIPH COLLISION: $sn end [tl_hx $se] >= PS window base\
                          [tl_hx $TL_PS_PERIPH_BASE]"
        }
    }

    # --- (5) PAIR_BASE == the OTHER instance's apb base + 0x2000, and lands
    #         inside the peer apb segment, with [13:0] == 0x2000 (fc_adapter
    #         ships only rtn_haddr[13:0]; plan sec 3.2). --------------------------
    set apb0 [dict get [dict get $tl_aper apb] off0]
    set apb1 [tl_inst1_off $apb0]
    set apbrng [dict get [dict get $tl_aper apb] range]
    # inst0 bakes peer(inst1) apb + off ; inst1 bakes peer(inst0) apb + off
    foreach {inst peer_off} [list 0 $apb1 1 $apb0] {
        set pb  [tl_pair_base $inst]
        set exp [expr {$peer_off + $TL_PAIR_OFFSET}]
        if {$pb != $exp} {
            incr nfail
            lappend fail "PAIR_BASE inst$inst = [tl_hx $pb] != peer_apb+0x2000 = [tl_hx $exp]"
        }
        if {($pb < $peer_off) || ($pb > [expr {$peer_off + $apbrng - 1}])} {
            incr nfail
            lappend fail "PAIR_BASE inst$inst = [tl_hx $pb] outside peer apb seg\
                          \[[tl_hx $peer_off]..[tl_hx [expr {$peer_off + $apbrng - 1}]]\]"
        }
        if {[expr {$pb & 0x3FFF}] != 0x2000} {
            incr nfail
            lappend fail "PAIR_BASE inst$inst = [tl_hx $pb] : \[13:0\] != 0x2000\
                          (fc_adapter delivers on rtn_haddr\[13:0\])"
        }
    }

    if {$nfail > 0} {
        error "tl_addr_selfcheck FAILED with $nfail violation(s):\n  [join $fail "\n  "]"
    }
    puts "tl_addr_selfcheck: PASS -- [llength $segs] segments, 0 overlaps,\
          all in-window, DDR/PS clear, PAIR_BASE bakes verified."
    return 1
}

# ===========================================================================
# Pretty printer -- the resolved table.
# ===========================================================================
proc tl_addr_print {} {
    global tl_aper
    puts ""
    puts "kr260-pair-onchip resolved address map (inst0=die_a, inst1=die_b):"
    puts [format "  %-9s %-13s %-13s %-13s %-8s" \
              aperture inst0 inst1 range plane]
    puts "  [string repeat - 62]"
    dict for {name a} $tl_aper {
        set off0 [dict get $a off0]
        set off1 [tl_inst1_off $off0]
        set rng  [dict get $a range]
        puts [format "  %-9s %-13s %-13s %-13s %-8s" \
                  $name [tl_hx $off0] [tl_hx $off1] [tl_hx $rng] [dict get $a plane]]
    }
    puts "  [string repeat - 62]"
    puts [format "  %-9s inst0=%-11s inst1=%-11s (= peer apb + 0x%04X)" \
              PAIR_BASE [tl_hx [tl_pair_base 0]] [tl_hx [tl_pair_base 1]] \
              $::TL_PAIR_OFFSET]
    puts ""
}

# ===========================================================================
# assign_bd_address emitter -- W5 sources this file and calls this proc so the
# BD tcl and this spec can NEVER drift.  Returns the 12-line block as a string;
# W5 may `eval` it or copy it.  (No Vivado commands are executed here.)
# ===========================================================================
# Line order matches plan sec 3.2 verbatim: control plane (inst0 then inst1),
# then data plane (inst0 then inst1); aperture order is the dict insertion
# order (ahb_sub,apb,strap,debug ; ahb_tx,ahb_fifo).
proc tl_emit_assign_bd_address {} {
    global tl_aper
    set lines {}
    foreach {plane hdr} {ctrl "# ---- Control plane (M_AXI_HPM0_LPD) ----" \
                         data "# ---- Data plane (M_AXI_HPM0_FPD) ----"} {
        lappend lines $hdr
        foreach which {seg0 seg1} {
            dict for {name a} $tl_aper {
                if {[dict get $a plane] ne $plane} { continue }
                set off0 [dict get $a off0]
                set off  [expr {$which eq "seg0" ? $off0 : [tl_inst1_off $off0]}]
                set rng  [dict get $a range]
                set seg  [dict get $a $which]
                lappend lines [format \
                    "assign_bd_address -offset %s -range %s \[get_bd_addr_segs {%s}\]" \
                    [tl_hx $off] [tl_hx $rng] $seg]
            }
        }
    }
    return [join $lines "\n"]
}

# ---------------------------------------------------------------------------
# Public accessors (name->base dicts) captured at source time for W8/host.
# ---------------------------------------------------------------------------
set tl_addr_inst0 [tl_addr_map 0]   ;# die_a
set tl_addr_inst1 [tl_addr_map 1]   ;# die_b
set tl_pair_base  [dict create 0 [tl_hx [tl_pair_base 0]] 1 [tl_hx [tl_pair_base 1]]]

# ===========================================================================
# RUN AT SOURCE TIME: verify then print.  Sourcing this file under tclsh or
# Vivado both executes the self-check; a violation aborts with `error`.
# ===========================================================================
tl_addr_selfcheck
tl_addr_print
