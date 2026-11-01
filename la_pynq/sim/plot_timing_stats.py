# =====================================================================
#  plot_timing_stats.py —— 时序参数直方图
#
#  读 tb_timing_stats_hist.csv，画两张直方图：
#    左/上：高电平宽度分布
#    右/下：周期分布
#  并在图上标出硬件扫描算出的 P50 / P95 / P99。
#
#  横轴换算：每桶 = 2^SHIFT 个 clk，SHIFT=2，clk = 8ns -> 每桶 32ns
#
#  输出 tb_timing_stats_fig.png
# =====================================================================

import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

CLK_NS = 8.0        # 125 MHz
SHIFT = 2
BIN_NS = (1 << SHIFT) * CLK_NS      # 每桶 32 ns

bins, wc, pc = [], [], []
with open("tb_timing_stats_hist.csv", newline="") as f:
    for row in csv.DictReader(f):
        bins.append(int(row["bin"]))
        wc.append(int(row["width_cnt"]))
        pc.append(int(row["period_cnt"]))

# 只画到最后一个非零桶之后一点
last = max([b for b, c in zip(bins, wc) if c > 0] +
           [b for b, c in zip(bins, pc) if c > 0])
keep = [i for i in range(len(bins)) if bins[i] <= last + 2]

bx = [bins[i] * BIN_NS for i in keep]
wv = [wc[i] for i in keep]
pv = [pc[i] for i in keep]

# 硬件算出的分位数（单位 clk），换算成 ns
W_P50, W_P95, W_P99 = 6, 18, 66
P_P50, P_P95, P_P99 = 106, 118, 166


def mark(ax, vals, ymax):
    for k, (v, c, lab) in enumerate(vals):
        x = v * CLK_NS
        ax.axvline(x, color=c, linestyle="--", linewidth=1.4, alpha=0.9)
        ax.text(x, ymax * (1.20 - 0.14 * (k % 2)), lab, color=c, fontsize=10,
                fontweight="bold", ha="center", va="center")


fig, (ax1, ax2) = plt.subplots(
    2, 1, figsize=(13, 9),
    gridspec_kw={"hspace": 0.52, "top": 0.895, "bottom": 0.155,
                 "left": 0.075, "right": 0.97})

TOP1 = max(wv) if max(wv) else 1
TOP2 = max(pv) if max(pv) else 1

# ---------------- 上：宽度直方图 ----------------
ax1.bar(bx, wv, width=BIN_NS * 0.72, color="#378ADD", edgecolor="#185FA5",
        linewidth=0.6)
mark(ax1, [(W_P50, "#A32D2D", "P50"), (W_P95, "#BA7517", "P95"),
           (W_P99, "#3B6D11", "P99")], TOP1)
ax1.set_ylabel("样本数")
ax1.set_xlabel("高电平宽度 (ns)")
ax1.set_title("高电平宽度分布 —— 硬件在采集通路上直接累加，不需要 CPU 参与",
              fontsize=12.5, pad=10)
ax1.set_ylim(0, TOP1 * 1.40)
ax1.set_xlim(0, W_P99 * CLK_NS * 1.22)

# ---------------- 下：周期直方图 ----------------
ax2.bar(bx, pv, width=BIN_NS * 0.72, color="#5DCAA5", edgecolor="#0F6E56",
        linewidth=0.6)
mark(ax2, [(P_P50, "#A32D2D", "P50"), (P_P95, "#BA7517", "P95"),
           (P_P99, "#3B6D11", "P99")], TOP2)
ax2.set_ylabel("样本数")
ax2.set_xlabel("周期 (ns)")
ax2.set_title("周期分布（相邻两个上升沿之间的时间）", fontsize=12.5, pad=10)
ax2.set_ylim(0, TOP2 * 1.40)
ax2.set_xlim(P_P50 * CLK_NS * 0.72, P_P99 * CLK_NS * 1.15)

for ax in (ax1, ax2):
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.spines["left"].set_color("#bfbfbf")
    ax.spines["bottom"].set_color("#bfbfbf")
    ax.grid(axis="y", color="#e8e8e8", linewidth=0.7)
    ax.set_axisbelow(True)

summary = (
    "宽度样本 64 个　P50 = 6 clk　P95 = 18 clk　P99 = 66 clk\n"
    "周期样本 63 个　P50 = 106 clk　P95 = 118 clk　P99 = 166 clk\n"
    "分位数扫描耗时 514 个时钟（约 4.1 µs）"
)
fig.text(0.5, 0.035, summary, ha="center", va="bottom", fontsize=10.5,
         color="#444441", linespacing=1.7)

fig.suptitle("时序参数统计：不问「什么时候是高」，而回答「有多宽、分布如何」   （真实仿真数据）",
             fontsize=14, y=0.955)

plt.savefig("tb_timing_stats_fig.png", dpi=125, bbox_inches="tight",
            facecolor="white")
print("saved: tb_timing_stats_fig.png")
print("width bins :", [(bins[i], wc[i]) for i in keep if wc[i] > 0])
print("period bins:", [(bins[i], pc[i]) for i in keep if pc[i] > 0])
