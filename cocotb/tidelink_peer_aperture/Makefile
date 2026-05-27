# =============================================================================
# tidelink_peer_aperture — cocotb sim for the v2 Eye Visibility cross-link
# extraction path (docs/EYE_VISIBILITY_RTL_PROPOSAL.md §7 + §9 test #7).
# =============================================================================
#
# Two cross-wired tidelink_top instances; master's ahb_sub is exposed to the
# cocotb test so it can issue AHB reads at 0x40032140..0x4003217F. Those
# addresses ride the peer aperture into slave's local Region 10.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv

TOPLEVEL = tb_top
MODULE  ?= test_eye_peer_aperture_drain

SKID_BITS ?= 0
export SKID_BITS

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flist/tidelink_fpga.flist
# Eye visibility RTL collateral. Until feat/eye-rtl-impl merges, the
# tidelink_eye_regs.sv file does not exist and elaboration will fail at
# the calibrator's new port list.
COMPILE_ARGS += -f $(TIDELINK_HOME)/flist/tidelink_eye_visibility.flist
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)
