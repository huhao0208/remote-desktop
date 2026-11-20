# UU 远程 · 自建服务端（完整版）

单文件 FastAPI 实现，端口只用 **8443(HTTPS/WSS)** 与 **3478(STUN/TURN)**，不占 443。
客户端与真实设备之间是私有 WebRTC，服务端只做**信令 + RPC 中继**，媒体面不落地。

## 快速开始

```bash
# 本地（NAS）联调：服务端 8443 + mitmproxy 8080 改写
bash run.sh start          # stop / status

# VPS 部署
cp .env.example .env       # PUBLIC_HOST=<IP或域名>  TURN_SECRET=<随机长串>
bash deploy.sh root@<VPS>  # 或登录 VPS 后直接 bash deploy.sh
```
安全组放行：`8443/tcp`、`3478/udp`、`3478/tcp`、`49160-49200/udp`。
管理页：`https://<host>:8443/admin`（在线设备、房间、最近抓取请求）。

## 测试

```bash
python tests.py            # 33 项，含 WS 二进制转发、RPC 双向、房间隔离、TURN 凭据算法
python tests_regression.py # 15 项回归：重启后房间可连、RPC 不阻塞信令、房间级清理、越权防护
```
真实网络链路（经 CA + 代理 + 真 TLS，证书与代理自动生成、无需外部产物）：
```bash
python ../tools/e2e_proxy_test.py   # ALL PASS
```

## 接口清单

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | /api/v1/login/by_mobile | 手机号登录，同号复用 uid、换发 token |
| POST | /api/v1/login/by_qrcode | 扫码登录 |
| POST | /api/v1/user/info · /user/logout | 用户信息 / 登出 |
| POST | /api/v1/device/{pc,android,android_tv}/init | 设备注册（含 device_id 冲突保护） |
| POST | /api/v1/device/list · /rename · /delete | 设备列表（含在线态）/ 改名 / 删除 |
| POST | /api/v1/room/create · /join/by_device/{id} · /join/refetch · /clear/{id} | 建房与房间生命周期 |
| GET | /api/v1/room/list | 未关闭房间 |
| POST | /api/v1/transport/{device_id}/rpc/request | 下发调用，阻塞等被控端应答（默认 30s） |
| GET | /api/v1/transport/{device_id}/rpc/poll | 被控端取任务 |
| POST | /api/v1/transport/{device_id}/rpc/respond | 被控端应答 |
| WS | /ws/signaling?token=&device_id= | 信令中继，text/binary 原样转发，回显子协议 |
| GET | /healthz · /debug/capture · /api/v1/transport/{id}/queue | 运维与排障 |
| ANY | /api/{path} | 未实现接口兜底：抓取原始报文 + 回 `{"code":0,"data":null}` |

## 设计要点

- **二进制透明**：客户端自定义帧不解析、不注入，任何私协议都能通过（客户端换协议不用改服务端）。
- **房间隔离**：WS 按 room_id 分组，跨房间不串帧。
- **打洞优先**：房间下发 STUN + 短时效 TURN 凭据（HMAC-SHA1，与 coturn `use-auth-secret` 一致），
  ICE 天然先直连、全失败才中继；`ice_transport_policy=all`。
- **未知请求不打死**：客户端调用我们没实现的接口时回空成功并落 capture，便于按真实报文补齐，
  而不是让客户端直接断链。
- **持久化**：sqlite（WAL）存用户/设备/房间/RPC 队列，容器内 `/app/data` 卷。`