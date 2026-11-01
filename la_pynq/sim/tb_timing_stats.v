// =====================================================================
//  tb_timing_stats.v —— 时序参数统计自检
//
//  激励是一串【宽度和周期都完全已知】的脉冲：
//      64 个脉冲，宽度循环 4/8/16/64 clk（40:16:6:2 的分布），
//      低电平间隔固定 100 clk，所以周期 = 宽度 + 100。
//
//  因为是精确已知的图案，每一项都能算出精确的期望值：
//      宽度样本数 64、周期样本数 63（第一个上升沿没有前一个参考）
//      宽度 min/max = 4 / 64，周期 min/max = 104 / 164
//      宽度直方图 : bin1=40 bin2=16 bin4=6 bin16=2       (SHIFT=2 -> 桶宽 4)
//      周期直方图 : bin26=40 bin27=16 bin29=6 bin41=1
//      分位数      : 宽度 P50/P95/P99 = 6 / 18 / 66
//                    周期 P50/P95/P99 = 106 / 118 / 166
//
//  ⚠️ 周期的边界容易数错：第 i 个脉冲的周期 = 第 i-1 个脉冲的宽度 + gap，
//     所以周期 104 对应 i=1..40（40 个），周期 164 只对应 i=63（1 个）。
// =====================================================================

`timescale 1ns / 1ps

module tb_timing_stats;

    localparam integer NBINS = 256;
    localparam integer SHIFT = 2;
    localparam integer GAP   = 100;      // 低电平间隔（clk）
    localparam integer NP    = 64;       // 脉冲总数
    localparam integer NWR   = 40;       // 宽度 4 的个数
    localparam integer NW8   = 16;       // 宽度 8
    localparam integer NW16  = 6;        // 宽度 16
    localparam integer NW64  = 2;        // 宽度 64

    reg clk = 1'b0;
    always #4 clk = ~clk;                // 8ns -> 125MHz

    reg        rst_n = 1'b0;
    reg        en    = 1'b0;
    reg        clr   = 1'b0;
    reg        sig   = 1'b0;
    reg [7:0]  rd_bin = 8'd0;
    reg        pct_req = 1'b0;

    wire [31:0] rd_w_cnt, rd_p_cnt;
    wire        clr_busy;
    wire [31:0] n_width, n_pulse, w_min, w_max, p_min, p_max, sat_cnt, drop_cnt;
    wire        pct_busy, pct_valid;
    wire [31:0] w_p50, w_p95, w_p99, p_p50, p_p95, p_p99;

    timing_stats #(.NBINS(NBINS), .SHIFT(SHIFT)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .clr       (clr),
        .sig       (sig),
        .rd_bin    (rd_bin),
        .rd_w_cnt  (rd_w_cnt),
        .rd_p_cnt  (rd_p_cnt),
        .clr_busy  (clr_busy),
        .n_width   (n_width),
        .n_pulse   (n_pulse),
        .w_min     (w_min),
        .w_max     (w_max),
        .p_min     (p_min),
        .p_max     (p_max),
        .sat_cnt   (sat_cnt),
        .drop_cnt  (drop_cnt),
        .pct_req   (pct_req),
        .pct_busy  (pct_busy),
        .pct_valid (pct_valid),
        .w_p50     (w_p50), .w_p95 (w_p95), .w_p99 (w_p99),
        .p_p50     (p_p50), .p_p95 (p_p95), .p_p99 (p_p99)
    );

    integer n_fail = 0;
    integer i, b, w;
    integer t_wait;

    // ---- 期望值表 ----
    reg [31:0] exp_w_bin [0:3];
    reg [31:0] exp_w_val [0:3];
    reg [7:0]  exp_p_bin [0:3];
    reg [31:0] exp_p_val [0:3];

    initial begin
        exp_w_bin[0]=32'd1;  exp_w_val[0]=32'd40;
        exp_w_bin[1]=32'd2;  exp_w_val[1]=32'd16;
        exp_w_bin[2]=32'd4;  exp_w_val[2]=32'd6;
        exp_w_bin[3]=32'd16; exp_w_val[3]=32'd2;
        exp_p_bin[0]=8'd26;  exp_p_val[0]=32'd40;
        exp_p_bin[1]=8'd27;  exp_p_val[1]=32'd16;
        exp_p_bin[2]=8'd29;  exp_p_val[2]=32'd6;
        exp_p_bin[3]=8'd41;  exp_p_val[3]=32'd1;
    end

`ifdef WAVE_MODE
    integer csv_fd;
`endif

    initial begin
        #5000000;
        $display("[FAIL] TIMEOUT");
        $display("RESULT: FAIL    (timeout)");
        $finish;
    end

    // ---- 读一个桶 ----
    task read_bin(input [7:0] bi, output [31:0] wv, output [31:0] pv);
        begin
            @(negedge clk); rd_bin = bi;
            @(posedge clk);
            @(negedge clk); wv = rd_w_cnt; pv = rd_p_cnt;
        end
    endtask

    task chk32(input [127:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("  [FAIL] %0s : got %0d, want %0d", name, got, want);
                n_fail = n_fail + 1;
            end
            else $display("  [PASS] %0s = %0d", name, got);
        end
    endtask

    reg [31:0] gw, gp;

    initial begin
        $display("=========== tb_timing_stats START ===========");
        $display("NBINS=%0d  SHIFT=%0d  gap=%0d clk  pulses=%0d", NBINS, SHIFT, GAP, NP);

        rst_n = 1'b0; en = 1'b0; clr = 1'b0; sig = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- 0. 先清空一次，验证清空引擎 ----
        clr = 1'b1;
        @(negedge clk);
        clr = 1'b0;
        wait (clr_busy === 1'b0);
        repeat (4) @(posedge clk);
        $display("[PASS] clear engine completed");

        // ---- 1. 产生 64 个已知脉冲 ----
        en = 1'b1;
        for (i = 0; i < NP; i = i + 1) begin
            if      (i < NWR)             w = 4;
            else if (i < NWR + NW8)       w = 8;
            else if (i < NWR + NW8 + NW16) w = 16;
            else                           w = 64;

            @(negedge clk); sig = 1'b1;
            repeat (w) @(negedge clk);
            sig = 1'b0;
            repeat (GAP) @(negedge clk);
        end
        en = 1'b0;

        // 等更新引擎把待处理事件做完
        repeat (60) @(posedge clk);

        // ---- 2. 样本数与极值 ----
        $display("--- counts and extremes ---");
        chk32("n_width       ", n_width, NP);
        chk32("n_pulse       ", n_pulse, NP - 1);
        chk32("w_min         ", w_min,   32'd4);
        chk32("w_max         ", w_max,   32'd64);
        chk32("p_min         ", p_min,   32'd104);
        chk32("p_max         ", p_max,   32'd164);
        chk32("sat_cnt (0)   ", sat_cnt, 32'd0);
        chk32("drop_cnt (0)  ", drop_cnt, 32'd0);

        // ---- 3. 直方图逐桶核对 ----
        $display("--- width histogram ---");
        for (b = 0; b < 4; b = b + 1) begin
            read_bin(exp_w_bin[b][7:0], gw, gp);
            chk32("w_bin", gw, exp_w_val[b]);
        end

        $display("--- period histogram ---");
        for (b = 0; b < 4; b = b + 1) begin
            read_bin(exp_p_bin[b], gw, gp);
            chk32("p_bin", gp, exp_p_val[b]);
        end

        // ---- 4. 分位数扫描 ----
        @(negedge clk);
        pct_req = 1'b1;
        @(negedge clk);
        pct_req = 1'b0;
        t_wait = 0;
        while (!pct_valid && t_wait < 5000) begin
            @(posedge clk);
            t_wait = t_wait + 1;
        end

        if (!pct_valid) begin
            $display("[FAIL] percentile scan never finished");
            n_fail = n_fail + 1;
        end
        else begin
            $display("--- percentiles (scan took %0d clk) ---", t_wait);
            chk32("width  P50    ", w_p50, 32'd6);
            chk32("width  P95    ", w_p95, 32'd18);
            chk32("width  P99    ", w_p99, 32'd66);
            chk32("period P50    ", p_p50, 32'd106);
            chk32("period P95    ", p_p95, 32'd118);
            chk32("period P99    ", p_p99, 32'd166);
        end

`ifdef WAVE_MODE
        csv_fd = $fopen("tb_timing_stats_hist.csv", "w");
        $fwrite(csv_fd, "bin,width_cnt,period_cnt\n");
        for (b = 0; b < NBINS; b = b + 1) begin
            read_bin(b[7:0], gw, gp);
            $fwrite(csv_fd, "%0d,%0d,%0d\n", b, gw, gp);
        end
        $fclose(csv_fd);
        $display("histogram dumped to tb_timing_stats_hist.csv");
`endif

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_timing_stats END ===========");
        $finish;
    end

endmodule
