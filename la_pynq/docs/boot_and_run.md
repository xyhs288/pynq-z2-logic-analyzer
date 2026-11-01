# 上电启动与演示流程

> 状态：已配置并实测通过（2026-10-31）。上电后自动加载 bit 流、自动启动网页服务，不需要电脑、不需要 Vivado、不需要 SSH。

---

## 一、现在怎么启动

```
插上 micro USB（供电）
      ↓  约 2 分钟
板子从 SD 卡启动 Linux，systemd 自动拉起 la-analyzer.service
      ↓  约 13 秒（加载 bit 流 + 起 HTTP 服务）
浏览器打开 http://192.168.2.99:8080/
```

**就这些。** 网线插在板子的以太网口，电脑改成同一网段（192.168.2.x）即可访问。

板子重启不影响 SD 卡里的文件，静态 IP 写在 `/etc/network/interfaces.d/eth0` 里，开机自动生效。

---

## 二、"每次都重新下载 bit 流"是怎么回事

**这是 Zynq 的物理特性，绕不过去，但也不用你操心。**

PL（可编程逻辑）是 **SRAM 结构**——配置数据存在片内 SRAM 里，**掉电即丢失**。所以每次上电都必须有人把 bit 流重新写进去。区别只在于**谁来写、什么时候写**：

| 方式 | 谁配置 PL | 需要电脑吗 | 需要 Vivado 吗 | 本项目适用 |
|---|---|---|---|---|
| **现在（systemd + PYNQ Overlay）** | 板子上的 Python，开机自动 | 否 | 否 | ✅ 在用 |
| boot.bin / QSPI 固化 | FSBL（上电第一段代码） | 否 | 一次性 | ⚠️ 见下 |
| Vivado JTAG 下载 | 你的电脑 | 是 | 是 | 仅调试用 |

三种方式里 PL 都是"上电时配一次"，**没有哪种能让配置永久保留**。区别只是自动化程度。

**关键点：你现在不需要"下载"这个动作。** 只有改了 RTL、要生成新 bit 流时才需要 Vivado；日常演示完全用不到。

---

## 三、能不能烧进 QSPI，彻底脱机？

**能烧，但对本项目没意义。**

PYNQ-Z2 上有 16MB Quad-SPI Flash（Spansion S25FL128S），把包含 bit 流的 `BOOT.BIN` 烧进去、把 JP1 跳线切到 QSPI 启动，确实可以做到"上电就跑"，连 SD 卡都不需要。

问题是：**那样只能跑裸机程序。** 没有 Linux 就没有网络栈、没有 Python、没有 HTTP 服务——网页界面直接没了。

除非以后把界面改成"PS 裸机 + LCD 屏 + 按键"的形态，QSPI 启动才有价值。现在这套架构（PL 采集 + PS 跑网页服务 + 浏览器显示）**必须**有 Linux。

所以结论：**用 SD 卡启动 + 开机自启，这是本方案的正确形态。** 已经配好了。

> 顺带一句：现在的 bit 流就存在 SD 卡里（`/home/xilinx/jupyter_notebooks/la_bringup/la_sys.bit`），不会因为重启丢。

---

## 四、服务管理（出问题时用）

```bash
# 看状态
systemctl status la-analyzer

# 看日志（最近 50 行）
journalctl -u la-analyzer -n 50 --no-pager
# 也有文件日志：/home/xilinx/la_server.log

# 重启（换 bit 流后必须做这一步）
sudo systemctl restart la-analyzer

# 临时停掉（比如要用 JTAG 下别的 bit 调试）
sudo systemctl stop la-analyzer

# 取消开机自启（万一出问题想恢复原状）
sudo systemctl disable la-analyzer
```

---

## 五、四个必须知道的坑

**① 用 JTAG 下过别的 bit 之后，网页会失灵。**
比如你下了 `test_axi.bit` 或 `clkmon.bit`，PL 里的电路已经不是逻辑分析仪了，但 la-analyzer 服务还在跑，它的 MMIO 读写会落到错误的地址上。
**解决**：`sudo systemctl restart la-analyzer`，让它重新加载 `la_sys.bit`。

**② 换了新 bit 流，要重启服务。**
把新的 `la_sys.bit` 和 `la_sys.hwh` 覆盖到 `/home/xilinx/jupyter_notebooks/la_bringup/` 后，执行 `restart`，否则跑的仍是旧配置。

**③ 端口 8080 被占。**
手工起过 `la_server.py` 又没关，会导致服务起不来。安装脚本里已经做了清理，但手工折腾过的话看一眼：
```bash
netstat -ltn | grep 8080
pgrep -af 'la_[s]erver'
```

**④ 板子没有 RTC，日期是错的。**
`date` 显示 2025 年不用管，不影响功能。日志时间戳不可信，按日志内容判断顺序。

---

## 五之二、上电后 PL 被换成 base（已修，但要知道症状）

**症状**：断电重启后网页能打开、`/meta` 也正常，但波形全是 2/4/8/16/32… 个采样点翻转的方波，
解码一条都没有；`WR_PTR` 一直是 0；`MEM[a]` 读回来正好等于 `a`。

**原因**：板子镜像里的 XRT/zocl 在第一个客户端释放后（开机约 16 秒）会把 PL **回落成默认的
`base.bin`**，把我们加载的 `la_sys.bit` 顶掉。`jupyter.service` 启动时也会加载 base，
而 `clear_pl_statefile.service` 又通过 `Requires=jupyter.service` 把它拉起来。

**判断方法**（一条命令）：

```bash
dmesg | grep fpga_manager | tail -5
# 正常：只有 la_sys.bin
# 出问题：la_sys.bin 后面跟着一条 base.bin
```

**已经做的修复**：

1. `systemctl mask jupyter.service clear_pl_statefile.service` —— 不让它们加载 base
2. `la_server.py` 里加了 `_pl_guard` 自检线程：启动后每 2 秒看一次 `WR_PTR`，
   连续 3 次不动就判定被换掉，重新下载 `la_sys.bit`。日志里会出现
   `[guard] 检测到 PL 被换掉，重新加载 la_sys.bit ...`

**如果又遇到**：

```bash
sudo systemctl restart la-analyzer    # 会重新加载并触发自检
dmesg | grep fpga_manager | tail -3   # 确认最后一条是 la_sys.bin
```

## 六、演示时的建议操作顺序

1. 插电，等约 2 分钟（这段时间可以讲 PPT）
2. 浏览器打开 `http://192.168.2.99:8080/`，页面应该是**停止状态**（不自动采）
3. 点「▶ 开始采集」→ 8 路波形滚动
4. 「解码」选 UART（采样率必须是 **1.56 MHz**）→ 波形上每个字节一个框，
   右上角直接显示这一帧解出的整串文本，例如 `"PYNQ-LA6PYNQ"`；
   选 I2C（CH4/CH5）→ 波形上看 `START / A0 / 55 / AA / ACK / STOP` 标注
5. 点「单次触发」→ 红色 `T` 线标出触发点；改边沿再触发一次，相位不同
6. 拔掉 Pmod 回环线 → 对应通道立刻变直线（证明采的是真实信号）

**回看历史**：底部「历史」一栏用 `◀` `▶` 按钮翻快照，也可以直接按键盘
`←` `→` 一帧一帧翻，`Home` / `End` 跳到最旧 / 最新一帧，空格开关采集。
翻页会自动暂停采集（帧与帧之间隔着整个读回耗时，不可能连续播放）。

**开机那 2 分钟别浪费**——评委不会等你，直接把这段时间用在讲作品定位上。
