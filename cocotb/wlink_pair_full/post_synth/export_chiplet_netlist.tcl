# Export ONLY the chiplet IP netlist (tidelink_top, with all RTL synthesised)
open_checkpoint /tmp/i2c_wt/imp/fpga/project/pynq-z2-pair-all/tidelink_project.runs/tidelink_design_tidelink_0_0_synth_1/tidelink_design_tidelink_0_0.dcp
write_verilog -force -mode funcsim /tmp/i2c_wt/cocotb/wlink_pair_full/post_synth/tidelink_design_tidelink_0_0_funcsim.v
puts "Wrote chiplet IP funcsim netlist."
exit
