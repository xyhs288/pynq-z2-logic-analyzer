// =====================================================================
//  proto_spi.v —— SPI 协议解码器
//
//  SPI 没有帧间隔，靠 CS 拉低界定一次传输。
//  CS 拉低后，每个采样边沿收一位，满 8 位输出一个字节（MSB 先到）。
//
//  CPOL / CPHA 决定采样用哪个边沿：
//    CPOL=0 空闲低，前沿是上升沿；CPOL=1 空闲高，前沿是下降沿
//    CPHA=0 在前沿采样；CPHA=1 在后沿采样
//
//  负责人：C
// =====================================================================

`timescale 1ns / 1ps

module proto_spi #(
    parameter integer CPOL = 0,
    parameter integer CPHA = 0
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sclk,
    input  wire       mosi,
    input  wire       cs_n,        // 低有效
    output reg  [7:0] data,        // 解出的字节
    output reg        valid,       // 收满一字节的单拍脉冲
    output reg  [7:0] byte_cnt,    // 本次片选内已收字节数
    output reg        frame_err    // CS 在字节中途抬起
);

    reg sclk_d, cs_d;

    wire sclk_r =  sclk & ~sclk_d;
    wire sclk_f = ~sclk &  sclk_d;

    wire cs_fall = ~cs_n &  cs_d;   // 一次传输开始
    wire cs_rise =  cs_n & ~cs_d;   // 一次传输结束

    // 采样边沿
    wire sample = (CPOL == 0) ? (CPHA == 0 ? sclk_r : sclk_f)
                              : (CPHA == 0 ? sclk_f : sclk_r);

    reg [2:0] bit_idx;
    reg [7:0] sh;

    always @(posedge clk) begin
        if (!rst_n) begin
            sclk_d    <= 1'b0;
            cs_d      <= 1'b1;
            bit_idx   <= 3'd0;
            sh        <= 8'd0;
            data      <= 8'd0;
            valid     <= 1'b0;
            byte_cnt  <= 8'd0;
            frame_err <= 1'b0;
        end
        else begin
            sclk_d <= sclk;
            cs_d   <= cs_n;
            valid  <= 1'b0;

            if (cs_fall) begin
                bit_idx   <= 3'd0;
                byte_cnt  <= 8'd0;
                frame_err <= 1'b0;
            end
            else if (!cs_n) begin
                if (sample) begin
                    // 满 8 位时直接拼出完整字节，避免多一拍延迟
                    if (bit_idx == 3'd7) begin
                        data     <= {sh[6:0], mosi};
                        valid    <= 1'b1;
                        byte_cnt <= byte_cnt + 1'b1;
                        bit_idx  <= 3'd0;
                    end
                    else begin
                        sh      <= {sh[6:0], mosi};
                        bit_idx <= bit_idx + 1'b1;
                    end
                end
            end
            else begin
                if (cs_rise && (bit_idx != 3'd0))
                    frame_err <= 1'b1;      // 字节没收完 CS 就抬了
                bit_idx <= 3'd0;
            end
        end
    end

endmodule
