#!/bin/bash
###############################################################################
# TideLink Environment Setup
###############################################################################
# Source this file before running UVM simulations:
#   source set_env.sh
#
# This script:
#   1. Sets environment variables for EDA tools and IP paths
#   2. Generates XHB500 bridge IP (if not already present) into deps/xhb500/
#      using the Arm XHB500 Generator with the config files in
#      deps/xhb500/configs/
###############################################################################

# Project root
export TIDELINK_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------
# Site configuration.
#
# Tool installs and vendor IP roots are per-machine facts, so they live in
# site.env (NOT tracked). Copy site.env.example to site.env and edit it, or
# export the same names from your login profile / site module file.
#
# NOTHING HERE CARRIES A DEFAULT PATH, deliberately: a default pointing at one
# lab's mount produces a setup that looks configured and is not — it resolves
# on exactly one machine, and everywhere else it fails as a missing FILE rather
# than as a missing SETTING. Unset, _require below names the variable.
#
# site.env is also `-include`d by syn/asic/common.mk, which is why it is
# written in the Make/shell syntax intersection (`export N=v`, no spaces).
# ---------------------------------------------------------------
if [ -f "${TIDELINK_HOME}/site.env" ]; then
    # shellcheck disable=SC1091
    . "${TIDELINK_HOME}/site.env"
fi

# Name the variable, say what it locates, and point at the one file that sets
# it. Non-fatal (this script is *sourced*; exiting would kill the caller's
# shell) but unmissable, and the flist/VCS failure that follows is no longer a
# mystery.
_require() {
    local var="$1" what="$2"
    if [ -z "${!var}" ]; then
        echo "  [ERROR] ${var} is not set — it locates ${what}."
        echo "          Copy site.env.example to site.env and set it there, or"
        echo "          export it in your environment. There is no default."
        return 1
    fi
}

# Arm Cortex-M System Design Kit. The package directory name carries a release
# code that differs per licensee, so CMSDK_DIR is set whole, not assembled.
_require CMSDK_DIR "the Arm Cortex-M System Design Kit package root"

# cmsdk_fpga_sram.v is absent from some CMSDK packages. Derive it from
# CMSDK_DIR when it is there; otherwise site.env must name it directly.
if [ -z "${CMSDK_FPGA_SRAM_V}" ]; then
    if [ -f "${CMSDK_DIR}/logical/models/memories/cmsdk_fpga_sram.v" ]; then
        export CMSDK_FPGA_SRAM_V="${CMSDK_DIR}/logical/models/memories/cmsdk_fpga_sram.v"
    else
        _require CMSDK_FPGA_SRAM_V \
            "cmsdk_fpga_sram.v, which this CMSDK package does not ship (set it to the copy in whichever package does)"
    fi
fi
export CMSDK_FPGA_SRAM_V

# Arm XHB-500 AHB/AXI bridge generator bundle
_require XHB500_IP_DIR "the Arm XHB-500 bridge IP root (the directory holding logical/generate)"

# Generated XHB500 output (within this repo, gitignored)
export XHB500_GEN_DIR="${TIDELINK_HOME}/deps/xhb500/generated"
export XHB500_SLV_DIR="${XHB500_GEN_DIR}/xhb_chiplet_slv"
export XHB500_MST_DIR="${XHB500_GEN_DIR}/xhb_chiplet_mst"

# EDA tools. Not _require'd: many hosts put these on PATH from a site module
# file instead, and the simulator's own "command not found" is already clear.
export VCS_HOME VERDI_HOME VIP_HOME

# ---------------------------------------------------------------
# Generate XHB500 bridges if not already present
# ---------------------------------------------------------------
XHB500_GENERATOR="${XHB500_IP_DIR}/logical/generate"
XHB500_CFG_DIR="${TIDELINK_HOME}/deps/xhb500/configs"

_generate_xhb500() {
    local config_file="$1"
    local output_dir="$2"
    local name="$3"

    if [ -d "${output_dir}/logical" ]; then
        echo "  [skip] ${name} already generated at ${output_dir}"
        return 0
    fi

    if [ ! -f "${XHB500_GENERATOR}" ]; then
        echo "  [ERROR] XHB500 generator not found at: ${XHB500_GENERATOR}"
        echo "          Set XHB500_IP_DIR to the Arm XHB-500 IP root directory."
        return 1
    fi

    echo "  [gen]  Generating ${name}..."
    mkdir -p "${output_dir}"
    python3 "${XHB500_GENERATOR}" \
        --config "${config_file}" \
        --output "${output_dir}" \
        2>&1 | sed 's/^/         /'

    if [ $? -eq 0 ] && [ -d "${output_dir}/logical" ]; then
        echo "  [done] ${name} generated at ${output_dir}"
    else
        echo "  [ERROR] Failed to generate ${name}"
        return 1
    fi
}

echo "TideLink environment setup:"
echo "  TIDELINK_HOME  = ${TIDELINK_HOME}"
echo "  CMSDK_DIR      = ${CMSDK_DIR}"
echo "  XHB500_IP_DIR  = ${XHB500_IP_DIR}"
echo "  XHB500_GEN_DIR = ${XHB500_GEN_DIR}"
echo ""

echo "Checking XHB500 generated IP..."
_generate_xhb500 \
    "${XHB500_CFG_DIR}/cfg_xhb_ahb_to_axi.cfg" \
    "${XHB500_SLV_DIR}" \
    "xhb500_ahb_to_axi_bridge_chiplet_slv"

_generate_xhb500 \
    "${XHB500_CFG_DIR}/cfg_xhb_axi_to_ahb.cfg" \
    "${XHB500_MST_DIR}" \
    "xhb500_axi_to_ahb_bridge_chiplet_mst"

unset -f _generate_xhb500 _require
echo ""
echo "Environment ready."
