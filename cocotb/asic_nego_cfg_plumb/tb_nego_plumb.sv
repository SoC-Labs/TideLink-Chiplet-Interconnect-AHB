// PENDING-DECISION #6 — NEGO_CFG_RESET DFT-wrapper plumbing proof.
//
// Instantiates the ASIC DFT wrapper (only hclk connected; every other port left
// dangling — this is an ELABORATION probe, not a functional sim) and prints the
// NEGO_CFG_RESET parameter value as seen AT THE DESTINATION: the inner
// axi_chiplet_controller (u_wrap.u_top.u_chiplet_controller.NEGO_CFG_RESET).
//
// The value is driven from `NCR` at the wrapper boundary. If the wrapper→top→
// controller forwarding is dead (the historical failure mode: plumbed at one
// level, never forwarded, so every build silently took the module default),
// the printed value would stay at the 7'h00 default regardless of NCR.
`ifndef NCR
  `define NCR 7'h00
`endif

module tb_nego_plumb;
    logic hclk = 0;

    tidelink_dft_wrapper #(
        .NEGO_CFG_RESET (`NCR)
    ) u_wrap (
        .hclk (hclk)
        // all other ports intentionally left unconnected (elaboration probe)
    );

    initial begin
        $display("PROOF NEGO_CFG_RESET_at_wrapper   = %0d", 7'(`NCR));
        $display("PROOF NEGO_CFG_RESET_at_controller = %0d",
                 u_wrap.u_top.u_chiplet_controller.NEGO_CFG_RESET);
        $finish;
    end
endmodule
