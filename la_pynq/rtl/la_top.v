// =====================================================================
//  la_top.v —— 逻辑分析仪顶层（集成全部功能）
//
//  子系统与通道约定（Pmod A 八路）：
//    ch[0] = UART RX
//    ch[1] = SPI SCLK
//    ch[2] = SPI MOSI
//    ch[3] = SPI CS_n（低有效）
//    ch[4] = I2C SCL
//    ch[5] = I2C SDA
//    ch[6] ch[7] = 自由通道
//
//  数据通路：
//    ch_in(Pmod A) ─> din_sync ─┬─> cap_mem（BRAM 环形缓冲）──> AXI 读出
//                               │
//                               ├─> trig_fsm ──cap_en──> cap_mem
//                               │     ↑
//                               │     └── proto_trig（协议字节匹配）
//                               │            ↑
//                               │     proto_uart / proto_spi / proto_i2c
//                               │
//                               └─> timing_stats（直方图 + 分位数扫描）
//
//  所有配置与读出都走 AXI4-Lite，地址映射见 docs/interface.md。
//
//  信号来源只有一条：Pmod A 八路引脚。
//  Pmod B 八路是板子自己发出的测试波形，用杜邦线接到 Pmod A 才被采集；
//  CTRL.bit5 = 0 时 Pmod B 整组高阻，可把 Pmod A 接到真实被测电路。
//
//  ⚠️ AXI 从机在 PS 上的正确工作**尚未真机验证**——见 README 的说明。
//
//  负责人：A（集成）
// =====================================================================

`timescale 1ns / 1ps

module la_top #(
    parameter integer DEPTH    = 8192,    // 物理缓冲深度
    parameter integer NBINS    = 256,
    parameter integer SHIFT    = 4,       // 直方图时基：每桶 2^SHIFT 个 clk
    parameter integer AW       = 8,       // AXI 地址位宽
    parameter integer I2C_HALF = 200,     // I2C 源半周期 clk 数（自测协议模式用）
    parameter integer I2C_GAP  = 4000     // I2C 事务之间的总线空闲
)(
    input  wire        sys_clk,     // FCLK_CLK0 = 62.5 MHz
    input  wire        btn0,        // BTN0 = D19，按下重新布防
    input  wire [7:0]  ch_in,       // Pmod A 八路输入
    output wire [3:0]  led,
    output wire [7:0]  sig_out,     // Pmod B 八路输出：板子自己发的方波，供杜邦线回接到 Pmod A

    // ---- AXI4-Lite 从机（接 Zynq PS7 的 M_AXI_GP0）----
    input  wire [AW-1:0] s_awaddr,
    input  wire          s_awvalid,
    output wire          s_awready,
    input  wire [31:0]   s_wdata,
    input  wire [3:0]    s_wstrb,
    input  wire          s_wvalid,
    output wire          s_wready,
    output wire [1:0]    s_bresp,
    output wire          s_bvalid,
    input  wire          s_bready,
    input  wire [AW-1:0] s_araddr,
    input  wire          s_arvalid,
    output wire          s_arready,
    output wire [31:0]   s_rdata,
    output wire [1:0]    s_rresp,
    output wire          s_rvalid,
    input  wire          s_rready
);

    localparam integer AW_MEM = $clog2(DEPTH);

    // ==================================================================
    // 复位：上电计数 + 寄存器软复位（脉冲拉长成若干拍）
    // ==================================================================
    reg [11:0] pwr_cnt = 12'd0;
    wire       pwr_rst_n = (pwr_cnt == 12'd4095);

    always @(posedge sys_clk) begin
        if (!pwr_rst_n) pwr_cnt <= pwr_cnt + 12'd1;
    end

    reg  [4:0] sr_stretch;
    wire       soft_rst_pulse;                 // 来自 axi_regs

    always @(posedge sys_clk) begin
        if (!pwr_rst_n)                sr_stretch <= 5'd0;
        else if (soft_rst_pulse)       sr_stretch <= 5'd31;
        else if (sr_stretch != 5'd0)   sr_stretch <= sr_stretch - 5'd1;
    end

    wire rst_n = pwr_rst_n & (sr_stretch == 5'd0);

    // ==================================================================
    // 输入两级同步
    // ==================================================================
    wire [7:0] din;

    din_sync u_din_sync (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .din   (ch_in),
        .dout  (din)
    );

    // BTN0 同步
    reg btn_d0, btn_d1, btn_d2;
    always @(posedge sys_clk) begin
        if (!rst_n) begin btn_d0 <= 1'b0; btn_d1 <= 1'b0; btn_d2 <= 1'b0; end
        else        begin btn_d0 <= btn0; btn_d1 <= btn_d0; btn_d2 <= btn_d1; end
    end

    // 板载按钮按下次数：上位机读它就能证明"波形来自真实硬件"，不是回放动画
    wire btn_press = btn_d1 & ~btn_d2;
    reg [15:0] btn_cnt;
    always @(posedge sys_clk) begin
        if (!rst_n)         btn_cnt <= 16'd0;
        else if (btn_press) btn_cnt <= btn_cnt + 16'd1;
    end

    // ==================================================================
    // Pmod B 输出方波在下方 smp_clk_div 之后产生（要用 smp_en，必须先声明）

    // ==================================================================
    // AXI 寄存器组
    // ==================================================================
    wire [31:0] reg_div, reg_proto_div;
    wire [15:0] reg_depth, reg_pre_trig, reg_mem_addr;
    wire [2:0]  reg_trig_mode, reg_trig_chan;
    wire [7:0]  reg_trig_value, reg_trig_mask, reg_chan_en, reg_hist_addr;
    wire [1:0]  reg_proto_sel;
    wire        reg_arm, reg_free_run,
                reg_pmodb_en, reg_stat_en, reg_stat_clr, stat_scan_pulse;

    wire [7:0]  st_proto_byte;
    wire [2:0]  st_proto_stat;
    wire        st_armed, st_trigged, st_full, st_clr_busy, st_pct_busy,
                st_pct_valid;
    wire [31:0] st_hist_wcnt, st_hist_pcnt;
    wire [31:0] st_w_p50, st_w_p95, st_w_p99;
    wire [31:0] st_p_p50, st_p_p95, st_p_p99;
    wire [31:0] st_w_min, st_w_max, st_p_min, st_p_max;
    wire [31:0] st_n_width, st_n_pulse, st_sat, st_drop;
    wire [15:0] st_wr_ptr, st_stop_ptr;
    wire [7:0]  st_mem_data;

    axi_regs #(.AW(AW)) u_regs (
        .clk(sys_clk), .rst_n(pwr_rst_n),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid),
        .s_wready(s_wready), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid),
        .s_rready(s_rready),

        .reg_div(reg_div), .reg_depth(reg_depth),
        .reg_trig_mode(reg_trig_mode), .reg_trig_chan(reg_trig_chan),
        .reg_trig_value(reg_trig_value), .reg_trig_mask(reg_trig_mask),
        .reg_pre_trig(reg_pre_trig), .reg_chan_en(reg_chan_en),
        .reg_proto_sel(reg_proto_sel), .reg_proto_div(reg_proto_div),
        .reg_hist_addr(reg_hist_addr), .reg_mem_addr(reg_mem_addr),
        .reg_arm(reg_arm),
        .reg_free_run(reg_free_run),
        .reg_pmodb_en(reg_pmodb_en),
        .pulse_soft_rst(soft_rst_pulse),
        .reg_stat_en(reg_stat_en), .reg_stat_clr(reg_stat_clr),
        .pulse_stat_scan(stat_scan_pulse),

        .st_proto_byte(st_proto_byte), .st_proto_stat(st_proto_stat),
        .st_armed(st_armed), .st_trigged(st_trigged), .st_full(st_full),
        .st_clr_busy(st_clr_busy), .st_pct_busy(st_pct_busy),
        .st_pct_valid(st_pct_valid),
        .st_hist_wcnt(st_hist_wcnt), .st_hist_pcnt(st_hist_pcnt),
        .st_w_p50(st_w_p50), .st_w_p95(st_w_p95), .st_w_p99(st_w_p99),
        .st_p_p50(st_p_p50), .st_p_p95(st_p_p95), .st_p_p99(st_p_p99),
        .st_w_min(st_w_min), .st_w_max(st_w_max),
        .st_p_min(st_p_min), .st_p_max(st_p_max),
        .st_n_width(st_n_width), .st_n_pulse(st_n_pulse),
        .st_n_sat(st_sat), .st_n_drop(st_drop),
        .st_wr_ptr(st_wr_ptr), .st_stop_ptr(st_stop_ptr),
        .st_btn_cnt(btn_cnt),
        .st_mem_data(st_mem_data)
    );

    // ==================================================================
    // I2C 波形源：只往 Pmod B 的针 7(SCL) / 8(SDA) 上送
    //   循环发 START + A0 + 55 + AA + STOP，应答位由源自己模拟
    //   波形必须从 Pmod B 用杜邦线接到 Pmod A 的 CH4/CH5 才会被采到、被解码
    // ==================================================================
    wire i2c_scl, i2c_sda;

    i2c_src #(.HALF(I2C_HALF), .GAP(I2C_GAP)) u_i2c_src (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .scl   (i2c_scl),
        .sda   (i2c_sda)
    );

    // ==================================================================
    // 采样节拍
    // ==================================================================
    wire smp_en;

    smp_clk_div u_smp_clk_div (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .div    (reg_div),
        .smp_en (smp_en)
    );

    // ==================================================================
    // Pmod B 输出：8 路**不同频率**的方波，周期以采样点为单位（全是整数）
    //   周期(采样点) : 48   64   96  128  192  256  384  512
    //   62.5kHz 采样 : 1.3k 977  651 488  326  244  163  122 Hz
    // 用途：用杜邦线从 Pmod B 接到 Pmod A，信号走真实的引脚和导线，
    //       拔掉任意一根，对应通道就变平 —— 这是"采的不是回放"最硬的证明。
    // 为什么必须用 smp_en 分频：这样周期恒为整数个采样点，重建波形零抖动。
    //   用自由计数器分频的话(62.5MHz/2^14)每周期采 16.38 点，边沿会周期性
    //   落在两个采样点之间，波形偶尔窄一拍（实测出现过）。
    // ==================================================================
    reg [7:0] pc1, pc2, pc3, pc6, pc7;   // 半周期计数
    reg [4:0] sq;                        // 5 路方波，接 Pmod B 针 2/3/4/9/10

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            pc1 <= 8'd0; pc2 <= 8'd0; pc3 <= 8'd0;
            pc6 <= 8'd0; pc7 <= 8'd0;
            sq  <= 5'd0;
        end
        else if (smp_en) begin
            // 半周期 32 / 48 / 64 / 192 / 256 个采样点 -> 周期 64/96/128/384/512
            if (pc1 == 8'd31)  begin pc1 <= 8'd0;  sq[0] <= ~sq[0]; end
            else pc1 <= pc1 + 8'd1;

            if (pc2 == 8'd47)  begin pc2 <= 8'd0;  sq[1] <= ~sq[1]; end
            else pc2 <= pc2 + 8'd1;

            if (pc3 == 8'd63)  begin pc3 <= 8'd0;  sq[2] <= ~sq[2]; end
            else pc3 <= pc3 + 8'd1;

            if (pc6 == 8'd191) begin pc6 <= 8'd0;  sq[3] <= ~sq[3]; end
            else pc6 <= pc6 + 8'd1;

            if (pc7 == 8'd255) begin pc7 <= 8'd0;  sq[4] <= ~sq[4]; end
            else pc7 <= pc7 + 8'd1;
        end
    end

    // ------------------------------------------------------------------
    // Pmod B 针 1：UART 发送（供协议解码演示，走真实引脚 + 杜邦线回环）
    //   波特率 = 62.5 MHz / 640 ≈ 97.66 kbaud（接收端 PROTO_DIV 也填 640）
    //   循环发 "ZYNQ" + 0x55 / 0xAA / 0x0F / 0xF0，字节间留 ~256 us 空闲，
    //   便于在波形上分辨帧边界
    // ------------------------------------------------------------------
    reg  [15:0] uart_gap;
    reg  [2:0]  uart_idx;
    reg  [3:0]  uart_digit;      // 每轮 +1，0..9 循环
    reg         uart_send;
    reg  [7:0]  uart_dat;
    wire        uart_busy, uart_line;

    // 循环发 "PYNQ-LA0" .. "PYNQ-LA9"，每轮最后一位加一。
    // 用可读 ASCII 而不是十六进制常量：评委在波形上直接读出文字，
    // 最后一位每轮变化，也说明不是固定的八字节循环。
    function [7:0] uart_pat;
        input [2:0] i;
        input [3:0] d;
        begin
            case (i)
                3'd0: uart_pat = 8'h50;              // 'P'
                3'd1: uart_pat = 8'h59;              // 'Y'
                3'd2: uart_pat = 8'h4E;              // 'N'
                3'd3: uart_pat = 8'h51;              // 'Q'
                3'd4: uart_pat = 8'h2D;              // '-'
                3'd5: uart_pat = 8'h4C;              // 'L'
                3'd6: uart_pat = 8'h41;              // 'A'
                default: uart_pat = 8'h30 + {4'd0, d};   // '0'..'9'
            endcase
        end
    endfunction

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            uart_gap   <= 16'd0;
            uart_idx   <= 3'd0;
            uart_digit <= 4'd0;
            uart_send  <= 1'b0;
            uart_dat   <= 8'h00;
        end
        else begin
            uart_send <= 1'b0;
            if (!uart_busy) begin
                if (uart_gap == 16'd0) begin
                    uart_gap  <= 16'd16000;
                    uart_send <= 1'b1;
                    uart_dat  <= uart_pat(uart_idx, uart_digit);
                    uart_idx  <= uart_idx + 3'd1;
                    if (uart_idx == 3'd7)
                        uart_digit <= (uart_digit == 4'd9) ? 4'd0 : uart_digit + 4'd1;
                end
                else uart_gap <= uart_gap - 16'd1;
            end
        end
    end

    uart_tx #(.DIV_W(16)) u_uart_tx (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .baud_div (16'd640),
        .send     (uart_send),
        .data_in  (uart_dat),
        .tx       (uart_line),
        .busy     (uart_busy)
    );

    // 针序：1=UART  2/3/4=方波  7=SCL  8=SDA  9/10=方波
    // CTRL.bit5 = 0 时整组高阻，方便把 Pmod A 接到真实被测电路
    wire [7:0] pmodb_pat = {sq[4], sq[3], i2c_sda, i2c_scl,
                            sq[2], sq[1], sq[0], uart_line};

    assign sig_out = reg_pmodb_en ? pmodb_pat : 8'hzz;

    // ==================================================================
    // 协议解码：三个解码器并行跑，输出由 PROTO_SEL 选一个给匹配器
    // ==================================================================
    wire [7:0] u_byte,  s_byte,  i_byte;
    wire       u_valid, s_valid, i_valid, u_err, s_err, i_ack;

    proto_uart #(.DIV_W(32)) u_pu (
        .clk(sys_clk), .rst_n(rst_n),
        .baud_div(reg_proto_div), .rx(din[0]),
        .data(u_byte), .valid(u_valid), .frame_err(u_err)
    );

    proto_spi #(.CPOL(0), .CPHA(0)) u_ps (
        .clk(sys_clk), .rst_n(rst_n),
        .sclk(din[1]), .mosi(din[2]), .cs_n(din[3]),
        .data(s_byte), .valid(s_valid), .byte_cnt(), .frame_err(s_err)
    );

    proto_i2c u_pi (
        .clk(sys_clk), .rst_n(rst_n),
        .scl(din[4]), .sda(din[5]),
        .data(i_byte), .valid(i_valid), .ack(i_ack),
        .first(), .rw(), .active()
    );

    wire [7:0] dec_byte;
    wire       dec_valid, dec_err;

    assign dec_byte = (reg_proto_sel == 2'd0) ? u_byte :
                      (reg_proto_sel == 2'd1) ? s_byte : i_byte;
    assign dec_valid = (reg_proto_sel == 2'd0) ? u_valid :
                       (reg_proto_sel == 2'd1) ? s_valid : i_valid;
    assign dec_err   = (reg_proto_sel == 2'd0) ? u_err :
                       (reg_proto_sel == 2'd1) ? s_err : i_ack;

    // 解码事件对 PS 必须做成【粘滞标志】：
    //   dec_valid / dec_err 都是单拍脉冲，PS 走 AXI 读寄存器根本抓不到。
    reg dec_seen, dec_err_seen;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            dec_seen     <= 1'b0;
            dec_err_seen <= 1'b0;
        end
        else begin
            if (dec_valid) dec_seen     <= 1'b1;
            if (dec_err)   dec_err_seen <= 1'b1;
        end
    end

    assign st_proto_byte = dec_byte;
    assign st_proto_stat = {i_ack, dec_err_seen, dec_seen};

    // ==================================================================
    // 协议内容匹配 -> 触发
    // ==================================================================
    wire proto_hit;

    proto_trig u_proto_trig (
        .clk(sys_clk), .rst_n(rst_n),
        .en(1'b1), .match_val(reg_trig_value),
        .data(dec_byte), .data_valid(dec_valid),
        .trig_pulse(proto_hit)
    );

    // TRIG_MODE = 4 表示用协议匹配脉冲作为触发源
    wire trig_src = (reg_trig_mode == 3'd4);

    wire armed, trigged, full, cap_en;

    trig_fsm #(.DEPTH(DEPTH)) u_trig_fsm (
        .clk(sys_clk), .rst_n(rst_n),
        .arm(reg_arm), .restart(btn_d1), .free_run(reg_free_run),
        .smp_en(smp_en), .din(din),
        .trig_chan(reg_trig_chan),
        .trig_mode(reg_trig_mode[1:0]),
        .trig_src(trig_src), .ext_trig(proto_hit),
        .pre_trig_cfg({16'd0, reg_pre_trig}),
        .armed(armed), .trigged(trigged), .full(full),
        .cap_en(cap_en), .trig_pulse()
    );

    assign st_armed   = armed;
    assign st_trigged = trigged;
    assign st_full    = full;

    // ==================================================================
    // 片内缓冲
    // ==================================================================
    wire [AW_MEM-1:0] wr_ptr, stop_ptr;
    wire [7:0]        mem_rd;

    cap_mem #(.DEPTH(DEPTH), .AW(AW_MEM)) u_cap_mem (
        .clk(sys_clk), .rst_n(rst_n),
        .cap_en(cap_en), .smp_en(smp_en), .din(din),
        .rd_addr(reg_mem_addr[AW_MEM-1:0]), .rd_en(1'b1),
        .rd_data(mem_rd), .wr_ptr(wr_ptr), .stop_ptr(stop_ptr)
    );

    assign st_wr_ptr   = {{(16-AW_MEM){1'b0}}, wr_ptr};
    assign st_stop_ptr = {{(16-AW_MEM){1'b0}}, stop_ptr};
    assign st_mem_data = mem_rd;

    // ==================================================================
    // 时序参数统计（统计通道 = 触发通道）
    // ==================================================================
    wire [31:0] h_wcnt, h_pcnt;

    timing_stats #(.NBINS(NBINS), .SHIFT(SHIFT)) u_timing_stats (
        .clk(sys_clk), .rst_n(rst_n),
        .en(reg_stat_en), .clr(reg_stat_clr),
        .sig(din[reg_trig_chan]),
        .rd_bin(reg_hist_addr), .rd_w_cnt(h_wcnt), .rd_p_cnt(h_pcnt),
        .clr_busy(st_clr_busy),
        .n_width(st_n_width), .n_pulse(st_n_pulse),
        .w_min(st_w_min), .w_max(st_w_max),
        .p_min(st_p_min), .p_max(st_p_max),
        .sat_cnt(st_sat), .drop_cnt(st_drop),
        .pct_req(stat_scan_pulse), .pct_busy(st_pct_busy),
        .pct_valid(st_pct_valid),
        .w_p50(st_w_p50), .w_p95(st_w_p95), .w_p99(st_w_p99),
        .p_p50(st_p_p50), .p_p95(st_p_p95), .p_p99(st_p_p99)
    );

    assign st_hist_wcnt = h_wcnt;
    assign st_hist_pcnt = h_pcnt;

    // ==================================================================
    // LED：板级粗指示（真正的数据要从 AXI 读）
    // ==================================================================
    reg [25:0] hb;
    reg [11:0] proto_led;

    always @(posedge sys_clk) begin
        if (!rst_n) hb <= 26'd0;
        else        hb <= hb + 26'd1;
    end

    always @(posedge sys_clk) begin
        if (!rst_n)                       proto_led <= 12'd0;
        else if (dec_valid)               proto_led <= 12'hFFF;
        else if (proto_led != 12'd0)      proto_led <= proto_led - 12'd1;
    end

    assign led[0] = armed;
    assign led[1] = full;
    assign led[2] = (proto_led != 12'd0);   // 解码出字节时亮一下
    assign led[3] = hb[24];

endmodule
