"""
la_sys_test.py —— 整机集成真机验证（PS7 + AXI Interconnect + la_top）

这是第一次让**我们自己的 axi_regs 从机**真正接在 Zynq PS 的 GP 口上，
所以判据分三层：
  A. 寄存器读写（AXI 协议本身通不通）
  B. 采集链路（arm -> 触发 -> 抓满 -> 通过 AXI 读回数据）
  C. 时序统计模块活着（样本数在涨）

板上没有接任何外部信号，靠 CTRL.bit2 = 1 打开**板内自测源**（内部 8 路方波）。

运行（Jupyter 里直接跑；SSH 要加 XILINX_XRT=/usr）：
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 la_sys_test.py
"""

import sys
import time

# ---- 寄存器（契约见 docs/interface.md）----
CTRL, STATUS, DIV, DEPTH = 0x00, 0x04, 0x08, 0x0C
TRIG_MODE, TRIG_CHAN, TRIG_VALUE = 0x10, 0x14, 0x18
PRE_TRIG, CHAN_EN = 0x20, 0x24
PROTO_SEL, PROTO_DIV, PROTO_BYTE, PROTO_STAT = 0x28, 0x2C, 0x30, 0x34
STAT_CTRL, STAT_STAT, HIST_ADDR, HIST_WCNT = 0x38, 0x3C, 0x40, 0x44
W_P50, W_P95, W_P99 = 0x4C, 0x50, 0x54
P_P50, STAT_NW, STAT_NP, STAT_ERR = 0x58, 0x74, 0x78, 0x7C
MEM_ADDR, WR_PTR, STOP_PTR = 0x80, 0x84, 0x88

PHYS_DEPTH = 8192        # 物理缓冲深度，RTL 参数固定值（la_top.v 的 DEPTH）
DIV_VAL = 10000          # 62.5MHz / 10000 = 6.25 kHz 采样（时钟为 PS FCLK_CLK0）
DEPTH_VAL = 1024         # 本次从缓冲里读回多少点（0x0C DEPTH 只管读出长度）
PRE_TRIG_VAL = 256
TRIG_CH = 3              # CH3 = 7.5 Hz 方波

LINE = "=" * 62
n_fail = 0


def sec(t):
    print()
    print(LINE)
    print(t)
    print(LINE)


def chk(name, got, want):
    global n_fail
    ok = (got == want)
    print("  [%s] %-44s = 0x%08X (期望 0x%08X)"
          % ("PASS" if ok else "FAIL", name, got, want))
    if not ok:
        n_fail += 1


def chk_t(name, cond, detail=""):
    global n_fail
    print("  [%s] %-44s %s" % ("PASS" if cond else "FAIL", name, detail))
    if not cond:
        n_fail += 1


# ---------------------------------------------------------------------
sec("0. 加载 overlay")
from pynq import Overlay, MMIO

ol = Overlay("la_sys.bit", ignore_version=True)

key = None
for k in ol.ip_dict:
    if "la_top" in k:
        key = k
        break
if key is None:
    print("  [FAIL] ip_dict 里找不到 la_top：", list(ol.ip_dict.keys()))
    sys.exit(1)

base = ol.ip_dict[key]["phys_addr"]
print("  实例名 :", key)
print("  基地址 :", hex(base))
print("  clock_dict:", ol.clock_dict)

mmio = MMIO(base, 0x1000)
rd, wr = mmio.read, mmio.write


# ---------------------------------------------------------------------
sec("A. 寄存器读写（AXI 协议）")

st = rd(STATUS)
chk("STATUS 复位值", st, 0)

wr(DIV, 12345)
chk("DIV 写读一致", rd(DIV), 12345)

wr(TRIG_VALUE, 0x5A)
chk("TRIG_VALUE 写读一致", rd(TRIG_VALUE), 0x5A)

wr(PRE_TRIG, 300)
chk("PRE_TRIG 写读一致", rd(PRE_TRIG), 300)

wr(CTRL, 0x4)
c = rd(CTRL)
chk_t("CTRL.bit2 自测源置位", (c & 0x4) == 0x4, "CTRL=0x%X" % c)
chk_t("CTRL.bit0 arm 仍为 0", (c & 0x1) == 0, "CTRL=0x%X" % c)

wr(CTRL, 0x0)
c = rd(CTRL)
chk_t("CTRL 清回 0", c == 0, "CTRL=0x%X" % c)

print()
print("  A 层完成：我们的 axi_regs 在真实 PS 的 GP 口上能正常读写。")


# ---------------------------------------------------------------------
sec("B. 采集链路（arm -> 触发 -> 抓满 -> AXI 读回）")

wr(CTRL, 0x2)                    # bit1 = 软复位，清写指针 / FSM
time.sleep(0.05)
wr(CTRL, 0x4)                    # 自测源开
wr(DIV, DIV_VAL)
wr(DEPTH, DEPTH_VAL)
wr(PRE_TRIG, PRE_TRIG_VAL)
wr(TRIG_CHAN, TRIG_CH)
wr(TRIG_MODE, 0)                 # 0 = 上升沿
wr(CTRL, 0x4 | 0x1)              # 自测源 + arm

print("  已布防，等 FULL（CH3 半周期约 134 ms，最坏等这么久；之后还要写 7936 点）...")

t0 = time.time()
full = False
while time.time() - t0 < 5.0:
    if rd(STATUS) & 0x4:
        full = True
        break
    time.sleep(0.005)

chk_t("进入 FULL", full, "耗时 %.1f ms" % ((time.time() - t0) * 1e3))
if not full:
    print("  [FAIL] 没抓到，后面跳过")
    sys.exit(1)

print()
print("  WR_PTR   = 0x%X  (物理地址 %d / %d)" % (rd(WR_PTR), rd(WR_PTR) & (PHYS_DEPTH - 1), PHYS_DEPTH))
stop = rd(STOP_PTR) & (PHYS_DEPTH - 1)
print("  STOP_PTR = 0x%X   （时间顺序上最老那个点的物理地址）" % stop)

print()
print("  按 STOP_PTR 顺序读回 %d 个点..." % DEPTH_VAL)
samples = []
t0 = time.time()
for k in range(DEPTH_VAL):
    wr(MEM_ADDR, (stop + k) & (PHYS_DEPTH - 1))
    samples.append(rd(MEM_ADDR) & 0xFF)
dt = time.time() - t0
print("  读完耗时 %.3f s（每次一次 AXI 写 + 一次 AXI 读）" % dt)

nz = sum(1 for s in samples if s != 0)
ones = sum(bin(s).count("1") for s in samples)
print("  缓冲里非零点 = %d / %d，总 1 的个数 = %d" % (nz, DEPTH_VAL, ones))
chk_t("缓冲里确实有采到的数据（不是全 0）", nz > 0, "非零 %d" % nz)

print()
print("  CH%d 在触发点两侧的电平：" % TRIG_CH)
for i in (PRE_TRIG_VAL - 2, PRE_TRIG_VAL - 1, PRE_TRIG_VAL,
          PRE_TRIG_VAL + 1, PRE_TRIG_VAL + 2):
    print("    index %4d : 0x%02X   CH%d=%d"
          % (i, samples[i], TRIG_CH, (samples[i] >> TRIG_CH) & 1))

pre = (samples[PRE_TRIG_VAL - 1] >> TRIG_CH) & 1
post = (samples[PRE_TRIG_VAL + 1] >> TRIG_CH) & 1
chk_t("触发前 CH%d == 0" % TRIG_CH, pre == 0, "值=%d" % pre)
chk_t("触发后 CH%d == 1" % TRIG_CH, post == 1, "值=%d" % post)

print()
print("  CH7（测试源里频率最高的一路，窗口 163.8 ms 内应有多次跳变）边沿数：")
edges = 0
for i in range(1, DEPTH_VAL):
    if ((samples[i] >> 7) & 1) != ((samples[i - 1] >> 7) & 1):
        edges += 1
print("    %d 次" % edges)
chk_t("CH7 在窗口内有多次跳变", edges >= 6, "%d 次" % edges)


# ---------------------------------------------------------------------
sec("C. 时序统计模块活着")
wr(STAT_CTRL, 0x0)
wr(TRIG_CHAN, 7)                 # 统计通道 = TRIG_CHAN
wr(STAT_CTRL, 0x2)               # 清空
time.sleep(0.3)
wr(STAT_CTRL, 0x1)               # 使能
time.sleep(1.0)
nw = rd(STAT_NW)
np_ = rd(STAT_NP)
err = rd(STAT_ERR)
print("  STAT_NW  = %d  （宽度样本数）" % nw)
print("  STAT_NP  = %d  （周期样本数）" % np_)
print("  STAT_ERR = 饱和 %d 次，丢弃 %d 次" % (err & 0xFFFF, err >> 16))
chk_t("统计在计数（样本数 > 0）", nw > 0 and np_ > 0)

print()
print("  说明：自测源是 0.47~59.6 Hz 的低频方波，半周期远大于直方图量程")
print("  （255 桶 x 16 clk = 4080 clk = 65.3 us @62.5MHz），所以样本会饱和进最后一桶、")
print("  饱和计数器应当 > 0 —— 这恰好验证了饱和逻辑在工作。")

wr(STAT_CTRL, 0x0)


# ---------------------------------------------------------------------
sec("结论")
if n_fail == 0:
    print("  ✅ 三层全过。")
    print("     A. 我们的 axi_regs 在真实 Zynq PS 上读写正常")
    print("     B. 采集链路端到端跑通（触发点在窗口中间，数据经 AXI 读回）")
    print("     C. 时序统计模块在计数")
    print()
    print("     => README 里那条'AXI 从机待真机验证'可以改成已验证。")
else:
    print("  ❌ %d 项未通过，把上面输出贴回来。" % n_fail)
