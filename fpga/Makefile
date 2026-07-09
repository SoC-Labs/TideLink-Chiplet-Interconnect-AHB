#-----------------------------------------------------------------------------
# TideLink Chiplet Subsystem - FPGA Build Flow Makefile
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Build flow:
#   make all          - Full flow: package_ip -> build_design
#   make package_ip   - Package tidelink_vivado_wrapper as Vivado XCI IP
#   make build_design - Create block design, synthesise, implement, generate bitstream + .hwh
#   make program      - JTAG-program the PL via Vivado Hardware Manager
#   make deploy       - scp bitstream + .hwh to a PYNQ running PYNQ Linux
#   make clean        - Remove all build outputs
#
# FPGA board selection (program / deploy / run-on-board targets):
#   BOARD=fpga1                       # explicit board name from fpgahub config
#   BOARD_TAG=pynq_z2                 # auto-allocate first free matching board
#   PYNQ_HOST=..., PYNQ_PROXY=...     # manual override (bypasses fpgahub)
#
# TARGET selects the board configuration:
#   TARGET=pynq-z2-single             # single Pynq-Z2 (default)
#   TARGET=pynq-z2-pair               # loopback pair of Pynq-Z2 boards
#   TARGET=mps3                       # MPS3 / AN552 (Cortex-M55)
#
# The "via_fpgahub" variants of program / deploy drive the manifest at
# fpga/fpgahub.toml through `fpgahub actions run`, which acquires a lease
# and auto-extends it via extend_for_action for the action's timeout_s.
#-----------------------------------------------------------------------------

# Project root - assumes this Makefile lives in $SOCLABS_TIDELINK_DIR/fpga
TIDELINK_HOME   := $(realpath ..)
FPGA_DIR        := $(TIDELINK_HOME)/fpga
VIVADO_IP_DIR   := $(FPGA_DIR)/vivado_ip

# Surface SOCLABS_TIDELINK_DIR if not already set (e.g. when the parent shell
# didn't source set_env.sh). Both the filelist and any sub-tools rely on it.
ifeq ($(SOCLABS_TIDELINK_DIR),)
SOCLABS_TIDELINK_DIR := $(TIDELINK_HOME)
export SOCLABS_TIDELINK_DIR
endif

# TARGET selection — valid values: pynq-z2-single | pynq-z2-pair | mps3
# Validated first so an unknown TARGET gives a clear error before env checks.
TARGET          ?= pynq-z2-single

ifneq ($(MAKECMDGOALS),help)
VALID_TARGETS   := pynq-z2-single pynq-z2-pair pynq-z2-pair-flip pynq-z2-pair-slow pynq-z2-pair-flip-slow pynq-z2-pair-ila pynq-z2-pair-flip-ila pynq-z2-pair-i2c-ila pynq-z2-pair-all pynq-z2-pair-flip-all pynq-z2-pair-mmcmbypass-all pynq-z2-pair-mmcmbypass-flip-all pynq-z2-pair-mmcmbypass-oddr-all pynq-z2-pair-mmcmbypass-oddr-flip-all pynq-z2-loopback kr260-pair-ptp kr260-pair-nptp kr260-pair-flip-ptp kr260-pair-flip-nptp mps3
ifeq ($(filter $(TARGET),$(VALID_TARGETS)),)
$(error Unknown TARGET '$(TARGET)'. Valid values: $(VALID_TARGETS))
endif

# Targets that need the Arm IP (Corstone CMSDK + XHB500). Anything else
# (deploy, program, deploy_pair_role, the manifest-driven dispatch
# wrappers) just consumes pre-built bitstreams and doesn't need the
# IP-library env vars set. Gating the env check on these specific goals
# lets fpgahub-driven deploys run on hosts that don't have ARM_IP_LIBRARY_PATH.
BUILD_GOALS := all build_design package_ip
ifneq ($(filter $(BUILD_GOALS),$(MAKECMDGOALS)),)
ifndef CMSDK_DIR
$(error CMSDK_DIR is not set - source set_env.sh first (only required for build/package goals: $(BUILD_GOALS)))
endif
export CMSDK_DIR

ifndef XHB500_IP_DIR
$(error XHB500_IP_DIR is not set - source set_env.sh first (only required for build/package goals: $(BUILD_GOALS)))
endif
export XHB500_IP_DIR
endif
endif

TARGET_DIR      := $(FPGA_DIR)/targets/$(TARGET)

# Xilinx part — keyed off TARGET
# pynq-z2-single / pynq-z2-pair: Zynq-7020 on Digilent Pynq-Z2
# mps3: Kintex UltraScale on MPS3 board (xcku115-flvb1760-1-c).
#   Confirmed against the working ethernet-subsystem-ahb arm_mps3 target.
ifeq ($(TARGET),pynq-z2-single)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-flip)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-slow)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-flip-slow)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-ila)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-flip-ila)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-i2c-ila)
XILINX_PART     := xc7z020clg400-1
# Bug N7/N8 i2c-ILA target — auto-enable insert_debug_core for this TARGET so
# callers don't have to remember the env-var. mark_debug attrs in the
# local_overrides RTL are inert without this flag.
FPGA_INSERT_DEBUG_CORE := 1
export FPGA_INSERT_DEBUG_CORE
else ifeq ($(TARGET),pynq-z2-pair-all)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-flip-all)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-mmcmbypass-all)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-mmcmbypass-flip-all)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-mmcmbypass-oddr-all)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-mmcmbypass-oddr-flip-all)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-loopback)
XILINX_PART     := xc7z020clg400-1
# -----------------------------------------------------------------------------
# Kria KR260 (Zynq UltraScale+, K26 SOM). 2026-07-09 port of the Z2 GPIO-PHY
# chiplet link onto the KR260 Raspberry-Pi 40-pin header. Four targets = the
# die_a / die_b flip pair x PTP on/off:
#   kr260-pair-ptp        die_a, PHC/PTP hardware clock IN   (FPGA_TIDELINK_PTP=1)
#   kr260-pair-nptp       die_a, PHC/PTP tied off            (FPGA_TIDELINK_PTP=0)
#   kr260-pair-flip-ptp   die_b (mirror pinout), PTP IN
#   kr260-pair-flip-nptp  die_b (mirror pinout), PTP tied off
# PS/DDR/MIO come from the KR260 board preset (needs BOARD_PART set); PL clock,
# HPM0/HPM1_FPD masters and pl_ps_irq0 are overridden in the BD tcl.
else ifeq ($(TARGET),kr260-pair-ptp)
XILINX_PART     := xck26-sfvc784-2LV-c
FPGA_BOARD_PART := xilinx.com:kr260_som:part0:1.1
FPGA_TIDELINK_PTP := 1
else ifeq ($(TARGET),kr260-pair-nptp)
XILINX_PART     := xck26-sfvc784-2LV-c
FPGA_BOARD_PART := xilinx.com:kr260_som:part0:1.1
FPGA_TIDELINK_PTP := 0
else ifeq ($(TARGET),kr260-pair-flip-ptp)
XILINX_PART     := xck26-sfvc784-2LV-c
FPGA_BOARD_PART := xilinx.com:kr260_som:part0:1.1
FPGA_TIDELINK_PTP := 1
else ifeq ($(TARGET),kr260-pair-flip-nptp)
XILINX_PART     := xck26-sfvc784-2LV-c
FPGA_BOARD_PART := xilinx.com:kr260_som:part0:1.1
FPGA_TIDELINK_PTP := 0
else ifeq ($(TARGET),mps3)
XILINX_PART     := xcku115-flvb1760-1-c
endif

# Defaults for the non-KR260 targets: no board part, PTP inclusion left to the
# per-target BD tcl (Z2 -all targets tie PHC off, mmcmbypass-oddr-all keeps it).
FPGA_BOARD_PART   ?=
FPGA_TIDELINK_PTP ?=

#-----------------------------------------------------------------------------
# EPOCH_ANCHOR=1 — build the EPOCH whole-word deskew anchor variant.
#
# Selects TL_EPOCH_ANCHOR_EN in deps/tidelink-phy/rtl/wav/WavD2DGpio.v via a
# run-level -verilog_define (build_design.tcl). Unset = the shipped config,
# bit-identical. Intended for an on-silicon A/B against the default build:
#
#   make -C fpga build_design TARGET=kr260-pair-nptp      EPOCH_ANCHOR=1
#   make -C fpga build_design TARGET=kr260-pair-flip-nptp EPOCH_ANCHOR=1
#   -> imp/fpga/output/kr260-pair-nptp-anchor/tidelink.bit
#
# The outputs are suffixed so the two variants never overwrite each other.
#
# The IP CACHE gets its own directory for anchor builds. This is not paranoia:
# the packaged IP *sources* are byte-identical between the two variants (the
# selector is an `ifdef inside the source), and only the synth-run
# -verilog_define differs. Vivado keys config_ip_cache on IP config + part +
# tool, NOT on the run's MORE_OPTIONS — so a shared cache would happily return
# the anchor-OFF OOC netlist for an anchor-ON build, silently. Same class of
# trap as the cocotb SIM_BUILD collision (see cocotb/tidelink_top_pair_v2).
#-----------------------------------------------------------------------------
EPOCH_ANCHOR ?= 0
ifeq ($(EPOCH_ANCHOR),1)
TIDELINK_EPOCH_ANCHOR := 1
export TIDELINK_EPOCH_ANCHOR
ANCHOR_SUFFIX := -anchor
else
ANCHOR_SUFFIX :=
endif

# Build output directories
BUILD_DIR       := $(TIDELINK_HOME)/imp/fpga
IP_OUTPUT_DIR   := $(BUILD_DIR)/tidelink_ip
PHC_IP_OUTPUT_DIR := $(BUILD_DIR)/phc_ip
RUN_DIR         := $(BUILD_DIR)/run
PROJECT_DIR     := $(BUILD_DIR)/project/$(TARGET)$(ANCHOR_SUFFIX)
OUTPUT_DIR      := $(BUILD_DIR)/output/$(TARGET)$(ANCHOR_SUFFIX)

# PHC sibling repo (sourced by package_phc_ip; defaults assume the parallel
# SoC Labs checkout, override with PHC_REPO_DIR for CI / alternate layouts).
PHC_REPO_DIR    ?= $(HOME)/SoCLabs/ptp-hardware-clock-ahb
# Per-TARGET Vivado working dir. build_design cd's here and writes its
# -log/-journal here (NOT the shared RUN_DIR) so two TARGETs can build
# concurrently without clobbering each other's cwd (.Xil/, vivado*.jou)
# or logs — the prerequisite for the farm flow (scripts/build_farm.sh).
BUILD_RUN_DIR   := $(RUN_DIR)/$(TARGET)$(ANCHOR_SUFFIX)

# IP metadata
FPGA_VENDOR     := soclabs.org
FPGA_CORE_REV   := 1
# SoC Labs 2026-06-21 (turnaround): 4->8 so the ~4-5m OOC sub-IP synth runs overlap
# fully (host has 16 cores; lower it for smaller farm hosts). QoR-neutral.
FPGA_NUM_JOBS   ?= 8
# Shared persistent Vivado IP cache (build_design.tcl config_ip_cache). Reused across
# builds so unchanged static Xilinx OOC IP is fetched, not re-synthesised. Outside the
# create_project -force project dir; under imp/ (already gitignored). Override to share
# one cache across farm hosts. Empty = disabled (old behaviour).
#
# $(ANCHOR_SUFFIX) is part of the cache PATH because Vivado keys config_ip_cache on
# IP config + part + tool — NOT on the synth run's -verilog_define. The anchor-on and
# anchor-off builds have byte-identical packaged IP sources, so they would collide in
# one cache and the anchor-on build would silently link the anchor-OFF OOC netlist.
FPGA_IP_CACHE_DIR ?= $(abspath $(BUILD_DIR)/ip_cache$(ANCHOR_SUFFIX))

# Vivado-native remote-host farming (launch_runs -host). Empty = local build.
# "host jobs" pairs, e.g. FPGA_REMOTE_HOSTS="srv03335 4 srv04936 8".
# Prerequisites + sysadmin NFS request: fpga/docs/FARM_NFS_EXPORT_REQUEST.md.
# Validate a farm host first:  make farm_check FARM_HOST=srv04936
FPGA_REMOTE_HOSTS ?=
FPGA_REMOTE_CMD   ?=
FARM_HOST         ?= srv04936

# Concurrent independent-job farming (scripts/build_farm.sh). Unlike
# FPGA_REMOTE_HOSTS (Vivado -host, needs the unfulfilled NFS export — see
# docs/CONCURRENT_FARM.md) this runs whole TARGET builds in parallel, each
# pinned to a host, and works today over plain ssh+rsync to FARM_HOST.
#   FARM_JOBS   "TARGET@HOST ..."  (HOST = 'local' or a farm hostname)
#   SKIP_PACKAGE_IP=1  drop the package_ip prereq of build_design; the farm
#                      orchestrator runs package_ip ONCE then fans out
#                      build_design, so parallel runs don't race the shared
#                      IP repo. Standalone `make build_design` is unchanged.
FARM_JOBS         ?=
SKIP_PACKAGE_IP   ?=

ifeq ($(SKIP_PACKAGE_IP),1)
BUILD_DESIGN_DEPS :=
else
BUILD_DESIGN_DEPS := package_ip package_phc_ip
endif

.PHONY: all package_ip package_phc_ip build_design clean program deploy \
        program_via_fpgahub deploy_via_fpgahub stress_via_fpgahub ci_full_via_fpgahub \
        program_via_plugin deploy_via_plugin \
        resolve_board farm_check farm_build build_pair_concurrent \
        build_pair_farmed check-wrapper-params help

all: build_design

#-----------------------------------------------------------------------------
# Pre-flight guard: catch the 51b5169-class regression (USE_CLKBUF/USE_IDELAY
# wrapper-param strip) BEFORE Vivado packages the IP, instead of letting the
# silent-XDC-drop / LUT-on-clock cascade reach silicon. See
# docs/LANE_LOCK_ROOT_CAUSE.md and docs/SIM_GUARD_FEASIBILITY.md.
#-----------------------------------------------------------------------------
check-wrapper-params:
	@$(FPGA_DIR)/scripts/check_wrapper_params.sh

#-----------------------------------------------------------------------------
# Step 1: Package tidelink RTL as Vivado XCI IP
#-----------------------------------------------------------------------------
package_ip: check-wrapper-params
	@mkdir -p $(RUN_DIR) $(IP_OUTPUT_DIR)
	cd $(RUN_DIR) && \
	export FPGA_COMPONENT_FILELIST=$(FPGA_DIR)/filelist.tcl && \
	export FPGA_COMPONENT_LIB=$(IP_OUTPUT_DIR) && \
	export FPGA_VENDOR=$(FPGA_VENDOR) && \
	export FPGA_CORE_REV=$(FPGA_CORE_REV) && \
	vivado -mode batch -source $(VIVADO_IP_DIR)/package_tidelink_ip.tcl \
	    -log $(RUN_DIR)/package_ip.log \
	    -journal $(RUN_DIR)/package_ip.jou

#-----------------------------------------------------------------------------
# Step 1b: Package PHC (ptp-hardware-clock-ahb) as a Vivado XCI IP
# The PHC source repo is a sibling checkout (PHC_REPO_DIR). Outputs a separate
# IP repo so the build_design step can add it alongside FPGA_IP_REPO.
#-----------------------------------------------------------------------------
package_phc_ip:
	@if [ ! -d "$(PHC_REPO_DIR)" ]; then \
	    echo "ERROR: PHC_REPO_DIR=$(PHC_REPO_DIR) not found." >&2; \
	    echo "       Clone ptp-hardware-clock-ahb next to tidelink, or set PHC_REPO_DIR." >&2; \
	    exit 2; \
	fi
	@mkdir -p $(RUN_DIR) $(PHC_IP_OUTPUT_DIR)
	cd $(RUN_DIR) && \
	export PHC_REPO_DIR=$(PHC_REPO_DIR) && \
	export PHC_COMPONENT_LIB=$(PHC_IP_OUTPUT_DIR) && \
	export FPGA_VENDOR=$(FPGA_VENDOR) && \
	export FPGA_CORE_REV=$(FPGA_CORE_REV) && \
	vivado -mode batch -source $(VIVADO_IP_DIR)/phc/package_phc_ip.tcl \
	    -log $(RUN_DIR)/package_phc_ip.log \
	    -journal $(RUN_DIR)/package_phc_ip.jou

#-----------------------------------------------------------------------------
# Step 2: Build block design + synthesis + implementation + bitstream
#-----------------------------------------------------------------------------
build_design: $(BUILD_DESIGN_DEPS)
	@mkdir -p $(BUILD_RUN_DIR) $(PROJECT_DIR) $(OUTPUT_DIR)
	cd $(BUILD_RUN_DIR) && \
	export FPGA_PART=$(XILINX_PART) && \
	export FPGA_PROJECT_DIR=$(PROJECT_DIR) && \
	export FPGA_IP_REPO=$(IP_OUTPUT_DIR) && \
	export FPGA_PHC_IP_REPO=$(PHC_IP_OUTPUT_DIR) && \
	export FPGA_TARGET_DIR=$(TARGET_DIR) && \
	export FPGA_OUTPUT_DIR=$(OUTPUT_DIR) && \
	export FPGA_NUM_JOBS=$(FPGA_NUM_JOBS) && \
	export FPGA_IP_CACHE_DIR=$(FPGA_IP_CACHE_DIR) && \
	export FPGA_BOARD_PART='$(FPGA_BOARD_PART)' && \
	export FPGA_TIDELINK_PTP='$(FPGA_TIDELINK_PTP)' && \
	export FPGA_REMOTE_HOSTS='$(FPGA_REMOTE_HOSTS)' && \
	export FPGA_REMOTE_CMD='$(FPGA_REMOTE_CMD)' && \
	export FPGA_INSERT_DEBUG_CORE='$(FPGA_INSERT_DEBUG_CORE)' && \
	vivado -mode batch -source $(FPGA_DIR)/build_design.tcl \
	    -log $(BUILD_RUN_DIR)/build_design.log \
	    -journal $(BUILD_RUN_DIR)/build_design.jou
	@echo ""
	@echo "=========================================="
	@echo " FPGA build complete!"
	@echo " Bitstream: $(OUTPUT_DIR)/tidelink.bit"
	@echo " HWH:       $(OUTPUT_DIR)/tidelink.hwh"
	@echo "=========================================="

#-----------------------------------------------------------------------------
# Validate the four Vivado -host prerequisites against FARM_HOST before
# trusting FPGA_REMOTE_HOSTS in a real build. Run from an authenticated shell.
#-----------------------------------------------------------------------------
farm_check:
	@FARM_HOST='$(FARM_HOST)' BUILD_DIR='$(BUILD_DIR)' \
	    $(FPGA_DIR)/scripts/farm_preflight.sh

#-----------------------------------------------------------------------------
# Concurrent independent-job farming (works today — no NFS export needed).
#
# build_farm.sh runs package_ip ONCE locally, then fans out one whole
# `build_design` per job in parallel. Each job is "TARGET@HOST"; HOST is
# 'local' (this box) or a farm hostname (ssh+rsync — tree out, build there,
# only imp/fpga/output/<TARGET>/ rsynced back to the identical local path so
# `make deploy` / deploy_pair work unchanged). See docs/CONCURRENT_FARM.md.
#
#   make farm_build FARM_JOBS="pynq-z2-pair-all@local pynq-z2-pair-flip-all@srv04936"
#-----------------------------------------------------------------------------
farm_build:
	@if [ -z "$(FARM_JOBS)" ]; then \
	    echo 'ERROR: set FARM_JOBS="TARGET@HOST ...", e.g.' >&2; \
	    echo '  make farm_build FARM_JOBS="pynq-z2-pair-all@local pynq-z2-pair-flip-all@$(FARM_HOST)"' >&2; \
	    exit 2; \
	fi
	@FPGA_INSERT_DEBUG_CORE='$(FPGA_INSERT_DEBUG_CORE)' \
	    $(FPGA_DIR)/scripts/build_farm.sh $(FARM_JOBS)

# The headline pair flows. *_concurrent runs master+slave in parallel on
# THIS host (promotes the old /tmp/build_pair_parallel.sh prototype, now
# race-safe). *_farmed offloads the slave onto FARM_HOST so the two halves
# build at the same time on two machines (~halves wall time, unloads the
# contended local host).
build_pair_concurrent:
	@FPGA_INSERT_DEBUG_CORE='$(FPGA_INSERT_DEBUG_CORE)' \
	    $(FPGA_DIR)/scripts/build_farm.sh \
	        pynq-z2-pair-all@local pynq-z2-pair-flip-all@local

build_pair_farmed:
	@FPGA_INSERT_DEBUG_CORE='$(FPGA_INSERT_DEBUG_CORE)' \
	    $(FPGA_DIR)/scripts/build_farm.sh \
	        pynq-z2-pair-all@local pynq-z2-pair-flip-all@$(FARM_HOST)

#-----------------------------------------------------------------------------
# Deployment helpers
#-----------------------------------------------------------------------------
BITSTREAM       := $(OUTPUT_DIR)/tidelink.bit
BITBIN          := $(OUTPUT_DIR)/tidelink.bin
HWH             := $(OUTPUT_DIR)/tidelink.hwh
BIT2BIN         := $(FPGA_DIR)/scripts/bit2bin.py

#-----------------------------------------------------------------------------
# Deploy style — keyed off TARGET.
#
#   fpga_manager (Zynq-7000 / Pynq-Z2): bit2bin.py strips the .bit header and
#       byte-swaps for the *zynq-fpga* driver (equivalent to
#       `bootgen -arch zynq -process_bitstream bin`), then the .bin is dropped
#       into /lib/firmware and poked at /sys/class/fpga_manager/fpga0/firmware.
#
#   pynq_overlay (Zynq UltraScale+ / KR260 on the PYNQ Kria image): PYNQ's
#       Overlay() loads the .bit directly (it drives the zynqmp fpga_manager
#       itself) using the sibling .hwh. There is NO bit2bin step and NO
#       /lib/firmware dance.
#
# bit2bin.py MUST NOT be used on ZynqMP: its byte-swap is the zynq-fpga
# driver's format, not the zynqmp one. Feeding a KR260 a bit2bin .bin silently
# produces a bad PL load. Hence the artefact list is style-dependent.
#-----------------------------------------------------------------------------
ifneq ($(filter kr260-%,$(TARGET)),)
DEPLOY_STYLE     := pynq_overlay
TIDELINK_SOC     := kr260
DEPLOY_ARTEFACTS := $(BITSTREAM) $(HWH)
else
DEPLOY_STYLE     := fpga_manager
TIDELINK_SOC     := z2
DEPLOY_ARTEFACTS := $(BITSTREAM) $(BITBIN) $(HWH)
endif

# FPGA board selection — preferred path is via fpgahub:
#   BOARD=fpga1          explicit board name in the local fpgahub config
#   BOARD_TAG=pynq_z2    auto-allocate first free board declaring this capability
#
# When BOARD is set, PYNQ_HOST / PYNQ_PROXY default to the board's
# configured host.ssh / host.proxy looked up via `fpgahub board status`.
# When neither BOARD nor BOARD_TAG is set, callers must export PYNQ_HOST
# and PYNQ_PROXY explicitly (useful for ad-hoc runs outside fpgahub).
BOARD           ?=
BOARD_TAG       ?=

ifneq ($(BOARD),)
# Hide "command not found" from shells that haven't installed fpgahub/jq
# yet — a missing tool turns into an empty string and the deploy target
# prints a clean "set BOARD or PYNQ_HOST" error instead of leaking shell
# noise through make -n output.
PYNQ_HOST       ?= $(shell sh -c 'fpgahub board status $(BOARD) --json 2>/dev/null | jq -r ".host_ssh // empty"' 2>/dev/null)
PYNQ_PROXY      ?= $(shell sh -c 'fpgahub board status $(BOARD) --json 2>/dev/null | jq -r ".host_proxy // empty"' 2>/dev/null)
endif
PYNQ_DEST       ?= /home/xilinx/tidelink_overlay
PYNQ_PASSWORD   ?= xilinx

ifneq ($(PYNQ_PROXY),)
SSH_OPTS  := -o "ProxyJump=$(PYNQ_PROXY)"
SCP_OPTS  := -o "ProxyJump=$(PYNQ_PROXY)"
else
SSH_OPTS  :=
SCP_OPTS  :=
endif

# Board identifier passed to `fpgahub actions run` — either the explicit
# BOARD, or --capability $(BOARD_TAG) for auto-allocation.
ifneq ($(BOARD),)
FPGAHUB_TARGET  := $(BOARD)
else ifneq ($(BOARD_TAG),)
FPGAHUB_TARGET  := --capability $(BOARD_TAG)
else
FPGAHUB_TARGET  :=
endif

# Print the resolved SSH target so CI / dev shells can sanity-check it.
resolve_board:
	@if [ -z "$(BOARD)" ] && [ -z "$(BOARD_TAG)" ]; then \
	    echo "ERROR: set BOARD=<name> or BOARD_TAG=<capability>" >&2; exit 2; \
	fi
	@if [ -n "$(BOARD)" ]; then \
	    fpgahub board status $(BOARD) --json | \
	        jq -r '"board=\(.name)\nssh=\(.host_ssh // "-")\nproxy=\(.host_proxy // "-")\nlease=\(.lease_state)"'; \
	else \
	    echo "Resolve via: fpgahub lease acquire --capability $(BOARD_TAG) --ttl 1h"; \
	    fpgahub board list --capability $(BOARD_TAG); \
	fi

program:
	@test -f $(BITSTREAM) || (echo "ERROR: $(BITSTREAM) not found - run 'make build_design' first"; exit 1)
	@echo "Programming $(BITSTREAM) via JTAG..."
	cd $(OUTPUT_DIR) && \
	vivado -mode batch -nojournal -nolog \
	    -source $(FPGA_DIR)/program_bitstream.tcl \
	    -tclargs $(BITSTREAM)

# bit-to-bin conversion for Linux fpga_manager - strips header, bit-reverses.
$(BITBIN): $(BITSTREAM) $(BIT2BIN)
	python3 $(BIT2BIN) $(BITSTREAM) $(BITBIN)

# One-time NOPASSWD sudo provisioning for a fresh PYNQ-Z2 image.
# Wraps fpga/scripts/provision_pynq_sudo.sh so fpgahub can dispatch
# this as a manifest action with the standard PYNQ_HOST / PYNQ_PROXY /
# PYNQ_PASSWORD env. Idempotent — re-running on a board that's already
# provisioned is a no-op.
#
# Usage (manual / lab):
#   make -C fpga provision_pynq_sudo PYNQ_HOST=xilinx@192.168.4.101 PYNQ_PASSWORD=xilinx
.PHONY: provision_pynq_sudo
provision_pynq_sudo:
	@if [ -z "$(PYNQ_HOST)" ]; then \
	    echo "ERROR: set PYNQ_HOST=user@host (or BOARD=<n> via fpgahub)." >&2; exit 2; \
	fi
	@if [ -z "$(PYNQ_PASSWORD)" ]; then \
	    echo "ERROR: set PYNQ_PASSWORD (the xilinx user's existing sudo password)." >&2; exit 2; \
	fi
	@PYNQ_HOST="$(PYNQ_HOST)" PYNQ_PROXY="$(PYNQ_PROXY)" PYNQ_PASSWORD="$(PYNQ_PASSWORD)" \
	    $(FPGA_DIR)/scripts/provision_pynq_sudo.sh

# One-time route provisioning for a paired PYNQ-Z2 image. Adds a
# persistent kernel route to the peer board's PS-side /24 via
# mapstone-dev as gateway, so the stress runner's peer-agent SSH spawn
# works without manual ProxyJump plumbing. Idempotent.
#
# Two invocation modes:
#
#   1. Manifest-driven (fpgahub):
#        PYNQ_HOST = {host.ssh}            (e.g. xilinx@192.168.4.101)
#        PEER_SSH  = {pair.peer.host.ssh}  (e.g. xilinx@192.168.6.101)
#      The make target derives PEER_NET (peer's /24) and GATEWAY
#      (this board's /24, .1) automatically from those.
#
#   2. Manual / standalone:
#        PYNQ_HOST=xilinx@192.168.4.101
#        PEER_NET=192.168.6.0/24
#        GATEWAY=192.168.4.1
#      Pass them explicitly; PEER_SSH not needed.

.PHONY: provision_pynq_route
provision_pynq_route:
	@if [ -z "$(PYNQ_HOST)" ]; then \
	    echo "ERROR: set PYNQ_HOST=user@host." >&2; exit 2; \
	fi
	@if [ -z "$(PYNQ_PASSWORD)" ]; then \
	    echo "ERROR: set PYNQ_PASSWORD (sudo)." >&2; exit 2; \
	fi
	@if [ -z "$(PEER_NET)" ] && [ -z "$(PEER_SSH)" ]; then \
	    echo "ERROR: set PEER_NET=<peer/24> OR PEER_SSH=user@peer-IP." >&2; exit 2; \
	fi
	@if [ -z "$(GATEWAY)" ] && [ -z "$(PYNQ_HOST)" ]; then \
	    echo "ERROR: set GATEWAY=<local-net-gateway-IP> OR PYNQ_HOST=user@local-IP for auto-derivation." >&2; exit 2; \
	fi
	@# Derive PEER_NET and GATEWAY from PEER_SSH / PYNQ_HOST when not
	@# given explicitly. Both inputs are "user@a.b.c.d"; chop off the
	@# user@ prefix and trim the last octet via shell parameter
	@# expansion so we get a.b.c.0/24 / a.b.c.1 respectively.
	@LOCAL_IP="$(PYNQ_HOST)"; LOCAL_IP="$${LOCAL_IP#*@}"; \
	 PEER_IP="$(PEER_SSH)"; PEER_IP="$${PEER_IP#*@}"; \
	 _PEER_NET="$(PEER_NET)"; \
	 [ -n "$$_PEER_NET" ] || _PEER_NET="$${PEER_IP%.*}.0/24"; \
	 _GATEWAY="$(GATEWAY)"; \
	 [ -n "$$_GATEWAY" ]  || _GATEWAY="$${LOCAL_IP%.*}.1"; \
	 echo "Provisioning route: PYNQ_HOST=$(PYNQ_HOST) PEER_NET=$$_PEER_NET GATEWAY=$$_GATEWAY"; \
	 PYNQ_HOST="$(PYNQ_HOST)" PYNQ_PROXY="$(PYNQ_PROXY)" \
	    PEER_NET="$$_PEER_NET" GATEWAY="$$_GATEWAY" \
	    PYNQ_PASSWORD="$(PYNQ_PASSWORD)" \
	    $(FPGA_DIR)/scripts/provision_pynq_route.sh

# One-time SSH peer-key provisioning. Generates xilinx@<board>:~/.ssh/id_ed25519
# (if missing) and propagates the pubkey to david@mapstone-dev (intermediate
# hop) and xilinx@<peer> (final hop) so the stress runner's peer-agent SSH
# spawn can authenticate at both hops without prompts. Idempotent.
#
# Manifest-driven (fpgahub):
#     PYNQ_HOST = {host.ssh}            (this board)
#     PEER_SSH  = {pair.peer.host.ssh}  (peer board)
.PHONY: provision_pynq_peer_keys
provision_pynq_peer_keys:
	@if [ -z "$(PYNQ_HOST)" ] || [ -z "$(PEER_SSH)" ]; then \
	    echo "ERROR: set PYNQ_HOST=<user@board> and PEER_SSH=<user@peer>." >&2; exit 2; \
	fi
	@PYNQ_HOST="$(PYNQ_HOST)" PEER_HOST="$(PEER_SSH)" \
	    MAPSTONE_HOST="$(MAPSTONE_HOST)" \
	    PYNQ_PROXY="$(PYNQ_PROXY)" \
	    PYNQ_PASSWORD="$(PYNQ_PASSWORD)" \
	    $(FPGA_DIR)/scripts/provision_pynq_peer_keys.sh

# Map an fpgahub pair role (die_a / die_b) to the matching TARGET, then
# call deploy. The two pair targets ship MIRRORED RPi pinouts so the
# physical cross-cable wires up correctly. fpgahub renders this via:
#   command = ["make", "-C", "fpga", "deploy_pair_role",
#              "ROLE={pair.local.role}", ...]
#
#   SOC=z2     (default) -> pynq-z2-pair-all / -flip-all      [PTP ignored]
#   SOC=kr260            -> kr260-pair-{,flip-}{ptp,nptp}, selected by PTP=1|0
#
#   make -C fpga deploy_pair_role ROLE=die_a SOC=kr260 PTP=1 BOARD=kria1
SOC ?= z2
PTP ?= 0
.PHONY: deploy_pair_role
deploy_pair_role:
	@set -e; \
	case "$(SOC)" in \
	  z2) case "$(ROLE)" in \
	        die_a) t=pynq-z2-pair-all ;; \
	        die_b) t=pynq-z2-pair-flip-all ;; \
	        *) echo "ERROR: ROLE must be die_a or die_b (got '$(ROLE)')" >&2; exit 2 ;; \
	      esac ;; \
	  kr260) case "$(PTP)" in \
	           1) sfx=ptp ;; 0) sfx=nptp ;; \
	           *) echo "ERROR: PTP must be 0 or 1 (got '$(PTP)')" >&2; exit 2 ;; \
	         esac; \
	         case "$(ROLE)" in \
	           die_a) t=kr260-pair-$$sfx ;; \
	           die_b) t=kr260-pair-flip-$$sfx ;; \
	           *) echo "ERROR: ROLE must be die_a or die_b (got '$(ROLE)')" >&2; exit 2 ;; \
	         esac ;; \
	  *) echo "ERROR: SOC must be z2 or kr260 (got '$(SOC)')" >&2; exit 2 ;; \
	esac; \
	echo "deploy_pair_role: SOC=$(SOC) ROLE=$(ROLE) PTP=$(PTP) -> TARGET=$$t"; \
	$(MAKE) -C $(FPGA_DIR) deploy TARGET=$$t \
	    PYNQ_HOST="$(PYNQ_HOST)" PYNQ_PROXY="$(PYNQ_PROXY)"

deploy: $(DEPLOY_ARTEFACTS)
	@if [ -z "$(PYNQ_HOST)" ]; then \
	    echo "ERROR: PYNQ_HOST is empty. Set BOARD=<name> (fpgahub lookup) or PYNQ_HOST=user@host." >&2; \
	    exit 2; \
	fi
	@echo "Copying overlay to $(PYNQ_HOST)$(if $(PYNQ_PROXY), via $(PYNQ_PROXY),) [style=$(DEPLOY_STYLE) soc=$(TIDELINK_SOC)]..."
	@ssh $(SSH_OPTS) $(PYNQ_HOST) "mkdir -p $(PYNQ_DEST)"
	@scp $(SCP_OPTS) $(BITSTREAM)             $(PYNQ_HOST):$(PYNQ_DEST)/
	@if [ "$(DEPLOY_STYLE)" = "fpga_manager" ]; then \
	    scp $(SCP_OPTS) $(BITBIN)             $(PYNQ_HOST):$(PYNQ_DEST)/ ; \
	fi
	@scp $(SCP_OPTS) $(HWH)                   $(PYNQ_HOST):$(PYNQ_DEST)/
	@# Drop any leftover pynq/ from earlier deploys — it would shadow the
	@# system PYNQ framework's `pynq` package on sys.path and break
	@# `from pynq import Overlay, MMIO` inside pynq_host/overlay.py.
	@# Needs sudo because leftover __pycache__ files inside the stale
	@# pynq/ tree are root-owned (created when root-run stress.runner
	@# imported them on prior runs).
	@ssh $(SSH_OPTS) $(PYNQ_HOST) "echo $(PYNQ_PASSWORD) | sudo -S rm -rf $(PYNQ_DEST)/pynq"
	@# Ship the entire pynq_host/ package (renamed from pynq/ to avoid the
	@# system-framework collision). Invoked as `python3 -m pynq_host.stress.runner`
	@# from $(PYNQ_DEST); imports like `from pynq_host.overlay import
	@# TidelinkOverlay` resolve to our package, and `from pynq import
	@# Overlay, MMIO` falls through to the system framework.
	@scp $(SCP_OPTS) -r $(TIDELINK_HOME)/pynq_host $(PYNQ_HOST):$(PYNQ_DEST)/
	@# tidelink/ is a sibling helper package — pynq_host/stress/bridge_tests.py
	@# imports `from tidelink.regs import ...`. Place it at $(PYNQ_DEST)/tidelink/
	@# so cwd-based resolution finds both packages.
	@scp $(SCP_OPTS) -r $(TIDELINK_HOME)/python/tidelink $(PYNQ_HOST):$(PYNQ_DEST)/
ifeq ($(DEPLOY_STYLE),fpga_manager)
	@echo "Installing .bin into /lib/firmware/ and loading via fpga_manager..."
	@ssh $(SSH_OPTS) $(PYNQ_HOST) "echo $(PYNQ_PASSWORD) | sudo -S cp $(PYNQ_DEST)/tidelink.bin /lib/firmware/ && \
	    echo $(PYNQ_PASSWORD) | sudo -S bash -c \"echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware\" && \
	    cat /sys/class/fpga_manager/fpga0/state"
else
	@# PYNQ Overlay() resolves the .hwh by sibling basename (tidelink.bit ->
	@# tidelink.hwh) and TidelinkOverlay() defaults its bitfile to the copy
	@# living NEXT TO pynq_host/overlay.py. Stage both into pynq_host/ so the
	@# zero-argument TidelinkOverlay() works, and keep the $(PYNQ_DEST) copies
	@# for anything passing an explicit path.
	@ssh $(SSH_OPTS) $(PYNQ_HOST) "cp $(PYNQ_DEST)/tidelink.bit $(PYNQ_DEST)/tidelink.hwh $(PYNQ_DEST)/pynq_host/"
	@echo "Loading PL via PYNQ Overlay (ZynqMP; no bit2bin / no /lib/firmware)..."
	@ssh $(SSH_OPTS) $(PYNQ_HOST) "cd $(PYNQ_DEST) && echo $(PYNQ_PASSWORD) | sudo -S -E env TIDELINK_SOC=$(TIDELINK_SOC) \
	    python3 -c \"from pynq import Overlay; ol = Overlay('$(PYNQ_DEST)/pynq_host/tidelink.bit'); print('PL loaded:', ol.bitfile_name); print('IPs:', len(getattr(ol, 'ip_dict', {})))\""
endif
	@echo ""
	@echo "Deployed and loaded (style=$(DEPLOY_STYLE)). To run stress test from the board:"
	@echo "  ssh $(SSH_OPTS) $(PYNQ_HOST)"
	@echo "  cd $(PYNQ_DEST) && sudo TIDELINK_SOC=$(TIDELINK_SOC) python3 -m pynq_host.stress.runner --budget 300"

#-----------------------------------------------------------------------------
# fpgahub-driven variants — run the same targets through the manifest so
# the lease is acquired, extend_for_action keeps it alive, and no two
# jobs clash on the same board. See fpga/fpgahub.toml for action defs.
#
# Acquire a board pair:
#   fpgahub pair up tidelink_bridge_01 --ttl 7200
#-----------------------------------------------------------------------------

program_via_fpgahub:
	@echo "ERROR: tidelink has no bare 'program' / 'deploy' actions —" >&2
	@echo "       use program_via_plugin (recommended), or pick a named" >&2
	@echo "       manifest action: program_z2_single / program_z2_pair /" >&2
	@echo "       program_mps3 / deploy_z2_single / deploy_z2_pair." >&2
	@echo "       e.g.  TARGET=pynq-z2-single make program_via_plugin" >&2
	@exit 2

deploy_via_fpgahub:
	@echo "ERROR: tidelink has no bare 'deploy' action —" >&2
	@echo "       use deploy_via_plugin (recommended) or fpgahub actions" >&2
	@echo "       run BOARD deploy_z2_single / deploy_z2_pair." >&2
	@exit 2

# fpgahub board-program plugin path. Hands the freshly-built bitstream
# to whichever program plugin is configured under
# [boards.<n>.program.<method>] (vivado_jtag / pynq_overlay /
# sd_install). Bypasses the manifest. FPGAHUB_METHOD picks a non-default
# method; FPGAHUB_FORCE=1 overrides the part-mismatch refusal.
FPGAHUB_METHOD  ?=
program_via_plugin: $(BITSTREAM)
	@if [ -z "$(BOARD)" ]; then \
	    echo "ERROR: set BOARD=<name>" >&2; exit 2; \
	fi
	fpgahub board program $(BOARD) $(BITSTREAM) \
	    $(if $(FPGAHUB_METHOD),--method $(FPGAHUB_METHOD)) \
	    $(if $(FPGAHUB_FORCE),--force)

deploy_via_plugin: $(BITSTREAM)
	@if [ -z "$(BOARD)" ]; then \
	    echo "ERROR: set BOARD=<name>" >&2; exit 2; \
	fi
	fpgahub board program $(BOARD) $(BITSTREAM) \
	    --method $(if $(FPGAHUB_METHOD),$(FPGAHUB_METHOD),linux) \
	    $(if $(FPGAHUB_FORCE),--force)

stress_via_fpgahub:
	@if [ -z "$(FPGAHUB_TARGET)" ]; then \
	    echo "ERROR: set BOARD=<name> or BOARD_TAG=<capability>" >&2; exit 2; \
	fi
	fpgahub actions run $(FPGAHUB_TARGET) stress_test

ci_full_via_fpgahub:
	@if [ -z "$(FPGAHUB_TARGET)" ]; then \
	    echo "ERROR: set BOARD=<name> or BOARD_TAG=<capability>" >&2; exit 2; \
	fi
	fpgahub actions run $(FPGAHUB_TARGET) ci_full

#-----------------------------------------------------------------------------
# Clean
#-----------------------------------------------------------------------------
clean:
	rm -rf $(BUILD_DIR)

#-----------------------------------------------------------------------------
# Help
#-----------------------------------------------------------------------------
help:
	@echo ""
	@echo "TideLink FPGA Build Flow"
	@echo "========================"
	@echo ""
	@echo "Usage: make [TARGET=<board>] <target>"
	@echo ""
	@echo "TARGET values (default: pynq-z2-single):"
	@echo "  pynq-z2-single     Digilent Pynq-Z2 — single-node    (xc7z020clg400-1)"
	@echo "  pynq-z2-pair       Digilent Pynq-Z2 — paired         (xc7z020clg400-1)"
	@echo "  pynq-z2-pair-flip  Digilent Pynq-Z2 — paired (mirror)(xc7z020clg400-1)"
	@echo "  pynq-z2-loopback     Digilent Pynq-Z2 — internal TX→RX  (xc7z020clg400-1)"
	@echo "  mps3                 MPS3 / Arm baseboard               (xcku115-flvb1760-1-c)"
	@echo ""
	@echo "Build targets:"
	@echo "  all               Full flow: package_ip -> build_design (default)"
	@echo "  package_ip        Package TideLink RTL as Vivado XCI IP"
	@echo "  build_design      Block design + synth + impl + bitstream + .hwh"
	@echo "  farm_check        Verify Vivado -host prereqs vs FARM_HOST"
	@echo ""
	@echo "Concurrent farming (parallel whole-TARGET builds — no NFS needed):"
	@echo "  build_pair_concurrent  master+slave in parallel on THIS host"
	@echo "  build_pair_farmed      master local + slave on FARM_HOST, concurrent"
	@echo "  farm_build             generic: FARM_JOBS=\"TARGET@HOST ...\""
	@echo "  program           JTAG-program the PL via Vivado Hardware Manager"
	@echo "  deploy            SCP .bit/.bin/.hwh to PYNQ board and load via fpga_manager"
	@echo "  clean             Remove all build outputs (imp/fpga/)"
	@echo ""
	@echo "fpgahub targets (set BOARD=<name> or BOARD_TAG=<cap>):"
	@echo "  resolve_board          Show resolved SSH endpoint for current BOARD"
	@echo "  program_via_fpgahub    Program via fpgahub manifest 'program' action"
	@echo "  deploy_via_fpgahub     Deploy via fpgahub manifest 'deploy' action"
	@echo "  program_via_plugin     Program via [boards.<n>.program.default] plugin"
	@echo "  deploy_via_plugin      Program via 'linux' method (pynq_overlay)"
	@echo "  stress_via_fpgahub     Stress-test via fpgahub lease"
	@echo "  ci_full_via_fpgahub    Full CI sweep via fpgahub lease"
	@echo ""
	@echo "Examples:"
	@echo "  make TARGET=pynq-z2-single build_design"
	@echo "  make TARGET=pynq-z2-pair   build_design"
	@echo "  make TARGET=mps3           build_design"
	@echo "  make farm_check FARM_HOST=srv04936"
	@echo "  make TARGET=pynq-z2-pair build_design \\"
	@echo "       FPGA_REMOTE_HOSTS=\"srv03335 4 srv04936 8\""
	@echo "  make build_pair_farmed FARM_HOST=srv04936"
	@echo "  make build_pair_concurrent"
	@echo "  make farm_build \\"
	@echo "       FARM_JOBS=\"pynq-z2-pair-all@local pynq-z2-pair-flip-all@srv04936\""
	@echo "  make TARGET=pynq-z2-single BOARD=fpga1 deploy"
	@echo "  make TARGET=pynq-z2-pair   BOARD_TAG=pynq_z2 deploy_via_fpgahub"
	@echo ""
	@echo "Current TARGET=$(TARGET)  XILINX_PART=$(XILINX_PART)"
	@echo ""
