#!/usr/bin/env bash
#=============================================================================
# ci/v1_build_flip.sh  —  CI wrapper around fpga/scripts/build_farm.sh for the
#   V1 silicon bilateral regression flow.
#
# Builds the TideLink FPGA bitstream(s) needed by the deploy_test stage and
# copies them (+ their .bin and .hwh) into a flat artefact directory that the
# GitLab `artifacts:` block exports. The deploy_test stage (ci/v1_deploy_test.sh)
# consumes that directory.
#
# By default it builds BOTH halves of the pair so a single nightly artefact set
# is self-sufficient for a cold re-deploy:
#     die_a (non-flip) : pynq-z2-pair-all
#     die_b (flip)     : pynq-z2-pair-flip-all   <- the half the V1 A->B fix lives in
# Set BUILD_TARGETS to override (e.g. just the flip half during a fix campaign).
#
# This runs on a Vivado-capable runner (tag: tidelink-fpga-build) which has:
#   * Vivado 2024.1 on PATH (or at VIVADO_BIN),
#   * the Arm IP library mounted at $ARM_IP_LIBRARY_PATH (/research/AAA/ip_library),
#   * passwordless ssh to the farm host(s) named in BUILD_TARGETS (setup_farm_ssh.sh),
#   * a checkout of this repo with submodules.
#
# Required / defaulted env:
#   BUILD_TARGETS   space-separated TARGET@HOST list passed to build_farm.sh
#                   [default: "pynq-z2-pair-all@local pynq-z2-pair-flip-all@srv04936"]
#   ARM_IP_LIBRARY_PATH   Arm IP root            [default: /research/AAA/ip_library]
#   VIVADO_BIN      vivado binary (added to PATH) [default: from PATH, else
#                   /apps/Xilinx/Vivado/2024.1/bin/vivado]
#   PHC_REPO_DIR    sibling PHC repo for the -all BD package_phc_ip step
#                   [default: $HOME/SoCLabs/ptp-hardware-clock-ahb; skipped if absent]
#   ARTIFACT_DIR    where to collect outputs     [default: $PWD/ci_artifacts/fpga]
#
# Exit codes:
#   0   all requested targets built; artefacts collected
#   1   a build failed (build_farm.sh non-zero) OR an expected .bit is missing
#   2   environment problem (missing Vivado / IP library / set_env.sh)
#=============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_FARM="$TIDELINK_HOME/fpga/scripts/build_farm.sh"

BUILD_TARGETS="${BUILD_TARGETS:-pynq-z2-pair-all@local pynq-z2-pair-flip-all@srv04936}"
ARM_IP_LIBRARY_PATH="${ARM_IP_LIBRARY_PATH:-/research/AAA/ip_library}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$PWD/ci_artifacts/fpga}"

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ printf '[v1-build %s] %s\n' "$(ts)" "$*"; }
die(){ log "FATAL: $*"; exit "${2:-1}"; }

# ---- environment preflight --------------------------------------------------
[ -x "$BUILD_FARM" ] || die "build_farm.sh not found at $BUILD_FARM" 2
[ -d "$ARM_IP_LIBRARY_PATH" ] || die "ARM_IP_LIBRARY_PATH not a dir: $ARM_IP_LIBRARY_PATH (Arm IP library not mounted?)" 2

# Put Vivado on PATH if not already there.
if ! command -v vivado >/dev/null 2>&1; then
  VIVADO_BIN="${VIVADO_BIN:-/apps/Xilinx/Vivado/2024.1/bin/vivado}"
  if [ -x "$VIVADO_BIN" ]; then
    export PATH="$(dirname "$VIVADO_BIN"):$PATH"
    log "added $(dirname "$VIVADO_BIN") to PATH"
  fi
fi
command -v vivado >/dev/null 2>&1 || die "vivado not on PATH and VIVADO_BIN not executable" 2
log "vivado: $(command -v vivado)  ($(vivado -version 2>/dev/null | head -1))"

# set_env.sh derives CMSDK_DIR / XHB500_IP_DIR / CMSDK_FPGA_SRAM_V from
# ARM_IP_LIBRARY_PATH and generates the XHB500 bridge IP. build_farm.sh sources
# it again for local jobs, but sourcing here surfaces any IP-gen failure early.
export ARM_IP_LIBRARY_PATH
# shellcheck disable=SC1091
source "$TIDELINK_HOME/set_env.sh" 2>&1 | sed 's/^/  /' || die "set_env.sh failed (XHB500 gen / IP paths)" 2

# Make the PHC sibling repo discoverable for the -all BD (package_phc_ip).
export PHC_REPO_DIR="${PHC_REPO_DIR:-$HOME/SoCLabs/ptp-hardware-clock-ahb}"
[ -d "$PHC_REPO_DIR" ] && log "PHC_REPO_DIR=$PHC_REPO_DIR (package_phc_ip enabled)" \
                       || log "PHC_REPO_DIR=$PHC_REPO_DIR absent — building without PHC IP"

# ---- run the farm build -----------------------------------------------------
log "build targets: $BUILD_TARGETS"
# shellcheck disable=SC2086
"$BUILD_FARM" $BUILD_TARGETS
rc=$?
if [ "$rc" -ne 0 ]; then
  log "build_farm.sh failed (rc=$rc) — see imp/fpga/run/farm/*.log"
  exit 1
fi
log "build_farm.sh: all targets built"

# ---- collect artefacts (.bit + .bin + .hwh per target) ----------------------
mkdir -p "$ARTIFACT_DIR"
missing=0
for job in $BUILD_TARGETS; do
  target="${job%@*}"
  out="$TIDELINK_HOME/imp/fpga/output/$target"
  bit="$out/tidelink.bit"
  if [ ! -f "$bit" ]; then
    log "ERROR: expected bitstream missing: $bit"
    missing=1
    continue
  fi
  dest="$ARTIFACT_DIR/$target"
  mkdir -p "$dest"
  cp "$bit" "$dest/tidelink.bit"
  # bit2bin so deploy can flash via fpga_manager without re-converting.
  if python3 "$TIDELINK_HOME/fpga/scripts/bit2bin.py" "$bit" "$dest/tidelink.bin" 2>/dev/null; then
    log "  $target: .bit + .bin collected"
  else
    log "  $target: .bit collected (bit2bin failed — deploy will convert)"
  fi
  # .hwh is REQUIRED by deploy_pair.sh; copy if present.
  cp "$out/tidelink.hwh" "$dest/tidelink.hwh" 2>/dev/null \
    && log "  $target: .hwh collected" \
    || log "  $target: WARN no .hwh (deploy_pair.sh needs it; overlay-program path is fine without)"
  sha256sum "$dest/tidelink.bit" | sed 's/^/  sha256 /'
done

if [ "$missing" -ne 0 ]; then
  die "one or more expected bitstreams were missing after build" 1
fi

log "artefacts collected under $ARTIFACT_DIR"
ls -R "$ARTIFACT_DIR" | sed 's/^/  /'
exit 0
