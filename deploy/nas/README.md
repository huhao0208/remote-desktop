# 家用 NAS 部署（公网 IPv4 版）

> 目标：把控制面（账号/设备/房间/信令）+ TURN 中继搬到自家 NAS，
> 让「家里设备互控」延迟从跨境的 ~200ms 降到局域网 ~1–5ms，且数据不出家门。
> 同一份镜像/VPS 配置完全通用，本目录只是把「家里网络」的差异固化成脚本。

## 0. 这套东西的边界（先明确，避免误解）

| 项 | 是否经过服务端 |
|---|---|
| 登录 / 设备列表 / 房间 / 信令（SDP、ICE、输入事件） | ✅ 经过（本文档部署的东西） |
| **画面（H.264/SRTP）** | ❌ 不经过，P2P 直连；只有打洞失败才走 TURN 中继 |

所以 NAS 带来的收益是：**建连更快 + 数据留在家里 + 家里设备之间完全走局域网**；
跨网时的画面质量仍取决于两端网络，不取决于服务端放哪。

## 1. 前置条件（缺一项就会翻车）

| 条件 | 要求 | 自查命令 |
|---|---|---|
| 公网 IPv4 | 路由器 WAN 口 IP = 外网看到的本机 IP（非 100.64.x.x / 10.x / 172.16-31.x） | `curl -s ifconfig.me` 与路由器 WAN 页对比 |
| 上行带宽 | ≥ 20 Mbps（TURN 中继时才用到） | `speedtest-cli` 或路由器面板 |
| 端口映射 | `8444/tcp`（控制面）、`3478/udp+tcp`（STUN/TURN）、`49160-49200/udp`（中继） | 部署后 `deploy/nas/preflight.sh` 会验 |
| DNS 名称 | 证书要域名；无域名可用 `sslip.io` 把 IP 转成域名 | 见 §4 |
| 802.1x / 双 NAT | 若光猫也拨号（双层 NAT），要么光猫桥接，要么在光猫再做一层映射 | 部署后从 4G 实测 |

> 端口说明：默认用 **8444**，避开 NAS 上常见的 443/8443 占用。改 `API_PORT` 即可。

## 2. 三条命令起服务

```bash
# 1) 拷到 NAS（群晖：/volume1/docker/uu-remote；威联通：/share/Container/uu-remote）
scp -r deploy/nas srv2 you@nas:/volume1/docker/uu-remote/

# 2) 生成配置（自动探测公网 IP / 内网网卡 IP / 生成 TURN_SECRET）
cd /volume1/docker/uu-remote/nas && sudo bash bootstrap.sh

# 3) 起服务
cd .. && sudo docker compose -f nas/docker-compose.yml up -d --build
```

`bootstrap.sh` 会产出 `srv2/.env`（或本目录 `.env`），内容形如：

```ini
PUBLIC_HOST=117-149-10-42.sslip.io   # sslip.io：把 IP 变成可签证书的域名
TURN_SECRET=<随机 32 字节>
TURN_PRIVATE_IP=192.168.1.10         # NAS 自己的内网 IP，coturn 必须绑这个
API_PORT=8444
```

## 3. 端口映射（路由器上做）

| 外部端口 | 协议 | 内网目标 | 用途 |
|---|---|---|---|
| 8444 | TCP | NAS:8444 | HTTPS + WSS（登录/设备/信令/控制页） |
| 3478 | UDP + TCP | NAS:3478 | STUN 打洞 + TURN |
| 49160-49200 | UDP | NAS（主机网络） | TURN 中继端口段 |

> coturn 用 `network_mode: host`，所以中继端口不需要在 Docker 里 publish，但**必须在路由器放行**。

## 4. 证书（二选一）

> ⚠️ **实测提醒（2026-11-20）**：该家宽公网 IP 在 10 分钟内从 `117.149.10.42` 变成
> `117.149.23.198` —— 是**动态 IP**。因此**方案 A 只适合试跑**，长期必须用方案 B。
> 判断依据：重播号/断线都会换 IP，sslip.io 的域名跟着 IP 走，证书和客户端地址都会失效。

### 方案 A：sslip.io + HTTP-01（零 DNS 配置，只建议试跑）

`sslip.io` 把 `a-b-c-d.sslip.io` 解析到 `a.b.c.d`，可直接申请 Let's Encrypt：

```bash
# 路由器先把 80/tcp 映射到 NAS，然后：
docker run --rm -p 80:80 -v "$PWD/certs:/etc/letsencrypt" \
  certbot/certbot certonly --standalone --agree-tos -m you@example.com \
  -d 117-149-10-42.sslip.io --non-interactive

# 拷成服务端要的固定文件名
sudo cp certs/live/117-149-10-42.sslip.io/fullchain.pem srv2/certs/
sudo cp certs/live/117-149-10-42.sslip.io/privkey.pem   srv2/certs/
```

> 公网 IP 变了（家宽重播号）→ 域名跟着变 → 证书要重签。介意的话走方案 B。

### 方案 B：自有域名 + DDNS + DNS-01（**推荐，长期方案**）

```bash
# 以阿里云 DNS 为例（acme.sh 支持十多家）
curl https://get.acme.sh | sh -s email=you@example.com
export Ali_Key=xxx Ali_Secret=yyy
~/.acme.sh/acme.sh --issue --dns dns_ali -d uu.example.com
~/.acme.sh/acme.sh --install-cert -d uu.example.com \
  --fullchain-file srv2/certs/fullchain.pem \
  --key-file srv2/certs/privkey.pem
```

配 DDNS（群晖自带 / 路由器 / `ddns-go`）把 `uu.example.com` 指到家宽 IP 即可。

## 5. 验证（部署后必跑）

```bash
bash deploy/nas/preflight.sh 117-149-10-42.sslip.io 8444
```

检查项：DNS 解析是否指向本机公网 IP、8444 是否可连、`/healthz` 是否 200、TURN 是否能 allocate（需要服务端先起来）。

再从**手机 4G**（关 Wi-Fi）打开 `https://<域名>:8444/control` 登录，设备列表能看到家里电脑即通。

## 6. 与 VPS 并存（推荐）

家里 NAS 做主，VPS 留作兜底：出差在外若家里断电/端口被封，切回 VPS 仍可用。
客户端支持改服务端地址（`RD_SERVER` 环境变量 / 设置页），两边跑同一份镜像，无需改代码。

## 7. 已知坑

| 坑 | 现象 | 处理 |
|---|---|---|
| NAS 上 443/8443 被占 | 容器起不来 | 改 `API_PORT`（默认已用 8444） |
| coturn 绑错网卡 | 中继偶发不通 | `TURN_PRIVATE_IP` 必须是**能出网的那块**内网网卡，不是 docker0 |
| 双层 NAT（光猫拨号） | 外网连不上 | 光猫改桥接，或光猫上也做端口映射 |
| NAS 休眠 | 首次连接超时 | 关掉硬盘休眠或给容器加 `restart: unless-stopped`（已加） |
| IP 变动 | 证书失效/连不上 | 用方案 B（自有域名 + DDNS） |
| 上行不够 | 中继时画面卡 | 控制页降到「流畅 1280 · 4M」档 |