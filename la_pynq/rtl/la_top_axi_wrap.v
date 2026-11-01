// =====================================================================
//  la_top_axi_wrap.v —— 给 la_top 套一层标准 AXI4-Lite 端口名
//
//  为什么需要它：
//    Vivado 的 block design "module reference" 靠端口命名自动推断总线接口。
//    la_top 的 AXI 端口叫 s_awaddr / s_rready ...，命名不符合 AXI 约定，
//    推不出接口。这一层只做两件事：
//      1. 把端口名改成标准的 s_axi_*
//      2. 地址位宽从 8 位抬到 32 位（内部截低 8 位给 la_top，地址译码不变）
//    la_top 本身一行不改。
//
//  注意（踩过坑）：
//    时钟端口必须叫 **s_axi_aclk**。Vivado 的 module reference 靠端口名做接口
//    推断，只有 s_axi_aclk 才会被自动关联到 s_axi 接口上。如果叫 sys_clk，
//    接口推得出来但"没有关联时钟"（BD 41-2265 / IP_Flow 19-3158），
//    结果是插入的协议转换器时钟接不上，PS 一访问就永久等不到响应 ——
//    整颗芯片会被卡死，连网口都不通，只能断电重启。
//
//  负责人：A（集成）
// =====================================================================

`timescale 1ns / 1ps

module la_top_axi_wrap #(
    parameter integer DEPTH = 8192,
    parameter integer NBINS = 256,
    parameter integer SHIFT = 4
)(
    input  wire        s_axi_aclk,   // FCLK_CLK0 = 62.5 MHz，来自 PS
    input  wire        btn0,         // BTN0 = D19，按下重新布防
    input  wire [7:0]  ch_in,        // Pmod A 八路输入
    output wire [3:0]  led,
    output wire [7:0]  sig_out,      // Pmod B 八路输出（板子自己发的方波）

    // ---- AXI4-Lite 从机（标准端口名 + 32 位地址）----
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready
);

    la_top #(
        .DEPTH (DEPTH),
        .NBINS (NBINS),
        .SHIFT (SHIFT),
        .AW    (8)
    ) u_la_top (
        .sys_clk   (s_axi_aclk),        .btn0      (btn0),
        .ch_in     (ch_in),
        .led       (led),
        .sig_out   (sig_out),

        .s_awaddr  (s_axi_awaddr[7:0]),
        .s_awvalid (s_axi_awvalid),
        .s_awready (s_axi_awready),
        .s_wdata   (s_axi_wdata),
        .s_wstrb   (s_axi_wstrb),
        .s_wvalid  (s_axi_wvalid),
        .s_wready  (s_axi_wready),
        .s_bresp   (s_axi_bresp),
        .s_bvalid  (s_axi_bvalid),
        .s_bready  (s_axi_bready),

        .s_araddr  (s_axi_araddr[7:0]),
        .s_arvalid (s_axi_arvalid),
        .s_arready (s_axi_arready),
        .s_rdata   (s_axi_rdata),
        .s_rresp   (s_axi_rresp),
        .s_rvalid  (s_axi_rvalid),
        .s_rready  (s_axi_rready)
    );

endmodule
