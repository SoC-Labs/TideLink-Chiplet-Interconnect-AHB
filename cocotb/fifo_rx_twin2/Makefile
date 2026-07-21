SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# ── Config select: 'tree' (the DEFAULT, real shared RTL) or 'unfixed' ─────────
# POLARITY FLIPPED 2026-07-19, when docs/proposals/twin2_fix.patch was APPLIED:
#   * 'tree'    -> src/rtl/fifo/*.sv, the REAL shared RTL, now carrying the fix.
#                  This is what the gate runs, and it must PASS. It was called
#                  'patched' while the fix was an unapplied proposal and pointed
#                  at local *.PATCHED.sv copies; those copies are DELETED, because
#                  a gate that tests a private copy of the fix tells you nothing
#                  about what ships.
#   * 'unfixed' -> frozen local *.UNFIXED.sv copies of the PRE-FIX RTL. THE
#                  NEGATIVE CONTROL: it must still FAIL, which is what proves the
#                  test has teeth. See flist_unfixed.f.
# Each config gets its OWN sim_build so a cached simv can never false-PASS the
# A/B (the exact stale-simv trap that hid the phantom-pop proof: cocotb
# recompiles only on tb_top.sv changes, so an RTL/flist swap alone does NOT
# retrigger VCS).
FIFO_SRC ?= tree
ifeq ($(FIFO_SRC),unfixed)
  FIFO_FLIST = $(CURDIR)/flist_unfixed.f
else ifeq ($(FIFO_SRC),tree)
  FIFO_FLIST = $(CURDIR)/flist_tree.f
else
  $(error FIFO_SRC must be 'tree' or 'unfixed', got '$(FIFO_SRC)')
endif
SIM_BUILD = $(CURDIR)/sim_build_$(FIFO_SRC)
# Keep each config's results in its OWN build dir (cocotb otherwise writes
# results.xml to CWD and the second run clobbers the first).
export COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_fifo_rx_twin2

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(FIFO_FLIST)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

# ── A/B convenience targets ──────────────────────────────────────────────────
# `make ab` runs the SAME test against unfixed (the frozen pre-fix copies —
# expect FAIL) then tree (the real shared RTL — expect PASS), each from a clean
# build dir, and prints a verdict.
.PHONY: ab unfixed tree
unfixed:
	$(MAKE) FIFO_SRC=unfixed sim

tree:
	$(MAKE) FIFO_SRC=tree sim

ab:
	@rm -rf $(CURDIR)/sim_build_unfixed $(CURDIR)/sim_build_tree
	@echo "=================== A: UNFIXED RTL (expect FAIL) ==================="
	-@$(MAKE) --no-print-directory FIFO_SRC=unfixed sim >/dev/null 2>&1; \
	  grep -E "TESTS=|FAIL=|PASS=" $(CURDIR)/sim_build_unfixed/results.xml 2>/dev/null; \
	  python3 -c "import sys,xml.etree.ElementTree as ET; \
	    r=ET.parse('$(CURDIR)/sim_build_unfixed/results.xml').getroot(); \
	    f=sum(1 for tc in r.iter('testcase') if tc.find('failure') is not None); \
	    t=sum(1 for tc in r.iter('testcase')); \
	    print(f'  UNFIXED: {t-f}/{t} passed, {f} failed  ->  '+('CORRECT (bug reproduced)' if f>0 else 'WRONG (bug did NOT reproduce)'))"
	@echo "============= B: TREE (real shared RTL, expect PASS) ==============="
	-@$(MAKE) --no-print-directory FIFO_SRC=tree sim >/dev/null 2>&1; \
	  python3 -c "import sys,xml.etree.ElementTree as ET; \
	    r=ET.parse('$(CURDIR)/sim_build_tree/results.xml').getroot(); \
	    f=sum(1 for tc in r.iter('testcase') if tc.find('failure') is not None); \
	    t=sum(1 for tc in r.iter('testcase')); \
	    print(f'  TREE:    {t-f}/{t} passed, {f} failed  ->  '+('CORRECT (fix holds in the tree)' if f==0 else 'WRONG (still failing)'))"

.PHONY: clean_all
clean_all:
	rm -rf $(CURDIR)/sim_build_unfixed $(CURDIR)/sim_build_tree \
	       $(CURDIR)/sim_build_patched \
	       $(CURDIR)/results.xml $(CURDIR)/waves.vcd $(CURDIR)/*.log \
	       $(CURDIR)/__pycache__
