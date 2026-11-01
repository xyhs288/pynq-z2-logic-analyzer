// =====================================================================
//  tb_stage3.v —— 完整链路自检 testbench
//
//  用缩小的参数实例化 stage3_top，把仿真压到几十微秒：
//    DEPTH=64  PRE_TRIG=16  SMP_DIV=8  RATE_DIV=16  SRC_MSB=7
//
//  这样 ARMED 期间跑 16 个采样点、触发后写 48 个点，正好写满一圈，
//  缓冲里就是"触发前 16 点 + 触发后 48 点"，符合设计预期。
//
//  检查四件事：
//    1. 触发 -> FULL 走完
//    2. 触发点处的 CH0 有 0->1 跳变（说明时间顺序对）
//    3. FULL 之后 wr_ptr 冻结（写入真的停了）
//    4. 重放计数器在动（读出通路活着）
// =====================================================================

`timescale 1ns / 1ps

module tb_stage3;

    localparam integer DEPTH    = 64;
    localparam integer PRE_TRIG = 16;
    localparam integer SMP_DIV  = 8;
    localparam integer RATE_DIV = 16;
    localparam integer SRC_MSB  = 7;
    localparam integer AW       = 6;

    reg clk  = 1'b0;
    always #4 clk = ~clk;

    reg  btn0 = 1'b0;
    wire [3:0] led;
    wire [7:0] dbg_data;

    stage3_top #(
        .DEPTH    (DEPTH),
        .PRE_TRIG (PRE_TRIG),
        .SMP_DIV  (SMP_DIV),
        .RATE_DIV (RATE_DIV),
        .SRC_MSB  (SRC_MSB)
    ) dut (
        .sys_clk  (clk),
        .btn0     (btn0),
        .led      (led),
        .dbg_data (dbg_data)
    );

`ifdef WAVE_MODE
    integer csv_fd;
    initial begin
        csv_fd = $fopen("tb_stage3.csv", "w");
        $fwrite(csv_fd, "t_ns,armed,trigged,full,cap_en,smp_en,wr,stop,r_cnt,rd_data,led\n");
    end
    always @(posedge clk) begin
        $fwrite(csv_fd, "%0d,%b,%b,%b,%b,%b,%0d,%0d,%0d,%0d,%0d\n",
                $time, dut.armed, dut.trigged, dut.full, dut.cap_en, dut.smp_en,
                dut.wr_ptr, dut.stop_ptr, dut.r_cnt, dut.rd_data, led);
    end
`endif

    integer      n_fail = 0;
    integer      t_trig = 0;
    integer      t_full = 0;
    reg [AW-1:0] a_pre, a_post;
    reg [7:0]    v_pre, v_post;

    // 观测触发 / FULL 时刻
    reg got_trig = 1'b0, got_full = 1'b0;

    always @(posedge clk) begin
        if (dut.trigged && !got_trig) begin
            got_trig = 1'b1;
            t_trig   = $time;
            $display("T=%0d ns  TRIGGERED", $time);
        end
        if (dut.full && !got_full) begin
            got_full = 1'b1;
            t_full   = $time;
            $display("T=%0d ns  FULL   wr_ptr=%0d  stop_ptr=%0d",
                     $time, dut.wr_ptr, dut.stop_ptr);
        end
    end

    // FULL 后 wr_ptr 是否冻结
    reg [AW-1:0] wr_at_full;
    reg [AW-1:0] wr_later;
    integer      r_snap_a, r_snap_b;

    initial begin
        $display("=========== tb_stage3 START ===========");
        $display("DEPTH=%0d PRE_TRIG=%0d SMP_DIV=%0d RATE_DIV=%0d SRC_MSB=%0d",
                 DEPTH, PRE_TRIG, SMP_DIV, RATE_DIV, SRC_MSB);

        // ---- 1. 等 FULL（最多等 20000 个时钟）----
        begin : wait_full
            integer w;
            for (w = 0; w < 20000 && dut.full !== 1'b1; w = w + 1) @(posedge clk);
        end
        if (dut.full !== 1'b1) begin
            $display("[FAIL] timeout waiting for FULL");
            $finish;
        end

        wr_at_full = dut.wr_ptr;
        $display("-----------------------------------------");
        $display("elapsed trigger->FULL = %0d ns  (expect %0d ns)",
                 t_full - t_trig, (DEPTH - PRE_TRIG) * SMP_DIV * 8);

        // ---- 2. 触发点处的 CH0 跳变 ----
        a_pre  = dut.stop_ptr + (PRE_TRIG - 1);
        a_post = dut.stop_ptr + PRE_TRIG;
        v_pre  = dut.u_cap_mem.mem[a_pre];
        v_post = dut.u_cap_mem.mem[a_post];

        $display("addr[stop+%0d] = %08b  (CH0=%b)", PRE_TRIG - 1, v_pre,  v_pre[0]);
        $display("addr[stop+%0d] = %08b  (CH0=%b)", PRE_TRIG,     v_post, v_post[0]);

        if (v_pre[0] === 1'b0 && v_post[0] === 1'b1)
            $display("[PASS] CH0 has a 0->1 transition exactly at the trigger point");
        else begin
            $display("[FAIL] CH0 transition not at the expected index");
            n_fail = n_fail + 1;
        end

        // ---- 2b. 缓冲里的数据必须有变化（否则说明根本没采到东西）----
        begin : check_not_flat
            integer j;
            integer ones;
            integer distinct;
            reg [7:0] first;
            ones     = 0;
            distinct = 0;
            first    = dut.u_cap_mem.mem[0];
            for (j = 0; j < DEPTH; j = j + 1) begin
                if (dut.u_cap_mem.mem[j] != 8'h00)  ones     = ones + 1;
                if (dut.u_cap_mem.mem[j] !== first) distinct = distinct + 1;
            end
            $display("non-zero samples = %0d / %0d ,  differing from mem[0] = %0d",
                     ones, DEPTH, distinct);
            if (distinct > 0)
                $display("[PASS] buffer holds changing data (real samples)");
            else begin
                $display("[FAIL] buffer is constant - nothing was sampled");
                n_fail = n_fail + 1;
            end
        end

        // ---- 3. FULL 之后 wr_ptr 必须冻结 ----
        #2000;
        wr_later = dut.wr_ptr;
        $display("wr_ptr at FULL = %0d , 2000ns later = %0d", wr_at_full, wr_later);
        if (wr_at_full == wr_later)
            $display("[PASS] wr_ptr frozen after FULL (writes really stopped)");
        else begin
            $display("[FAIL] wr_ptr still moving after FULL");
            n_fail = n_fail + 1;
        end

        // ---- 4. 重放计数器在动 ----
        r_snap_a = dut.r_cnt;
        #((RATE_DIV + 4) * 8);
        r_snap_b = dut.r_cnt;
        $display("replay r_cnt: %0d -> %0d", r_snap_a, r_snap_b);
        if (r_snap_a != r_snap_b)
            $display("[PASS] replay counter is running (read path alive)");
        else begin
            $display("[FAIL] replay counter stuck");
            n_fail = n_fail + 1;
        end

        // ---- 5. led[1] 应表示 FULL ----
        if (led[1] === 1'b1)
            $display("[PASS] led[1] asserts FULL");
        else begin
            $display("[FAIL] led[1] not asserting FULL");
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_stage3 END ===========");
`ifdef WAVE_MODE
        $fclose(csv_fd);
`endif
        $finish;
    end

endmodule
