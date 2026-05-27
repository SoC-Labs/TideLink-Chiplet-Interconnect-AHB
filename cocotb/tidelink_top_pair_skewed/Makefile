# =============================================================================
# tidelink_top_pair_skewed cocotb sim — paired tidelink_top with asymmetric
# per-lane pad skid emulating ribbon-cable skew between two PYNQ-Z2 boards.
#
# Variant of cocotb/tidelink_top_pair/ that breaks the "zero-skew shared-clock"
# assumption — see docs/agent_l_skewed_pad_sim.md for the rationale and the
# per-lane SKID_BITS values used. The unmodified tidelink_top_pair directory
# is preserved as a control regression target.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv

TOPLEVEL = tb_top
MODULE  ?= test_tidelink_pair_doorbell

# SKID_BITS exposed for future skid sweeps; default 0 = passthrough so the
# protocol path is exercised without alignment artefacts.
SKID_BITS ?= 0
export SKID_BITS

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flist/tidelink_fpga.flist
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)
# VCD dumping is OFF by default in the skewed variant — a 6 GB+ VCD over the
# calibrator sweep window dominates wall time. Enable with `make VCD=1`.
ifeq ($(VCD),1)
COMPILE_ARGS += +define+TB_VCD_ENABLE
SIM_ARGS     += +vcs+dumpvars+waves.vcd
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)
