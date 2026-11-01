# =====================================================================
#  plot_cap_mem.py —— 把 cap_mem 仿真结果画成图
#
#  用法: python plot_cap_mem.py
#
#  读三个文件（都由 testbench 在 WAVE_MODE 下导出）：
#    tb_cap_mem.csv        逐时钟时序
#    tb_cap_mem_final.csv  缓冲终态（地址 -> 值）
#    tb_cap_mem_ptr.csv    stop_ptr / wr_ptr / DEPTH / NWRITE
#
#  两张图：
#    上：写入时序 + 读出阶段
#    下：环形缓冲终态映射（这是理解"最老数据在哪"的关键）
#
#  输出 tb_cap_mem_fig.png
# =====================================================================

import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.cm as cm

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

C_TIDY = "#bfbfbf"


def load_trace(path):
    t, sig, prev = [], {}, {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            t.append(int(row["t_ns"]))
            for k, v in row.items():
                if k == "t_ns":
                    continue
                v = prev.get(k, 0) if v in ("x", "X", "z", "Z") else int(v)
                prev[k] = v
                sig.setdefault(k, []).append(v)
    return t, sig


t, sig = load_trace("tb_cap_mem.csv")

mem = []
with open("tb_cap_mem_final.csv", newline="") as f:
    for row in csv.DictReader(f):
        mem.append(int(row["value"]))

ptr = {}
with open("tb_cap_mem_ptr.csv", newline="") as f:
    for row in csv.DictReader(f):
        ptr[row["key"]] = int(row["value"])

stop = ptr["stop_ptr"]
depth = ptr["depth"]
nwrite = ptr["nwrite"]

# 读出阶段起始：第一次 rd_en 拉高
t_rd = next((t[i] for i in range(1, len(t)) if sig["rd_en"][i]), t[-1])

fig = plt.figure(figsize=(14, 12))
gs = fig.add_gridspec(3, 1, height_ratios=[0.85, 1.0, 1.35], hspace=0.36)
ax1, ax2, ax3 = (fig.add_subplot(gs[i]) for i in range(3))

# ---------- 图 1：控制信号 ----------
for i, (key, label) in enumerate([("smp_en", "采样节拍  smp_en"), ("cap_en", "写使能  cap_en")]):
    base = -i
    ax1.step(t, [base + v * 0.7 for v in sig[key]], where="post",
             linewidth=1.6, color="#1668dc" if i == 0 else "#d4380d")
    ax1.axhline(base, color=C_TIDY, linewidth=0.8, zorder=0)
    ax1.text(-0.012, base + 0.35, label, transform=ax1.get_yaxis_transform(),
             ha="right", va="center", fontsize=10)

ax1.axvline(t_rd, color="#389e0d", linestyle="--", linewidth=1.2, alpha=0.85)
ax1.text(t_rd, 0.55, "  停止写入 / 开始读出", color="#389e0d", fontsize=10, va="bottom")
ax1.set_xlim(t[0], t[-1])
ax1.set_ylim(-1.05, 0.95)
ax1.set_yticks([])
for s in ("top", "right", "left"):
    ax1.spines[s].set_visible(False)
ax1.spines["bottom"].set_color(C_TIDY)
ax1.set_title("一、控制信号：cap_en 落下 = 停止写入（触发条件已满足，写够了 DEPTH-PRE_TRIG 拍）",
              fontsize=12.5, pad=10)

# ---------- 图 2：数据与指针 ----------
ax2.step(t, sig["din"], where="post", linewidth=1.6, color="#722ed1", label="写入数据 din")
ax2.step(t, sig["wr"], where="post", linewidth=1.8, color="#1668dc", label="写指针 wr_ptr")
ax2.step(t, sig["stop"], where="post", linewidth=1.4, color="#d4380d",
         linestyle="--", label="stop_ptr（停止时锁存）")
ax2.axvline(t_rd, color="#389e0d", linestyle="--", linewidth=1.2, alpha=0.6)
ax2.axhline(depth - 1, color=C_TIDY, linewidth=0.8, linestyle=":")
ax2.text(t[-1], depth - 1, "  DEPTH-1", fontsize=9, color="#8c8c8c", va="center")
ax2.set_xlim(t[0], t[-1])
ax2.set_ylabel("数值")
ax2.grid(True, axis="y", color="#f0f0f0", linewidth=0.8)
ax2.set_axisbelow(True)
for s in ("top", "right"):
    ax2.spines[s].set_visible(False)
ax2.legend(loc="upper left", fontsize=10, frameon=False)
ax2.set_title("二、数据与指针：wr_ptr 数到 %d 后回绕到 0 —— 环形写入，永不停止" % depth,
              fontsize=12.5, pad=10)

# ---------- 图 3：环形缓冲终态 ----------
addrs = list(range(depth))
# 时间顺序索引：从 stop_ptr 开始算最老
order = [(a - stop) % depth for a in addrs]
norm = [o / max(depth - 1, 1) for o in order]
colors = [cm.viridis(0.15 + 0.7 * n) for n in norm]

bars = ax3.bar(addrs, mem, color=colors, edgecolor="white", linewidth=1.2, zorder=3)

ax3.axvline(stop - 0.5, color="#d4380d", linestyle="--", linewidth=2.0, zorder=4)
ax3.text(stop - 0.5, max(mem) * 1.06, " stop_ptr = %d\n 最老数据在这里" % stop,
         color="#d4380d", fontsize=10, va="bottom", ha="left")

for a, v in zip(addrs, mem):
    ax3.text(a, v + 0.5, str(v), ha="center", va="bottom", fontsize=9, color="#404040")

ax3.set_xticks(addrs)
ax3.set_xlabel("BRAM 物理地址")
ax3.set_ylabel("存储的采样值")
ax3.set_ylim(0, max(mem) * 1.28)
ax3.grid(True, axis="y", color="#f0f0f0", linewidth=0.8)
ax3.set_axisbelow(True)
for s in ("top", "right"):
    ax3.spines[s].set_visible(False)

sm = cm.ScalarMappable(cmap="viridis")
sm.set_array([0, 1])
cb = fig.colorbar(sm, ax=ax3, pad=0.015, fraction=0.03)
cb.set_ticks([0, 1])
cb.set_ticklabels(["最老", "最新"])
cb.ax.tick_params(labelsize=10)
cb.outline.set_visible(False)

ax3.set_title("三、环形缓冲终态：写入 %d 个点进 %d 个格子 → 绕了一圈，覆盖了前 %d 个\n"
              "读出时从 stop_ptr 顺序读 %d 个，得到的时间顺序正好是 %d, %d, ..., %d"
              % (nwrite, depth, nwrite - depth, depth, nwrite - depth, nwrite - depth + 1, nwrite - 1),
              fontsize=12.5, pad=12)

fig.suptitle("cap_mem 片内 BRAM 环形缓冲 —— 真实仿真数据（DEPTH=%d，写入 %d 个点）"
             % (depth, nwrite), fontsize=14, y=0.975)

plt.savefig("tb_cap_mem_fig.png", dpi=125, bbox_inches="tight", facecolor="white")
print("saved: tb_cap_mem_fig.png")
print("depth      =", depth)
print("nwrite     =", nwrite)
print("stop_ptr   =", stop)
print("buffer     =", mem)
