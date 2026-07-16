# =============================================================================
# tidelink_v2_smoke — fast V2 (S3 PHY swap) integration sanity gate for CI
#
# Elaborates a SINGLE tidelink_top with the V2 swap set (the same source
# swap as flists/tidelink_top_full_asic_v2.flist, taken here via the sim-able
# flists/tidelink_fpga_v2.flist — BRAM-model SRAM instead of the TSMC rf_16k
# macros, identical TIDELINK_PHY_V2 define + deps/tidelink-phy sources +
# `ifdef arms) and checks reset deassertion + APB liveness:
#   * PHY_ALIGN_ID  (paddr 0x211C, HW 0x4403_211C)  == 0x5041_0100
#   * Region 10     (paddr 0x2140, eye-vis retired) == 0x0 (RAZ, AUDIT #17)
#   * SWI_BIT_SLIP_LO (paddr 0x2104) write/read-back
#
# ~30 s wall: compile + a few hundred hclk cycles. No link partner, no
# training — the pads are tied off. The full bring-up gate remains
# cocotb/tidelink_top_pair (TIDELINK_PHY_V2=1).
# Style modeled on cocotb/tidelink_fc_adapter.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE  ?= test_tidelink_v2_smoke

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)
