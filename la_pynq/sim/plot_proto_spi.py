# =====================================================================
#  plot_proto_spi.py —— SPI 解码波形图
#
#  读 tb_proto_spi.csv，画成逻辑分析仪式波形：
#    上：CS / SCLK / MOSI 三条轨道
#    下：每收满 8 位输出的字节
#
#  字节边界用 valid 脉冲定位（不能用 SCLK 边沿 —— 那样会多切一刀）。
#
#  输出 tb_proto_spi_fig.png
# =====================================================================

import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

t, sig, prev = [], {}, {}
with open("tb_proto_spi.csv", newline="") as f:
    for row in csv.DictReader(f):
        t.append(int(row["t_ns"]))
        for k, v in row.items():
            if k == "t_ns":
                continue
            v = prev.get(k, 0) if v in ("x", "X", "z", "Z") else int(v)
            prev[k] = v
            sig.setdefault(k, []).append(v)

# 解码完成时刻（valid 上升沿）
decodes = [(t[i], sig["data"][i]) for i in range(1, len(t))
           if sig["valid"][i] and not sig["valid"][i - 1]]

fig = plt.figure(figsize=(15, 7))
gs = fig.add_gridspec(2, 1, height_ratios=[2.4, 1.0], hspace=0.28)
ax1 = fig.add_subplot(gs[0])
ax2 = fig.add_subplot(gs[1], sharex=ax1)

t_end = t[-1]

# ---------- 上：三条轨道（控制线在上）----------
rows = [("cs_n", "CS",  2, "#8c8c8c"),
        ("sclk", "SCLK", 1, "#1668dc"),
        ("mosi", "MOSI", 0, "#d4380d")]

AMP = 0.62
for name, lab, y, col in rows:
    ys = [sig[name][i] * AMP + y for i in range(len(t))]
    ax1.step(t, ys, where="post", linewidth=1.8, color=col)

# 字节边界
for tt, v in decodes:
    ax1.axvline(tt, color="#389e0d", linestyle="--", linewidth=1.2, alpha=0.8)

# 片选区间底色
cs = sig["cs_n"]
i = 0
while i < len(t):
    if cs[i] == 0:
        j = i
        while j < len(t) and cs[j] == 0:
            j += 1
        ax1.axvspan(t[i], t[min(j, len(t) - 1)], color="#1668dc", alpha=0.05)
        i = j
    else:
        i += 1

ax1.set_ylim(-0.5, 3.2)
ax1.set_yticks([0, 1, 2])
ax1.set_yticklabels(["MOSI", "SCLK", "CS"])
for lbl, col in zip(ax1.get_yticklabels(),
                    ["#d4380d", "#1668dc", "#8c8c8c"]):
    lbl.set_color(col)
for s in ("top", "right", "left"):
    ax1.spines[s].set_visible(False)
ax1.spines["bottom"].set_color("#bfbfbf")
ax1.set_title("SPI mode 0（SCLK 空闲低、上升沿采样）：CS 拉低界定一次传输，MSB 先到",
              fontsize=13, pad=12)

# ---------- 下：解码事件 ----------
for tt, v in decodes:
    ax2.plot([tt], [1], marker="v", markersize=9, color="#389e0d")
    ax2.text(tt, 0.52, "0x%02X" % v, ha="center", va="top",
             fontsize=11, color="#389e0d", fontweight="bold")

ax2.set_ylim(0, 1.6)
ax2.set_yticks([])
ax2.set_xlabel("时间 (ns)")
ax2.set_xlim(t[0], t_end)
for s in ("top", "right", "left"):
    ax2.spines[s].set_visible(False)
ax2.spines["bottom"].set_color("#bfbfbf")
ax2.set_title("解码输出：满 8 位给一个 valid 脉冲，同时输出字节",
              fontsize=12.5, pad=10)

fig.suptitle("proto_spi 协议解码仿真   （真实仿真数据）", fontsize=14, y=0.97)

plt.savefig("tb_proto_spi_fig.png", dpi=125, bbox_inches="tight", facecolor="white")
print("saved: tb_proto_spi_fig.png")
print("decoded:", ["0x%02X" % v for _, v in decodes])
