"""
diag_i2c.py —— 量 Pmod B 上 I2C 波形（针7/8 回接 Pmod A CH4/CH5）的实际参数，和 RTL 设计值对照

设计值（la_top 参数 I2C_HALF=200, I2C_GAP=4000，clk = 62.5 MHz）：
    SCL 半周期 = 200 clk = 3.2 us  -> 周期 6.4 us (156 kHz)
    一帧 = START(2) + 3 字节 x 9 位 + STOP(2) = 31 个 HALF = 99.2 us
    GAP = 4000 clk = 64 us，且 GAP 期间 SCL / SDA 都应为高
"""

import numpy as np

from la_driver import LogicAnalyzer

la = LogicAnalyzer()
s, m = la.capture(div=20, pre_trig=2000, trig_chan=4,
                  trig_mode=la.TRIG_RISING, read_depth=4096,
                  proto_sel=la.PROTO_I2C)

us = m["div"] / la.CLK_HZ * 1e6
print("1 采样点 = %.3f us     窗口 = %d 点 = %.1f us" % (us, len(s), len(s) * us))

scl = la.channel(s, 4)
sda = la.channel(s, 5)

for name, ch in (("CH4(SCL)", scl), ("CH5(SDA)", sda)):
    hi = np.flatnonzero(ch[1:] != ch[:-1])
    print("%s : 电平翻转 %d 次, 高电平占比 %.1f%%"
          % (name, len(hi), 100.0 * ch.mean()))

h, p, l = la.measure_channel(s, 4)
if len(h) and len(l):
    print()
    print("SCL 高电平 : median %5.1f 点 = %6.1f us   min %d  max %d" % (np.median(h), np.median(h) * us, h.min(), h.max()))
    print("SCL 低电平 : median %5.1f 点 = %6.1f us   min %d  max %d" % (np.median(l), np.median(l) * us, l.min(), l.max()))
    if len(p):
        print("SCL 周期   : median %5.1f 点 = %6.1f us   (%.1f kHz)"
              % (np.median(p), np.median(p) * us, 1e3 / (np.median(p) * us)))
        print("反推周期 = %.0f clk  ->  HALF = %.0f clk   （设计值 200）"
              % (np.median(p) * m["div"], np.median(p) * m["div"] / 2))

sh, sp, sl = la.measure_channel(s, 5)
if len(sl):
    print()
    print("SDA 低电平 : median %5.1f 点 = %6.1f us   min %d  max %d"
          % (np.median(sl), np.median(sl) * us, sl.min(), sl.max()))
    print("SDA 高电平 : median %5.1f 点 = %6.1f us   min %d  max %d"
          % (np.median(sh), np.median(sh) * us, sh.min(), sh.max()))

# SCL 高电平期间 SDA 若长期为低，说明总线空闲状态不标准（GAP 里 SDA 该是高）
gap_sda = sda[scl == 1]
print()
print("SCL=1 期间共 %d 点，其中 SDA=0 的占 %.1f%%"
      % (len(gap_sda), 100.0 * (1 - gap_sda.mean())))

print()
print("SCL 每个低电平段的宽度（点），前 12 个：",
      sorted(l)[:12] if len(l) else "无")
print("SCL 最长低电平段 = %d 点 = %.1f us" % (l.max(), l.max() * us) if len(l) else "")

# 找最长低电平段的起点，把那段前后 40 点的原始值打出来
if len(l):
    pos = np.flatnonzero(scl[1:] != scl[:-1]) + 1
    lo_idx = [(pos[i], l[i]) for i in range(len(l)) if l[i] == l.max()]
    if lo_idx:
        st = lo_idx[0][0]
        a = max(0, st - 5)
        b = min(len(s), st + l.max() + 5)
        print()
        print("最长低电平段前后原始采样值（每点 SCL/SDA）：")
        for i in range(a, b, max(1, (b - a) // 20)):
            print("   idx %4d  raw=0x%02X  SCL=%d SDA=%d"
                  % (i, s[i], scl[i], sda[i]))
