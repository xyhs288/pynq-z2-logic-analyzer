# 只读寄存器，不加载 overlay（避免重新下载 bit 流把寄存器复位）
import mmap, os, struct, sys, time

BASE = 0x40000000          # axi_regs 的物理地址（bringup 里确认过）
OFF = {"CTRL": 0x00, "DIV": 0x08, "TRIG_CHAN": 0x14,
       "PROTO_SEL": 0x28, "PROTO_DIV": 0x2C, "PROTO_BYTE": 0x30,
       "PROTO_STAT": 0x34, "WR_PTR": 0x84}

f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(f, 0x1000, mmap.MAP_SHARED,
              mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)

def rd(o):
    return struct.unpack("<I", m[o:o + 4])[0]

print("CTRL       = 0x%02X" % rd(OFF["CTRL"]))
print("DIV        = %d  -> %.3f kSa/s" % (rd(OFF["DIV"]), 62.5e6 / max(1, rd(OFF["DIV"])) / 1e3))
print("TRIG_CHAN  = %d" % rd(OFF["TRIG_CHAN"]))
print("PROTO_SEL  = %d" % rd(OFF["PROTO_SEL"]))
print("PROTO_DIV  = %d  (实际需要 640)" % rd(OFF["PROTO_DIV"]))
print("PROTO_STAT = 0x%02X" % rd(OFF["PROTO_STAT"]))
print()

vals = []
t0 = time.time()
while time.time() - t0 < 0.5:
    vals.append(rd(OFF["PROTO_BYTE"]) & 0xFF)
from collections import Counter
c = Counter(vals)
print("PROTO_BYTE 采样 %d 次:" % len(vals))
for v, n in c.most_common(10):
    print("   0x%02X  %5.1f%%" % (v, 100.0 * n / len(vals)))
