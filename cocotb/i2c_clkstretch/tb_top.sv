// Cocotb TB for SHORTCOMINGS-14a multi-byte I2C wedge reproduction.
//
// Wires the real i2c_master_axil + i2c_slave_axil_master cores together over
// a modelled open-drain (wired-AND) I2C bus, exactly as uvm/.../tb/top.sv
// does for the two chiplets. The slave-side SCL contribution to the bus is
// muxed at runtime to mirror axi_chiplet_controller.sv's I2C pin mux:
//
//   SCL_STRETCH_PASS=0 : slave SCL on bus = 1'b1   (the OLD buggy mux —
//                        "slave doesn't drive SCL", clock-stretch discarded)
//   SCL_STRETCH_PASS=1 : slave SCL on bus = slv_scl_t (the FIX — slave's
//                        open-drain clock-stretch reaches the shared bus)
//
// The slave-side AXIL master drives a tiny memory whose write/read response
// is delayed by APB_WAIT clk cycles, modelling the Wlink-APB-mux latency
// that makes clock-stretch necessary for multi-byte transfers (the autoneg
// FSM's MASK_RES_TX / MASK_RD_ADDR->MASK_RD_DATA transaction shapes).
//
// Re-derived on the de44db6 lineage for SHORTCOMINGS-14a (clock-stretch).
// A joint work commissioned on behalf of SoC Labs.

`timescale 1ns/1ps

module tb_top #(
    parameter SCL_STRETCH_PASS = 1,
    parameter APB_WAIT         = 400  // clk cycles of write/read latency.
                                      // Must exceed one full I2C byte+ACK
                                      // window (~9 bits * 4*PRESCALE =
                                      // ~144 clk @ PRESCALE=4) so that a
                                      // mid-transaction word write keeps
                                      // the bridge in STATE_WRITE_2 past
                                      // the next inbound I2C byte, forcing
                                      // the slave core to clock-stretch.
)(
    input  logic        clk,
    input  logic        rst,

    // I2C master AXIL slave port (driven by cocotb)
    input  logic [3:0]  m_axil_awaddr,
    input  logic        m_axil_awvalid,
    output logic        m_axil_awready,
    input  logic [31:0] m_axil_wdata,
    input  logic [3:0]  m_axil_wstrb,
    input  logic        m_axil_wvalid,
    output logic        m_axil_wready,
    output logic [1:0]  m_axil_bresp,
    output logic        m_axil_bvalid,
    input  logic        m_axil_bready,
    input  logic [3:0]  m_axil_araddr,
    input  logic        m_axil_arvalid,
    output logic        m_axil_arready,
    output logic [31:0] m_axil_rdata,
    output logic [1:0]  m_axil_rresp,
    output logic        m_axil_rvalid,
    input  logic        m_axil_rready,

    // Observability
    output logic        i2c_scl,
    output logic        i2c_sda,
    output logic        slv_scl_stretching,   // slave pulling SCL low
    output logic [7:0]  mem_dbg_0,
    output logic [7:0]  mem_dbg_1,
    output logic [7:0]  mem_dbg_2,
    output logic [7:0]  mem_dbg_3,
    // Slave-side AXIL ground-truth observables (set by the real bridge,
    // independent of the cocotb I2C-read driver)
    output logic [31:0] slv_first_wdata,      // first word the bridge wrote
    output logic [31:0] slv_last_wdata,       // last word the bridge wrote
    output logic [7:0]  slv_wr_count,         // # of AXIL writes issued
    output logic [31:0] slv_last_rdata,       // last word the bridge read
    output logic [7:0]  slv_rd_count,         // # of AXIL reads issued
    output logic        slv_ever_stretched    // slave pulled SCL low at all
);

    // ── I2C master core ─────────────────────────────────────────────────
    wire mst_scl_o, mst_scl_t, mst_sda_o, mst_sda_t;

    i2c_master_axil u_mst (
        .clk            (clk),
        .rst            (rst),
        .s_axil_awaddr  (m_axil_awaddr),
        .s_axil_awprot  (3'b000),
        .s_axil_awvalid (m_axil_awvalid),
        .s_axil_awready (m_axil_awready),
        .s_axil_wdata   (m_axil_wdata),
        .s_axil_wstrb   (m_axil_wstrb),
        .s_axil_wvalid  (m_axil_wvalid),
        .s_axil_wready  (m_axil_wready),
        .s_axil_bresp   (m_axil_bresp),
        .s_axil_bvalid  (m_axil_bvalid),
        .s_axil_bready  (m_axil_bready),
        .s_axil_araddr  (m_axil_araddr),
        .s_axil_arprot  (3'b000),
        .s_axil_arvalid (m_axil_arvalid),
        .s_axil_arready (m_axil_arready),
        .s_axil_rdata   (m_axil_rdata),
        .s_axil_rresp   (m_axil_rresp),
        .s_axil_rvalid  (m_axil_rvalid),
        .s_axil_rready  (m_axil_rready),
        .nBSY_IRQ       (),
        .nRD_EMPTY_IRQ  (),
        .i2c_scl_i      (i2c_scl),
        .i2c_scl_o      (mst_scl_o),
        .i2c_scl_t      (mst_scl_t),
        .i2c_sda_i      (i2c_sda),
        .i2c_sda_o      (mst_sda_o),
        .i2c_sda_t      (mst_sda_t)
    );

    // ── I2C slave core + AXIL master ────────────────────────────────────
    wire        slv_scl_o, slv_scl_t, slv_sda_o, slv_sda_t;
    wire [12:0] s_awaddr;  wire s_awvalid;  reg  s_awready;
    wire [31:0] s_wdata;   wire [3:0] s_wstrb; wire s_wvalid; reg s_wready;
    reg  [1:0]  s_bresp;   reg  s_bvalid;     wire s_bready;
    wire [12:0] s_araddr;  wire s_arvalid;    reg  s_arready;
    reg  [31:0] s_rdata;   reg  [1:0] s_rresp; reg s_rvalid; wire s_rready;

    i2c_slave_axil_master #(
        .ADDR_WIDTH (13)
    ) u_slv (
        .clk            (clk),
        .rst            (rst),
        .i2c_scl_i      (i2c_scl),
        .i2c_scl_o      (slv_scl_o),
        .i2c_scl_t      (slv_scl_t),
        .i2c_sda_i      (i2c_sda),
        .i2c_sda_o      (slv_sda_o),
        .i2c_sda_t      (slv_sda_t),
        .m_axil_awaddr  (s_awaddr),
        .m_axil_awprot  (),
        .m_axil_awvalid (s_awvalid),
        .m_axil_awready (s_awready),
        .m_axil_wdata   (s_wdata),
        .m_axil_wstrb   (s_wstrb),
        .m_axil_wvalid  (s_wvalid),
        .m_axil_wready  (s_wready),
        .m_axil_bresp   (s_bresp),
        .m_axil_bvalid  (s_bvalid),
        .m_axil_bready  (s_bready),
        .m_axil_araddr  (s_araddr),
        .m_axil_arprot  (),
        .m_axil_arvalid (s_arvalid),
        .m_axil_arready (s_arready),
        .m_axil_rdata   (s_rdata),
        .m_axil_rresp   (s_rresp),
        .m_axil_rvalid  (s_rvalid),
        .m_axil_rready  (s_rready),
        .busy           (),
        .bus_addressed  (),
        .bus_active     (),
        .enable         (1'b1),
        .device_address (7'h7E)
    );

    // ── Open-drain wired-AND bus (mirrors uvm tb/top.sv) ────────────────
    // The master is always the I2C master here; the slave path's SCL
    // contribution is selected at runtime via +SCL_STRETCH_PASS=<0|1>
    // (plusarg, default = parameter). This is the exact decision made by
    // axi_chiplet_controller.sv's I2C pin mux for a board in slave role.
    integer scl_stretch_pass_arg;
    initial begin
        scl_stretch_pass_arg = SCL_STRETCH_PASS;
        void'($value$plusargs("SCL_STRETCH_PASS=%d", scl_stretch_pass_arg));
        $display("[tb_top] SCL_STRETCH_PASS = %0d (%s mux)",
                 scl_stretch_pass_arg,
                 (scl_stretch_pass_arg != 0) ? "FIXED" : "OLD-BUGGY");
    end
    wire slv_scl_bus_t = (scl_stretch_pass_arg != 0) ? slv_scl_t : 1'b1;

    assign i2c_scl = (mst_scl_t     ? 1'b1 : mst_scl_o) &
                     (slv_scl_bus_t ? 1'b1 : slv_scl_o);
    assign i2c_sda = (mst_sda_t ? 1'b1 : mst_sda_o) &
                     (slv_sda_t ? 1'b1 : slv_sda_o);

    assign slv_scl_stretching = !slv_scl_t && !slv_scl_o;

    // ── Latency-injecting AXIL slave target ─────────────────────────────
    // Byte-addressable memory. AW and W are latched independently (the
    // i2c_slave_axil_master bridge asserts them together but spec-correct
    // handling keeps the model robust). Every write and read incurs
    // APB_WAIT clk cycles of latency before B/R, modelling the Wlink-APB
    // mux round-trip that makes the slave's clock-stretch necessary on
    // each multi-byte payload byte.
    localparam MEM_BYTES = 64;
    reg [7:0]  mem [0:MEM_BYTES-1];
    integer    i;

    assign mem_dbg_0 = mem[0];
    assign mem_dbg_1 = mem[1];
    assign mem_dbg_2 = mem[2];
    assign mem_dbg_3 = mem[3];

    reg        aw_seen, w_seen;
    reg [12:0] aw_addr_q;
    reg [31:0] w_data_q;
    reg [3:0]  w_strb_q;
    reg [15:0] wr_cnt;
    reg        wr_busy;

    reg [12:0] ar_addr_q;
    reg [15:0] rd_cnt;
    reg        rd_busy;

    // Combinational ready: accept AW/W when not already mid-write
    always @(*) begin
        s_awready = s_awvalid && !aw_seen && !wr_busy;
        s_wready  = s_wvalid  && !w_seen  && !wr_busy;
        s_arready = s_arvalid && !rd_busy && !s_rvalid;
    end

    always @(posedge clk) begin
        if (rst) begin
            aw_seen <= 1'b0; w_seen <= 1'b0; wr_busy <= 1'b0;
            rd_busy <= 1'b0;
            s_bvalid <= 1'b0; s_bresp <= 2'b00;
            s_rvalid <= 1'b0; s_rresp <= 2'b00; s_rdata <= 32'd0;
            wr_cnt <= 16'd0; rd_cnt <= 16'd0;
            for (i = 0; i < MEM_BYTES; i = i + 1) mem[i] <= 8'd0;
        end else begin
            // Latch AW / W
            if (s_awvalid && s_awready) begin
                aw_addr_q <= s_awaddr;
                aw_seen   <= 1'b1;
            end
            if (s_wvalid && s_wready) begin
                w_data_q <= s_wdata;
                w_strb_q <= s_wstrb;
                w_seen   <= 1'b1;
            end

            // Start a write once both AW and W are in
            if (!wr_busy && (aw_seen || (s_awvalid && s_awready)) &&
                            (w_seen  || (s_wvalid  && s_wready))) begin
                wr_busy <= 1'b1;
                wr_cnt  <= APB_WAIT[15:0];
            end

            if (wr_busy) begin
                if (wr_cnt != 0) begin
                    wr_cnt <= wr_cnt - 1'b1;
                end else begin
                    if (w_strb_q[0]) mem[aw_addr_q[5:0]+0] <= w_data_q[7:0];
                    if (w_strb_q[1]) mem[aw_addr_q[5:0]+1] <= w_data_q[15:8];
                    if (w_strb_q[2]) mem[aw_addr_q[5:0]+2] <= w_data_q[23:16];
                    if (w_strb_q[3]) mem[aw_addr_q[5:0]+3] <= w_data_q[31:24];
                    s_bvalid <= 1'b1;
                    s_bresp  <= 2'b00;
                    wr_busy  <= 1'b0;
                    aw_seen  <= 1'b0;
                    w_seen   <= 1'b0;
                end
            end
            if (s_bvalid && s_bready) s_bvalid <= 1'b0;

            // Reads
            if (!rd_busy && s_arvalid && s_arready) begin
                ar_addr_q <= s_araddr;
                rd_busy   <= 1'b1;
                rd_cnt    <= APB_WAIT[15:0];
            end
            if (rd_busy) begin
                if (rd_cnt != 0) begin
                    rd_cnt <= rd_cnt - 1'b1;
                end else begin
                    s_rdata  <= {mem[ar_addr_q[5:0]+3], mem[ar_addr_q[5:0]+2],
                                 mem[ar_addr_q[5:0]+1], mem[ar_addr_q[5:0]+0]};
                    s_rvalid <= 1'b1;
                    s_rresp  <= 2'b00;
                    rd_busy  <= 1'b0;
                end
            end
            if (s_rvalid && s_rready) s_rvalid <= 1'b0;
        end
    end

    // ── Slave-AXIL ground-truth capture ─────────────────────────────────
    always @(posedge clk) begin
        if (rst) begin
            slv_first_wdata    <= 32'd0;
            slv_last_wdata     <= 32'd0;
            slv_wr_count       <= 8'd0;
            slv_last_rdata     <= 32'd0;
            slv_rd_count       <= 8'd0;
            slv_ever_stretched <= 1'b0;
        end else begin
            if (s_wvalid && s_wready) begin
                if (slv_wr_count == 8'd0)
                    slv_first_wdata <= s_wdata;
                slv_last_wdata <= s_wdata;
                slv_wr_count   <= slv_wr_count + 1'b1;
            end
            if (s_rvalid && s_rready) begin
                slv_last_rdata <= s_rdata;
                slv_rd_count   <= slv_rd_count + 1'b1;
            end
            if (slv_scl_stretching)
                slv_ever_stretched <= 1'b1;
        end
    end

    // ── Slave-AXIL trace (debug) ────────────────────────────────────────
`ifdef TRACE_AXIL
    always @(posedge clk) begin
        if (!rst) begin
            if (s_awvalid && s_awready)
                $display("[%0t] SLV-AXIL AW addr=%0h", $time, s_awaddr);
            if (s_wvalid && s_wready)
                $display("[%0t] SLV-AXIL W  data=%08h strb=%b", $time,
                         s_wdata, s_wstrb);
            if (s_bvalid && s_bready)
                $display("[%0t] SLV-AXIL B  resp=%0d", $time, s_bresp);
            if (s_arvalid && s_arready)
                $display("[%0t] SLV-AXIL AR addr=%0h", $time, s_araddr);
            if (s_rvalid && s_rready)
                $display("[%0t] SLV-AXIL R  data=%08h", $time, s_rdata);
        end
    end
`endif

endmodule
