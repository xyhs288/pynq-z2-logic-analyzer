"""
probe_axi.py <base> [offset ...] —— 绕过 PYNQ，直接读 PL 的 AXI 寄存器

用途：PL 由 JTAG 预先配置好，本脚本**不做 Overlay 加载**，直接 open /dev/mem
+ mmap 读物理地址。这样能把「从机本身不响应」与「PYNQ 加载流程的干扰」分开。

用法（板子上）：
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 -u \
         probe_axi.py 0x41200000 0x0 0x4        # AXI GPIO
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 -u \
         probe_axi.py 0x40000000 0x0 0x4 0x8    # 我们的从机

判读：
  某个 read 行之后没有输出 = 挂死在那个地址
  全部读完 = 从机正常响应
"""

import sys
import os
import time
import mmap as mmap_mod

LOG = "/home/xilinx/jupyter_notebooks/la_bringup/probe.log"


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

if len(sys.argv) < 2:
    p("usage: probe_axi.py <base> [offset ...]")
    sys.exit(1)

base = int(sys.argv[1], 0)
offs = [int(x, 0) for x in sys.argv[2:]] or [0]

p("=== PROBE ===")
p("base    = %s" % hex(base))
p("offsets = %s" % [hex(o) for o in offs])
p("(PL 必须已由 JTAG 配置；本脚本不做 Overlay 加载)")

p("open /dev/mem")
fd = os.open("/dev/mem", os.O_RDWR)
p("open OK  fd=%d" % fd)

p("mmap 0x1000 @ %s" % hex(base))
t0 = time.time()
mem = mmap_mod.mmap(fd, 0x1000, offset=base)
p("mmap OK  (%.3f s)" % (time.time() - t0))

for o in offs:
    p(">>> read +0x%02X" % o)
    t0 = time.time()
    v = int.from_bytes(mem[o:o + 4], "little")
    p("    = 0x%08X    (%.3f s)" % (v, time.time() - t0))

p("=== PROBE DONE (all reads returned) ===")
