"""
step1_load.py —— 精确定位挂在哪一步

关键设计：
  1. 所有输出**同时写文件 + fsync**。进程被 timeout 杀掉或板子卡死时，
     stdout 会随管道一起丢，但文件里的记录还在。
  2. 绕过 PYNQ 的 MMIO 包装，手动 open("/dev/mem") + mmap，
     把「mmap（不访问总线）」和「第一次 AXI 读（真正上总线）」分开。
     挂在哪一步，就是哪一类问题。

判读：
  T1 挂  → overlay 加载/PL 配置
  T2/T3 挂 → 驱动层（mmap 不访问 AXI 总线，不该挂）
  T4 挂  → 第一次 AXI 读挂死 → axi_regs 从机不响应
"""

import sys
import os
import time
import mmap as mmap_mod

LOG = "/home/xilinx/jupyter_notebooks/la_bringup/step1.log"


def p(*a):
    line = " ".join(str(x) for x in a)
    try:
        print(line)
        sys.stdout.flush()
    except Exception:
        pass
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
            f.flush()
            os.fsync(f.fileno())
    except Exception:
        pass


open(LOG, "w").close()
p("=== STEP1 start ===")

p("T0: import pynq")
from pynq import Overlay, MMIO
p("T0: OK")

p("T1: Overlay(la_sys.bit)")
t0 = time.time()
ol = Overlay("la_sys.bit", ignore_version=True)
p("T1: OK  (%.1f s)" % (time.time() - t0))
p("    ip_dict =", list(ol.ip_dict.keys()))

key = [k for k in ol.ip_dict if "la_top" in k][0]
base = ol.ip_dict[key]["phys_addr"]
p("    instance =", key)
p("    base     =", hex(base))
p("    clock_dict =", ol.clock_dict)

# ---------------- 手动 mmap，绕过 PYNQ 包装 ----------------
p("T2: open /dev/mem")
fd = os.open("/dev/mem", os.O_RDWR)
p("T2: OK  fd = %d" % fd)

p("T3: mmap size=0x1000 offset=%s" % hex(base))
t0 = time.time()
mem = mmap_mod.mmap(fd, 0x1000, offset=base)
p("T3: OK  (%.1f s)   <- mmap 只建映射，不访问 AXI 总线" % (time.time() - t0))

p("T4: >>> FIRST AXI READ (status @ +0x04)   <== 挂在这里 = axi_regs 不响应")
t0 = time.time()
v = int.from_bytes(mem[0x04:0x08], "little")
p("T4: OK  status = 0x%08X  (%.1f s)" % (v, time.time() - t0))

p("T5: read CTRL @ +0x00")
t0 = time.time()
v = int.from_bytes(mem[0x00:0x04], "little")
p("T5: OK  ctrl = 0x%08X  (%.1f s)" % (v, time.time() - t0))

p("T6: 走 PYNQ 的 MMIO 路径对比")
mmio = MMIO(base, 0x1000)
p("T6: MMIO created")
p("T6: status = 0x%08X" % mmio.read(0x04))

p("T7: 连续读 16 个寄存器（看是否稳定）")
for a in range(0, 0x40, 4):
    p("    +0x%02X = 0x%08X" % (a, mmio.read(a)))

p("=== STEP1 DONE ===")
