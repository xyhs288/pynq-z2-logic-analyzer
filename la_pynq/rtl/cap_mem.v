// =====================================================================
//  cap_mem.v —— 片内 BRAM 环形缓冲
//
//  写：cap_en 有效时，每个 smp_en 写入一个 8-bit 采样值，地址自动回绕
//  停：cap_en 落下的那一刻锁存 wr_ptr 到 stop_ptr，即最老数据的位置
//  读：给物理地址，1 拍后出数据
//
//  负责人：B
// =====================================================================

`timescale 1ns / 1ps

module cap_mem #(
    parameter integer DEPTH = 65536,   // 采样深度
    parameter integer AW    = 16       // 地址位宽 = log2(DEPTH)
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          cap_en,     // 写使能，来自 trig_fsm
    input  wire          smp_en,     // 采样节拍（单拍脉冲）
    input  wire [7:0]    din,        // 8 路输入
    input  wire [AW-1:0] rd_addr,    // 读地址（物理地址）
    input  wire          rd_en,      // 读使能
    output reg  [7:0]    rd_data,    // 读数据
    output reg  [AW-1:0] wr_ptr,     // 当前写指针
    output reg  [AW-1:0] stop_ptr    // 冻结时的写指针 = 最老数据位置
);

    (* ram_style = "block" *)
    reg [7:0] mem [0:DEPTH-1];

    wire we = cap_en & smp_en;

    always @(posedge clk) begin
        if (we) mem[wr_ptr] <= din;
    end

    always @(posedge clk) begin
        if (!rst_n)                    wr_ptr <= {AW{1'b0}};
        else if (we)                   wr_ptr <= wr_ptr + 1'b1;   // 位宽决定自动回绕
    end

    always @(posedge clk) begin
        if (!rst_n)      stop_ptr <= {AW{1'b0}};
        else if (!cap_en) stop_ptr <= wr_ptr;                     // 只在停下的那一刻锁存
    end

    always @(posedge clk) begin
        if (rd_en) rd_data <= mem[rd_addr];
    end

endmodule
