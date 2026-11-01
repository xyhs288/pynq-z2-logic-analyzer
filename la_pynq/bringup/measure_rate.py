"""
measure_rate.py —— 实测采样节拍绝对速率（判决 PL 时钟到底是多少 MHz）

背景
----
la_sys_test.py 里出现一个对不上的数：等 FULL 花了 1355 ms，
但 WR_PTR 只读到 269。由 trig_fsm 可知 FULL 需要写满
    post_limit = 物理深度 - PRE_TRIG = 8192 - 256 = 7936 个点，
所以真实写入点数 W 必然 >= 7936，而 W mod 8192 = 269
    => W = 8461 或 16653 或 24845 ...
光看这个数判不出时钟频率，因为 W 有歧义。

判别方法
--------
软复位（CTRL.bit1）会把 wr_ptr 清零。清零后**立刻**布防，
在固定时长 t 内自由写入，只要写入点数 < 物理深度 8192，
wr_ptr 就是「这 t 秒里真实写入的点数」，没有回绕歧义：
    采样率 = wr_ptr / t

为什么不能用自测源的频率反推时钟
--------------------------------
自测源（test_gen）和采样节拍（smp_clk_div）**出自同一个时钟**。
"CH5 一个周期有几个采样点" 等于 2^22 / DIV，与时钟频率无关。
只有把 wr_ptr 和**秒**联系起来，才有判决力。

运行（SSH）：
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 measure_rate.py
"""

import time

from pynq import Overlay, MMIO

CTRL, STATUS, DIV, DEPTH = 0x00, 0x04, 0x08, 0x0C
TRIG_MODE, TRIG_CHAN, PRE_TRIG = 0x10, 0x14, 0x20
WR_PTR = 0x84
PHYS_DEPTH = 8192

LINE = "=" * 62


def sec(t):
    print()
    print(LINE)
    print(t)
    print(LINE)


ol = Overlay("la_sys.bit", ignore_version=True)
key = [k for k in ol.ip_dict if "la_top" in k][0]
mmio = MMIO(ol.ip_dict[key]["phys_addr"], 0x1000)
rd, wr = mmio.read, mmio.write


sec("1. PS 侧报告的 PL 时钟频率（PYNQ 自己的账本）")
try:
    from pynq import Clocks
    for i in range(4):
        try:
            print("  fclk%d_mhz = %s" % (i, getattr(Clocks, "fclk%d_mhz" % i)))
        except Exception as e:
            print("  fclk%d 读不到: %s" % (i, e))
    try:
        print("  cpu_mhz   = %s" % Clocks.cpu_mhz)
    except Exception as e:
        print("  cpu_mhz 读不到: %s" % e)
except Exception as e:
    print("  Clocks 不可用: %s" % e)
print("  clock_dict:", ol.clock_dict)


sec("2. 实测采样节拍绝对速率")


print("  每档：软复位归零 -> 布防 -> 计时窗口内读 wr_ptr 的增量")
print()
print("  %-8s %-10s %-12s %-14s %s" % ("DIV", "点数", "实测耗时", "采样率", "推出 clk"))
print("  " + "-" * 58)

for d, w in ((10000, 0.5), (20000, 0.5), (50000, 1.0), (5000, 0.2)):
    wr(CTRL, 0x2)
    time.sleep(0.05)
    wr(CTRL, 0x4)
    wr(DIV, d)
    wr(TRIG_MODE, 0)
    wr(TRIG_CHAN, 0)
    wr(PRE_TRIG, 256)
    wr(CTRL, 0x5)
    time.sleep(0.02)

    t0 = time.perf_counter()
    a = rd(WR_PTR) & (PHYS_DEPTH - 1)
    time.sleep(w)
    b = rd(WR_PTR) & (PHYS_DEPTH - 1)
    t1 = time.perf_counter()

    st = rd(STATUS)
    n = (b - a) & (PHYS_DEPTH - 1)
    dt = t1 - t0
    rate = n / dt
    clk = rate * d
    flag = ""
    if st & 0x4:
        flag = "  <-- 已 FULL，本行不可信"
    if n >= PHYS_DEPTH - 1:
        flag = "  <-- 可能回绕，本行不可信"
    print("  %-8d %-10d %-12.4f %-14.1f %.2f MHz%s"
          % (d, n, dt, rate, clk / 1e6, flag))

print()
print("  读法：DIV 每翻一倍，采样率应减半；'推出 clk' 一列应当各行一致，")
print("        那个一致的数就是 PL 时钟的真实频率。")

wr(CTRL, 0x0)
print()
print("=== DONE ===")
