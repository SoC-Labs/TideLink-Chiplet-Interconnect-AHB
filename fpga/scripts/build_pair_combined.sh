#!/bin/bash
# Combined build: integration base (cab2d8f mask_hs gate + d1351f4 SWI_RECAL)
# + per-lane-phase (5633c69/cbf8c73) + (applied separately just before this
# runs) lane-7 pin remap to W9/V7 IF v4 confirms lane 7 is a physical pin.
# Builds from the per-lane-phase worktree, NOT the consolidation worktree.
set -e
WT=${TIDELINK_BUILD_WT:-/tmp/phase_sweep_wt}
cd $WT/fpga
source $WT/set_env.sh > /dev/null 2>&1
export CMSDK_DIR=/research/AAA/ip_library/BP210/BP210-BU-00000-r1p1-00rel0
export CMSDK_FPGA_SRAM_V="${CMSDK_DIR}/logical/models/memories/cmsdk_fpga_sram.v"
export FPGA_INSERT_DEBUG_CORE=1
echo "TIDELINK_HOME=$TIDELINK_HOME (expect $WT)"
ls "$CMSDK_FPGA_SRAM_V" >/dev/null
ls -ld $WT/deps/xhb500/generated >/dev/null   # agent-symlinked vendor RTL

echo "=== package_ip $(date) ==="
make package_ip 2>&1 | tail -3
PKG=${PIPESTATUS[0]}; [ "$PKG" != 0 ] && { echo "PACKAGE_IP FAILED $PKG"; exit 1; }

rm -rf $WT/imp/fpga/project/pynq-z2-pair-all $WT/imp/fpga/project/pynq-z2-pair-flip-all

echo "=== MASTER start $(date) ==="
make build_design TARGET=pynq-z2-pair-all 2>&1 | tail -8
echo "=== MASTER end $(date) ==="
echo "=== SLAVE start $(date) ==="
make build_design TARGET=pynq-z2-pair-flip-all 2>&1 | tail -8
echo "=== SLAVE end $(date) ==="
echo "=== DONE $(date) ==="
