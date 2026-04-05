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

# CMSDK path (Arm Corstone SSE-200 / BP210 package)
export CMSDK_DIR="${CMSDK_DIR:-${ARM_IP_LIBRARY_PATH}/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0}"

# XHB500 source IP (Arm XHB-500 Generic Global Bundle)
export XHB500_IP_DIR="${XHB500_IP_DIR:-${ARM_IP_LIBRARY_PATH}/DMA-350/CG096-r0p0-00rel0/PL417-BU-50000-r0p1-00rel0/xhb500}"

# Generated XHB500 output (within this repo, gitignored)
export XHB500_GEN_DIR="${TIDELINK_HOME}/deps/xhb500/generated"
export XHB500_SLV_DIR="${XHB500_GEN_DIR}/xhb_chiplet_slv"
export XHB500_MST_DIR="${XHB500_GEN_DIR}/xhb_chiplet_mst"

# EDA tools
export VCS_HOME="${VCS_HOME:-/eda/synopsys/2022-23/RHELx86/VCS_2022.06-SP2}"
export VERDI_HOME="${VERDI_HOME:-/eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2}"
export VIP_HOME="${VIP_HOME:-/eda/synopsys/2022-23/RHELx86/VC-VIP-SOC_2022.12}"

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

unset -f _generate_xhb500
echo ""
echo "Environment ready."
