# PENDING-DECISION #5 — role-from-STRAP red/green gate.
#   make MODE=trap   # ROLE_FROM_STRAP=0 : NACK -> (slave,slave)  [today, the trap]
#   make MODE=fix    # ROLE_FROM_STRAP=1 : NACK -> (master,slave) [ASIC posture]
# Compiles the SHIPPING copy: src/rtl/local_overrides/tidelink_autoneg.sv
# (the one the top/asic flists use — NOT the deps submodule copy).
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

MODE ?= trap
ifeq ($(MODE),fix)
  RFS        = 1
  SIM_BUILD ?= sim_build_fix
else
  RFS        = 0
  SIM_BUILD ?= sim_build_trap
endif
export ROLE_FROM_STRAP_MODE = $(MODE)

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_role_strap

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += +define+ROLE_FROM_STRAP=$(RFS)
COMPILE_ARGS += $(TIDELINK_HOME)/src/rtl/local_overrides/tidelink_autoneg.sv

include $(shell cocotb-config --makefiles)/Makefile.sim
