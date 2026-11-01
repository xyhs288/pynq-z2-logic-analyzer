---
name: vivado-cli-flow
description: 用命令行驱动本机 Vivado 2025.2，完成 FPGA 工程的构建（综合/实现/bitstream）、仿真自检、以及下载到开发板。当需要构建 FPGA 设计、跑仿真验证、或把 bitstream 烧进板子时使用。触发词：Vivado, 综合, 实现, bitstream, 上板, 下载, 仿真, xsim, xvlog, PYNQ-Z2, xc7z020。
---

# Vivado 命令行全流程

## 环境（本机已实测）

```
Vivado  : D:\Xilinx\2025.2\Vivado\bin\vivado.bat
仿真器  : 同目录下的 xvlog.bat / xelab.bat / xsim.bat
板卡    : PYNQ-Z2，器件 xc7z020clg400-1
```

`.bat` 可直接从 Git Bash 调用。**跑 batch 前提醒用户关掉占用同一工程的 Vivado GUI。**

## 三条命令

**构建**（非工程流程，最稳）：
```bash
vivado.bat -mode batch -source build_nonproj.tcl -tclargs <顶层名>
```
流程：`read_verilog` + `read_xdc` → `synth_design` → `opt_design` → `place_design` → `route_design` → `report_*` → `write_bitstream`。

**仿真自检**（testbench 自己打印 PASS/FAIL，不用人工看波形）：
```bash
xvlog.bat <rtl...> tb_xxx.v
xelab.bat tb_xxx -s tb_xxx_sim -debug typical
xsim.bat tb_xxx_sim -runall
```

**看波形**（三样一起出：波形库 + PNG + GUI 查看器）：
```bash
xvlog.bat -d WAVE_MODE <rtl...> tb_xxx.v
xelab.bat tb_xxx -s tb_xxx_wave -debug typical
xsim.bat tb_xxx_wave -tclbatch wave.tcl -wdb tb_xxx.wdb
python plot_wave.py tb_xxx.csv tb_xxx_wave.png
xsim.bat tb_xxx_wave -gui -tclbatch gui.tcl     # 独立窗口，可缩放测量
```
项目里已封装成 `sim/run_wave.bat <tb>`（加 `nogui` 参数则只出文件不开窗口）和 `sim/run_sim.bat <tb>`（真实参数 PASS/FAIL 自检）。

**下载到板子**：
```bash
vivado.bat -mode batch -source program.tcl -tclargs <顶层名>
```
`open_hw_manager` → `connect_hw_server` → `open_hw_target` → 取 `PART` 匹配 `xc7z020*` 的 device（Zynq 上还有一个 `arm_dap_0`，别选错）→ `program_hw_devices`。

## 波形流程的四个关键点

1. **`-debug typical` 必须加在 `xelab` 上，否则信号记录不下来**；**宏 `-d WAVE_MODE` 必须加在 `xvlog` 上**——Verilog 的 `` `ifdef `` 是编译期预处理，xelab 阶段再定义已经来不及。
2. **testbench 用 `` `ifdef WAVE_MODE `` 切换参数**：真实参数跑 PASS/FAIL 自检（快、不占盘），缩小参数跑波形（`DIV` 和 `DEPTH` 都调小，波形窗口缩到十几微秒才看得清）。完整参数下 `log_wave -recursive /*` 会产出 GB 级波形，打不开。
3. **`-tclbatch` 的脚本末尾要 `exit`**，否则 xsim 跑完停在交互模式等输入、挂住不返回。**GUI 模式（`-gui`）的脚本不能有 `exit`**，否则窗口一闪就关。所以分成 `wave.tcl`（含 exit）和 `gui.tcl`（不含）两个文件。
4. **GUI 脚本里除了 `log_wave` 还要 `add_wave -recursive /*`**，否则波形窗格是空的（见坑 12）。`gui.tcl` 里同时把进度写进一个文本文件，因为 GUI 模式的 stdout 抓不到（见坑 13）。

**波形画图**：testbench 在 `` `ifdef WAVE_MODE `` 下用 `$fwrite` 逐时钟写 CSV（含 `$time` 和各信号），Python + matplotlib 画堆叠波形。**这比截图强**——图能直接进报告，且数据可复算。

**批处理隔离**：`run_wave.bat <tb> nogui` 用独立 snapshot（`_cli` 后缀）且不写同名 `.wdb`，因此**可以在用户的波形查看器窗口仍然开着的时候跑**（见坑 14）。

## 三十二个坑（都踩过）

1. **不要用工程模式**。batch 下 `launch_runs` 生成的工程，综合会报 `No Verilog or VHDL sources found in project`（无 GUI 时"自动层次更新"不运行）。修法是 `set_property source_mgmt_mode None [current_project]`，但**即使修好，`wait_on_run` 仍会误报** `Failed runs(s)`（实际综合成功）。⇒ 直接用非工程流程。
2. **exit code 不可信**。`vivado.bat` 恒返回 127；`xelab.bat` 成功也可能返回非零。**判断成败只能看日志内容**，不能用 `if errorlevel`。
3. **RTL 必须有 `timescale`**。否则 elaboration 报 `XSIM 43-4099 ... doesn't have a timescale but at least one module in design has a timescale`。在每个 .v 顶部加 `` `timescale 1ns / 1ps ``。
4. **未约束的顶层端口会阻断 bitstream**。Vivado 报 DRC `UCIO-1`：*"This design will fail to generate a bitstream unless all logical ports have a user specified site LOC constraint defined."*
5. **PYNQ-Z2 的 125MHz 时钟来自以太网 PHY（H16）**，别去复位网口 PHY，否则 CLK125 消失、PL 没有时钟。
6. **testbench 里的时间测量有观测延迟**。在 `always @(posedge clk)` 里读 DUT 输出，读到的是 NBA 提交**前**的值，天然差 1–2 个时钟。严格相等的时间断言必然失败，**容差至少给 1 个采样周期**。
7. **CSV 首行是 `x`**（复位前未初始化），Python 解析时要兜住，否则 `int('x')` 抛 `ValueError`。**但仅替换成 0 还不够，会造出假边沿——见坑 22。**
8. **波形图上看不到单时钟脉冲**。1600 px 宽的图配 2800 个采样点，`smp_en` 那种 1 拍宽的脉冲会糊成实心色块。⇒ **必须配一个局部放大子图**，用 `event ± 几百 ns` 的窗口单独画。
9. **`.bat` 文件必须纯 ASCII**（🔴 严重，2026-10-01 实际翻车）。中文 Windows 的 cmd 用 GBK 解码 `.bat`，UTF-8 的中文注释会在解码时重组出 `"`、`&` 等字节，**把整行命令拆碎**。症状：满屏 `'xxx' 不是内部或外部命令`，`%VAR%` 变量全部失效，`call "%VBIN%\xsim.bat"` 变成找不到文件。⇒ **`.bat` 里注释一律英文，检查方式 `grep -cP '[^\x00-\x7F]' x.bat` 必须为 0。**（Python / Tcl / Verilog 源文件不受此限，只有 `.bat` / `.cmd` 有这个问题。）
10. **`.bat` 里不要用 `start` 启动子进程**（在自动化/管道环境下）。`start` 出来的进程会继承 stdout 管道句柄，导致调用方（CI、Bash 工具）一直等不到 EOF 而超时。⇒ 用 `call` 同步等待，或给脚本加一个 `nogui` 参数跳过 GUI 步骤。
11. **`REM` 行里的 `<` `>` 照样被当重定向处理**。cmd 在解析阶段就处理重定向符，注释也逃不掉，报"系统找不到指定的文件"。⇒ **`REM` 行里不要出现尖括号**——最容易中招的是**用法说明文字**：
    ```
    REM Usage: program.bat <top_name>      <- 错，cmd 会去找名为 top_name 的文件
    REM Usage: program.bat  top_name       <- 对
    ```
    检查方式：`grep -n "[<>]" x.bat`，**只剩 `pause >nul` 这类有意的重定向才是正常的**。
12. **波形窗口默认是空的**。`log_wave` 只把信号记进内存/库，**不会**显示。GUI 模式下必须显式 `add_wave -recursive /*`，否则查看器打开的是空白波形窗格。
13. **GUI 模式的 stdout 进不了 `-log` 文件**。`xsim <snap> -gui -tclbatch x.tcl > log 2>&1` 里看不见 tcl 的 `puts`（日志只到 `start_gui` 就断了）。⇒ 诊断信息要 `open` 一个文件写进去，再用工具读那个文件。
14. **`xsim` 的 snapshot 和 `.wdb` 是独占资源**。上一个查看器窗口还开着时再跑同一个 snapshot，报 `ERROR: [Simtcl 6-50] Simulation engine failed to start: The Simulation shut down unexpectedly during initialization.`——**错误信息毫无指向性**。⇒ 批处理/自动测试用**独立 snapshot 名**（如 `_cli` 后缀）并避开同名 `.wdb`。
15. **RTL / testbench 里 `$display` 的字符串也必须是 ASCII**，不只是 `.bat`。xsim 输出到中文 Windows 的 GBK 控制台，UTF-8 中文会变成 `鏈熸湜` 这类乱码。Python 脚本的 `print` 同理。**中文只留在注释里**（注释不进控制台，不受影响）。
16. 🔴 **只被读出部分位的存储器会被综合裁掉**（2026-10-02 实际踩到）。`cap_mem` 的 `mem` 是 8 位宽（8 通道），但顶层只用 `rd_data[0]` 驱动一个 LED，**综合把其余 7 位当死代码删除**，BRAM 从 `64K x 8` 变成 `64K x 1`，RAMB36 从 16 个变成 2 个。**症状：资源报告里 BRAM 少得离谱，但不报任何错**，上板后你只看到 1 个通道有数据。
    **检查方法**：综合日志里搜 `Block RAM: Final Mapping Report`，核对 `PORT A (Depth x Width)` 那一列的**位宽**。
    **修法**：把存储器的全部位引到顶层端口（哪怕只是加一个 `output [7:0] dbg_data` 再悬空），综合器就不能删。
    **同源的另一半（2026-10-03 遇到）**：即使全位都引到顶层，**写数据里恒定的位照样被常量传播删掉**。stage4 里 `din = {6'b0, sda, scl}`，日志报 `Optimized 6 bits of RAM ... Old ram width 8 bits, new ram width 2 bits`，RAMB 从预期的 2 个 RAMB36 变成 1 个 RAMB18。**这一次是正确优化，不是 bug**——只接了两路信号，就没有必要存 8 位。
    **判断标准**：看**写数据的来源**。写数据里有常量位 → 被缩是正常的；写数据是 8 路真实信号但只读出 1 位 → 是坑 16 前半段，要修。
17. **Verilog TB 里不能用 SystemVerilog 语法**。`disable fork` 报 `Verilog 2000 keyword 'disable' used in incorrect context`；命名块内的 `integer x = 0;` 报 `non-module variable cannot be initialized at declaration`。
    **替代**：超时用 `for (w = 0; w < N && sig !== 1'b1; w = w + 1) @(posedge clk);`（注意用 `!==` 而不是 `!`——复位前信号是 `x`，`!x` 为假会导致循环一次都不走）。
18. 🔴 **AXI4-Lite TB 主机模型：`ready` 必须在 `valid` 拉高之后再给**（2026-10-02 卡死过一次）。如果 TB 在等 `bvalid` 之前就把 `bready` 置 1，从机的"置位 valid"和"响应 ready"会在同一拍撞上，`bvalid` **永远出不来**，TB 的 `while (!s_bvalid) @(negedge clk);` 无限循环，仿真挂死（表现为工具 SIGTERM 超时，无任何输出）。
    **正确顺序**：`等 awready → 撤 awvalid/wvalid → 等 bvalid → 拉 bready → 撤 bready`。R 通道同理。
    **防御**：TB 里永远加一个独立的 `initial begin #N; $display("TIMEOUT"); $finish; end`，卡住时能退出而不是挂到超时。
19. **TB 的握手驱动/采样统一用 `negedge clk`**。`posedge` 时刻 DUT 的 NBA 还没提交，此时读到的还是旧值，检查 `ready/valid` 会误判。用 negedge 观察和驱动，值都是稳定的。
20. 🔴 **非工程流程（batch）下用 `create_debug_core` 插 ILA 会失败**（2026-10-02 实测，Vivado 2025.2，未解决）。ILA 本身综合成功，但配套的 `dbg_hub` 生成失败：
    ```
    ERROR: [Vivado 12-13638] Failed runs(s) : 'dbg_hub_synth_1'
    ERROR: [Chipscope 16-330] Synthesis of Debug Cores has failed
    ```
    **症状极具迷惑性**：同一次日志里同时出现 `The checkpoint '.../dbg_hub_synth_1/dbg_hub.dcp' has been generated`、`0 Errors encountered`、`dbg_hub_synth_1 finished`，**紧接着就报 Failed**。而 `dbg_hub_synth_1` 的 run 目录从来没被创建，错误日志指向的 `dc_drv.0/vivado.log` 也不存在 —— **说明 debug core 的驱动进程根本没启动**。
    **已排除**：磁盘空间（D 盘 100G 空闲）、路径长度（把 cwd 换到 `D:\` 根目录仍失败；实测最长路径 117 字符 < Vivado 的 146 阈值）、IP cache（跑两次无效）。
    **已知正确的操作要点**（即使最终没跑通，这些是对的）：
    - ILA 的时钟**不能连输入引脚对应的 net**（报 `Cannot debug net 'sys_clk'; it is not accessible from the fabric routing`），要连 **BUFG 之后的 net**，本设计里叫 `sys_clk_IBUF_BUFG`。
    - `create_debug_core` 的 debug_core 对象**没有 `C_NUM_OF_PROBES` 属性**；默认只建 `probe0`，其余要用 **`create_debug_port u_ila_0 probe`** 逐个添加。
    - `get_nets stop_ptr[*]` 不加 `-hier` 才只匹配顶层；加了会同时匹配 `u_cap_mem/stop_ptr[*]`，数量翻倍。
    **✅ 2026-10-13 根因已查明 —— 见坑 23。不是路径长度，也不是 IP cache，就是 run 管理器本身
    把成功的 run 记成 ERROR。** 上面第 ① ② 条备选路线不用试了。
21. 🔴 **画图脚本在 `valid` 上升沿处要取 `data` 列，不是取 `valid` 列**（2026-10-02 实际踩到）。写 `rises("valid")` 返回的是 `(时刻, valid值)`，画出来所有字节都是 `0x01`。
    **正确写法**：`if sig["valid"][i] and not sig["valid"][i-1]: out.append((t[i], sig["data"][i]))`。
    **自查**：图上一串相同的 `0x01` / `0x00`，基本就是取错列了。
22. **`x` 的处理不只是防 `ValueError`，还要防"假边沿"**（坑 7 的加强版）。把首行的 `x` 简单替换成 `0` 之后，如果下一拍是真值 `1`，就会凭空造出一个**上升沿**——在 I2C 图上表现为 `t=0` 处多出一个假的 `STOP`。
    **修法**：解析时**另外记一个 `ok[k]` 掩码**（该点原本是否为确定值），边沿判定要求**前后两点都已知**；同时用第一个已知值**回填**前面的采样点，避免画出从 0 跳起的斜坡。
23. 🔴🔴 **工程 run 管理器把成功的 run 记成 ERROR**（2026-10-13 查明，Vivado 2025.2 + 本机 Windows）。
    **这是坑 20（dbg_hub）的真正根因**，凡是"日志说成功、状态说失败"的现象都归这条。
    **症状**：
    ```
    runme.log 里:  synth_design completed successfully / 0 Errors encountered
                   标记文件 __synthesis_is_complete__ 存在、.dcp 已生成
    get_property STATUS →  "synth_design ERROR"
    后续 run 拒绝启动: ERROR: [Common 17-70] Failed to launch run 'impl_1'
                       due to failures in the following run(s):
    ```
    **根因有两条，都已实测确认**：
    a) **run 管理器用子进程退出码判定成败，而 `vivado.bat` 的退出码恒为 1。**
       实测：`cd /d/Xilinx/2025.2/Vivado/bin && cmd //c "vivado.bat -version"` → `exit=1`
       —— 哪怕只是打印版本号也返回 1。于是所有 run 一律被记 ERROR。
    b) **`wait_on_run` 会提前返回**，脚本一退出就把仍在跑的子进程杀掉。
       症状：那个 run 的标记停在 `__synthesis_is_running__`（而不是 `__synthesis_is_complete__`），
       DCP 缺失，报 `ERROR: [Runs 36-527] DCP does not exist: ...`。
    **绕开方案（已在 `la_pynq/build/build_bd_test.tcl` 固化并通过实测）**：
    ```tcl
    foreach r [get_runs -filter {NAME =~ "*_synth_1*"}] { catch { reset_run $r } }
    launch_runs $ipruns -jobs 4
    # 不信 get_property STATUS，按 DCP 文件是否出现轮询
    while {1} {
        set ok 1
        foreach f $wants { if {![file exists $f]} { set ok 0 } }
        if {$ok} break
        if {[clock seconds]-$t0 > 480} break
        after 5000
    }
    # IP 落地后，用直接命令做综合/实现，完全不经过 run
    synth_design -top $top -part $part
    opt_design ; place_design ; route_design
    write_bitstream -force -file $out/x.bit
    ```
    **关键认识**：**block design 必须用工程模式创建**（`.hwh` 靠 `generate_target all` 产出），
    但综合/实现可以用直接命令 —— 这样就绕开了 run 管理器。纯 RTL 用非工程流程本来就不受影响。
24. **block design 里的 PS7 不需要板卡预设文件**（2026-10-13 实测）。
    **PS 的 DDR / MIO 配置对 PYNQ 无影响 —— PYNQ 镜像在启动时配置 PS，bitstream 只灌 PL。**
    所以 BD 里 PS7 只要 `CONFIG.PCW_USE_M_AXI_GP0 {1}` 加一个时钟即可，
    **不必往 Vivado 安装目录里塞 TUL 的 board files**（那份是 2018 年的 schema，且属于改动安装目录）。
25. **BD 脚本里的几个小坑**（2026-10-13）：
    - `set_property CONFIG.PORT_BUNDLE ...` —— **没有这个参数**，报 `CRITICAL WARNING [BD 41-1411]`。
      重命名 BD 端口要用 `set_property name led [get_bd_ports gpio_io_o_0]`。
    - 直接用 `FCLK_RESET0_N` 驱 AXI 的 `aresetn`，会报 4 条
      `CRITICAL WARNING [BD 41-1348] Reset pin ... connected to asynchronous reset source`
      （不阻塞，但正式设计里应加 `proc_sys_reset`）。
    - Tcl 里 `foreach r $ipruns { puts "[$r]" }` 会把 run 名当命令执行 → `invalid command name`。
      要用 `[get_property NAME $r]`。
26. **BD 工程必须用自动源管理**（2026-10-13 踩到）。
    `set_property source_mgmt_mode None [current_project]` 会让
    `create_bd_cell -type module -reference <mod>` 失败：
    ```
    ERROR: [filemgmt 56-587] Failed to resolve reference. Nothing was found in the project
                             to match the name clkmon
    ERROR: [BD 41-1690] Unable to resolve module-source based on inputs: clkmon
    ```
    ⇒ 改成 `set_property source_mgmt_mode All [current_project]`。
    那个 `None` 设置只适用于**纯 RTL** 的工程流程（避开坑 1 里的层次更新问题），
    BD 工程千万不要用。
27. **`generate_target all` 不会创建 OOC IP run**（2026-10-13 踩到）。
    紧跟其后的 `get_runs -filter {NAME =~ "*_synth_1*"}` 会返回**空**，
    `launch_runs` 报 `ERROR: [Common 17-162] Invalid option value specified for '-runs'`。
    ⇒ 要先用 `launch_runs impl_1 -to_step write_bitstream` 触发一次，Vivado 才会把
    缺失的 OOC run 建出来。
    **而且判断"跑完没有"不能看 run 状态**：顶层 `synth_1`/`impl_1` 会因依赖被误判而
    永远停在 `Not started`（那条路会死等超时）。**正确做法是看产物**：
    ```tcl
    set ipdir ".../<proj>.gen/sources_1/bd/sys/ip"
    set last -1; set stable 0
    while {1} {
        set n [llength [glob -nocomplain ${ipdir}/*/*.dcp]]
        if {$n == $last} { incr stable } else { set stable 0 }
        set last $n
        if {$stable >= 4} break          ;# 连续 16 秒没有新 dcp 出现
        after 4000
    }
    ```
28. ✅ **module reference 是好用的，不用把 RTL 打包成 IP**（2026-10-13 验证通过）。
    把模块的 AXI 端口命名成标准的 `s_axi_awaddr / s_axi_awvalid / ... / s_axi_rready`，
    **地址位宽用 32 位**（内部自己截低位译码），Vivado 就能自动推断出 `S_AXI` 接口，
    实例名在 `.hwh` 里正常出现（如 `clkmon_0`）。
    在 BD 里加一行即可：
    ```tcl
    create_bd_cell -type module -reference clkmon clkmon_0
    ```
    前提是先把 .v 用 `add_files` 加进工程（见坑 26）。
    **这条让整机集成（PS7 + AXI Interconnect + 自写 RTL）省掉了 IP 打包这一大块工作。**

29. 🔴🔴 **module reference 的 AXI 接口必须关联时钟，否则会把整颗芯片挂死**（2026-10-13 实际挂死过板子，要断电重启）。
    **接口推断完全依赖端口命名**：
    - 地址/数据：`s_axi_awaddr` / `s_axi_awvalid` / ... / `s_axi_rready`
    - **时钟必须叫 `s_axi_aclk`**
    - 复位叫 `s_axi_aresetn`
    把时钟起名 `sys_clk` 之类，接口照样推得出来，但**不会关联到时钟**：
    ```
    WARNING: [BD 41-2265] Clock pin for protocol instance pin s_axi could not be determined.
    WARNING: [IP_Flow 19-3158] Bus Interface 's_axi': FREQ_HZ bus parameter missing from
                             AXI interface when interface is not associated to a clock.
    ```
    后果：Vivado 为 AXI3→AXI4-Lite 插入的协议转换器（`*_imp_auto_pc_*`）时钟接不上，
    **PS 一发起 AXI 事务就永久等不到响应 → CPU 卡死 → 网口也不通 → 只能断电**。
    **⚠️ 只报 WARNING，能一路生成 bitstream** —— 所以**构建日志必须逐条检查警告**，
    不能只看有没有 ERROR。

    **在 BD 脚本里加一道安全检查**（本仓库 `build_bd_la.tcl` 已加）：
    ```tcl
    set assoc ""
    catch { set assoc [get_property CONFIG.ASSOCIATED_BUSIF \
                         [get_bd_pins la_top_axi_wrap_0/s_axi_aclk]] }
    puts "  ASSOCIATED_BUSIF = '$assoc'"
    if {[string first "S_AXI" [string toupper $assoc]] < 0} {
        puts "  !!! 时钟未关联到 S_AXI —— 中止（跑下去会挂死 PS）"
        exit 1
    }
    ```

    **附：第一次上板一个未知 AXI 从机是有风险的**（可能挂死整机、要断电）。正确做法：
    - 用 `python3 -u` 跑（**不加 `-u` 时 stdout 被管道缓冲，进程被杀后什么输出都不留**，
      本次就因为这点白丢一次机会）
    - 每一步套 `timeout N`，分步执行，才能定位卡在哪一次访问

30. 🔴🔴 **PS 的 `M_AXI_GP0_ACLK` 绝不能接"PL 配置后才存在"的外部时钟**（2026-10-13 第二次挂死板子）。
    本项目一度把 `ps7/M_AXI_GP0_ACLK` 接到板载以太网 PHY 送来的 H16（CLK125），
    理由是"AXI 与采样同源、单时钟域、绕开 PS 时钟配置"。**结果是 PYNQ 一执行
    `Overlay()` 整机就卡死** —— 连加载都没返回，SSH 断开，只能断电。
    **根因**：`M_AXI_GP0_ACLK` 是 PS 的 GP 口在 PL 侧的接口时钟，Zynq 要求它
    **在 PS 启动早期就有效**。H16 来自以太网 PHY，**PL 未配置时这条通路根本不存在**，
    于是 PS 的 AXI 互连从启动起就处于异常状态。
    **正确做法（Xilinx 标准）**：接 `ps7/FCLK_CLK0`（PS PLL 输出，一开始就有效）。
    本仓库现改为 AXI 与采样共用 FCLK_CLK0（100MHz），全设计单时钟域，
    采样率 = 100MHz / DIV（软件侧按 100MHz 换算，功能不受影响）。
    **判别方法（记住这条就够了）**：外部时钟只能驱动**你自己的逻辑**，
    **绝不能驱动 PS 的 AXI 接口时钟**。凡是"PL 配置后才出现"的时钟，
    都不能接到 `*_ACLK` 上。
    **对照实验的价值**：同一天早些时候 `la_clkmon` 能跑通，正是因为它用 `FCLK_CLK0`
    驱动 AXI —— **两个设计的 PS7 配置逐行相同，唯一差异就是时钟源**。
    出问题时先找"和上一个能跑的版本有哪些不同"，比凭空推理快得多。

    **配套：复位要用 `proc_sys_reset`，不要用 `xlconstant` 恒 1**。
    前者等 FCLK 锁定后才释放，上电时序才正确；恒 1 意味着互连在上电瞬间就"已复位"，
    时钟还没稳就开始工作。

### 🔴 H16（PHY 送来的 125MHz）会不会停振 —— 实测：不会
手册 5 节原文：*"When the PHYRSTB signal is driven low, the Ethernet PHY (U5) is held
in reset **disabling the CLK125**."* PHYRSTB 接 MIO9，由 PS 控制 —— **机制上确实存在**。

**2026-10-13 实测结论（PYNQ-Z2 + PYNQ v3.1.1）**：运行期**未测到任何停振**。
- 实测频率 **124.991 MHz**（设计值 125）
- 连续监控 60 秒（约 210 万次采样）三轮，停振检测器 `STALL_MAX` 恒为 **7**，
  恰好是 128ns 同步粒度下的**地板值**（AXI≈50MHz 时理论 6.4）
- ⇒ **可以把 H16 的 125MHz 直接用作 PL 主时钟**

**测量方法值得复用**：AXI **必须挂在独立稳定的时钟上**（PS 的 FCLK），
被测时钟只驱动一个自由计数器；把计数器高位 2 拍同步到 AXI 域，
统计"同步值连续多久没变化的最大值"。若 AXI 也挂被测时钟，时钟一停连读数都拿不到。

**两个易错点**：
- 计数器若做了 `(x>>4)<<4` 这类对齐，**其 LSB 仍然是原来的时钟周期**（8ns），不是 16 倍。
- PS 侧"最慢一次读"的耗时会受 Linux 调度影响（动辄几 ms），**那不是时钟停振**；
  权威指标只有硬件统计出来的 STALL_MAX。

31. 🔴🔴🔴 **AXI 从机：`valid` 绝不能在同一拍「置位又清零」**（2026-10-15 真机两次挂死整机后定位）。
    错误写法（本项目 `axi_regs.v` 原来的读通道）：
    ```verilog
    else begin
        s_arready <= 1'b0;
        s_rvalid  <= 1'b1;          // 先置位
        if (s_rready) begin
            s_rvalid <= 1'b0;       // 同一拍又被清零（非阻塞赋值：后者覆盖前者）
            r_state  <= 1'b0;
        end
    end
    ```
    **后果**：主机的 `rready` 预先就位时（AXI 规范允许，ARM/PS 主机常见做法），
    `rvalid` 永远输出不出去 → 主机死等 → **整颗 Zynq 卡死、SSH 断连、只能断电**。
    写通道的 `bvalid`（`s_bvalid <= 1'b1; if (s_bready) s_bvalid <= 1'b0;`）完全同病。
    **正确写法**：先拉高 valid，**下一拍**才检查 ready：
    ```verilog
    if (!s_rvalid)      s_rvalid <= 1'b1;      // 先把数据推出去
    else if (s_rready) begin                   // 下一拍才可能完成握手
        s_rvalid <= 1'b0; r_state <= 1'b0;
    end
    ```
    **写通道还有第二个坑**：`if (s_awvalid && s_wvalid)` 要求地址和数据**同时**到达。
    AXI 允许两者独立握手，主机先发 AW 等 awready 时会死锁。
    ⇒ **AW / W 各自独立握手**（各自读写一个 done 标志），两者都到齐再更新寄存器。

    **🔴 为什么仿真发现不了（最该记住的一条）**：
    testbench 的主机模型通常是"**先等 valid，再拉 ready**"的**友好模式**，
    永远不会触发这个场景 —— 本项目 39 项断言全过，真机一读就挂。
    **必须把 TB 主机改成 `ready` 预先就位**（真实主机行为）才能复现。
    改完 TB 后：旧 RTL 立刻报 `[FAIL] TIMEOUT - AXI handshake stuck`，
    新 RTL 39 项全过 —— 这就是"修复被验证"的证据。
    **通用规则：仿真主机模型要"恶劣"，不要"友好"。**
    至少覆盖：ready 提前就位、valid 提前就位、AW/W 分离、背靠背事务、
    非对齐/窄传输。

    **📌 定位手法（可复用）**：做成败二分要用**同一套加载/读法**换设计——
    JTAG 下载 `test_axi.bit`（PS7+AXI GPIO，已知能跑）+ 手工 mmap 读 → 成功；
    JTAG 下载自己的设计 + 同样读法 → 挂死。
    **唯一变量是设计本身**，一步就把范围锁死在自己的 IP 上，
    比反复猜"是不是 PYNQ 的问题"高效得多。

32. 🔴 **新增 RTL 模块后，必须同步两处手写的源文件列表**（2026-10-15 踩，白等 10 分钟）。
    `la_pynq/sim/run_sim.bat` 里每个 TB 的 `RTLFILES`，和
    `la_pynq/build/build_bd_la.tcl` 里的 `$rtl` 列表，都是**手写枚举**，不会自动发现新文件。
    漏加后果分两档：
    - 仿真：`tb_*` 直接 elaborate 失败（`Module <xxx> not found`），还好，立刻能看到；
    - **BD 构建：最阴**。IP 的 OOC 综合找不到模块而失败，但脚本的等待循环只看
      `__synthesis_is_complete__` 标记，**等满 600 秒才超时**，日志里只留一句 `timeout`。
      症状：`!!! timeout` + `IP dcp 数量 = 3`（比应有的少一个）+
      `ERROR: [Runs 36-527] DCP does not exist: .../sys_xxx_0_0.dcp`。
    ⇒ 已把超时分支改成**打印未完成 run 的 `runme.log` 尾部并 `exit 1`**，下次一眼看到根因。
    **记住：加一个 .v，就要检查这两处列表 + 该模块的 TB。**

## 协议解码器的实现要点（UART / SPI / I2C，均已仿真验证）

**为什么这几个模块的验证是可信的**（区别于 AXI 那种"自己模拟自己"）：协议帧格式是**公开标准**，不是自设假设。UART（1 起始 + 8 数据 LSB 先 + 1 停止）、SPI（CPOL/CPHA 四种模式）、I2C（START/STOP + 9 位一组）都能对着标准逐位核对。

1. **UART**：IDLE 等起始位下降沿 → START 等**半个位周期**再确认还是低（滤毛刺）→ DATA 每个位周期采一位 → STOP 检查停止位。`baud_div` = 一个位周期含多少 clk。
2. **SPI**：靠 **CS 拉低**界定一次传输（SPI 没有帧间隔）。采样边沿由 CPOL/CPHA 决定：
   `sample = CPOL==0 ? (CPHA==0 ? 上升沿 : 下降沿) : (CPHA==0 ? 下降沿 : 上升沿)`。
   CS 在字节中途抬起 → `frame_err`（半个字节）。
3. **I2C**：START/STOP **不是电平，是"SCL 为高时 SDA 的跳变"**——`start = scl & sda_d & ~sda`，`stop = scl & ~sda_d & sda`。每 9 个 SCL 上升沿一组（8 数据 + 1 应答）。
   🔴 **应答位极性别搞反**：接收方**拉低 SDA** 表示应答，所以应是 `ack <= sda`（0 = ACK、1 = NACK）。写成 `ack <= ~sda` 会让所有 ACK 都读成 NACK。
4. **画图时帧起点要靠协议状态机，不能靠信号边沿**。用 `tx` 的下降沿找 UART 帧起点会全线错位——数据位里也有下降沿（`0x55` 就有 4 个）。改用**解码器内部状态 `IDLE->START` 的跳变**才准。
5. **配套的信号源（`uart_tx` / `spi_src` / `i2c_src`）值得写**：不接任何外部设备就能在板子上自测，而且"源 → 解码器"环回 TB 验证的正是将来上板跑的那条链路。

### 协议内容触发（`proto_trig` + `trig_fsm`）

**做法**：解码器输出 `valid` + `data` → 一个比较器（`proto_trig`）比对目标字节 → 输出单拍脉冲 → 送给 `trig_fsm` 的 `ext_trig`，由 `trig_src` 选择用内部边沿还是外部脉冲。

**为什么必须这样**：数据是**触发之后**才有的，所以解码必须在**触发通路上**。放 PS 里就是鸡生蛋——PS 要拿到数据才能解码，数据要触发之后才有，永远转不起来。

**一个容易写错的断言**：`proto_trig` 是纯比较器，**离开 ARMED 之后它照样输出脉冲**（总线上还会再出现同一个字节）。这些脉冲被 `trig_fsm` 忽略（不在 S_ARMED），功能无害。但 **TB 里数"触发了几次"时必须只数布防期间的**（`trig_pulse && armed`），否则会误判成"触发了多次"。

### 演示参数 vs 测量参数（板级演示必看）

**上板演示时，总线和采样率必须一起放慢，否则人眼什么都看不到。** 真实参数下 I2C 一条 3 字节事务只要 23 µs，`ARMED` 到 `TRIG` 的转换瞬间就过去了，效果是"上电后 led[0] 根本没亮过"。

**做法**：把 `BUS_HALF`（总线半周期）和 `SMP_DIV`（采样分频）同比例放大，保持"每 1 个总线位采 ~10 个点"的关系不变。stage4 的演示配置：
- `BUS_HALF = 3_000_000` → SCL 约 21 Hz，一个字节 432 ms
- `SMP_DIV = 600_000` → 采样率 208 Hz，每总线位 10 个点
- 结果：ARMED 持续约 0.94 s 才触发，FULL 再等 1.84 s —— 全部肉眼可见

⚠️ **真实测量参数和演示参数要在代码里明确分开标注**，报告里也要写清用的是哪套，别让评委以为你的采样率只有 208 Hz。

🔴 **配套的坑：分频计数器的位宽要按最大参数算。** 原 `smp_clk_div` 的 `div` 端口和 `cnt` 都是 16 位（最大 65535），一改成 `SMP_DIV = 600000` 就溢出，**不报错，只是行为完全错**（分频比变成 600000 mod 65536）。`i2c_src` / `spi_src` 的相位计数器同理。**凡是"可外部配置的计数阈值 + 对应的计数器"，一律用 32 位**，代价极小。

## 🔴 多驱动寄存器：仿真抓不到，只有综合会报（2026-10-03 踩了两次）

**症状**：同一个 `reg` 在两个 `always` 块里都被赋值。**Verilog 仿真器通常一声不吭**（按调度顺序取最后一个值），testbench 全部 PASS；但综合报 CRITICAL WARNING：

```
CRITICAL WARNING: [Synth 8-6859] multi-driven net on pin drop_cnt[0]
  1st driver: xxx.v:213
  2nd driver: xxx.v:257
```

真实硬件上是竞态。**之所以仿真没暴露**：测试激励里两个事件相隔上百个时钟，两个块的赋值永远不在同一拍，问题被完全掩盖。

**典型案例**：设计里有一个"测量块"负责 `pending <= pending + 1`（新事件入队），一个"状态机块"负责 `pending <= pending - 1`（事件出队）。看起来自然，实际是两个驱动源。

**修法（模式）**：
- **测量侧只产生"单拍事件脉冲"**（`w_evt`、`w_evt_bin`），不碰任何队列/状态寄存器。
- **队列标志、丢弃计数、桶号锁存全部由 FSM 块独占。**
- 需要在两个 FSM 里各自累加同一个输出时，**拆成两个寄存器，最后 `assign out = a + b;`**（把输出从 `reg` 改成 `wire`）。

**强制检查手段**（已固化成脚本，每个新模块都要跑）：

```bash
python sim/check_multidriver.py rtl/*.v      # 返回码 0 = 干净
grep -c "8-6859" build/synth.log             # 综合后必须为 0
```

`check_multidriver.py` 按 `always` 块切分、收集每个块左侧被赋值的寄存器名，出现在两个及以上块里的就是多驱动。**这条检查比跑仿真有用**——仿真对这类 bug 是盲的。

## 时序参数统计的实现要点（`timing_stats.v`）

**要解决的问题**：不问"信号什么时候是高"，而回答"高电平有多宽、分布如何"。

1. **两块 256×32 直方图用分布式 RAM（LUTRAM），不用 BRAM。** 理由是**有意的资源分配**：把有限的 BRAM 全留给采集缓冲。实测 0 BRAM、0 DSP、约 2.3K LUT。这个取舍本身就是"资源优化"的论据。
   - 用 `(* ram_style = "distributed" *)` 明确指定，别让工具自己猜。
   - 直方图需要 **1 写口 + 2 读口**（更新引擎读-改-写、扫描读），BRAM 的端口数不够，LUTRAM 天然支持。

2. **分位数扫描不做除法**：判定式用 `cum*100 >= n*PCT`，等价于 `cum/n >= PCT/100`。两边同乘 100，全程整数。
   - 宽度和周期的**样本数不一样**（周期少了第一个上升沿那次），所以两套阈值必须分开算，不能共用一个总数。
   - 实测扫 256 个桶用 **514 个时钟**（2 拍/桶）。

3. **清空要单独做**。`clr` 只复位计数器是不够的——直方图内容还在。需要一个走 256 拍的清空引擎，并输出 `clr_busy`，否则上位机会读到清了一半的数据。

4. **测试激励要选"期望值能手算"的图案**。本设计用 64 个脉冲、宽度按 40:16:6:2 分布在 4/8/16/64 clk 上、间隔固定 100 clk，于是每一项都有精确期望值。
   ⚠️ **周期的边界最容易数错**：第 i 个脉冲的周期 = 第 i-1 个脉冲的宽度 + gap。所以宽度序列是 40/16/6/2 时，周期序列是 **40/16/6/1**（最后一个宽度只贡献一个周期）。我第一次就是这么数错了，误判成 RTL bug。

5. **饱和与丢弃都要计数**。超出量程压进最后一桶并累加 `sat_cnt`；事件来得太快来不及处理则累加 `drop_cnt`。**有这两个计数器，测量结果才可信**——否则数据静默丢失，你还以为统计是对的。

## 🔴 PS 侧读不到的"单拍脉冲"（2026-10-03 集成时踩到）

**问题**：把解码器的 `valid`（单拍脉冲，125 MHz 下 8 ns 宽）直接接到 AXI 状态寄存器位。
PS 走 AXI 读一次要几十个时钟，**永远读到 0**，而且不报错。现象是"总线上明明有数据，
寄存器却一直说没解码出东西"。

**修法**：模块内的实时脉冲 → **在顶层（或寄存器文件里）做成粘滞标志**，
一旦置位就保持为 1，由软复位清除。

```verilog
reg dec_seen;
always @(posedge clk)
    if (!rst_n)          dec_seen <= 1'b0;
    else if (dec_valid)  dec_seen <= 1'b1;    // 只置位，不清零
```

**通用规则**：**任何宽度小于"一次 AXI 事务周期"的信号，都不能直接进状态寄存器。**
要么粘滞、要么在 PL 里累加成计数（如 `sat_cnt` / `drop_cnt`）。

**⚠️ 2026-10-15 又踩第 2 次**：`timing_stats.v` 的 `pct_valid` 犯了同样的错 ——
`S_DONE` 里置 1，下一拍回到 `S_IDLE` 又被清 0，**只有 1 个时钟（16 ns）宽**。
PS 轮询永远读不到，表现为"分位数扫描好像根本没跑"（超时）。
仿真没发现，因为 TB 是 `while (!pct_valid)` **逐拍等待**的，1 拍宽也等得到。
修法与上面相同：只在「启动新扫描」时清零，平时保持。

⇒ **规则升级：写完之后要逐个检查"单拍脉冲有没有出口到 AXI 寄存器"，不能只修发现的那一处。**
这次是第 2 处了。同类问题的共同点：**逐拍能看见的东西，AXI 批量读看不见。**

**同时要区分两类别名近的状态位，写进接口文档**：
- **实时状态**（armed / trigged / full）：读到的就是当前值，其中 `trigged` 只在中间一段时间为 1，
  **轮询 `full` 比轮询 `trigged` 可靠**；
- **粘滞标志**（解码出过字节 / 出现过帧错误）：置位后保持。

## 集成顶层的组织方式（`la_top.v`）

**做法**：把 `axi_regs` 作为唯一的配置/状态汇聚点，其余模块只与它和彼此的数据通路相连；
顶层不做任何判断逻辑，只做例化与连线。

**经验**：
- **配置类寄存器默认值要能安全工作**（如 `DIV=1250`、`PRE_TRIG=256`），
  否则 PS 还没配置之前 PL 就跑在未知状态。
- **脉冲型控制位（软复位、启动扫描）在寄存器文件里转成单拍脉冲输出**，
  电平型控制位（统计使能、清空）保持电平——这两类要分清并写进接口文档。
- 软复位脉冲要**拉长成若干拍**再用作 datapath 复位，单拍脉冲做异步复位会漏掉模块。
- 集成完**先跑 out_of_context 综合**拿资源和 CRITICAL WARNING 数量，
  比直接上板快得多：`synth_design -top xx -part xx -mode out_of_context`，
  不需要引脚约束，也能出 `report_utilization`。



## 仿真加速技巧

跑长设计前先算周期数：`仿真周期数 = 采样拍数 × 分频系数`。26 位计数器的分频源会让仿真时间膨胀到上亿周期，**testbench 里应自行制造确定时刻的激励（如 `#2000 din=8'h01`），不要用设计内部的长分频信号**。

## 模块自检 TB 的写法（已验证好用）

1. **参数化模块要用小参数实例化**。验证环形缓冲 / 指针回绕时，用 `DEPTH=16` 配 **超过 DEPTH 的写入次数**（如写 20 个点）——大参数下回绕几十次，出错你根本数不清；小参数下一次回绕就暴露语义 bug。跑通后再用真实参数综合。
2. **用 task 封装单拍操作**（`tick_write` / `tick_read`），在 `negedge` 改激励、`posedge` 让 DUT 采样，避免竞争。循环里调用，TB 主体只剩检查逻辑。
3. **同步读要等一拍**：`negedge 设地址 → posedge 采样 → negedge 取值`。少等一拍会读到上一拍的残值，表现为"随机"错。
4. **除逐时钟 CSV 外，把"终态快照"也导出**（如 `$fwrite` 整个 BRAM 内容 + 指针值到单独的小 CSV）。**画出来的柱状图比波形更能说明问题**——环形缓冲的关键就是"最老数据现在在哪个物理地址"，波形看不出来，快照图一眼就懂。

## 板上调试：直接从本机 SSH 驱动（2026-10-13 建立，效率提升很大）

板子 `192.168.2.99`，SSH 22 口开放，用户/密码 `xilinx`/`xilinx`。
本机没有 sshpass，但 OpenSSH 10.3 支持 `SSH_ASKPASS_REQUIRE=force`，可免交互传密码：

```sh
cat > /tmp/askpass.sh <<'EOF'
#!/bin/sh
echo "xilinx"
EOF
chmod +x /tmp/askpass.sh

# 远程执行
SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    xilinx@192.168.2.99 "命令"

# 传文件：注意 -O（新版 OpenSSH 默认走 SFTP，与板子 sshd 配合要用传统协议）
scp -O ... 文件 xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/
```

**Git Bash 里没有 `setsid`**，但 `SSH_ASKPASS_REQUIRE=force` 单独就能生效，不需要它。

### 🔴 跑 PYNQ 脚本必须设 XILINX_XRT，且值必须是 /usr

PYNQ 3.1 的 `pynq/pl_server/__init__.py` 是**条件导入**：

```python
if os.environ.get("XILINX_XRT", False):
    from .embedded_device import EmbeddedDevice
    from .xclbin_parser import XclBin
    from .xrt_device import XrtDevice
```

- 不设 → `DeviceMeta._subclasses` **为空** → `Overlay()` 抛
  `RuntimeError: No Devices Found`，并先给一条误导性的
  `UserWarning: No devices found, is the XRT environment sourced?`
- **值写成 `1` → 报 `No such library '1/lib/libxrt_core.so.2'`**。
  必须 **`XILINX_XRT=/usr`**（来源 `/etc/profile.d/xrt_setup.sh`）
- Jupyter 环境下该变量由 `/etc/profile.d/xrt_setup.sh` 自动设置，所以在 Jupyter 里跑没问题——
  **只在 SSH/脚本方式下才会撞到这个坑**

```sh
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 xxx.py
```

### 其他板上事实
- **PYNQ 的 Python 在 venv 里**：`/usr/local/share/pynq-venv/bin/python3`（3.10.4）。
  `/usr/bin/python3` 是没有 pynq 的那个，别用。
- **PL 加载需要 root**（写 `/sys/class/fpga_manager/fpga0/firmware`、读写 `/dev/mem`）。
  `xilinx` 用户的 sudo 需要密码（也是 `xilinx`）：`printf 'xilinx\n' | sudo -S -p "" ...`
- **`/home/xilinx/pynq/` 是全符号链接的 pynq 包副本**。在 `~/` 下跑 Python 会**遮蔽**安装的包
  （`pynq.__file__` 指向 `~/pynq/...`，且 `_subclasses` 为空）。跑脚本要 cd 到别处。
- Jupyter 在 **9090** 口（Tornado），80 口是 `redirect_server` 跳转过去。
- Jupyter 以 root 运行：`/usr/local/share/pynq-venv/bin/jupyter-notebook --no-browser --allow-root`

### 镜像 ↔ 工具链版本：实测结论（2026-10-13）
**PYNQ-Z2 v3.1.1 + Vivado 2025.2 可用，overlay 加载连 `ignore_version` 都不需要。**
（v3.1.1 绑 Vivado 2024.1，但 PYNQ 的版本检查能容忍 2025.2。）
⇒ 推翻了此前"差一个大版本很可能不兼容"的担忧。**不再需要装 Vivado 2024.x。**

## PYNQ-Z2 板载资源引脚（手册已核实）

| 器件 | 引脚 | 有效电平 |
|---|---|---|
| LED0–3 | R14 / P14 / N16 / M14 | 高电平点亮 |
| RGB LED | 见手册 Table 12 | **低电平点亮**（经三极管反相） |
| BTN0–3 | D19 / D20 / L20 / L19 | 按下为高 |
| SW0 / SW1 | M20 / M19 | 拨到 up 为高 |
| Pmod A | pin1–4 = Y18/Y19/Y16/Y17，pin7–10 = U18/U19/W18/W19；pin5/11=GND，pin6/12=3V3 | 3.3V，**不可接 5V** |

Pmod 是**母座**，插进去的一端要公头。Pmod 引脚**悬空时读高电平**（板上有外部上拉）。
