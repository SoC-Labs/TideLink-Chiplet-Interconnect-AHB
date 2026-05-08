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
VALID_TARGETS   := pynq-z2-single pynq-z2-pair pynq-z2-pair-flip pynq-z2-pair-slow pynq-z2-pair-flip-slow pynq-z2-pair-ila pynq-z2-pair-flip-ila pynq-z2-pair-all pynq-z2-pair-flip-all pynq-z2-loopback mps3
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
else ifeq ($(TARGET),pynq-z2-pair-all)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-pair-flip-all)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),pynq-z2-loopback)
XILINX_PART     := xc7z020clg400-1
else ifeq ($(TARGET),mps3)
XILINX_PART     := xcku115-flvb1760-1-c
endif

# Build output directories
BUILD_DIR       := $(TIDELINK_HOME)/imp/fpga
IP_OUTPUT_DIR   := $(BUILD_DIR)/tidelink_ip
RUN_DIR         := $(BUILD_DIR)/run
PROJECT_DIR     := $(BUILD_DIR)/project/$(TARGET)
OUTPUT_DIR      := $(BUILD_DIR)/output/$(TARGET)

# IP metadata
FPGA_VENDOR     := soclabs.org
FPGA_CORE_REV   := 1
FPGA_NUM_JOBS   ?= 4

.PHONY: all package_ip build_design clean program deploy \
        program_via_fpgahub deploy_via_fpgahub stress_via_fpgahub ci_full_via_fpgahub \
        program_via_plugin deploy_via_plugin \
        resolve_board help

all: build_design

#-----------------------------------------------------------------------------
# Step 1: Package tidelink RTL as Vivado XCI IP
#-----------------------------------------------------------------------------
package_ip:
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
# Step 2: Build block design + synthesis + implementation + bitstream
#-----------------------------------------------------------------------------
build_design: package_ip
	@mkdir -p $(RUN_DIR) $(PROJECT_DIR) $(OUTPUT_DIR)
	cd $(RUN_DIR) && \
	export FPGA_PART=$(XILINX_PART) && \
	export FPGA_PROJECT_DIR=$(PROJECT_DIR) && \
	export FPGA_IP_REPO=$(IP_OUTPUT_DIR) && \
	export FPGA_TARGET_DIR=$(TARGET_DIR) && \
	export FPGA_OUTPUT_DIR=$(OUTPUT_DIR) && \
	export FPGA_NUM_JOBS=$(FPGA_NUM_JOBS) && \
	vivado -mode batch -source $(FPGA_DIR)/build_design.tcl \
	    -log $(RUN_DIR)/build_design.log \
	    -journal $(RUN_DIR)/build_design.jou
	@echo ""
	@echo "=========================================="
	@echo " FPGA build complete!"
	@echo " Bitstream: $(OUTPUT_DIR)/tidelink.bit"
	@echo " HWH:       $(OUTPUT_DIR)/tidelink.hwh"
	@echo "=========================================="

#-----------------------------------------------------------------------------
# Deployment helpers
#-----------------------------------------------------------------------------
BITSTREAM       := $(OUTPUT_DIR)/tidelink.bit
BITBIN          := $(OUTPUT_DIR)/tidelink.bin
HWH             := $(OUTPUT_DIR)/tidelink.hwh
BIT2BIN         := $(FPGA_DIR)/scripts/bit2bin.py

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

# Map an fpgahub pair role (die_a / die_b) to the matching TARGET, then
# call deploy. The two pair targets ship MIRRORED RPi pinouts so the
# physical cross-cable wires up correctly. fpgahub renders this via:
#   command = ["make", "-C", "fpga", "deploy_pair_role",
#              "ROLE={pair.local.role}", ...]
.PHONY: deploy_pair_role
deploy_pair_role:
	@case "$(ROLE)" in \
	    die_a) $(MAKE) -C $(FPGA_DIR) deploy TARGET=pynq-z2-pair-all      \
	            PYNQ_HOST="$(PYNQ_HOST)" PYNQ_PROXY="$(PYNQ_PROXY)" ;;    \
	    die_b) $(MAKE) -C $(FPGA_DIR) deploy TARGET=pynq-z2-pair-flip-all \
	            PYNQ_HOST="$(PYNQ_HOST)" PYNQ_PROXY="$(PYNQ_PROXY)" ;;    \
	    *)     echo "ERROR: deploy_pair_role: ROLE must be die_a or die_b (got '$(ROLE)')" >&2; exit 2 ;; \
	esac

deploy: $(BITSTREAM) $(BITBIN) $(HWH)
	@if [ -z "$(PYNQ_HOST)" ]; then \
	    echo "ERROR: PYNQ_HOST is empty. Set BOARD=<name> (fpgahub lookup) or PYNQ_HOST=user@host." >&2; \
	    exit 2; \
	fi
	@echo "Copying overlay to $(PYNQ_HOST)$(if $(PYNQ_PROXY), via $(PYNQ_PROXY),)..."
	@ssh $(SSH_OPTS) $(PYNQ_HOST) "mkdir -p $(PYNQ_DEST)"
	@scp $(SCP_OPTS) $(BITSTREAM)             $(PYNQ_HOST):$(PYNQ_DEST)/
	@scp $(SCP_OPTS) $(BITBIN)                $(PYNQ_HOST):$(PYNQ_DEST)/
	@scp $(SCP_OPTS) $(HWH)                   $(PYNQ_HOST):$(PYNQ_DEST)/
	@scp $(SCP_OPTS) -r $(TIDELINK_HOME)/pynq/* $(PYNQ_HOST):$(PYNQ_DEST)/
	@echo "Installing .bin into /lib/firmware/ and loading via fpga_manager..."
	@ssh $(SSH_OPTS) $(PYNQ_HOST) "echo $(PYNQ_PASSWORD) | sudo -S cp $(PYNQ_DEST)/tidelink.bin /lib/firmware/ && \
	    echo $(PYNQ_PASSWORD) | sudo -S bash -c \"echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware\" && \
	    cat /sys/class/fpga_manager/fpga0/state"
	@echo ""
	@echo "Deployed and loaded. To run stress test from PYNQ:"
	@echo "  ssh $(SSH_OPTS) $(PYNQ_HOST)"
	@echo "  cd $(PYNQ_DEST) && sudo python3 -m stress.runner --budget 300"

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
	@echo "  pynq-z2-loopback   Digilent Pynq-Z2 — internal TX→RX (xc7z020clg400-1)"
	@echo "  mps3               MPS3 / Arm baseboard              (xcku115-flvb1760-1-c)"
	@echo ""
	@echo "Build targets:"
	@echo "  all               Full flow: package_ip -> build_design (default)"
	@echo "  package_ip        Package TideLink RTL as Vivado XCI IP"
	@echo "  build_design      Block design + synth + impl + bitstream + .hwh"
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
	@echo "  make TARGET=pynq-z2-single BOARD=fpga1 deploy"
	@echo "  make TARGET=pynq-z2-pair   BOARD_TAG=pynq_z2 deploy_via_fpgahub"
	@echo ""
	@echo "Current TARGET=$(TARGET)  XILINX_PART=$(XILINX_PART)"
	@echo ""
