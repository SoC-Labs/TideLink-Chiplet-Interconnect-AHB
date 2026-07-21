# PENDING-DECISION #5 — role-from-STRAP red/green gate.
#   make MODE=trap   # ROLE_FROM_STRAP=0 : NACK -> (slave,slave)  [today, the trap]
#   make MODE=fix    # ROLE_FROM_STRAP=1 : NACK -> (master,slave) [ASIC posture]
# Compiles the SHIPPING copy: src/rtl/local_overrides/tidelink_autoneg.sv
# (the one the top/asic flists use — NOT the deps submodule copy).
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

MODE ?= default
ifeq ($(MODE),fix)
  RFS        = 1
  SIM_BUILD ?= sim_build_fix
  EXTRA_DEF  = +define+ROLE_FROM_STRAP=1
else ifeq ($(MODE),trap)
  RFS        = 0
  SIM_BUILD ?= sim_build_trap
  EXTRA_DEF  = +define+ROLE_FROM_STRAP=0
else
  # MODE=default: omit the parameter override entirely so the instances take
  # tidelink_autoneg's OWN default. This is what proves DECISION #3's global
  # flip landed — expectations are the same as MODE=fix.
  SIM_BUILD ?= sim_build_default
  EXTRA_DEF  = +define+TB_ROLE_STRAP_DEFAULT
endif
export ROLE_FROM_STRAP_MODE = $(MODE)

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_role_strap

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += $(EXTRA_DEF)
COMPILE_ARGS += $(TIDELINK_HOME)/src/rtl/local_overrides/tidelink_autoneg.sv

include $(shell cocotb-config --makefiles)/Makefile.sim
