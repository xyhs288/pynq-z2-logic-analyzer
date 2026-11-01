// =====================================================================
//  proto_uart.v —— UART 协议解码器
//
//  输入是串行线上采到的 rx 电平（由 din_sync 同步过来），直接输出字节。
//  这是"实时协议分析"最基础的一个：PL 里并行跑，不占 PS。
//
//  baud_div = 每个位周期包含多少个 clk
//
//  状态机：
//    IDLE  等起始位下降沿
//    START 等半个位周期，确认还是低（滤掉毛刺）
//    DATA  每个位周期采一位，共 8 位，LSB 先来
//    STOP  等一个位周期后检查停止位是否为高
//
//  负责人：C
// =====================================================================

`timescale 1ns / 1ps

module proto_uart #(
    parameter integer DIV_W = 16
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [DIV_W-1:0] baud_div,
    input  wire             rx,          // 串行输入
    output reg  [7:0]       data,        // 解出的字节
    output reg              valid,       // 解出一字节的单拍脉冲
    output reg              frame_err    // 停止位不是高
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]       state;
    reg [DIV_W-1:0] cnt;
    reg [2:0]       bit_idx;
    reg [7:0]       sh;

    // 半位周期用 baud_div/2 个时钟，位周期用 baud_div 个
    wire [DIV_W-1:0] half_div = {1'b0, baud_div[DIV_W-1:1]};

    wire tick_half = (cnt == half_div - 1'b1);
    wire tick_full = (cnt == baud_div - 1'b1);

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cnt       <= {DIV_W{1'b0}};
            bit_idx   <= 3'd0;
            data      <= 8'd0;
            valid     <= 1'b0;
            frame_err <= 1'b0;
        end
        else begin
            valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    cnt <= {DIV_W{1'b0}};
                    if (!rx) state <= S_START;      // 起始位下降沿
                end

                S_START: begin
                    if (tick_half) begin
                        cnt <= {DIV_W{1'b0}};
                        if (!rx) begin              // 半位后仍为低，确认是起始位
                            state   <= S_DATA;
                            bit_idx <= 3'd0;
                        end
                        else begin
                            state <= S_IDLE;        // 是毛刺，丢掉
                        end
                    end
                    else cnt <= cnt + 1'b1;
                end

                S_DATA: begin
                    if (tick_full) begin
                        sh   <= {rx, sh[7:1]};      // LSB 先到，右移进来
                        cnt  <= {DIV_W{1'b0}};
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else                 bit_idx <= bit_idx + 1'b1;
                    end
                    else cnt <= cnt + 1'b1;
                end

                default: begin                       // S_STOP
                    if (tick_full) begin
                        data      <= sh;
                        valid     <= 1'b1;
                        frame_err <= ~rx;            // 停止位应为高
                        cnt       <= {DIV_W{1'b0}};
                        state     <= S_IDLE;
                    end
                    else cnt <= cnt + 1'b1;
                end
            endcase
        end
    end

endmodule
