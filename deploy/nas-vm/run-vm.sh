#!/bin/sh
# 在 userns 里 bind 一个「合成目录」到 /usr/bin：
#   合成目录 = 原 /usr/bin 的全部内容（硬链接，usrmerge 系统里 /bin==/usr/bin）
#            + 解包的 Xvfb/xkbcomp 覆盖
# 这样 Xvfb 硬编码的 /usr/bin/xkbcomp 存在，同时 sleep/python 等原工具全部保留。
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
exec ./agent-venv/bin/python agent/agent.py --server https://192.168.31.152:8443 --insecure --mobile 13800000001 --name NAS-VM --transport jpeg --no-audio
