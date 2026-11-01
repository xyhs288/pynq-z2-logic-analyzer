"""
bringup_test.py —— PYNQ 加载自建 overlay 的兼容性验证

目的：把两个问题分开
  (A) PYNQ 镜像能不能加载 Vivado 2025.2 生成的 .bit + .hwh
  (B) 我们自己的 axi_regs 从机对不对
本脚本验 (A)。通过后才有必要把 (B) 装进 block design。

用法：
  1. 把 test_axi.bit / test_axi.hwh / 本文件放到板子上同一个目录
     （JupyterLab 直接拖拽上传即可）
  2. 在 Jupyter 里运行本文件，或把内容拆成 cell 逐段跑
  3. 把全部输出贴回来

⚠️ 如果从 SSH 跑（不走 Jupyter），必须先设 XILINX_XRT，否则 PYNQ 找不到设备后端，
   报 "No Devices Found"：
     sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 bringup_test.py
   值必须是 /usr（来自 /etc/profile.d/xrt_setup.sh），写成 1 会报
   "No such library '1/lib/libxrt_core.so.2'"。Jupyter 环境下已自动设置，无需理会。

判据（2026-10-13 实测结果，PYNQ-Z2 v3.1.1 + Vivado 2025.2）：
  version_check = pass  ← 连 ignore_version 都不用加
  addr_map      = pass  ← gpio @ 0x41200000
  clk_parse     = pass
  axi_rw        = pass  ← 写 0xF 读回 0xF，写 0x5 读回 0x5
"""


import os
import sys
import traceback

LINE = "=" * 62
result = {}


def sec(t):
    print()
    print(LINE)
    print(t)
    print(LINE)


# ---------------------------------------------------------------------
sec("0. 环境")
try:
    import pynq
    print("  pynq    :", getattr(pynq, "__version__", "?"))
except Exception as e:
    print("  pynq 导入失败:", e)
print("  python  :", sys.version.split()[0])
print("  cwd     :", os.getcwd())
for f in ("test_axi.bit", "test_axi.hwh"):
    print("  %-16s %s" % (f, "存在" if os.path.exists(f) else "!!! 缺失"))


# ---------------------------------------------------------------------
sec("1. 不用 ignore_version 加载（看它报什么）")
from pynq import Overlay

ol = None
try:
    ol = Overlay("test_axi.bit")
    print("  [OK] 版本检查通过，直接加载成功")
    result["version_check"] = "pass"
except Exception as e:
    print("  失败:", type(e).__name__)
    print("  ", str(e)[:400])
    result["version_check"] = "fail"


# ---------------------------------------------------------------------
sec("2. 用 ignore_version=True 加载")
if ol is None:
    try:
        ol = Overlay("test_axi.bit", ignore_version=True)
        print("  [OK] 加载成功（跳过了版本检查）")
        result["load"] = "pass"
    except Exception as e:
        print("  [FAIL] 仍然失败:", type(e).__name__)
        traceback.print_exc()
        result["load"] = "fail"
else:
    print("  （第 1 节已经加载成功，无需再试）")
    result["load"] = "pass"

if ol is None:
    print()
    print(">>> 到此为止，overlay 完全加载不了。把上面的输出贴回来。")
    sys.exit(1)


# ---------------------------------------------------------------------
sec("3. IP 地址解析（这一环最关键）")
for k, v in sorted(ol.ip_dict.items()):
    addr = v.get("phys_addr", None)
    print("  %-28s type=%-22s addr=%s" % (
        k, v.get("type", "?"),
        hex(addr) if isinstance(addr, int) else addr))

result["addr_map"] = "pass" if "gpio" in ol.ip_dict else "fail"
if "gpio" in ol.ip_dict:
    a = ol.ip_dict["gpio"].get("phys_addr")
    print()
    print("  gpio phys_addr =", hex(a) if isinstance(a, int) else a,
          " (期望 0x41200000)")
    if a != 0x41200000:
        result["addr_map"] = "fail"


# ---------------------------------------------------------------------
sec("4. 时钟解析（PL 时钟频率是否被正确读出）")
try:
    print("  clock_dict:", ol.clock_dict)
    result["clk_parse"] = "pass"
except Exception as e:
    print("  [FAIL]", e)
    result["clk_parse"] = "fail"


# ---------------------------------------------------------------------
sec("5. 读写寄存器（PL 真的在响应吗）")
try:
    from pynq import MMIO
    base = ol.ip_dict["gpio"]["phys_addr"]
    gpio = MMIO(base, 0x1000)

    print("  写 GPIO_DATA = 0xF  ...")
    gpio.write(0x00, 0xF)
    v = gpio.read(0x00)
    print("  读回          = 0x%X  (期望 0xF)" % v)

    print("  写 GPIO_DATA = 0x5  ...")
    gpio.write(0x00, 0x5)
    v2 = gpio.read(0x00)
    print("  读回          = 0x%X  (期望 0x5)" % v2)

    if v == 0xF and v2 == 0x5:
        print("  [PASS] AXI 读写通路成立")
        result["axi_rw"] = "pass"
    else:
        print("  [FAIL] 读回值与写入不符")
        result["axi_rw"] = "fail"

    print()
    print("  现在看板子上的 4 个 LED：应该是 LD0/LD2 亮、LD1/LD3 灭（0x5 = 0101）")
except Exception as e:
    traceback.print_exc()
    result["axi_rw"] = "fail"


# ---------------------------------------------------------------------
sec("结论")
for k in ("version_check", "load", "addr_map", "clk_parse", "axi_rw"):
    print("  %-16s : %s" % (k, result.get(k, "-")))

print()
if result.get("load") == "pass" and result.get("addr_map") == "pass" \
        and result.get("axi_rw") == "pass":
    print("  >>> 通过：这个镜像可以继续用，直接进入下一步（把自己写的")
    print("      axi_regs 装进 block design）。")
else:
    print("  >>> 有问题，把上面输出全部贴回来。")
    print("      特别是第 3、4 节：地址和时钟解析失败 = 版本不兼容，" \
          "该换镜像。")
