#-----------------------------------------------------------------------------
# Create Fusion (NDM) reference library from LEF + Liberty (.db/.lib) files
#
# Run with: lm_shell -f create_fusion_lib.tcl
#
# This creates a pre-compiled NDM reference library that RTL Architect
# can use for physical-aware RTL exploration.
#
# Environment variables (set by Makefile via common.mk):
#   PHYS_IP_PATH  - Root of physical IP library
#   TF_FILE       - Technology file (.tf)
#   DB_SS         - Slow corner .db library
#   DB_FF         - Fast corner .db library
#   MEM_PATH      - Memory macro library path
#   MEM_DB_SS     - Memory macro .db (slow-slow corner)
#   MEM_DB_FF     - Memory macro .db (fast-fast corner)
#-----------------------------------------------------------------------------

set phys_ip_path $::env(PHYS_IP_PATH)
set tf_file      $::env(TF_FILE)
set db_ss        $::env(DB_SS)
set db_ff        $::env(DB_FF)
set mem_path     $::env(MEM_PATH)
set mem_db_ss    $::env(MEM_DB_SS)
set mem_db_ff    $::env(MEM_DB_FF)

# The Arm Artisan std-cell LEF. Its path carries the library variant and the
# drop revision — per-site facts — so it is named whole in <repo>/site.env as
# RTLA_LEF_FILE (the Makefile passes it through as LEF_FILE). No default.
if {[info exists ::env(LEF_FILE)] && $::env(LEF_FILE) ne ""} {
    set stdcell_lef $::env(LEF_FILE)
} elseif {[info exists ::env(RTLA_LEF_FILE)] && $::env(RTLA_LEF_FILE) ne ""} {
    set stdcell_lef $::env(RTLA_LEF_FILE)
} else {
    error "\[lib\] RTLA_LEF_FILE is not set — it locates the Arm Artisan standard-cell\n\
           \      LEF this fusion library is built from. Set it in <repo>/site.env\n\
           \      (see site.env.example) or export it. There is no default."
}
set mem_lef      "${mem_path}/rf_16k.lef"
set output_lib   "./fusion_lib/sc12_lib"

puts "INFO: Creating fusion reference library"
puts "INFO: Std cell LEF: $stdcell_lef"
puts "INFO: Memory LEF:   $mem_lef"
puts "INFO: DB(SS):       $db_ss"
puts "INFO: DB(FF):       $db_ff"
puts "INFO: MEM DB(SS):   $mem_db_ss"
puts "INFO: MEM DB(FF):   $mem_db_ff"
puts "INFO: TF:           $tf_file"
puts "INFO: Output:       $output_lib"

# Clean previous output
file delete -force ./fusion_lib
file mkdir ./fusion_lib

# Create workspace with technology
create_workspace fusion_ws -tech $tf_file -flow frame

# Read LEF for cell physical abstracts (standard cells + memory macro)
read_lef $stdcell_lef
read_lef $mem_lef

# Read timing libraries (.db) — standard cells and memory macro
read_db $db_ss
read_db $db_ff
read_db $mem_db_ss
read_db $mem_db_ff

# Check workspace
check_workspace

# Commit to NDM library
commit_workspace -output $output_lib

puts "INFO: Fusion reference library created at $output_lib"
puts "INFO: Done"

exit
