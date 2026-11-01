// =====================================================================
//  i2c_src.v —— I2C 测试信号源
//
//  周期性产生一次写传输：START + A0 + 55 + AA + STOP。
//  应答位由本模块模拟从机拉低（总线上没有真实从机）。
//
//  HALF = 半个 SCL 周期占多少个 clk；GAP = 事务间空闲多少个 clk
//
//  负责人：C
// =====================================================================

`timescale 1ns / 1ps

module i2c_src #(
    parameter integer HALF = 50,
    parameter integer GAP  = 200
)(
    input  wire clk,
    input  wire rst_n,
    output reg  scl,
    output reg  sda
);

    localparam [2:0] P_GAP    = 3'd0,
                     P_START1 = 3'd1,
                     P_START2 = 3'd2,
                     P_LO     = 3'd3,
                     P_HI     = 3'd4,
                     P_STOP1  = 3'd5,
                     P_STOP2  = 3'd6;

    reg [2:0]  ph;
    reg [31:0] cnt;          // 32 位：演示参数下 HALF 可达数百万
    reg [1:0]  byte_cnt;
    reg [3:0]  bit_cnt;

    reg [7:0]  cur;

    always @(*) begin
        case (byte_cnt)
            2'd0:    cur = 8'hA0;      // 地址 + 写
            2'd1:    cur = 8'h55;
            default: cur = 8'hAA;
        endcase
    end

    // 第 9 位是从机应答，模拟从机拉低
    wire sda_bit = (bit_cnt == 4'd8) ? 1'b0 : cur[3'd7 - bit_cnt[2:0]];

    always @(posedge clk) begin
        if (!rst_n) begin
            ph <= P_GAP; cnt <= 32'd0;
            byte_cnt <= 2'd0; bit_cnt <= 4'd0;
            scl <= 1'b1; sda <= 1'b1;
        end
        else begin
            case (ph)
                P_GAP: begin
                    scl <= 1'b1; sda <= 1'b1;          // 总线空闲
                    if (cnt == GAP - 1) begin
                        cnt <= 32'd0; ph <= P_START1;
                    end
                    else cnt <= cnt + 32'd1;
                end

                P_START1: begin
                    scl <= 1'b1; sda <= 1'b1;
                    if (cnt == HALF - 1) begin
                        cnt <= 32'd0; sda <= 1'b0;     // SCL 高时 SDA 下降
                        byte_cnt <= 2'd0; bit_cnt <= 4'd0;
                        ph <= P_START2;
                    end
                    else cnt <= cnt + 32'd1;
                end

                P_START2: begin
                    scl <= 1'b1; sda <= 1'b0;
                    if (cnt == HALF - 1) begin
                        cnt <= 32'd0; scl <= 1'b0; ph <= P_LO;
                    end
                    else cnt <= cnt + 32'd1;
                end

                P_LO: begin
                    scl <= 1'b0; sda <= sda_bit;
                    if (cnt == HALF - 1) begin
                        cnt <= 32'd0; scl <= 1'b1; ph <= P_HI;
                    end
                    else cnt <= cnt + 32'd1;
                end

                P_HI: begin
                    if (cnt == HALF - 1) begin
                        cnt <= 32'd0; scl <= 1'b0;
                        if (bit_cnt == 4'd8) begin
                            bit_cnt <= 4'd0;
                            if (byte_cnt == 2'd2) ph <= P_STOP1;
                            else begin
                                byte_cnt <= byte_cnt + 1'b1;
                                ph <= P_LO;
                            end
                        end
                        else begin
                            bit_cnt <= bit_cnt + 1'b1;
                            ph <= P_LO;
                        end
                    end
                    else cnt <= cnt + 32'd1;
                end

                P_STOP1: begin
                    scl <= 1'b0; sda <= 1'b0;
                    if (cnt == HALF - 1) begin
                        cnt <= 32'd0; scl <= 1'b1; ph <= P_STOP2;
                    end
                    else cnt <= cnt + 32'd1;
                end

                default: begin                     // P_STOP2
                    scl <= 1'b1; sda <= 1'b0;
                    if (cnt == HALF - 1) begin
                        cnt <= 32'd0; sda <= 1'b1; // SCL 高时 SDA 上升 = STOP
                        ph <= P_GAP;
                    end
                    else cnt <= cnt + 32'd1;
                end
            endcase
        end
    end

endmodule
