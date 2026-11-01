// =====================================================================
//  proto_i2c.v —— I2C 协议解码器
//
//  I2C 只有两根线，START / STOP 不是电平，是"SCL 为高时 SDA 的跳变"：
//    START : SCL 高，SDA 下降
//    STOP  : SCL 高，SDA 上升
//  传输期间每 9 个 SCL 上升沿一组：8 数据位 + 1 个应答位。
//
//  总线上拉，所以 scl / sda 空闲都是高。
//
//  负责人：C
// =====================================================================

`timescale 1ns / 1ps

module proto_i2c (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       scl,
    input  wire       sda,
    output reg  [7:0] data,     // 解出的字节
    output reg        valid,    // 一个字节收完的单拍脉冲
    output reg        ack,      // 0 = 从机应答(ACK)，1 = 未应答(NACK)
    output reg        first,    // 该字节是 START 后的首个字节（地址 + R/W）
    output reg        rw,       // 首字节的 R/W 位：1 = 读，0 = 写
    output reg        active    // 总线处于一次传输中
);

    reg scl_d, sda_d;

    wire scl_r =  scl & ~scl_d;

    wire start_cond = scl &  sda_d & ~sda;   // SCL 高时 SDA 下降
    wire stop_cond  = scl & ~sda_d &  sda;   // SCL 高时 SDA 上升

    reg [3:0] bit_cnt;      // 0..7 数据位，8 = 应答位
    reg [7:0] sh;
    reg       addr_phase;   // 1 = 当前收的是地址字节

    always @(posedge clk) begin
        if (!rst_n) begin
            scl_d      <= 1'b1;
            sda_d      <= 1'b1;
            bit_cnt    <= 4'd0;
            sh         <= 8'd0;
            data       <= 8'd0;
            valid      <= 1'b0;
            ack        <= 1'b0;
            first      <= 1'b0;
            rw         <= 1'b0;
            active     <= 1'b0;
            addr_phase <= 1'b0;
        end
        else begin
            scl_d <= scl;
            sda_d <= sda;
            valid <= 1'b0;
            first <= 1'b0;

            if (start_cond) begin
                // 起始条件（含重复起始）：重新开始一次字节序列
                active     <= 1'b1;
                addr_phase <= 1'b1;
                bit_cnt    <= 4'd0;
                sh         <= 8'd0;
            end
            else if (stop_cond) begin
                active     <= 1'b0;
                addr_phase <= 1'b0;
                bit_cnt    <= 4'd0;
            end
            else if (active && scl_r) begin
                if (bit_cnt == 4'd8) begin
                    // 应答位：接收方拉低 SDA 表示应答
                    ack      <= sda;
                    data     <= sh;
                    valid    <= 1'b1;
                    first    <= addr_phase;
                    addr_phase <= 1'b0;
                    bit_cnt  <= 4'd0;
                end
                else begin
                    sh <= {sh[6:0], sda};           // MSB 先到
                    if (addr_phase && bit_cnt == 3'd7)
                        rw <= sda;                  // 第 8 位是 R/W
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
        end
    end

endmodule
