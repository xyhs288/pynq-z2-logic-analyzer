# =====================================================================
#  plot_wave.py —— 把仿真导出的 CSV 画成波形图（PNG）
#
#  用法: python plot_wave.py [csv] [png]
#  默认: tb_trig_fsm.csv  ->  tb_trig_fsm_wave.png
#
#  数据来自 testbench 在 WAVE_MODE 下 $fwrite 出来的逐时钟快照，
#  所以这是真实仿真结果，不是示意图。
#
#  三张子图：
#    1) 全程    —— 状态机流转 IDLE->ARMED->TRIG->FULL
#    2) 局部放大 —— 触发瞬间，看清 smp_en 脉冲
#    3) 计数器  —— post_cnt 每个采样节拍 +1，到 POST_LIMIT 停
# =====================================================================

import csv
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

C_TRACE = "#1668dc"
C_GRID  = "#d9d9d9"

src = sys.argv[1] if len(sys.argv) > 1 else "tb_trig_fsm.csv"
out = sys.argv[2] if len(sys.argv) > 2 else "tb_trig_fsm_wave.png"

t = []
sig = {}
prev = {}
with open(src, newline="") as f:
    for row in csv.DictReader(f):
        t.append(int(row["t_ns"]))
        for k, v in row.items():
            if k == "t_ns":
                continue
            # 复位前信号是 x，沿用上一拍的值（首拍按 0 处理）
            v = prev.get(k, 0) if v in ("x", "X", "z", "Z") else int(v)
            prev[k] = v
            sig.setdefault(k, []).append(v)

t_trig = next((t[i] for i in range(1, len(t)) if sig["trig_pulse"][i]), t[0])
t_full = next((t[i] for i in range(1, len(t)) if sig["full"][i]), t[-1])
post_ticks = sum(1 for i in range(len(t))
                 if t_trig < t[i] <= t_full and sig["smp_en"][i])

fig, (ax1, ax2, ax3) = plt.subplots(
    3, 1, figsize=(15, 12), gridspec_kw={"height_ratios": [1.9, 1.3, 1.1], "hspace": 0.34})


def stack(ax, traces, t0, t1):
    """在 ax 上画堆叠的 0/1 波形。traces = [(key, label, vmax), ...]"""
    ROW_H = 0.72
    for i, (key, label, vmax) in enumerate(traces):
        base = -i
        xs = [x for x in t if t0 <= x <= t1]
        ys = [base + (sig[key][j] / vmax) * ROW_H
              for j, x in enumerate(t) if t0 <= x <= t1]
        ax.step(xs, ys, where="post", linewidth=1.6, color=C_TRACE)
        ax.axhline(base, color=C_GRID, linewidth=0.8, zorder=0)
        ax.text(-0.012, base + ROW_H / 2, label, transform=ax.get_yaxis_transform(),
                ha="right", va="center", fontsize=10)
    ax.set_xlim(t0, t1)
    ax.set_ylim(-len(traces) + 0.05, 0.95)
    ax.set_yticks([])
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color("#bfbfbf")


# ---------- 图 1：全程 ----------
stack(ax1, [
    ("din0",       "CH0 输入  din[0]",      1),
    ("state",      "状态 state  0=IDLE 1=ARMED 2=TRIG 3=FULL", 3),
    ("cap_en",     "写使能  cap_en",        1),
    ("trig_pulse", "触发脉冲  trig_pulse",  1),
    ("full",       "抓取完成  full",        1),
], t[0], t[-1])

ax1.axvline(t_trig, color="#d4380d", linestyle="--", linewidth=1.2, alpha=0.85)
ax1.axvline(t_full, color="#389e0d", linestyle="--", linewidth=1.2, alpha=0.85)
ax1.text(t_trig, 0.62, " 触发", color="#d4380d", fontsize=10, va="bottom")
ax1.text(t_full, 0.62, " FULL", color="#389e0d", fontsize=10, va="bottom")
ax1.set_title("一、全程：触发不是「开始记录」，而是「让循环记录停下来」——cap_en 在 FULL 时刻落下",
              fontsize=12.5, pad=10)

# 标注 IDLE -> ARMED 的跳变
t_arm = next((t[i] for i in range(1, len(t)) if sig["armed"][i]), None)
if t_arm:
    ax1.text(t_arm, 0.62, "arm 布防 ", color="#595959", fontsize=9,
             va="bottom", ha="right")

# ---------- 图 2：触发瞬间局部放大 ----------
w0, w1 = t_trig - 120, t_trig + 320
stack(ax2, [
    ("din0",   "CH0 输入  din[0]", 1),
    ("smp_en", "采样节拍  smp_en", 1),
    ("state",  "状态  state",      3),
], w0, w1)
ax2.axvline(t_trig, color="#d4380d", linestyle="--", linewidth=1.2, alpha=0.85)
ax2.set_xlabel("时间 (ns)")
ax2.set_title("二、局部放大：每个 smp_en 脉冲 = 一个采样点（脉冲宽 1 个时钟 → 全程图上糊成一片，故单独放大）",
              fontsize=12.5, pad=10)

# ---------- 图 3：post_cnt 台阶 ----------
xs = [x for x in t if w0 <= x <= w1]
ys = [sig["post_cnt"][j] for j, x in enumerate(t) if w0 <= x <= w1]
ax3.step(xs, ys, where="post", linewidth=2.0, color="#722ed1")
ax3.fill_between(xs, 0, ys, step="post", color="#722ed1", alpha=0.12)
ax3.axvline(t_trig, color="#d4380d", linestyle="--", linewidth=1.2, alpha=0.85)
ax3.set_xlim(w0, w1)
ax3.set_xlabel("时间 (ns)")
ax3.set_ylabel("post_cnt")
ax3.grid(True, axis="y", color=C_GRID, linewidth=0.8)
ax3.set_axisbelow(True)
for s in ("top", "right"):
    ax3.spines[s].set_visible(False)
ax3.spines["bottom"].set_color("#bfbfbf")
ax3.spines["left"].set_color("#bfbfbf")
ax3.set_title("三、预触发计数：触发后每个采样节拍 +1，数满 %d 拍就把写使能拉低" % post_ticks,
              fontsize=12.5, pad=10)

fig.suptitle("trig_fsm 仿真波形   （真实仿真数据，WAVE_MODE 缩小参数便于观察）",
             fontsize=14, y=0.985)

plt.savefig(out, dpi=125, bbox_inches="tight", facecolor="white")
# Keep console output ASCII: the bat / cmd console is GBK and would garble Chinese.
print("saved:", out)
print("samples    =", len(t))
print("t_trigger  =", t_trig, "ns")
print("t_full     =", t_full, "ns")
print("post_ticks =", post_ticks)
