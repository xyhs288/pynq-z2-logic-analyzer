// =====================================================================
//  smp_clk_div.v —— 采样节拍分频器
//
//  每 div 个时钟产生一个单周期脉冲 smp_en，作为全设计的采样节拍。
//  采样率 = clk / div（本板 clk = FCLK_CLK0 = 62.5 MHz）
//
//  用脉冲而不是分频时钟：全设计只有一个时钟域，
//  所有模块跑同一个时钟，采样时刻靠 smp_en 控制。
//  这样不用做跨时钟域处理，时序也更好收敛。
//
//  负责人：A
// =====================================================================

`timescale 1ns / 1ps

module smp_clk_div (
    input  wire        clk,       // FCLK_CLK0 = 62.5 MHz
    input  wire        rst_n,
    input  wire [31:0] div,       // 分频系数，0 按 1 处理
    output reg         smp_en     // 单周期脉冲
);

    reg [31:0] cnt;

    // div 写 0 会减出负数，这里保护一下
    wire [31:0] div_i = (div == 32'd0) ? 32'd1 : div;

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt    <= 32'd0;
            smp_en <= 1'b0;
        end
        else if (cnt >= div_i - 32'd1) begin
            cnt    <= 32'd0;
            smp_en <= 1'b1;
        end
        else begin
            cnt    <= cnt + 32'd1;
            smp_en <= 1'b0;
        end
    end

endmodule
