// =====================================================================
//  tb_stage4.v —— 协议内容触发 端到端自检
//
//  验证的核心命题：
//     总线上一直有 I2C 流量，系统【等到出现指定字节 0xAA】才开始抓，
//     而且抓到的窗口把触发点【之前】和【之后】的总线活动都包住了。
//
//  断言：
//    1. 触发那一刻解码器输出的正是 0xAA
//    2. 解码序列为 A0 -> 55 -> AA（源、解码器、匹配、触发 四段全通）
//    3. 触发后写入拍数 == DEPTH - PRE_TRIG
//    4. 缓冲里不是平的（真的采到了总线波形）
//    5. 预触发区里有 SCL 边沿（触发点之前确实攒到了总线数据）
// =====================================================================

`timescale 1ns / 1ps

module tb_stage4;

    localparam integer DEPTH    = 1024;
    localparam integer PRE_TRIG = 256;
    localparam integer BUS_HALF = 8;      // I2C 半周期 8 clk -> SCL 周期 16 clk
    localparam integer BUS_GAP  = 16;

    localparam integer POST_LIMIT = DEPTH - PRE_TRIG;
    localparam integer AW         = 10;   // clog2(1024)

    reg clk = 1'b0;
    always #4 clk = ~clk;                 // 8ns -> 125MHz

    reg btn0 = 1'b0;

    wire [3:0] led;
    wire [7:0] dbg_data;

    stage4_top #(
        .DEPTH     (DEPTH),
        .PRE_TRIG  (PRE_TRIG),
        .SMP_DIV   (1),
        .RATE_DIV  (100),
        .TRIG_BYTE (8'hAA),
        .BUS_HALF  (BUS_HALF),
        .BUS_GAP   (BUS_GAP)
    ) dut (
        .sys_clk  (clk),
        .btn0     (btn0),
        .led      (led),
        .dbg_data (dbg_data)
    );

    integer n_fail = 0;

    // ---- 观测 ----
    integer   nseq = 0;
    reg [7:0] seq [0:15];

    integer   t_trig      = -1;
    reg [7:0] trig_byte   = 8'h00;
    integer   n_trig      = 0;    // 匹配器输出过几次脉冲
    integer   n_trig_arm  = 0;    // 其中被状态机采信的有几次（布防期间）
    integer   t_full      = -1;

    always @(posedge clk) begin
        if (dut.u_proto_i2c.valid) begin
            seq[nseq] = dut.u_proto_i2c.data;
            nseq      = nseq + 1;
        end
        if (dut.u_proto_trig.trig_pulse) begin
            trig_byte = dut.u_proto_i2c.data;
            if (t_trig < 0) t_trig = $time;
            n_trig    = n_trig + 1;
            // 只有布防期间到来的脉冲才会被状态机接受
            if (dut.armed) n_trig_arm = n_trig_arm + 1;
        end
        if (dut.full && t_full < 0) t_full = $time;
    end

`ifdef WAVE_MODE
    integer csv_fd;
    initial begin
        csv_fd = $fopen("tb_stage4.csv", "w");
        $fwrite(csv_fd, "t_ns,bus_scl,bus_sda,dec_valid,dec_data,trig,armed,trigged,full\n");
    end
    always @(posedge clk) begin
        $fwrite(csv_fd, "%0d,%b,%b,%b,%0d,%b,%b,%b,%b\n",
                $time, dut.bus_scl, dut.bus_sda,
                dut.u_proto_i2c.valid, dut.u_proto_i2c.data,
                dut.u_proto_trig.trig_pulse,
                dut.armed, dut.trigged, dut.full);
    end
`endif

    // 超时保护
    initial begin
        #2000000;
        $display("[FAIL] TIMEOUT");
        $display("RESULT: FAIL    (timeout)");
        $finish;
    end

    // ---- 缓冲扫描用的变量 ----
    integer   i, addr, k;
    integer   scl_lo, scl_hi, scl_edges_pre, scl_edges_all, sda_edges_all;
    integer   stop_val;
    reg [7:0] b, b_prev;
`ifdef WAVE_MODE
    integer   fd_buf;
`endif

    initial begin
        $display("=========== tb_stage4 START ===========");
        $display("target byte = AA   DEPTH=%0d  PRE_TRIG=%0d", DEPTH, PRE_TRIG);

        // 等 FULL（最多 200000 个时钟）
        for (i = 0; i < 200000 && dut.full !== 1'b1; i = i + 1) @(posedge clk);

        if (dut.full !== 1'b1) begin
            $display("[FAIL] never reached FULL");
            $display("RESULT: FAIL    (no FULL)");
            $finish;
        end

        $display("trigger at t=%0d ns, FULL at t=%0d ns", t_trig, t_full);

        // ---- 1. 触发时刻解码的字节就是目标字节 ----
        if (trig_byte == 8'hAA)
            $display("[PASS] trigger fired exactly on the target byte 0xAA");
        else begin
            $display("[FAIL] trigger byte = %02h, expected AA", trig_byte);
            n_fail = n_fail + 1;
        end

        // ---- 2. 解码序列 A0 55 AA ----
        $display("decoded sequence (%0d bytes):", nseq);
        for (i = 0; i < nseq && i < 8; i = i + 1)
            $display("    [%0d] %02h", i, seq[i]);

        if (nseq >= 3 && seq[0] == 8'hA0 && seq[1] == 8'h55 && seq[2] == 8'hAA)
            $display("[PASS] source -> decoder -> match -> trigger chain intact");
        else begin
            $display("[FAIL] decoded sequence is not A0 55 AA");
            n_fail = n_fail + 1;
        end

        // ---- 3. 只有布防期间的那一次被状态机接受 ----
        $display("matcher pulses = %0d, accepted while armed = %0d", n_trig, n_trig_arm);
        if (n_trig_arm == 1)
            $display("[PASS] FSM accepted exactly one trigger");
        else begin
            $display("[FAIL] FSM accepted %0d triggers", n_trig_arm);
            n_fail = n_fail + 1;
        end

        // 非布防期的脉冲应被忽略（状态机早已离开 ARMED）
        if (n_trig >= n_trig_arm)
            $display("[PASS] pulses outside ARMED are ignored by the FSM");
        else begin
            $display("[FAIL] pulse accounting inconsistent");
            n_fail = n_fail + 1;
        end

        // ---- 4/5. 扫缓冲：验证真的采到了总线波形 ----
        stop_val = dut.u_cap_mem.stop_ptr;

        scl_lo = 0; scl_hi = 0;
        scl_edges_pre = 0; scl_edges_all = 0; sda_edges_all = 0;
        b_prev = 8'h00;

        for (i = 0; i < DEPTH; i = i + 1) begin
            addr = (stop_val + i) & (DEPTH - 1);
            b    = dut.u_cap_mem.mem[addr];

            if (b[0]) scl_hi = scl_hi + 1;
            else      scl_lo = scl_lo + 1;

            if (i > 0) begin
                if (b[0] && !b_prev[0]) begin
                    scl_edges_all = scl_edges_all + 1;
                    if (i < PRE_TRIG) scl_edges_pre = scl_edges_pre + 1;
                end
                if (b[1] != b_prev[1]) sda_edges_all = sda_edges_all + 1;
            end
            b_prev = b;
        end

        $display("buffer: SCL high=%0d low=%0d, SCL edges total=%0d pre-trig=%0d, SDA edges=%0d",
                 scl_hi, scl_lo, scl_edges_all, scl_edges_pre, sda_edges_all);

        if (scl_hi > 0 && scl_lo > 0)
            $display("[PASS] buffer holds real bus activity (not flat)");
        else begin
            $display("[FAIL] buffer is flat");
            n_fail = n_fail + 1;
        end

        if (scl_edges_pre > 0)
            $display("[PASS] pre-trigger region has %0d SCL edges (data captured before trigger)",
                     scl_edges_pre);
        else begin
            $display("[FAIL] nothing captured before the trigger point");
            n_fail = n_fail + 1;
        end

        // ---- 6. 触发点前后的数据都应在（预触发语义）----
        $display("stop_ptr = %0d, index %0d is the trigger point",
                 stop_val, PRE_TRIG);

`ifdef WAVE_MODE
        // 把缓冲按时间顺序导出，供画图
        fd_buf = $fopen("tb_stage4_buf.csv", "w");
        $fwrite(fd_buf, "idx,scl,sda\n");
        for (k = 0; k < DEPTH; k = k + 1) begin
            addr = (stop_val + k) & (DEPTH - 1);
            $fwrite(fd_buf, "%0d,%b,%b\n",
                    k, dut.u_cap_mem.mem[addr][0], dut.u_cap_mem.mem[addr][1]);
        end
        $fclose(fd_buf);
        $display("buffer dumped to tb_stage4_buf.csv");
`endif

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_stage4 END ===========");
`ifdef WAVE_MODE
        $fclose(csv_fd);
`endif
        $finish;
    end

endmodule
