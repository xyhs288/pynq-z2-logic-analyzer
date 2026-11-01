// =====================================================================
//  clkmon.v —— 被测时钟的停振检测（临时验证模块，不属于作品）
//
//  原理：
//    被测时钟 test_clk（H16，125MHz，来自以太网 PHY）跑一个自由计数器；
//    AXI 侧用 PS 的 FCLK（稳定、与 PHY 无关）把计数器高位同步过来，
//    并统计"同步值连续多久没变化"的最大值 —— 那就是最长停振时间。
//
//  AXI 故意挂在稳定的 FCLK 上：即使被测时钟停了，AXI 也还活着，
//  PS 才能把结果读出来（若两者同源，时钟一停连读数都读不到）。
//
//  寄存器（低 8 位地址译码，AXI 地址位宽 32）：
//    0x00 RO  CNT_HI     c125[31:4]<<4，单位 16 个被测时钟 = 128 ns
//    0x04 RO  STALL_MAX  最长停振，单位 AXI 时钟周期
//    0x08 RO  STALL      当前停振计数
//    0x0C WO  CTRL       写 bit0=1 -> 清 STALL / STALL_MAX
//    0x10 RO  MAGIC      0x12345678，用于确认 AXI 通路本身是活的
// =====================================================================

`timescale 1ns / 1ps

module clkmon (
    input  wire        s_axi_aclk,      // 稳定时钟（PS FCLK）
    input  wire        s_axi_aresetn,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    input  wire        test_clk,        // 被测时钟（H16）
    output wire [3:0]  dbg_led          // 被测时钟在跑就闪烁
);

    // ================= 被测时钟域：自由计数器 =================
    reg [31:0] c125;
    always @(posedge test_clk) c125 <= c125 + 32'd1;

    assign dbg_led = c125[25:22];

    // ================= 同步到 AXI 域（只同步高 28 位）=================
    // 低 4 位每个被测时钟就变，同步过来是垃圾；高 28 位每 16 拍才变，2 拍同步够用
    reg [27:0] sy1, sy2;
    always @(posedge s_axi_aclk) begin
        sy1 <= c125[31:4];
        sy2 <= sy1;
    end

    // ================= 停振检测 =================
    reg [27:0] sy2_d;
    reg        seen;
    reg [31:0] stall, stall_max;
    reg        clr;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            sy2_d     <= 28'd0;
            seen      <= 1'b0;
            stall     <= 32'd0;
            stall_max <= 32'd0;
        end
        else if (clr) begin
            stall     <= 32'd0;
            stall_max <= 32'd0;
            seen      <= 1'b0;
        end
        else if (sy2 != sy2_d) begin
            if (seen && stall > stall_max) stall_max <= stall;
            stall <= 32'd0;
            sy2_d <= sy2;
            seen  <= 1'b1;
        end
        else begin
            stall <= stall + 32'd1;
        end
    end

    // ================= AXI 写通道 =================
    reg [1:0]  wst;
    reg [7:0]  awaddr_r;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            wst           <= 2'd0;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            awaddr_r      <= 8'd0;
            clr           <= 1'b0;
        end
        else begin
            clr <= 1'b0;
            case (wst)
                2'd0: begin
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        s_axi_awready <= 1'b1;
                        s_axi_wready  <= 1'b1;
                        awaddr_r      <= s_axi_awaddr[7:0];
                        wst           <= 2'd1;
                    end
                end
                2'd1: begin
                    s_axi_awready <= 1'b0;
                    s_axi_wready  <= 1'b0;
                    s_axi_bvalid  <= 1'b1;
                    s_axi_bresp   <= 2'b00;
                    if (awaddr_r == 8'h0C) clr <= 1'b1;
                    wst <= 2'd2;
                end
                2'd2: begin
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wst          <= 2'd0;
                    end
                end
                default: wst <= 2'd0;
            endcase
        end
    end

    // ================= AXI 读通道 =================
    reg [1:0]  rst_;
    reg [7:0]  araddr_r;
    reg [31:0] rdata_c;

    always @(*) begin
        case (araddr_r)
            8'h00:   rdata_c = {sy2, 4'b0000};
            8'h04:   rdata_c = stall_max;
            8'h08:   rdata_c = stall;
            8'h10:   rdata_c = 32'h12345678;
            default: rdata_c = 32'hDEADBEEF;
        endcase
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            rst_          <= 2'd0;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
            araddr_r      <= 8'd0;
        end
        else begin
            case (rst_)
                2'd0: begin
                    s_axi_rvalid <= 1'b0;
                    if (s_axi_arvalid) begin
                        s_axi_arready <= 1'b1;
                        araddr_r      <= s_axi_araddr[7:0];
                        rst_          <= 2'd1;
                    end
                end
                2'd1: begin
                    s_axi_arready <= 1'b0;
                    s_axi_rdata   <= rdata_c;
                    s_axi_rresp   <= 2'b00;
                    s_axi_rvalid  <= 1'b1;
                    rst_          <= 2'd2;
                end
                2'd2: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        rst_         <= 2'd0;
                    end
                end
                default: rst_ <= 2'd0;
            endcase
        end
    end

endmodule
