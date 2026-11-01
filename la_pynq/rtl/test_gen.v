// =====================================================================
//  test_gen.v —— 内置信号源（自测用）
//
//  产生 8 路频率依次减半的方波，作为已知信号送给采集通路自测。
//  8 路频率各不相同，所以万一通道顺序接错，从数据上一眼就能看出来。
//
//  各路频率 = clk / 2^(27-i)，依次倍增
//  （clk = 62.5 MHz 时约 0.47 Hz ~ 59.6 Hz）
//
//  负责人：C
// =====================================================================

`timescale 1ns / 1ps

module test_gen #(
    parameter integer MSB = 26     // 计数器最高位位置，决定各路频率（MSB 越小频率越高）
)(
    input  wire       clk,       // FCLK_CLK0 = 62.5 MHz
    input  wire       rst_n,
    output wire [7:0] sig_out
);

    reg [MSB:0] cnt;

    always @(posedge clk) begin
        if (!rst_n) cnt <= {(MSB+1){1'b0}};
        else        cnt <= cnt + 1'b1;
    end

    // 每一路取计数器的不同位，频率正好依次减半
    assign sig_out[0] = cnt[MSB];
    assign sig_out[1] = cnt[MSB-1];
    assign sig_out[2] = cnt[MSB-2];
    assign sig_out[3] = cnt[MSB-3];
    assign sig_out[4] = cnt[MSB-4];
    assign sig_out[5] = cnt[MSB-5];
    assign sig_out[6] = cnt[MSB-6];
    assign sig_out[7] = cnt[MSB-7];

endmodule
