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

# cmsdk_fpga_sram.v is missing from the Corstone-101 BP210 install used in CI;
# fall back to the standalone BP210 install when not present in CMSDK_DIR.
if [ -z "${CMSDK_FPGA_SRAM_V}" ]; then
    if [ -f "${CMSDK_DIR}/logical/models/memories/cmsdk_fpga_sram.v" ]; then
        export CMSDK_FPGA_SRAM_V="${CMSDK_DIR}/logical/models/memories/cmsdk_fpga_sram.v"
    else
        export CMSDK_FPGA_SRAM_V="${ARM_IP_LIBRARY_PATH}/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v"
    fi
fi

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

    # A generation counts as complete only if the terminal leaf artefact every
    # flist consumes (xhb500_flop.sv) is present — NOT merely logical/, which a
    # failed run leaves behind half-written. Testing the bare directory would
    # [skip] regeneration over a broken tree forever (e.g. right after you
    # install the missing dependency), making the fix look like a no-op.
    local done_marker="${output_dir}/logical/models/cells/generic/xhb500_flop.sv"
    if [ -f "${done_marker}" ]; then
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

    # $? after a pipeline is the status of its LAST command (sed, ~always 0),
    # NOT the generator's — capture the generator's real exit code via
    # PIPESTATUS[0]. (PIPESTATUS is used rather than `set -o pipefail` because
    # this file is *sourced*: pipefail would leak into the caller's shell.)
    local gen_rc="${PIPESTATUS[0]}"

    if [ "${gen_rc}" -eq 0 ] && [ -f "${done_marker}" ]; then
        echo "  [done] ${name} generated at ${output_dir}"
    else
        echo "  [ERROR] Failed to generate ${name} (generator exit ${gen_rc})"
        # Remove the partial tree so a retry actually re-runs the generator
        # instead of [skip]-ing over half-written output on the next source.
        rm -rf "${output_dir}"
        return 1
    fi
}

# ---------------------------------------------------------------
# Undocumented host requirements for the Arm XHB500 generator.
# Both fail *inside* the generator, with a message that names neither
# set_env.sh nor the real cause. Probe for them here so the diagnosis is
# at the source rather than a mystifying VCS "cannot be opened" minutes later.
#   * perl module File::Slurp  — perl-File-Slurp on RHEL 8 (appstream)
#   * python3 in [3.7, 3.11)   — the generator calls open(..., 'U');
#                                universal-newline mode was REMOVED in 3.11
#                                ("ValueError: invalid mode: 'U'").
#                                Verified: 3.6/3.8 ok, 3.11/3.12 fail.
# Non-fatal: warn clearly and let the generator emit the authoritative error.
# ---------------------------------------------------------------
_xhb500_host_preflight() {
    if ! perl -MFile::Slurp -e 1 >/dev/null 2>&1; then
        echo "  [WARN] perl module File::Slurp not found — the XHB500 generator will"
        echo "         abort with \"Can't locate File/Slurp.pm\". On RHEL 8:"
        echo "         dnf install perl-File-Slurp"
    fi
    local _pyver
    _pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
    case "${_pyver}" in
        3.7|3.8|3.9|3.10) ;;  # supported window
        "") echo "  [WARN] could not determine python3 version; the XHB500 generator needs >= 3.7 and < 3.11." ;;
        *)  echo "  [WARN] python3 is ${_pyver}; the XHB500 generator needs >= 3.7 and < 3.11"
            echo "         (it calls open(...,'U'), removed in 3.11 -> \"invalid mode: 'U'\")." ;;
    esac
}

echo "TideLink environment setup:"
echo "  TIDELINK_HOME  = ${TIDELINK_HOME}"
echo "  CMSDK_DIR      = ${CMSDK_DIR}"
echo "  XHB500_IP_DIR  = ${XHB500_IP_DIR}"
echo "  XHB500_GEN_DIR = ${XHB500_GEN_DIR}"
echo ""

echo "Checking XHB500 generated IP..."
# Probe host requirements only when a (re)generation is actually going to run.
if [ ! -f "${XHB500_SLV_DIR}/logical/models/cells/generic/xhb500_flop.sv" ] || \
   [ ! -f "${XHB500_MST_DIR}/logical/models/cells/generic/xhb500_flop.sv" ]; then
    _xhb500_host_preflight
fi
_generate_xhb500 \
    "${XHB500_CFG_DIR}/cfg_xhb_ahb_to_axi.cfg" \
    "${XHB500_SLV_DIR}" \
    "xhb500_ahb_to_axi_bridge_chiplet_slv"

_generate_xhb500 \
    "${XHB500_CFG_DIR}/cfg_xhb_axi_to_ahb.cfg" \
    "${XHB500_MST_DIR}" \
    "xhb500_axi_to_ahb_bridge_chiplet_mst"

unset -f _generate_xhb500 _xhb500_host_preflight
echo ""
echo "Environment ready."
