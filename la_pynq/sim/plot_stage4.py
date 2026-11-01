# =====================================================================
#  plot_stage4.py —— 协议内容触发
#
#  三栏：
#    1. 状态时序：ARMED -> TRIG -> FULL，标出触发发生的时刻
#    2. 触发瞬间的总线特写：解码器逐字节输出，第 3 个字节正是目标 0xAA
#    3. 片内缓冲内容（时间顺序）：触发点之前/之后的总线波形都留住了
#
#  输入：tb_stage4.csv（逐时钟）、tb_stage4_buf.csv（缓冲快照）
#  输出：tb_stage4_fig.png
# =====================================================================

import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

AMP = 0.62
PRE_TRIG = 256          # 与 testbench 里的参数一致

# ---------------- 读逐时钟 CSV ----------------
t, sig, prev, ok = [], {}, {}, {}
with open("tb_stage4.csv", newline="") as f:
    for row in csv.DictReader(f):
        t.append(int(row["t_ns"]))
        for k, v in row.items():
            if k == "t_ns":
                continue
            unknown = v in ("x", "X", "z", "Z")
            v = prev.get(k, 0) if unknown else int(v)
            prev[k] = v
            sig.setdefault(k, []).append(v)
            ok.setdefault(k, []).append(not unknown)

for k in sig:
    first = next((i for i, v in enumerate(ok[k]) if v), 0)
    for i in range(first):
        sig[k][i] = sig[k][first]

# 触发时刻
trig_i = next((i for i, v in enumerate(sig["trig"]) if v), None)
if trig_i is None:
    raise SystemExit("no trigger found in tb_stage4.csv")
t_trig = t[trig_i]

# 解码完成时刻
decodes = []
for i in range(1, len(t)):
    if ok["dec_valid"][i] and ok["dec_valid"][i - 1] and \
       sig["dec_valid"][i] and not sig["dec_valid"][i - 1]:
        decodes.append((t[i], sig["dec_data"][i]))

fig = plt.figure(figsize=(15, 10))
gs = fig.add_gridspec(3, 1, height_ratios=[0.85, 1.35, 1.35], hspace=0.62,
                      top=0.875, bottom=0.075, left=0.065, right=0.975)

# ============ 1. 状态时序 ============
ax1 = fig.add_subplot(gs[0])
rows1 = [("armed",   "ARMED",  1, "#1668dc"),
         ("trigged", "TRIG",   0, "#faad14")]
for name, lab, y, col in rows1:
    ys = [sig[name][i] * AMP + y for i in range(len(t))]
    ax1.step(t, ys, where="post", linewidth=2.0, color=col)

ax1.axvline(t_trig, color="#d4380d", linestyle="--", linewidth=1.6)
ax1.text(t_trig, 1.95, "触发  0xAA", color="#d4380d", fontsize=10.5,
         fontweight="bold", ha="center", clip_on=True)

for tt, v in decodes:
    ax1.axvline(tt, color="#389e0d", linestyle=":", linewidth=0.9, alpha=0.55)

ax1.set_ylim(-0.4, 2.3)
ax1.set_yticks([0, 1])
ax1.set_yticklabels(["TRIG", "ARMED"])
for lbl, col in zip(ax1.get_yticklabels(), ["#faad14", "#1668dc"]):
    lbl.set_color(col)
ax1.set_xlim(t[0], t[-1])
for s in ("top", "right", "left"):
    ax1.spines[s].set_visible(False)
ax1.spines["bottom"].set_color("#bfbfbf")
ax1.set_title("① 状态：一直布防等目标字节 —— 触发时刻落在解码出 0xAA 的那一拍",
              fontsize=12.5, pad=10)

# ============ 2. 触发瞬间特写 ============
ax2 = fig.add_subplot(gs[1])
rows2 = [("bus_scl", "SCL", 1, "#1668dc"),
         ("bus_sda", "SDA", 0, "#d4380d")]
for name, lab, y, col in rows2:
    ys = [sig[name][i] * AMP + y for i in range(len(t))]
    ax2.step(t, ys, where="post", linewidth=1.8, color=col)

ax2.axvline(t_trig, color="#d4380d", linestyle="--", linewidth=1.6)
t0_win, t1_win = t_trig - 1600, t_trig + 1600
for tt, v in decodes:
    if not (t0_win <= tt <= t1_win):
        continue
    ax2.axvline(tt, color="#389e0d", linestyle="--", linewidth=1.0, alpha=0.7)
    ax2.text(tt, 2.02, "%02X" % v, ha="center", fontsize=10,
             color="#389e0d", fontweight="bold", clip_on=True)

ax2.set_xlim(t0_win, t1_win)
ax2.set_ylim(-0.5, 2.5)
ax2.set_yticks([0, 1])
ax2.set_yticklabels(["SDA", "SCL"])
for lbl, col in zip(ax2.get_yticklabels(), ["#d4380d", "#1668dc"]):
    lbl.set_color(col)
for s in ("top", "right", "left"):
    ax2.spines[s].set_visible(False)
ax2.spines["bottom"].set_color("#bfbfbf")
ax2.set_title("② 触发瞬间：总线上的 I2C 波形 —— 虚线处解码器刚收完 0xAA",
              fontsize=12.5, pad=10)

# ============ 3. 缓冲内容 ============
idx, bscl, bsda = [], [], []
with open("tb_stage4_buf.csv", newline="") as f:
    for row in csv.DictReader(f):
        idx.append(int(row["idx"]))
        bscl.append(int(row["scl"]))
        bsda.append(int(row["sda"]))

ax3 = fig.add_subplot(gs[2])
for ys, y, col, lab in ((bscl, 1, "#1668dc", "SCL"), (bsda, 0, "#d4380d", "SDA")):
    ax3.step(idx, [v * AMP + y for v in ys], where="post",
             linewidth=1.6, color=col)

ax3.axvline(PRE_TRIG, color="#d4380d", linestyle="--", linewidth=1.8)
ax3.axvspan(0, PRE_TRIG, color="#1668dc", alpha=0.06)
ax3.axvspan(PRE_TRIG, idx[-1], color="#d4380d", alpha=0.05)
ax3.text(PRE_TRIG / 2, 2.22, "触发前 %d 点" % PRE_TRIG, ha="center",
         fontsize=10, color="#1668dc")
ax3.text((PRE_TRIG + idx[-1]) / 2, 2.22, "触发后 %d 点" % (idx[-1] + 1 - PRE_TRIG),
         ha="center", fontsize=10, color="#d4380d")
ax3.text(PRE_TRIG, 1.95, "触发点", ha="center", fontsize=10.5,
         color="#d4380d", fontweight="bold")

ax3.set_ylim(-0.5, 2.55)
ax3.set_yticks([0, 1])
ax3.set_yticklabels(["SDA", "SCL"])
for lbl, col in zip(ax3.get_yticklabels(), ["#d4380d", "#1668dc"]):
    lbl.set_color(col)
ax3.set_xlabel("采样点序号（0 = 缓冲里最老的一个点）")
ax3.set_xlim(0, idx[-1])
for s in ("top", "right", "left"):
    ax3.spines[s].set_visible(False)
ax3.spines["bottom"].set_color("#bfbfbf")
ax3.set_title("③ 片内缓冲（时间顺序）：触发点两侧的数据都在 —— 这就是预触发",
              fontsize=12.5, pad=10)

fig.suptitle("协议内容触发：等总线上出现 0xAA 才开始抓   （真实仿真数据）",
             fontsize=14, y=0.955)

plt.savefig("tb_stage4_fig.png", dpi=125, bbox_inches="tight", facecolor="white")
print("saved: tb_stage4_fig.png")
print("trigger at %0d ns" % t_trig)
print("decoded:", ["0x%02X" % v for _, v in decodes])
print("buffer edge counts: SCL=%d SDA=%d" %
      (sum(1 for i in range(1, len(bscl)) if bscl[i] and not bscl[i - 1]),
       sum(1 for i in range(1, len(bsda)) if bsda[i] != bsda[i - 1])))
