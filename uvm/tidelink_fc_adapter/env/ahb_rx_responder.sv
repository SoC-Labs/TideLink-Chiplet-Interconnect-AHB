///////////////////////////////////////////////////////////////////////////////
// ahb_rx_responder.sv
///////////////////////////////////////////////////////////////////////////////
// Passive AHB slave responder for the DUT's RX master ports.
// Simply drives hready=1 and hresp=0 (OKAY) so the DUT's AHB masters
// can complete their write transactions. Captures observed writes into
// an analysis port for the scoreboard.
//
// Parameterised by ADDR_W to handle both FIFO (14-bit) and config (12-bit)
// address widths.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_RX_RESPONDER_SV
`define GUARD_AHB_RX_RESPONDER_SV

// Sequence item for observed RX AHB writes
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
// RX FIFO AHB Slave Responder
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
    // Always ready, no error
    vif.fc_rx_fifo_hready <= 1'b1;
    vif.fc_rx_fifo_hresp  <= 1'b0;
    vif.fc_rx_fifo_hrdata <= 32'h0;

    @(posedge vif.rst_n);

    forever begin
      @(posedge vif.clk);

      // Detect address phase (NONSEQ write)
      if (vif.fc_rx_fifo_htrans == 2'b10 && vif.fc_rx_fifo_hwrite) begin
        bit [13:0] captured_addr;
        captured_addr = vif.fc_rx_fifo_haddr;

        // Wait for data phase
        @(posedge vif.clk);
        while (!vif.fc_rx_fifo_hready)
          @(posedge vif.clk);

        begin
          ahb_rx_observed_item item;
          item = ahb_rx_observed_item::type_id::create("rx_fifo_obs");
          item.addr    = captured_addr;
          item.data    = vif.fc_rx_fifo_hwdata;
          item.is_fifo = 1'b1;
          ap.write(item);

          `uvm_info("RX_FIFO_RESP", $sformatf("Observed FIFO write: addr=0x%04h data=0x%08h",
            item.addr, item.data), UVM_MEDIUM)
        end
      end
    end
  endtask

endclass

// ---------------------------------------------------------------
// RX Config AHB Slave Responder
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
    // Always ready, no error
    vif.fc_rx_cfg_hready <= 1'b1;
    vif.fc_rx_cfg_hresp  <= 1'b0;
    vif.fc_rx_cfg_hrdata <= 32'h0;

    @(posedge vif.rst_n);

    forever begin
      @(posedge vif.clk);

      // Detect address phase (NONSEQ write)
      if (vif.fc_rx_cfg_htrans == 2'b10 && vif.fc_rx_cfg_hwrite) begin
        bit [11:0] captured_addr;
        captured_addr = vif.fc_rx_cfg_haddr;

        // Wait for data phase
        @(posedge vif.clk);
        while (!vif.fc_rx_cfg_hready)
          @(posedge vif.clk);

        begin
          ahb_rx_observed_item item;
          item = ahb_rx_observed_item::type_id::create("rx_cfg_obs");
          item.addr    = {2'b00, captured_addr};
          item.data    = vif.fc_rx_cfg_hwdata;
          item.is_fifo = 1'b0;
          ap.write(item);

          `uvm_info("RX_CFG_RESP", $sformatf("Observed CFG write: addr=0x%03h data=0x%08h",
            item.addr, item.data), UVM_MEDIUM)
        end
      end
    end
  endtask

endclass

`endif // GUARD_AHB_RX_RESPONDER_SV
