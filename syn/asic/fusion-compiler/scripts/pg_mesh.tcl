#-----------------------------------------------------------------------------
# Power-ground mesh insertion for the tidelink_top partition.
#
# Builds:
#   - supply nets + ports for VDD / VSS (UPF-style)
#   - cell PG pin auto-connection (every std cell + rf_16k macro grabs VDD/VSS)
#   - M1 follow-pin rails inside every std-cell row
#   - M5 horizontal + M6 vertical mesh, interleaved VDD/VSS 2 μm wide straps
#     — stitches the M1 rails together and gives the rf_16k macro a
#     low-impedance path. Reserves M7+ for chip-top global routing.
#   - rf_16k macro M4 long-pin connection pattern (per-pin M5 strap)
#
# Run after floorplan + macros are placed, before compile_fusion runs
# std-cell placement — sourced from 1_init_design.tcl after place_pins.tcl.
#
# Pitch + width are conservative starting points for the ~1100 × 600 μm
# tile @ 250 MHz hclk. Tune after the first IR-drop analysis at chip top
# (the partition only owns its own M1-M6 mesh; chip-top stitches M7+).
#-----------------------------------------------------------------------------

# ── Step 1: power domain + supply nets + ports ───────────────────────────
# Single voltage domain — chip-top wires the partition's VDD/VSS supply
# ports to its global rails at integration. UPF-style flow: create the
# domain first, then nets in that domain's scope, then ports at the
# boundary, then designate VDD/VSS as the domain's primary supplies so
# connect_pg_net knows what to tie cell PG pins to.
puts "INFO: \[pg_mesh\] creating power domain + supply nets + ports"

create_power_domain PD_TOP -include_scope

create_supply_net VDD -domain PD_TOP
create_supply_net VSS -domain PD_TOP

create_supply_port VDD -direction in
create_supply_port VSS -direction in

connect_supply_net VDD -ports {VDD}
connect_supply_net VSS -ports {VSS}

set_domain_supply_net PD_TOP \
    -primary_power_net  VDD \
    -primary_ground_net VSS

# Voltage per corner — UPF requires the supply net's voltage to be
# defined for every corner that scenarios reference (UPF-520).
foreach corner_name {slow fast} {
    if {[sizeof_collection [get_corners -quiet $corner_name]] > 0} {
        set v [expr {$corner_name eq "slow" ? 1.08 : 1.32}]
        set_voltage $v   -object_list [get_supply_nets VDD] -corners $corner_name
        set_voltage 0.00 -object_list [get_supply_nets VSS] -corners $corner_name
    }
}

# ── Step 2: connect cell PG pins to the supply nets ──────────────────────
puts "INFO: \[pg_mesh\] connect_pg_net -automatic"
connect_pg_net -automatic

# ── Step 3: M1 follow-pin pattern (std-cell rails) ───────────────────────
# tcbn65lp 9-track std cells carry their own M1 PG rails by construction;
# this pattern tells compile_pg to use them so it drops via stacks from
# the M5 mesh down to M1 at every crossing. rail_width 0.18 is the
# follow-pin nominal that lands via stacks correctly on both
# tcbn65lp 9-track and Arm sc12 cells (same rough M1 PG rail
# geometry); a tighter value can be set in pg_mesh.tcl if the foundry
# rail width differs materially.
puts "INFO: \[pg_mesh\] creating M1 follow-pin pattern"
create_pg_std_cell_conn_pattern std_cell_rail \
    -layers {M1} \
    -rail_width 0.18

# ── Step 4: M5 horizontal + M6 vertical mesh ─────────────────────────────
# 2 μm wide straps, 25 μm pitch, interleaved VDD/VSS pairs.
#
# 50 μm pitch — the tidelink_top partition has ONE macro pinned at one
# corner, so the std-cell area is one contiguous L-shape (unlike ahb_qspi's
# two-column cache layout that forced its 25 μm fix). The 25 μm pitch
# was characterised here on 2026-05-20 and DOUBLED the floating-cell
# count (4623 → 9023 wire-stub artefacts) — i.e. the denser mesh adds
# more trim:true stub fragments without resolving any real disconnect.
# Override with FC_PG_PITCH=<μm> for IR-drop-tightening experiments.
set pg_pitch 50.0
if {[info exists ::env(FC_PG_PITCH)]} { set pg_pitch $::env(FC_PG_PITCH) }
puts "INFO: \[pg_mesh\] creating M5/M6 mesh pattern (pitch=${pg_pitch} μm)"
create_pg_mesh_pattern mesh_m5_m6 -layers [list \
    "{horizontal_layer: M5} {width: 2.0} {pitch: $pg_pitch} {spacing: interleaving} {offset: 10.0} {trim: true}" \
    "{vertical_layer:   M6} {width: 2.0} {pitch: $pg_pitch} {spacing: interleaving} {offset: 10.0} {trim: true}"]

# ── Step 5: macro PG connection pattern ──────────────────────────────────
# The rf_16k macro exposes VDD/VSS pins as `long_pin` style vertical
# rails. The mesh alone may not land vias on every long pin, so this
# pattern drops a per-pin horizontal M5 strap (perpendicular to the long
# pins) every 4 μm so compile_pg picks up every macro pin it crosses.
puts "INFO: \[pg_mesh\] creating macro PG connection pattern"
create_pg_macro_conn_pattern macro_conn \
    -pin_conn_type long_pin \
    -direction horizontal \
    -pitch 4.0 \
    -layers M5

# ── Step 6: bind patterns to nets via PG strategies ──────────────────────
puts "INFO: \[pg_mesh\] defining PG strategies"

set_pg_strategy rail_strategy \
    -pattern {{name: std_cell_rail} {nets: {VDD VSS}}} \
    -core

set_pg_strategy mesh_strategy \
    -pattern {{name: mesh_m5_m6} {nets: {VDD VSS}}} \
    -core

set hard_macros [get_cells -quiet -hier -filter {is_hard_macro==true}]
if {[sizeof_collection $hard_macros] > 0} {
    set_pg_strategy macro_strategy \
        -pattern {{name: macro_conn} {nets: {VDD VSS}}} \
        -macros $hard_macros
    set strats {rail_strategy mesh_strategy macro_strategy}
} else {
    puts "INFO: \[pg_mesh\] no hard macros found — skipping macro_strategy"
    set strats {rail_strategy mesh_strategy}
}

# ── Step 7: synthesize the PG network ────────────────────────────────────
puts "INFO: \[pg_mesh\] compile_pg -strategies $strats"
compile_pg -strategies $strats

puts "INFO: \[pg_mesh\] PG mesh built (M1 rails + M5/M6 mesh @ ${pg_pitch} μm pitch)"
