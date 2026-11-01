# =====================================================================
#  check_multidriver.py —— 检查一个 Verilog 文件里有没有"多驱动寄存器"
#
#  为什么需要它：
#    同一个 reg 在两个 always 块里都被赋值，Verilog 仿真器通常不会报错
#    （按调度顺序取最后一个值），但综合会报 CRITICAL WARNING 8-6859，
#    而且真实硬件上是竞态。这种 bug 靠仿真极难发现。
#
#  做法：按 always 块切分，收集每个块左侧被赋值的寄存器名（<= 和 =），
#        出现在两个及以上块里的就是多驱动。
#
#  用法：python check_multidriver.py <file.v> [file2.v ...]
#  返回码：0 = 干净，1 = 发现多驱动
# =====================================================================

import re
import sys


def blocks(src):
    """把源码按 always 块切开，返回 [(起始行号, 块文本), ...]"""
    out = []
    for m in re.finditer(r"\balways\b", src):
        i = m.start()
        # 找到块体的起始 '{' 或第一个 ';' 结尾的单语句
        j = src.find("{", i)
        k = src.find(";", i)
        if j == -1 or (k != -1 and k < j):
            out.append((src[:i].count("\n") + 1, src[i:k + 1]))
            continue
        depth, p = 0, j
        while p < len(src):
            if src[p] == "{":
                depth += 1
            elif src[p] == "}":
                depth -= 1
                if depth == 0:
                    break
            p += 1
        out.append((src[:i].count("\n") + 1, src[j:p + 1]))
    return out


def lhs_names(chunk):
    """取块内被赋值的寄存器名（去掉位选和下标）"""
    names = set()
    body = chunk[chunk.find("{") + 1:] if "{" in chunk else chunk
    for m in re.finditer(r"([A-Za-z_]\w*)\s*(?:\[[^\]]*\])*\s*<=", body):
        names.add(m.group(1))
    return names


def check(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    src = re.sub(r"//[^\n]*", "", src)          # 去行注释
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)  # 去块注释

    owners = {}
    for line, chunk in blocks(src):
        for n in lhs_names(chunk):
            owners.setdefault(n, []).append(line)

    bad = {n: l for n, l in owners.items() if len(l) > 1}
    print("=" * 58)
    print(" checking:", path)
    print("=" * 58)
    if not bad:
        print("  OK - no multi-driven register found")
        return 0
    for n, lines in sorted(bad.items()):
        print("  [MULTI-DRIVEN] %-18s driven at lines: %s"
              % (n, ", ".join(str(x) for x in lines)))
    print("  -> fix: give each register exactly one always block")
    return 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: python check_multidriver.py <file.v> [...]")
        sys.exit(2)
    rc = 0
    for p in sys.argv[1:]:
        rc |= check(p)
    sys.exit(1 if rc else 0)
