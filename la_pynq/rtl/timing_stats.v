// =====================================================================
//  timing_stats.v —— 时序参数直方图统计
//
//  这是作品里"不止于呈现原始波形"的那一块：
//  它不问"CH3 什么时候是高"，而是回答"CH3 的高电平有多宽、分布如何"。
//
//  对指定通道做三件事：
//    1. 测高电平宽度（width）和周期（period），按桶累加进直方图
//    2. 记录最小值 / 最大值 / 样本数 / 量程溢出次数
//    3. 分位数扫描：顺序扫直方图，求出 P50 / P95 / P99
//
//  分位数为什么该由硬件算：
//    对 65K 个样本求分位数，PS 要先把数据搬过去再排序或遍历；
//    直方图在采集通路上是顺手累加的，分位数只要扫 256 个桶。
//    计算量从 O(样本数) 降到 O(桶数)（实测 514 个时钟）。
//
//  分桶：桶号 = 时间计数 >> SHIFT，每桶代表 2^SHIFT 个时钟。
//        SHIFT 就是"时基"，按被测信号量级选。超出量程压进最后一桶。
//
//  阈值比较全程整数、不做除法：cum*100 >= n*PCT  等价于  cum/n >= PCT/100
//
//  存储用分布式 RAM 而不是 BRAM：
//    两块 256x32 共 16 Kbit，用 LUT 实现，把有限的 BRAM 全留给采集缓冲。
//    实测 0 BRAM、0 DSP、约 2.3K LUT。这是有意的资源分配。
//
//  ⚠️ 每个寄存器只在一个 always 块里赋值。测量侧只产生"单拍事件脉冲"，
//     队列/丢弃/状态机全部由 FSM 块独占，避免多驱动竞态。
//
//  负责人：B
// =====================================================================

`timescale 1ns / 1ps

module timing_stats #(
    parameter integer NBINS = 256,
    parameter integer SHIFT = 8            // 每桶 = 2^SHIFT 个 clk
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,                 // 统计使能
    input  wire        clr,                // 清空统计（保持高电平直到 clr_busy 落下）
    input  wire        sig,                // 被测信号（已同步到 clk）

    // 直方图读出（上位机用；扫描 / 清空进行时该读口被占用）
    input  wire [7:0]  rd_bin,
    output reg  [31:0] rd_w_cnt,
    output reg  [31:0] rd_p_cnt,
    output reg         clr_busy,           // 清空中，此时不要读直方图

    // 汇总
    output reg  [31:0] n_width,            // 宽度样本数（= 下降沿数）
    output reg  [31:0] n_pulse,            // 周期样本数（= 上升沿数 - 1）
    output reg  [31:0] w_min, w_max,
    output reg  [31:0] p_min, p_max,
    output reg  [31:0] sat_cnt,            // 超出量程次数
    output wire [31:0] drop_cnt,           // 来不及处理的次数（两个 FSM 各一个计数，相加输出）

    // 分位数扫描
    input  wire        pct_req,            // 请求一次扫描（单拍脉冲）
    output reg         pct_busy,
    output reg         pct_valid,
    output reg  [31:0] w_p50, w_p95, w_p99,
    output reg  [31:0] p_p50, p_p95, p_p99
);

    localparam [7:0]  LAST_BIN = NBINS[7:0] - 8'd1;
    localparam [31:0] BIN_MID  = (32'd1 << SHIFT) >> 1;   // 桶中点偏移

    // ------------------------------------------------------------------
    // 直方图存储：1 个写口 + 2 个读口
    //   读口 1 给"更新引擎"（读-改-写），读口 2 给"扫描 / 上位机"
    // ------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [31:0] mem_w [0:NBINS-1];
    (* ram_style = "distributed" *) reg [31:0] mem_p [0:NBINS-1];

    // ==================================================================
    // 一、测量：只产生"单拍事件脉冲 + 桶号"，不碰任何 FSM 状态
    // ==================================================================
    reg        sig_d;
    wire       rise = sig & ~sig_d;
    wire       fall = ~sig &  sig_d;

    reg [31:0] w_cnt;        // 高电平已经持续了多少个 clk
    reg [31:0] p_cnt;        // 距上一个上升沿多少个 clk
    reg        have_prev;

    wire [31:0] w_bin_full = w_cnt >> SHIFT;
    wire [31:0] p_bin_full = p_cnt >> SHIFT;
    wire        w_over     = (w_bin_full >= NBINS);
    wire        p_over     = (p_bin_full >= NBINS);

    reg        w_evt;        // 宽度事件（单拍）
    reg        p_evt;        // 周期事件（单拍）
    reg [7:0]  w_evt_bin;
    reg [7:0]  p_evt_bin;

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            sig_d     <= 1'b0;
            w_cnt     <= 32'd0;
            p_cnt     <= 32'd0;
            have_prev <= 1'b0;
            w_evt     <= 1'b0;
            p_evt     <= 1'b0;
            w_evt_bin <= 8'd0;
            p_evt_bin <= 8'd0;
            n_width   <= 32'd0;
            n_pulse   <= 32'd0;
            w_min     <= 32'hFFFFFFFF;
            w_max     <= 32'd0;
            p_min     <= 32'hFFFFFFFF;
            p_max     <= 32'd0;
            sat_cnt   <= 32'd0;
        end
        else begin
            w_evt <= 1'b0;
            p_evt <= 1'b0;
            if (en) begin
                sig_d <= sig;

                if (sig) w_cnt <= w_cnt + 32'd1;
                p_cnt <= p_cnt + 32'd1;

                // 下降沿：宽度 = 高电平持续的 clk 数
                if (fall) begin
                    w_cnt     <= 32'd0;
                    w_evt     <= 1'b1;
                    w_evt_bin <= w_over ? LAST_BIN : w_bin_full[7:0];
                    if (w_cnt < w_min) w_min <= w_cnt;
                    if (w_cnt > w_max) w_max <= w_cnt;
                    if (w_over)        sat_cnt <= sat_cnt + 32'd1;
                    n_width <= n_width + 32'd1;
                end

                // 上升沿：周期 = 距上一个上升沿的 clk 数
                if (rise) begin
                    if (have_prev) begin
                        p_evt     <= 1'b1;
                        p_evt_bin <= p_over ? LAST_BIN : p_bin_full[7:0];
                        if (p_cnt < p_min) p_min <= p_cnt;
                        if (p_cnt > p_max) p_max <= p_cnt;
                        if (p_over)        sat_cnt <= sat_cnt + 32'd1;
                        n_pulse <= n_pulse + 32'd1;
                    end
                    else have_prev <= 1'b1;
                    p_cnt <= 32'd0;
                end
            end
        end
    end

    // ==================================================================
    // 二、更新引擎：读 -> 加一 -> 写回
    //     队列标志、丢弃计数、桶号锁存全部由各自的 FSM 块独占
    // ==================================================================
    localparam [1:0] U_IDLE = 2'd0, U_RD = 2'd1, U_WR = 2'd2;

    reg [1:0]  uw_st, up_st;
    reg [7:0]  uw_bin, up_bin;
    reg [31:0] uw_hit, up_hit;
    reg        we_w, we_p;
    reg [7:0]  wa_w, wa_p;
    reg [31:0] wd_w, wd_p;
    reg        w_req, p_req;
    reg [7:0]  w_req_bin, p_req_bin;
    reg [31:0] w_drop, p_drop;             // 各自 FSM 独占，避免多驱动

    assign drop_cnt = w_drop + p_drop;

    wire w_busy = (uw_st != U_IDLE);
    wire p_busy = (up_st != U_IDLE);

    // 读口 1
    always @(posedge clk) begin
        uw_hit <= mem_w[uw_bin];
        up_hit <= mem_p[up_bin];
    end

    // 清空引擎
    reg [7:0] clr_idx;

    always @(posedge clk) begin
        if (!rst_n) begin
            clr_busy <= 1'b0;
            clr_idx  <= 8'd0;
        end
        else if (clr) begin
            clr_busy <= 1'b1;
            clr_idx  <= 8'd0;
        end
        else if (clr_busy) begin
            if (clr_idx == LAST_BIN) clr_busy <= 1'b0;
            clr_idx <= clr_idx + 8'd1;
        end
    end

    // 写口：清空优先
    always @(posedge clk) begin
        if (clr_busy) begin
            mem_w[clr_idx] <= 32'd0;
            mem_p[clr_idx] <= 32'd0;
        end
        else begin
            if (we_w) mem_w[wa_w] <= wd_w;
            if (we_p) mem_p[wa_p] <= wd_p;
        end
    end

    always @(posedge clk) begin
        we_w <= 1'b0;
        if (!rst_n || clr) begin
            uw_st     <= U_IDLE;
            uw_bin    <= 8'd0;
            w_req     <= 1'b0;
            w_req_bin <= 8'd0;
            w_drop    <= 32'd0;
        end
        else if (!clr_busy) begin
            if (w_evt) begin
                if (!w_req && !w_busy) begin
                    w_req     <= 1'b1;
                    w_req_bin <= w_evt_bin;
                end
                else w_drop <= w_drop + 32'd1;       // 上一次还没做完
            end

            case (uw_st)
                U_IDLE: begin
                    if (w_req) begin
                        uw_bin <= w_req_bin;
                        w_req  <= 1'b0;
                        uw_st  <= U_RD;
                    end
                end
                U_RD: uw_st <= U_WR;                 // uw_hit 下一拍有效
                default: begin
                    we_w <= 1'b1;
                    wa_w <= uw_bin;
                    wd_w <= uw_hit + 32'd1;
                    uw_st <= U_IDLE;
                end
            endcase
        end
    end

    always @(posedge clk) begin
        we_p <= 1'b0;
        if (!rst_n || clr) begin
            up_st     <= U_IDLE;
            up_bin    <= 8'd0;
            p_req     <= 1'b0;
            p_req_bin <= 8'd0;
            p_drop    <= 32'd0;
        end
        else if (!clr_busy) begin
            if (p_evt) begin
                if (!p_req && !p_busy) begin
                    p_req     <= 1'b1;
                    p_req_bin <= p_evt_bin;
                end
                else p_drop <= p_drop + 32'd1;
            end

            case (up_st)
                U_IDLE: begin
                    if (p_req) begin
                        up_bin <= p_req_bin;
                        p_req  <= 1'b0;
                        up_st  <= U_RD;
                    end
                end
                U_RD: up_st <= U_WR;
                default: begin
                    we_p <= 1'b1;
                    wa_p <= up_bin;
                    wd_p <= up_hit + 32'd1;
                    up_st <= U_IDLE;
                end
            endcase
        end
    end

    // ==================================================================
    // 三、分位数扫描：顺序扫桶，累计计数跨过阈值就记下桶号
    // ==================================================================
    localparam [1:0] S_IDLE  = 2'd0,
                     S_ISSUE = 2'd1,
                     S_ACC   = 2'd2,
                     S_DONE  = 2'd3;

    reg [1:0]  s_st;
    reg [7:0]  s_idx;
    reg [31:0] s_cum_w, s_cum_p;
    reg        f50, f95, f99, fw50, fw95, fw99;
    reg [47:0] thr50, thr95, thr99;         // 周期阈值（用 n_pulse）
    reg [47:0] tw50,  tw95,  tw99;          // 宽度阈值（用 n_width）

    wire scan_active = (s_st == S_ISSUE) | (s_st == S_ACC);
    wire [7:0] rd_addr_eff = scan_active ? s_idx : rd_bin;

    // 读口 2：扫描 / 上位机共用，同步读，1 拍延迟
    always @(posedge clk) begin
        rd_w_cnt <= mem_w[rd_addr_eff];
        rd_p_cnt <= mem_p[rd_addr_eff];
    end

    wire [47:0] n48        = {16'd0, n_pulse};
    wire [47:0] nw48       = {16'd0, n_width};
    wire [47:0] cum_w_next = {16'd0, s_cum_w} + {16'd0, rd_w_cnt};
    wire [47:0] cum_p_next = {16'd0, s_cum_p} + {16'd0, rd_p_cnt};
    wire [47:0] cw100      = cum_w_next * 48'd100;
    wire [47:0] cp100      = cum_p_next * 48'd100;

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            s_st      <= S_IDLE;
            s_idx     <= 8'd0;
            s_cum_w   <= 32'd0;
            s_cum_p   <= 32'd0;
            fw50 <= 1'b0; fw95 <= 1'b0; fw99 <= 1'b0;
            f50  <= 1'b0; f95  <= 1'b0; f99  <= 1'b0;
            pct_busy  <= 1'b0;
            pct_valid <= 1'b0;
            w_p50 <= 32'd0; w_p95 <= 32'd0; w_p99 <= 32'd0;
            p_p50 <= 32'd0; p_p95 <= 32'd0; p_p99 <= 32'd0;
        end
        else case (s_st)
            S_IDLE: begin
                if (pct_req) begin
                    pct_valid <= 1'b0;    // pct_valid 是保持标志：只在新扫描启动时清
                    s_idx   <= 8'd0;
                    s_cum_w <= 32'd0;
                    s_cum_p <= 32'd0;
                    fw50 <= 1'b0; fw95 <= 1'b0; fw99 <= 1'b0;
                    f50  <= 1'b0; f95  <= 1'b0; f99  <= 1'b0;
                    thr50   <= n48  * 48'd50;
                    thr95   <= n48  * 48'd95;
                    thr99   <= n48  * 48'd99;
                    tw50    <= nw48 * 48'd50;
                    tw95    <= nw48 * 48'd95;
                    tw99    <= nw48 * 48'd99;
                    pct_busy <= 1'b1;
                    s_st     <= S_ISSUE;
                end
            end

            S_ISSUE: s_st <= S_ACC;              // 地址已给，下一拍数据有效

            S_ACC: begin
                s_cum_w <= cum_w_next[31:0];
                s_cum_p <= cum_p_next[31:0];

                if (!fw50 && cw100 >= tw50) begin
                    w_p50 <= ({24'd0, s_idx} << SHIFT) + BIN_MID; fw50 <= 1'b1;
                end
                if (!fw95 && cw100 >= tw95) begin
                    w_p95 <= ({24'd0, s_idx} << SHIFT) + BIN_MID; fw95 <= 1'b1;
                end
                if (!fw99 && cw100 >= tw99) begin
                    w_p99 <= ({24'd0, s_idx} << SHIFT) + BIN_MID; fw99 <= 1'b1;
                end
                if (!f50 && cp100 >= thr50) begin
                    p_p50 <= ({24'd0, s_idx} << SHIFT) + BIN_MID; f50 <= 1'b1;
                end
                if (!f95 && cp100 >= thr95) begin
                    p_p95 <= ({24'd0, s_idx} << SHIFT) + BIN_MID; f95 <= 1'b1;
                end
                if (!f99 && cp100 >= thr99) begin
                    p_p99 <= ({24'd0, s_idx} << SHIFT) + BIN_MID; f99 <= 1'b1;
                end

                if (s_idx == LAST_BIN) s_st <= S_DONE;
                else begin
                    s_idx <= s_idx + 8'd1;
                    s_st  <= S_ISSUE;
                end
            end

            default: begin                       // S_DONE
                pct_valid <= 1'b1;
                pct_busy  <= 1'b0;
                s_st      <= S_IDLE;
            end
        endcase
    end

endmodule
