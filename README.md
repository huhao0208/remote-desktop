# uu-remote-server

自建 UU 远程兼容服务端：控制面（账号/设备/房间/信令）跑在自己的 VPS 上，
媒体面走 **WebRTC（H.264 + SRTP/UDP）**，服务端不碰屏幕数据，**打洞优先、TURN 兜底**。

- 端口：`8443` HTTPS/WSS（不占 443） + `3478` STUN/TURN + `49160-49200/udp` 中继
- 单文件服务端：`srv2/server.py`（FastAPI + sqlite WAL，无外部依赖）
- 部署：Docker Compose（api + coturn），一条命令起

## 目录

```
srv2/            服务端（推荐入口）
  server.py      全部接口与信令中继
  tests.py       33 项集成测试
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

每个桌面平台包含 `uu-server`（服务端）与 `uu-agent`（被控端）两个独立二进制：

| 产物 | 平台 | 形态 |
|---|---|---|
| `uu-server-windows-x64.zip` | Windows | server + agent 独立 exe，免装 Python |
| `uu-server-macos-arm64.tar.gz` | macOS Apple Silicon | server + agent 独立可执行 |
| `uu-server-macos-x64.tar.gz` | macOS Intel | server + agent 独立可执行 |
| `uu-server-linux-x64.tar.gz` | Linux / VPS | server + agent 独立可执行（免 Docker 备选） |
| `uu-server-android-termux.tar.gz` | Android（Termux） | 源码 + 一键脚本 |
| `uu-server-universal.tar.gz` | iOS（a-Shell）及任意 Python 3.10+ | 通用源码包 |

注：本仓库为服务端控制面；Android/iOS 官方客户端 App 本体不在此仓库，
移动端包用于在手机/平板上跑自建服务端。

## 免责声明

仅供个人学习与自用，与 UU 远程官方无关；请勿用于商业分发或绕过付费服务。
客户端二进制与反编译产物不入库。