export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/..)

# VCS flags
VCS       = vcs
VCS_FLAGS = -full64 -sverilog -timescale=1ns/1ps \
            -debug_access+all -kdb \
            +lint=all,noVCDE,noUI,noNS \
            -l compile.log

# Filelist
FLIST = $(TIDELINK_HOME)/flist/tb_tidelink_sram_manager.flist

# Simulation executable
SIMV = simv

.PHONY: compile run gui clean all

all: compile run

compile: $(SIMV)

$(SIMV): $(FLIST)
	$(VCS) $(VCS_FLAGS) -f $^ -o $@

run: $(SIMV)
	./$(SIMV) -l sim.log

gui: $(SIMV) 
	unset NOVAS_HOME; VERDI_HOME=/eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2/ ./$(SIMV) -l sim.log -gui

clean:
	rm -rf $(SIMV) $(SIMV).daidir csrc *.log *.fsdb *.vpd *.vcd ucli.key
