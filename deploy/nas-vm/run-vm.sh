#!/bin/sh
# 在 userns 里 bind 一个「合成目录」到 /usr/bin：
#   合成目录 = 原 /usr/bin 的全部内容（cp -a，硬链接跨文件系统会静默失败）
#            + 解包的 Xvfb/xkbcomp 覆盖
# 这样 Xvfb 硬编码的 /usr/bin/xkbcomp 存在，同时 sleep/python 等原工具全部保留。
# 边界（2026-11-21 实测定案）：ns 只服务于 Xvfb 启动（xkbcomp 编译 keymap）。
# /tmp 在 NAS 上不是独立挂载，unshare 的 rprivate 只隔离新挂载操作，X99 socket
# 在 ns 外同一 inode 直接可达——所以 Agent 不必进 ns，ns 外 DISPLAY=:99 即可。
# 调用方式建议 nohup 包装，否则 ssh 会话结束进程组被杀：
#   nohup unshare -Urm sh ~/uu-remote/run-vm.sh > /tmp/vm.log 2>&1 &
# 依赖：agent-venv 的 site-packages 里要有空壳 tkinter（见 nas-debug-handoff.md §5-9），
# 否则 mouseinfo import 时 sys.exit 静默杀掉 agent。
SETUP=/home/huzhfieng/xvfb/merged-bin
rm -rf "$SETUP"
mkdir -p "$SETUP"
# cp 原 /usr/bin 全部内容（/ 与 /home 不同文件系统，硬链接跨盘不可能）
cp -a /usr/bin/. "$SETUP/" 2>/dev/null
# 叠加解包的 X11 工具（覆盖同名，加载自己的库）
cp -f /home/huzhfieng/xvfb/root/usr/bin/* "$SETUP/" 2>/dev/null

mount --bind "$SETUP" /usr/bin
export LD_LIBRARY_PATH=/home/huzhfieng/xvfb/root/usr/lib/x86_64-linux-gnu:/home/huzhfieng/xvfb/root/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu

/home/huzhfieng/xvfb/root/usr/bin/Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
# 等 socket 出现（此时 /usr/bin 已 bind，sleep 可用）
for i in 1 2 3 4 5 6 7 8 9 10; do
  [ -S /tmp/.X11-unix/X99 ] && break
  sleep 1
done

umount /usr/bin
export DISPLAY=:99
cd /home/huzhfieng/uu-remote
exec ./agent-venv/bin/python agent/agent.py --server http://192.168.31.152:18443 --mobile 13800000001 --name NAS-VM --transport jpeg --no-audio
