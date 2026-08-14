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

unset -f _generate_xhb500 _xhb500_host_preflight _require
echo ""
echo "Environment ready."
