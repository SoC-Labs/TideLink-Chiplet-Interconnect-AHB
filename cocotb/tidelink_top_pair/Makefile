# =============================================================================
# tidelink_top_pair cocotb sim — two cross-wired tidelink_top instances
# Reproduces the HW bring-up chain observed on bridge1 b24 deploy 2026-05-24.
#
# TIDELINK_PHY_V2 (S3 PHY swap, 2026-06-11)
#   0 (default) = V1 build: compiles flists/tidelink_fpga.flist (the
#       local_overrides/tidelink-gpio-phy PHY composition).
#   1 = V2 build: compiles flists/tidelink_fpga_v2.flist instead — the
#       deps/tidelink-phy shared component (FIX-N..R serdes + always-on
#       lane-mask-aware calibrator). The +define+TIDELINK_PHY_V2 rides in
#       the flist itself, activating the `ifdef arms in local_overrides/
#       {Wlink.v,axi_chiplet_controller.sv} + src/rtl/tidelink_top.sv.
#       Use a dedicated SIM_BUILD (e.g. SIM_BUILD=sim_build_v2) so V1/V2
#       objects never mix:
#         TIDELINK_PHY_V2=1 make MODULE=test_tidelink_pair_doorbell \
#                                SIM_BUILD=sim_build_v2
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
# V1/V2 flist selection — see header. The V2 flist carries the
# +define+TIDELINK_PHY_V2 itself.
TIDELINK_PHY_V2 ?= 0
ifeq ($(TIDELINK_PHY_V2),1)
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
else
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga.flist
endif
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)

# Per-lane differential skew injection (S3-A repro, 2026-06-05). Pass e.g.
#   EXTRA_DEFINES="+define+TB_TOP_SKID_L1=1 +define+TB_TOP_SKID_L2=2 ..."
# to drive DIFFERENTIAL per-lane pad-clk-period skew through pad_skid, exciting
# the cross-lane deskew bubble bug. Empty by default => uniform SKID_BITS only.
EXTRA_DEFINES ?=
COMPILE_ARGS += $(EXTRA_DEFINES)

# BYPASS_AUTONEG (Phase 0c autonomy plan)
#   1 = legacy behaviour: autoneg parks in ST_BYPASS at POR, role-lock is
#       SW-driven via APB ROLE_CFG W1S. Default for test_01..test_09.
#   0 = autonomy: tb forces nego_cfg_reg + nego_train_cfg_r at time 0 so the
#       FSM walks ST_NEGO_INIT → ST_TRAIN_DONE without any SW writes. Used
#       by test_10_autonomous_train_post_por and any future Phase 7 tests.
# Default = 1 (preserve existing tests).
BYPASS_AUTONEG ?= 1
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=$(BYPASS_AUTONEG)

# RELY_ON_RTL_PRIO_DEFAULTS (Bug N7 regression — test_18)
#   0 = tb force-injects nego_priority_reg = master:0x0001, slave:0x0002
#       (legacy behaviour; masks Bug N7).
#   1 = tb leaves nego_priority_reg alone — RTL POR default decides.
#       Used only by test_18_bug_n7_priority_deadlock.
# Default = 0 (preserve existing tests).
RELY_ON_RTL_PRIO_DEFAULTS ?= 0
COMPILE_ARGS += +define+TB_TOP_RELY_ON_RTL_PRIO_DEFAULTS=$(RELY_ON_RTL_PRIO_DEFAULTS)

# Wave dump (gated). Probe-only tests can opt out via TB_TOP_NO_DUMP=1 — the
# VCD grew >4 GB on the 4-test credit-ledger probe run and OOM'd the host.
TB_TOP_NO_DUMP ?= 0
ifeq ($(TB_TOP_NO_DUMP),1)
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
else
SIM_ARGS     += +vcs+dumpvars+waves.vcd
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)
