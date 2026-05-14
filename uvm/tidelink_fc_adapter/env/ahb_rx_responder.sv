///////////////////////////////////////////////////////////////////////////////
// ahb_rx_responder.sv
///////////////////////////////////////////////////////////////////////////////
// Passive responders for the DUT's RX master ports. The DUT moved off AHB:
//   - RX FIFO path is now a direct valid/write/addr/wdata interface
//   - RX Config path is now an APB-style master
// File name retained for backwards-compat with includes; classes wrap each
// protocol with an analysis port to feed the existing scoreboard.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_RX_RESPONDER_SV
`define GUARD_AHB_RX_RESPONDER_SV

// Sequence item for observed RX writes (FIFO valid/write or APB)
class ahb_rx_observed_item extends uvm_sequence_item;

  bit [13:0] addr;
  bit [31:0] data;
  bit        is_fifo;   // 1 = FIFO path, 0 = config path

  `uvm_object_utils_begin(ahb_rx_observed_item)
    `uvm_field_int(addr,    UVM_ALL_ON)
    `uvm_field_int(data,    UVM_ALL_ON)
    `uvm_field_int(is_fifo, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "ahb_rx_observed_item");
    super.new(name);
  endfunction

endclass

// ---------------------------------------------------------------
// RX FIFO Direct-Write Responder
// Drives fc_rx_fifo_ready high; captures (addr, wdata) on every
// accepted (valid && write && ready) cycle.
// ---------------------------------------------------------------
class ahb_rx_fifo_responder extends uvm_component;

  `uvm_component_utils(ahb_rx_fifo_responder)

  virtual tidelink_fc_adapter_if vif;
  uvm_analysis_port #(ahb_rx_observed_item) ap;

  function new(string name = "ahb_rx_fifo_responder", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual tidelink_fc_adapter_if)::get(this, "", "dut_vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not found for ahb_rx_fifo_responder")
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.fc_rx_fifo_ready <= 1'b1;

    @(posedge vif.rst_n);

    forever begin
      @(posedge vif.clk);

      if (vif.fc_rx_fifo_valid && vif.fc_rx_fifo_write && vif.fc_rx_fifo_ready) begin
        ahb_rx_observed_item item;
        item = ahb_rx_observed_item::type_id::create("rx_fifo_obs");
        item.addr    = vif.fc_rx_fifo_addr;
        item.data    = vif.fc_rx_fifo_wdata;
        item.is_fifo = 1'b1;
        ap.write(item);

        `uvm_info("RX_FIFO_RESP", $sformatf("Observed FIFO write: addr=0x%04h data=0x%08h",
          item.addr, item.data), UVM_MEDIUM)
      end
    end
  endtask

endclass

// ---------------------------------------------------------------
// RX Config APB Responder
// Drives PREADY high during the access (PENABLE) phase and zero PRDATA;
// captures (PADDR, PWDATA) at the end of every write access.
// ---------------------------------------------------------------
class ahb_rx_cfg_responder extends uvm_component;

  `uvm_component_utils(ahb_rx_cfg_responder)

  virtual tidelink_fc_adapter_if vif;
  uvm_analysis_port #(ahb_rx_observed_item) ap;

  function new(string name = "ahb_rx_cfg_responder", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual tidelink_fc_adapter_if)::get(this, "", "dut_vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not found for ahb_rx_cfg_responder")
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.fc_rx_cfg_pready <= 1'b1;
    vif.fc_rx_cfg_prdata <= 32'h0;

    @(posedge vif.rst_n);

    forever begin
      @(posedge vif.clk);

      // Capture on the access phase (PSEL && PENABLE && PREADY) for writes.
      if (vif.fc_rx_cfg_psel && vif.fc_rx_cfg_penable && vif.fc_rx_cfg_pready
          && vif.fc_rx_cfg_pwrite) begin
        ahb_rx_observed_item item;
        item = ahb_rx_observed_item::type_id::create("rx_cfg_obs");
        item.addr    = {2'b00, vif.fc_rx_cfg_paddr};
        item.data    = vif.fc_rx_cfg_pwdata;
        item.is_fifo = 1'b0;
        ap.write(item);

        `uvm_info("RX_CFG_RESP", $sformatf("Observed CFG write: addr=0x%03h data=0x%08h",
          item.addr, item.data), UVM_MEDIUM)
      end
    end
  endtask

endclass

`endif // GUARD_AHB_RX_RESPONDER_SV
