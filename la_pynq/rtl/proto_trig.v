// =====================================================================
//  proto_trig.v —— 协议内容触发
//
//  把解码器解出来的字节和设定的值比较，相等就输出一个触发脉冲。
//  这样触发状态机就会"等总线上出现特定字节才开始抓"。
//
//  为什么这件事只能由 PL 做：数据是【触发之后】才有的，
//  所以解码必须在触发通路上。放 PS 里就是鸡生蛋，永远转不起来。
//
//  en = 0 时退化为"任意字节都触发"，方便现场演示对比。
//
//  负责人：C
// =====================================================================

`timescale 1ns / 1ps

module proto_trig (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       en,           // 1 = 匹配 match_val；0 = 任意字节
    input  wire [7:0] match_val,    // 目标字节
    input  wire [7:0] data,         // 解码器输出字节
    input  wire       data_valid,   // 解码器 valid（单拍脉冲）
    output reg        trig_pulse
);

    wire hit = data_valid & (en ? (data == match_val) : 1'b1);

    always @(posedge clk) begin
        if (!rst_n) trig_pulse <= 1'b0;
        else        trig_pulse <= hit;
    end

endmodule
