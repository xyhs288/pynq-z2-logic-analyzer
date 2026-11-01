// =====================================================================
//  din_sync.v —— 8 路输入两级同步
//
//  外部信号与 clk 没有相位关系，直接采会出亚稳态（触发器输出悬在
//  0 和 1 之间，下游不同触发器可能收到不同值，波形随机乱跳）。
//  打两拍之后，亚稳态在第一级被消化掉，第二级输出是干净的。
//
//  注意：本模块跑【自由运行的时钟】，不是采样节拍。
//  采样节拍在别处用 smp_en 去锁存 dout。
//
//  负责人：A（这个模块答辩必问，要能自己默写出来）
// =====================================================================

`timescale 1ns / 1ps

module din_sync (
    input  wire       clk,       // FCLK_CLK0 = 62.5 MHz，自由运行
    input  wire       rst_n,
    input  wire [7:0] din,       // 来自 Pmod A 的 8 路原始输入
    output wire [7:0] dout       // 同步后的 8 路
);

    reg [7:0] d0;
    reg [7:0] d1;

    always @(posedge clk) begin
        if (!rst_n) begin
            d0 <= 8'd0;
            d1 <= 8'd0;
        end
        else begin
            d0 <= din;   // 第一级：可能进亚稳态，所以后面只用 d1
            d1 <= d0;    // 第二级：输出干净
        end
    end

    assign dout = d1;

endmodule
