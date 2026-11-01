"""
la_driver.py —— 多通道逻辑分析仪 PS 侧驱动

寄存器契约见 la_pynq/docs/interface.md（冻结版 v2），本文件严格照它的第 "三" 节流程写。

在板子上跑（SSH）：
    cd <本目录>
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 -u la_driver.py

在 Jupyter 里：
    from la_driver import LogicAnalyzer
    la = LogicAnalyzer()
    samples, meta = la.capture(div=1000, pre_trig=512)
    la.plot(samples, chans=[0, 1, 2, 3])

两个常量来自 RTL，改 RTL 必须同步改这里：
    PHYS_DEPTH = 8192     物理缓冲深度 = la_top.v 的 DEPTH 参数
    CLK_HZ     = 62.5e6   FCLK_CLK0 实测频率（bringup/measure_rate.py 测出，非 125M）
"""

import time
import warnings

import numpy as np


class LogicAnalyzer:
    # ---------------- 寄存器偏移（对齐 docs/interface.md） ----------------
    CTRL = 0x00
    STATUS = 0x04
    DIV = 0x08
    DEPTH = 0x0C
    TRIG_MODE = 0x10
    TRIG_CHAN = 0x14
    TRIG_VALUE = 0x18
    TRIG_MASK = 0x1C
    PRE_TRIG = 0x20
    CHAN_EN = 0x24

    PROTO_SEL = 0x28
    PROTO_DIV = 0x2C
    PROTO_BYTE = 0x30
    PROTO_STAT = 0x34

    STAT_CTRL = 0x38
    STAT_STAT = 0x3C
    HIST_ADDR = 0x40
    HIST_WCNT = 0x44
    HIST_PCNT = 0x48
    W_P50, W_P95, W_P99 = 0x4C, 0x50, 0x54
    P_P50, P_P95, P_P99 = 0x58, 0x5C, 0x60
    W_MIN, W_MAX, P_MIN, P_MAX = 0x64, 0x68, 0x6C, 0x70
    STAT_NW, STAT_NP, STAT_ERR = 0x74, 0x78, 0x7C

    MEM_ADDR, WR_PTR, STOP_PTR = 0x80, 0x84, 0x88
    BTN_CNT = 0x8C

    # ---------------- 位定义 ----------------
    CTRL_ARM = 0x1
    CTRL_RESET = 0x2
    # bit2 / bit3 保留（原板内自测源，已删除），写 1 无效果
    CTRL_PMODB = 0x20            # Pmod B 输出使能（0 = 高阻，接真实被测电路时关掉）

    ST_ARMED = 0x1
    ST_TRIGGED = 0x2
    ST_FULL = 0x4

    # 触发模式
    TRIG_RISING, TRIG_FALLING, TRIG_HIGH, TRIG_LOW, TRIG_PROTO = 0, 1, 2, 3, 4

    # 协议选择
    PROTO_UART, PROTO_SPI, PROTO_I2C = 0, 1, 2

    # ---------------- 板级常量 ----------------
    PHYS_DEPTH = 8192
    CLK_HZ = 62_500_000

    # =================================================================
    def __init__(self, bit="la_sys.bit", ip_hint="la_top", ignore_version=True):
        from pynq import Overlay, MMIO

        self.ol = Overlay(bit, ignore_version=ignore_version)
        key = next((k for k in self.ol.ip_dict if ip_hint in k), None)
        if key is None:
            raise RuntimeError("overlay 里没有 %r，实际有 %s"
                               % (ip_hint, list(self.ol.ip_dict)))
        self.ip = key
        self.base = self.ol.ip_dict[key]["phys_addr"]
        self.mmio = MMIO(self.base, 0x1000)

    def __repr__(self):
        return "<LogicAnalyzer %s @ %s, 最高 %.1f kSa/s, 深 %d>" % (
            self.ip, hex(self.base), self.CLK_HZ / 1e3, self.PHYS_DEPTH)

    def reload(self, bit="la_sys.bit", ip_hint="la_top", ignore_version=True):
        """重新下载 bit 流，并**重建 MMIO**。

        为什么必须重建：Overlay 重配置 PL 之后，旧的 MMIO 映射已经不对应新设计了，
        继续拿它读 WR_PTR 会读到一个永远不变的值 —— 上层会误判成"PL 又卡住了"，
        于是再重载一次，变成无限重载 PL 的死循环（最后 PS 挂死）。
        """
        from pynq import Overlay, MMIO

        self.ol = Overlay(bit, ignore_version=ignore_version)
        key = next((k for k in self.ol.ip_dict if ip_hint in k), None)
        if key is None:
            raise RuntimeError("overlay 里没有 %r，实际有 %s"
                               % (ip_hint, list(self.ol.ip_dict)))
        try:
            self.mmio.close()
        except Exception:
            pass
        self.ip = key
        self.base = self.ol.ip_dict[key]["phys_addr"]
        self.mmio = MMIO(self.base, 0x1000)
        return self

    # ---------------- 底层寄存器 ----------------
    def rd(self, off):
        return self.mmio.read(off)

    def wr(self, off, val):
        self.mmio.write(off, val & 0xFFFFFFFF)

    @property
    def sample_rate(self):
        """当前采样率（Hz）"""
        return self.CLK_HZ / (self.rd(self.DIV) or 1)

    def status(self):
        s = self.rd(self.STATUS)
        return {"armed": bool(s & self.ST_ARMED),
                "trigged": bool(s & self.ST_TRIGGED),
                "full": bool(s & self.ST_FULL)}

    # ---------------- 采集流程（契约第三节） ----------------
    def reset(self):
        """软复位：清写指针 / 触发 FSM / 粘滞标志。第 3 步。"""
        self.wr(self.CTRL, self.CTRL_RESET)
        time.sleep(0.001)
        self.wr(self.CTRL, 0x0)

    def _ctrl_bits(self, pmodb=True):
        # 注意：每次写 CTRL 都要带上 PMODB 位，否则 Pmod B 测试信号会被关掉
        return self.CTRL_PMODB if pmodb else 0

    def configure(self, div=1000, pre_trig=512, trig_mode=TRIG_RISING,
                  trig_chan=0, trig_value=0, read_depth=None,
                  proto_sel=None, proto_div=None, pmodb=True):
        """第 1、2 步：写配置寄存器（不含软复位和布防）

        proto_sel / proto_div 传 None 表示"不动它"。**不要**默认去写，
        否则会把上一处设置的协议选择覆盖掉（踩过：只看解码结果、不做协议触发时，
        PROTO_SEL 停在复位默认的 UART，读回来的字节跟自己想看的协议没关系）。
        """
        self.wr(self.DIV, div)
        self.wr(self.PRE_TRIG, pre_trig)
        self.wr(self.TRIG_MODE, trig_mode)
        self.wr(self.TRIG_CHAN, trig_chan)
        self.wr(self.TRIG_VALUE, trig_value)
        # 协议选择与触发模式无关：想单独用解码器也一样要能设
        if proto_sel is not None:
            self.wr(self.PROTO_SEL, proto_sel)
        if proto_div is not None:
            self.wr(self.PROTO_DIV, proto_div)
        if read_depth is not None:
            self.wr(self.DEPTH, read_depth)
        self.wr(self.CTRL, self._ctrl_bits(pmodb))

    def arm(self, pmodb=True):
        """第 4 步：布防"""
        self.wr(self.CTRL, self.CTRL_ARM | self._ctrl_bits(pmodb))

    def wait_full(self, timeout=5.0, poll=0.002):
        """第 5 步：轮询 STATUS.full。注意 trigged 只在触发到抓满之间为 1，full 才可靠。"""
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.rd(self.STATUS) & self.ST_FULL:
                return True
            time.sleep(poll)
        return False

    def read_samples(self, n):
        """第 6、7 步：从 STOP_PTR 起按时间顺序读回 n 个点。

        0x80 是"写地址 / 读数据"复用的：写进去的是物理地址，读出来的是该地址的采样值。
        STOP_PTR + i 会越过缓冲末尾，所以必须 & (物理深度 - 1) 回绕。
        """
        mask = self.PHYS_DEPTH - 1
        stop = self.rd(self.STOP_PTR) & mask
        out = np.empty(n, dtype=np.uint8)
        mm = self.mmio
        for i in range(n):
            mm.write(self.MEM_ADDR, (stop + i) & mask)
            out[i] = mm.read(self.MEM_ADDR) & 0xFF
        return out, stop

    def capture(self, div=1000, pre_trig=512, trig_mode=TRIG_RISING, trig_chan=0,
                trig_value=0, read_depth=None, timeout=5.0,
                proto_sel=None, proto_div=None):
        """配置 -> 布防 -> 等抓满 -> 读回。返回 (samples, meta)。"""
        read_depth = read_depth or self.PHYS_DEPTH
        self.reset()
        self.configure(div=div, pre_trig=pre_trig, trig_mode=trig_mode,
                       trig_chan=trig_chan, trig_value=trig_value,
                       read_depth=read_depth,
                       proto_sel=proto_sel, proto_div=proto_div)
        wp0 = self.rd(self.WR_PTR) & (self.PHYS_DEPTH - 1)   # 布防前写指针
        self.arm()

        t0 = time.time()
        if not self.wait_full(timeout=timeout):
            raise TimeoutError("等 FULL 超时 %.1fs，status=%s" % (timeout, self.status()))
        t_wait = time.time() - t0

        t0 = time.time()
        samples, stop = self.read_samples(read_depth)
        t_read = time.time() - t0

        meta = {
            "div": div,
            "sample_rate": self.CLK_HZ / div,
            "pre_trig": pre_trig,
            "trig_mode": trig_mode,
            "trig_chan": trig_chan,
            "read_depth": read_depth,
            "stop_ptr": stop,
            "wr_ptr": self.rd(self.WR_PTR),
            "t_wait": t_wait,
            "t_read": t_read,
        }

        # 预触发区是否真的填满了：从布防到触发这段时间必须写够 pre_trig 个点，
        # 否则窗口最前面那些点是上一轮捕获留在 BRAM 里的旧数据（波形上会看到怪毛刺）。
        #
        # 注意 STOP_PTR 是 **FULL 那一刻**的写指针（cap_en 落下时锁存），不是触发时刻的。
        # 触发时刻写指针 = STOP_PTR - post_limit，post_limit = 物理深度 - PRE_TRIG。
        # 这里我第一版算错过：直接拿 STOP_PTR 减布防前的写指针，会得出"写了 8000 多点"的假象。
        pre_eff = min(pre_trig, self.PHYS_DEPTH)
        post_limit = self.PHYS_DEPTH - pre_eff
        trig_wr = (stop - post_limit) & (self.PHYS_DEPTH - 1)
        n_armed = (trig_wr - wp0) & (self.PHYS_DEPTH - 1)
        meta["pre_armed"] = n_armed
        meta["pre_valid"] = min(n_armed, pre_trig)
        if n_armed < pre_trig:
            warnings.warn(
                "预触发区没填满：布防到触发只写了 %d 点，而 PRE_TRIG=%d；"
                "窗口最前面 %d 点是旧数据。把 PRE_TRIG 降到 %d 以下。"
                % (n_armed, pre_trig, pre_trig - n_armed, n_armed),
                RuntimeWarning)
        return samples, meta

    # ---------------- 滚动显示（free run 模式） ----------------
    def set_free_run(self, on=True, div=1000, proto_sel=None, proto_div=None,
                     pmodb=True):
        """进入/退出自由运行模式（CTRL.bit4）。

        free run 下 cap_en 常有效，缓冲一直写、永不触发停止，
        PS 可以随时读最新 N 个点做滚动显示。
        """
        if on:
            self.wr(self.DIV, div)
            if proto_sel is not None:
                self.wr(self.PROTO_SEL, proto_sel)
            if proto_div is not None:
                self.wr(self.PROTO_DIV, proto_div)
            bits = self._ctrl_bits(pmodb)
            self.wr(self.CTRL, bits)              # 先清 free_run，写入配置
            self.wr(self.CTRL, bits | 0x10)       # 0x10 = free run
        else:
            self.wr(self.CTRL, self.CTRL_PMODB if pmodb else 0x0)

    def set_pmodb(self, on=True):
        """Pmod B 测试信号总开关。关掉后 8 根针是高阻，
        可以把 Pmod A 直接接到真实被测电路上，不会被板子自己驱动。"""
        c = self.rd(self.CTRL)
        c = (c | self.CTRL_PMODB) if on else (c & ~self.CTRL_PMODB)
        self.wr(self.CTRL, c & ~self.CTRL_ARM & ~0x10)   # 顺手别把 arm/free_run 带进去
        return on

    def read_latest(self, n, freeze=True):
        """读环形缓冲里**最新**的 n 个点（不等待触发）。

        关键：读取期间必须先停写。
        每一对 AXI 事务约 37 us，读 8192 点要 0.31 s，而缓冲在 1.5625 MSa/s 下
        5.2 ms 就绕一圈 —— 不停写的话，读回来的是几十个不同时刻的碎片拼在一起，
        波形看着像真的，字节全错。停写再读，得到的就是同一时刻的连续快照。

        返回 (samples, wr_ptr)。freeze=False 时保持旧行为（仅用于不需要一致性的场合）。
        """
        mask = self.PHYS_DEPTH - 1
        ctrl0 = self.rd(self.CTRL) if freeze else 0
        if freeze:
            self.wr(self.CTRL, ctrl0 & ~0x10)      # 清 free_run -> cap_en 落下，停止写入
        try:
            wr = self.rd(self.WR_PTR) & mask
            start = (wr - n) & mask
            out = np.empty(n, dtype=np.uint8)
            mm = self.mmio
            w, r = mm.write, mm.read
            addr = self.MEM_ADDR
            for i in range(n):
                w(addr, (start + i) & mask)
                out[i] = r(addr) & 0xFF
        finally:
            if freeze:
                self.wr(self.CTRL, ctrl0)          # 恢复 free run，采集继续
        return out, wr

    # ---------------- 数据处理 ----------------
    @staticmethod
    def channel(samples, chan):
        """取某一路的比特序列（0/1）"""
        return ((samples >> chan) & 1).astype(np.uint8)

    def time_axis(self, n, div=None):
        """时间轴（微秒）。第 i 点对应 i * div / CLK。"""
        div = div or self.rd(self.DIV)
        return np.arange(n, dtype=np.float64) * (div / self.CLK_HZ) * 1e6

    def edges(self, samples, chan):
        """返回该通道跳变位置（索引数组）"""
        b = self.channel(samples, chan)
        return np.flatnonzero(b[1:] != b[:-1]) + 1

    def measure_channel(self, samples, chan):
        """量某通道的脉宽 / 周期，单位是**采样点**

        返回 (high_widths, periods, low_widths)。
        periods 是**同向边沿**（上升沿到上升沿）的间隔；别用 np.diff(所有边沿)，
        那是半周期 —— 这个坑我踩过，会把 156 kHz 的 I2C 读成 312 kHz。
        """
        b = self.channel(samples, chan)
        pos = np.flatnonzero(b[1:] != b[:-1]) + 1
        if len(pos) < 3:
            return np.array([]), np.array([]), np.array([])
        highs, lows = [], []
        for k in range(len(pos) - 1):
            (highs if b[pos[k]] else lows).append(pos[k + 1] - pos[k])
        rise = np.flatnonzero((b[1:] == 1) & (b[:-1] == 0)) + 1
        periods = np.diff(rise) if len(rise) >= 2 else np.array([])
        return np.array(highs), periods, np.array(lows)

    # ---------------- 协议解码 ----------------
    def proto_status(self):
        """粘滞标志：seen / frame_err 一旦出现过就保持，直到软复位"""
        v = self.rd(self.PROTO_STAT)
        return {"seen": bool(v & 1), "frame_err": bool(v & 2), "ack": bool(v & 4)}

    def proto_byte(self):
        return self.rd(self.PROTO_BYTE) & 0xFF

    # ---------------- 时序统计 ----------------
    def stats_clear(self, timeout=1.0):
        """bit1 是保持型信号，必须置 1 -> 等 clr_busy 落下 -> 再置 0"""
        self.wr(self.STAT_CTRL, 0x2)
        t0 = time.time()
        while time.time() - t0 < timeout:
            if not (self.rd(self.STAT_STAT) & 0x1):
                break
            time.sleep(0.001)
        self.wr(self.STAT_CTRL, 0x0)

    def stats_enable(self, chan=0, on=True):
        """统计通道就是 TRIG_CHAN（RTL 里复用了这个寄存器）"""
        self.wr(self.TRIG_CHAN, chan)
        self.wr(self.STAT_CTRL, 0x1 if on else 0x0)

    def stats_scan(self, timeout=1.0):
        """启动硬件分位数扫描，返回耗时（秒）"""
        self.wr(self.STAT_CTRL, 0x1 | 0x4)
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.rd(self.STAT_STAT) & 0x4:
                return time.time() - t0
            time.sleep(0.0002)
        return None

    def stats_read(self):
        err = self.rd(self.STAT_ERR)
        sec = lambda *o: [self.rd(x) for x in o]
        return {
            "n_width": self.rd(self.STAT_NW),
            "n_period": self.rd(self.STAT_NP),
            "n_sat": err & 0xFFFF,
            "n_drop": err >> 16,
            "w_ps": sec(self.W_P50, self.W_P95, self.W_P99),
            "p_ps": sec(self.P_P50, self.P_P95, self.P_P99),
            "w_mm": sec(self.W_MIN, self.W_MAX),
            "p_mm": sec(self.P_MIN, self.P_MAX),
        }

    def histogram(self, kind="w"):
        """读回 256 桶直方图。kind='w' 宽度 / 'p' 周期。"""
        off = self.HIST_WCNT if kind == "w" else self.HIST_PCNT
        out = np.empty(256, dtype=np.int64)
        for i in range(256):
            self.wr(self.HIST_ADDR, i)
            out[i] = self.rd(off)
        return out

    # ---------------- 画图 ----------------
    def plot(self, samples, chans=(0, 1, 2, 3), div=None, meta=None, title=None,
             ax=None, show_trigger=True):
        """画数字波形（阶梯图）。

        时间轴单位按窗口长度自动选 s / ms / us —— 2 秒窗口还用 us 的话，
        刻度会变成 "0.5e6" 这种没法读的东西。
        meta 里带 pre_trig 时自动标出触发点。
        """
        import matplotlib.pyplot as plt

        div = div or (meta or {}).get("div") or self.rd(self.DIV)
        span = len(samples) * div / self.CLK_HZ          # 秒
        if span >= 2.0:
            unit, k = "s", 1.0
        elif span >= 0.002:
            unit, k = "ms", 1e3
        else:
            unit, k = "us", 1e6
        t = np.arange(len(samples)) * (div / self.CLK_HZ) * k

        if ax is None:
            _, ax = plt.subplots(figsize=(12, 0.9 * len(chans) + 1.2))

        off = len(chans)
        for i, c in enumerate(chans):
            b = self.channel(samples, c).astype(float)
            ax.step(t, b + (off - i - 1) * 1.2, where="post", linewidth=1.2,
                    label="CH%d" % c)
        ax.set_yticks([(off - i - 1) * 1.2 + 0.5 for i in range(len(chans))])
        ax.set_yticklabels(["CH%d" % c for c in chans])
        ax.set_ylim(-0.4, off * 1.2 - 0.2)
        ax.set_xlabel("time (%s)   [%.1f kHz @ DIV=%d]"
                      % (unit, self.CLK_HZ / div / 1e3, div))
        ax.grid(True, alpha=0.3, axis="x")

        if show_trigger and meta and "pre_trig" in meta:
            ax.axvline(meta["pre_trig"] * div / self.CLK_HZ * k,
                       color="r", ls="--", lw=1, label="trigger")
        if ax.get_legend_handles_labels()[0]:
            ax.legend(loc="upper right", fontsize=8)
        if title:
            ax.set_title(title)
        return ax


# =====================================================================
# 板内自检：python3 la_driver.py
# =====================================================================
if __name__ == "__main__":
    LINE = "=" * 62
    fail = 0

    def chk(name, cond, detail=""):
        global fail
        print("  [%s] %-40s %s" % ("PASS" if cond else "FAIL", name, detail))
        if not cond:
            fail += 1

    print(LINE)
    print("la_driver 自检（板内自测源，不需要外接信号）")
    print(LINE)

    la = LogicAnalyzer()
    print("  overlay :", la.ip, "@", hex(la.base))

    print()
    print("  1. 寄存器读写")
    la.wr(la.DIV, 12345)
    chk("DIV 写读一致", la.rd(la.DIV) == 12345, "= %d" % la.rd(la.DIV))

    print()
    print("  2. 采集链路（Pmod B 方波 -> 杜邦线 -> Pmod A）")
    samples, meta = la.capture(div=10000, pre_trig=256, trig_chan=3,
                               read_depth=1024)
    chk("抓到 FULL", True, "等待 %.0f ms" % (meta["t_wait"] * 1e3))
    chk("数据非全零", int(np.count_nonzero(samples)) > 0,
        "非零 %d / %d" % (int(np.count_nonzero(samples)), len(samples)))
    chk("采样率", abs(meta["sample_rate"] - 6250) < 1,
        "%.0f Hz @ DIV=%d" % (meta["sample_rate"], meta["div"]))

    ch3 = la.channel(samples, 3)
    chk("触发点 CH3 前 0 后 1",
        ch3[meta["pre_trig"] - 1] == 0 and ch3[meta["pre_trig"] + 1] == 1,
        "index %d" % meta["pre_trig"])

    ne = len(la.edges(samples, 7))
    chk("CH7 窗口内有跳变", ne >= 6, "%d 次" % ne)

    print()
    print("  3. 协议解码（Pmod B 针7/8 出 I2C SCL/SDA -> Pmod A CH4/CH5）")
    ps, pm = la.capture(div=20, pre_trig=2000, trig_chan=4,
                        trig_mode=la.TRIG_RISING, read_depth=4096,
                        proto_sel=la.PROTO_I2C, timeout=2.0)
    stat = la.proto_status()
    # PROTO_BYTE 是"最近解出的字节"，是瞬时值（源在 A0/55/AA 之间循环），
    # 单次读撞上哪一相说不准 —— 采一小段时间看集合，才是可靠的判据
    seen_bytes = set()
    for _ in range(60):
        seen_bytes.add(la.proto_byte())
        time.sleep(0.002)
    chk("协议源抓到 FULL", True, "等待 %.0f ms" % (pm["t_wait"] * 1e3))
    chk("I2C 解码器解出过字节", stat["seen"], "粘滞标志 decoded_seen")
    chk("解出的字节落在源发的集合内", bool(seen_bytes & {0xA0, 0x55, 0xAA}),
        "出现过 %s" % [hex(b) for b in sorted(seen_bytes)])
    edges = len(la.edges(ps, 4))
    chk("CH4(SCL) 波形上有边沿", edges >= 8, "%d 次" % edges)

    print()
    print("  3b. 协议内容触发（等总线上出现 0xAA 再抓）")
    _, tm = la.capture(div=20, pre_trig=1000, read_depth=2048,
                       trig_mode=la.TRIG_PROTO, trig_value=0xAA,
                       proto_sel=la.PROTO_I2C, timeout=3.0)
    chk("协议字节触发命中", True, "等待 %.0f ms" % (tm["t_wait"] * 1e3))

    print()
    print("  4. 时序统计")
    la.stats_clear()
    la.stats_enable(chan=7)
    time.sleep(0.5)
    st = la.stats_read()
    chk("样本数在涨", st["n_width"] > 0 and st["n_period"] > 0,
        "width=%d period=%d" % (st["n_width"], st["n_period"]))
    t_scan = la.stats_scan()
    chk("分位数扫描完成", t_scan is not None,
        ("%.1f us" % (t_scan * 1e6)) if t_scan else "超时")
    la.stats_enable(on=False)

    print()
    print(LINE)
    print("  %s" % ("全部 PASS" if fail == 0 else "%d 项 FAIL" % fail))
    print(LINE)
