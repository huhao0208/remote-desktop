# uu-remote-server

自建 UU 远程兼容服务端：把官方客户端的信令与 API 落到自己的 VPS 上，
媒体面仍是客户端之间的私有 WebRTC（服务端不碰屏幕数据），**打洞优先、TURN 兜底**。

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
cd srv2 && python tests.py          # 33 checks PASSED
python ../tools/e2e_proxy_test.py   # ALL PASS（真实 TLS 链路）
```

## 能力

账号（手机号/扫码登录、登出）、设备（三平台注册、列表含在线态、改名、删除）、
房间（创建/加入/重取/关闭/列表，RoomConfig 14 字段对齐）、
信令（text/binary 透明中继、子协议回显、房间隔离）、
远程指令中继（request/poll/respond，30s 超时 2004）、
TURN 短时效凭据（HMAC-SHA1，与 coturn `use-auth-secret` 一致）、
未实现接口兜底并抓包。

## 免责声明

仅供个人学习与自用，与 UU 远程官方无关；请勿用于商业分发或绕过付费服务。
客户端二进制与反编译产物不入库。