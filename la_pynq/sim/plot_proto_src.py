# =====================================================================
#  plot_proto_src.py —— 两路协议并行解码
#
#  读 tb_proto_src.csv，上下两栏：
#    上：SPI  (CS / SCLK / MOSI  + 解出的字节)
#    下：I2C  (SCL / SDA         + 解出的字节 + 应答位)
#
#  两路解码器在同一时刻各自独立工作 —— 这就是"多路并行解码
#  不增加延迟"的直接证据：时间轴相同，两路同时出结果。
#
#  输出 tb_proto_src_fig.png
# =====================================================================

import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

AMP = 0.60

t, sig, prev, ok = [], {}, {}, {}
with open("tb_proto_src.csv", newline="") as f:
    for row in csv.DictReader(f):
        t.append(int(row["t_ns"]))
        for k, v in row.items():
            if k == "t_ns":
                continue
            unknown = v in ("x", "X", "z", "Z")
            v = prev.get(k, 0) if unknown else int(v)
            prev[k] = v
            sig.setdefault(k, []).append(v)
            # 记录该点是否为已确定值：x 被替换成 0 后不能当成真边沿
            ok.setdefault(k, []).append(not unknown)

# 起始处未初始化的采样点用第一个确定值回填，避免画出假的跳变
for k in sig:
    first = next((i for i, v in enumerate(ok[k]) if v), 0)
    for i in range(first):
        sig[k][i] = sig[k][first]

def decoded(valid_name, data_name):
    """valid 上升沿处取同一时刻的 data"""
    out = []
    for i in range(1, len(t)):
        if not (ok[valid_name][i] and ok[valid_name][i - 1] and ok[data_name][i]):
            continue
        if sig[valid_name][i] and not sig[valid_name][i - 1]:
            out.append((t[i], sig[data_name][i]))
    return out

spi_dec = decoded("spi_valid", "spi_data")
i2c_dec = decoded("i2c_valid", "i2c_data")

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(15, 8),
                               gridspec_kw={"height_ratios": [1.0, 1.0], "hspace": 0.45})

def track(ax, name, y, col, lw=1.8):
    ys = [sig[name][i] * AMP + y for i in range(len(t))]
    ax.step(t, ys, where="post", linewidth=lw, color=col)

# ---------------- 上：SPI ----------------
rows_spi = [("spi_cs_n", 2, "#8c8c8c"),
            ("spi_sclk", 1, "#1668dc"),
            ("spi_mosi", 0, "#d4380d")]
for name, y, col in rows_spi:
    track(ax1, name, y, col)

for tt, v in spi_dec:
    ax1.axvline(tt, color="#389e0d", linestyle="--", linewidth=1.0, alpha=0.7)

# CS 有效区底色
cs = sig["spi_cs_n"]
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

ax1.set_ylim(-1.35, 3.1)
ax1.set_yticks([0, 1, 2])
ax1.set_yticklabels(["MOSI", "SCLK", "CS"])
for lbl, col in zip(ax1.get_yticklabels(), ["#d4380d", "#1668dc", "#8c8c8c"]):
    lbl.set_color(col)
ax1.set_xlim(t[0], 44000)
for s in ("top", "right", "left"):
    ax1.spines[s].set_visible(False)
ax1.spines["bottom"].set_color("#bfbfbf")
ax1.set_title("SPI 通道：源发 一帧 3 字节（A5 5A FF），解码器逐个输出",
              fontsize=12.5, pad=10)

# 解码标注画在轴内下方
for tt, v in spi_dec:
    if tt > 44000:
        continue
    ax1.text(tt, -0.75, "0x%02X" % v, ha="center", va="top",
             fontsize=10.5, color="#389e0d", fontweight="bold")

# ---------------- 下：I2C ----------------
track(ax2, "i2c_scl", 1, "#1668dc")
track(ax2, "i2c_sda", 0, "#d4380d")

starts, stops = [], []
for i in range(1, len(t)):
    if not (ok["i2c_scl"][i] and ok["i2c_sda"][i] and ok["i2c_sda"][i - 1]):
        continue
    if sig["i2c_scl"][i] and sig["i2c_sda"][i - 1] == 1 and sig["i2c_sda"][i] == 0:
        starts.append(t[i])
    if sig["i2c_scl"][i] and sig["i2c_sda"][i - 1] == 0 and sig["i2c_sda"][i] == 1:
        stops.append(t[i])

for k, tt in enumerate(starts):
    ax2.axvline(tt, color="#389e0d", linestyle="--", linewidth=1.2, alpha=0.9)
    ax2.text(tt, 2.35, "START", color="#389e0d", fontsize=9.5,
             fontweight="bold", ha="center")
for k, tt in enumerate(stops):
    ax2.axvline(tt, color="#d4380d", linestyle="--", linewidth=1.2, alpha=0.9)
    ax2.text(tt, 2.35, "STOP", color="#d4380d", fontsize=9.5,
             fontweight="bold", ha="center")

for tt, v in i2c_dec:
    ax2.axvline(tt, color="#1668dc", linestyle="--", linewidth=1.0, alpha=0.5)

ax2.set_ylim(-1.35, 2.9)
ax2.set_yticks([0, 1])
ax2.set_yticklabels(["SDA", "SCL"])
for lbl, col in zip(ax2.get_yticklabels(), ["#d4380d", "#1668dc"]):
    lbl.set_color(col)
ax2.set_xlabel("时间 (ns)")
ax2.set_xlim(t[0], 48000)
for s in ("top", "right", "left"):
    ax2.spines[s].set_visible(False)
ax2.spines["bottom"].set_color("#bfbfbf")
ax2.set_title("I2C 通道：源发 START + A0 55 AA + STOP，解码器逐字节输出",
              fontsize=12.5, pad=10)

for tt, v in i2c_dec:
    if tt > 48000:
        continue
    ax2.text(tt, -0.75, "0x%02X" % v, ha="center", va="top",
             fontsize=10.5, color="#1668dc", fontweight="bold")

fig.suptitle("两路协议同时解码   （真实仿真数据）", fontsize=14, y=0.96)

plt.savefig("tb_proto_src_fig.png", dpi=125, bbox_inches="tight", facecolor="white")
print("saved: tb_proto_src_fig.png")
print("SPI :", ["0x%02X" % v for _, v in spi_dec])
print("I2C :", ["0x%02X" % v for _, v in i2c_dec])
