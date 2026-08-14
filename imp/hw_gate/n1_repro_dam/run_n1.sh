#!/usr/bin/env bash
# N1 fix-validation runner (dam). OVERRIDE route: compiles an override copy of
# tidelink_top.sv (HEAD +/- the N1 fix) via a swapped v2shim in a private flist,
# leaving the tracked tree byte-identical. Usage: run_n1.sh <fix|nofix>
set -e
MODE="${1:?usage: run_n1.sh <fix|nofix>}"
LOG2="${N1_TIMEOUT_LOG2:-11}"
REPO=/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink
MYDIR="$REPO/imp/hw_gate/n1_repro_dam"
cd "$REPO"
set +u
source ./set_env.sh >/dev/null 2>&1
set -u

if [ "$MODE" = "fix" ]; then
    BASE="$MYDIR/n1fix_base.flist";   LOCAL="$MYDIR/n1fix_local.flist"
    SB="sim_build_n1fixdam";          EXPECT="recover"
else
    BASE="$MYDIR/n1nofix_base.flist"; LOCAL="$MYDIR/n1nofix_local.flist"
    SB="sim_build_n1nofixdam";        EXPECT="hang"
fi

cd "$REPO/cocotb/tidelink_axi_datanode_recovery"
# md5 the tracked DUT before the run (prove no mutation)
echo "PRE-RUN  tracked src/rtl/tidelink_top.sv md5: $(md5sum "$REPO/src/rtl/tidelink_top.sv")"

N1_TIMEOUT_LOG2="$LOG2" N1_EXPECT="$EXPECT" \
  make \
    MODULE=test_n1_fix_recovery_dam \
    TESTCASE=test_n1_coincident_deferred_recovery \
    SIM_BUILD="$SB" \
    BASE_FLIST="$BASE" \
    LOCAL_FLIST="$LOCAL" \
    EXTRA_DEFINES="+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=$LOG2" \
    REF_PERIOD_NS=40.0

rc=$?
echo "POST-RUN tracked src/rtl/tidelink_top.sv md5: $(md5sum "$REPO/src/rtl/tidelink_top.sv")"
echo "make rc=$rc"
exit $rc
