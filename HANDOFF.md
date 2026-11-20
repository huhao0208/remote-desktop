# UU 远程自研项目 · 交接文档

> 交接对象：接手开发人员
> 项目根：`remote-desktop/`
> 文档版本：2026-11-20
> 配套逆向分析资料：`/Users/hoha/WorkBuddy/2026-11-20-18-18-50/uu-reverse/`（4 份文档，见 §6）

---

## 0. 30 秒速览

**这是什么**：一套自建的远程桌面系统。服务端跑在自己的 VPS 上，被控电脑跑 Agent，手机浏览器/桌面 Electron 客户端看画面、发指令。定位是个人自用 + 互操作性研究，不对外分发。

**现在能做什么**：
- 手机免装 App，浏览器打开 `/control` 就能控制电脑（画面 + 键鼠 + 关机）
- 桌面 Electron 客户端「远控 + 被控一体」，登录后本机自动出现在可控列表
- 自建服务端完整替代官方控制面（账号/设备/房间/信令/RPC/TURN 凭据）
- 媒体走 WebRTC（H.264 + SRTP/UDP），信令复用现有 WS，服务端零改动（见 ADR-8）
- 三套自动化测试（34 + 23 + e2e）全绿

**下一步做什么**：先换框架，再做性能。

| 顺序 | 任务 | 收益 | 工期 |
|---|---|---|---|
| 1 | **控制端框架迁移到 Flutter**（五端一套） | 包体 120MB(dmg)/274MB(app) → 18–60MB，内存 -70%，冷启动 -60% | 1 周（UI + 信令） |
| 2 | ~~媒体链路重构：媒体从 WS 拆出、走 UDP~~ **已被 ADR-8 替代** | 延迟 -60%（唯一致命项） | — |
| 3 | ~~H.264 + Texture 零拷贝渲染~~ **已随 ADR-8 落地** | 带宽 -70%，CPU -50% | — |
| 4 | ~~移动端原生解码插件~~ **已被 `flutter_webrtc` 部分消解** | iOS 旧版可用，移动延迟减半 | — |

> **2026-11-20 修订**：第 2/3/4 项已由 **ADR-8（媒体传输改 WebRTC）** 覆盖，不要再按原计划自研 UDP 包格式。详见 §8 顶部修订提示与 §9 ADR-8。

**已定稿的架构决策（别推翻）**：
- 控制端**换 Flutter**，Electron + Capacitor 作废（论证见 §2.4）
- **iOS 不做被控端**（系统限制，见 §1 端角色分工）
- 媒体传输**用 WebRTC**（H.264 + SRTP/UDP），信令复用现有 WS（见 ADR-8）
- 服务端 `srv2/` **一行不改**；被控端 `agent/` **只改媒体出口**（加 aiortc / ScreenTrack），其余不动

---

## 1. 项目定位与边界

### 目标
| 项 | 说明 |
|---|---|
| 形态 | 自建控制面 + 客户端间 P2P 媒体（服务端不碰画面） |
| 部署 | 单台 VPS，Docker Compose 一键起 |
| **控制端** | 五端全支持：Electron 桌面（Win/macOS/Linux）+ Capacitor 移动（Android/iOS）+ 手机 H5 |
| **被控端** | Python Agent（Win/macOS/Linux；Android 可选） |

### 端角色分工（重要，影响需求边界）

| 平台 | 控制端 | 被控端 | 说明 |
|---|---|---|---|
| Windows | ✅ | ✅ | |
| macOS | ✅ | ✅ | 需 ScreenCaptureKit + 辅助功能权限 |
| Linux | ✅ | ✅ | PipeWire / X11 |
| Android | ✅ | ⚠️ | 需 MediaProjection 每次授权，后台受限 |
| **iOS** | ✅ | ❌ | **系统层面不成立**：ReplayKit 只能录本 App，无系统级采集 + 注入 |

> 结论：iOS **只做控制端**。若收到「iOS 手机被控」的需求，直接拒绝并引用此表。

### 非目标（明确不做）
- 不做商业化，**无会员体系、无功能付费墙**
- 不做云电脑/云盘（官方那套商业形态）
- 不做游戏加速/模拟器联动
- 不做多租户 SaaS（单账号体系够用）
- **不做 iOS 被控端**（系统限制，非工作量问题）

### 法律边界（重要）
- 官方客户端二进制与反编译产物**不入库**
- 逆向分析仅用于理解互操作契约与功能设计
- 不提供任何绕过官方授权/付费校验的代码

---

## 2. 现有架构

### 2.1 组件图

```
┌──────────────┐    HTTPS/WSS     ┌─────────────────┐    HTTPS/WSS    ┌──────────────┐
│  客户端       │ ◄──────────────► │  服务端 srv2     │ ◄──────────────► │  被控端 Agent │
│ 桌面/移动/H5  │                  │  FastAPI+sqlite  │                  │  Python       │
└──────────────┘                  └─────────────────┘                  └──────────────┘
       │                                    │                                  │
       │                                    │ TURN 凭据(HMAC-SHA1)             │
       │                                    ▼                                  │
       │                            ┌─────────────┐                            │
       └────── P2P 媒体（WebRTC）──────│  coturn     │◄──── 中继兜底 ─────────────┘
                                    │ 3478/49160+ │
                                    └─────────────┘
```

### 2.2 三条链路

| 链路 | 协议 | 现状 | 用途 |
|---|---|---|---|
| **控制面** | HTTPS POST/GET `/api/v1/*` | ✅ 已实现 | 登录/设备/房间/RPC |
| **信令** | WSS `/ws/signaling?token=&device_id=` | ✅ 已实现 | 房间广播、输入事件、控制指令、SDP/ICE 交换 |
| **媒体** | WebRTC：H.264 + SRTP/UDP（ICE/DTLS） | ✅ 已落地，待真机/公网验证 | 屏幕帧传输 |

> **已解决（原 P0-2）**：媒体不再和信令挤在同一条 TCP 连接上。画面走 SRTP/UDP，丢包只影响画面、不再队头阻塞输入指令。
> 老通路（`FRM1 + JPEG` over WS 二进制帧）保留为**兜底**：Agent 无 aiortc 或协商失败时自动回落。
> 协议契约见 `docs/media-protocol.md`。

### 2.3 部署拓扑

```
VPS
├─ uu-api   (FastAPI, 8443/tcp, TLS)
├─ coturn   (3478/udp+tcp, 49160-49200/udp, host 网络)
└─ volume uu-data → /app/data/uu.db (sqlite WAL)
```

端口只用 8443，不占 443（避免与其它站点冲突）。

> ⚠️ **TURN 运行层当前不可用**：代码层 TURN 凭据（HMAC-SHA1）与服务端算法已对齐、测试通过；但实测 coturn 的 `3478` 只绑在 `127.0.0.1` + docker 网桥地址上，**公网连不上**，中继兜底暂时无效。修复中（不在本文档范围）。P2P 直连正常的场景不受影响。

### 2.4 客户端框架策略（**已定稿：换 Flutter**）

详细论证见 `docs/客户端框架重选型-Flutter.md`。这里只放结论。

> **历史变更**：2026-11-20 前的一版结论是「保留 Electron + Capacitor，只下沉解码层」，被 owner 否决——理由是客户端**过于臃肿**（Electron 实测：dmg 120MB、`.app` 解压后 274MB、常驻 90–450MB、冷启动 1–3s）。该结论已作废，旧文档 `docs/客户端全端技术选型.md` 仅保留平台能力矩阵作为参考。

**结论：控制端框架换 Flutter（五端一套），服务端与被控端不变。**

#### 为什么换（硬指标）

| 框架 | 安装包 | 空闲内存 | 冷启动 |
|---|---|---|---|
| **Electron**（当前） | 120 MB（dmg）/ **274 MB**（`.app` 解压） | 90–450 MB | 1–3 s |
| **Flutter**（目标） | 18–60 MB | 45–90 MB | 0.5–1 s |
| Tauri 2 | 3–30 MB | 25–60 MB | 0.3–0.8 s |
| Qt 6 | 20–80 MB | 35–100 MB | 0.2–0.8 s |

差距是数量级的（解压后 274 MB 对 Flutter 的 18–60 MB，约 5–15 倍），**不是优化能解决的，必须换**。

#### 目标架构

```
┌──────────────────────────────────────────────┐
│ Flutter UI（Dart，五端一套）                   │
│  登录 / 设备列表 / 远控页 / 工具栏 / 设置       │
├──────────────────────────────────────────────┤
│ 信令层（dart:io WebSocket，协议照搬现有）        │
├──────────────────────────────────────────────┤
│ 渲染桥：Texture(textureId)                     │
├──────────────────────────────────────────────┤
│ 解码：flutter_webrtc（三端内建解码）            │
└──────────────────────────────────────────────┘
```

#### 各端渲染路径（性能关键路径）

| 端 | 路径 | 绝对不能用的做法 |
|---|---|---|
| 桌面 | `media_kit`(libmpv 硬解) 或 FFI+ffmpeg → `Texture` | ❌ 每帧 `Image.memory`（Dart 层拷贝，1080p30 会卡） |
| Android | `MediaCodec`(output surface) → `SurfaceTexture` → `TextureRegistry` → `Texture` | ❌ `ImageReader` + Bitmap 中转 |
| iOS | `VTDecompressionSession` → `CVPixelBuffer` → `CVMetalTextureCache` → `FlutterTexture` | ❌ `UIImage`/`CIImage` 中转 |

**`Texture` 的关键**：像素数据全程留在原生/GPU 侧，只把 `textureId` 传给 Dart，无逐帧拷贝。这是 `flutter_webrtc` 的生产级做法。

> **ADR-8 后简化**：`flutter_webrtc` 已自带上表三端的 Texture 路径，P0-4 的原生插件（Android `MediaCodec` / iOS `VTDecompressionSession`）**不用自己写**，接 `RTCVideoRenderer` → `Texture` 即可。

#### 为什么是 Flutter，不是 Tauri / Qt / 原生

| 候选 | 判断 |
|---|---|
| **Tauri 2** | 最轻（3–30MB），但 **Linux 用 WebKitGTK，WebCodecs 不全 + GPU 路径弱**；视频仍须原生 overlay（`NSView`/`HWND`/`Surface`），等于「Tauri 外壳 + 原生视频窗口」，**架构比 Flutter 更复杂**。除非只做 Win+macOS，否则不选 |
| **Qt 6** | 性能天花板、`QVideoSink` 直通，但 LGPL/商业授权风险 + C++/QML 开发效率低 + 移动端体验落后。个人项目不划算 |
| **原生五套** | 性能最优，维护成本 ×5，个人项目不可行 |
| **Flutter** | 体积/内存可接受（比 Electron 小 4–5 倍），五端官方支持，自绘引擎渲染一致，`Texture` 零拷贝路径成熟 → **唯一同时满足「不臃肿」和「五端一套」的选项** |

#### 对现有代码的影响

| 资产 | 处置 |
|---|---|
| `srv2/server.py`、`srv2/control.html` | **不动**（服务端与框架无关；信令复用，见 `docs/media-protocol.md`） |
| `agent/agent.py` | **只改媒体出口**（加 aiortc / `ScreenTrack`，JPEG 保留兜底），输入/房间/关机逻辑不动 |
| WS 协议 / 房间契约 / 输入事件格式 | **完全复用**，Dart 侧照搬 |
| `client-desktop/`（Electron） | 迁移完成后归档，保留一版作参照 |
| `client-mobile/`（Capacitor） | 迁移完成后删除 |

> **关键**：换框架只换控制端 UI 层，**服务端一行不用改**；被控端只因 ADR-8（换媒体传输）而改媒体出口，其余不动。

---

## 3. 代码地图

```
remote-desktop/
├── srv2/                        ★ 服务端（生产入口）
│   ├── server.py      798 行    全部接口 + 信令中继 + 控制页/管理页
│   ├── control.html    23K      手机端控制页（单文件，免构建）
│   ├── tests.py        9.3K     34 项集成测试
│   ├── tests_regression.py 9.2K 23 项回归测试（重启/越权/房间清理）
│   ├── Dockerfile / docker-compose.yml / entrypoint.sh
│   ├── deploy.sh                 VPS 一键部署
│   └── run.sh                    本地起服务 + mitmproxy 改写（真机联调）
│
├── agent/
│   └── agent.py       358 行    ★ 被控端（mss 截屏 + pyautogui 注入 + aiortc 推流）
│
├── client-desktop/     ★ 桌面客户端（Electron 33）
│   ├── main.js        151 行    主进程：拉起 agent 子进程、IPC、窗口
│   ├── preload.js      17 行    contextBridge 暴露 rd-session
│   ├── web/index.html            ⚠️ **生成产物**（`scripts/sync-web.js` 输出，已 gitignore，别直接改）
│   ├── scripts/sync-web.js      构建前把 web/ 同步到打包目录
│   └── package.json             electron-builder 配置（mac/win/linux）
│
├── client-mobile/      ★ 移动端（Capacitor 6.2）
│   ├── www/index.html 21K       H5 资源（与 desktop/web 基本同源）
│   ├── android/ ios/             原生壳（**当前无原生插件**）
│   └── capacitor.config.json
│
├── tools/
│   └── e2e_proxy_test.py        真实 TLS + 自建 CA + 代理端到端验证
│
├── proxy/
│   └── addon_uuyc.py            mitmproxy 改写：*.nrd.nie.163.com → 本地服务端
│
├── docs/                        ★ 项目文档（⚠️ 见下方提示：当前未入 git）
│   ├── 客户端框架重选型-Flutter.md  ★ 当前结论（Flutter）
│   ├── 客户端全端技术选型.md        ⚠️ 结论已作废，仅留平台能力矩阵参考
│   ├── media-protocol.md          ★ 媒体通道契约（WebRTC，FROZEN v1）
│   ├── 媒体链路实测.md            PSNR/带宽/每帧大小实测对比
│   └── reverse/                 官方技术解剖（4 md + 3 数据文件，只读参考）
│
├── packaging/                   打包脚本
├── dist/                        产物（uu-agent 26M / uu-server 21M）
└── .github/workflows/build.yml  四平台构建 + 测试门禁
```

> **迁移完成后**新增 `client-flutter/`（五端），`client-desktop/` 归档，`client-mobile/` 删除。

> ⚠️ **文档尚未入库**：`HANDOFF.md` 与 `docs/`（含 `docs/reverse/`、`docs/media-protocol.md`）目前**不在 git 仓库中**——clone 下来看不到这些文件。移交前必须 `git add` 提交，否则接手人拿到的仓库是「无文档」状态。见 §13。

---

## 4. 已实现能力清单

### 4.1 服务端 HTTP API（30 个路由）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 健康检查 |
| POST | `/api/v1/login/by_mobile` | 手机号登录（同号复用 uid，换发 token） |
| POST | `/api/v1/login/by_qrcode` | 扫码登录 |
| POST | `/api/v1/qrcode/gen/login` | 生成扫码会话 |
| POST | `/api/v1/qrcode/login/status` | 轮询扫码状态 |
| POST | `/api/v1/user/info` · `/user/logout` | 用户信息 / 登出 |
| POST | `/api/v1/tool/fp/token` | 指纹 token |
| POST | `/api/v1/device/{android,android_tv,pc,mobile}/init` | 四平台设备注册（含 device_id 冲突保护） |
| POST | `/api/v1/device/list` · `/rename` · `/delete` | 设备列表（含在线态）/ 改名 / 删除 |
| POST | `/api/v1/room/create` | 建房（复用该设备未关闭房间） |
| POST | `/api/v1/room/join/by_device/{device_id}` | 按设备加入 |
| POST | `/api/v1/room/join/refetch` | 重取房间配置 |
| POST | `/api/v1/room/clear/{room_id}` | 关闭房间 |
| GET | `/api/v1/room/list` | 未关闭房间 |
| POST | `/api/v1/transport/{device_id}/rpc/request` | 下发调用，阻塞等应答（默认 30s） |
| GET | `/api/v1/transport/{device_id}/rpc/poll` | 被控端取任务 |
| POST | `/api/v1/transport/{device_id}/rpc/respond` | 被控端应答 |
| GET | `/api/v1/transport/{device_id}/queue` | 队列排障 |
| WS | `/ws/signaling` | 信令中继（text/binary 原样转发，房间隔离） |
| GET | `/control` · `/admin` | 手机控制页 / 管理页 |
| GET | `/debug/capture` | 最近抓取的原始请求 |
| ANY | `/api/{path}` | **兜底**：抓报文 + 回 `{"code":0,"data":null}` |

> 兜底路由很关键：官方客户端调用未实现接口时不会断链，报文落在 `/debug/capture`，可按真实报文补齐契约。

### 4.2 响应格式约定
```json
{"code": 0, "msg": "", "data": {...}}
```
`code != 0` 为业务错误。所有接口统一这个信封（`envelope()`）。

### 4.3 房间配置（对齐官方 `RoomConfig` 契约）
`room_config()` 返回字段（服务端 `server.py:208`）：
```
signaling_server / token / signaling_list / ws_connect_timeout_ms
streamer_retry_delta_ms / max_reconnect_delta
report_token / report_url / report_server_address
international_connect / sni_required_signaling_list
streamer_config(JSON字符串: ice_servers + ice_transport_policy + max_bitrate_kbps + prefer_hardware)
room_id / ice_servers
```
> 这组字段与官方 `StreamerManager loginRoomWithToken:serverList:sniRequiredServerList:streamerConfig:connectTimeout:reconnectDelay:reportToken:reportUrl:reportServerAddress:` 参数一一对应，是逆向确认的契约（见 §6 文档 A2）。

### 4.4 Agent 能力
| 能力 | 实现 |
|---|---|
| 截屏 | `mss`，主屏，变化检测（md5 采样 `[::997]`），未变则跳过（2s 保活一帧） |
| 媒体主通路 | **WebRTC**（aiortc，H.264 + SRTP/UDP），信令复用 WS（见 `docs/media-protocol.md`） |
| 媒体兜底 | JPEG，`subsampling=2`(4:2:0)，quality 可调；`b"FRM1" + 8字节大端毫秒时戳 + JPEG` |
| 缩放 | 最大宽度限制（默认 1920），BILINEAR |
| 背压 | 队列 `maxsize=1`，发不完丢旧帧（永远发最新画面） |
| 输入注入 | `pyautogui`，**归一化坐标 0..1** |
| 中文输入 | 走剪贴板粘贴（`pbcopy`/`Set-Clipboard` + 粘贴快捷键） |
| 关机 | 30s 倒计时可撤销，每秒广播剩余秒数 |
| 动态调参 | `stream.config`（fps 1-30 / quality 30-90 / width 640-3840 / bitrate kbps 可选） |
| 重连 | 断链 5s 重试，复用 `LAST_DEVICE` 避免堆重复设备 |

### 4.5 WS 消息（`p` 字段路由）

| 消息 | 方向 | 说明 |
|---|---|---|
| `agent.hello` | Agent → 客户端 | 设备名、系统、屏幕尺寸、stream 配置、`media`（`webrtc`/`jpeg`） |
| `peer.join` | 服务端 → Agent | 新控制端进房，触发重发 hello |
| `input` | 客户端 → Agent | 输入事件（见 §5.3） |
| `stream.pause` / `stream.resume` | 客户端 → Agent | 暂停/恢复推流 |
| `stream.config` | 客户端 → Agent | 动态调参（含可选 `bitrate`） |
| `stream.config.ack` | Agent → 客户端 | 参数确认（含生效 `media` / `bitrate`） |
| `rtc.offer` / `rtc.answer` / `rtc.ice` / `rtc.close` | 双向 | WebRTC 信令，服务端原样透传（见 `docs/media-protocol.md`） |
| `shutdown` | 客户端 → Agent | 关机（`cancel` 撤销 / `delay` 秒数） |
| `shutdown.state` | Agent → 客户端 | `pending`(带 remain) / `executing` / `cancelled` |
| `ping` / `pong` | 双向 | 心跳 / 单向延迟测量 |
| `agent.error` | Agent → 客户端 | 单事件异常（不断链） |

### 4.6 客户端 UI（桌面 + 移动）

**桌面（Electron）**
- 登录 → 设备列表 → 点设备进远控（WebRTC 通时走 `<video>`；回落时 canvas 2D）
- 底部工具栏：画质（流畅 1280,55/4000 / 高清 1920,75/8000 / 超清 2560,80/20000，末位为 kbps）、键盘、Ctrl→⌘ 映射、复制/粘贴/切窗/桌面、右键、关机、返回
- 内置 Agent 状态机：`off / starting / running / error`，异常退出 5s 自动重启

**移动（Capacitor 6.2）**
- `client-mobile/www/index.html`（21K 单文件 H5）+ `android/` `ios/` 原生壳
- **当前无任何原生插件**，纯粹是 WebView 装 H5 → 渲染性能受限
- 迁移 Flutter 后由 `flutter_webrtc` 的 Texture 路径接管解码（ADR-8，原 P0-4 不必自写插件）
- `www/` 与 `client-desktop/web/` 内容基本同源（`scripts/sync-web.js` 同步），改 UI 时注意两处一致

### 4.7 测试
```bash
cd srv2
python tests.py                # 34 项：WS 二进制转发、RPC 双向、房间隔离、TURN 凭据算法
python tests_regression.py     # 23 项：重启后房间可连、RPC 不阻塞信令、越权防护
python ../tools/e2e_proxy_test.py   # 真实 TLS + CA + 代理端到端
```

---

## 5. 现有协议规范

### 5.1 鉴权
```
Authorization: Bearer <token>
```
Token 由登录接口签发，WS 通过 query 参数 `?token=&device_id=` 传入。

### 5.2 房间与信令
- WS 按 `room_id` 分组，跨房间不串帧
- text 帧：JSON（`p` 字段路由）；**WebRTC 的 SDP/ICE 也走这里**，服务端仅透传
- binary 帧：原样转发（仅 JPEG 兜底通路使用）
- 子协议回显（`Sec-WebSocket-Protocol`）

### 5.3 输入事件格式（客户端 → Agent）
```json
{"p":"input","t":"move","x":0.512,"y":0.334}
{"p":"input","t":"down","x":0.512,"y":0.334,"btn":"left"}
{"p":"input","t":"up","x":0.512,"y":0.334,"btn":"left"}
{"p":"input","t":"click","x":0.5,"y":0.5,"double":false,"btn":"left"}
{"p":"input","t":"scroll","dy":-3}
{"p":"input","t":"keydown","k":"shift"}
{"p":"input","t":"keyup","k":"shift"}
{"p":"input","t":"key","k":"enter"}
{"p":"input","t":"key","combo":["ctrl","c"]}
{"p":"input","t":"text","v":"中文内容"}
```
**坐标一律归一化 0..1**，Agent 侧按实际分辨率换算 —— 这样换屏/换分辨率不用改协议。

### 5.4 媒体帧格式

**主通路（WebRTC）**：H.264 编码进 SRTP/UDP，帧格式由 RTP 承载，**不再自定义包头**。协商与参数见 `docs/media-protocol.md`。

**兜底通路（JPEG over WS）**：
```
+--------+------------------+------------------+
| "FRM1" | 8B 大端毫秒时戳   | JPEG 数据         |
+--------+------------------+------------------+
   4B            8B             变长
```
时戳用于控制端计算单向延迟。仅在 `media: "jpeg"`（Agent 无 aiortc / 协商失败）时使用。

---

## 6. 参考基线（逆向分析资料）

这四份文档是官方的技术解剖，**做设计决策前先查这里**，能省大量试错。
路径：本项目 `docs/reverse/`（已归档；⚠️ 当前未入 git，见 §3 提示）

| 文档 | 内容 | 什么时候看 |
|---|---|---|
| `UU远程-远控核心全量技术分析.md` | 引擎 SDK 全签名、193 个 Protobuf 消息、双栈传输、编解码矩阵、音频链、安全体系 | **主力参考**，做协议/媒体/安全时必看 |
| `UU远程-远程功能与UI设计还原.md` | 远程功能实现方案 + UI 设计规范（工具栏结构、面板、设计 token、快捷键体系） | 做 UI 时必看 |
| `UU远程-功能逆向分析报告.md` | 模块结构、62 项功能开关、63 个 API 端点、架构总览 | 查功能全貌、找还缺什么 |
| `官方付费墙地图与自研实现路径.md` | 18 项付费能力的技术拆解与实现难度分级 | 规划新功能时评估成本 |
| `pb-messages.txt` | 193 个 Protobuf 消息名清单 | 设计自己协议时的命名参考 |
| `zh-strings.json` | 1809 条官方界面文案 | 写 UI 文案时抄（比自己编好） |
| `assets-names.txt` | 719 个资源名（颜色 token + 图标命名） | 做设计系统时参考 |

以上在 `docs/reverse/`（已归档；⚠️ 当前未入 git，见 §3 提示）。

**本项目自建文档（不是逆向资料）**：

| 文档 | 内容 | 什么时候看 |
|---|---|---|
| `docs/客户端框架重选型-Flutter.md` | **当前有效结论**：为什么换 Flutter、硬指标对比、Texture 零拷贝路径、四阶段迁移 | **动客户端前必看** |
| `docs/客户端全端技术选型.md` | ⚠️ **结论已作废**（Electron 方案被否）；但 §1 性能归因、§2 平台能力矩阵仍有效 | 查平台 API 能力时看 |
| `docs/media-protocol.md` | **媒体通道契约（FROZEN v1）**：`agent.hello.media`、`rtc.offer/answer/ice/close`、清晰度参数、降级规则 | **改媒体/渲染代码前必看** |
| `docs/媒体链路实测.md` | JPEG vs H.264 的 PSNR/每帧大小/带宽实测对比与测试方法 | 调码率、质疑画质时看 |
| `HANDOFF.md`（本文） | 交接总览 | 入门第一份 |

### 官方架构对照（关键差异）

| 维度 | 官方 | 本项目现状 | 差距 |
|---|---|---|---|
| 进程模型 | UI / Agent / Daemon 三进程 + XPC | 单进程 Agent | 中 |
| 登录窗口级运行 | ✅ `LimitLoadToSessionType=LoginWindow` | ❌ | **大**（开机未登录时控不了） |
| 媒体传输 | WebRTC(SRTP) + QUIC(ngtcp2/BBR) 双栈 | **WebRTC(SRTP)** ✅；QUIC 无极 | 小（单栈够用） |
| 编码 | H.264/H.265 硬编（VT/NVENC/AMF/QSV） | H.264 软编（aiortc 内置 OpenH264，`ScreenTrack` 出 I420） | 中（缺硬编） |
| 控制协议 | Protobuf（193 消息） | JSON | 中 |
| 多轨道 | videoTrackIndex / audioTrackIndex | 单流 | 中 |
| 虚拟屏 | IDD / CGVirtualDisplay | ❌ | 大（成本高） |
| **客户端框架** | 原生 SwiftUI/AppKit | Electron → **迁移 Flutter 中** | 中（**已决策换 Flutter**，见 §2.4） |
| **移动端渲染** | 原生解码直通 | WebView canvas | 大（P0-2/P0-3 待做） |

---

## 7. 技术债务与已知问题

| # | 问题 | 严重度 | 影响 | 建议 |
|---|---|---|---|---|
| 1 | **客户端框架臃肿**（Electron 120MB dmg / 274MB 解压 / 90–450MB 内存） | **致命** | 产品形态不可接受 | **见 P0-1（换 Flutter）** |
| 2 | 媒体走 TCP(WS) | ~~致命~~ → 已解决 | 丢包→队头阻塞→延迟飙积累 | **WebRTC 方案已落地，待真机验证**（ADR-8） |
| 3 | JPEG 编码 | ~~高~~ → 已解决 | 带宽是 H.264 的 3-5 倍 | **WebRTC 方案已落地**：H.264 8Mbps ≈ 旧高清档 1/3.5 带宽（ADR-8） |
| 4 | 桌面用 canvas 2D `drawImage` 渲染 | ~~高~~ → 已解决 | CPU 拷贝，1080p60 吃 30% CPU | **WebRTC 方案已落地**：`<video>` / Flutter `Texture`（ADR-8） |
| 5 | 移动端零原生插件 | ~~高~~ → 部分消解 | WebView 解码性能受限，iOS 旧版 WebCodecs 不可用 | **WebRTC 方案已落地**：`flutter_webrtc` Texture 路径，待真机验证 |
| 6 | 无音频 | 高 | 只有画面没声音 | 见 P1-3 |
| 7 | 单屏 | 中 | 多显示器用户只能看主屏 | 见 P1-4 |
| 8 | 无剪贴板同步 | 中 | 只能靠 `text` 事件单向粘贴 | 见 P1-5 |
| 9 | 无文件传输 | 中 | 传文件得走别的工具 | 见 P2-1 |
| 10 | 输入无修饰键状态机 | 中 | 长按 Shift 多选等场景不灵 | 见 P1-6 |
| 11 | Agent 单进程无提权 | 中 | macOS 锁屏界面无法被控 | 见 P1-1 |
| 12 | 无端到端加密 | ~~中~~ → 已解决 | 目前靠 TLS，P2P 后需 DTLS/SRTP | **WebRTC 自带 DTLS-SRTP**，媒体已端到端加密 |
| 13 | 单一 WebSocket 承载全部 | ~~中~~ → 已解决 | 大帧会阻塞控制指令 | 媒体已拆到 SRTP/UDP，WS 只剩信令 |
| 14 | `www/` 与 `client-desktop/web/` 双份 UI | 低 | 改一处忘另一处 | 迁移 Flutter 后自然消失 |
| 15 | 无重连画面恢复 | 低 | 断线后要等新关键帧 | WebRTC 重协商 + 回落 JPEG 已覆盖；弱网恢复仍待验证 |
| 16 | **aiortc 码率上限绕过依赖私有字段** | 中 | `_H264Encoder__target_bitrate` 属内部实现，升级 aiortc 后字段改名会静默失效 → 码率掉回 1Mbps、画质变糊 | 升级 aiortc 时必须复核 `agent/webrtc_media.py` 的 watchdog；长期改为上游暴露正式 API 或自行替换编码器 |

> 注：Electron / Capacitor 的"双份 UI"和"WebView 渲染"问题，会随 **P0-1 框架迁移** 一并消失，不需要单独修。
> 第 2–5 条已由 **ADR-8（媒体传输改 WebRTC）** 覆盖，剩余工作是**真机/公网验证**，不要再按原计划自研 UDP 包格式或写原生解码插件。

---

## 8. Backlog（按优先级，含验收标准）

### P0 — 必须做（顺序别乱）

> ⚠️ **2026-11-20 重要修订（先读这段，别重复劳动）**
> - **P0-2**（自研 UDP 包格式）→ **已被 ADR-8 取代**：媒体改走 **WebRTC**，拥塞控制/NACK/FEC/抖动缓冲由 WebRTC 自带，不再自研 seq/ts/flags/frag。
> - **P0-3**（H.264 + Texture）→ **已随 ADR-8 落地**：Agent 侧 aiortc 出 H.264，控制端 `<video>`（Web）/ `flutter_webrtc` `Texture`（Flutter）。
> - **P0-4**（移动端原生解码插件）→ **被 `flutter_webrtc` 部分消解**：Texture 路径已由插件提供，不必自己写 `MediaCodec`/`VTDecompressionSession` 插件。
> - 以下 P0-2/3/4 原文**保留**用于追溯设计意图，但**不要照着做**。

#### P0-1 控制端框架迁移到 Flutter
**为什么**：Electron 实测 120MB(dmg) / 274MB(`.app` 解压)、常驻 90–450MB、冷启动 1–3s，对远控工具不可接受。这是**产品形态问题**，优化解决不了。

**做法**（详见 `docs/客户端框架重选型-Flutter.md`）：
1. `flutter create --platforms=windows,macos,linux,android,ios`
2. UI 翻译：`client-desktop/web/index.html` → Flutter widget
   - 登录页 → `TextField` + `Button`
   - 设备列表 → `ListView.builder`
   - 远控页 → `Stack(Texture, 工具栏 overlay)`
3. 信令用 `dart:io` WebSocket 重写（**协议不变**，JS 对象 → Dart `Map`）
4. ~~先用「JPEG → `Image.memory`」跑通链路~~ → **跳过**：媒体已由 ADR-8 走 WebRTC，直接接 `RTCVideoRenderer` → `Texture`
5. 跑通后进 P0-3 换低延迟渲染（注：P0-3 已随 ADR-8 落地，见上方修订提示）

**验收**：
- [ ] 五端能登录、看画面、发输入
- [ ] 桌面安装包 < 60MB，移动 < 25MB
- [ ] 空闲内存 < 100MB
- [ ] 冷启动 < 1s（桌面）/ < 1.5s（移动）

#### P0-2 媒体链路分离 + UDP 传输  ⚠️ **已被 ADR-8 替代（勿按原文实施）**
**为什么**：TCP 上跑实时视频是根本性错误。丢一个包，后续所有帧都要等重传，延迟会累积到不可用。

> 实际做法：改用 **WebRTC**（H.264 + SRTP/UDP + ICE/DTLS），信令复用现有 WS 透传，服务端零改动。下面的自研包格式方案作废。

**做法**：
1. WS 只保留信令（输入、控制指令、心跳）
2. 媒体走 UDP：自研轻量包格式
   ```
   seq(4B) | ts(8B) | flags(1B: keyframe/frag) | fragIdx(2B) | fragTotal(2B) | payload
   ```
3. Agent 监听 UDP 端口，客户端通过 ICE 候选（已有 TURN 凭据）打洞
4. 打洞失败 → 回落 WS 分片（保底可用）
5. 加 NACK（丢包重传）+ 简单码率反馈

**验收**：
- [ ] 局域网 1080p@30 延迟 < 50ms（当前约 100-150ms）
- [ ] 弱网（5% 丢包）下画面不冻结，只降质量
- [ ] 拔网线 5s 内自动重连并恢复画面
- [ ] 信令不受大帧影响（输入响应 < 30ms）

#### P0-3 H.264 编码 + Texture 零拷贝渲染  ✅ **已随 ADR-8 落地**
**做法**（已完成，保留供参考）：
- Agent：`openh264`（pip 可装）或 `ffmpeg -f rawvideo` 管道，I420 输入
- 关键帧间隔 2s，关闭 B 帧（降低延迟）
- **桌面**：先用 `media_kit`（libmpv 硬解，低延迟模式）；不达标再自行 FFI + ffmpeg → `Texture`
- **移动**：见 P0-4
- 解码队列深度限制 2–3 帧，超出丢帧
- 保留 JPEG 作为兜底

> ⚠️ **禁止**每帧走 `Image.memory` / `ui.decodeImageFromList` —— 那是 Dart 层解码 + 拷贝，1080p30 直接卡死。必须走 `Texture`。

> **实际实现（与上面计划不同）**：Agent 用 aiortc 内置 OpenH264（`ScreenTrack` 出 I420，关 B 帧）；控制端 Web 用 `<video>`、Flutter 用 `flutter_webrtc` 的 `Texture`。`media_kit` / 自建 FFI 方案**未采用**。

**验收**：
- [ ] 1080p@30 带宽 < 8Mbps（当前 JPEG 约 20-30Mbps）
- [ ] 首帧 < 500ms
- [ ] 静止画面带宽接近 0
- [ ] 1080p60 解码渲染 CPU < 25%

#### P0-4 移动端原生解码插件（Android + iOS）  ⚠️ **已被 `flutter_webrtc` 部分消解（不必自写）**
**为什么**：移动端要 1080p 低延迟，解码必须下沉到系统硬解器，走 Flutter `Texture`。

> `flutter_webrtc` 已内建 `TextureRegistry`（Android）/ `FlutterTexture`（iOS）路径，接 `RTCVideoRenderer` 即可拿到 `textureId`。**只有**在该插件性能不达标时，才回落到下面自写插件的方案。

**做法**：
1. 写 Flutter 插件（Android Kotlin / iOS Swift），实现 `FlutterTexture` 协议
2. **Android**：`MediaCodec.configure(format, surface, …)` 直接输出到 `SurfaceTexture` → 注册到 `TextureRegistry` → 把 `textureId` 回传 Dart
3. **iOS**：`VTDecompressionSession` → `CVPixelBuffer` → `CVMetalTextureCache` → 实现 `FlutterTexture.copyPixelBuffer` 回传
4. Dart 侧 `Texture(textureId: id)` 直接合成

**验收**：
- [ ] 1080p@30 延迟 < 50ms
- [ ] CPU < 30%（中端机）
- [ ] iOS 15+ 可运行（不依赖 Safari 26）
- [ ] 无 `ImageReader`/`UIImage`/`ui.Image` 中转（校验零拷贝）

### P1 — 可用性补全（2-4 周）

| # | 任务 | 验收标准 |
|---|---|---|
| P1-1 | macOS 登录窗口级运行（LaunchAgent + `LimitLoadToSessionType=LoginWindow`） | 重启 Mac 未登录时，另一端能看到登录界面 |
| P1-2 | 三档鼠标模式（主控端/被控端/智能） | 设置项可切换，被控端模式光标跟随系统 |
| P1-3 | 音频（Opus + 系统声采集） | 能听到被控端声音，延迟 < 200ms |
| P1-4 | 多屏枚举与切换 | 能列出全部显示器并切换，工具栏显示当前屏 |
| P1-5 | 剪贴板双向同步 | 文本双向，去重，方向可配（跟随本地/远程） |
| P1-6 | 输入修饰键状态机 | Shift 多选、Ctrl 滚轮等组合操作正常 |
| P1-7 | 画质面板（对齐官方 6 档 + 帧率 30/60/90/144） | UI 见逆向文档 B2.2 |
| P1-8 | 连接信息面板（延时/丢包/带宽/编解码） | 28 字段，见逆向文档 B3 |

### P2 — 协作能力（按需）

| # | 任务 | 备注 |
|---|---|---|
| P2-1 | 文件传输（块传输 + 断点续传） | 协议参考逆向文档 B6（24 消息） |
| P2-2 | 剪贴板文件/图片 | 参考 B5（15 消息） |
| P2-3 | 屏幕批注 | 纯前端 canvas + 坐标同步，成本低收益高 |
| P2-4 | 远程终端（pty + tmux + xterm.js） | 参考 A7 |
| P2-5 | 隐私屏保（全屏图覆盖） | 成本极低（半天），安全感知强 |
| P2-6 | 观看模式（只渲染不收输入） | 一个开关，防误触 |
| P2-7 | 端口映射 | 参考 A9 |
| P2-8 | 虚拟屏 / 超级屏 | **成本最高**（Windows 要写 IDD 驱动），最后做 |

### 明确不做
HDR、真彩、超分、无线副屏、MuMu 联动、云电脑、会员体系。
（理由见 `官方付费墙地图与自研实现路径.md` §三难度表）

---

## 9. 关键设计决策记录（ADR）

### ADR-1 为什么媒体先走 WS 而不是一步到位 UDP
**当时**：优先验证「控制面能不能完全替代官方」，把链路跑通比性能重要。
**代价**：现在必须重构成 UDP。
**结论**：这个取舍是对的（先证明可行性），但不要在此基础上加功能，先重构。
**后续（2026-11-20）**：重构已完成，但**不是自研 UDP 包格式**，而是改用 WebRTC —— 见 ADR-8。

### ADR-2 为什么用 JSON 而不是 Protobuf
**理由**：调试直观、无需 .proto 编译、Python/JS 双侧零成本。
**代价**：体积大 30-50%，无 schema 校验。
**建议**：媒体通道定型后，考虑把高频消息（input）换成 MessagePack 或 Protobuf，低频保持 JSON。

### ADR-3 为什么 Agent 用 Python
**理由**：mss/pyautogui 跨三平台开箱可用，开发速度最快。
**代价**：启动慢（PyInstaller 打包 26M）、CPU 效率不如 C++/Rust、需要目标机装运行环境（打包后免）。
**建议**：媒体编码走 C 扩展（openh264），Python 只做编排。

### ADR-4 为什么坐标用归一化 0..1
**理由**：换分辨率/多屏切换时协议不变，控制端不用知道被控端真实分辨率。
**这是好决策，保持。**

### ADR-5 为什么房间 create 复用未关闭房间
**理由**：断线重连时回原房间，避免每次重连产生新房间。
**注意**：多控制端场景要改（见 P1 多主控端）。

### ADR-6 为什么 daemon 化没做
**理由**：macOS 需要 LaunchAgent + 权限提升，成本高，先验证主链路。
**代价**：现在**未登录状态无法被控**，这是相比官方最大的体验缺口（官方 `agent.plist` 用 `LimitLoadToSessionType=LoginWindow` 解决）。

### ADR-7 为什么控制端换 Flutter（并附带记录一次结论反转）

**最终决策**：控制端从 Electron + Capacitor **迁移到 Flutter**（五端一套）。服务端与被控端不动。

**理由（硬指标）**：

| 框架 | 安装包 | 空闲内存 | 冷启动 |
|---|---|---|---|
| Electron | 120 MB（dmg）/ **274 MB**（`.app` 解压） | 90–450 MB | 1–3 s |
| Flutter | 18–60 MB | 45–90 MB | 0.5–1 s |
| Tauri | 3–30 MB | 25–60 MB | 0.3–0.8 s |

差距是数量级的，属于**框架固有属性，优化无法解决**。对一个常驻的远控客户端，解压后 274MB + 90–450MB 内存不可接受。

**Flutter 胜过 Tauri 的关键**：
- Tauri 的 Linux 用 WebKitGTK（WebCodecs 不全、GPU 路径弱）；视频仍须原生 overlay（`NSView`/`HWND`/`Surface`），变成「Tauri 外壳 + 原生视频窗口」，**架构比 Flutter 复杂**
- Flutter 的 `Texture` widget 是**官方级**的外部纹理通道，`flutter_webrtc` 已用此路径跑生产，零拷贝方案成熟

**代价（必须承认）**：
- UI 从 HTML 重写为 Dart（3–5 天）
- ~~要写两套原生解码插件（Android Kotlin / iOS Swift，2–3 周）~~ → **已被 ADR-8 消解**：`flutter_webrtc` 自带 Texture 路径，不用自写（省 2–3 周）
- Dart 学习成本（前端背景上手快）

**结论反转记录（重要，供后人参考）**：
> 2026-11-20 初版 ADR-7 的结论是「**不换框架**」，论据是「端到端延迟 95% 来自传输，UI 框架只占 2–5ms」。
>
> **这个论证本身没错，但它回答错了问题** —— owner 关心的是**产品形态（臃肿）**，不只是延迟。框架的体积和内存是固有属性，换传输协议解决不了。
>
> 教训：选型时不能只盯一个指标（延迟），要同时评估**产品形态约束**（体积/内存/启动）。

**复核条件**：若 Flutter 桌面端 1080p60 下 CPU 超 40%，说明解码路径不合适（当前为 `flutter_webrtc` 的 Texture，见 ADR-8；原 `media_kit` 方案未采用），改为自行 FFI 调 ffmpeg 输出到 `Texture`。

详见 `docs/客户端框架重选型-Flutter.md`。

### ADR-8 媒体传输从「自研 UDP 包格式」改为 WebRTC

> 状态：**已落地**（2026-11-20）　契约：`docs/media-protocol.md`（FROZEN v1）　实测：`docs/媒体链路实测.md`

**Context（当时的计划）**
原 P0-2 打算自研一套 UDP 媒体协议，只做「够用」的那部分：

```
seq(4B) | ts(8B) | flags(1B: keyframe/frag) | fragIdx(2B) | fragTotal(2B) | payload
```

配套 NACK（按 seq 请求重传）+ 一个简单码率反馈环，打洞失败回落 WS 分片。
出发点没错——TCP 上跑实时视频是根本性错误（丢包 → 队头阻塞 → 延迟累积）。但把这套东西做**对**，需要的是：

- 拥塞控制（丢包/延迟双信号，避免把链路打爆又不敢提码率）
- 带宽估计（GCC/TWCC 一类，否则码率只能拍脑袋）
- NACK + FEC + 抖动缓冲 + 乱序重组 + 关键帧请求
- 自适应分辨率/帧率的降级策略

这每一块都是**月级**工作量，而且是「做得出来但做不好」的典型——写完能跑，弱网就露馅。

**Decision（决定）**
媒体传输改用 **WebRTC**：

| 层 | 选型 |
|---|---|
| 编码 | H.264（Agent 侧 aiortc 内置 OpenH264，`ScreenTrack` 出 I420，关 B 帧/zerolatency） |
| 传输 | SRTP over UDP（DTLS 握手），自带拥塞控制/BWE/NACK/FEC/抖动缓冲 |
| 连接 | ICE 打洞，STUN/TURN 复用服务端已下发的 `ice_servers` 凭据 |
| 信令 | **复用现有 `/ws/signaling` 透传**：`rtc.offer` / `rtc.answer` / `rtc.ice` / `rtc.close`（JSON，走 text 帧） |
| 服务端 | `srv2/server.py` **零改动**（信令本来就是原样转发） |

`agent.hello` 增加 `media` 字段（`"webrtc"` / `"jpeg"`）供控制端选路；老 Agent 不发该字段 → 按 `jpeg` 处理，**向后兼容**。
JPEG over WS 保留为**兜底**（aiortc 缺失 / 协商失败 / `connectionState=failed` 自动回落）。

**理由（为什么值得改方向）**
1. **自研成本是月级**：拥塞控制 + BWE + NACK/FEC + 抖动缓冲，自己写要几个月，且弱网表现大概率不如 WebRTC（后者是十年积累 + 全球部署调优的结果）。
2. **顺手消掉 P0-4**：`flutter_webrtc` 的 `RTCVideoRenderer` → `Texture` 已内建 Android `TextureRegistry` / iOS `FlutterTexture` 路径，**原计划「写两套原生解码插件」的 2–3 周直接省掉**。
3. **端到端加密白送**：DTLS-SRTP，原技术债第 12 条（无 E2E 加密）一并解决。
4. **服务端零改动**：信令透传这条路本来就通，不需要新增端口/协议。

**Consequences（代价与约束，必须知道）**
- **红线冲突**：Agent 必须加 aiortc 依赖并新增媒体出口（`agent/webrtc_media.py`），与旧红线「被控端一行不改」矛盾 → 红线已修正为「**服务端一行不改；agent 只改媒体出口**」。
- **aiortc 码率上限**：默认 1 Mbps，且 `target_bitrate` setter 会把值夹到 3 Mbps。必须直接写私有字段 `_H264Encoder__target_bitrate` 绕过（`agent/webrtc_media.py` 有 watchdog 持续重设）。**这是私有实现，升级 aiortc 需复核**（已记为技术债 #16，细节见 `docs/media-protocol.md` §3）。
- **清晰度默认会变糊**：WebRTC 按「视频通话」优化，拥塞时优先降分辨率。必须显式设 `degradationPreference="maintain-resolution"` + `jitterBufferTarget=0`，并把发送码率定到 **8 Mbps**（可切 4/8/20）。
- **画质达标靠参数，不靠玄学**：本机 2048×1280 截图实测，H.264 8 Mbps 的 PSNR **45.77 dB**、38 KB/帧；旧「高清」JPEG 1920/q75 只有 37.16 dB、231 KB/帧。即**画质更好、带宽约 1/3.5**（数据见 `docs/媒体链路实测.md`）。
- **TURN 兜底暂不可用**：代码层凭据算法已对齐，但运行层 coturn 的 3478 只绑 `127.0.0.1`+docker 网桥，公网连不上（另一条线在修）。P2P 直连场景不受影响。
- **待验证**：真机（Win/macOS/Android/iOS）+ 公网 + 弱网（5% 丢包）尚未跑通，`docs/media-protocol.md` §7 的验收项仍全是未勾状态。

**复核条件**：若 aiortc 软编（OpenH264）在 1080p@30 下吃满单核，说明需要硬编/换编码器；若移动端 `flutter_webrtc` 的 Texture 路径做不到 < 50ms，才回到 P0-4 自写插件。

---

## 10. 风险与坑（血泪清单）

| # | 坑 | 现象 | 规避 |
|---|---|---|---|
| 1 | **证书与域名** | 裸 IP + 自签证书，部分手机浏览器/微信内嵌不信任 | 用域名（当前 `sslip.io` 类似方案），走标准 CA 链 |
| 2 | **macOS 权限** | 截屏/辅助功能未授权 → 黑屏或无法操作 | 启动时检测 `checkScreenRecordingPermission`，缺权限必须明确提示（官方做法：权限与「允许被控」开关强绑定） |
| 3 | **关机不可撤销** | 静默执行关机最招骂 | 已做 30s 倒计时 + 每秒广播；**任何改动不得移除撤销能力** |
| 4 | **帧堆积** | 网络慢时旧帧排队，延迟无限增长 | 已做 `maxsize=1` 丢旧帧；改 WebRTC 后仍要丢而不排队（`jitterBufferTarget=0`） |
| 5 | **指纹不一致** | Python `uuid.getnode()` 与 Node `networkInterfaces` 取到的 MAC 顺序不同 → 同一台机器注册成两个设备 | `main.js:35` 有注释说明；改动任一侧必须同步验证 |
| 6 | **token 互相顶掉** | Agent 重新登录把控制页 token 顶掉 | Agent 支持 `--token` 复用页面登录态；不要让 Agent 自己登录 |
| 7 | **RDP 会话冲突** | Windows 上远程桌面/切换用户导致画面黑 | 官方用 `Control.Error.rdp` 提示「系统会话变化」；改 agent 时要捕获并提示 |
| 8 | **UAC 安全桌面** | Windows 提权弹窗时画面黑/输入无效 | 官方有 `SecureDesktopState` 协议消息；当前实现未处理，属已知限制 |
| 9 | **中文输入** | `pyautogui.typewrite` 不支持非 ASCII | 已走剪贴板粘贴；新增输入方式时别退回 typewrite |
| 10 | **单实例锁** | 开两个客户端 → 两个 Agent 抢同一设备 | 已用 `requestSingleInstanceLock` |
| 11 | **兜底路由掩盖错误** | `/api/{path}` 回空成功，真错误被吞 | 排障必看 `/debug/capture`，不要只看响应码 |
| 12 | **TURN 凭据时效** | 凭据 24h 过期，长连接续期 | `TURN_TTL` 可配；连接超过 TTL 要重取房间配置。**另注：当前 coturn 只绑 `127.0.0.1`，公网中继不可用（修复中）** |

---

## 11. 上手步骤

### 11.1 环境
```bash
# 服务端
pip install fastapi uvicorn websockets mitmproxy cryptography
# Agent
pip install mss pillow pyautogui websockets httpx aiortc av   # aiortc/av 用于 WebRTC 媒体，缺失时自动退回 JPEG
# 桌面客户端
cd client-desktop && npm install
```

### 11.2 本地跑通（5 分钟）
```bash
# 1. 起服务端（本机，http 明文调试）
cd srv2 && python server.py
#    默认 0.0.0.0:8443

# 2. 起 Agent（连本机服务端）
cd agent
python agent.py --server http://127.0.0.1:8443 --mobile 13800000000 --name TEST-PC --insecure

# 3. 打开控制页
#    浏览器 → http://127.0.0.1:8443/control
#    登录同一手机号 → 设备列表点 TEST-PC → 看到画面
```

### 11.3 跑测试
```bash
cd srv2
python tests.py                    # 34 项
python tests_regression.py         # 23 项
python ../tools/e2e_proxy_test.py  # 端到端（自动生成 CA 与证书）
```

### 11.4 部署到 VPS
```bash
cd srv2
cp .env.example .env      # 填 PUBLIC_HOST=<IP或域名>  TURN_SECRET=<随机长串>
bash deploy.sh root@<VPS>
# 安全组放行：8443/tcp、3478/udp+tcp、49160-49200/udp
```
管理页 `https://<host>:8443/admin`，健康检查 `/healthz`。

### 11.5 桌面客户端开发
```bash
cd client-desktop
npm start          # 同步 web/ 后起 Electron
npm run dist:mac   # 打包（无需签名，identity: null）
```

### 11.6 真机联调（走官方客户端）
```bash
cd srv2 && bash run.sh start       # 起服务端 + mitmproxy(8080)
# 官方客户端设代理 127.0.0.1:8080 → 它的 *.nrd.nie.163.com 请求被改写到你服务端
# 未实现接口的原始报文落 /debug/capture，按它补齐契约
```

---

## 12. 排障手册

| 现象 | 排查顺序 |
|---|---|
| 画面黑屏 | ① macOS 屏幕录制权限 ② `/debug/capture` 看请求 ③ Agent 日志是否 `room=` ④ WS 是否连上（浏览器 Network） |
| 画面卡住 | ① 看是否 `stream.pause` ② 网络丢包 ③ Agent CPU 100%（降 fps/width） |
| 输入无反应 | ① 辅助功能权限 ② pyautogui 坐标是否越界（多屏） ③ 是否在观看模式 |
| 设备不显示 | ① 指纹冲突（看 `/admin`） ② token 失效 ③ `device/list` 返回是否含在线态 |
| 连接立即断开 | ① 证书校验（试 `--insecure`） ② 域名 vs IP ③ 房间 token 是否过期 |
| 关机没执行 | ① `shutdown.state` 是否到 `executing` ② macOS 无 root 时走的是对话框（需用户确认） |
| 打包后 Agent 起不来 | ① `dist/uu-agent` 是否存在 ② `package.json` 的 `extraResources` 路径 ③ 权限位 |
| 画面糊（像被降分辨率） | ① 接收端 `degradationPreference` 是否 `maintain-resolution` ② 发送端实际码率（`rtc.answer.bitrate`）是否掉回 1Mbps（私有字段失效） ③ `stream.config` 的 `bitrate` 是否 8000 |
| 一直走 JPEG / 没有 H.264 | ① `agent.hello.media` 是否为 `webrtc`（aiortc 未装会降级） ② `rtc.offer/answer` 是否在 WS 上往返 ③ `connectionState` 值 ④ 是否被 TURN 拖住（当前 TURN 公网不可用） |

---

## 13. 交接清单（待确认）

上线/移交前需确认：

- [ ] VPS 的 `TURN_SECRET` 已更换（旧值不应带进新环境）
- [ ] `.env` 未入库（检查 `.gitignore`）
- [ ] `srv2/certs/` 下的私钥不入库
- [ ] **`HANDOFF.md` 与 `docs/` 已入库**（⚠️ 当前**未入 git**，clone 下来看不到；必须 `git add` 后提交，见 §3 提示）
- [ ] `data-local/` 下的测试数据可清理
- [ ] `build_tmp_*` 四个临时目录可删除（构建中间产物）
- [ ] `dist/uu-agent`、`dist/uu-server` 是否随仓库分发（当前 26M/21M）
- [ ] GitHub Actions 的 secrets 配置（若用 CI 发布）
- [x] 逆向分析资料已归档至 `docs/reverse/`（保留出处与免责声明）
- [x] 框架重选型文档已归档至 `docs/客户端框架重选型-Flutter.md`（结论固化到 §2.4 / ADR-7）
- [x] 旧选型文档已标注作废（`docs/客户端全端技术选型.md` 顶部有 ⚠️ 标记）
- [x] 媒体通道契约已冻结（`docs/media-protocol.md`，FROZEN v1）
- [x] 媒体链路实测数据已归档（`docs/媒体链路实测.md`）
- [x] 媒体传输决策已记录（ADR-8，替代原 P0-2 自研 UDP 方案）
- [x] 测试数量已核对（`tests.py` 34 项 + `tests_regression.py` 23 项）
- [ ] **WebRTC 媒体真机验证**（Win/macOS/Android/iOS 各一台，含 5% 丢包弱网），验收项见 `docs/media-protocol.md` §7
- [ ] **coturn 公网可用**（当前 3478 只绑 `127.0.0.1`+docker 网桥，中继兜底不可用；修复后测 `turn` 链路）
- [ ] **aiortc 版本锁定/复核**（码率绕过依赖 `_H264Encoder__target_bitrate` 私有字段，见技术债 #16）
- [ ] 明确不做清单已对齐（§1 非目标，含 **iOS 不做被控端**）
- [ ] 接手人已确认四条红线：
  - [ ] **控制端框架用 Flutter**（不要再用 Electron/Capacitor 加功能）
  - [ ] **服务端 `srv2/` 一行不改**（换框架只换 UI 层）
  - [ ] **`agent/` 只改媒体出口**（aiortc 推流），输入/房间/关机逻辑不改
  - [ ] **不追求 iOS 被控端**（系统限制）

---

## 附：术语表

| 术语 | 含义 |
|---|---|
| 控制面 | 账号/设备/房间/信令这些"管理"流量，走 HTTPS/WSS |
| 媒体面 | 画面和声音数据，走 WebRTC（SRTP/UDP），信令仍走 WS |
| ICE | 交互式连接建立，用于 NAT 打洞（WebRTC 标准） |
| STUN | 探测本机公网映射，供 ICE 生成候选 |
| TURN | 打洞失败时的中继兜底（⚠️ 当前运行层仅绑 `127.0.0.1`，公网不可用） |
| **SRTP / DTLS** | WebRTC 的媒体加密与密钥协商，媒体端到端加密由它提供 |
| **BWE** | 带宽估计（Bandwidth Estimation），WebRTC 内置，决定编码器实际码率 |
| **`maintain-resolution`** | WebRTC 接收端的降级偏好：拥塞时宁可掉帧也不降分辨率。**不设就一定会糊** |
| RPC 中继 | 服务端把控制端指令排队，被控端轮询取任务（当前用于关机等） |
| 房间 | 一次远控会话的容器，WS 按 room_id 隔离 |
| 指纹 | 机器唯一标识（hostname + OS + MAC），用于设备去重 |
| **WebCodecs** | 浏览器底层编解码 API（`VideoDecoder`/`VideoEncoder`），直接产出 `VideoFrame`，绕过 `<video>` 标签的缓冲。**迁移 Flutter 后不再使用** |
| **零拷贝** | 解码输出直接在 GPU 显存里被渲染使用，不经过 CPU 内存中转 |
| **Flutter `Texture`** | Flutter 的外部纹理 widget。原生侧把解码结果注册为纹理，只把 `textureId` 传给 Dart，像素数据不跨层拷贝 |
| **`FlutterTexture`**（iOS） | iOS 侧需实现的协议，提供 `copyPixelBuffer` 把 `CVPixelBuffer` 交给 Flutter 引擎 |
| **`TextureRegistry`**（Android） | Android 侧注册 `SurfaceTexture`，产出 `textureId` 给 Flutter |
| **Impeller / Skia** | Flutter 的渲染引擎（Impeller 为新版，iOS/Android 默认），自绘 UI，不依赖系统控件 |
| **media_kit** | Flutter 生态的播放器库，基于 libmpv，支持硬解与低延迟模式。**当前未采用**（ADR-8 后由 `flutter_webrtc` 的 Texture 路径接管） |
| **VideoFrame** | WebCodecs 的解码输出对象，可被 `texImage2D` 直接上传为 GPU 纹理（Electron 时代用） |
| **SurfaceTexture**（Android） | 把 `MediaCodec` 的解码输出（Surface）绑定为 GL 纹理，实现零拷贝 |
| **CVMetalTextureCache**（iOS） | 把 `CVPixelBuffer` 直接映射为 Metal 纹理，实现零拷贝 |
| **VTDecompressionSession** | macOS/iOS 的 VideoToolbox 硬解会话 |
| **desynchronized canvas** | canvas 上下文选项，绕过浏览器合成器排队降低延迟（Electron 时代用） |
| **NACK** | 丢包否定确认，接收端主动要求重传指定序号 |
| **IDR 帧** | 关键帧，解码器可从此帧独立开始解码（丢包恢复靠它） |

---

*本文档与 `docs/reverse/` 逆向分析资料、`docs/media-protocol.md`（媒体契约）、`docs/媒体链路实测.md`、`docs/客户端全端技术选型.md` 配合使用。逆向资料仅用于理解互操作契约与功能设计，不包含绕过授权校验的方法。*
### ADR-9 废弃 Electron / Capacitor，控制端统一 Flutter

**状态**：Accepted（2026-11-20）

**Context**：ADR-7 已决定迁移 Flutter，但迁移期间保留 Electron 作为可用版本。实测两版差距：
Electron 包 144MB / 解包 274MB / 冷启 1–3s；Flutter 包 53MB / 解包 128MB / 冷启 666ms。
两套并行维护成本高，且 Electron 版已不再承担独有能力（内置 agent 将由 Flutter 桌面版接管）。

**Decision**：Electron（`client-desktop/`）与 Capacitor（`client-mobile/`）**停止构建与发布**，
目录仅留档；控制端收敛为 Flutter 一套 + H5 控制页（`srv2/control.html`）作为免安装入口。
CI 中 `desktop-client`、`android-apk`、`ios-project` 三个 job 保留定义但不进 `release.needs`。

**Consequences**：
- 好：单一代码库、发布产物减少 6 个、体积降 2.1×、启动快 2–4×；UI 改动只需改一处
- 代价：Flutter 桌面版必须自己接管「内置被控端」（Process 拉起 uu-agent），否则「装上即可被控」的能力会丢失；
  这是 Electron `main.js` 原本负责的部分，迁移未完成前不能删 `client-desktop/` 目录
- 已知缺口：Flutter 侧 WebRTC 通路（`flutter_webrtc`）落地前，Flutter 客户端只有 JPEG 画质

**复核条件**：若 Flutter 桌面版 CPU 在 1080p60 下超 40%，或 `flutter_webrtc` 在某一端不可用，
再单独评估该端是否回退（不整体回退到 Electron）。
