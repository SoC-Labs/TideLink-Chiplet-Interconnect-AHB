//-----------------------------------------------------------------------------
// SoCLabs TideLink Control Counter
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This module accepts commands via an AXI-Stream input interface and drives
// AXI-Stream control and data outputs to the tidelink_sram_manager. Read data
// is returned via an AXI-Stream output interface.
//
// Command word format (first beat of input stream):
//   Bit 31         : 1 = WRITE, 0 = READ
//   Bits [NW-1:0]  : number of 32-bit words (NW = RAM_ADDR_W - 2)
//
// Write transaction: command word, then num_words data beats (tlast on last).
// Read  transaction: command word only (tlast asserted). Read data returned on
//                    the output stream.
//-----------------------------------------------------------------------------
module tidelink_control_counter #(
    parameter RAM_ADDR_W = 14,
    parameter WORD_LEN_W = 8
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // AXI-Stream Input (command + write data)
    input  logic           [31:0] in_tdata,
    input  logic                  in_tvalid,
    output logic                  in_tready,
    input  logic                  in_tlast,

    // AXI-Stream Output (read data)
    output logic           [31:0] out_tdata,
    output logic                  out_tvalid,
    input  logic                  out_tready,
    output logic                  out_tlast,

    // AXI-Stream Control Out (to sram_manager ctrl port)
    output logic           [22:0] ctrl_tdata,
    output logic                  ctrl_tvalid,
    input  logic                  ctrl_tready,

    // AXI-Stream Data Out (to sram_manager din port)
    output logic           [31:0] dout_tdata,
    output logic                  dout_tvalid,
    output logic                  dout_tlast,
    input  logic                  dout_tready,

    // AXI-Stream Data In (from sram_manager dout port)
    input  logic           [31:0] din_tdata,
    input  logic                  din_tvalid,
    input  logic                  din_tlast,
    output logic                  din_tready
);
    localparam NUM_WORDS_WIDTH = RAM_ADDR_W - 2;

    //-------------------------------------------
    // State Machine
    //-------------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        SEND_CTRL,
        WRITING,
        SEND_READ_CTRL,
        READING
    } control_state_t;

    control_state_t state, state_next;

    // Captured command fields
    logic                        cmd_rw,      cmd_rw_next;      // 1=write, 0=read
    logic [NUM_WORDS_WIDTH-1:0]  cmd_nwords,  cmd_nwords_next;

    // Word counter for write data forwarding and read data output
    logic [NUM_WORDS_WIDTH-1:0]  word_cnt,    word_cnt_next;

    // Read and write pointers in the SRAM
    logic [RAM_ADDR_W-1:0] write_pointer, write_pointer_next;
    logic [RAM_ADDR_W-1:0] read_pointer,  read_pointer_next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            cmd_rw        <= 1'b0;
            cmd_nwords    <= '0;
            word_cnt      <= '0;
            write_pointer <= '0;
            read_pointer  <= '0;
        end else begin
            state         <= state_next;
            cmd_rw        <= cmd_rw_next;
            cmd_nwords    <= cmd_nwords_next;
            word_cnt      <= word_cnt_next;
            write_pointer <= write_pointer_next;
            read_pointer  <= read_pointer_next;
        end
    end

    //-------------------------------------------
    // Control command structure
    //-------------------------------------------
    typedef enum logic {
        READ  = 1'b0,
        WRITE = 1'b1
    } operation_t;

    typedef struct packed {
        operation_t                  read_write;
        logic       [RAM_ADDR_W-1:0] addr;
        logic       [WORD_LEN_W-1:0] length;
    } ctrl_command_t;

    ctrl_command_t ctrl_command;
    assign ctrl_tdata = ctrl_command;

    //-------------------------------------------
    // Combinational next-state and output logic
    //-------------------------------------------
    always_comb begin
        // Defaults: hold registers
        state_next         = state;
        cmd_rw_next        = cmd_rw;
        cmd_nwords_next    = cmd_nwords;
        word_cnt_next      = word_cnt;
        write_pointer_next = write_pointer;
        read_pointer_next  = read_pointer;

        // AXI-Stream input defaults
        in_tready = 1'b0;

        // AXI-Stream output defaults
        out_tdata  = 32'h0;
        out_tvalid = 1'b0;
        out_tlast  = 1'b0;

        // Control interface defaults
        ctrl_command = '0;
        ctrl_tvalid  = 1'b0;

        // Data out to sram_manager defaults
        dout_tdata  = 32'h0;
        dout_tvalid = 1'b0;
        dout_tlast  = 1'b0;

        // Data in from sram_manager defaults
        din_tready = 1'b0;

        case (state)
            // -------------------------------------------------------
            IDLE: begin
                // Ready to accept a new command word
                in_tready = 1'b1;
                if (in_tvalid && in_tready) begin
                    cmd_rw_next     = in_tdata[31];
                    cmd_nwords_next = in_tdata[NUM_WORDS_WIDTH-1:0];
                    word_cnt_next   = '0;
                    if (in_tdata[31]) begin
                        // Write command — next: issue ctrl then forward data
                        state_next = SEND_CTRL;
                    end else begin
                        // Read command — next: issue ctrl then collect data
                        state_next = SEND_READ_CTRL;
                    end
                end
            end

            // -------------------------------------------------------
            SEND_CTRL: begin
                // Issue write control command to sram_manager
                ctrl_command.read_write = WRITE;
                ctrl_command.addr       = write_pointer;
                ctrl_command.length     = cmd_nwords[WORD_LEN_W-1:0];
                ctrl_tvalid             = 1'b1;
                if (ctrl_tvalid && ctrl_tready) begin
                    state_next = WRITING;
                end
            end

            // -------------------------------------------------------
            WRITING: begin
                // Forward write data from input stream to sram_manager din
                in_tready   = dout_tready; // back-pressure from sram_manager
                dout_tdata  = in_tdata;
                dout_tvalid = in_tvalid;
                dout_tlast  = in_tlast;
                if (in_tvalid && dout_tready) begin
                    word_cnt_next = word_cnt + 1'b1;
                    if (in_tlast || (word_cnt + 1'b1 == cmd_nwords)) begin
                        // Advance write pointer past the written region
                        write_pointer_next = write_pointer + {cmd_nwords, 2'b00};
                        state_next         = IDLE;
                    end
                end
            end

            // -------------------------------------------------------
            SEND_READ_CTRL: begin
                // Issue read control command to sram_manager
                ctrl_command.read_write = READ;
                ctrl_command.addr       = read_pointer;
                ctrl_command.length     = cmd_nwords[WORD_LEN_W-1:0];
                ctrl_tvalid             = 1'b1;
                if (ctrl_tvalid && ctrl_tready) begin
                    state_next = READING;
                end
            end

            // -------------------------------------------------------
            READING: begin
                // Forward sram_manager dout to output stream
                din_tready = out_tready; // back-pressure from output consumer
                out_tdata  = din_tdata;
                out_tvalid = din_tvalid;
                out_tlast  = din_tlast;
                if (din_tvalid && out_tready) begin
                    word_cnt_next = word_cnt + 1'b1;
                    if (din_tlast || (word_cnt + 1'b1 == cmd_nwords)) begin
                        // Advance read pointer past the read region
                        read_pointer_next = read_pointer + {cmd_nwords, 2'b00};
                        state_next        = IDLE;
                    end
                end
            end

            // -------------------------------------------------------
            default: begin
                state_next = IDLE;
            end
        endcase
    end

endmodule
