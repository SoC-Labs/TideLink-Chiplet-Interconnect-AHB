///////////////////////////////////////////////////////////////////////////////
// ahb_tx_driver.sv
///////////////////////////////////////////////////////////////////////////////
// UVM driver for AHB master writes to DUT's TX aperture slave port.
// Drives AHB-Lite single write transfers (address phase + data phase).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_TX_DRIVER_SV
`define GUARD_AHB_TX_DRIVER_SV

class ahb_tx_driver extends uvm_driver #(ahb_tx_seq_item);

  `uvm_component_utils(ahb_tx_driver)

  virtual tidelink_fc_adapter_if vif;

  function new(string name = "ahb_tx_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual tidelink_fc_adapter_if)::get(this, "", "dut_vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not found for ahb_tx_driver")
  endfunction

  virtual task run_phase(uvm_phase phase);
    // Initialize TX aperture AHB bus to idle
    vif.ahb_tx_drv_cb.ahb_tx_hsel   <= 1'b0;
    vif.ahb_tx_drv_cb.ahb_tx_htrans <= 2'b00;
    vif.ahb_tx_drv_cb.ahb_tx_hwrite <= 1'b0;
    vif.ahb_tx_drv_cb.ahb_tx_haddr  <= 14'h0;
    vif.ahb_tx_drv_cb.ahb_tx_hwdata <= 32'h0;
    vif.ahb_tx_drv_cb.ahb_tx_hsize  <= 3'b010;

    @(posedge vif.rst_n);
    @(posedge vif.clk);

    forever begin
      ahb_tx_seq_item item;
      seq_item_port.get_next_item(item);
      drive_ahb_write(item);
      seq_item_port.item_done();
    end
  endtask

  virtual task drive_ahb_write(ahb_tx_seq_item item);
    // Optional delay
    repeat (item.delay) @(posedge vif.clk);

    // Address phase: drive NONSEQ write
    @(posedge vif.clk);
    vif.ahb_tx_drv_cb.ahb_tx_hsel   <= 1'b1;
    vif.ahb_tx_drv_cb.ahb_tx_htrans <= 2'b10;  // NONSEQ
    vif.ahb_tx_drv_cb.ahb_tx_hwrite <= 1'b1;
    vif.ahb_tx_drv_cb.ahb_tx_haddr  <= item.addr[13:0];
    vif.ahb_tx_drv_cb.ahb_tx_hsize  <= item.hsize;

    // Wait for hreadyout (address phase accepted)
    @(posedge vif.clk);
    while (!vif.ahb_tx_drv_cb.ahb_tx_hreadyout) begin
      @(posedge vif.clk);
    end

    // Data phase: drive write data, deassert address phase
    vif.ahb_tx_drv_cb.ahb_tx_hsel   <= 1'b0;
    vif.ahb_tx_drv_cb.ahb_tx_htrans <= 2'b00;  // IDLE
    vif.ahb_tx_drv_cb.ahb_tx_hwrite <= 1'b0;
    vif.ahb_tx_drv_cb.ahb_tx_hwdata <= item.data;

    // Wait for data phase to complete
    @(posedge vif.clk);
    while (!vif.ahb_tx_drv_cb.ahb_tx_hreadyout) begin
      @(posedge vif.clk);
    end

    `uvm_info("AHB_TX_DRV", $sformatf("Drove TX write: addr=0x%04h data=0x%08h",
      item.addr[13:0], item.data), UVM_HIGH)
  endtask

endclass

`endif // GUARD_AHB_TX_DRIVER_SV
