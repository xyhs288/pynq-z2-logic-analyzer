# =====================================================================
#  plot_proto_i2c.py —— I2C 解码波形图
#
#  读 tb_proto_i2c.csv，画成逻辑分析仪式波形：
#    上：SCL / SDA 两条轨道，标出 START 与 STOP 条件
#    下：每个字节 + 应答位
#
#  START / STOP 用 scl 高电平期间的 sda 跳变定位。
#
#  输出 tb_proto_i2c_fig.png
# =====================================================================

import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

t, sig, prev = [], {}, {}
with open("tb_proto_i2c.csv", newline="") as f:
    for row in csv.DictReader(f):
        t.append(int(row["t_ns"]))
        for k, v in row.items():
            if k == "t_ns":
                continue
            v = prev.get(k, 0) if v in ("x", "X", "z", "Z") else int(v)
            prev[k] = v
            sig.setdefault(k, []).append(v)

decodes = [(t[i], sig["data"][i], sig["ack"][i], sig["first"][i], sig["rw"][i])
           for i in range(1, len(t))
           if sig["valid"][i] and not sig["valid"][i - 1]]

# START / STOP：SCL 高时 SDA 的跳变
starts, stops = [], []
for i in range(1, len(t)):
    if sig["scl"][i] and sig["sda"][i - 1] == 1 and sig["sda"][i] == 0:
        starts.append(t[i])
    if sig["scl"][i] and sig["sda"][i - 1] == 0 and sig["sda"][i] == 1:
        stops.append(t[i])

fig = plt.figure(figsize=(15, 7))
gs = fig.add_gridspec(2, 1, height_ratios=[2.2, 1.0], hspace=0.30)
ax1 = fig.add_subplot(gs[0])
ax2 = fig.add_subplot(gs[1], sharex=ax1)

rows = [("scl", "SCL", 1, "#1668dc"),
        ("sda", "SDA", 0, "#d4380d")]

AMP = 0.62
for name, lab, y, col in rows:
    ys = [sig[name][i] * AMP + y for i in range(len(t))]
    ax1.step(t, ys, where="post", linewidth=1.8, color=col)

# START / STOP 标注错开高度，避免相互压字
for k, tt in enumerate(starts):
    ax1.axvline(tt, color="#389e0d", linestyle="--", linewidth=1.4, alpha=0.9)
    ax1.text(tt, 2.30 - 0.38 * (k % 2), "START", color="#389e0d", fontsize=10,
             fontweight="bold", ha="center")
for k, tt in enumerate(stops):
    ax1.axvline(tt, color="#d4380d", linestyle="--", linewidth=1.4, alpha=0.9)
    ax1.text(tt, 2.30 - 0.38 * (k % 2), "STOP", color="#d4380d", fontsize=10,
             fontweight="bold", ha="center")

ax1.set_ylim(-0.5, 2.9)
ax1.set_yticks([0, 1])
ax1.set_yticklabels(["SDA", "SCL"])
for lbl, col in zip(ax1.get_yticklabels(), ["#d4380d", "#1668dc"]):
    lbl.set_color(col)
for s in ("top", "right", "left"):
    ax1.spines[s].set_visible(False)
ax1.spines["bottom"].set_color("#bfbfbf")
ax1.set_title("I2C：START / STOP 不是电平，是 SCL 高电平期间 SDA 的跳变",
              fontsize=13, pad=12)

for tt, v, a, f, r in decodes:
    ax2.plot([tt], [1], marker="v", markersize=9,
             color="#1668dc" if f else "#389e0d")
    lab = "0x%02X" % v
    if f:
        lab += "  (addr R/W=%d)" % r
    ax2.text(tt, 0.52, lab, ha="center", va="top", fontsize=10,
             color="#1668dc" if f else "#389e0d")
    ax2.text(tt, 0.12, "ACK" if a == 0 else "NACK", ha="center", va="top",
             fontsize=9, color="#8c8c8c")

ax2.set_ylim(0, 1.6)
ax2.set_yticks([])
ax2.set_xlabel("时间 (ns)")
ax2.set_xlim(t[0], t[-1])
for s in ("top", "right", "left"):
    ax2.spines[s].set_visible(False)
ax2.spines["bottom"].set_color("#bfbfbf")
ax2.set_title("解码输出：每 9 个 SCL 上升沿一组（8 数据位 + 1 应答位）",
              fontsize=12.5, pad=10)

fig.suptitle("proto_i2c 协议解码仿真   （真实仿真数据）", fontsize=14, y=0.97)

plt.savefig("tb_proto_i2c_fig.png", dpi=125, bbox_inches="tight", facecolor="white")
print("saved: tb_proto_i2c_fig.png")
print("decoded:", ["0x%02X%s" % (v, "(addr)" if f else "") for _, v, a, f, r in decodes])
