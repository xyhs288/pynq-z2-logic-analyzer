// =====================================================================
//  tb_la_top.v —— 集成验证：走 AXI 配置 -> 采集 -> 读回
//
//  这是"整机"的验证，不是单模块：所有配置和数据都经过 AXI4-Lite 事务，
//  与 PS 真实使用路径一致。
//
//  激励：
//    ch[4] = I2C SCL，ch[5] = I2C SDA（由 i2c_src 产生 A0 55 AA 循环）
//    其余通道接地
//
//  验证：
//    1. 复位后 STATUS 全 0
//    2. 经 AXI 配置 TRIG_MODE=4(协议匹配) / PROTO_SEL=2(I2C) / TRIG_VALUE=AA
//    3. arm 后 STATUS.armed 置位
//    4. 轮询到 STATUS.full
//    5. 读 STOP_PTR，按时间顺序读回 DEPTH 个采样点
//    6. 读回的数据里 SCL/SDA 都有跳变（不是平的）
//    7. PROTO_BYTE 随总线变化（证明解码器接上了）
//    8. 使能统计后 n_width 增长（证明统计模块接上了）
// =====================================================================

`timescale 1ns / 1ps

module tb_la_top;

    localparam integer DEPTH    = 1024;
    localparam integer PRE_TRIG = 128;
    localparam integer AW       = 8;
    localparam integer AW_MEM   = 10;
    localparam integer I2C_HALF = 8;

    reg clk = 1'b0;
    always #4 clk = ~clk;                       // 8ns -> 125MHz

    reg rst_n = 1'b0;

    // ---- 被测信号源：I2C ----
    wire bus_scl, bus_sda;

    i2c_src #(.HALF(I2C_HALF), .GAP(16)) u_src (
        .clk(clk), .rst_n(rst_n), .scl(bus_scl), .sda(bus_sda)
    );

    wire [7:0] sig_out;   // DUT 的 Pmod B 输出

    reg [7:0] ch_drv;
    reg       uart_loop = 1'b0;
    reg       i2c_loop  = 1'b0;   // 把 Pmod B 针 7/8 回环到 CH4/CH5
    always @(*) begin
        ch_drv    = 8'h01;          // bit0 默认空闲高（UART 空闲电平）
        ch_drv[4] = bus_scl;
        ch_drv[5] = bus_sda;
    end
    // 回环：把 DUT 的 Pmod B 针 1（UART TX）接到 Pmod A 的 CH0
    wire [7:0] ch_in = uart_loop ? {ch_drv[7:1], sig_out[0]} :
                       i2c_loop  ? {ch_drv[7:6], sig_out[5], sig_out[4], ch_drv[3:0]} :
                                   ch_drv;

    // ---- AXI4-Lite 主机侧 ----
    reg  [AW-1:0] s_awaddr  = {AW{1'b0}};
    reg           s_awvalid = 1'b0;
    wire          s_awready;
    reg  [31:0]   s_wdata   = 32'd0;
    reg  [3:0]    s_wstrb   = 4'hF;
    reg           s_wvalid  = 1'b0;
    wire          s_wready;
    wire [1:0]    s_bresp;
    wire          s_bvalid;
    reg           s_bready  = 1'b0;
    reg  [AW-1:0] s_araddr  = {AW{1'b0}};
    reg           s_arvalid = 1'b0;
    wire          s_arready;
    wire [31:0]   s_rdata;
    wire [1:0]    s_rresp;
    wire          s_rvalid;
    reg           s_rready  = 1'b0;

    wire [3:0] led;

    la_top #(
        .DEPTH   (DEPTH),
        .NBINS   (256),
        .SHIFT   (2),
        .AW      (AW)
    ) dut (
        .sys_clk(clk), .btn0(1'b0), .ch_in(ch_in), .led(led), .sig_out(sig_out),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid),
        .s_wready(s_wready), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid),
        .s_rready(s_rready)
    );

    integer    n_fail = 0;
    reg [31:0] rv;
    integer    i, addr, edges;
    integer    k;
    reg        seen_5a, seen_59;
    reg        seen_a0, seen_55, seen_aa;

    initial begin
        #16000000;  // UART + I2C 两段回环测试需要跑到 ~12 ms
        $display("[FAIL] TIMEOUT");
        $display("RESULT: FAIL    (timeout)");
        $finish;
    end

    // ---- AXI 主机模型 ----
    task axi_write(input [AW-1:0] a, input [31:0] d);
        begin
            @(negedge clk);
            s_awaddr = a; s_wdata = d; s_wstrb = 4'hF;
            s_awvalid = 1'b1; s_wvalid = 1'b1;
            @(negedge clk);
            while (!s_awready) @(negedge clk);
            s_awvalid = 1'b0; s_wvalid = 1'b0;
            @(negedge clk);
            while (!s_bvalid) @(negedge clk);
            s_bready = 1'b1;
            @(negedge clk);
            s_bready = 1'b0;
            @(negedge clk);
        end
    endtask

    task axi_read(input [AW-1:0] a, output [31:0] d);
        begin
            @(negedge clk);
            s_araddr = a; s_arvalid = 1'b1;
            @(negedge clk);
            while (!s_arready) @(negedge clk);
            s_arvalid = 1'b0;
            @(negedge clk);
            while (!s_rvalid) @(negedge clk);
            d = s_rdata;
            s_rready = 1'b1;
            @(negedge clk);
            s_rready = 1'b0;
            @(negedge clk);
        end
    endtask

    task chk(input [31:0] got, input [31:0] want, input [8*32-1:0] name);
        begin
            if (got !== want) begin
                $display("  [FAIL] %0s : got 0x%h, want 0x%h", name, got, want);
                n_fail = n_fail + 1;
            end
            else $display("  [PASS] %0s = 0x%h", name, got);
        end
    endtask

    initial begin
        $display("=========== tb_la_top START ===========");
        $display("DEPTH=%0d PRE_TRIG=%0d  I2C_HALF=%0d", DEPTH, PRE_TRIG, I2C_HALF);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- 1. 复位后状态 ----
        axi_read(8'h04, rv);
        chk(rv, 32'd0, "STATUS after reset");

        // ---- 2. 经 AXI 配置 ----
        $display("--- configure via AXI ---");
        axi_write(8'h08, 32'd1);        // DIV = 1 -> 每个 clk 采一次
        axi_write(8'h0C, DEPTH);
        axi_write(8'h20, PRE_TRIG);
        axi_write(8'h14, 32'd4);        // TRIG_CHAN = 4 -> 统计盯 I2C SCL
        axi_write(8'h18, 32'hAA);       // 匹配字节
        axi_write(8'h28, 32'd2);        // PROTO_SEL = I2C
        axi_write(8'h10, 32'd4);        // TRIG_MODE = 4 -> 协议内容触发

        axi_read(8'h10, rv); chk(rv, 32'd4,  "TRIG_MODE readback");
        axi_read(8'h28, rv); chk(rv, 32'd2,  "PROTO_SEL readback");
        axi_read(8'h18, rv); chk(rv, 32'hAA, "TRIG_VALUE readback");

        // ---- 3. 布防 ----
        $display("--- arm ---");
        axi_write(8'h00, 32'd1);        // CTRL.arm = 1
        repeat (20) @(posedge clk);
        axi_read(8'h04, rv);
        if (rv[0] === 1'b1) $display("  [PASS] STATUS.armed set");
        else begin
            $display("  [FAIL] STATUS.armed not set (0x%h)", rv);
            n_fail = n_fail + 1;
        end

        // ---- 4. 等抓满 ----
        $display("--- wait for FULL ---");
        i = 0;
        while (i < 20000) begin
            axi_read(8'h04, rv);
            if (rv[2] === 1'b1) i = 99999;
            else i = i + 1;
        end
        if (i != 99999) begin
            $display("  [FAIL] never reached FULL");
            n_fail = n_fail + 1;
        end
        else $display("  [PASS] reached FULL");

        // ---- 5. 读回数据 ----
        // 注意：arm 发生在 I2C 源已经跑起来之后，触发前积累的采样点数
        // 取决于 arming 时刻总线处于事务的哪一段，所以 STOP_PTR 的具体值
        // 不是确定量。这里只验证【范围】和【内容】，不硬编码数值。
        $display("--- read back ---");
        axi_read(8'h88, rv);
        $display("  STOP_PTR = %0d", rv[15:0]);
        if (rv[15:0] < DEPTH) $display("  [PASS] STOP_PTR in range");
        else begin
            $display("  [FAIL] STOP_PTR out of range: %0d", rv[15:0]);
            n_fail = n_fail + 1;
        end
        addr = rv[15:0];

        begin : read_loop
            integer k;
            integer pre_edges, post_edges;
            reg [7:0] prev, cur;
            pre_edges = 0; post_edges = 0;
            prev = 8'h00;
            for (k = 0; k < DEPTH; k = k + 1) begin
                axi_write(8'h80, (addr + k) & (DEPTH - 1));
                axi_read (8'h80, rv);
                cur = rv[7:0];
                if (k > 0 && cur[4] !== prev[4]) begin
                    if (k < PRE_TRIG) pre_edges  = pre_edges + 1;
                    else              post_edges = post_edges + 1;
                end
                prev = cur;
            end
            $display("  SCL edges: pre-trigger=%0d  post-trigger=%0d",
                     pre_edges, post_edges);
            if (pre_edges > 0 && post_edges > 0)
                $display("  [PASS] window spans the trigger point (both sides have bus activity)");
            else begin
                $display("  [FAIL] window does not span the trigger point");
                n_fail = n_fail + 1;
            end
        end

        // ---- 6. 协议解码确实在跑 ----
        $display("--- protocol decode wired ---");
        axi_read(8'h30, rv);
        $display("  PROTO_BYTE = 0x%h", rv[7:0]);
        axi_read(8'h34, rv);
        if (rv[0] === 1'b1) $display("  [PASS] PROTO_STAT.decoded_seen set");
        else begin
            $display("  [FAIL] protocol decoder produced no byte");
            n_fail = n_fail + 1;
        end

        // ---- 7. 统计模块确实在跑 ----
        $display("--- timing stats wired ---");
        axi_write(8'h38, 32'h2);        // 清空
        i = 0;
        while (i < 2000) begin
            axi_read(8'h04, rv);
            if (rv[3] === 1'b0) i = 99999; else i = i + 1;
        end
        axi_write(8'h38, 32'h0);
        axi_write(8'h38, 32'h1);        // 统计使能
        repeat (4000) @(posedge clk);   // 跑一段时间
        axi_write(8'h38, 32'h0);
        axi_read(8'h74, rv);
        $display("  n_width = %0d", rv);
        if (rv > 0) $display("  [PASS] timing_stats is counting");
        else begin
            $display("  [FAIL] timing_stats counted nothing");
            n_fail = n_fail + 1;
        end

        // 扫一次分位数
        axi_write(8'h38, 32'h4);
        i = 0;
        while (i < 5000) begin
            axi_read(8'h3C, rv);
            if (rv[2] === 1'b1) i = 99999; else i = i + 1;
        end
        if (i == 99999) begin
            axi_read(8'h4C, rv);
            $display("  [PASS] W_P50 = %0d clk", rv);
        end
        else begin
            $display("  [FAIL] percentile scan never finished");
            n_fail = n_fail + 1;
        end

        // ---- 8. 板内协议源自测（CTRL.bit3）：不接任何外部信号也能解码 ----
        $display("--- built-in I2C source (CTRL.bit3) ---");
        axi_write(8'h00, 32'h2);        // soft reset: clear PROTO_STAT sticky bits
        axi_write(8'h00, 32'h0);
        axi_write(8'h28, 32'd2);        // PROTO_SEL = I2C
        axi_write(8'h00, 32'hC);        // selftest on + protocol source -> CH4/CH5 = SCL/SDA
        repeat (20000) @(posedge clk);  // one I2C frame is about 11600 clk
        axi_read(8'h30, rv);
        $display("  PROTO_BYTE = 0x%h  (source sends A0 / 55 / AA)", rv[7:0]);
        if (rv[7:0] === 8'hA0 || rv[7:0] === 8'h55 || rv[7:0] === 8'hAA)
            $display("  [PASS] built-in I2C source decoded to a valid byte");
        else begin
            $display("  [FAIL] built-in I2C source not decoded");
            n_fail = n_fail + 1;
        end
        axi_read(8'h34, rv);
        if (rv[0] === 1'b1) $display("  [PASS] PROTO_STAT.decoded_seen set (bit3 path)");
        else begin
            $display("  [FAIL] bit3 path: decoder saw nothing");
            n_fail = n_fail + 1;
        end
        axi_write(8'h00, 32'h0);

        // ---- 9. free run（CTRL.bit4）：不触发也在写，供实时滚动显示 ----
        $display("--- free run mode (CTRL.bit4) ---");
        axi_write(8'h00, 32'h10);
        axi_read (8'h84, rv);
        i = rv[15:0];
        repeat (3000) @(posedge clk);
        axi_read (8'h84, rv);
        if (rv[15:0] != i[15:0])
            $display("  [PASS] WR_PTR advancing in free run (%0d -> %0d)", i[15:0], rv[15:0]);
        else begin
            $display("  [FAIL] WR_PTR frozen in free run (stuck at %0d)", rv[15:0]);
            n_fail = n_fail + 1;
        end
        axi_write(8'h00, 32'h0);

        // ---- 8. Pmod B 针 1 的 UART 源：回环到 CH0 能解出字节 ----
        $display("--- UART source on Pmod B pin1 (loopback to CH0) ---");
        axi_write(8'h00, 32'h20);       // CTRL.bit5 = 1，Pmod B 才驱动引脚
        axi_write(8'h28, 32'd0);        // PROTO_SEL = 0 -> UART
        axi_write(8'h2C, 32'd640);      // 位周期 640 clk（62.5MHz/640 ≈ 97.7 kbaud）
        uart_loop = 1'b1;
        seen_5a = 1'b0; seen_59 = 1'b0;
        for (k = 0; k < 700; k = k + 1) begin
            axi_read(8'h30, rv);
            if (rv[7:0] == 8'h50) seen_5a = 1'b1;    // 'P'
            if (rv[7:0] == 8'h59) seen_59 = 1'b1;    // 'Y'
            repeat (400) @(posedge clk);
        end
        if (seen_5a && seen_59)
            $display("  [PASS] decoded 'P' and 'Y' from Pmod B UART source");
        else begin
            $display("  [FAIL] UART decode missing ('P'=%b 'Y'=%b)", seen_5a, seen_59);
            n_fail = n_fail + 1;
        end

        // ---- 9. Pmod B 针 7/8 的 I2C 源：回环到 CH4/CH5 能解出 A0/55/AA ----
        // 这一项的用意：现场要插的正是这两根线，仿真先把"引脚 -> 解码器"这段证掉
        $display("--- I2C source on Pmod B pin7/8 (loopback to CH4/CH5) ---");
        uart_loop = 1'b0;
        i2c_loop  = 1'b1;
        axi_write(8'h00, 32'h20);       // CTRL.bit5 = 1 -> Pmod B 驱动引脚
        axi_write(8'h28, 32'd2);        // PROTO_SEL = 2 -> I2C
        seen_a0 = 1'b0; seen_55 = 1'b0; seen_aa = 1'b0;
        for (k = 0; k < 700; k = k + 1) begin
            axi_read(8'h30, rv);
            if (rv[7:0] == 8'hA0) seen_a0 = 1'b1;
            if (rv[7:0] == 8'h55) seen_55 = 1'b1;
            if (rv[7:0] == 8'hAA) seen_aa = 1'b1;
            repeat (200) @(posedge clk);
        end
        if (seen_a0 && seen_55 && seen_aa)
            $display("  [PASS] decoded A0/55/AA through Pmod B pin7/8 -> CH4/CH5");
        else begin
            $display("  [FAIL] I2C loopback missing (A0=%b 55=%b AA=%b)",
                     seen_a0, seen_55, seen_aa);
            n_fail = n_fail + 1;
        end
        i2c_loop = 1'b0;

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_la_top END ===========");
        $finish;
    end

endmodule
