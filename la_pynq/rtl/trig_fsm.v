// =====================================================================
//  trig_fsm.v —— 触发状态机（含预触发计数）
//
//  状态转移：IDLE -> ARMED -> TRIG -> FULL
//
//  触发不是"开始记录"，而是"让一直在循环的记录停下来"：
//    触发发生的那一刻，缓冲里已经存着触发之前的数据，
//    所以只要在触发之后【再写 DEPTH-PRE_TRIG 拍】就停下，
//    缓冲里留下的正好是 "触发前 PRE_TRIG 点 + 触发后 DEPTH-PRE_TRIG 点"。
//
//  cap_en  = 写使能，送给 cap_mem 控制数据写入
//  full    = 抓取完成
//  trig_pulse = 触发那一刻的单拍脉冲
//  restart = 拉高则强制回到 IDLE 重新布防（退出 FULL 用）
//
//  触发源二选一（trig_src）：
//    0 = din[trig_chan] 的边沿/电平（常规逻辑分析仪用法）
//    1 = ext_trig 脉冲（协议内容触发，来自 proto_trig）
//
//  负责人：A
// =====================================================================

`timescale 1ns / 1ps

module trig_fsm #(
    parameter integer DEPTH    = 65536,   // 缓冲总深度（物理）
    parameter integer PRE_TRIG = 16384    // 默认预触发点数（可被 pre_trig_cfg 覆盖）
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       arm,          // 布防信号
    input  wire       restart,      // 高电平：强制回 IDLE，重新布防
    input  wire       free_run,     // 1 = 不触发，cap_en 常有效（滚动显示用）
    input  wire       smp_en,       // 采样节拍（单拍脉冲）
    input  wire [7:0] din,          // 同步后的 8 路输入
    input  wire [2:0] trig_chan,    // 触发通道号
    input  wire [2:0] trig_mode,    // 0=上升沿 1=下降沿 2=高电平 3=低电平
    input  wire       trig_src,     // 0=用 din 的电平/边沿，1=用 ext_trig 脉冲
    input  wire       ext_trig,     // 外部触发脉冲（来自 proto_trig）
    input  wire [31:0] pre_trig_cfg,// 运行时预触发点数（来自寄存器）
    output reg        armed,
    output reg        trigged,
    output reg        full,
    output reg        cap_en,
    output reg        trig_pulse
);

    localparam integer CNT_W = $clog2(DEPTH + 1);

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_ARMED = 2'd1;
    localparam [1:0] S_TRIG  = 2'd2;
    localparam [1:0] S_FULL  = 2'd3;

    reg [1:0]       state;
    reg [7:0]       din_d;
    reg [CNT_W-1:0] post_cnt;

    // 触发后还要写多少拍 = 物理深度 - 预触发点数
    // pre_trig_cfg 超过物理深度时钳到 DEPTH（此时 post_limit = 0，触发即满）
    wire [CNT_W-1:0] DEPTH_V = DEPTH[CNT_W-1:0];
    wire [CNT_W-1:0] PRE_V   = (pre_trig_cfg >= DEPTH) ? DEPTH_V
                                                       : pre_trig_cfg[CNT_W-1:0];
    wire [CNT_W-1:0] post_limit = DEPTH_V - PRE_V;

    always @(posedge clk) begin
        if (!rst_n) din_d <= 8'd0;
        else        din_d <= din;
    end

    wire din_b   = din[trig_chan];
    wire din_b_d = din_d[trig_chan];

    // 触发条件：边沿模式是单拍脉冲，电平模式是持续有效
    reg trig_cond;
    always @(*) begin
        case (trig_mode)
            2'd0:    trig_cond =  din_b & ~din_b_d;
            2'd1:    trig_cond = ~din_b &  din_b_d;
            2'd2:    trig_cond =  din_b;
            default: trig_cond = ~din_b;
        endcase
    end

    // 二选一：din 的电平/边沿，或者协议解码给出的脉冲
    wire trig_hit = trig_src ? ext_trig : trig_cond;

    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            post_cnt   <= {CNT_W{1'b0}};
            trig_pulse <= 1'b0;
        end
        else if (restart) begin
            state      <= S_IDLE;
            post_cnt   <= {CNT_W{1'b0}};
            trig_pulse <= 1'b0;
        end
        else begin
            trig_pulse <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (arm) state <= S_ARMED;
                end

                S_ARMED: begin
                    if (trig_hit) begin
                        state      <= S_TRIG;
                        post_cnt   <= {CNT_W{1'b0}};
                        trig_pulse <= 1'b1;
                    end
                end

                S_TRIG: begin
                    if (smp_en) begin
                        // post_limit = 0 时（预触发 ≥ 物理深度）触发即满
                        if (post_cnt + 1'b1 >= post_limit) state <= S_FULL;
                        else                               post_cnt <= post_cnt + 1'b1;
                    end
                end

                default: state <= S_FULL;
            endcase
        end
    end

    always @(*) begin
        armed   = (state == S_ARMED);
        trigged = (state == S_TRIG);
        full    = (state == S_FULL);
        // free_run：绕过状态机直接让缓冲一直写（PS 可以随时读最新 N 点做滚动显示）
        cap_en  = free_run | (state == S_ARMED) | (state == S_TRIG);
    end

endmodule
