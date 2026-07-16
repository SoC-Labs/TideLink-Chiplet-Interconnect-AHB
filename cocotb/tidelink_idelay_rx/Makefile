# =============================================================================
# tidelink_idelay_rx — standalone cocotb unit sim for the IDELAY OPT-OUT path
# =============================================================================
#
# Elaborates tidelink_idelay_rx with USE_IDELAY=1 (hard-set in tb_top.sv) AND
# `+define+TIDELINK_IDELAY_NO_PRIMITIVE`, so the `g_idelay` generate branch is
# selected but falls back to the bit-exact passthrough `else (no Xilinx
# unisim primitive — VCS cannot elaborate IDELAYE2/IDELAYCTRL). This pins the
# inverted safety net the FPGA-only path otherwise tests in 22 minutes.
#
# Run (always clean sim_build first — cocotb does NOT rebuild simv on RTL or
# +define+ changes, so a stale simv would give a false PASS):
#
#   cd /home/dam1n19/td_idelay_wt && source set_env.sh
#   rm -rf cocotb/tidelink_idelay_rx/sim_build
#   make -C cocotb/tidelink_idelay_rx
#
# (set_env.sh is sourced for parity with the other TBs; this standalone TB
#  pulls only tb_top.sv + tidelink_idelay_rx.sv so it does not need
#  ${CMSDK_FPGA_SRAM_V}, but sourcing it is harmless and keeps the recipe
#  identical to every other cocotb dir.)
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# ── Target select ───────────────────────────────────────────────────────────
#   FULLRANGE=0 (default): the OPT-OUT passthrough corner (tb_top.sv +
#                          +define+TIDELINK_IDELAY_NO_PRIMITIVE, no unisim).
#   FULLRANGE=1          : the FULL-RANGE tap corner (2026-06-25). USE_IDELAY=1
#                          PRIMITIVE arm against the behavioural IDELAYE2 stub
#                          (idelay_prim_stubs.sv) so lane_tap == 2*nibble+lsb is
#                          observable on CNTVALUEOUT. Proves odd-tap reach +
#                          lsb=0 even-only identity. NEVER pass NO_PRIMITIVE here.
FULLRANGE ?= 0

ifeq ($(FULLRANGE),1)
VERILOG_SOURCES = $(CURDIR)/tb_fullrange.sv \
                  $(CURDIR)/idelay_prim_stubs.sv \
                  $(TIDELINK_HOME)/src/rtl/tidelink_idelay_rx.sv
TOPLEVEL = tb_top
MODULE   = test_idelay_fullrange
COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
# NOTE: deliberately NO +define+TIDELINK_IDELAY_NO_PRIMITIVE — the primitive
# arm (g_idelay g_lane IDELAYE2) MUST elaborate so CNTVALUEOUT exposes lane_tap.
SIM_BUILD := sim_build_fullrange
else
VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(TIDELINK_HOME)/src/rtl/tidelink_idelay_rx.sv
TOPLEVEL = tb_top
MODULE   = test_idelay_optout_passthrough
COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
# The escape hatch under test: force the opt-OUT (no unisim) inside the
# USE_IDELAY=1 `g_idelay` branch. If this define stops reaching the RTL, the
# `ifndef would try to elaborate IDELAYE2/IDELAYCTRL and VCS compile FAILS —
# which is itself a (loud) regression signal.
COMPILE_ARGS += +define+TIDELINK_IDELAY_NO_PRIMITIVE
SIM_BUILD := sim_build
endif

SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim
