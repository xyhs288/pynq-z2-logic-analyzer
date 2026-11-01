// =====================================================================
//  tb_proto_i2c.v —— I2C 解码自检 testbench
//
//  testbench 直接驱动 scl / sda 两根线（总线空闲为高），产生：
//    START + 地址 + 应答 + 数据 + 应答 + ... + STOP
//  检查解码结果。验证：
//    1. 传输中每个字节解码正确（含应答位）
//    2. 首字节被标记为地址，R/W 位解析正确
//    3. START / STOP 的界定不产生假字节
//
//  I2C 时序是公开标准，不是我编的假设。
// =====================================================================

`timescale 1ns / 1ps

module tb_proto_i2c;

    localparam integer T = 100;         // 半个 SCL 周期 100ns -> 5MHz

    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg rst_n = 1'b0;
    reg scl   = 1'b1;                   // 总线上拉，空闲高
    reg sda   = 1'b1;

    wire [7:0] data;
    wire       valid;
    wire       ack;
    wire       first;
    wire       rw;
    wire       active;

    proto_i2c u_i2c (
        .clk    (clk),
        .rst_n  (rst_n),
        .scl    (scl),
        .sda    (sda),
        .data   (data),
        .valid  (valid),
        .ack    (ack),
        .first  (first),
        .rw     (rw),
        .active (active)
    );

    integer n_fail = 0;

`ifdef WAVE_MODE
    integer csv_fd;
    initial begin
        csv_fd = $fopen("tb_proto_i2c.csv", "w");
        $fwrite(csv_fd, "t_ns,scl,sda,state,valid,data,ack,first,rw\n");
    end
    always @(posedge clk) begin
        $fwrite(csv_fd, "%0d,%b,%b,%0d,%b,%0d,%b,%b,%b\n",
                $time, scl, sda, u_i2c.bit_cnt, valid, data, ack, first, rw);
    end
`endif

    initial begin
        #3000000;
        $display("[FAIL] TIMEOUT");
        $display("RESULT: FAIL    (timeout)");
        $finish;
    end

    // ---- 收集解码结果 ----
    reg [7:0] rxq  [0:15];
    reg       fq   [0:15];
    reg       rwq  [0:15];
    reg       ackq [0:15];
    integer   nq = 0;

    always @(posedge clk) begin
        if (valid) begin
            rxq[nq]  = data;
            fq[nq]   = first;
            rwq[nq]  = rw;
            ackq[nq] = ack;
            nq       = nq + 1;
        end
    end

    // ---- 主机模型 ----
    task i2c_start;
        begin
            sda = 1'b1; scl = 1'b1; #(T);
            sda = 1'b0; #(T);           // SCL 高，SDA 下降 = START
            scl = 1'b0; #(T);
        end
    endtask

    // 发一个字节 + 一个应答位（ack_bit：0=从机应答）
    task i2c_byte(input [7:0] b, input ack_bit);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                sda = b[i]; #(T);
                scl = 1'b1; #(T);       // 上升沿：解码器采样
                scl = 1'b0; #(T);
            end
            sda = ack_bit; #(T);        // 应答位
            scl = 1'b1; #(T);
            scl = 1'b0; #(T);
            sda = 1'b1; #(T);
        end
    endtask

    task i2c_stop;
        begin
            sda = 1'b0; #(T);
            scl = 1'b1; #(T);
            sda = 1'b1; #(T);           // SCL 高，SDA 上升 = STOP
            #(T);
        end
    endtask

    initial begin
        $display("=========== tb_proto_i2c START ===========");

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        #200;

        // ---- 1. 写传输：地址 0xA0 + 2 个数据字节 ----
        nq = 0;
        i2c_start;
        i2c_byte(8'hA0, 1'b0);          // 地址 + 写，从机应答
        i2c_byte(8'h55, 1'b0);
        i2c_byte(8'hAA, 1'b0);
        i2c_stop;
        #500;

        if (nq == 3 && rxq[0] == 8'hA0 && rxq[1] == 8'h55 && rxq[2] == 8'hAA)
            $display("[PASS] write frame decoded : A0 55 AA (3 bytes)");
        else begin
            $display("[FAIL] write frame: got %0d bytes: %02h %02h %02h",
                     nq, rxq[0], rxq[1], rxq[2]);
            n_fail = n_fail + 1;
        end

        // ---- 2. 首字节标记为地址，且 R/W 位正确（A0 -> 写） ----
        if (fq[0] == 1'b1 && rwq[0] == 1'b0)
            $display("[PASS] first byte flagged as address, R/W = 0 (write)");
        else begin
            $display("[FAIL] first=%b rw=%b (expect 1 / 0)", fq[0], rwq[0]);
            n_fail = n_fail + 1;
        end

        // ---- 3. 数据字节不应被当作地址 ----
        if (fq[1] == 1'b0)
            $display("[PASS] data byte not flagged as address");
        else begin
            $display("[FAIL] data byte wrongly flagged as address");
            n_fail = n_fail + 1;
        end

        // ---- 4. 应答位解析（从机应答 = ack 0） ----
        if (ackq[0] == 1'b0 && ackq[1] == 1'b0 && ackq[2] == 1'b0)
            $display("[PASS] ACK bits decoded as 0");
        else begin
            $display("[FAIL] ack = %b %b %b (expect all 0)", ackq[0], ackq[1], ackq[2]);
            n_fail = n_fail + 1;
        end

        // ---- 5. 读传输：地址 0xA1 -> R/W = 1 ----
        nq = 0;
        i2c_start;
        i2c_byte(8'hA1, 1'b0);
        i2c_byte(8'h3C, 1'b1);          // 主机 NACK（读传输最后一字节）
        i2c_stop;
        #500;

        if (nq == 2 && rxq[0] == 8'hA1 && rwq[0] == 1'b1)
            $display("[PASS] read frame decoded : A1, R/W = 1");
        else begin
            $display("[FAIL] read frame: nq=%0d rxq0=%02h rw0=%b", nq, rxq[0], rwq[0]);
            n_fail = n_fail + 1;
        end

        if (ackq[1] == 1'b1)
            $display("[PASS] NACK from master decoded as 1");
        else begin
            $display("[FAIL] NACK not detected");
            n_fail = n_fail + 1;
        end

        // ---- 6. STOP 之后总线应回到空闲 ----
        if (active == 1'b0)
            $display("[PASS] bus idle after STOP");
        else begin
            $display("[FAIL] still active after STOP");
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_proto_i2c END ===========");
`ifdef WAVE_MODE
        $fclose(csv_fd);
`endif
        $finish;
    end

endmodule
