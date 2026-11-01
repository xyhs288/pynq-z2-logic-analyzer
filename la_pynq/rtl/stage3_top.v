// =====================================================================
//  stage3_top.v —— 完整采集链路板内验证顶层
//
//  通路：test_gen -> din_sync -> trig_fsm ──cap_en──> cap_mem
//                              \-> smp_clk_div (采样节拍)
//
//  验证目标：数据真的写进 BRAM，并且能按时间顺序读出来。
//
//  采满后自动重放：从触发点前 REPLAY_HALF 个采样点开始，每 RATE_DIV 个
//  时钟读一个，把读出的 CH0 放到 led[0]。
//  触发条件就是 CH0 的上升沿，所以 led[0] 会在重放到一半时【从灭变亮】——
//  这直接证明数据完整、顺序正确。
//
//  四个 LED：
//    led[0]  采集阶段 = ARMED；重放阶段 = 读出的 CH0
//    led[1]  FULL 抓取完成
//    led[2]  重放已越过触发点
//    led[3]  心跳约 3.7 Hz
//
//  重新开始：按住 BTN0
// =====================================================================

`timescale 1ns / 1ps

module stage3_top #(
    parameter integer DEPTH    = 65536,
    parameter integer PRE_TRIG = 16384,
    parameter integer SMP_DIV  = 1250,       // 采样分频，125MHz/1250 = 100kHz
    parameter integer RATE_DIV = 6250000,    // 重放节拍，125MHz/6250000 = 20Hz
    parameter integer SRC_MSB  = 26          // test_gen 最高位，仿真时调小
)(  
    input  wire       sys_clk,   // 125 MHz
    input  wire       btn0,      // BTN0 = D19，按下为高：重新布防
    output wire [3:0] led,
    output wire [7:0] dbg_data   // 重放时读出的采样值，接 Pmod A（8 位都要引出）
);

    localparam integer AW          = $clog2(DEPTH);
    localparam integer REPLAY_HALF = (PRE_TRIG >= 128) ? 64 : (PRE_TRIG / 2);
    localparam integer REPLAY_LEN  = REPLAY_HALF * 2;
    localparam [AW-1:0] IDX_BASE   = PRE_TRIG - REPLAY_HALF;
    localparam [15:0]   SMP_DIV_V  = SMP_DIV;

    // ---- 上电复位 ----
    reg [11:0] rst_cnt = 12'd0;
    wire       rst_n   = (rst_cnt == 12'd4095);

    always @(posedge sys_clk) begin
        if (!rst_n) rst_cnt <= rst_cnt + 12'd1;
    end

    // ---- 内置信号源 ----
    wire [7:0] tg_out;

    test_gen #(.MSB(SRC_MSB)) u_test_gen (
        .clk     (sys_clk),
        .rst_n   (rst_n),
        .sig_out (tg_out)
    );

    // ---- 两级同步 ----
    wire [7:0] din_synced;

    din_sync u_din_sync (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .din   (tg_out),
        .dout  (din_synced)
    );

    // ---- 采样节拍 ----
    wire smp_en;

    smp_clk_div u_smp_clk_div (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .div    (SMP_DIV_V),
        .smp_en (smp_en)
    );

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

    // ---- 触发状态机 ----
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
        .din        (din_synced),
        .trig_chan  (3'd0),
        .trig_mode  (2'd0),
        .trig_src   (1'b0),
        .ext_trig   (1'b0),
        .pre_trig_cfg(PRE_TRIG),
        .armed      (armed),
        .trigged    (trigged),
        .full       (full),
        .cap_en     (cap_en),
        .trig_pulse ()
    );

    // ---- 重放节拍：采满之后从触发点前 REPLAY_HALF 个点开始循环读 ----
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
        .din      (din_synced),
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

    assign led[0] = full ? rd_data[0] : armed;
    assign led[1] = full;
    assign led[2] = full & (r_cnt >= REPLAY_HALF);
    assign led[3] = hb[24];

    // 必须把 8 位全都引到顶层端口：
    // 只要有一位没被读出，综合工具就会把 BRAM 的对应位裁掉
    // （实测只引 led[0] 时，BRAM 被裁成 64K x 1，8 位只剩 1 位）。
    assign dbg_data = rd_data;

endmodule
