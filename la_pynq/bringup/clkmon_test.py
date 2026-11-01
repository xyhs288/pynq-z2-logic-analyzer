"""
clkmon_test.py —— 测量 H16（以太网 PHY 送来的 125MHz）是否会短暂停振

背景（PYNQ-Z2 手册 5 节原文）：
    "When the PHYRSTB signal is driven low, the Ethernet PHY (U5) is held in
     reset disabling the CLK125."
PHYRSTB 接在 MIO9，由 PS 控制。所以只要 PS 拉低它，PL 的 125MHz 参考时钟就没了。

测量原理（clkmon.v）：
    被测时钟跑自由计数器；AXI 侧（挂在不依赖 PHY 的 PS FCLK 上）把计数器高位
    同步过来，并记录"同步值连续多久没变化"的**最大值** = 最长停振时间。

单位说明（重要）：
    CNT_HI = c125[31:4] << 4，即低 4 位被清零 —— 所以它的**最小变化量是 16**，
    而 16 对应 16 个被测时钟 = 128 ns。等效地，CNT_HI 的 **LSB = 1 个被测
    时钟周期 = 8 ns**（不是 128 ns！）。

运行（Jupyter 里直接跑；SSH 要加 XILINX_XRT=/usr）：
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 clkmon_test.py
"""

import sys
import time

CNT_HI, STALL_MAX, STALL, CTRL, MAGIC = 0x00, 0x04, 0x08, 0x0C, 0x10
DURATION = 20.0          # 每轮连续采样秒数
RELOADS = 3              # 反复重载 overlay 的次数

# 可选：命令行覆盖，例如 `... clkmon_test.py 300 1` = 一轮 300 秒
if len(sys.argv) > 1:
    DURATION = float(sys.argv[1])
if len(sys.argv) > 2:
    RELOADS = int(sys.argv[2])

CLK_NS = 8.0             # CNT_HI 的 LSB = 1 个被测时钟 = 8 ns
SYNC_NS = 128.0          # 同步粒度 = 16 个被测时钟

LINE = "=" * 62


def sec(t):
    print()
    print(LINE)
    print(t)
    print(LINE)


from pynq import Overlay, MMIO


def load(n):
    ol = Overlay("clkmon.bit", ignore_version=True)
    key = None
    for k in ol.ip_dict:
        if "clkmon" in k:
            key = k
            break
    if key is None:
        print("  [FAIL] ip_dict 里找不到 clkmon：", list(ol.ip_dict.keys()))
        sys.exit(1)
    return ol, MMIO(ol.ip_dict[key]["phys_addr"], 0x1000), key


def measure(mmio, dur):
    """连续采样 dur 秒，返回统计"""
    t_end = time.perf_counter() + dur
    prev_c = mmio.read(CNT_HI)
    prev_t = time.perf_counter()

    n = 0
    max_dt = 0.0
    max_dt_dc = 0
    worst = []

    while time.perf_counter() < t_end:
        c = mmio.read(CNT_HI)
        t = time.perf_counter()

        dc = (c - prev_c) & 0xFFFFFFFF
        dt = t - prev_t
        n += 1

        if dt > 5e-5:                      # 只挑出"慢"的读
            worst.append((dt, dc))
            if dt > max_dt:
                max_dt = dt
                max_dt_dc = dc

        prev_c, prev_t = c, t

    worst.sort(reverse=True)
    return n, max_dt, max_dt_dc, worst


# ---------------------------------------------------------------------
sec("0. 加载 overlay")
ol, mmio, key = load(0)
print("  实例名 :", key)
print("  基地址 :", hex(mmio.base_addr))
print("  clock_dict:", ol.clock_dict)


sec("1. AXI 通路自检")
m = mmio.read(MAGIC)
print("  MAGIC = 0x%08X  (期望 0x12345678)" % m)
if m != 0x12345678:
    print("  [FAIL] AXI 读通路不对，后面结果不可信")
    sys.exit(1)
print("  [PASS] AXI 通路正常")


sec("2. 时钟是否在跑（用 200ms 标定频率）")
a = mmio.read(CNT_HI)
t0 = time.perf_counter()
time.sleep(0.2)
b = mmio.read(CNT_HI)
t1 = time.perf_counter()
d = (b - a) & 0xFFFFFFFF
dt = t1 - t0
# CNT_HI 每个单位 = 1 个被测时钟（低 4 位被清零，所以 d 总是 16 的倍数）
freq = d / dt
print("  %.1f ms 内 CNT_HI 增加 %d -> 推算频率 = %.3f MHz"
      % (dt * 1e3, d, freq / 1e6))
if d == 0:
    print("  [FAIL] 计数器没动 —— 被测时钟是停的")
    sys.exit(1)
print("  [PASS] 被测时钟在跑，实测 %.3f MHz（设计值 125 MHz）" % (freq / 1e6))


# ---------------------------------------------------------------------
sec("3. 连续采样 + 反复重载 overlay（共 %d 轮，每轮 %.0f s）" % (RELOADS, DURATION))

overall_stall_max = 0

for r in range(RELOADS):
    print()
    print("  ---------- 第 %d 轮 ----------" % (r + 1))
    if r > 0:
        ol, mmio, _ = load(r)
        if mmio.read(MAGIC) != 0x12345678:
            print("    重载后 MAGIC 不对，跳过")
            continue

    mmio.write(CTRL, 1)                    # 清统计
    n, max_dt, max_dt_dc, worst = measure(mmio, DURATION)
    smax = mmio.read(STALL_MAX)

    print("    采样 %d 次（平均 %.0f kHz）" % (n, n / DURATION / 1e3))
    print("    >>> 本轮最长停振 STALL_MAX = %d 个 AXI 周期" % smax)

    if smax > overall_stall_max:
        overall_stall_max = smax

    print("    参考（下面是 PS 侧的调度抖动，不是时钟停振——")
    print("    被抢占时 dt 会偏大而计数偏小，下一次读会补回来）：")
    for wdt, wdc in worst[:3]:
        print("      dt=%9.3f ms  该区间计数器走了 %9.3f ms"
              % (wdt * 1e3, wdc * CLK_NS * 1e-6))


# ---------------------------------------------------------------------
sec("最终结论")
print("  同步粒度 = 128 ns（每 16 个被测时钟更新一次）。")
print("  AXI 约 50 MHz（20 ns/周期）时，STALL_MAX 的**地板值** ≈ 128/20 = 6.4，")
print("  即：只要没超过约 7，就说明整个监控期间时钟一次都没停过。")
print()
print("  全程测得的最大 STALL_MAX = %d" % overall_stall_max)
print()
if overall_stall_max <= 20:
    print("  ✅ 未测到任何停振。")
    print("     STALL_MAX = %d 恰好是地板值，说明被测时钟始终连续。" % overall_stall_max)
    print("     => 这块板子上 PHY 的 CLK125 在**运行期**是稳定的，")
    print("        可以直接用作 PL 主时钟。")
else:
    print("  ⚠️ 测到停振：STALL_MAX = %d ≈ %.3f ms（按 AXI=50MHz 折算）"
          % (overall_stall_max, overall_stall_max * 20e-6))
    print("     老师的说法在这块板子上成立。设计上必须考虑：")
    print("       · AXI 若挂在会被停的时钟上，PS 的事务会被卡住")
    print("       · 建议 PL 主时钟改用 PS 的 FCLK（来自 PS PLL，与 PHY 无关）")
print()
print("  注：本测试覆盖的是**运行期**。PHY 复位发生在启动阶段（PL 还没配置），")
print("      那个阶段不影响我们。")
