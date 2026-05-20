# =============================================================================
# tidelink_rxclk_buf — standalone cocotb unit sim for the boundary BUFG buffer
# =============================================================================
#
# Elaborates tidelink_rxclk_buf TWICE in tb_top:
#   * u_passthru: USE_CLKBUF=0 (sim/ASIC default) — pure passthrough, NO
#                 Xilinx primitive referenced. Bit-exact clk_o = clk_i.
#   * u_optout  : USE_CLKBUF=1 + `+define+TIDELINK_RXCLK_NO_PRIMITIVE — the
#                 belt-and-braces opt-OUT escape hatch (non-Vivado flow forces
#                 USE_CLKBUF=1 without a unisim library). Also bit-exact
#                 clk_o = clk_i, but via a different generate branch.
#
# These are the two corners the non-Vivado sim flow can elaborate. The
# USE_CLKBUF=1 WITHOUT the opt-OUT define would try to resolve a Xilinx BUFG
# primitive — VCS cannot do that without the unisim library, so that corner
# is intentionally NOT covered here (it is covered by the FPGA build flow).
#
# Run (always clean sim_build first — cocotb does NOT rebuild simv on RTL or
# +define+ changes, so a stale simv would give a false PASS):
#
#   cd /home/dam1n19/td_idelay_wt && source set_env.sh
#   rm -rf cocotb/tidelink_rxclk_buf/sim_build
#   make -C cocotb/tidelink_rxclk_buf
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(TIDELINK_HOME)/fpga/rtl/tidelink_rxclk_buf.sv

TOPLEVEL = tb_top
MODULE   = test_rxclk_buf

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
# Belt-and-braces opt-OUT: lets the USE_CLKBUF=1 generate branch fall back to
# bit-exact passthrough WITHOUT a Xilinx BUFG primitive (which VCS can't
# elaborate without the unisim library). If this define stops reaching the
# RTL, the USE_CLKBUF=1 instance's `ifndef takes the BUFG arm and VCS
# compile FAILS — itself a (loud) regression signal.
COMPILE_ARGS += +define+TIDELINK_RXCLK_NO_PRIMITIVE
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim
