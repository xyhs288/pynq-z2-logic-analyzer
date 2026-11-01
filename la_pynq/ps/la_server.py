#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
la_server.py —— 逻辑分析仪实时波形网页

板子上跑，PC 浏览器打开 http://<板子IP>:8080 就能看到滚动波形。

数据通路
--------
    浏览器 --GET /data?n=1024--> 本服务
                                  ├─ PL 处于 free run（CTRL.bit4=1），缓冲一直写
                                  ├─ 读 MEM_ADDR 拿最新 n 个点
                                  └─ 返回 n 字节原始数据（每字节 = 8 路电平）

为什么用二进制不用 JSON：1024 个整数变 JSON 约 4 KB，浏览器还要 parse；
二进制只有 1 KB，且直接 new Uint8Array。带宽和解码都是白赚的。

运行
----
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 la_server.py

可选：--port 8080  --n 1024  --div 1000  --proto 0|2|9
"""

import argparse
import base64
import json
import os
import socketserver
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from la_driver import LogicAnalyzer

HERE = os.path.dirname(os.path.abspath(__file__))
# 可重入：guard 重载时要在持锁状态下再调 enter_mode（它自己也持锁）
LOCK = threading.RLock()
# 置位期间 PL 正在重配置，任何 AXI 访问都不能进去（重配置撞上在途 AXI 事务会把 PS 挂死）
RELOADING = threading.Event()

STATE = {
    "n": 8192,
    "div": 40,
    # 信号只从 Pmod A 八路引脚来；Pmod B 是板子自己发的测试波形，
    # 靠杜邦线回接到 Pmod A 才会被采到
    "proto": 0,                  # 0=UART 2=I2C 9=关闭
    "pdiv": 640,                 # UART 位周期 = 640 clk（62.5MHz/640≈97.66kbaud）
    "pmodb": 1,                  # Pmod B 测试信号输出（0 = 高阻，接真实被测电路时关）
    "page": b"",
    "fps": 0.0,
    "_last": 0.0,
    "_frames": 0,
}

la = LogicAnalyzer()


def _pl_guard():
    """开机自检：确认 PL 里跑的还是我们的设计。

    背景：这块板子的镜像里 XRT/zocl 会在第一个客户端释放后（开机约 107 秒）
    把 PL 回落成默认的 base.bin，把我们加载的 la_sys 覆盖掉。表现是：
    网页能打开、寄存器也能读，但读回来的数据是地址本身、波形全是 2/4/8/16 的方波。

    🔴 这里踩过一个把整块板子搞死的坑（2026-10-31）：
       重载之后必须用 la.reload() 重建 MMIO。只换 la.ol 不重建 mmio 的话，
       读 WR_PTR 拿到的是死值，判定"又卡住了" -> 再重载 -> 无限重载 PL。
       dmesg 里能看到 6 秒一次连续 writing la_sys.bin，最后 PS 与 AXI 一起挂死。
       现在加了：重载期间置 RELOADING 挡住前端请求 + 最多重载 3 次就收手。
    """
    stuck = 0
    reloads = 0
    for _ in range(60):                       # 观察约 2 分钟
        time.sleep(2)
        if reloads >= 3:                      # 重载 3 次还不行，就别再折腾 PL 了
            print("[guard] 已重载 3 次仍未恢复，停止重试（请检查 bit 文件）", flush=True)
            break
        try:
            with LOCK:
                a = la.rd(la.WR_PTR)
                time.sleep(0.05)
                b = la.rd(la.WR_PTR)
        except Exception:
            continue
        if a != b:                            # 写指针在动 = 设计正常
            stuck = 0
            continue
        stuck += 1
        if stuck < 3:                         # 连续 3 次不动才判定
            continue
        stuck = 0
        reloads += 1
        try:
            print("[guard] 检测到 PL 被换掉，第 %d 次重载 la_sys.bit ..." % reloads,
                  flush=True)
            RELOADING.set()                   # 挡住所有前端 AXI 访问
            with LOCK:
                la.reload()
                enter_mode(STATE["div"])
            print("[guard] 重新加载完成", flush=True)
        except Exception as e:
            print("[guard] 重新加载失败:", e, flush=True)
        finally:
            RELOADING.clear()


def enter_mode(div, proto=None, pdiv=None, pmodb=None):
    """按当前设置进入 free run（信号固定来自 Pmod A 八路引脚）。"""
    if proto is None:
        proto = STATE["proto"]
    if pdiv is None:
        pdiv = STATE["pdiv"]
    if pmodb is None:
        pmodb = STATE["pmodb"]
    with LOCK:
        la.set_free_run(on=True, div=div, proto_sel=proto, proto_div=pdiv,
                        pmodb=bool(pmodb))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass                     # 不刷屏

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        # PL 正在重配置：除静态页外一律 503，绝不让 AXI 读插进去
        if u.path not in ("/", "/index.html") and RELOADING.is_set():
            self._send(503, "text/plain; charset=utf-8", b"PL reloading")
            return
        q = parse_qs(u.query)

        if u.path in ("/", "/index.html"):
            self._send(200, "text/html; charset=utf-8", STATE["page"])
            return

        if u.path == "/data":
            n = int(q.get("n", [STATE["n"]])[0])
            n = max(64, min(n, la.PHYS_DEPTH))
            with LOCK:
                s, _ = la.read_latest(n)
            body = s.tobytes()

            now = time.time()
            STATE["_frames"] += 1
            if now - STATE["_last"] >= 1.0:
                STATE["fps"] = STATE["_frames"] / (now - STATE["_last"])
                STATE["_frames"] = 0
                STATE["_last"] = now

            self._send(200, "application/octet-stream", body)
            return

        if u.path == "/capture":
            # 单次触发：退出 free run -> 布防 -> 等触发抓满 -> 读回
            div = int(q.get("div", [STATE["div"]])[0])
            pre = int(q.get("pre", [1024])[0])
            chan = int(q.get("chan", [5])[0])
            tmode = int(q.get("mode", [0])[0])
            val = int(q.get("val", [0])[0])
            n = max(256, min(int(q.get("n", [4096])[0]), la.PHYS_DEPTH))
            try:
                with LOCK:
                    la.set_free_run(on=False, pmodb=bool(STATE["pmodb"]))
                    s, meta = la.capture(
                        div=div, pre_trig=pre, trig_chan=chan, trig_mode=tmode,
                        trig_value=val, read_depth=n,
                        timeout=6.0)
                body = json.dumps({
                    "ok": True,
                    "n": n,
                    "pre_trig": pre,
                    "stop_ptr": meta["stop_ptr"],
                    "t_wait": meta["t_wait"],
                    "sample_rate": meta["sample_rate"],
                    "data": base64.b64encode(s.tobytes()).decode(),
                })
            except Exception as e:
                body = json.dumps({"ok": False, "error": str(e)})
            self._send(200, "application/json", body.encode())
            return

        if u.path == "/live":
            # 从触发模式切回自由运行（滚动显示）
            enter_mode(STATE["div"])
            self._send(200, "application/json", b'{"ok":true}')
            return

        if u.path == "/meta":
            with LOCK:
                ps = la.proto_status()
                pb = la.proto_byte()
                wr = la.rd(la.WR_PTR)
                btn = la.rd(la.BTN_CNT)
            self._send(200, "application/json", json.dumps({
                "div": STATE["div"],
                "clk_mhz": la.CLK_HZ / 1e6,
                "sample_rate": la.CLK_HZ / STATE["div"],
                "n": STATE["n"],
                "depth": la.PHYS_DEPTH,
                "proto_sel": STATE["proto"],
                "pmodb": STATE["pmodb"],
                "fps": round(STATE["fps"], 1),
                "wr_ptr": wr,
                "btn_cnt": btn,
                "proto_byte": pb,
                "proto": ps,
            }).encode())
            return

        if u.path == "/set":
            if "div" in q:
                STATE["div"] = int(q["div"][0])
            if "n" in q:
                STATE["n"] = max(64, min(int(q["n"][0]), la.PHYS_DEPTH))
            if "proto" in q:
                STATE["proto"] = int(q["proto"][0])
            if "pdiv" in q:
                STATE["pdiv"] = int(q["pdiv"][0])
            if "pmodb" in q:
                STATE["pmodb"] = 1 if q["pmodb"][0] in ("1", "on", "true") else 0
            enter_mode(STATE["div"])
            self._send(200, "application/json", b'{"ok":true}')
            return

        self._send(404, "text/plain", b"not found")


class FastServer(ThreadingHTTPServer):
    """跳过 server_bind 里的 getfqdn() 反向 DNS 查询。

    标准库 HTTPServer.server_bind() 会调 socket.getfqdn(host)，板子上没有 DNS，
    这一步能卡几十秒 —— 表现是"服务启动了但一行日志都没有"，非常难查。
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--n", type=int, default=8192, help="每帧点数（满深度 8192）")
    ap.add_argument("--div", type=int, default=40,
                    help="默认 40 -> 1.5625 MSa/s，正好让 UART 每位 16 个采样点")
    ap.add_argument("--mode", default="ext", choices=["ext"],
                    help="已废弃：信号固定来自 Pmod A，保留参数只为兼容启动脚本")
    ap.add_argument("--proto", type=int, default=0, choices=[0, 2, 9],
                    help="解码器 0=UART 2=I2C 9=关闭")
    a = ap.parse_args()

    STATE["n"] = a.n
    STATE["div"] = a.div
    STATE["proto"] = a.proto
    with open(os.path.join(HERE, "la_view.html"), "rb") as f:
        STATE["page"] = f.read()

    enter_mode(a.div)
    threading.Thread(target=_pl_guard, daemon=True).start()

    srv = FastServer(("0.0.0.0", a.port), Handler)
    print("=" * 54)
    print("  多通道逻辑分析仪 · 实时波形")
    print("  浏览器打开 : http://<板子IP>:%d/" % a.port)
    print("  每帧点数   : %d   采样率 : %.1f kHz (DIV=%d)"
          % (a.n, la.CLK_HZ / a.div / 1e3, a.div))
    print("  信号源     : Pmod A 八路输入（Pmod B 输出作测试源，需杜邦线回接）")
    print("=" * 54)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
