#-----------------------------------------------------------------------------
# mk/site.mk — site configuration for the SIMULATION / LINT / CDC layer
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# The counterpart of syn/asic/common.mk's site block, for every Makefile that
# is NOT part of the ASIC flow: cocotb/, uvm/, xprop/, cdc/, lint/, fpga/.
#
# WHY THIS FILE EXISTS
# --------------------
# set_env.sh and syn/asic/common.mk have carried "no default site path" since
# 2026-08-14. The test and lint layer did not: ~40 bench Makefiles carried
#
#     export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/<release-coded drop name>
#     VERDI_HOME = <an absolute tool-install path>
#
# Those two lines are worse than no setting at all:
#
#   * the `?=` one RESOLVES on the lab host and nowhere else, so the policy
#     looked enforced while every bench quietly depended on one mount; and
#   * the VERDI_HOME one used `=`, a HARD assignment, which OVERRODE whatever
#     set_env.sh or the site module file had already exported. Setting it
#     correctly in the environment had no effect.
#
# Neither failed as "you have not configured this". They failed hours later as
# a missing FILE, which reads as a broken checkout rather than a missing
# setting. See `make site-check` at the repo root for the guard that keeps
# them from coming back.
#
# HOW TO USE IT
# -------------
# Before including this file, name what the bench needs:
#
#     TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
#     SITE_VARS_REQUIRED += CMSDK_DIR
#     include $(TIDELINK_HOME)/mk/site.mk
#
# Anything unset is then named, ALL of them in one pass, before a tool runs.
#
# For a variable only ONE target needs (a GUI viewer, a gate-level netlist
# run), do not put it in SITE_VARS_REQUIRED — that would make every other
# target in the bench refuse to run without it. Check it in the recipe:
#
#     gui: $(SIM_BUILD)/simv
#     	@$(SITE_REQUIRE) VERDI_HOME "the Verdi install root (waveform GUI)"
#     	...
#
# THIS FILE DEFINES NO RULES, deliberately. Bench Makefiles include it above
# `include $(shell cocotb-config --makefiles)/Makefile.sim`, and the first
# rule a makefile defines becomes its default goal. A `site-check:` target
# here would silently become the default goal of ~40 benches. The target
# lives in the root Makefile only.
#-----------------------------------------------------------------------------

# Guard against double inclusion (a bench may include this and also include a
# fragment that includes it).
ifndef _TIDELINK_SITE_MK_INCLUDED
_TIDELINK_SITE_MK_INCLUDED := 1

# Where we are. Captured immediately: $(MAKEFILE_LIST) grows with every
# subsequent include, so a lazily-expanded `?=` right-hand side would read
# whichever file is included last, not this one.
_SITE_MK_DIR  := $(dir $(lastword $(MAKEFILE_LIST)))
TIDELINK_HOME ?= $(realpath $(_SITE_MK_DIR)..)

# ── site.env ────────────────────────────────────────────────────────────────
# Per-machine facts. NOT tracked; copy site.env.example to site.env and edit,
# or export the same names from a login profile / site module file. Written in
# the Make/shell syntax intersection (`export N=v`, no spaces) so set_env.sh
# sources the SAME file. Optional: absent, the environment is used as-is,
# which is the CI case.
SITE_ENV ?= $(TIDELINK_HOME)/site.env
-include $(SITE_ENV)

# Every site variable reaches recipes and sub-makes. A name that arrives from
# the environment is exported already; one that arrives from site.env is
# exported by site.env's own `export` keyword; one set on the make command
# line is exported by make. This line covers the remaining case — a name a
# bench Makefile computes — so `$(SITE_REQUIRE) NAME` in a recipe can always
# see it.
export CMSDK_DIR CMSDK_FPGA_SRAM_V ARM_IP_LIBRARY_PATH XHB500_IP_DIR
export VCS_HOME VERDI_HOME VIP_HOME SPYGLASS_HOME XCELIUM_HOME
export XILINX_VIVADO VIVADO_BIN
export PHYS_IP_PATH STDCELL_VERILOG MEM_BASE MEM_PATH
export CHIPLET_HOME ETH_SS_HOME TIDECHART_HOME

# ── cmsdk_fpga_sram.v ───────────────────────────────────────────────────────
# Not every CMSDK package ships it. Derive it from CMSDK_DIR when it is there;
# otherwise site.env must name the copy in whichever package does. This is the
# same rule set_env.sh applies, so the two agree. (The previous version named
# a second release-coded package as the fallback, which is exactly the
# inventory disclosure site.env.example exists to keep out of tracked files.)
ifeq ($(strip $(CMSDK_FPGA_SRAM_V)),)
CMSDK_FPGA_SRAM_V := $(wildcard $(CMSDK_DIR)/logical/models/memories/cmsdk_fpga_sram.v)
endif

# ── Recipe-time requirement check ───────────────────────────────────────────
# For a variable only one target needs.  Usage, as the first line of a recipe:
#     $(SITE_REQUIRE) VERDI_HOME "the Verdi install root (waveform GUI)"
SITE_REQUIRE := $(TIDELINK_HOME)/scripts/ci/site_require.sh

# ── Parse-time requirement check ────────────────────────────────────────────
# Names EVERY missing variable at once, and only when a goal that actually
# needs one was asked for: `make clean` and `make help` must keep working on
# an unconfigured machine, or the first thing a new checkout does is fail at
# the one command that would tidy it up.
SITE_SOFT_GOALS += help clean clean_all distclean site-check sim_gate_env_check

SITE_VARS_MISSING := $(strip $(foreach v,$(SITE_VARS_REQUIRED),$(if $(strip $($(v))),,$(v))))
SITE_HARD_GOALS   := $(filter-out $(SITE_SOFT_GOALS),$(if $(MAKECMDGOALS),$(MAKECMDGOALS),_default))

ifneq ($(SITE_VARS_MISSING),)
ifneq ($(SITE_HARD_GOALS),)
$(warning ERROR: [site] unset, with no default: $(SITE_VARS_MISSING))
$(warning        Each names a per-machine path this bench cannot guess. Copy)
$(warning        site.env.example to $(SITE_ENV) and set them there, or export)
$(warning        them in your environment — `source set_env.sh` does both.)
$(warning        site.env.example says what each one locates.)
$(error   [site] refusing to run $(SITE_HARD_GOALS) with an unconfigured site)
endif
endif

endif # _TIDELINK_SITE_MK_INCLUDED
