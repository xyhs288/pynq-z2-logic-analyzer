"""
show_wave.py —— 跑几次采集，把波形存成 PNG（方便直接看 / 进报告）

图里标签一律英文：板子上唯一的 CJK 字体不含拉丁字母，matplotlib 3.5 又不支持
跨字体逐字形回退，中英混排会大面报缺字。

运行（板上）：
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 show_wave.py
"""

import matplotlib
matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np

from la_driver import LogicAnalyzer

OUT = "/tmp/"

la = LogicAnalyzer()
print("overlay :", la.ip, "@", hex(la.base))


def save(fig, name):
    fig.tight_layout()
    fig.savefig(OUT + name, dpi=130)
    plt.close(fig)
    print("  saved", name)


# ------------------------------------------------------------------ 1a
# 8 路频率跨 4 个数量级（0.47 Hz ~ 59.6 Hz），一个窗口装不下全部跳变，
# 所以按"慢通道 / 快通道"分两张图，每张的窗口都能看到多次翻转。
print("[1a] CH0-CH3 (slow, 2.1 s window)")
s, m = la.capture(div=16000, pre_trig=200, trig_chan=3,
                  read_depth=8192)
fig, ax = plt.subplots(figsize=(14, 5))
la.plot(s, chans=[0, 1, 2, 3], meta=m, ax=ax,
        title="CH0-CH3  slow channels   window = %.2f s   (DIV=%d)"
              % (len(s) * m["div"] / la.CLK_HZ, m["div"]))
save(fig, "wave_slow.png")

# ------------------------------------------------------------------ 1b
print("[1b] CH4-CH7 (fast, 262 ms window)")
s, m = la.capture(div=2000, pre_trig=120, trig_chan=5,
                  read_depth=8192)
fig, ax = plt.subplots(figsize=(14, 5))
la.plot(s, chans=[4, 5, 6, 7], meta=m, ax=ax,
        title="CH4-CH7  fast channels   window = %.0f ms   (DIV=%d)"
              % (len(s) * m["div"] / la.CLK_HZ * 1e3, m["div"]))
save(fig, "wave_fast.png")

# ------------------------------------------------------------------ 2
print("[2] I2C local zoom")
s2, m2 = la.capture(div=20, pre_trig=50, trig_chan=4,
                    trig_mode=la.TRIG_RISING, read_depth=4096,
                    proto_sel=la.PROTO_I2C)
e = la.edges(s2, 4)
a = int(e[0]) if len(e) else 0
b = min(a + 400, len(s2))          # 400 点 x 0.32us = 128us，约 20 个 SCL 周期
print("     decode byte = 0x%02X   edges(CH4) = %d" % (la.proto_byte(), len(e)))
fig, ax = plt.subplots(figsize=(14, 5))
la.plot(s2[a:b], chans=[4, 5], meta=m2, ax=ax,
        title="I2C from Pmod B (pin7->CH4, pin8->CH5), zoomed")
save(fig, "wave_i2c.png")

# ------------------------------------------------------------------ 3
print("[3] trigger mode compare")
fig, axes = plt.subplots(2, 1, figsize=(14, 7))
for ax, mode, name in ((axes[0], la.TRIG_RISING, "rising edge"),
                       (axes[1], la.TRIG_FALLING, "falling edge")):
    st, mt = la.capture(div=1500, pre_trig=150, trig_chan=5,
                        trig_mode=mode, read_depth=8192)
    la.plot(st, chans=[5], meta=mt, ax=ax, title="CH5 - trigger on %s" % name)
save(fig, "wave_trigger.png")

# ------------------------------------------------------------------ 4
# Pmod B 的方波周期以采样点为单位，远大于直方图量程
# （255 桶 x 16 clk = 4080 clk = 65 us），全都会饱和进最后一桶，
# 图上只有一个尖峰、没有信息量。
# 改用 I2C 的 SCL（156 kHz，半周期 200 clk）—— 正好落在量程内。
print("[4] width histogram (on I2C SCL)")
la.reset()
la.configure(div=20, proto_sel=la.PROTO_I2C)
la.stats_clear()
la.stats_enable(chan=4)             # 统计 CH4 = SCL
import time
time.sleep(0.1)
t_scan = la.stats_scan()
st = la.stats_read()
la.stats_enable(on=False)
hist = la.histogram("w")
print("     n=%d  P50=%s clk  (SCL 半周期设计值 200 clk)"
      % (st["n_width"], st["w_ps"]))
fig, ax = plt.subplots(figsize=(12, 4))
ax.bar(np.arange(256), hist, width=1.0)
ax.set_xlim(0, 40)
ax.set_xlabel("bucket (16 clk each)   ->  bucket 12 means 192~208 clk")
ax.set_ylabel("count")
ax.set_title("Pulse-width histogram of I2C SCL - hardware, 256 bins   "
             "(n=%d, P50=%d clk, scan %.0f us)"
             % (st["n_width"], st["w_ps"][0], (t_scan or 0) * 1e6))
save(fig, "hist_width.png")

print()
print("done.")
