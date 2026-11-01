// =====================================================================
//  stage2_top.v —— 第二阶段板内验证顶层（触发状态机）
//
//  通路：test_gen -> din_sync -> trig_fsm
//
//  采样率故意调慢到 10kHz（div=12500），让状态机的时间行为肉眼可见。
//
//  四个 LED：
//    led[0] = ARMED   已布防，等待触发条件
//    led[1] = TRIG'D  已触发，正在写触发点之后的数据
//    led[2] = FULL    抓取完成
//    led[3] = 采集期间的心跳，FULL 之后【冻结不动】
//
//  预期现象：
//    上电后       -> led[0] 亮，led[3] 开始闪
//    最多 1.1 秒后 -> led[1] 也亮（CH0 上升沿到来）
//    约 4.9 秒后   -> led[2] 亮，led[0]/led[1] 灭，led[3] 冻结
//
//  重新开始：按住 BTN0（板上有 4 个按钮，BTN0 在 D19）。
//  按住期间状态回到 IDLE，松手后重新布防。
//  【不要用 PROG 或 SRST 按钮】—— 它们只会把 PL 清空，不会重跑设计。
// =====================================================================

`timescale 1ns / 1ps

module stage2_top (
    input  wire       sys_clk,   // 125 MHz
    input  wire       btn0,      // BTN0 (D19)，按下为高电平：重新布防
    output wire [3:0] led
);

    reg [11:0] rst_cnt = 12'd0;
    wire       rst_n   = (rst_cnt == 12'd4095);

    always @(posedge sys_clk) begin
        if (!rst_n) rst_cnt <= rst_cnt + 12'd1;
    end

    // 内置信号源
    wire [7:0] tg_out;

    test_gen u_test_gen (
        .clk     (sys_clk),
        .rst_n   (rst_n),
        .sig_out (tg_out)
    );

    // 两级同步
    wire [7:0] din_synced;

    din_sync u_din_sync (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .din   (tg_out),
        .dout  (din_synced)
    );

    // 采样节拍：125MHz / 12500 = 10kHz
    wire smp_en;

    smp_clk_div u_smp_clk_div (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .div    (16'd12500),
        .smp_en (smp_en)
    );

    // BTN0 两级同步（按键是异步输入）
    reg btn_d0, btn_d1;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            btn_d0 <= 1'b0;
            btn_d1 <= 1'b0;
        end
        else begin
            btn_d0 <= btn0;
            btn_d1 <= btn_d0;
        end
    end

    // 触发状态机：上电即布防，盯 CH0 的上升沿
    wire armed, trigged, full, cap_en;

    trig_fsm #(
        .DEPTH    (65536),
        .PRE_TRIG (16384)
    ) u_trig_fsm (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .arm        (1'b1),
        .restart    (btn_d1),
        .smp_en     (smp_en),
        .din        (din_synced),
        .trig_chan  (3'd0),
        .trig_mode  (2'd0),
        .trig_src   (1'b0),
        .ext_trig   (1'b0),
        .pre_trig_cfg(PRE_TRIG),
        .armed      (armed),
        .trigged    (trigged),
        .full       (full),
        .cap_en     (cap_en),
        .trig_pulse ()
    );

    // 采集期间的心跳：FULL 之后 cap_en 为 0，计数冻结
    reg [12:0] beat;

    always @(posedge sys_clk) begin
        if (!rst_n)                   beat <= 13'd0;
        else if (cap_en && smp_en)    beat <= beat + 13'd1;
    end

    assign led[0] = armed;
    assign led[1] = trigged;
    assign led[2] = full;
    assign led[3] = beat[12];

endmodule
