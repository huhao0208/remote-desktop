# NAS 虚拟机调试：Linux 被控端 + srv2 服务端

> 目标：用 NAS 虚拟机跑一台 **Linux 被控端**（本项目从未在真实 Linux 上验过的部分），
> 顺带跑 **srv2 服务端**，本机 Mac 当控制端做局域网联调。
> 重点验证 B 阶段四项在 Linux 上的行为（见 §5 验证清单）。

---

## 0. 这套组合能验什么、不能验什么

| 项 | Linux 虚拟机上能验 | 说明 |
|---|---|---|
| 屏幕采集（mss） | ✅ | X11 下没问题；**Wayland 不行**（mss 依赖 X11），装桌面时选 X11 会话 |
| 键鼠注入（pyautogui） | ✅ | 需要 `xdotool` 兜底（见 §3 步骤 5） |
| 鼠标三模式 | ✅ 但有边界 | `cursor.py` 在 Linux 是 `unsupported`（X11/Wayland 无统一隐藏光标 API，**这是设计好的降级不是缺陷**）→ 「主控端鼠标」按钮应置灰 |
| 文件传输 | ✅ 全功能 | `safe_name`/`check_space`/`.part` 均跨平台纯 stdlib |
| 键位映射 | ⚠️ 部分 | Mac→Linux **不跨平台**（`isCrossPlatform` 只认 mac↔win），面板会显示「同平台」置灰，这是预期 |
| 控制端麦克风 | ⚠️ | `audio_playback` 依赖 sounddevice；虚拟机需要一块虚拟声卡（多数虚拟机默认有 `Intel HDA`），没有则 `hello.mic=false` 按钮消失 |
| srv2 服务端 | ✅ | docker compose 一键起 |

**已知不能验**：WebRTC 硬编（aiortc 软编可用但 CPU 高，虚拟机里给够 2 核）；macOS 特有的
CGDisplayStream 防窥、Windows SendInput 侧键。

---

## 1. 虚拟机配置建议

| 项 | 建议值 | 原因 |
|---|---|---|
| 系统 | **Ubuntu 22.04 LTS 桌面版**（X11 会话） | aiortc/sounddevice 轮子最全；X11 是 mss 硬要求 |
| CPU | 2 vCPU（够） | 软编 H.264 是 CPU 大户 |
| 内存 | 4 GB | 桌面 + Python + Firefox 自检 |
| 磁盘 | 32 GB | 文件传输测试要传大文件 |
| 网络 | **桥接（Bridge）**到 NAS 物理网卡 | 必须和 Mac 同网段，P2P 直连才能通；NAT 模式打洞必失败 |
| 显示 | 关 3D 加速、显存 16MB+ | mss 抓帧走 CPU，不需要 GPU |
| 声卡 | 默认 Intel HDA（有就行） | 麦克风放音验证用 |

> 群晖 VMM / 威联通 Virtualization Station 都行；要是 NAS 虚拟机不支持桥接，
>退路是 NAT + 端口映射（虚拟网段 → 虚机 22/8443），但 TURN 中继会绕路，延迟大。

## 2. 服务端：两分钟起 srv2

```bash
# 在 NAS 的 Docker 目录（已有 deploy/nas 的话直接复用）
cd /volume1/docker/uu-remote        # 或新目录
scp -r srv2 you@nas:/volume1/docker/uu-remote/

cd /volume1/docker/uu-remote/srv2
# 临时调试不需要证书：UU_DEBUG 直接 HTTP
cat > .env <<'EOF'
API_PORT=18443
EOF
docker compose up -d --build
# 自检
curl -s http://127.0.0.1:18443/healthz
```

> 局域网调试用 `http://<NAS_IP>:18443` 明文即可，不用配证书——
> `run.sh` 里那套 HTTPS/sslip.io 是给**公网穿透**用的，内网联调跳过。

## 3. Linux 被控端安装（虚拟机里）

```bash
# 1) 系统库（X11 桌面默认有，缺就补）
sudo apt update
sudo apt install -y python3-pip python3-venv scrot xdotool libasound2-dev \
                    portaudio19-dev ffmpeg

# 2) 拉代码（或从 Mac scp）
#    git clone https://github.com/huhao0208/remote-desktop.git
scp -r you@mac:/Users/hoha/WorkBuddy/2026-11-20-14-15-30/remote-desktop-git/agent ~/uu-agent-src

# 3) 虚拟环境
cd ~/uu-agent-src
python3 -m venv venv && source venv/bin/activate
pip install -r agent/requirements.txt

# 4) 起被控端（指向 srv2）
python3 agent.py --server http://<NAS_IP>:18443 --name Linux-VM
```

要点：
- **X11 会话登录**（登录界面右下角选「Ubuntu on Xorg」），Wayland 下 mss 抓到的是黑屏。
- `xdotool` 是 pyautogui 在 Linux 下的实测依赖，装了它键鼠注入才稳。
- `libasound2-dev + portaudio19-dev` 是 sounddevice 的编译依赖，没有它
  `pip install sounddevice` 能装但运行时打不开设备 → `hello.mic=false`。
- Agent 日志开头会打印 `media=… audio=… mic=…(backend)`——**mic=off 时先查声卡**。

## 4. Mac 控制端连接

```bash
cd client-flutter
flutter run -d macos
# 设置页 → 服务端地址 → http://<NAS_IP>:18443
# 登录 → 设备列表应出现「Linux-VM」→ 连接
```

---

## 5. 验证清单（B 阶段四项 × Linux 被控端）

按顺序做，每项都对应协议或基线里承诺过的行为：

| # | 操作 | 预期 | 对应承诺 |
|---|---|---|---|
| 1 | 连接 Linux-VM，看画面 | JPEG 通路出画面 | Linux mss 采集 |
| 2 | 鼠标移动/点击/滚轮 | 被控端跟手 | pyautogui 注入 |
| 3 | 打开「鼠标」面板 | 「使用主控端鼠标」**置灰**+原因 | cursor.py Linux=unsupported 的降级 |
| 4 | 「外设」面板 | 显示「同平台/键位直通」置灰 | isCrossPlatform 只认 mac↔win |
| 5 | 传一个 100MB 文件过去 | 秒传 + sha256 一致 + 无 `.part` 残留 | 文件传输全链路 |
| 6 | 传同名文件第二次 | 落成 `a (1).zip` | 冲突改名 |
| 7 | 从 Linux 下载 `/etc/hosts` 回来 | 成功；但下载 `/etc/shadow` | **被拒**（路径白名单） |
| 8 | 开语音 | Mac 上说句话、虚拟机扬声器出声 | audio_playback + gate |
| 9 | 关语音再开，连续开关 5 次 | �次都有 `mic.state` 回执、无卡死 | 状态机 + 零重协商 |
| 10 | `Ctrl+Alt+Del` 按钮 | 无效但不出错（Linux 无此组合） | 降级路径 |
| 11 | 断开重连 | 恢复正常，麦克风是 OFF | 协议 §6.6 |

## 6. 常见翻车点（虚拟机特有）

| 现象 | 原因 | 处理 |
|---|---|---|
| hello 报 `screen_permission` 或全黑 | Wayland 会话 | 换「Ubuntu on Xorg」登录 |
| 键鼠没反应 | 缺 xdotool / X 权限 | `sudo apt install xdotool`；别用 sudo 跑 agent |
| `hello.mic=false` | 虚拟机没声卡 | VMM 设置里加一块 Intel HDA 声卡再开机 |
| WebRTC 协商失败回落 JPEG | 桥接没开 / 防火墙拦 UDP | 虚拟机网络改桥接；`sudo ufw disable` 试跑 |
| 传输慢 | base64 走信令 WS 本来就不快（~2MB/s） | 正常，4GiB 上限测试换小文件分批传 |
| TURN 报错 | 内网调试用不到 TURN | 忽略，P2P 直连成功即可 |
