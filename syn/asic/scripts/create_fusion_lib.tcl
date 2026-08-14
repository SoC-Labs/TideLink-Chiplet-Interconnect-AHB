#-----------------------------------------------------------------------------
# Build NDMs for the FC flow.
#
# Run with: lm_shell -f create_fusion_lib.tcl
#
# Builds, in order:
#   <out>/sc12_lib       — TSMC65 sc12 std cells (LEF + .db, full lib)
#   <out>/mem_frame_lib  — frame-only NDM for rf_16k (LEF only;
#                          macro Liberty reaches fc_shell via the
#                          link_library .db list set in 1_init_design.tcl)
#
# Why split sc12 from mems:
#   - sc12 cells are self-contained, so a normal-flow lm_shell build embeds
#     Liberty next to the frame and gives fc_shell the AND/OR/INV cells it
#     needs for synthesis (DWS-0103 otherwise).
#   - The rf_16k Liberty references std-cell sub-modules (A2DFFQN_X1M_A12TR
#     …), so committing a normal-flow workspace that reads both rf_16k.lef
#     AND rf_16k.db without their parent std-cell library context fails
#     check_workspace. Frame-only is sufficient for placement; macro timing
#     comes through fc_shell's link_library.
#
# Environment variables (set by Makefile via common.mk):
#   PHYS_IP_PATH      - sc12 base path
#   TF_FILE           - .tf
#   DB_SS / DB_FF     - sc12 slow/fast .db
#   MEM_BASE          - precompiled-mems root (TSMC65)
#   FUSION_LIB        - output path for sc12_lib (siblings created next to it)
#-----------------------------------------------------------------------------

set phys_ip_path $::env(PHYS_IP_PATH)
set tf_file      $::env(TF_FILE)
set db_ss        $::env(DB_SS)
set db_ff        $::env(DB_FF)
set db_tt        [expr {[info exists ::env(DB_TT)] ? $::env(DB_TT) : ""}]

if {[info exists ::env(MEM_BASE)] && $::env(MEM_BASE) ne ""} {
    set mem_base $::env(MEM_BASE)
} else {
    set mem_base [file dirname $::env(MEM_PATH)]
}

# Standard-cell LEF. STANDARD_CELL_LEF_FILE names it whole: its release
# directory and its metal-stack suffix are per-site facts, so there is no
# inferred fallback — a guessed LEF for the wrong metal stack is not diagnosed
# by the tools, it just builds a library that routes wrong.
if {[info exists ::env(STANDARD_CELL_LEF_FILE)] && $::env(STANDARD_CELL_LEF_FILE) ne ""} {
    set stdcell_lef $::env(STANDARD_CELL_LEF_FILE)
} else {
    error "\[lib\] STANDARD_CELL_LEF_FILE is not set — it locates the standard-cell\n\
           \      LEF for the metal stack this design targets, and must describe the\n\
           \      same stack as TF_FILE. Set it in <repo>/site.env (see\n\
           \      site.env.example) or export it. There is no default."
}

# Memory LEFs — only rf_16k is currently instantiated, but include the
# sibling rf_*k frames so additional macro flavours can drop in without
# rebuilding the fusion library.
set mem_lefs [list \
    "${mem_base}/rf_01k/rf_01k.lef" \
    "${mem_base}/rf_08k/rf_08k.lef" \
    "${mem_base}/rf_16k/rf_16k.lef"]

if {[info exists ::env(FUSION_LIB)] && $::env(FUSION_LIB) ne ""} {
    set output_lib_stdcell $::env(FUSION_LIB)
} else {
    set output_lib_stdcell "./fusion_lib/stdcell_lib"
}
set output_dir     [file dirname $output_lib_stdcell]
set output_lib_mem "${output_dir}/mem_frame_lib"
file mkdir $output_dir

# Demote LEF-vs-Liberty VDD/VSS direction-mismatch errors (NDM-032) to
# warnings. lm_shell auto-corrects each one (LM-054 "Fixed direction
# mismatches…") but the Error severity counts toward the commit_workspace
# fail threshold. Without this, commit_workspace aborts despite every
# mismatch having been fixed in-flight.
set_message_info -id NDM-032 -limit 5

#-----------------------------------------------------------------------------
# 1) stdcell_lib — tcbn65lp 9-track std cells, normal flow w/ Liberty.
#    All three corners (bc/tc/wc) bundled so fc_shell's MCMM has every
#    operating point available at link time.
#-----------------------------------------------------------------------------
puts "INFO: \[lib\] Building stdcell_lib (tcbn65lp std cells w/ Liberty)"
puts "INFO: \[lib\]   LEF : $stdcell_lef"
puts "INFO: \[lib\]   .db : $db_ss / $db_ff"
if {$db_tt ne ""} { puts "INFO: \[lib\]   .db : $db_tt (TT)" }
puts "INFO: \[lib\]   Out : $output_lib_stdcell"

file delete -force $output_lib_stdcell
# Explicit `-flow normal` is required for the leading-positional form to
# parse — the implicit/default form rejects the `<name>` positional with
# CMD-012 "extra positional option" in U-2022.12.
create_workspace stdcell_ws -technology $tf_file -flow normal
read_lef $stdcell_lef
read_db $db_ss
read_db $db_ff
if {$db_tt ne "" && [file exists $db_tt]} {
    read_db $db_tt
}
check_workspace
commit_workspace -output $output_lib_stdcell

#-----------------------------------------------------------------------------
# 2) mem_frame_lib — memory macros, frame-only (LEFs only).
#    Liberty for rf_*k reaches fc_shell via the link_library .db list set
#    in 1_init_design.tcl (the .db's reference std-cell sub-modules so
#    they cannot be cleanly committed into a normal-flow NDM here).
#-----------------------------------------------------------------------------
puts "INFO: \[lib\] Building mem_frame_lib (rf_*k frames)"
foreach lef $mem_lefs { puts "INFO: \[lib\]   LEF : $lef" }
puts "INFO: \[lib\]   Out : $output_lib_mem"

file delete -force $output_lib_mem
create_workspace mem_ws -technology $tf_file -flow frame
foreach lef $mem_lefs {
    if {[file exists $lef]} {
        read_lef $lef
    } else {
        puts "WARN: \[lib\] $lef not found — skipping"
    }
}
check_workspace
commit_workspace -output $output_lib_mem

puts "INFO: \[lib\] All NDMs committed under $output_dir"
exit
