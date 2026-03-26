// Testbench for tidelink_sram_manager
module tb_tidelink_sram_manager;

    // -----------------------------------------------
    // Parameters
    // -----------------------------------------------
    localparam RAM_ADDR_W  = 14;
    localparam WORD_LEN_W  = 8;
    localparam SRAM_AW     = RAM_ADDR_W - 2; // Word-addressed
    localparam CTRL_W      = 1 + RAM_ADDR_W + WORD_LEN_W;
    localparam CLK_PERIOD  = 10;

    // -----------------------------------------------
    // Signals
    // -----------------------------------------------
    logic                clk;
    logic                rst_n;

    // AXI Stream Control
    logic         [22:0] ctrl_tdata;
    logic                ctrl_tvalid;
    logic                ctrl_tready;

    // AXI Stream Data In
    logic         [31:0] din_tdata;
    logic                din_tvalid;
    logic                din_tlast;
    logic                din_tready;

    // AXI Stream Data Out
    logic         [31:0] dout_tdata;
    logic                dout_tvalid;
    logic                dout_tlast;
    logic                dout_tready;

    // SRAM Interface
    logic  [RAM_ADDR_W-1:0] sramaddr;
    logic         [31:0] sramwdata;
    logic          [3:0] sramwen;
    logic                sramcs;
    logic         [31:0] sramrdata;

    // -----------------------------------------------
    // Clock Generation
    // -----------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -----------------------------------------------
    // DUT
    // -----------------------------------------------
    tidelink_sram_manager #(
        .RAM_ADDR_W(RAM_ADDR_W),
        .WORD_LEN_W(WORD_LEN_W)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .ctrl_tdata (ctrl_tdata),
        .ctrl_tvalid(ctrl_tvalid),
        .ctrl_tready(ctrl_tready),
        .din_tdata  (din_tdata),
        .din_tvalid (din_tvalid),
        .din_tlast  (din_tlast),
        .din_tready (din_tready),
        .dout_tdata (dout_tdata),
        .dout_tvalid(dout_tvalid),
        .dout_tlast (dout_tlast),
        .dout_tready(dout_tready),
        .sramaddr   (sramaddr),
        .sramwdata  (sramwdata),
        .sramwen    (sramwen),
        .sramcs     (sramcs),
        .sramrdata  (sramrdata)
    );

    // -----------------------------------------------
    // SRAM Model
    // -----------------------------------------------
    sram_model #(
        .ADDR_W(SRAM_AW),
        .DATA_W(32)
    ) u_sram (
        .clk   (clk),
        .addr  (sramaddr[RAM_ADDR_W-1:2]),
        .wdata (sramwdata),
        .wen   (sramwen),
        .cs    (sramcs),
        .rdata (sramrdata)
    );

    // -----------------------------------------------
    // Test counters
    // -----------------------------------------------
    int test_count;
    int pass_count;
    int fail_count;

    // -----------------------------------------------
    // Tasks
    // -----------------------------------------------

    // Reset
    task automatic do_reset();
        rst_n       = 1'b0;
        ctrl_tdata  = '0;
        ctrl_tvalid = 1'b0;
        din_tdata   = 32'h0;
        din_tvalid  = 1'b0;
        din_tlast   = 1'b0;
        dout_tready = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
    endtask

    // Send a control command and wait for handshake.
    // read_write: 1 = WRITE, 0 = READ
    // addr: byte address (RAM_ADDR_W bits)
    // length: number of 32-bit words to transfer
    task automatic send_ctrl(
        input  logic                   read_write,
        input  logic [RAM_ADDR_W-1:0]  addr,
        input  logic [WORD_LEN_W-1:0]  length,
        output logic                   success
    );
        int timeout_cnt;
        ctrl_tdata  = {read_write, addr, length};
        ctrl_tvalid = 1'b1;
        success     = 1'b0;
        timeout_cnt = 0;
        forever begin
            @(posedge clk);
            timeout_cnt++;
            if (ctrl_tready) begin
                success = 1'b1;
                break;
            end
            if (timeout_cnt > 100) break;
        end
        ctrl_tvalid = 1'b0;
        ctrl_tdata  = '0;
    endtask

    // Send data on din stream with timeout.
    task automatic send_din_burst(
        input  int              num_words,
        input  logic [31:0]     start_val,
        output int              words_sent
    );
        int timeout_cnt;
        words_sent = 0;
        for (int i = 0; i < num_words; i++) begin
            din_tdata  = start_val + i;
            din_tvalid = 1'b1;
            din_tlast  = (i == num_words - 1);
            timeout_cnt = 0;
            forever begin
                @(posedge clk);
                timeout_cnt++;
                if (din_tready) begin
                    words_sent++;
                    break;
                end
                if (timeout_cnt > 100) begin
                    din_tvalid = 1'b0;
                    din_tlast  = 1'b0;
                    din_tdata  = 32'h0;
                    return;
                end
            end
        end
        din_tvalid = 1'b0;
        din_tlast  = 1'b0;
        din_tdata  = 32'h0;
    endtask

    // Receive data on dout stream with timeout.
    // Collects until tlast or num_words reached.
    task automatic recv_dout_burst(
        input  int              num_words,
        output logic [31:0]     data[$],
        output int              words_recv
    );
        int timeout_cnt;
        data = {};
        words_recv = 0;
        dout_tready = 1'b1;
        for (int i = 0; i < num_words; i++) begin
            timeout_cnt = 0;
            forever begin
                @(posedge clk);
                timeout_cnt++;
                if (dout_tvalid) begin
                    data.push_back(dout_tdata);
                    words_recv++;
                    if (dout_tlast) begin
                        dout_tready = 1'b0;
                        return;
                    end
                    break;
                end
                if (timeout_cnt > 100) begin
                    dout_tready = 1'b0;
                    return;
                end
            end
        end
        dout_tready = 1'b0;
    endtask

    // Send data on din stream with random gaps (tvalid deasserted between beats).
    task automatic send_din_burst_gapped(
        input  int              num_words,
        input  logic [31:0]     start_val,
        input  int              max_gap,    // max idle cycles between beats
        output int              words_sent
    );
        int timeout_cnt;
        int gap;
        words_sent = 0;
        for (int i = 0; i < num_words; i++) begin
            // Insert random gap before asserting valid
            gap = $urandom_range(0, max_gap);
            din_tvalid = 1'b0;
            din_tlast  = 1'b0;
            din_tdata  = 32'h0;
            repeat (gap) @(posedge clk);
            // Now drive the beat
            din_tdata  = start_val + i;
            din_tvalid = 1'b1;
            din_tlast  = (i == num_words - 1);
            timeout_cnt = 0;
            forever begin
                @(posedge clk);
                timeout_cnt++;
                if (din_tready) begin
                    words_sent++;
                    break;
                end
                if (timeout_cnt > 100) begin
                    din_tvalid = 1'b0;
                    din_tlast  = 1'b0;
                    din_tdata  = 32'h0;
                    return;
                end
            end
        end
        din_tvalid = 1'b0;
        din_tlast  = 1'b0;
        din_tdata  = 32'h0;
    endtask

    // Receive data on dout stream with random stalls (tready toggled off between beats).
    task automatic recv_dout_burst_stalled(
        input  int              num_words,
        input  int              max_stall,  // max cycles tready held low between beats
        output logic [31:0]     data[$],
        output int              words_recv
    );
        int timeout_cnt;
        int stall;
        data = {};
        words_recv = 0;
        for (int i = 0; i < num_words; i++) begin
            // Insert random stall before accepting next beat
            stall = $urandom_range(0, max_stall);
            dout_tready = 1'b0;
            repeat (stall) @(posedge clk);
            dout_tready = 1'b1;
            timeout_cnt = 0;
            forever begin
                @(posedge clk);
                timeout_cnt++;
                if (dout_tvalid) begin
                    data.push_back(dout_tdata);
                    words_recv++;
                    if (dout_tlast) begin
                        dout_tready = 1'b0;
                        return;
                    end
                    break;
                end
                if (timeout_cnt > 100) begin
                    dout_tready = 1'b0;
                    return;
                end
            end
        end
        dout_tready = 1'b0;
    endtask

    // Check helper
    task automatic check(input string name, input logic [31:0] actual, input logic [31:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
            $display("  PASS: %s", name);
        end else begin
            fail_count++;
            $display("  FAIL: %s — expected 0x%08h, got 0x%08h", name, expected, actual);
        end
    endtask

    // -----------------------------------------------
    // Main Test Sequence
    // -----------------------------------------------
    initial begin
        logic        cmd_ok;
        int          words_done;
        logic [31:0] rx_data[$];

        test_count = 0;
        pass_count = 0;
        fail_count = 0;

        $display("========================================");
        $display(" TideLink SRAM Manager Testbench");
        $display("========================================");

        // ---- Reset ----
        do_reset();

        // ==================================================================
        // Test 1: Reset defaults
        // ==================================================================
        $display("\n[TEST 1] Reset defaults");
        @(posedge clk);
        check("ctrl_tready in IDLE",  ctrl_tready,  1'b1);
        check("sramcs default",       sramcs,       1'b0);
        check("sramwen default",      sramwen,      4'b0000);
        check("dout_tvalid default",  dout_tvalid,  1'b0);

        // ==================================================================
        // Test 2: WRITE command — FSM transitions to WAIT_DATA_IN
        // ==================================================================
        do_reset();
        $display("\n[TEST 2] WRITE command — FSM leaves IDLE");
        send_ctrl(1'b1, 14'h0000, 8'd4, cmd_ok);
        check("WRITE cmd handshake", cmd_ok, 1'b1);
        @(posedge clk);
        check("ctrl_tready low in WAIT_DATA_IN", ctrl_tready, 1'b0);
        check("din_tready high in WAIT_DATA_IN", din_tready, 1'b1);
        do_reset();

        // ==================================================================
        // Test 3: Single word write and readback
        // ==================================================================
        $display("\n[TEST 3] Single word write and readback (addr=0x0000)");
        send_ctrl(1'b1, 14'h0000, 8'd1, cmd_ok);
        check("WRITE cmd accepted", cmd_ok, 1'b1);

        send_din_burst(1, 32'hCAFE_BABE, words_done);
        check("1 word sent", words_done, 1);

        repeat (2) @(posedge clk);
        check("ctrl_tready back in IDLE", ctrl_tready, 1'b1);
        // $display("\n  Value at 0x0000000 is %x", u_sram.mem[0]);

        // Read back to verify
        send_ctrl(1'b0, 14'h0000, 8'd1, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);
        recv_dout_burst(1, rx_data, words_done);
        check("1 word received", words_done, 1);
        if (words_done >= 1)
            check("Readback data", rx_data[0], 32'hCAFE_BABE);

        // ==================================================================
        // Test 4: Multi-word write burst and readback (4 words)
        // ==================================================================
        $display("\n[TEST 4] 4-word write burst and readback (addr=0x0010)");
        do_reset();


        send_ctrl(1'b1, 14'h0000, 8'd4, cmd_ok);
        send_din_burst(4, 32'hAA00_0000, words_done);
        check("WRITE cmd accepted", cmd_ok, 1'b1);
        @(posedge clk);
        check("4 words sent", words_done, 4);

        repeat (2) @(posedge clk);
        check("ctrl_tready back in IDLE", ctrl_tready, 1'b1);

        // Read back to verify
        send_ctrl(1'b0, 14'h0000, 8'd4, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);
        recv_dout_burst(4, rx_data, words_done);
        check("4 words received", words_done, 4);
        for (int i = 0; i < words_done && i < 4; i++) begin
            check($sformatf("Readback data[%0d]", i), rx_data[i], 32'hAA00_0000 + i);
        end

        // ==================================================================
        // Test 5: READ command — FSM transitions to WAIT_DATA_OUT
        // ==================================================================
        $display("\n[TEST 5] READ command — FSM goes to WAIT_DATA_OUT");
        do_reset();
        send_ctrl(1'b0, 14'h0000, 8'd1, cmd_ok);
        check("READ cmd handshake", cmd_ok, 1'b1);
        @(posedge clk);
        check("state is PROCESS_DATA_OUT", u_dut.control_state, 2'd2);
        check("ctrl_tready low in WAIT_DATA_OUT", ctrl_tready, 1'b0);
        do_reset();

        // ==================================================================
        // Test 6: Write-then-read loopback at different address
        // ==================================================================
        $display("\n[TEST 6] Write-then-read loopback (addr=0x0040)");
        do_reset();

        // Write phase
        send_ctrl(1'b1, 14'h0040, 8'd4, cmd_ok);
        check("WRITE cmd accepted", cmd_ok, 1'b1);
        send_din_burst(4, 32'hCC00_0000, words_done);
        check("4 words written", words_done, 4);
        repeat (2) @(posedge clk);

        // Read phase
        send_ctrl(1'b0, 14'h0040, 8'd4, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);
        recv_dout_burst(4, rx_data, words_done);
        check("4 words read back", words_done, 4);
        for (int i = 0; i < words_done && i < 4; i++) begin
            check($sformatf("Loopback data[%0d]", i), rx_data[i], 32'hCC00_0000 + i);
        end

        // ==================================================================
        // Test 7: Back-to-back single-word writes then readback
        // ==================================================================
        $display("\n[TEST 7] Back-to-back single-word writes then readback");
        do_reset();

        send_ctrl(1'b1, 14'h0000, 8'd1, cmd_ok);
        check("1st WRITE accepted", cmd_ok, 1'b1);
        send_din_burst(1, 32'h1111_1111, words_done);
        check("1st burst complete", words_done, 1);
        repeat (2) @(posedge clk);
        check("FSM back to IDLE", ctrl_tready, 1'b1);

        send_ctrl(1'b1, 14'h0004, 8'd1, cmd_ok);
        check("2nd WRITE accepted", cmd_ok, 1'b1);
        send_din_burst(1, 32'h2222_2222, words_done);
        check("2nd burst complete", words_done, 1);
        repeat (2) @(posedge clk);
        check("FSM back to IDLE again", ctrl_tready, 1'b1);

        // Read back both words
        send_ctrl(1'b0, 14'h0000, 8'd1, cmd_ok);
        check("READ 1st word accepted", cmd_ok, 1'b1);
        recv_dout_burst(1, rx_data, words_done);
        if (words_done >= 1)
            check("1st write readback", rx_data[0], 32'h1111_1111);

        repeat (2) @(posedge clk);
        send_ctrl(1'b0, 14'h0004, 8'd1, cmd_ok);
        check("READ 2nd word accepted", cmd_ok, 1'b1);
        recv_dout_burst(1, rx_data, words_done);
        if (words_done >= 1)
            check("2nd write readback", rx_data[0], 32'h2222_2222);

        // ==================================================================
        // Test 8: Verify dout_tlast on final read beat
        // ==================================================================
        $display("\n[TEST 8] Verify dout_tlast on final read beat (length=3)");
        do_reset();

        // Write 3 words first
        send_ctrl(1'b1, 14'h0000, 8'd3, cmd_ok);
        check("WRITE cmd accepted", cmd_ok, 1'b1);
        send_din_burst(3, 32'hFF00_0000, words_done);
        check("3 words written", words_done, 3);
        repeat (2) @(posedge clk);

        // Read and check tlast
        send_ctrl(1'b0, 14'h0000, 8'd3, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);

        dout_tready = 1'b1;
        begin
            int beat_count = 0;
            logic saw_tlast = 1'b0;
            int timeout = 0;
            while (!saw_tlast && timeout < 200) begin
                @(posedge clk);
                timeout++;
                if (dout_tvalid) begin
                    beat_count++;
                    if (dout_tlast) saw_tlast = 1'b1;
                end
            end
            dout_tready = 1'b0;
            check("dout_tlast seen", saw_tlast, 1'b1);
            check("dout_tlast on beat 3", beat_count, 3);
        end

        // ==================================================================
        // Test 9: Write with gapped din (random gaps in tvalid)
        // ==================================================================
        $display("\n[TEST 9] 4-word write with gapped din, then readback");
        do_reset();

        send_ctrl(1'b1, 14'h0080, 8'd4, cmd_ok);
        check("WRITE cmd accepted", cmd_ok, 1'b1);
        send_din_burst_gapped(4, 32'hDA00_0000, 5, words_done);
        check("4 words sent (gapped)", words_done, 4);
        repeat (2) @(posedge clk);
        check("ctrl_tready back in IDLE", ctrl_tready, 1'b1);

        send_ctrl(1'b0, 14'h0080, 8'd4, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);
        recv_dout_burst(4, rx_data, words_done);
        check("4 words received", words_done, 4);
        for (int i = 0; i < words_done && i < 4; i++)
            check($sformatf("Gapped write readback[%0d]", i), rx_data[i], 32'hDA00_0000 + i);

        // ==================================================================
        // Test 10: Read with stalled dout (random stalls on tready)
        // ==================================================================
        $display("\n[TEST 10] 4-word read with stalled dout_tready");
        do_reset();

        // Write known data first
        send_ctrl(1'b1, 14'h00C0, 8'd4, cmd_ok);
        check("WRITE cmd accepted", cmd_ok, 1'b1);
        send_din_burst(4, 32'hAC00_0000, words_done);
        check("4 words written", words_done, 4);
        repeat (2) @(posedge clk);

        // Read with stalls
        send_ctrl(1'b0, 14'h00C0, 8'd4, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);
        recv_dout_burst_stalled(4, 5, rx_data, words_done);
        check("4 words received (stalled)", words_done, 4);
        for (int i = 0; i < words_done && i < 4; i++)
            check($sformatf("Stalled read data[%0d]", i), rx_data[i], 32'hAC00_0000 + i);

        // ==================================================================
        // Test 11: Combined gapped write + stalled read
        // ==================================================================
        $display("\n[TEST 11] 8-word gapped write + stalled read");
        do_reset();

        send_ctrl(1'b1, 14'h0100, 8'd8, cmd_ok);
        check("WRITE cmd accepted", cmd_ok, 1'b1);
        send_din_burst_gapped(8, 32'hBB00_0000, 4, words_done);
        check("8 words sent (gapped)", words_done, 8);
        repeat (2) @(posedge clk);
        check("ctrl_tready back in IDLE", ctrl_tready, 1'b1);

        send_ctrl(1'b0, 14'h0100, 8'd8, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);
        recv_dout_burst_stalled(8, 4, rx_data, words_done);
        check("8 words received (stalled)", words_done, 8);
        for (int i = 0; i < words_done && i < 8; i++)
            check($sformatf("Gapped/stalled data[%0d]", i), rx_data[i], 32'hBB00_0000 + i);

        // ==================================================================
        // Test 12: Single-word gapped write + stalled read (edge case)
        // ==================================================================
        $display("\n[TEST 12] Single-word gapped write + stalled read");
        do_reset();

        send_ctrl(1'b1, 14'h0140, 8'd1, cmd_ok);
        check("WRITE cmd accepted", cmd_ok, 1'b1);
        send_din_burst_gapped(1, 32'hDEAD_BEEF, 3, words_done);
        check("1 word sent (gapped)", words_done, 1);
        repeat (2) @(posedge clk);

        send_ctrl(1'b0, 14'h0140, 8'd1, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);
        recv_dout_burst_stalled(1, 3, rx_data, words_done);
        check("1 word received (stalled)", words_done, 1);
        if (words_done >= 1)
            check("Single-word gapped/stalled readback", rx_data[0], 32'hDEAD_BEEF);

        // ==================================================================
        // Test 13: Heavy gapping and stalling (stress test)
        // ==================================================================
        $display("\n[TEST 13] Stress: 8-word write (max gap=10) + read (max stall=10)");
        do_reset();

        send_ctrl(1'b1, 14'h0180, 8'd8, cmd_ok);
        check("WRITE cmd accepted", cmd_ok, 1'b1);
        send_din_burst_gapped(8, 32'hEE00_0000, 10, words_done);
        check("8 words sent (heavy gaps)", words_done, 8);
        repeat (2) @(posedge clk);
        check("ctrl_tready back in IDLE", ctrl_tready, 1'b1);

        send_ctrl(1'b0, 14'h0180, 8'd8, cmd_ok);
        check("READ cmd accepted", cmd_ok, 1'b1);
        recv_dout_burst_stalled(8, 10, rx_data, words_done);
        check("8 words received (heavy stalls)", words_done, 8);
        for (int i = 0; i < words_done && i < 8; i++)
            check($sformatf("Stress data[%0d]", i), rx_data[i], 32'hEE00_0000 + i);

        // ---- Results ----
        repeat (5) @(posedge clk);
        $display("\n========================================");
        $display(" Results: %0d/%0d passed (%0d failed)", pass_count, test_count, fail_count);
        $display("========================================");

        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    // -----------------------------------------------
    // Timeout watchdog
    // -----------------------------------------------
    initial begin
        #(CLK_PERIOD * 50000);
        $display("ERROR: Simulation timed out!");
        $finish;
    end

    // -----------------------------------------------
    // Waveform dump
    // -----------------------------------------------
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_tidelink_sram_manager);
    end

endmodule
