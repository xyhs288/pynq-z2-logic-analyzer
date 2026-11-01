// =====================================================================
//  stage4_top.v —— 协议内容触发（完整链路）
//
//  通路：
//    i2c_src ──> proto_i2c ──valid+data──> proto_trig ──脉冲──> trig_fsm
//        │                     │                                   │
//        └──(scl/sda)──> cap_mem <──cap_en─────────────────────────┘
//
//  演示的是：总线上一直有 I2C 流量，但【等到出现指定字节】才开始抓。
//  抓到的窗口里能同时看到触发点【之前】和【之后】的总线波形。
//
//  这件事 PS 做不到——数据是触发之后才有的，解码必须在触发通路上。
//
//  采集内容：bit1 = SDA，bit0 = SCL（这样波形图能直接看出总线活动）
//
//  四个 LED：
//    led[0]  采集阶段 = ARMED（在等目标字节）；重放阶段 = 采到的 SDA
//    led[1]  FULL 抓取完成
//    led[2]  重放指针已越过触发点
//    led[3]  心跳
//
//  重新布防：按住 BTN0
//
//  ⚠️ 默认参数是【演示参数】，不是真实测量参数：
//     总线和采样率一起放慢，让 ARMED -> TRIG 的转换肉眼可见。
//     I2C 时钟约 21 Hz，采样率约 208 Hz，每 1 个总线位采 10 个点。
//     真实测量时应把 BUS_HALF 和 SMP_DIV 同比例调小。
// =====================================================================

`timescale 1ns / 1ps

module stage4_top #(
    parameter integer DEPTH     = 512,
    parameter integer PRE_TRIG  = 128,
    parameter integer SMP_DIV   = 600000,     // 125MHz/600000 ≈ 208Hz 采样
    parameter integer RATE_DIV  = 6250000,    // 重放节拍 20Hz
    parameter [7:0]   TRIG_BYTE = 8'hAA,      // 目标字节
    parameter integer BUS_HALF  = 3000000,    // I2C 半周期 24ms -> SCL 约 21Hz
    parameter integer BUS_GAP   = 3000000     // I2C 事务间空闲
)(
    input  wire       sys_clk,   // 125 MHz
    input  wire       btn0,      // BTN0 = D19，按下为高
    output wire [3:0] led,
    output wire [7:0] dbg_data   // 重放读出的采样值（8 位全引出，防止 BRAM 被裁）
);

    localparam integer AW          = $clog2(DEPTH);
    localparam integer REPLAY_HALF = (PRE_TRIG >= 128) ? 64 : (PRE_TRIG / 2);
    localparam integer REPLAY_LEN  = REPLAY_HALF * 2;
    localparam [AW-1:0] IDX_BASE   = PRE_TRIG - REPLAY_HALF;
    localparam [31:0]   SMP_DIV_V  = SMP_DIV;

    // ---- 上电复位 ----
    reg [11:0] rst_cnt = 12'd0;
    wire       rst_n   = (rst_cnt == 12'd4095);

    always @(posedge sys_clk) begin
        if (!rst_n) rst_cnt <= rst_cnt + 12'd1;
    end

    // ---- I2C 信号源（板内自测，不需要外部设备）----
    wire bus_scl, bus_sda;

    i2c_src #(
        .HALF (BUS_HALF),
        .GAP  (BUS_GAP)
    ) u_i2c_src (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .scl   (bus_scl),
        .sda   (bus_sda)
    );

    // ---- I2C 解码器 ----
    wire [7:0] dec_data;
    wire       dec_valid, dec_ack, dec_first, dec_rw, dec_active;

    proto_i2c u_proto_i2c (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .scl    (bus_scl),
        .sda    (bus_sda),
        .data   (dec_data),
        .valid  (dec_valid),
        .ack    (dec_ack),
        .first  (dec_first),
        .rw     (dec_rw),
        .active (dec_active)
    );

    // ---- 协议内容匹配 ----
    wire proto_trig_pulse;

    proto_trig u_proto_trig (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .en         (1'b1),
        .match_val  (TRIG_BYTE),
        .data       (dec_data),
        .data_valid (dec_valid),
        .trig_pulse (proto_trig_pulse)
    );

    // ---- 采样节拍 ----
    wire smp_en;

    smp_clk_div u_smp_clk_div (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .div    (SMP_DIV_V),
        .smp_en (smp_en)
    );

    // ---- 采集的是总线本身 ----
    wire [7:0] din_bus = {6'b0, bus_sda, bus_scl};

    // ---- BTN0 两级同步 ----
    reg btn_d0, btn_d1;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            btn_d0 <= 1'b0;
            btn_d1 <= 1'b0;
        end
        else begin
            btn_d0 <= btn0;
            btn_d1 <= btn_d0;
        end
    end

    // ---- 触发状态机：触发源选外部脉冲（协议匹配）----
    wire armed, trigged, full, cap_en;

    trig_fsm #(
        .DEPTH    (DEPTH),
        .PRE_TRIG (PRE_TRIG)
    ) u_trig_fsm (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .arm        (1'b1),
        .restart    (btn_d1),
        .smp_en     (smp_en),
        .din        (din_bus),
        .trig_chan  (3'd0),
        .trig_mode  (2'd0),
        .trig_src   (1'b1),               // 用协议匹配脉冲
        .ext_trig   (proto_trig_pulse),
        .pre_trig_cfg(PRE_TRIG),
        .armed      (armed),
        .trigged    (trigged),
        .full       (full),
        .cap_en     (cap_en),
        .trig_pulse ()
    );

    // ---- 重放 ----
    reg  [31:0] rate_cnt;
    reg  [15:0] r_cnt;

    always @(posedge sys_clk) begin
        if (!rst_n || !full) begin
            rate_cnt <= 32'd0;
            r_cnt    <= 16'd0;
        end
        else if (rate_cnt >= RATE_DIV - 1) begin
            rate_cnt <= 32'd0;
            r_cnt    <= (r_cnt >= REPLAY_LEN - 1) ? 16'd0 : (r_cnt + 16'd1);
        end
        else begin
            rate_cnt <= rate_cnt + 32'd1;
        end
    end

    wire [AW-1:0] idx = IDX_BASE + r_cnt[AW-1:0];

    // ---- 片内缓冲 ----
    wire [AW-1:0] wr_ptr, stop_ptr;
    wire [7:0]    rd_data;

    cap_mem #(
        .DEPTH (DEPTH),
        .AW    (AW)
    ) u_cap_mem (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .cap_en   (cap_en),
        .smp_en   (smp_en),
        .din      (din_bus),
        .rd_addr  (stop_ptr + idx),
        .rd_en    (1'b1),
        .rd_data  (rd_data),
        .wr_ptr   (wr_ptr),
        .stop_ptr (stop_ptr)
    );

    // ---- 心跳 ----
    reg [25:0] hb;

    always @(posedge sys_clk) begin
        if (!rst_n) hb <= 26'd0;
        else        hb <= hb + 26'd1;
    end

    assign led[0] = full ? rd_data[1] : armed;   // 重放时显示采到的 SDA
    assign led[1] = full;
    assign led[2] = full & (r_cnt >= REPLAY_HALF);
    assign led[3] = hb[24];

    assign dbg_data = rd_data;

endmodule