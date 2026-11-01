#!/bin/bash
# 在 PYNQ-Z2 上安装「上电即用」服务：开机自动加载 bit 流并启动网页服务
# 用法：sudo bash install_autostart.sh
set -e

APP=/home/xilinx/jupyter_notebooks/la_bringup
UNIT=/etc/systemd/system/la-analyzer.service

echo "==> 检查文件"
[ -f "$APP/la_sys.bit" ] || { echo "缺少 $APP/la_sys.bit"; exit 1; }
[ -f "$APP/la_sys.hwh" ] || { echo "缺少 $APP/la_sys.hwh"; exit 1; }
[ -f "$APP/la_server.py" ] || { echo "缺少 $APP/la_server.py"; exit 1; }

echo "==> 安装 unit"
install -m 644 /home/xilinx/la-analyzer.service "$UNIT" 2>/dev/null || \
install -m 644 "$(dirname "$0")/la-analyzer.service" "$UNIT"

echo "==> 关掉会覆盖 PL 的 PYNQ 服务"
# jupyter.service 启动时会加载默认 base overlay；clear_pl_statefile.service 又
# 通过 Requires=jupyter.service 把它拉起来。两者都会把我们加载的 la_sys 顶掉，
# 表现是「网页能开、但读回来的数据是地址本身、波形全是 2/4/8/16 的方波」。
systemctl mask jupyter.service clear_pl_statefile.service >/dev/null 2>&1 || true
systemctl stop  jupyter.service >/dev/null 2>&1 || true

echo "==> 清理手工进程（避免抢 8080 端口）"
pkill -f 'la_[s]erver\.py' 2>/dev/null || true
sleep 1

systemctl daemon-reload
systemctl enable la-analyzer.service
systemctl restart la-analyzer.service

echo "==> 等待服务就绪（加载 overlay 约需 10~20 秒）"
for i in $(seq 1 40); do
    if curl -s --max-time 2 http://127.0.0.1:8080/meta >/dev/null 2>&1; then
        echo "OK: 服务已就绪，用时约 $((i)) 秒"
        curl -s --max-time 3 http://127.0.0.1:8080/meta; echo
        systemctl is-enabled la-analyzer.service
        exit 0
    fi
    sleep 1
done

echo "!!! 服务未在 40 秒内就绪，查看日志："
journalctl -u la-analyzer.service -n 30 --no-pager
exit 1
