// =====================================================================
//  spi_src.v —— SPI 测试信号源（mode 0）
//
//  周期性地发一帧：A5 5A FF，用 CS 拉低界定一次传输。
//  和 uart_tx 一样，是给板上自测用的信号源，不接外部设备也能演示。
//
//  HALF = SCLK 半周期占多少个 clk；GAP = 帧间空闲多少个 clk
//
//  负责人：C
// =====================================================================

`timescale 1ns / 1ps

module spi_src #(
    parameter integer HALF = 50,
    parameter integer GAP  = 200
)(
    input  wire       clk,
    input  wire       rst_n,
    output reg        sclk,
    output reg        mosi,
    output reg        cs_n
);

    localparam [1:0] S_GAP  = 2'd0,
                     S_LOW  = 2'd1,
                     S_HIGH = 2'd2;

    reg [1:0]  st;
    reg [31:0] cnt;
    reg [1:0]  byte_cnt;
    reg [3:0]  bit_cnt;

    reg [7:0]  cur;

    always @(*) begin
        case (byte_cnt)
            2'd0:    cur = 8'hA5;
            2'd1:    cur = 8'h5A;
            default: cur = 8'hFF;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_GAP; cnt <= 32'd0;
            byte_cnt <= 2'd0; bit_cnt <= 4'd0;
            sclk <= 1'b0; mosi <= 1'b0; cs_n <= 1'b1;
        end
        else begin
            case (st)
                S_GAP: begin
                    cs_n <= 1'b1; sclk <= 1'b0; mosi <= 1'b0;
                    if (cnt == GAP - 1) begin
                        cnt      <= 32'd0;
                        cs_n     <= 1'b0;       // 片选拉低，传输开始
                        byte_cnt <= 2'd0;
                        bit_cnt  <= 4'd0;
                        st       <= S_LOW;
                    end
                    else cnt <= cnt + 32'd1;
                end

                S_LOW: begin
                    mosi <= cur[3'd7 - bit_cnt[2:0]];   // SCLK 低时改数据（MSB 先）
                    if (cnt == HALF - 1) begin
                        cnt  <= 32'd0;
                        sclk <= 1'b1;           // 上升沿 -> 解码器采样
                        st   <= S_HIGH;
                    end
                    else cnt <= cnt + 32'd1;
                end

                default: begin                  // S_HIGH
                    if (cnt == HALF - 1) begin
                        cnt  <= 32'd0;
                        sclk <= 1'b0;
                        if (bit_cnt == 4'd7) begin
                            bit_cnt <= 4'd0;
                            if (byte_cnt == 2'd2) begin
                                cs_n     <= 1'b1;   // 3 个字节发完
                                byte_cnt <= 2'd0;
                                st       <= S_GAP;
                            end
                            else begin
                                byte_cnt <= byte_cnt + 1'b1;
                                st       <= S_LOW;
                            end
                        end
                        else begin
                            bit_cnt <= bit_cnt + 1'b1;
                            st      <= S_LOW;
                        end
                    end
                    else cnt <= cnt + 32'd1;
                end
            endcase
        end
    end

endmodule
