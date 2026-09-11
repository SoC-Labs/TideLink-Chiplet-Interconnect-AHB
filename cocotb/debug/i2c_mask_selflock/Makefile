# =============================================================================
# i2c_mask_selflock — Fix B proof: a SLAVE-role axi_chiplet_controller must be
# able to latch role_lock via the REAL 0x21C lane-mask-handshake result
# (mask_hs_bypass_i=0), the autonomous replacement for the bring-up bypass.
#
# Reuses the wlink_pair testbench (two cross-wired axi_chiplet_controller
# instances + the full tidelink_fpga.flist, which compiles the patched
# Wlink.v with the SHORTCOMINGS-14a/14b 0x21C sniffer) so this exercises
# the genuine gate path: wlink_mask_hs_result[0] -> mask_hs_match ->
# mask_hs_gate_open -> role_lock_reg.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../../..)
export TIDELINK_HOME
# Site configuration: per-machine tool + IP roots, with NO default path.
# mk/site.mk reads site.env and names anything missing. site.env.example
# says what each variable locates.
SITE_VARS_REQUIRED += CMSDK_DIR
include $(TIDELINK_HOME)/mk/site.mk

PAIR = $(TIDELINK_HOME)/cocotb/wlink_pair
VERILOG_SOURCES = $(PAIR)/tb_top.sv $(PAIR)/pad_skid.sv

TOPLEVEL = tb_top
MODULE   = test_mask_selflock

# SKID_BITS=0 — clean PHY passthrough. role_lock is gated only by
# mask_hs_gate_open + nego_lock_pending, independent of PHY bring-up, so
# no skid/link-active wait is needed; keeps the test deterministic & fast.
SKID_BITS ?= 0

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga.flist
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim
