// =====================================================================
//  tb_trig_fsm.v —— trig_fsm 自检 testbench
//
//  跑完直接打印 PASS/FAIL，不需要人工看波形。
//
//  验证四件事：
//    1. 状态序列 IDLE -> ARMED -> TRIG -> FULL
//    2. 触发后写入的采样拍数 == DEPTH-PRE_TRIG（预触发计数的核心）
//    3. 触发 -> FULL 的耗时 == 拍数 x 采样周期
//    4. restart 能把状态拉回 IDLE 并重新布防（对应板上 BTN0）
//
//  触发信号由本 testbench 自行制造（真实在确定时刻产生上升沿），
//  不用 test_gen 的慢计数器，否则仿真时间会长到跑不动。
// =====================================================================

`timescale 1ns / 1ps

module tb_trig_fsm;

`ifdef WAVE_MODE
    // ---- 波形模式：参数缩到最小，波形窗口只有十几微秒，肉眼能看 ----
    localparam integer DIV        = 4;        // 采样节拍 4 个时钟一次
    localparam integer DEPTH      = 512;
    localparam integer PRE_TRIG   = 128;
    localparam integer WAIT_NS    = 20000;    // 波形模式下这里早就跑完了
`else
    // ---- 验证模式：真实参数，只输出 PASS/FAIL ----
    localparam integer DIV        = 125;      // 采样率 125MHz/125 = 1MHz
    localparam integer DEPTH      = 65536;
    localparam integer PRE_TRIG   = 16384;
    localparam integer WAIT_NS    = 52000000; // 49152 x 125 x 8ns = 49.152ms，留余量
`endif

    localparam integer POST_LIMIT = DEPTH - PRE_TRIG;

    reg clk = 1'b0;
    always #4 clk = ~clk;                                 // 8ns -> 125MHz

    reg rst_n = 1'b0;

    // 采样节拍
    reg [15:0] div_cnt = 16'd0;
    reg        smp_en  = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt <= 16'd0;
            smp_en  <= 1'b0;
        end
        else if (div_cnt == DIV - 1) begin
            div_cnt <= 16'd0;
            smp_en  <= 1'b1;
        end
        else begin
            div_cnt <= div_cnt + 16'd1;
            smp_en  <= 1'b0;
        end
    end

    // 被测输入
    reg [7:0] din      = 8'h00;
    reg       arm      = 1'b1;
    reg       restart  = 1'b0;
    reg       trig_src = 1'b0;      // 0=内部边沿，1=外部协议脉冲
    reg       ext_trig = 1'b0;

    wire armed, trigged, full, cap_en, trig_pulse;

    trig_fsm #(
        .DEPTH    (DEPTH),
        .PRE_TRIG (PRE_TRIG)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .arm        (arm),
        .restart    (restart),
        .smp_en     (smp_en),
        .din        (din),
        .trig_chan  (3'd0),
        .trig_mode  (2'd0),
        .trig_src   (trig_src),
        .ext_trig   (ext_trig),
        .pre_trig_cfg(PRE_TRIG),
        .armed      (armed),
        .trigged    (trigged),
        .full       (full),
        .cap_en     (cap_en),
        .trig_pulse (trig_pulse)
    );

    // ---- 观测 ----
    integer pre_ticks  = 0;
    integer post_ticks = 0;
    integer t_trig     = 0;
    integer t_full     = 0;
    integer n_fail     = 0;
    integer elapsed    = 0;
    integer expected   = 0;

    reg got_trig = 1'b0;
    reg got_full = 1'b0;

`ifdef WAVE_MODE
    // ---- 波形数据导出：每个时钟沿写一行，供脚本画图 ----
    integer csv_fd;
    initial begin
        csv_fd = $fopen("tb_trig_fsm.csv", "w");
        $fwrite(csv_fd, "t_ns,smp_en,din0,state,post_cnt,armed,trigged,full,cap_en,trig_pulse\n");
    end

    always @(posedge clk) begin
        $fwrite(csv_fd, "%0d,%b,%b,%0d,%0d,%b,%b,%b,%b,%b\n",
                $time, smp_en, din[0], dut.state, dut.post_cnt,
                armed, trigged, full, cap_en, trig_pulse);
    end
`endif

    // 状态变化打印
    reg [2:0] st_q = 3'b000;

    always @(posedge clk) begin
        if ({full, trigged, armed} !== st_q) begin
            $display("T=%0d ns   STATE   armed=%b trigged=%b full=%b",
                     $time, armed, trigged, full);
            st_q <= {full, trigged, armed};
        end
    end

    // 采样拍计数：数状态为 ARMED / TRIG 的周期里出现多少次 smp_en
    always @(posedge clk) begin
        if (armed   && smp_en) pre_ticks  = pre_ticks  + 1;
        if (trigged && smp_en) post_ticks = post_ticks + 1;
    end

    always @(posedge clk) begin
        if (trig_pulse && !got_trig) begin
            got_trig = 1'b1;
            t_trig   = $time;
            $display("T=%0d ns   === TRIGGER PULSE ===   pre_ticks=%0d", $time, pre_ticks);
        end
        if (full && !got_full) begin
            got_full = 1'b1;
            t_full   = $time;
            $display("T=%0d ns   === FULL ===            post_ticks=%0d", $time, post_ticks);
        end
    end

    // ---- 主流程 ----
    initial begin
        $display("=========== tb_trig_fsm START ===========");
        $display("DIV=%0d  DEPTH=%0d  PRE_TRIG=%0d  POST_LIMIT=%0d",
                 DIV, DEPTH, PRE_TRIG, POST_LIMIT);

        rst_n = 1'b0;
        #200;
        rst_n = 1'b1;

        // 制造 CH0 上升沿
        #2000;
        din = 8'h01;

        #WAIT_NS;

        $display("-----------------------------------------");

        if (!got_trig) begin
            $display("[FAIL] no trigger detected");
            n_fail = n_fail + 1;
        end
        if (!got_full) begin
            $display("[FAIL] never reached FULL");
            n_fail = n_fail + 1;
        end

        $display("pre_ticks  = %0d", pre_ticks);
        $display("post_ticks = %0d    (expect %0d)", post_ticks, POST_LIMIT);

        if (post_ticks == POST_LIMIT)
            $display("[PASS] post-trigger write count == DEPTH-PRE_TRIG");
        else begin
            $display("[FAIL] post-trigger write count WRONG");
            n_fail = n_fail + 1;
        end

        elapsed  = t_full - t_trig;
        expected = POST_LIMIT * DIV * 8;
        $display("elapsed    = %0d ns   (expect %0d ns)", elapsed, expected);

        // 容差 = 1 个采样周期。t_trig / t_full 都是本 testbench 在时钟沿观测到的，
        // 与状态机内部翻转的时刻隔着 NBA 提交，天然有 1-2 个时钟的观测延迟。
        if (elapsed >= expected - DIV * 8 && elapsed <= expected + DIV * 8)
            $display("[PASS] trigger-to-FULL elapsed time OK");
        else begin
            $display("[FAIL] trigger-to-FULL elapsed time WRONG");
            n_fail = n_fail + 1;
        end

        if (armed || trigged) begin
            $display("[FAIL] after FULL, armed/trigged must be 0");
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");

        // ---- 测 restart（对应板上 BTN0）----
        restart = 1'b1;
        #100;
        if (!full && !armed && !trigged)
            $display("[PASS] restart pressed -> back to IDLE");
        else begin
            $display("[FAIL] restart had no effect: armed=%b trigged=%b full=%b",
                     armed, trigged, full);
            n_fail = n_fail + 1;
        end

        restart = 1'b0;
        #100;
        if (armed)
            $display("[PASS] restart released -> re-armed (ARMED)");
        else begin
            $display("[FAIL] did not return to ARMED after release");
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");

        // ---- 测外部触发源（协议匹配脉冲，trig_src=1）----
        // din 故意保持不动，证明这次触发完全来自 ext_trig，
        // 而且没被 din 上的任何电平/边沿带偏。
        restart  = 1'b1;
        #100;
        restart  = 1'b0;
        trig_src = 1'b1;
        din      = 8'h00;
        #(DIV * 8 * 4);

        if (!trigged)
            $display("[PASS] armed with ext trigger source, not triggered by din");
        else begin
            $display("[FAIL] triggered by din while trig_src=1");
            n_fail = n_fail + 1;
        end

        #(DIV * 8 * 2);
        @(negedge clk);
        ext_trig = 1'b1;
        @(negedge clk);
        ext_trig = 1'b0;
        #(DIV * 8);

        if (trigged || full)
            $display("[PASS] external pulse triggered the FSM");
        else begin
            $display("[FAIL] external trigger pulse had no effect");
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_trig_fsm END ===========");
`ifdef WAVE_MODE
        $fclose(csv_fd);
`endif
        $finish;
    end

endmodule
