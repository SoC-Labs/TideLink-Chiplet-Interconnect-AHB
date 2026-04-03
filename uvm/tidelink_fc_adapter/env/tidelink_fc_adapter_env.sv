///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_env.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM environment for TideLink FC Adapter verification.
//
// Contains:
//   - AHB TX aperture master agent (drives writes to DUT's TX aperture)
//   - Returner master agent (drives writes to DUT's returner interception)
//   - AHB RX FIFO slave responder (responds to DUT's FIFO AHB master)
//   - AHB RX Config slave responder (responds to DUT's config AHB master)
//   - FC agent (drives FC RX l2a, monitors FC TX a2l)
//   - FC TX ready driver (controls a2l_ready backpressure)
//   - Scoreboard
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_ENV_SV
`define GUARD_TIDELINK_FC_ADAPTER_ENV_SV

class tidelink_fc_adapter_env extends uvm_env;

  `uvm_component_utils(tidelink_fc_adapter_env)

  // Components
  ahb_tx_agent                    tx_agt;           // AHB master for TX aperture
  rtn_agent                       rtn_agt;          // AHB master for returner port
  ahb_rx_fifo_responder           rx_fifo_resp;     // AHB slave for RX FIFO path
  ahb_rx_cfg_responder            rx_cfg_resp;      // AHB slave for RX config path
  fc_agent                        fc_agt;           // FC RX driver + FC TX monitor
  fc_tx_ready_driver              fc_tx_rdy;        // FC a2l_ready backpressure
  tidelink_fc_adapter_scoreboard  sb;

  function new(string name = "tidelink_fc_adapter_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building tidelink_fc_adapter_env...", UVM_LOW)

    // Create agents and responders
    tx_agt       = ahb_tx_agent::type_id::create("tx_agt", this);
    rtn_agt      = rtn_agent::type_id::create("rtn_agt", this);
    rx_fifo_resp = ahb_rx_fifo_responder::type_id::create("rx_fifo_resp", this);
    rx_cfg_resp  = ahb_rx_cfg_responder::type_id::create("rx_cfg_resp", this);
    fc_agt       = fc_agent::type_id::create("fc_agt", this);
    fc_tx_rdy    = fc_tx_ready_driver::type_id::create("fc_tx_rdy", this);
    sb           = tidelink_fc_adapter_scoreboard::type_id::create("sb", this);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // FC TX monitor -> scoreboard
    fc_agt.ap.connect(sb.fc_tx_export);

    // RX FIFO responder -> scoreboard
    rx_fifo_resp.ap.connect(sb.rx_fifo_export);

    // RX Config responder -> scoreboard
    rx_cfg_resp.ap.connect(sb.rx_cfg_export);
  endfunction

endclass

`endif // GUARD_TIDELINK_FC_ADAPTER_ENV_SV
