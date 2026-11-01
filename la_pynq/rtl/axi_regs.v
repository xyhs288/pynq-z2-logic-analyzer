// =====================================================================
//  axi_regs.v —— AXI4-Lite 从机 + 完整控制/状态寄存器组
//
//  地址位宽 8 位（64 个寄存器），映射见 docs/interface.md（冻结版 v2）。
//
//  两条独立通道：
//    写通道：收地址+数据 -> 更新配置寄存器 -> 回写响应
//    读通道：收地址 -> 组合选择读数据 -> 回读响应
//
//  大部分读数据是"组合直通"（引外部状态），只有 MEM_ADDR 的数据来自外部
//  同步读、会晚一拍——但 PS 写地址和读数据是两次独立的 AXI 事务，
//  中间隔了足够拍数，所以拿到的总是最新值。
//
//  ⚠️ 每个寄存器只在本文件的写通道里赋值，避免多驱动。
//
//  负责人：B
// =====================================================================

`timescale 1ns / 1ps

module axi_regs #(
    parameter integer AW = 8
)(
    input  wire          clk,
    input  wire          rst_n,

    // ---- AXI4-Lite 从机 ----
    input  wire [AW-1:0] s_awaddr,
    input  wire          s_awvalid,
    output reg           s_awready,
    input  wire [31:0]   s_wdata,
    input  wire [3:0]    s_wstrb,
    input  wire          s_wvalid,
    output reg           s_wready,
    output reg  [1:0]    s_bresp,
    output reg           s_bvalid,
    input  wire          s_bready,
    input  wire [AW-1:0] s_araddr,
    input  wire          s_arvalid,
    output reg           s_arready,
    output reg  [31:0]   s_rdata,
    output reg  [1:0]    s_rresp,
    output reg           s_rvalid,
    input  wire          s_rready,

    // ---- 配置输出 ----
    output reg  [31:0] reg_div,
    output reg  [15:0] reg_depth,
    output reg  [2:0]  reg_trig_mode,
    output reg  [2:0]  reg_trig_chan,
    output reg  [7:0]  reg_trig_value,
    output reg  [7:0]  reg_trig_mask,
    output reg  [15:0] reg_pre_trig,
    output reg  [7:0]  reg_chan_en,
    output reg  [1:0]  reg_proto_sel,
    output reg  [31:0] reg_proto_div,
    output reg  [7:0]  reg_hist_addr,
    output reg  [15:0] reg_mem_addr,
    output reg         reg_arm,
    // CTRL.bit2 / bit3 保留（原板内自测源，已删除），写 1 无效果
    output reg         reg_free_run,       // CTRL.bit4：1=不触发，缓冲一直写（滚动显示用）
    output reg         reg_pmodb_en,       // CTRL.bit5：1=Pmod B 输出测试信号，0=高阻断开
    output reg         pulse_soft_rst,     // CTRL.bit1 写 1 -> 单拍脉冲
    output reg         reg_stat_en,        // STAT_CTRL.bit0 电平
    output reg         reg_stat_clr,       // STAT_CTRL.bit1 电平（保持到 clr_busy 落下）
    output reg         pulse_stat_scan,    // STAT_CTRL.bit2 写 1 -> 单拍脉冲

    // ---- 状态输入 ----
    input  wire [7:0]  st_proto_byte,
    input  wire [2:0]  st_proto_stat,
    input  wire        st_armed,
    input  wire        st_trigged,
    input  wire        st_full,
    input  wire        st_clr_busy,
    input  wire        st_pct_busy,
    input  wire        st_pct_valid,
    input  wire [31:0] st_hist_wcnt,
    input  wire [31:0] st_hist_pcnt,
    input  wire [31:0] st_w_p50, st_w_p95, st_w_p99,
    input  wire [31:0] st_p_p50, st_p_p95, st_p_p99,
    input  wire [31:0] st_w_min, st_w_max, st_p_min, st_p_max,
    input  wire [31:0] st_n_width, st_n_pulse, st_n_sat, st_n_drop,
    input  wire [15:0] st_wr_ptr, st_stop_ptr,
    input  wire [15:0] st_btn_cnt,         // 板载按钮按下次数（只读，证明数据来自真实硬件）
    input  wire [7:0]  st_mem_data
);

    // ---------------- 地址表（以 docs/interface.md 为准）----------------
    localparam [AW-1:0] A_CTRL       = 8'h00,
                        A_STATUS     = 8'h04,
                        A_DIV        = 8'h08,
                        A_DEPTH      = 8'h0C,
                        A_TRIG_MODE  = 8'h10,
                        A_TRIG_CHAN  = 8'h14,
                        A_TRIG_VALUE = 8'h18,
                        A_TRIG_MASK  = 8'h1C,
                        A_PRE_TRIG   = 8'h20,
                        A_CHAN_EN    = 8'h24,
                        A_PROTO_SEL  = 8'h28,
                        A_PROTO_DIV  = 8'h2C,
                        A_PROTO_BYTE = 8'h30,
                        A_PROTO_STAT = 8'h34,
                        A_STAT_CTRL  = 8'h38,
                        A_STAT_STAT  = 8'h3C,
                        A_HIST_ADDR  = 8'h40,
                        A_HIST_WCNT  = 8'h44,
                        A_HIST_PCNT  = 8'h48,
                        A_W_P50      = 8'h4C,
                        A_W_P95      = 8'h50,
                        A_W_P99      = 8'h54,
                        A_P_P50      = 8'h58,
                        A_P_P95      = 8'h5C,
                        A_P_P99      = 8'h60,
                        A_W_MIN      = 8'h64,
                        A_W_MAX      = 8'h68,
                        A_P_MIN      = 8'h6C,
                        A_P_MAX      = 8'h70,
                        A_STAT_NW    = 8'h74,
                        A_STAT_NP    = 8'h78,
                        A_STAT_ERR   = 8'h7C,
                        A_MEM_ADDR   = 8'h80,
                        A_WR_PTR     = 8'h84,
                        A_STOP_PTR   = 8'h88,
                        A_BTN_CNT    = 8'h8C;

    // ---------------- 写通道 ----------------
    //  🔴 两个坑（2026-10-15 真机上挂死整机后定位）：
    //   1) 原来用 `s_bvalid <= 1'b1; if (s_bready) s_bvalid <= 1'b0;` ——
    //      同一拍里"置位又被清零"。当主机的 bready 预先就位（AXI 允许，
    //      ARM 主机常见）时，bvalid 永远输出不出去 → 主机死等 → 总线挂死。
    //      修法：先拉高，**下一拍**才检查 ready。
    //   2) 原来要求 `s_awvalid && s_wvalid` 同时有效才响应。AXI 允许地址和
    //      数据独立到达，主机先发 AW 等 awready 时就会死锁。
    //      修法：AW / W 各自独立握手，两者都到齐再更新寄存器。
    reg              aw_done, w_done, b_pending;
    reg [AW-1:0]     awaddr_lat;
    reg [31:0]       wdata_lat;

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_done         <= 1'b0;
            w_done          <= 1'b0;
            b_pending       <= 1'b0;
            awaddr_lat      <= {AW{1'b0}};
            wdata_lat       <= 32'd0;
            s_awready       <= 1'b0;
            s_wready        <= 1'b0;
            s_bvalid        <= 1'b0;
            s_bresp         <= 2'b00;
            reg_div         <= 32'd1250;
            reg_depth       <= 16'd1024;
            reg_trig_mode   <= 3'd0;
            reg_trig_chan   <= 3'd0;
            reg_trig_value  <= 8'h00;
            reg_trig_mask   <= 8'hFF;
            reg_pre_trig    <= 16'd256;
            reg_chan_en     <= 8'hFF;
            reg_proto_sel   <= 2'd0;
            reg_proto_div   <= 32'd640;    // 62.5MHz / 640 ≈ 97.66 kbaud，与板内 UART 源一致
            reg_hist_addr   <= 8'd0;
            reg_mem_addr    <= 16'd0;
            reg_arm         <= 1'b0;
            reg_free_run    <= 1'b0;
            reg_pmodb_en    <= 1'b1;       // 默认开：上电就有测试信号，接错线也好发现
            pulse_soft_rst  <= 1'b0;
            reg_stat_en     <= 1'b0;
            reg_stat_clr    <= 1'b0;
            pulse_stat_scan <= 1'b0;
        end
        else begin
            // 脉冲型输出默认拉低
            pulse_soft_rst  <= 1'b0;
            pulse_stat_scan <= 1'b0;

            // ---- AW 通道独立握手 ----
            if (!aw_done && !b_pending) begin
                s_awready <= 1'b1;
                if (s_awvalid) begin
                    awaddr_lat <= s_awaddr;
                    aw_done    <= 1'b1;
                end
            end
            else begin
                s_awready <= 1'b0;
            end

            // ---- W 通道独立握手 ----
            if (!w_done && !b_pending) begin
                s_wready <= 1'b1;
                if (s_wvalid) begin
                    wdata_lat <= s_wdata;
                    w_done    <= 1'b1;
                end
            end
            else begin
                s_wready <= 1'b0;
            end

            // ---- 地址与数据都到齐 -> 更新寄存器，挂起写响应 ----
            if (aw_done && w_done && !b_pending) begin
                case (awaddr_lat)
                    A_CTRL: begin
                        reg_arm        <= wdata_lat[0];
                        pulse_soft_rst <= wdata_lat[1];
                        reg_free_run   <= wdata_lat[4];
                        reg_pmodb_en   <= wdata_lat[5];
                    end
                    A_DIV:        reg_div        <= wdata_lat;
                    A_DEPTH:      reg_depth      <= wdata_lat[15:0];
                    A_TRIG_MODE:  reg_trig_mode  <= wdata_lat[2:0];
                    A_TRIG_CHAN:  reg_trig_chan  <= wdata_lat[2:0];
                    A_TRIG_VALUE: reg_trig_value <= wdata_lat[7:0];
                    A_TRIG_MASK:  reg_trig_mask  <= wdata_lat[7:0];
                    A_PRE_TRIG:   reg_pre_trig   <= wdata_lat[15:0];
                    A_CHAN_EN:    reg_chan_en    <= wdata_lat[7:0];
                    A_PROTO_SEL:  reg_proto_sel  <= wdata_lat[1:0];
                    A_PROTO_DIV:  reg_proto_div  <= wdata_lat;
                    A_STAT_CTRL: begin
                        reg_stat_en     <= wdata_lat[0];
                        reg_stat_clr    <= wdata_lat[1];
                        pulse_stat_scan <= wdata_lat[2];
                    end
                    A_HIST_ADDR:  reg_hist_addr  <= wdata_lat[7:0];
                    A_MEM_ADDR:   reg_mem_addr   <= wdata_lat[15:0];
                    default: ;      // 只读寄存器忽略写入
                endcase
                b_pending <= 1'b1;
            end

            // ---- 写响应：先拉高 bvalid，下一拍才检查 bready ----
            if (b_pending) begin
                if (!s_bvalid) begin
                    s_bvalid <= 1'b1;
                end
                else if (s_bready) begin
                    s_bvalid  <= 1'b0;
                    b_pending <= 1'b0;
                    aw_done   <= 1'b0;
                    w_done    <= 1'b0;
                end
            end
        end
    end

    // ---------------- 读通道 ----------------
    //  🔴 同样的坑：原来写的是
    //        s_rvalid <= 1'b1;
    //        if (s_rready) begin s_rvalid <= 1'b0; ... end
    //     同一拍里"置位又被清零"。主机的 rready 若预先就位，
    //     rvalid 永远输出不出去 —— 主机等不到读数据，总线挂死。
    //     修法：先拉高 rvalid，**下一拍**才检查 rready。
    reg r_state;

    always @(posedge clk) begin
        if (!rst_n) begin
            r_state   <= 1'b0;
            s_arready <= 1'b0;
            s_rvalid  <= 1'b0;
            s_rresp   <= 2'b00;
            s_rdata   <= 32'd0;
        end
        else if (r_state == 1'b0) begin
            s_rvalid <= 1'b0;
            if (s_arvalid) begin
                s_arready <= 1'b1;
                s_rdata   <= rd_mux(s_araddr);
                r_state   <= 1'b1;
            end
        end
        else begin
            s_arready <= 1'b0;
            if (!s_rvalid) begin
                s_rvalid <= 1'b1;
            end
            else if (s_rready) begin
                s_rvalid <= 1'b0;
                r_state  <= 1'b0;
            end
        end
    end

    // ---------------- 读数据选择 ----------------
    function [31:0] rd_mux;
        input [AW-1:0] a;
        begin
            case (a)
                // 位位置必须和写通道一致：bit5=pmodb_en bit4=free_run bit1=soft_rst bit0=arm
                // 中间补 2 位给保留的 bit3/bit2，否则 pmodb/free_run 会整体下移两位
                A_CTRL:       rd_mux = {26'd0, reg_pmodb_en, reg_free_run, 2'b00,
                                        pulse_soft_rst, reg_arm};
                A_STATUS:     rd_mux = {28'd0, st_clr_busy, st_full,
                                        st_trigged, st_armed};
                A_DIV:        rd_mux = reg_div;
                A_DEPTH:      rd_mux = {16'd0, reg_depth};
                A_TRIG_MODE:  rd_mux = {29'd0, reg_trig_mode};
                A_TRIG_CHAN:  rd_mux = {29'd0, reg_trig_chan};
                A_TRIG_VALUE: rd_mux = {24'd0, reg_trig_value};
                A_TRIG_MASK:  rd_mux = {24'd0, reg_trig_mask};
                A_PRE_TRIG:   rd_mux = {16'd0, reg_pre_trig};
                A_CHAN_EN:    rd_mux = {24'd0, reg_chan_en};
                A_PROTO_SEL:  rd_mux = {30'd0, reg_proto_sel};
                A_PROTO_DIV:  rd_mux = reg_proto_div;
                A_PROTO_BYTE: rd_mux = {24'd0, st_proto_byte};
                A_PROTO_STAT: rd_mux = {29'd0, st_proto_stat};
                A_STAT_CTRL:  rd_mux = {29'd0, pulse_stat_scan,
                                        reg_stat_clr, reg_stat_en};
                A_STAT_STAT:  rd_mux = {29'd0, st_pct_valid, st_pct_busy,
                                        st_clr_busy};
                A_HIST_ADDR:  rd_mux = {24'd0, reg_hist_addr};
                A_HIST_WCNT:  rd_mux = st_hist_wcnt;
                A_HIST_PCNT:  rd_mux = st_hist_pcnt;
                A_W_P50:      rd_mux = st_w_p50;
                A_W_P95:      rd_mux = st_w_p95;
                A_W_P99:      rd_mux = st_w_p99;
                A_P_P50:      rd_mux = st_p_p50;
                A_P_P95:      rd_mux = st_p_p95;
                A_P_P99:      rd_mux = st_p_p99;
                A_W_MIN:      rd_mux = st_w_min;
                A_W_MAX:      rd_mux = st_w_max;
                A_P_MIN:      rd_mux = st_p_min;
                A_P_MAX:      rd_mux = st_p_max;
                A_STAT_NW:    rd_mux = st_n_width;
                A_STAT_NP:    rd_mux = st_n_pulse;
                A_STAT_ERR:   rd_mux = {st_n_drop[15:0], st_n_sat[15:0]};
                A_MEM_ADDR:   rd_mux = {24'd0, st_mem_data};
                A_WR_PTR:     rd_mux = {16'd0, st_wr_ptr};
                A_STOP_PTR:   rd_mux = {16'd0, st_stop_ptr};
                A_BTN_CNT:    rd_mux = {16'd0, st_btn_cnt};
                default:      rd_mux = 32'd0;
            endcase
        end
    endfunction

endmodule
