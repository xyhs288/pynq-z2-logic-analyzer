// =====================================================================
//  tb_proto_src.v —— 信号源 -> 解码器 环回自检
//
//  这条链路就是将来在板子上自测时跑的那条：
//      spi_src  ->  proto_spi
//      i2c_src  ->  proto_i2c
//
//  验证两个源发出的字节序列被对应的解码器完整还原，
//  而且连续多帧都正确（检查状态机能自己复位重来）。
// =====================================================================

`timescale 1ns / 1ps

module tb_proto_src;

    localparam integer HALF = 50;
    localparam integer GAP  = 200;

    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg rst_n = 1'b0;

    // ---- SPI 链路 ----
    wire        s_sclk, s_mosi, s_cs_n;
    wire [7:0]  s_data;
    wire        s_valid;

    spi_src #(.HALF(HALF), .GAP(GAP)) u_spi_src (
        .clk (clk), .rst_n (rst_n),
        .sclk (s_sclk), .mosi (s_mosi), .cs_n (s_cs_n)
    );

    proto_spi #(.CPOL(0), .CPHA(0)) u_spi_dec (
        .clk (clk), .rst_n (rst_n),
        .sclk (s_sclk), .mosi (s_mosi), .cs_n (s_cs_n),
        .data (s_data), .valid (s_valid),
        .byte_cnt (), .frame_err ()
    );

    // ---- I2C 链路 ----
    wire        i_scl, i_sda;
    wire [7:0]  i_data;
    wire        i_valid, i_ack, i_first, i_rw;

    i2c_src #(.HALF(HALF), .GAP(GAP)) u_i2c_src (
        .clk (clk), .rst_n (rst_n),
        .scl (i_scl), .sda (i_sda)
    );

    proto_i2c u_i2c_dec (
        .clk (clk), .rst_n (rst_n),
        .scl (i_scl), .sda (i_sda),
        .data (i_data), .valid (i_valid), .ack (i_ack),
        .first (i_first), .rw (i_rw), .active ()
    );

    integer n_fail = 0;

`ifdef WAVE_MODE
    integer csv_fd;
    initial begin
        csv_fd = $fopen("tb_proto_src.csv", "w");
        $fwrite(csv_fd, "t_ns,spi_sclk,spi_mosi,spi_cs_n,spi_valid,spi_data,i2c_scl,i2c_sda,i2c_valid,i2c_data\n");
    end
    always @(posedge clk) begin
        $fwrite(csv_fd, "%0d,%b,%b,%b,%b,%0d,%b,%b,%b,%0d\n",
                $time, s_sclk, s_mosi, s_cs_n, s_valid, s_data,
                i_scl, i_sda, i_valid, i_data);
    end
`endif

    initial begin
        #200000;
        $display("[FAIL] TIMEOUT");
        $display("RESULT: FAIL    (timeout)");
        $finish;
    end

    // ---- 收集结果 ----
    reg [7:0] sq [0:15];  integer sn = 0;
    reg [7:0] iq [0:15];  reg ifq [0:15];  integer inq = 0;

    always @(posedge clk) begin
        if (s_valid) begin sq[sn] = s_data; sn = sn + 1; end
    end

    always @(posedge clk) begin
        if (i_valid) begin iq[inq] = i_data; ifq[inq] = i_first; inq = inq + 1; end
    end

    integer k;

    initial begin
        $display("=========== tb_proto_src START ===========");

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        // 等两轮完整事务跑完（SPI 每帧 20800ns，I2C 每次 24400ns）
        #60000;

        // ---- SPI：应连续解出 A5 5A FF A5 5A FF ----
        $display("SPI  decoded count = %0d", sn);
        if (sn >= 6 && sq[0] == 8'hA5 && sq[1] == 8'h5A && sq[2] == 8'hFF &&
                       sq[3] == 8'hA5 && sq[4] == 8'h5A && sq[5] == 8'hFF)
            $display("[PASS] SPI source -> decoder : A5 5A FF repeated");
        else begin
            $display("[FAIL] SPI chain wrong:");
            for (k = 0; k < sn && k < 8; k = k + 1) $display("        [%0d] %02h", k, sq[k]);
            n_fail = n_fail + 1;
        end

        // ---- I2C：应连续解出 A0 55 AA A0 55 AA ----
        $display("I2C  decoded count = %0d", inq);
        if (inq >= 6 && iq[0] == 8'hA0 && iq[1] == 8'h55 && iq[2] == 8'hAA &&
                        iq[3] == 8'hA0 && iq[4] == 8'h55 && iq[5] == 8'hAA)
            $display("[PASS] I2C source -> decoder : A0 55 AA repeated");
        else begin
            $display("[FAIL] I2C chain wrong:");
            for (k = 0; k < inq && k < 8; k = k + 1) $display("        [%0d] %02h", k, iq[k]);
            n_fail = n_fail + 1;
        end

        // ---- I2C 每轮首字节应被标为地址 ----
        if (inq >= 4 && ifq[0] == 1'b1 && ifq[3] == 1'b1 && ifq[1] == 1'b0)
            $display("[PASS] address byte flagged at the start of each transaction");
        else begin
            $display("[FAIL] address flag wrong");
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_proto_src END ===========");
`ifdef WAVE_MODE
        $fclose(csv_fd);
`endif
        $finish;
    end

endmodule
