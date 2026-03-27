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
#-----------------------------------------------------------------------------

set phys_ip_path $::env(PHYS_IP_PATH)
set tf_file      $::env(TF_FILE)
set db_ss        $::env(DB_SS)
set db_ff        $::env(DB_FF)

set lef_file     "${phys_ip_path}/sc12_base_rvt/r0p0/lef/sc12_cln65lp_base_rvt.lef"
set output_lib   "./fusion_lib/sc12_lib"

puts "INFO: Creating fusion reference library"
puts "INFO: LEF:     $lef_file"
puts "INFO: DB(SS):  $db_ss"
puts "INFO: DB(FF):  $db_ff"
puts "INFO: TF:      $tf_file"
puts "INFO: Output:  $output_lib"

# Clean previous output
file delete -force ./fusion_lib
file mkdir ./fusion_lib

# Create workspace with technology
create_workspace fusion_ws -tech $tf_file -flow frame

# Read LEF for cell physical abstracts
read_lef $lef_file

# Read timing libraries (.db)
read_db $db_ss
read_db $db_ff

# Check workspace
check_workspace

# Commit to NDM library
commit_workspace -output $output_lib

puts "INFO: Fusion reference library created at $output_lib"
puts "INFO: Done"

exit
