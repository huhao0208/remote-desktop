# uu-remote-server

自建 UU 远程兼容服务端：把官方客户端的信令与 API 落到自己的 VPS 上，
媒体面仍是客户端之间的私有 WebRTC（服务端不碰屏幕数据），**打洞优先、TURN 兜底**。

- 端口：`8443` HTTPS/WSS（不占 443） + `3478` STUN/TURN + `49160-49200/udp` 中继
- 单文件服务端：`srv2/server.py`（FastAPI + sqlite WAL，无外部依赖）
- 部署：Docker Compose（api + coturn），一条命令起

## 目录

```
client-desktop/  桌面客户端（Electron，远控+被控一体）
client-mobile/   移动客户端（Capacitor，Android/iOS 工程）
agent/           被控端 agent.py（推屏 + 输入注入 + 可撤销关机）
srv2/            服务端（推荐入口）
  server.py      全部接口与信令中继
  control.html   控制页（网页版与客户端共用同一份）
  tests.py       34 项集成测试
  tests_regression.py  23 项回归测试
  Dockerfile · docker-compose.yml · entrypoint.sh
  deploy.sh      VPS 一键部署（本地推送或机上执行）
  run.sh         本地起服务端 + 改写代理（局域网真机联调）
  README.md      接口清单与设计说明
tools/
  e2e_proxy_test.py   真实 TLS + 自建 CA + 代理的端到端验证
proxy/
  addon_uuyc.py       mitmproxy 改写插件：*.nrd.nie.163.com → 本地服务端
```

## 快速开始

```bash
cd srv2
cp .env.example .env       # PUBLIC_HOST=<VPS IP或域名>  TURN_SECRET=<随机长串>
bash deploy.sh root@<VPS>  # 安全组放行 8443/tcp、3478/udp+tcp、49160-49200/udp
```

管理页 `https://<host>:8443/admin`；健康检查 `/healthz`；请求抓取 `/debug/capture`。

## 测试

```bash
pip install fastapi uvicorn websockets mitmproxy cryptography
cd srv2 && python tests.py             # 34 checks PASSED
python tests_regression.py             # 23 regression checks PASSED
python ../tools/e2e_proxy_test.py      # ALL PASS（真实 TLS 链路，证书/代理自动生成）
```

## 能力

账号（手机号/扫码登录、登出）、设备（三平台注册、列表含在线态、改名、删除）、
房间（创建/加入/重取/关闭/列表，RoomConfig 14 字段对齐）、
信令（text/binary 透明中继、子协议回显、房间隔离）、
远程指令中继（request/poll/respond，30s 超时 2004）、
TURN 短时效凭据（HMAC-SHA1，与 coturn `use-auth-secret` 一致）、
未实现接口兜底并抓包。

## 客户端（远控 + 被控一体，UU 远程同款形态）

装一个 App 就同时具备两种能力：登录后既能把别的电脑拉过来控制，本机也自动上线、
出现在其它设备的可控列表里。服务器地址内置，不用手输网址。

```
桌面客户端(Electron) ─┐
                      ├─WSS→ 自建服务端 ←WSS→ 内置被控端 uu-agent
移动客户端(Capacitor)─┘
```

| 目录 | 产物 | 形态 |
|---|---|---|
| `client-desktop/` | `uu-remote-client-{windows-x64,macos-arm64,macos-x64,linux-x64}` | 原生窗口 App，内含 `uu-agent` 被控端，登录即启动、登出即停、崩溃 5s 自愈 |
| `client-mobile/` | `uu-remote-client-android.apk` · `uu-remote-client-ios-project.zip` | Android 原生壳；iOS 需 Mac+Xcode 选签名团队出 ipa |
| `agent/agent.py` | `uu-agent` | 独立被控端，可单独部署（`--mobile` 或 `--token` 登录） |

设备列表里的「本机」与内置被控端是**同一台设备**：客户端用机器级指纹
（`hostname-OS-MAC`）注册，与 Agent 上报的 `device_id` 对齐，不会出现两条记录。
界面上「允许其他设备远程控制本机」可一键停/启被控服务。

> 权限：macOS 首次被控需在 系统设置 → 隐私与安全性 授予 **屏幕录制 + 辅助功能**。

## 手机远程控制电脑（自研轻量链路）

```
手机浏览器 /control ←WSS→ 自建服务端 ←WSS→ 电脑 Agent
```

1. **服务端**（VPS 或局域网任一机器）：`cd srv2 && bash deploy.sh root@<VPS>`，或本机 `python server.py`
2. **被控电脑**（Windows / macOS）：
   ```bash
   pip install mss pillow pyautogui websockets httpx
   python agent/agent.py --server https://<host>:8443 --mobile <手机号> --name MY-PC
   ```
   macOS 需授予「屏幕录制」+「辅助功能」权限。
3. **手机**（Android / iOS 浏览器，免装 App）：打开 `https://<域名>:<端口>/control`，
   同一手机号登录 → 设备列表展示该账号全部已登录客户端（本机带「本机」标签，
   电脑显示在线/离线状态）→ 点击在线电脑整行即进入远程桌面；断线自动指数退避重连。

   > 手机访问注意：请使用**域名**入口而非裸 IP。IP 证书只能走短期 profile（ECDSA 新链），
   > 部分手机浏览器/微信内嵌不信任；域名证书走标准链，兼容性最好。
   > 当前部署：`https://47-251-105-202.sslip.io:8444/control`（nginx TLS 反代 → 18443）。
   > 手机号带 +86 前缀会自动归一化；同一账号多端登录不互相顶号。

操作：单指移动=光标；轻点=左键；长按=右键；双指滑动=滚轮；⌨️ 唤起键盘（中文走剪贴板粘贴）；
快捷键按钮：复制/粘贴/切窗/回桌面。**远程关机**：⏻ 按钮 → 二次确认 → 30 秒倒计时可撤销。

实测（Mac 本机端到端）：`python tools/e2e_remote_test.py` → 设备在线 / hello / JPEG 帧流 /
输入路由 / 关机倒计时与撤销，全部通过。

## 自动打包（GitHub Actions）

push `main` / 打 `v*` tag / 手动触发 `.github/workflows/build.yml`：
先跑 33+15 项测试与 e2e 门禁，再产出四平台部署包（Artifacts，tag 时自动发 Release）：

服务端/Agent 独立二进制（每平台一包，含 `uu-server` + `uu-agent`）：

| 产物 | 平台 | 形态 |
|---|---|---|
| `uu-remote-windows-x64.zip` | Windows | server + agent 独立 exe，免装 Python |
| `uu-remote-macos-arm64.tar.gz` | macOS Apple Silicon | server + agent 独立可执行 |
| `uu-remote-macos-x64.tar.gz` | macOS Intel | server + agent 独立可执行 |
| `uu-remote-linux-x64.tar.gz` | Linux / VPS | server + agent 独立可执行（免 Docker 备选） |
| `uu-remote-android-termux.tar.gz` | Android（Termux） | 源码 + 一键脚本 |
| `uu-remote-universal.tar.gz` | 任意 Python 3.10+ | 通用源码包 |

控制端客户端：

| 产物 | 平台 | 形态 |
|---|---|---|
| `uu-remote-client-windows-x64.exe` | Windows | 安装包 + 免安装 exe（内含被控端） |
| `uu-remote-client-macos-arm64.dmg` / `-x64.dmg` | macOS | 拖入 Applications 即用 |
| `uu-remote-client-linux-x64.AppImage` | Linux | 单文件可执行 |
| `uu-remote-client-android.apk` | Android | 直接安装（debug 签名） |
| `uu-remote-client-ios-project.zip` | iOS | Xcode 工程，签名后安装 |

注：客户端为 Electron / Capacitor 壳，`client-desktop/web/index.html` 与
`client-mobile/www/index.html` 由 `srv2/control.html` 经 `scripts/sync-web.js`
自动生成并注入服务器地址（`RD_SERVER` 环境变量可覆盖），改页面只需改 `srv2/control.html`。

## 免责声明

仅供个人学习与自用，与 UU 远程官方无关；请勿用于商业分发或绕过付费服务。
客户端二进制与反编译产物不入库。