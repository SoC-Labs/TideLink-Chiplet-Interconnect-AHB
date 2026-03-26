module tidelink_fifo #(
    parameter RAM_ADDR_W  = 16
)(
    input  wire                  hclk,      // system bus clock
    input  wire                  hresetn,   // system bus reset
    input  wire                  hsel,      // AHB peripheral select
    input  wire                  hready,    // AHB ready input
    input  wire    [1:0]         htrans,    // AHB transfer type
    input  wire    [2:0]         hsize,     // AHB hsize
    input  wire                  hwrite,    // AHB hwrite
    input  wire [RAM_ADDR_W-1:0] haddr,     // AHB address bus
    input  wire           [31:0] hwdata,    // AHB write data bus
    output wire                  hreadyout, // AHB ready output to S->M mux
    output wire                  hresp,     // AHB response
    output wire           [31:0] hrdata,    // AHB read data bus

    input  wire           [31:0] sramrdata, // SRAM Read Data
    output wire [RAM_ADDR_W-3:0] sramaddr,  // SRAM address
    output wire            [3:0] sramwen,   // SRAM write enable (active high)
    output wire           [31:0] sramwdata, // SRAM write data
    output wire                  sramcs     // SRAM chip select (active high)
);

   // ----------------------------------------------------------
   // Internal state
   // ----------------------------------------------------------
   reg  [(RAM_ADDR_W-3):0]   buf_addr;        // Write address buffer
   reg  [ 3:0]               buf_we;          // Write enable buffer (data phase)
   reg                       buf_hit;         // High when AHB read address
                                              // matches buffered address
   reg  [31:0]               buf_data;        // AHB write bus buffered
   reg                       buf_pend;        // Buffer write data valid
   reg                       buf_data_en;     // Data buffer write enable (data phase)

   // ----------------------------------------------------------
   // Read/write control logic
   // ----------------------------------------------------------

   wire        ahb_access   = htrans[1] & hsel & hready;
   wire        ahb_write    = ahb_access &  hwrite;
   wire        ahb_read     = ahb_access & (~hwrite);

   // Stored write data in pending state if new transfer is read
   //   buf_data_en indicate new write (data phase)
   //   ahb_read    indicate new read  (address phase)
   //   buf_pend    is registered version of buf_pend_nxt
   wire        buf_pend_nxt = (buf_pend | buf_data_en) & ahb_read;

   // RAM write happens when
   // - write pending (buf_pend), or
   // - new AHB write seen (buf_data_en) at data phase,
   // - and not reading (address phase)
   wire        ram_write    = (buf_pend | buf_data_en)  & (~ahb_read); // ahb_write

   // RAM WE is the buffered WE
   assign      sramwen  = {4{ram_write}} & buf_we[3:0];

   // RAM address is the buffered address for RAM write otherwise haddr
   assign      sramaddr = ahb_read ? haddr[RAM_ADDR_W-1:2] : buf_addr;

   // RAM chip select during read or write
   assign      sramcs   = ahb_read | ram_write;

   // ----------------------------------------------------------
   // Byte lane decoder and next state logic
   // ----------------------------------------------------------

   wire       tx_byte    = (~hsize[1]) & (~hsize[0]);
   wire       tx_half    = (~hsize[1]) &  hsize[0];
   wire       tx_word    =   hsize[1];

   wire       byte_at_00 = tx_byte & (~haddr[1]) & (~haddr[0]);
   wire       byte_at_01 = tx_byte & (~haddr[1]) &   haddr[0];
   wire       byte_at_10 = tx_byte &   haddr[1]  & (~haddr[0]);
   wire       byte_at_11 = tx_byte &   haddr[1]  &   haddr[0];

   wire       half_at_00 = tx_half & (~haddr[1]);
   wire       half_at_10 = tx_half &   haddr[1];

   wire       word_at_00 = tx_word;

   wire       byte_sel_0 = word_at_00 | half_at_00 | byte_at_00;
   wire       byte_sel_1 = word_at_00 | half_at_00 | byte_at_01;
   wire       byte_sel_2 = word_at_00 | half_at_10 | byte_at_10;
   wire       byte_sel_3 = word_at_00 | half_at_10 | byte_at_11;

   // Address phase byte lane strobe
   wire [3:0] buf_we_nxt = { byte_sel_3 & ahb_write,
                             byte_sel_2 & ahb_write,
                             byte_sel_1 & ahb_write,
                             byte_sel_0 & ahb_write };

   // ----------------------------------------------------------
   // Write buffer
   // ----------------------------------------------------------

   // buf_data_en is data phase write control
   always @(posedge hclk or negedge hresetn)
     if (~hresetn)
       buf_data_en <= 1'b0;
     else
       buf_data_en <= ahb_write;

   always @(posedge hclk)
     if(buf_we[3] & buf_data_en)
       buf_data[31:24] <= hwdata[31:24];

   always @(posedge hclk)
     if(buf_we[2] & buf_data_en)
       buf_data[23:16] <= hwdata[23:16];

   always @(posedge hclk)
     if(buf_we[1] & buf_data_en)
       buf_data[15: 8] <= hwdata[15: 8];

   always @(posedge hclk)
     if(buf_we[0] & buf_data_en)
       buf_data[ 7: 0] <= hwdata[ 7: 0];

   // buf_we keep the valid status of each byte (data phase)
   always @(posedge hclk or negedge hresetn)
     if (~hresetn)
       buf_we <= 4'b0000;
     else if(ahb_write)
       buf_we <= buf_we_nxt;

   always @(posedge hclk or negedge hresetn)
     begin
     if (~hresetn)
       buf_addr <= {(RAM_ADDR_W-2){1'b0}};
     else if (ahb_write)
         buf_addr <= haddr[(RAM_ADDR_W-1):2];
     end
   // ----------------------------------------------------------
   // Buf_hit detection logic
   // ----------------------------------------------------------

   wire  buf_hit_nxt = (haddr[RAM_ADDR_W-1:2] == buf_addr[RAM_ADDR_W-3:0]);

   // ----------------------------------------------------------
   // Read data merge : This is for the case when there is a AHB
   // write followed by AHB read to the same address. In this case
   // the data is merged from the buffer as the RAM write to that
   // address hasn't happened yet
   // ----------------------------------------------------------

   wire [ 3:0] merge1  = {4{buf_hit}} & buf_we; // data phase, buf_we indicates data is valid

   assign hrdata =
              { merge1[3] ? buf_data[31:24] : sramrdata[31:24],
                merge1[2] ? buf_data[23:16] : sramrdata[23:16],
                merge1[1] ? buf_data[15: 8] : sramrdata[15: 8],
                merge1[0] ? buf_data[ 7: 0] : sramrdata[ 7: 0] };

   // ----------------------------------------------------------
   // Synchronous state update
   // ----------------------------------------------------------

   always @(posedge hclk or negedge hresetn)
     if (~hresetn)
       buf_hit <= 1'b0;
     else if(ahb_read)
       buf_hit <= buf_hit_nxt;

   always @(posedge hclk or negedge hresetn)
     if (~hresetn)
       buf_pend <= 1'b0;
     else
       buf_pend <= buf_pend_nxt;

   // if there is an AHB write and valid data in the buffer, RAM write data
   // comes from the buffer. otherwise comes from the hwdata
   assign sramwdata = (buf_pend) ? buf_data : hwdata[31:0];

   // ----------------------------------------------------------
   // Assign outputs
   // ----------------------------------------------------------
   assign hreadyout = 1'b1;
   assign hresp     = 1'b0;
   
endmodule