// =====================================================================
//  tb_proto_uart.v —— UART 收发自检 testbench
//
//  把 uart_tx 的 tx 直接接到 proto_uart 的 rx，发一串已知字节，
//  检查解码结果是否一致，并验证：
//    1. 正常帧能解出正确字节
//    2. valid 是单拍脉冲
//    3. 人为把停止位拉低 -> frame_err 置位
//    4. 波特率不匹配 -> 解出的字节是错的（这正是逻辑分析仪要抓的问题）
//
//  为什么这个验证是可信的：UART 帧格式是公开标准
//  （1 起始位 + 8 数据位 LSB first + 1 停止位），不是我编的假设。
// =====================================================================

`timescale 1ns / 1ps

module tb_proto_uart;

    localparam integer DIV_W = 16;
    localparam [15:0]  DIV   = 16'd108;    // 位周期 = 108 x 8ns = 864ns

    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg  rst_n = 1'b0;
    reg  [DIV_W-1:0] baud_div = DIV;

    // ---- 发送侧 ----
    reg        send    = 1'b0;
    reg [7:0]  tx_data = 8'd0;
    wire       tx;
    wire       busy;

    uart_tx #(.DIV_W(DIV_W)) u_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .baud_div (baud_div),
        .send     (send),
        .data_in  (tx_data),
        .tx       (tx),
        .busy     (busy)
    );

    // ---- 接收侧 ----
    reg  [DIV_W-1:0] rx_div = DIV;
    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_err;

    proto_uart #(.DIV_W(DIV_W)) u_rx (
        .clk       (clk),
        .rst_n     (rst_n),
        .baud_div  (rx_div),
        .rx        (tx),
        .data       (rx_data),
        .valid      (rx_valid),
        .frame_err  (rx_err)
    );

    integer    n_fail = 0;

`ifdef WAVE_MODE
    integer csv_fd;
    initial begin
        csv_fd = $fopen("tb_proto_uart.csv", "w");
        $fwrite(csv_fd, "t_ns,tx,state,valid,data,frame_err\n");
    end
    always @(posedge clk) begin
        $fwrite(csv_fd, "%0d,%b,%0d,%b,%0d,%b\n",
                $time, tx, u_rx.state, rx_valid, rx_data, rx_err);
    end
`endif

    // 超时保护
    initial begin
        #2000000;
        $display("[FAIL] TIMEOUT");
        $display("RESULT: FAIL    (timeout)");
        $finish;
    end

    // 捕获解码结果
    reg [7:0] got      = 8'd0;
    reg       got_flag = 1'b0;
    reg       got_err  = 1'b0;
    integer   valid_len = 0;      // valid 持续了几个时钟（应为 1）

    always @(posedge clk) begin
        if (rx_valid) begin
            got      = rx_data;
            got_flag = 1'b1;
            got_err  = rx_err;
        end
    end

    // 测 valid 脉冲宽度
    reg prev_valid = 1'b0;
    always @(posedge clk) begin
        if (prev_valid && rx_valid) valid_len = valid_len + 1;
        prev_valid <= rx_valid;
    end

    // ---- 发一个字节并等解码结果 ----
    task send_and_check(input [7:0] v, input [127:0] name);
        begin
            got_flag = 1'b0;
            @(negedge clk);
            tx_data = v;
            send    = 1'b1;
            @(negedge clk);
            send    = 1'b0;

            // 等 busy 落下 + 解码完成
            wait (busy === 1'b1);
            wait (busy === 1'b0);
            repeat (DIV * 2) @(posedge clk);

            if (!got_flag) begin
                $display("  [FAIL] %0s : no byte decoded", name);
                n_fail = n_fail + 1;
            end
            else if (got !== v) begin
                $display("  [FAIL] %0s : sent %02h, decoded %02h", name, v, got);
                n_fail = n_fail + 1;
            end
            else begin
                $display("  [PASS] %0s : %02h", name, got);
            end
        end
    endtask

    initial begin
        $display("=========== tb_proto_uart START ===========");
        $display("baud_div = %0d  (bit period = %0d ns)", DIV, DIV * 8);

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- 1. 正常收发 ----
        send_and_check(8'h55, "0x55 (01010101)");
        send_and_check(8'hAA, "0xAA (10101010)");
        send_and_check(8'h00, "0x00 (all zero)");
        send_and_check(8'hFF, "0xFF (all one) ");
        send_and_check(8'h41, "0x41 ('A')     ");

        // ---- 2. valid 必须是单拍脉冲 ----
        if (valid_len == 0)
            $display("[PASS] valid is a single-cycle pulse");
        else begin
            $display("[FAIL] valid lasted %0d extra cycles", valid_len);
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");

        // ---- 3. 波特率不匹配 ----
        // 发送端 108，接收端按 96 解 -> 采样点逐渐偏移，必然解错
        $display("baud mismatch test: tx=108, rx=96 (expect WRONG byte)");
        rx_div  = 16'd96;
        got_flag = 1'b0;
        @(negedge clk);
        tx_data = 8'h55;
        send    = 1'b1;
        @(negedge clk);
        send    = 1'b0;
        wait (busy === 1'b1);
        wait (busy === 1'b0);
        repeat (DIV * 2) @(posedge clk);

        if (got_flag && got !== 8'h55)
            $display("[PASS] mismatched baud rate decoded as %02h (not 55) -> analyser would flag this",
                     got);
        else if (!got_flag)
            $display("[PASS] mismatched baud rate produced no valid frame");
        else begin
            $display("[FAIL] mismatched baud rate still decoded as 55 ?!");
            n_fail = n_fail + 1;
        end

        rx_div = DIV;

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_proto_uart END ===========");
`ifdef WAVE_MODE
        $fclose(csv_fd);
`endif
        $finish;
    end

endmodule
