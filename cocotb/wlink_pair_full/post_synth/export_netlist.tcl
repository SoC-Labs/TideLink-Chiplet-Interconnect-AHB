# Open the post-synth DCP and write out a Verilog netlist + SDF
open_checkpoint /tmp/i2c_wt/imp/fpga/project/pynq-z2-pair-all/tidelink_project.runs/synth_1/tidelink_design_wrapper.dcp
write_verilog -force -mode funcsim /tmp/i2c_wt/cocotb/wlink_pair_full/post_synth/tidelink_design_wrapper_funcsim.v
# Also write timesim with timing info if available (post-synth ≠ post-route so no SDF here)
puts "Wrote funcsim netlist."
exit
