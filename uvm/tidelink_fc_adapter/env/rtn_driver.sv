///////////////////////////////////////////////////////////////////////////////
// rtn_driver.sv
///////////////////////////////////////////////////////////////////////////////
// UVM driver for AHB master writes to DUT's returner interception slave port.
// Mimics how the returner AHB master drives writes (NONSEQ, write-only).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_RTN_DRIVER_SV
`define GUARD_RTN_DRIVER_SV

class rtn_driver extends uvm_driver #(ahb_tx_seq_item);

  `uvm_component_utils(rtn_driver)

  virtual tidelink_fc_adapter_if vif;

  function new(string name = "rtn_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual tidelink_fc_adapter_if)::get(this, "", "dut_vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not found for rtn_driver")
  endfunction

  virtual task run_phase(uvm_phase phase);
    // Initialize returner AHB bus to idle
    vif.rtn_drv_cb.rtn_htrans <= 2'b00;
    vif.rtn_drv_cb.rtn_hwrite <= 1'b0;
    vif.rtn_drv_cb.rtn_haddr  <= 32'h0;
    vif.rtn_drv_cb.rtn_hwdata <= 32'h0;
    vif.rtn_drv_cb.rtn_hsize  <= 3'b010;

    @(posedge vif.rst_n);
    @(posedge vif.clk);

    forever begin
      ahb_tx_seq_item item;
      seq_item_port.get_next_item(item);
      drive_rtn_write(item);
      seq_item_port.item_done();
    end
  endtask

  virtual task drive_rtn_write(ahb_tx_seq_item item);
    // Optional delay
    repeat (item.delay) @(posedge vif.clk);

    // Address phase: drive NONSEQ write
    @(posedge vif.clk);
    vif.rtn_drv_cb.rtn_htrans <= 2'b10;  // NONSEQ
    vif.rtn_drv_cb.rtn_hwrite <= 1'b1;
    vif.rtn_drv_cb.rtn_haddr  <= item.addr;
    vif.rtn_drv_cb.rtn_hsize  <= item.hsize;

    // Wait for hready (address phase accepted)
    @(posedge vif.clk);
    while (!vif.rtn_drv_cb.rtn_hready) begin
      @(posedge vif.clk);
    end

    // Data phase: drive write data, return to idle
    vif.rtn_drv_cb.rtn_htrans <= 2'b00;  // IDLE
    vif.rtn_drv_cb.rtn_hwrite <= 1'b0;
    vif.rtn_drv_cb.rtn_hwdata <= item.data;

    // Wait for data phase to complete
    @(posedge vif.clk);
    while (!vif.rtn_drv_cb.rtn_hready) begin
      @(posedge vif.clk);
    end

    `uvm_info("RTN_DRV", $sformatf("Drove RTN write: addr=0x%08h data=0x%08h",
      item.addr, item.data), UVM_HIGH)
  endtask

endclass

`endif // GUARD_RTN_DRIVER_SV
