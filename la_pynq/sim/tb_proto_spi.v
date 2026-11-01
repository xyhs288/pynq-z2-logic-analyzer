// =====================================================================
//  tb_proto_spi.v —— SPI 解码自检 testbench
//
//  testbench 里直接产生 SPI mode 0 时序（SCLK 空闲低、上升沿采样），
//  发一串已知字节，检查解码结果。验证：
//    1. 单次传输内多字节解码正确
//    2. 跨传输 byte_cnt 复位
//    3. CS 在字节中途抬起 -> frame_err
//
//  SPI 时序是公开标准（CPOL/CPHA 四种组合），不是我编的假设。
// =====================================================================

`timescale 1ns / 1ps

module tb_proto_spi;

    localparam integer HALF = 100;      // SCLK 半周期 100ns -> 5MHz

    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg  rst_n = 1'b0;
    reg  cs_n  = 1'b1;
    reg  sclk  = 1'b0;
    reg  mosi  = 1'b0;

    wire [7:0] data;
    wire       valid;
    wire [7:0] byte_cnt;
    wire       frame_err;

    proto_spi #(.CPOL(0), .CPHA(0)) u_spi (
        .clk       (clk),
        .rst_n     (rst_n),
        .sclk      (sclk),
        .mosi      (mosi),
        .cs_n      (cs_n),
        .data      (data),
        .valid     (valid),
        .byte_cnt  (byte_cnt),
        .frame_err (frame_err)
    );

    integer n_fail = 0;

`ifdef WAVE_MODE
    integer csv_fd;
    initial begin
        csv_fd = $fopen("tb_proto_spi.csv", "w");
        $fwrite(csv_fd, "t_ns,cs_n,sclk,mosi,state,valid,data,frame_err\n");
    end
    always @(posedge clk) begin
        $fwrite(csv_fd, "%0d,%b,%b,%b,%0d,%b,%0d,%b\n",
                $time, cs_n, sclk, mosi, u_spi.bit_idx, valid, data, frame_err);
    end
`endif

    initial begin
        #2000000;
        $display("[FAIL] TIMEOUT");
        $display("RESULT: FAIL    (timeout)");
        $finish;
    end

    // ---- 收集解码结果 ----
    reg [7:0] rxq [0:15];
    integer   nq = 0;

    always @(posedge clk) begin
        if (valid) begin
            rxq[nq] = data;
            nq      = nq + 1;
        end
    end

    // ---- 主机模型：mode 0，一个字节 ----
    task spi_byte(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = b[i];            // SCLK 低时改数据
                #(HALF);
                sclk = 1'b1;            // 上升沿：解码器采样
                #(HALF);
                sclk = 1'b0;
            end
        end
    endtask

    task begin_frame;
        begin
            cs_n = 1'b1; sclk = 1'b0; mosi = 1'b0;
            #(HALF * 2);
            cs_n = 1'b0;                // 片选拉低，传输开始
            #(HALF * 2);
        end
    endtask

    task end_frame;
        begin
            sclk = 1'b0;
            #(HALF * 2);
            cs_n = 1'b1;                // 片选抬起，传输结束
            #(HALF * 4);
        end
    endtask

    integer i;

    initial begin
        $display("=========== tb_proto_spi START ===========");
        $display("SPI mode 0  sclk half period = %0d ns", HALF);

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        #200;

        // ---- 1. 单次传输 3 个字节 ----
        nq = 0;
        begin_frame;
        spi_byte(8'hA5);
        spi_byte(8'h5A);
        spi_byte(8'hFF);
        end_frame;

        if (nq == 3 && rxq[0] == 8'hA5 && rxq[1] == 8'h5A && rxq[2] == 8'hFF)
            $display("[PASS] 3 bytes in one frame : A5 5A FF");
        else begin
            $display("[FAIL] got %0d bytes: %02h %02h %02h", nq, rxq[0], rxq[1], rxq[2]);
            n_fail = n_fail + 1;
        end

        // ---- 2. byte_cnt 在新传输里复位 ----
        nq = 0;
        begin_frame;
        spi_byte(8'h12);
        end_frame;
        if (byte_cnt == 8'd1)
            $display("[PASS] byte_cnt restarts at each CS falling edge");
        else begin
            $display("[FAIL] byte_cnt = %0d after a fresh frame (expect 1)", byte_cnt);
            n_fail = n_fail + 1;
        end

        // ---- 3. CS 在字节中途抬起 -> frame_err ----
        begin_frame;
        for (i = 7; i >= 3; i = i - 1) begin    // 只发 5 位
            mosi = 1'b1;
            #(HALF);
            sclk = 1'b1;
            #(HALF);
            sclk = 1'b0;
        end
        end_frame;                              // CS 抬起，字节没收完
        #200;
        if (frame_err)
            $display("[PASS] partial byte at CS rising -> frame_err");
        else begin
            $display("[FAIL] frame_err not raised on a partial byte");
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_proto_spi END ===========");
`ifdef WAVE_MODE
        $fclose(csv_fd);
`endif
        $finish;
    end

endmodule
