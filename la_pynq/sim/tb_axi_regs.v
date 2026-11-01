// =====================================================================
//  tb_axi_regs.v —— axi_regs 自检 testbench（对应 interface.md 冻结版 v2）
//
//  这个 TB 里有一个【AXI4-Lite 主机模型】：它自己产生 AW/W/B/AR/R
//  五个通道的握手时序，所以不需要 PS、不需要板子就能验证 AXI 协议。
//
//  ⚠️ 注意这个 TB 的局限：主机模型只发我们构造的合法事务。
//     真实的 AXI 主机是 Zynq PS7 的 GP 口，中间还隔着 AXI Interconnect。
//     "PS 发送从机不认识的事务导致总线挂死"这类问题本 TB 发现不了，
//     因此 axi_regs 的状态只能算"待真机验证"。
//
//  验证：
//    1. 复位后 STATUS 全 0
//    2. 各配置寄存器写后能读回原值（含新增的协议/统计寄存器）
//    3. CTRL.bit1 是单拍脉冲（soft reset）
//    4. STAT_CTRL.bit2 是单拍脉冲（扫描启动）
//    5. STATUS 各状态位逐个置位后能正确读出
//    6. 只读寄存器（WR_PTR / STOP_PTR / MEM_ADDR）读值正确
//    7. 往只读寄存器写值必须被忽略
// =====================================================================

`timescale 1ns / 1ps

module tb_axi_regs;

    localparam integer AW = 8;

    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg rst_n = 1'b0;

    // ---- AXI4-Lite 主机侧 ----
    reg  [AW-1:0] s_awaddr  = {AW{1'b0}};
    reg           s_awvalid = 1'b0;
    wire          s_awready;
    reg  [31:0]   s_wdata   = 32'd0;
    reg  [3:0]    s_wstrb   = 4'hF;
    reg           s_wvalid  = 1'b0;
    wire          s_wready;
    wire [1:0]    s_bresp;
    wire          s_bvalid;
    reg           s_bready  = 1'b0;
    reg  [AW-1:0] s_araddr  = {AW{1'b0}};
    reg           s_arvalid = 1'b0;
    wire          s_arready;
    wire [31:0]   s_rdata;
    wire [1:0]    s_rresp;
    wire          s_rvalid;
    reg           s_rready  = 1'b0;

    // ---- 用户侧：配置输出 ----
    wire [31:0] reg_div, reg_proto_div;
    wire [15:0] reg_depth, reg_pre_trig, reg_mem_addr;
    wire [2:0]  reg_trig_mode, reg_trig_chan;
    wire [7:0]  reg_trig_value, reg_trig_mask, reg_chan_en, reg_hist_addr;
    wire [1:0]  reg_proto_sel;
    wire        reg_arm, pulse_soft_rst, reg_stat_en, reg_stat_clr, pulse_stat_scan;
    wire        reg_selftest, reg_selftest_proto, reg_free_run, reg_pmodb_en;

    // ---- 用户侧：状态输入 ----
    reg  [7:0]  st_proto_byte = 8'h3C;
    reg  [2:0]  st_proto_stat = 3'b001;
    reg         st_armed = 1'b0, st_trigged = 1'b0, st_full = 1'b0;
    reg         st_clr_busy = 1'b0, st_pct_busy = 1'b0, st_pct_valid = 1'b0;
    reg  [31:0] st_hist_wcnt = 32'd40, st_hist_pcnt = 32'd39;
    reg  [31:0] st_w_p50 = 32'd6,  st_w_p95 = 32'd18, st_w_p99 = 32'd66;
    reg  [31:0] st_p_p50 = 32'd106, st_p_p95 = 32'd118, st_p_p99 = 32'd166;
    reg  [31:0] st_w_min = 32'd4, st_w_max = 32'd64;
    reg  [31:0] st_p_min = 32'd104, st_p_max = 32'd164;
    reg  [31:0] st_n_width = 32'd64, st_n_pulse = 32'd63;
    reg  [31:0] st_n_sat = 32'd0, st_n_drop = 32'd0;
    reg  [15:0] st_wr_ptr = 16'h1234, st_stop_ptr = 16'h5678;
    reg  [7:0]  st_mem_data = 8'hA5;

    // 统计脉冲计数
    integer n_soft_rst = 0, n_scan = 0;
    always @(posedge clk) begin
        if (pulse_soft_rst)  n_soft_rst = n_soft_rst + 1;
        if (pulse_stat_scan) n_scan      = n_scan + 1;
    end

    axi_regs #(.AW(AW)) dut (
        .clk(clk), .rst_n(rst_n),
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
        .reg_arm(reg_arm), .pulse_soft_rst(pulse_soft_rst),
        .reg_selftest(reg_selftest),
        .reg_selftest_proto(reg_selftest_proto),
        .reg_free_run(reg_free_run),
        .reg_pmodb_en(reg_pmodb_en),
        .reg_stat_en(reg_stat_en), .reg_stat_clr(reg_stat_clr),
        .pulse_stat_scan(pulse_stat_scan),
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
        .st_n_sat(st_n_sat), .st_n_drop(st_n_drop),
        .st_wr_ptr(st_wr_ptr), .st_stop_ptr(st_stop_ptr),
        .st_btn_cnt(16'd7),
        .st_mem_data(st_mem_data)
    );

    integer    n_fail = 0;
    reg [31:0] rv;

    // 超时保护：握手卡住时能退出来，而不是让仿真永远挂着
    initial begin
        #200000;
        $display("[FAIL] TIMEOUT - AXI handshake stuck");
        $display("RESULT: FAIL    (timeout)");
        $finish;
    end

    // ---- AXI4-Lite 主机模型：写 ----
    // 关键：bready 必须等 bvalid 拉高之后再给，否则从机在同一拍
    // "置位 valid" 和 "响应 ready" 撞在一起，valid 永远出不来。
    // 主机模型：bready **预先就位**（真实 PS/ARM 主机的常见做法）。
    //  这一点是关键：旧版从机在"ready 预先为高"时会把 bvalid 当场清掉，
    //  永远输出不出去；而"先等 valid 再拉 ready"的友好模型测不出来 ——
    //  这正是仿真 39 项全过、真机却挂死整机的原因。
    task axi_write(input [AW-1:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            s_awaddr  = addr;
            s_wdata   = data;
            s_wstrb   = 4'hF;
            s_awvalid = 1'b1;
            s_wvalid  = 1'b1;
            s_bready  = 1'b1;

            @(negedge clk);
            while (!s_awready) @(negedge clk);
            s_awvalid = 1'b0;
            s_wvalid  = 1'b0;

            @(negedge clk);
            while (!s_bvalid) @(negedge clk);
            @(negedge clk);          // 跨越握手完成的 posedge
            s_bready = 1'b0;
            @(negedge clk);
        end
    endtask

    // ---- AXI4-Lite 主机模型：读 ----
    // 主机模型：rready **预先就位**（同写通道，真实主机行为）。
    task axi_read(input [AW-1:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            s_araddr  = addr;
            s_arvalid = 1'b1;
            s_rready  = 1'b1;

            @(negedge clk);
            while (!s_arready) @(negedge clk);
            s_arvalid = 1'b0;

            @(negedge clk);
            while (!s_rvalid) @(negedge clk);
            data = s_rdata;
            @(negedge clk);          // 跨越握手完成的 posedge
            s_rready = 1'b0;
            @(negedge clk);
        end
    endtask

    task check(input [31:0] got, input [31:0] want, input [8*32-1:0] name);
        begin
            if (got !== want) begin
                $display("  [FAIL] %0s : got 0x%h, want 0x%h", name, got, want);
                n_fail = n_fail + 1;
            end
            else
                $display("  [PASS] %0s = 0x%h", name, got);
        end
    endtask

    initial begin
        $display("=========== tb_axi_regs START ===========");
        $display("interface.md v2  AW=%0d", AW);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- 1. 复位后状态 ----
        $display("--- reset state ---");
        axi_read(8'h04, rv);
        check(rv, 32'd0, "STATUS after reset");

        // ---- 2. 采集配置寄存器写后读回 ----
        $display("--- acquisition config ---");
        axi_write(8'h08, 32'd2500);   axi_read(8'h08, rv); check(rv, 32'd2500, "DIV");
        axi_write(8'h0C, 32'd1024);   axi_read(8'h0C, rv); check(rv, 32'd1024, "DEPTH");
        axi_write(8'h10, 32'd4);      axi_read(8'h10, rv); check(rv, 32'd4,    "TRIG_MODE");
        axi_write(8'h14, 32'd3);      axi_read(8'h14, rv); check(rv, 32'd3,    "TRIG_CHAN");
        axi_write(8'h18, 32'hAA);     axi_read(8'h18, rv); check(rv, 32'hAA,   "TRIG_VALUE");
        axi_write(8'h1C, 32'h0F);     axi_read(8'h1C, rv); check(rv, 32'h0F,   "TRIG_MASK");
        axi_write(8'h20, 32'd8192);   axi_read(8'h20, rv); check(rv, 32'd8192, "PRE_TRIG");
        axi_write(8'h24, 32'hFF);     axi_read(8'h24, rv); check(rv, 32'hFF,   "CHAN_EN");

        // ---- 3. 协议寄存器 ----
        $display("--- protocol ---");
        axi_write(8'h28, 32'd2);      axi_read(8'h28, rv); check(rv, 32'd2,    "PROTO_SEL");
        axi_write(8'h2C, 32'd1085);   axi_read(8'h2C, rv); check(rv, 32'd1085, "PROTO_DIV");
        axi_read(8'h30, rv);          check(rv, 32'h3C, "PROTO_BYTE (RO)");
        axi_read(8'h34, rv);          check(rv, 32'h1,  "PROTO_STAT (RO)");

        // ---- 4. 统计寄存器 ----
        $display("--- timing stats ---");
        axi_write(8'h40, 32'd26);     axi_read(8'h40, rv); check(rv, 32'd26,   "HIST_ADDR");
        axi_read(8'h44, rv);          check(rv, 32'd40,   "HIST_WCNT (RO)");
        axi_read(8'h48, rv);          check(rv, 32'd39,   "HIST_PCNT (RO)");
        axi_read(8'h4C, rv);          check(rv, 32'd6,    "W_P50 (RO)");
        axi_read(8'h54, rv);          check(rv, 32'd66,   "W_P99 (RO)");
        axi_read(8'h58, rv);          check(rv, 32'd106,  "P_P50 (RO)");
        axi_read(8'h60, rv);          check(rv, 32'd166,  "P_P99 (RO)");
        axi_read(8'h74, rv);          check(rv, 32'd64,   "STAT_NW (RO)");
        axi_read(8'h78, rv);          check(rv, 32'd63,   "STAT_NP (RO)");
        axi_read(8'h7C, rv);          check(rv, 32'd0,    "STAT_ERR (RO)");

        // ---- 5. 数据读出与指针 ----
        $display("--- data readout ---");
        axi_read(8'h84, rv);          check(rv, 32'h1234, "WR_PTR (RO)");
        axi_read(8'h88, rv);          check(rv, 32'h5678, "STOP_PTR (RO)");
        axi_read(8'h80, rv);          check(rv, 32'hA5,   "MEM_ADDR data (RO)");

        st_mem_data = 8'h5A;
        @(negedge clk);
        axi_read(8'h80, rv);          check(rv, 32'h5A,   "MEM_ADDR updated");

        // ---- 6. 脉冲型寄存器：写一次只能产生一个脉冲 ----
        $display("--- pulse outputs ---");
        n_soft_rst = 0;
        axi_write(8'h00, 32'h2);                 // CTRL.bit1 = soft reset
        repeat (10) @(posedge clk);
        if (n_soft_rst == 1) $display("  [PASS] soft reset emitted exactly 1 pulse");
        else begin
            $display("  [FAIL] soft reset emitted %0d pulses", n_soft_rst);
            n_fail = n_fail + 1;
        end

        n_scan = 0;
        axi_write(8'h38, 32'h4);                 // STAT_CTRL.bit2 = scan
        repeat (10) @(posedge clk);
        if (n_scan == 1) $display("  [PASS] scan request emitted exactly 1 pulse");
        else begin
            $display("  [FAIL] scan request emitted %0d pulses", n_scan);
            n_fail = n_fail + 1;
        end

        // ---- 7. 电平型寄存器：保持到最后一次写入 ----
        $display("--- level outputs ---");
        axi_write(8'h38, 32'h1);                 // 统计使能 = 1
        repeat (5) @(posedge clk);
        check({31'd0, reg_stat_en}, 32'd1, "STAT_CTRL.en held high");
        axi_write(8'h38, 32'h0);
        repeat (5) @(posedge clk);
        check({31'd0, reg_stat_en}, 32'd0, "STAT_CTRL.en held low");

        // ---- 8. arm 位与 STATUS ----
        $display("--- arm and status ---");
        axi_write(8'h00, 32'h1);
        axi_read (8'h00, rv);         check(rv[0], 32'd1, "CTRL.arm");

        st_armed = 1'b1; st_trigged = 1'b0; st_full = 1'b0;
        @(negedge clk);
        axi_read(8'h04, rv);          check(rv, 32'd1, "STATUS.armed");

        st_armed = 1'b0; st_trigged = 1'b1;
        @(negedge clk);
        axi_read(8'h04, rv);          check(rv, 32'd2, "STATUS.trigged");

        st_trigged = 1'b0; st_full = 1'b1;
        @(negedge clk);
        axi_read(8'h04, rv);          check(rv, 32'd4, "STATUS.full");

        st_clr_busy = 1'b1;
        @(negedge clk);
        axi_read(8'h04, rv);          check(rv, 32'd12, "STATUS.full+clr_busy");

        // ---- 8b. CTRL 自测源两位：bit2 方波源 / bit3 协议源 ----
        $display("--- CTRL selftest bits ---");
        axi_write(8'h00, 32'h4);              // 只要方波源
        axi_read (8'h00, rv);
        check(rv[2], 32'd1, "CTRL.selftest set");
        check(rv[3], 32'd0, "CTRL.selftest_proto clear");
        check({31'd0, reg_selftest}, 32'd1,         "reg_selftest = 1");
        check({31'd0, reg_selftest_proto}, 32'd0,   "reg_selftest_proto = 0");

        axi_write(8'h00, 32'hC);              // 方波源 + 协议源
        axi_read (8'h00, rv);
        check(rv[2], 32'd1, "CTRL.selftest still set");
        check(rv[3], 32'd1, "CTRL.selftest_proto set");
        check({31'd0, reg_selftest_proto}, 32'd1,   "reg_selftest_proto = 1");

        axi_write(8'h00, 32'h0);              // 清回
        axi_read (8'h00, rv);
        check(rv[3:0], 32'd0, "CTRL bits 2:0 cleared");

        // ---- 8c. CTRL.bit4 自由运行 ----
        $display("--- CTRL free_run bit ---");
        axi_write(8'h00, 32'h10);
        axi_read (8'h00, rv);
        check(rv[4], 32'd1, "CTRL.free_run set");
        check({31'd0, reg_free_run}, 32'd1, "reg_free_run = 1");
        axi_write(8'h00, 32'h30);       // free_run + pmodb_en
        axi_read (8'h00, rv);
        check(rv[5], 32'd1, "CTRL.bit5 pmodb_en set");
        axi_write(8'h00, 32'h10);       // 只留 free_run
        axi_read (8'h00, rv);
        check(rv[5], 32'd0, "CTRL.bit5 pmodb_en cleared");
        axi_write(8'h00, 32'h0);
        axi_read (8'h00, rv);
        check(rv[4], 32'd0, "CTRL.free_run cleared");

        // ---- 9. 往只读寄存器写必须无效 ----
        $display("--- illegal write must be ignored ---");
        axi_write(8'h84, 32'hDEAD);
        axi_read (8'h84, rv);         check(rv, 32'h1234, "WR_PTR unchanged");
        axi_write(8'h88, 32'hBEEF);
        axi_read (8'h88, rv);         check(rv, 32'h5678, "STOP_PTR unchanged");
        axi_read (8'h8C, rv);         check(rv, 32'd7, "BTN_CNT readback");
        axi_write(8'h44, 32'h99);
        axi_read (8'h44, rv);         check(rv, 32'd40,   "HIST_WCNT unchanged");

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_axi_regs END ===========");
        $finish;
    end

endmodule
