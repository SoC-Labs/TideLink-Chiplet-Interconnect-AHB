# =============================================================================
# wavd2d_gpiorx_wordpin — SIM-GATE 1 (unit latch proof) for the FIX-R
#                          word-window pin added to WavD2DGpioRx.
# =============================================================================
#
# FIX-R adds io_word_pin (4-bit, per-lane) to src/rtl/local_overrides/
# WavD2DGpioRx.v: a third RX alignment dimension that SLIDES the completed-word
# LOAD decode by 0..15 capture cells (io_phase_offset and io_bit_slip are pure
# rotations and CANNOT move the 16-cell capture window). word_pin=0 is the
# bit-exact legacy framing. The fix is OFF-by-default; B->A (the proven-good
# silicon direction) MUST stay byte-identical with word_pin=0.
#
# This env proves, in seconds with VCS, the SAFETY + LOGIC of the change:
#
#   equiv   (tb_realrtl_equiv.sv) — GOLD STANDARD 1a. Instantiates the REAL
#           committed local_overrides WavD2DGpioRx with io_word_pin=0 AND a
#           module-renamed copy of the PROVEN-GOOD baseline @142a7ca RX (no
#           io_word_pin port), drives an identical serial stream + pad clock,
#           and asserts io_link_data is BYTE-IDENTICAL across ALL 16
#           io_phase_offset values. The baseline copy is generated at build
#           time from `git show 142a7ca:` so it can never silently drift.
#           => PROVES the B->A OFF-by-default byte-exact guarantee on real RTL.
#
#   verify  (wp_verify_model.sv) — 1a (model). The proposed two-stage word_pin
#           latch == the legacy single-stage latch at word_pin=0, all 16 phases,
#           in an idealised model of the exact capture chain. RESULT: PASS.
#
#   reject  (wp_reject_model.sv) — 1b + 1c. NEGATIVE controls: the deps-style
#           load-at-(count==word_pin) and load-at-(adj_count==15-word_pin) are
#           DIRTY at phase!=0 (15/16 and 16/16) while ONLY adj_count==(0-pin) is
#           byte-exact — guards against a future "simplify to the deps form"
#           regression. Plus the window RE-CUT dump (distinct captured words
#           across word_pin), proving the pin actually relocates the boundary.
#
# Run (clean each time — VCS does NOT rebuild simv on RTL edits):
#   cd <repo> && source set_env.sh
#   make -C cocotb/wavd2d_gpiorx_wordpin            # builds + runs all three
#   make -C cocotb/wavd2d_gpiorx_wordpin clean
#
# A joint work commissioned on behalf of SoC Labs, Arm Academic Access license.
# Contributors: David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
RTL    := $(TIDELINK_HOME)/src/rtl/local_overrides
WLINK  := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink
# Proven-good baseline anchor the equivalence diffs against.
BASE_REF ?= 142a7ca

VCS := vcs -full64 -sverilog -timescale=1ns/1ps -q
PRIM := $(WLINK)/WavClockInv.v $(WLINK)/WavClockMux.v $(WLINK)/WavResetSync.v \
        $(WLINK)/WavDemetSet.v $(WLINK)/WavAnd.v

.PHONY: all equiv verify reject clean
all: equiv verify reject
	@echo "==================================================================="
	@echo "SIM-GATE 1 (wavd2d_gpiorx_wordpin) COMPLETE — see RESULT lines above"
	@echo "==================================================================="

# --- GOLD STANDARD: real-RTL differential, word_pin=0 vs baseline @142a7ca ----
WavD2DGpioRx_BASE.v:
	@git -C $(TIDELINK_HOME) show $(BASE_REF):src/rtl/local_overrides/WavD2DGpioRx.v \
	  | sed 's/module WavD2DGpioRx/module WavD2DGpioRx_BASE/' > $@
	@echo "generated $@ from git $(BASE_REF) (proven-good baseline, module renamed)"

equiv: WavD2DGpioRx_BASE.v
	@echo "--- [equiv] real-RTL byte-exact differential (word_pin=0 vs $(BASE_REF)) ---"
	$(VCS) -o simv_equiv tb_realrtl_equiv.sv \
	  $(RTL)/WavD2DGpioRx.v WavD2DGpioRx_BASE.v $(PRIM) > build_equiv.log 2>&1
	./simv_equiv | tee run_equiv.log
	@grep -q "RESULT: PASS" run_equiv.log || (echo "EQUIV FAILED"; exit 1)

verify:
	@echo "--- [verify] model: word_pin=0 == legacy single-stage, all 16 phases ---"
	$(VCS) -o simv_verify wp_verify_model.sv > build_verify.log 2>&1
	./simv_verify | tee run_verify.log
	@grep -q "RESULT: PASS" run_verify.log || (echo "VERIFY FAILED"; exit 1)

reject:
	@echo "--- [reject] model: negative controls + window re-cut ---"
	$(VCS) -o simv_reject wp_reject_model.sv > build_reject.log 2>&1
	./simv_reject | tee run_reject.log
	@grep -q "ONLY adj_count==(0-wp) is byte-exact" run_reject.log || (echo "REJECT FAILED"; exit 1)

clean:
	rm -rf simv_* csrc *.daidir *.log ucli.key WavD2DGpioRx_BASE.v \
	       DVEfiles AN.DB novas* verdiLog
