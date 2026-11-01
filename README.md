# PYNQ-Z2 八通道逻辑分析仪与协议分析仪

基于 Zynq-7020（PYNQ-Z2）的逻辑分析仪。采样、触发、缓冲、协议解码、时序统计全部在 PL 侧用 Verilog 实现，
PS 侧只跑 Python 驱动和网页界面。

## 平台

- 开发板：PYNQ-Z2（XC7Z020-1CLG400C）
- 工具：Vivado 2025.2，PYNQ 3.1.1 镜像
- 时钟：FCLK_CLK0 = 62.5 MHz，全设计单时钟域

## 功能

- 8 路并行采样，8192 点环形缓冲，预触发深度可配
- 边沿触发 / 协议字节触发
- UART、SPI、I2C 三路硬件解码器并行
- 256 桶脉宽与周期直方图，P50/P95/P99 硬件扫描（514 clk）
- 35 个 AXI4-Lite 寄存器
- 浏览器实时波形：缩放、通道开关、双游标测量、历史快照逐帧回看

## 目录

```
la_pynq/rtl            Verilog 源码，la_top.v 为整机顶层
la_pynq/ps             Python 驱动、HTTP 服务、网页界面
la_pynq/build          建工程 / 综合 / 下载的 Tcl 脚本
la_pynq/constraints    引脚约束
la_pynq/sim            testbench
la_pynq/docs           寄存器映射、Pmod 接线表、启动说明
skills/                Vivado 命令行构建流程与踩坑记录
```

## 运行

板上执行：

```bash
cd /home/xilinx/jupyter_notebooks/la_bringup
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 la_server.py --port 8080
```

浏览器打开 `http://<板子IP>:8080/`。

信号从 Pmod A 引入。板子自身从 Pmod B 输出 8 路测试波形（UART 文本 / 方波 / I2C 时序），
用杜邦线回接到 Pmod A 即可自测；拔掉任一根线，对应通道立刻变直线。
接线表见 `la_pynq/docs/pmod_wiring.md`。

## 重建 bitstream

```bash
cd la_pynq/build
vivado -mode batch -source build_bd_la.tcl
```

输出 `la_sys.bit` 与 `la_sys.hwh`。

## 资源占用

3328 LUT（6.26%）、2064 FF（1.94%）、2 个 BRAM36、0 DSP；
62.5 MHz 下 WNS +0.365 ns、WHS +0.030 ns，无失败端点。
