//-----------------------------------------------------------------------------
// SoCLabs TideLink SRAM Manager 
// - to be substitued with same name file in filelist when moving to ASIC
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This modudle implements a fifo-based SRAM manager that interfaces with an AXI Stream and manages read/write operations to an SRAM.
// TODO:
// - Error handing (length mismatch, invalid commands, etc.)
//-----------------------------------------------------------------------------
module tidelink_sram_manager #(
    parameter RAM_ADDR_W = 14,
    parameter WORD_LEN_W = 8
)(
    input  logic                  clk,
    input  logic                  rst_n,
    
    // AXI Stream Control In
    input  logic           [22:0] ctrl_tdata,
    input  logic                  ctrl_tvalid,
    output logic                  ctrl_tready,
    
    // AXI Stream Data In
    input  logic           [31:0] din_tdata,
    input  logic                  din_tvalid,
    input  logic                  din_tlast,
    output logic                  din_tready,
    
    // AXI Stream Data Out
    output logic           [31:0] dout_tdata,
    output logic                  dout_tvalid,
    output logic                  dout_tlast,
    input  logic                  dout_tready,
    
    // SRAM Interface
    output logic [RAM_ADDR_W-1:0] sramaddr,
    output logic           [31:0] sramwdata,
    output logic            [3:0] sramwen,
    output logic                  sramcs,
    input  logic           [31:0] sramrdata
);
    //-------------------------------------------
    // Internal types
    //-------------------------------------------
    
    // Type to represent control commands coming in
    typedef enum logic {
        READ,
        WRITE
    } operation_t;
    
    // Type to represent the control command structure
    typedef struct packed {
        operation_t                  read_write; // 1 for write, 0 for read
        logic       [RAM_ADDR_W-1:0] addr;       // Address for the SRAM operation
        logic       [WORD_LEN_W-1:0] length;     // Length of the data transfer (in number of 32-bit words)
    } ctrl_command_t;
    
    // States for the control state machine
    typedef enum logic [1:0] {
        IDLE,
        PROCESSING_DATA_IN,
        PROCESSING_DATA_OUT
    } control_state_t;

    // ------------------------------------------
    // Control Handling
    // ------------------------------------------
    // Wait until the data in or data out streams are complete before accepting new control commands
    logic ctrl_active, ctrl_active_next;
    
    // Register to hold the current command being processed
    ctrl_command_t current_command, current_command_nxt, current_command_reg;
    assign         current_command = ctrl_tdata; // Assuming control data is packed as {read_write, addr, length}
    
    control_state_t control_state, control_state_next;
    
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            // Reset logic
            ctrl_active        <= 1'b0;
            control_state      <= IDLE;
            current_command_reg <= '0;
        end else begin
            // Update state and registers
            ctrl_active         <= ctrl_active_next;
            control_state       <= control_state_next;
            current_command_reg <= current_command_nxt;
        end
    end
    
    always_comb begin : control_state_machine
        // Default Logic
        //----------------------------------
        control_state_next = control_state;
        ctrl_tready = 1'b0;
        current_command_nxt = current_command_reg; // Hold the current command
        
        // Begin State Machine
        // ---------------------------------
        case (control_state)
            IDLE: begin
                ctrl_tready = 1'b1; // Ready to accept control commands
                
                // Seen a handshake on control stream
                if (ctrl_tvalid) begin
                    ctrl_active_next = 1'b1;
                    current_command_nxt = current_command; // Latch the command
                    
                    // Read top bit of the control data to determine if we are reading or writing
                    if (current_command.read_write == WRITE) begin
                        // Write command - wait for data in
                        control_state_next = PROCESSING_DATA_IN;
                    end else begin
                        // Read command - wait for data out
                        control_state_next = PROCESSING_DATA_OUT;
                    end
                end
            end
            
            PROCESSING_DATA_IN: begin
                if (din_tvalid && din_tlast) begin
                    ctrl_active_next = 1'b0;
                    control_state_next = IDLE;
                end
            end
            
            PROCESSING_DATA_OUT: begin
                if (dout_tvalid && dout_tlast) begin
                    ctrl_active_next = 1'b0;
                    control_state_next = IDLE;
                end
            end
            
            default: control_state_next = IDLE;
        endcase
    end
    
    // ------------------------------------------
    // Read/Write Handling
    // ------------------------------------------
    logic [RAM_ADDR_W-1:0] addr, addr_nxt; // Address pointer for read/write operations
    
    // Address handling next logic
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            addr <= '0;
        end else begin
            addr <= addr_nxt;
        end
    end
    
    // Output Data Logic
    logic        rdata_out_valid_nxt;
    logic        rdata_out_last_nxt;
    
    // Transaction Counter
    logic  [WORD_LEN_W-1:0] trans_count, trans_count_nxt;
    
    // Clocking block for output data handling
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            dout_tvalid  <= 1'b0;
            dout_tlast   <= 1'b0;
            trans_count <= '0;
        end else begin
            dout_tvalid  <= rdata_out_valid_nxt;
            dout_tlast   <= rdata_out_last_nxt;
            trans_count  <= trans_count_nxt;
        end
    end
    
    always_comb begin : data_handling
        din_tready = 1'b0;
        
        // Default SRAM control signals
        sramwen   = 4'b0000; // Assuming word writes for simplicity
        sramcs    = 1'b0;    // Deassert chip select when no valid data
        sramwdata = din_tdata; // Write data directly from the input stream (assuming 1:1 mapping for simplicity)
        sramaddr  = addr; // Address pointer for SRAM operations
        addr_nxt  = addr; // Default to hold the current address
        
        // Default output data signals
        // - reduce muxing on data path in default case
        dout_tdata          = sramrdata;
        rdata_out_last_nxt  = dout_tlast;
        rdata_out_valid_nxt = 1'b0;
        
        // Transaction Counter Next
        trans_count_nxt = trans_count; // Default to hold the current transaction length

        case (control_state)
            IDLE: begin
                // set the address
                sramaddr        = current_command.addr;
                trans_count_nxt = current_command.length;
                // If we see a valid control command and its read, we can set the SRAM control signals for a read operation immediately
                if (ctrl_tvalid) begin
                    if (current_command.read_write == READ) begin
                        // Assert chip select for read
                        sramcs    = 1'b1;
                        sramaddr  = current_command.addr; // Set the SRAM address from the control command

                        // Decrement the transaction length for each beat of data read
                        trans_count_nxt = current_command.length - 1;
    
                        // Assert the next valid signal on the data
                        rdata_out_valid_nxt = 1'b1;
                        rdata_out_last_nxt  = (trans_count_nxt == 0); // If length is 0, this is the last beat
                        
                        // Retain current address until we see a handshake on the output stream
                        addr_nxt = current_command.addr;
                    end else begin // Recieved write command, wait for data to arrive on the input stream before setting SRAM control signals
                        // Display the received write command for debugging
                        // Assert ready for data input so we can process the write command as soon as data arrives
                        din_tready = 1'b1;
                        // If Data is valid on the input stream, we can set the SRAM control signals for a write operation immediately and transition to the data processing state
                        if (din_tvalid) begin
                            sramcs    = 1'b1;    // Assert chip select for write
                            sramwen   = 4'b1111; // Assuming word writes for simplicity
                            sramaddr  = current_command.addr; // Set the SRAM address from the control command
                            addr_nxt  = current_command.addr + 4; // Increment by 4 for next word (assuming 32-bit words)
                        end else begin
                            // If data is not valid yet, we can still set the SRAM control signals for a write operation but hold the address until data arrives
                            addr_nxt  = current_command.addr;
                        end
                    end
                end
            end
        
            PROCESSING_DATA_IN: begin
                // Data tready is always high in this state as no backpressure is applied from the SRAM
                din_tready = 1'b1;
                // When a handshake has occured, we can set the SRAM control signals for a write operation
                if (din_tvalid) begin
                    sramcs    = 1'b1;     // Assert chip select for write
                    sramwen   = 4'b1111; // Assuming word writes for simplicity
                    if (~din_tlast) begin
                        addr_nxt  = addr + 4; // Increment by 4 for next word (assuming 32-bit words)
                    end
                end
            end
            
            PROCESSING_DATA_OUT: begin
                // if we see a handshake on the output stream, we can prepare the next beat of data
                sramcs   = 1'b1;
                sramaddr = addr; // Set the SRAM address for the read operation
                if (dout_tready & ~dout_tlast) begin
                    trans_count_nxt     = trans_count - 1; // Decrement the transaction count for each beat of data read
                    rdata_out_valid_nxt = 1'b1;
                    rdata_out_last_nxt  = (trans_count_nxt == 0); // If transaction count is 0, this is the last beat
                    addr_nxt            = addr + 4; // Increment address for next read
                    sramaddr            = addr_nxt; // Set the SRAM address for the read operation
                end

                if (dout_tready & dout_tlast) begin
                    // Deassert chip select on last clock cycle of output
                    sramcs = 1'b0;
                    // Deassert valid on last clock cycle of output
                    rdata_out_valid_nxt = 1'b0;
                end
            end
            
            default: begin
                // Default case to handle any unexpected states
            end
        endcase
        
    end

endmodule
