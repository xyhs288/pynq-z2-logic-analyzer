# =====================================================================
#  plot_proto_uart.py —— UART 解码波形图
#
#  读 tb_proto_uart.csv（WAVE_MODE 下由 testbench 逐时钟导出），
#  画出像逻辑分析仪那样的波形：串行线上每一位是什么、解出来的字节是什么。
#
#  帧起点用【解码器内部状态 IDLE->START 的跳变】来定位，
#  不能用 tx 的下降沿 —— 数据位里的下降沿会把定位带偏。
#
#  输出 tb_proto_uart_fig.png
# =====================================================================

import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

t, sig, prev = [], {}, {}
with open("tb_proto_uart.csv", newline="") as f:
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

# 帧起点：状态机 IDLE(0) -> START(1)
starts = [t[i] for i in range(1, len(t))
          if sig["state"][i] == 1 and sig["state"][i - 1] == 0]

# 组成 (帧起点, 位宽, 解出字节)
frames = []
for t0 in starts:
    nxt = next((tt for tt, _ in decodes if tt > t0), None)
    if nxt is None:
        continue
    v = next((vv for tt, vv in decodes if tt >= nxt - 1), None)
    frames.append((t0, (nxt - t0) / 10.0, v))

show = frames[:2]                       # 只标前两帧，图面才清爽
t_end = min(t[-1], (show[-1][0] + show[-1][1] * 11) if show else t[-1])

fig, (ax1, ax2) = plt.subplots(
    2, 1, figsize=(15, 6), sharex=True,
    gridspec_kw={"height_ratios": [2.0, 1.0], "hspace": 0.22})

# ---------- 上：串行线电平 ----------
xs = [x for x in t if x <= t_end]
ys = [sig["tx"][i] for i in range(len(t)) if t[i] <= t_end]
ax1.step(xs, ys, where="post", linewidth=2.0, color="#1668dc")
ax1.fill_between(xs, 0, ys, step="post", color="#1668dc", alpha=0.10)

labels = ["起始"] + ["D%d" % i for i in range(8)] + ["停止"]
for t0, bw, v in show:
    for j, lab in enumerate(labels):
        xc = t0 + bw * (j + 0.5)
        ax1.axvline(t0 + bw * j, color="#e8e8e8", linewidth=0.8, zorder=0)
        ax1.text(xc, -0.30, lab, ha="center", va="top", fontsize=9, color="#5F5E5A")
    ax1.axvline(t0, color="#d4380d", linestyle="--", linewidth=1.3, alpha=0.85)
    ax1.axvline(t0 + bw * 10, color="#389e0d", linestyle="--", linewidth=1.3, alpha=0.85)
    if v is not None:
        ax1.text(t0 + bw * 10, 1.32, "= 0x%02X" % v, color="#389e0d",
                 fontsize=12, fontweight="bold", ha="center")

ax1.set_ylim(-0.80, 1.80)
ax1.set_yticks([0, 1])
ax1.set_yticklabels(["0", "1"])
ax1.set_ylabel("串行线电平")
for s in ("top", "right"):
    ax1.spines[s].set_visible(False)
ax1.spines["left"].set_color("#bfbfbf")
ax1.spines["bottom"].set_visible(False)
ax1.set_title("UART 帧结构：1 起始位 + 8 数据位（低位先发）+ 1 停止位 —— PL 里实时解码出字节",
              fontsize=13, pad=12)

# ---------- 下：解码事件 ----------
for tt, v in decodes:
    if tt > t_end:
        continue
    ax2.plot([tt], [1], marker="v", markersize=9, color="#389e0d")
    ax2.text(tt, 0.52, "0x%02X" % v, ha="center", va="top",
             fontsize=10, color="#389e0d")

ax2.set_ylim(0, 1.6)
ax2.set_yticks([])
ax2.set_xlabel("时间 (ns)")
ax2.set_xlim(t[0], t_end)
for s in ("top", "right", "left"):
    ax2.spines[s].set_visible(False)
ax2.spines["bottom"].set_color("#bfbfbf")
ax2.set_title("解码输出：每收完一帧，valid 给一个单拍脉冲并输出字节",
              fontsize=12.5, pad=10)

fig.suptitle("proto_uart 协议解码仿真   （真实仿真数据）", fontsize=14, y=0.98)

plt.savefig("tb_proto_uart_fig.png", dpi=125, bbox_inches="tight", facecolor="white")
print("saved: tb_proto_uart_fig.png")
print("frames:", [(int(a), round(b, 1), "0x%02X" % c if c is not None else "?")
                  for a, b, c in frames])
