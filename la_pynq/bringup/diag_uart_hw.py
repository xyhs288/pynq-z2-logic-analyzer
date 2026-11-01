# 诊断：硬件 UART 解码器为什么给出 0xF3
# 读 PROTO_SEL / PROTO_DIV / PROTO_BYTE / PROTO_STAT，并在紧循环里采一批字节
import time
from la_driver import LogicAnalyzer

la = LogicAnalyzer()
print("PROTO_SEL  =", la.rd(0x28))
print("PROTO_DIV  =", la.rd(0x2C))
print("PROTO_STAT = 0x%02X" % la.rd(0x34))
print("CTRL       = 0x%02X" % la.rd(0x00))
print("DIV        =", la.rd(0x14))
print()

vals = []
t0 = time.time()
while time.time() - t0 < 0.6:
    vals.append(la.rd(0x30) & 0xFF)

from collections import Counter
c = Counter(vals)
print("PROTO_BYTE 采样 %d 次，不同取值 %d 种:" % (len(vals), len(c)))
for v, n in c.most_common(12):
    print("   0x%02X  %5.1f%%  (%d)" % (v, 100.0 * n / len(vals), n))

# 同时看一下 CH0 的实际位宽（用采样缓冲反推）
s, m = la.capture(div=40, pre_trig=8, trig_chan=0, read_depth=1024,
                  timeout=3.0)
b = la.channel(s, 0)
edges = [i for i in range(1, len(b)) if b[i] != b[i - 1]]
if len(edges) > 2:
    gaps = [edges[i + 1] - edges[i] for i in range(len(edges) - 1)]
    print()
    print("CH0 边沿间隔（采样点，1 点 = %d clk）:" % m["div"])
    print("   最小 %d / 最大 %d / 众数 %s" % (min(gaps), max(gaps), Counter(gaps).most_common(3)))
