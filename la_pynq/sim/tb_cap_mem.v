// =====================================================================
//  tb_cap_mem.v —— cap_mem 自检 testbench
//
//  用 DEPTH=16 的小缓冲写 20 个递增数据，专门验证环形回绕：
//    1. wr_ptr 写完 20 个点后 == 20 mod 16 == 4
//    2. cap_en 落下后 stop_ptr 锁存为 4（最老数据的位置）
//    3. cap_en 落下后再发节拍，wr_ptr 不许动
//    4. 从 stop_ptr 顺序读 16 个点，应得到时间顺序的 4,5,6,...,19
// =====================================================================

`timescale 1ns / 1ps

module tb_cap_mem;

    localparam integer DEPTH  = 16;
    localparam integer AW     = 4;
    localparam integer NWRITE = 20;   // > DEPTH，制造回绕
    localparam integer NAFTER = 5;    // 停后继续发节拍，应被忽略

    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg rst_n  = 1'b0;
    reg cap_en = 1'b0;
    reg smp_en = 1'b0;
    reg [7:0]    din     = 8'd0;
    reg [AW-1:0] rd_addr = {AW{1'b0}};
    reg          rd_en   = 1'b0;

    wire [7:0]    rd_data;
    wire [AW-1:0] wr_ptr;
    wire [AW-1:0] stop_ptr;

    cap_mem #(.DEPTH(DEPTH), .AW(AW)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .cap_en   (cap_en),
        .smp_en   (smp_en),
        .din      (din),
        .rd_addr  (rd_addr),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .wr_ptr   (wr_ptr),
        .stop_ptr (stop_ptr)
    );

`ifdef WAVE_MODE
    integer csv_fd;
    initial begin
        csv_fd = $fopen("tb_cap_mem.csv", "w");
        $fwrite(csv_fd, "t_ns,smp_en,cap_en,din,wr,stop,rd_en,rd_addr,rd_data\n");
    end
    always @(posedge clk) begin
        $fwrite(csv_fd, "%0d,%b,%b,%0d,%0d,%0d,%b,%0d,%0d\n",
                $time, smp_en, cap_en, din, wr_ptr, stop_ptr, rd_en, rd_addr, rd_data);
    end
`endif

    integer      n_fail = 0;
    integer      i;
    reg [7:0]    rd_val;
    reg [AW-1:0] base;

    task tick_write(input [7:0] v);
        begin
            @(negedge clk); din = v; smp_en = 1'b1;
            @(posedge clk);
            @(negedge clk); smp_en = 1'b0;
        end
    endtask

    task tick_read(input [AW-1:0] a, output [7:0] d);
        begin
            @(negedge clk); rd_addr = a; rd_en = 1'b1;
            @(posedge clk);
            @(negedge clk); rd_en = 1'b0; d = rd_data;
        end
    endtask

    integer k;
    integer bad;
    reg [7:0] expect_v;

    initial begin
        $display("=========== tb_cap_mem START ===========");
        $display("DEPTH=%0d  NWRITE=%0d  NAFTER=%0d", DEPTH, NWRITE, NAFTER);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- 1. 连续写入 ----
        cap_en = 1'b1;
        for (i = 0; i < NWRITE; i = i + 1) tick_write(i[7:0]);

        $display("after %0d writes : wr_ptr = %0d  (expect %0d)",
                 NWRITE, wr_ptr, NWRITE % DEPTH);
        if (wr_ptr !== (NWRITE % DEPTH)) begin
            $display("[FAIL] wr_ptr wrong");
            n_fail = n_fail + 1;
        end else
            $display("[PASS] wr_ptr wrapped correctly");

        // ---- 2. 停止（对应 trig_fsm 写够 POST_LIMIT 拍后拉低 cap_en）----
        cap_en = 1'b0;
        repeat (3) @(posedge clk);

        base = stop_ptr;
        $display("stop_ptr = %0d  (expect %0d)", stop_ptr, NWRITE % DEPTH);
        if (stop_ptr !== (NWRITE % DEPTH)) begin
            $display("[FAIL] stop_ptr wrong");
            n_fail = n_fail + 1;
        end else
            $display("[PASS] stop_ptr latched at the freeze point");

        // ---- 3. 停后再发节拍，必须被忽略 ----
        for (i = NWRITE; i < NWRITE + NAFTER; i = i + 1) tick_write(i[7:0]);

        if (wr_ptr !== (NWRITE % DEPTH)) begin
            $display("[FAIL] wr_ptr moved after cap_en deasserted (wr_ptr=%0d)", wr_ptr);
            n_fail = n_fail + 1;
        end else
            $display("[PASS] writes ignored after cap_en deasserted");

        // ---- 4. 顺序读回整个缓冲 ----
        bad = 0;
        for (k = 0; k < DEPTH; k = k + 1) begin
            tick_read(base + k[AW-1:0], rd_val);
            expect_v = (NWRITE - DEPTH) + k;
            if (rd_val !== expect_v) begin
                $display("  [MISMATCH] addr %0d -> got %0d, expect %0d",
                         base + k[AW-1:0], rd_val, expect_v);
                bad = bad + 1;
            end
        end
        if (bad == 0)
            $display("[PASS] all %0d samples read back in time order (oldest value = %0d)",
                     DEPTH, NWRITE - DEPTH);
        else begin
            $display("[FAIL] %0d mismatch(es) in read-back", bad);
            n_fail = n_fail + 1;
        end

        $display("-----------------------------------------");
        if (n_fail == 0) $display("RESULT: PASS    (all checks passed)");
        else             $display("RESULT: FAIL    (%0d check(s) failed)", n_fail);
        $display("=========== tb_cap_mem END ===========");
`ifdef WAVE_MODE
        // 导出缓冲终态，供脚本画"环形缓冲映射图"
        begin : dump_mem
            integer j;
            integer mfd;
            integer sfd;
            mfd = $fopen("tb_cap_mem_final.csv", "w");
            $fwrite(mfd, "addr,value\n");
            for (j = 0; j < DEPTH; j = j + 1)
                $fwrite(mfd, "%0d,%0d\n", j, dut.mem[j]);
            $fclose(mfd);

            sfd = $fopen("tb_cap_mem_ptr.csv", "w");
            $fwrite(sfd, "key,value\n");
            $fwrite(sfd, "stop_ptr,%0d\n", stop_ptr);
            $fwrite(sfd, "wr_ptr,%0d\n", wr_ptr);
            $fwrite(sfd, "depth,%0d\n", DEPTH);
            $fwrite(sfd, "nwrite,%0d\n", NWRITE);
            $fclose(sfd);

            $display("dumped buffer contents: tb_cap_mem_final.csv");
        end
        $fclose(csv_fd);
`endif
        $finish;
    end

endmodule
