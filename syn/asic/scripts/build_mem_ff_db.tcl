#-----------------------------------------------------------------------------
# lc_shell helper — compile the FF (fast-min) Liberty files for the
# precompiled rf_16k macro into .db format.
#
# The precompiled rf_16k already ships FF .db files directly, so this script
# is normally a no-op (the FF .db symlinks land straight onto MEM_DBS_FF). It
# exists as the canonical hook for the FC multi-corner flow: any future rf_*k
# flavour added without an FF .db can be regenerated locally via
# `make mem_ff_db` without writing into the shared macro tree, which is
# read-only.
#
# MEM_BASE is that tree's root — a per-machine fact, set in <repo>/site.env
# (see site.env.example). No default.
#
# Run with: lc_shell -f scripts/build_mem_ff_db.tcl
# Output  : syn/asic/libs/mem_ff/rf_*k_ff_*.db
#-----------------------------------------------------------------------------

if {![info exists ::env(MEM_BASE)] || $::env(MEM_BASE) eq ""} {
    error "\[mem_ff_db\] MEM_BASE is not set — it locates the precompiled memory\n\
           \      macro tree (the directory holding rf_01k/, rf_16k/, ...). Set it\n\
           \      in <repo>/site.env (see site.env.example) or export it."
}
set src_root  $::env(MEM_BASE)
set dst_root  $::env(MEM_FF_DB_DIR)

file mkdir $dst_root

# Inventory: only re-compile flavours whose FF .lib is present but whose
# FF .db is absent in the precompiled-mems tree. The shipped tree already
# has rf_16k_ff_*.db — this loop is a future-proofing scaffold for the
# rf_01k/rf_08k frames create_fusion_lib.tcl optionally bundles into the
# fusion library.
set jobs [list \
    [list rf_01k rf_01k_ff_1p32v_1p32v_m40c RF_01K_ff_1p32v_1p32v_m40c] \
    [list rf_01k rf_01k_ff_1p32v_1p32v_125c RF_01K_ff_1p32v_1p32v_125c] \
    [list rf_08k rf_08k_ff_1p32v_1p32v_m40c RF_08K_ff_1p32v_1p32v_m40c] \
    [list rf_08k rf_08k_ff_1p32v_1p32v_125c RF_08K_ff_1p32v_1p32v_125c] \
    [list rf_16k rf_16k_ff_1p32v_1p32v_m40c RF_16K_ff_1p32v_1p32v_m40c] \
    [list rf_16k rf_16k_ff_1p32v_1p32v_125c RF_16K_ff_1p32v_1p32v_125c]]

set built 0
foreach job $jobs {
    lassign $job dir base libname
    set lib_in  "${src_root}/${dir}/${base}.lib"
    set db_pre  "${src_root}/${dir}/${base}.db"
    set db_out  "${dst_root}/${base}.db"

    if {![file exists $lib_in]} {
        puts "INFO: skip $base — Liberty not present"
        continue
    }
    if {[file exists $db_pre]} {
        puts "INFO: $base — FF .db already shipped under precompiled_mems; skipping build"
        continue
    }
    puts "INFO: read_lib  $lib_in"
    read_lib $lib_in
    puts "INFO: write_lib $libname -> $db_out"
    write_lib $libname -output $db_out
    remove_lib $libname
    incr built
}

puts "INFO: built $built FF .db file(s) under $dst_root"
exit
