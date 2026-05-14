.PHONY: clean_all clean_uvm clean_cocotb clean_formal clean_lint clean_syn

# Clean all verification, lint, and synthesis directories
clean_all: clean_uvm clean_cocotb clean_formal clean_lint clean_syn
	@echo "All clean targets completed"

# Clean UVM directories
clean_uvm:
	@echo "Cleaning UVM directories..."
	$(MAKE) -C uvm/tidelink clean
	$(MAKE) -C uvm/tidelink_fc_adapter clean
	$(MAKE) -C uvm/tidelink_integration clean
	$(MAKE) -C uvm/tidelink_top_system clean
	$(MAKE) -C uvm/tidelink_ptp_chain clean
	$(MAKE) -C uvm/tidelink_ptp_stress clean
	$(MAKE) -C uvm/tidelink_system clean
	@echo "UVM clean completed"

# Clean cocotb directories
clean_cocotb:
	@echo "Cleaning cocotb directories..."
	$(MAKE) -C cocotb/tidelink clean
	$(MAKE) -C cocotb/tidelink_ahb clean
	$(MAKE) -C cocotb/tidelink_fifo clean
	$(MAKE) -C cocotb/tidelink_returner clean
	$(MAKE) -C cocotb/tidelink_apb_regs clean
	$(MAKE) -C cocotb/tidelink_py_pair clean
	$(MAKE) -C cocotb/tidelink_fc_adapter clean
	$(MAKE) -C cocotb/tidelink_top clean
	$(MAKE) -C cocotb/tidelink_system clean
	$(MAKE) -C cocotb/tidelink_ptp clean
	@echo "cocotb clean completed"

# Clean formal verification directories
clean_formal:
	@echo "Cleaning formal verification directories..."
	$(MAKE) -C formal/tidelink clean
	$(MAKE) -C formal/tidelink_fifo clean
	$(MAKE) -C formal/tidelink_fifo_ctrl clean
	$(MAKE) -C formal/tidelink_apb_regs clean
	$(MAKE) -C formal/tidelink_returner clean
	@echo "Formal verification clean completed"

# Clean lint directory
clean_lint:
	@echo "Cleaning lint directory..."
	$(MAKE) -C lint clean
	@echo "Lint clean completed"

# Clean synthesis directories
clean_syn:
	@echo "Cleaning synthesis directories..."
	$(MAKE) -C syn/asic/rtl-architect clean
	$(MAKE) -C syn/asic/design-compiler clean
	@echo "Synthesis clean completed"
