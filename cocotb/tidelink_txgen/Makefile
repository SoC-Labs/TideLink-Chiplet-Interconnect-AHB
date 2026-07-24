SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_txgen_unit

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += +incdir+$(TIDELINK_HOME)/src/rtl
COMPILE_ARGS += $(TIDELINK_HOME)/src/rtl/tidelink_tx_gen.sv
COMPILE_ARGS += $(TIDELINK_HOME)/src/rtl/tidelink_fc_adapter.sv

# The DUT sources are named explicitly above (not via a flist), so make CAN see
# them — unlike the flist-driven envs where an RTL-only edit silently reuses a
# stale simv. Keep them here as compile deps so an edit always recompiles.
CUSTOM_COMPILE_DEPS = $(TIDELINK_HOME)/src/rtl/tidelink_tx_gen.sv \
                      $(TIDELINK_HOME)/src/rtl/tidelink_fc_adapter.sv

include $(shell cocotb-config --makefiles)/Makefile.sim
