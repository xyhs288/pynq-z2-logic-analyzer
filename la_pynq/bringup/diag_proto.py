"""
diag_proto.py —— 看 PROTO_BYTE 随时间怎么变

背景：板内 I2C 源自测时，PROTO_STAT.seen = 1、协议触发也能命中 0xAA，
但 PROTO_BYTE 读回 0x00。需要判断这是"解码器有 bug"还是"读的时机问题"
（PROTO_BYTE 是"最近解出的字节"，是瞬时值，不是粘滞量）。

做法：开自测协议源，连续采 2 秒 PROTO_BYTE，看值的分布。
  - 只出现 0x00        -> 解码器/接线有问题
  - 出现 A0 / 55 / AA  -> 通路正常，之前只是撞上了别的相位
"""

import time
from collections import Counter

from pynq import Overlay, MMIO

CTRL, PROTO_SEL, PROTO_BYTE, PROTO_STAT = 0x00, 0x28, 0x30, 0x34

ol = Overlay("la_sys.bit", ignore_version=True)
key = [k for k in ol.ip_dict if "la_top" in k][0]
mmio = MMIO(ol.ip_dict[key]["phys_addr"], 0x1000)
rd, wr = mmio.read, mmio.write

wr(CTRL, 0x2)          # 软复位：清粘滞标志
time.sleep(0.01)
wr(CTRL, 0x0)
wr(PROTO_SEL, 2)       # I2C
wr(CTRL, 0xC)          # 板内自测源 + 协议源 -> CH4/CH5 出 SCL/SDA

vals = []
t0 = time.time()
while time.time() - t0 < 2.0:
    vals.append(rd(PROTO_BYTE) & 0xFF)
    time.sleep(0.001)

c = Counter(vals)
print("采样次数 : %d" % len(vals))
print("PROTO_BYTE 分布 :")
for v in sorted(c):
    print("   0x%02X : %6d 次  (%.1f%%)" % (v, c[v], 100.0 * c[v] / len(vals)))
print("PROTO_STAT = 0x%X  (bit0=seen bit1=frame_err bit2=ack)" % rd(PROTO_STAT))
