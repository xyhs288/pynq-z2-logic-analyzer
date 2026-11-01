// =====================================================================
//  uart_tx.v —— UART 发送器（测试用信号源）
//
//  帧格式：1 起始位(0) + 8 数据位(LSB 先发) + 1 停止位(1)
//  空闲时 tx 保持高电平。
//
//  baud_div = 每个位周期包含多少个 clk，= clk / 波特率（62.5MHz / 115200 ≈ 543）
//
//  负责人：C
// =====================================================================

`timescale 1ns / 1ps

module uart_tx #(
    parameter integer DIV_W = 16
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [DIV_W-1:0] baud_div,
    input  wire             send,      // 发送请求，单拍脉冲
    input  wire [7:0]       data_in,
    output reg              tx,
    output reg              busy
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]         state;
    reg [DIV_W-1:0]   cnt;
    reg [2:0]         bit_idx;
    reg [7:0]         sh;

    wire tick = (cnt == baud_div - 1'b1);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cnt   <= {DIV_W{1'b0}};
            tx    <= 1'b1;
            busy  <= 1'b0;
        end
        else begin
            case (state)
                S_IDLE: begin
                    tx   <= 1'b1;
                    cnt  <= {DIV_W{1'b0}};
                    busy <= 1'b0;
                    if (send) begin
                        sh       <= data_in;
                        state    <= S_START;
                        busy     <= 1'b1;
                        tx       <= 1'b0;      // 起始位
                    end
                end

                S_START: begin
                    if (tick) begin
                        cnt      <= {DIV_W{1'b0}};
                        bit_idx  <= 3'd0;
                        tx       <= sh[0];     // 最低位先发
                        state    <= S_DATA;
                    end
                    else cnt <= cnt + 1'b1;
                end

                S_DATA: begin
                    if (tick) begin
                        cnt <= {DIV_W{1'b0}};
                        if (bit_idx == 3'd7) begin
                            tx    <= 1'b1;     // 停止位
                            state <= S_STOP;
                        end
                        else begin
                            bit_idx <= bit_idx + 1'b1;
                            tx      <= sh[bit_idx + 1'b1];
                        end
                    end
                    else cnt <= cnt + 1'b1;
                end

                default: begin                 // S_STOP
                    if (tick) begin
                        cnt   <= {DIV_W{1'b0}};
                        tx    <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                    else cnt <= cnt + 1'b1;
                end
            endcase
        end
    end

endmodule
