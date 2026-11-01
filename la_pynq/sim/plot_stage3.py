# =====================================================================
#  plot_stage3.py —— 完整链路仿真图
#
#  读 tb_stage3.csv（WAVE_MODE 下由 testbench 逐时钟导出），画三张子图：
#    1. 状态流转  armed -> trigged -> full
#    2. 写指针    wr_ptr 递增、停止时锁存到 stop_ptr
#    3. 重放进度  r_cnt 在 FULL 之后开始走
#
#  输出 tb_stage3_fig.png
# =====================================================================

import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

C_TIDY = "#bfbfbf"

t, sig, prev = [], {}, {}
with open("tb_stage3.csv", newline="") as f:
    for row in csv.DictReader(f):
        t.append(int(row["t_ns"]))
        for k, v in row.items():
            if k == "t_ns":
                continue
            v = prev.get(k, 0) if v in ("x", "X", "z", "Z") else int(v)
            prev[k] = v
            sig.setdefault(k, []).append(v)

t_trig = next((t[i] for i in range(1, len(t)) if sig["trigged"][i]), None)
t_full = next((t[i] for i in range(1, len(t)) if sig["full"][i]), None)
t_arm = next((t[i] for i in range(1, len(t)) if sig["armed"][i]), t[0])

# 只画有内容的那一段（前面是上电复位，状态全 0）
t0 = max(t[0], t_arm - 500)
t1 = t[-1]

fig, (ax1, ax2, ax3) = plt.subplots(
    3, 1, figsize=(14, 10), sharex=True,
    gridspec_kw={"height_ratios": [1.5, 1.2, 1.0], "hspace": 0.28})

# ---------- 图 1：状态 ----------
traces = [
    ("armed",   "armed   已布防"),
    ("trigged", "trigged 已触发"),
    ("full",    "full    抓取完成"),
    ("cap_en",  "cap_en  写使能"),
]
ROW_H = 0.72
for i, (key, label) in enumerate(traces):
    base = -i
    ax1.step(t, [base + v * ROW_H for v in sig[key]], where="post",
             linewidth=1.7, color="#1668dc")
    ax1.axhline(base, color=C_TIDY, linewidth=0.8, zorder=0)
    ax1.text(-0.012, base + ROW_H / 2, label, transform=ax1.get_yaxis_transform(),
             ha="right", va="center", fontsize=10)

if t_trig:
    ax1.axvline(t_trig, color="#d4380d", linestyle="--", linewidth=1.3, alpha=0.85)
    ax1.text(t_trig, 0.55, " 触发", color="#d4380d", fontsize=10, va="bottom")
if t_full:
    ax1.axvline(t_full, color="#389e0d", linestyle="--", linewidth=1.3, alpha=0.85)
    ax1.text(t_full, 0.55, " FULL", color="#389e0d", fontsize=10, va="bottom")

ax1.set_ylim(-len(traces) + 0.05, 0.95)
ax1.set_yticks([])
for s in ("top", "right", "left"):
    ax1.spines[s].set_visible(False)
ax1.spines["bottom"].set_color(C_TIDY)
ax1.set_title("一、状态流转：ARMED -> 触发 -> TRIG -> FULL，cap_en 在 FULL 时刻落下",
              fontsize=12.5, pad=10)

# ---------- 图 2：指针 ----------
ax2.step(t, sig["wr"], where="post", linewidth=1.8, color="#1668dc", label="wr_ptr 写指针")
ax2.step(t, sig["stop"], where="post", linewidth=1.6, color="#d4380d",
         linestyle="--", label="stop_ptr 冻结位置（最老数据）")
if t_full:
    ax2.axvline(t_full, color="#389e0d", linestyle="--", linewidth=1.2, alpha=0.6)
ax2.set_ylabel("指针")
ax2.grid(True, axis="y", color="#f0f0f0", linewidth=0.8)
ax2.set_axisbelow(True)
for s in ("top", "right"):
    ax2.spines[s].set_visible(False)
ax2.legend(loc="upper left", fontsize=10, frameon=False)
ax2.set_title("二、写指针：FULL 之后完全冻结 —— 采集真的停了", fontsize=12.5, pad=10)

# ---------- 图 3：重放 ----------
ax3.step(t, sig["r_cnt"], where="post", linewidth=1.8, color="#722ed1")
ax3.fill_between(t, 0, sig["r_cnt"], step="post", color="#722ed1", alpha=0.12)
if t_full:
    ax3.axvline(t_full, color="#389e0d", linestyle="--", linewidth=1.2, alpha=0.6)
    ax3.text(t_full, 0.5, "  FULL 后开始重放", color="#389e0d", fontsize=10, va="bottom")
ax3.set_ylabel("r_cnt")
ax3.set_xlabel("时间 (ns)")
ax3.grid(True, axis="y", color="#f0f0f0", linewidth=0.8)
ax3.set_axisbelow(True)
for s in ("top", "right"):
    ax3.spines[s].set_visible(False)
ax3.set_title("三、重放：FULL 之后从触发点前 64 个点开始顺序读出", fontsize=12.5, pad=10)

ax1.set_xlim(t0, t1)

fig.suptitle("stage3_top 完整采集链路仿真   test_gen -> din_sync -> trig_fsm -> cap_mem",
             fontsize=14, y=0.97)

plt.savefig("tb_stage3_fig.png", dpi=125, bbox_inches="tight", facecolor="white")
# 控制台输出保持 ASCII
print("saved: tb_stage3_fig.png")
print("t_armed =", t_arm, "ns")
print("t_trig  =", t_trig, "ns")
print("t_full  =", t_full, "ns")
print("wr at full =", sig["wr"][-1], " stop_ptr =", sig["stop"][-1])
