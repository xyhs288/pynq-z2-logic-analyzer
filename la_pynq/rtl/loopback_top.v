// =====================================================================
//  loopback_top.v —— 板内环回验收顶层
//
//  用途：不接任何外部器件，把 test_gen 的输出直接接进采集通路，
//        验证「信号源 -> 同步 -> 采样节拍锁存」这条链是通的。
//
//  通路：
//    test_gen --> din_sync --> (smp_en 锁存) --> cap_data --> LED
//
//  四个 LED：
//    led[0] = 采集到的 CH0，约 0.93 Hz
//    led[1] = 信号源原始 CH0，约 0.93 Hz   <-- 应与 led[0] 同步闪烁
//    led[2] = 采集到的 CH3，约 7.5 Hz
//    led[3] = 采样节拍心跳，约 3.8 Hz
//
//  判据：led[0] 与 led[1] 同步闪烁 = 采集通路工作正常。
//        led[0] 恒灭 = 没采到数据。
//
//  这是临时验收顶层，不是最终作品（最终顶层是 la_top）。
// =====================================================================

`timescale 1ns / 1ps

module loopback_top (
    input  wire       sys_clk,   // 125 MHz
    output wire [3:0] led
);

    // 上电复位：数到 4095 释放，约 33 微秒
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

    // 同步：板内环回，直接把自测信号接进来
    wire [7:0] din_synced;

    din_sync u_din_sync (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .din   (tg_out),
        .dout  (din_synced)
    );

    // 采样节拍
    wire smp_en;

    smp_clk_div u_smp_clk_div (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .div    (16'd125),          // 125MHz / 125 = 1MHz
        .smp_en (smp_en)
    );

    // 采样锁存：每个采样节拍把同步后的数据锁一次
    reg [7:0] cap_data;

    always @(posedge sys_clk) begin
        if (smp_en) cap_data <= din_synced;
    end

    // 采样节拍计数，用来看节拍器是不是在跑
    reg [19:0] beat_cnt;

    always @(posedge sys_clk) begin
        if (!rst_n)      beat_cnt <= 20'd0;
        else if (smp_en) beat_cnt <= beat_cnt + 20'd1;
    end

    assign led[0] = cap_data[0];
    assign led[1] = tg_out[0];
    assign led[2] = cap_data[3];
    assign led[3] = beat_cnt[17];

endmodule
