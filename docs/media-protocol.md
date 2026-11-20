# 媒体通道协议（WebRTC）· 契约冻结版

> 状态：**FROZEN v1**（2026-11-20）
> 适用范围：`agent/` 发送端 ↔ `srv2/control.html` 接收端
> 硬约束：**服务端 `srv2/server.py` 不改一行** —— 本协议全部消息走现有 `/ws/signaling` 文本帧透传

---

## 0. 一句话

信令仍走原来的房间 WS；**画面不再走 WS 二进制帧**，改由 WebRTC（H.264 + SRTP/UDP）直传。
WS 只保留：输入事件、控制指令、SDP/ICE 交换、心跳。

```
控制端(浏览器/Flutter) ──┐                        ┌── 被控端 Agent
  信令 WS（JSON）  ◄──────┼── 服务端 WS 透传 ──────┼──►  信令 WS（JSON）
  媒体 SRTP/UDP  ◄────────┴──── ICE 打洞 / TURN ──┴──►  媒体 SRTP/UDP
```

---

## 1. 能力声明（Agent → 控制端）

`agent.hello` 增加 `media` 字段，控制端据此决定走哪条通路：

```json
{
  "p": "agent.hello",
  "name": "MY-PC",
  "os": "Darwin",
  "screen": {"w": 2048, "h": 1280},
  "media": "webrtc",
  "stream": {"fps": 30, "quality": 75, "width": 1920}
}
```

| 字段 | 取值 | 含义 |
|---|---|---|
| `media` | `"webrtc"` \| `"jpeg"` | `webrtc` = 走 H.264/UDP；`jpeg` = 老通路（FRM1 + JPEG over WS） |

- 缺省（老 Agent 不发该字段）→ 控制端按 `jpeg` 处理，**向后兼容**
- Agent 侧若 aiortc 不可用，自动降级为 `media: "jpeg"` 并在日志说明

---

## 2. 协商流程（trickle ICE）

```
控制端                                             Agent
  │  ── rtc.offer {sdp, ice[]} ──────────────────►  │  建 PC / 挂 ScreenTrack
  │  ◄──────────────── rtc.answer {sdp, bitrate} ──  │  createAnswer + setLocal
  │  ── rtc.ice {candidate, sdpMid, sdpMLineIndex} ► │  addIceCandidate
  │  ◄──────────────── rtc.ice {...} ───────────────  │  addIceCandidate
  │  ═══════ SRTP/UDP 媒体（不经服务端）═══════════  │
  │  ── rtc.close（可选，离开房间/重连）──────────►   │  关闭 PC
```

### 2.1 `rtc.offer`（控制端 → Agent）

```json
{
  "p": "rtc.offer",
  "sdp": "v=0\r\no=- ...",
  "ice": {
    "stun": ["stun:47.251.105.202:3478"],
    "turn": [{"urls": "turn:47.251.105.202:3478?transport=udp",
              "username": "1795000000:ub40b18...", "credential": "base64hmac"}]
  }
}
```

- `ice` 结构与服务端 `room_config.ice_servers` **完全一致**，控制端直接透传，Agent 无需再请求
- Agent 也支持数组形态 `[{urls, username, credential}]`（兼容）

### 2.2 `rtc.answer`（Agent → 控制端）

```json
{"p": "rtc.answer", "sdp": "v=0\r\na=...", "bitrate": 8000}
```

- `bitrate`：Agent 实际生效的码率（kbps），仅用于 UI 显示与自检

### 2.3 `rtc.ice`（双向）

```json
{"p": "rtc.ice", "candidate": "candidate:1 1 udp 2130706431 ...", "sdpMid": "0", "sdpMLineIndex": 0}
```

- 候选可能早于 `answer` 到达，接收方需**缓存后补投**（当前实现直接丢弃并依赖重发，可接受）

### 2.4 `rtc.close`（双向，可选）

```json
{"p": "rtc.close"}
```

- 收到后关闭 PC；Agent 侧同时恢复 JPEG 兜底推流

---

## 3. 清晰度契约（关键，别改错）

WebRTC 默认按「视频通话」优化：码率 1–3 Mbps、拥塞时降分辨率 → **看起来比 JPEG 还糊**。
本项目必须显式覆盖：

| 位置 | 设置 | 值 | 原因 |
|---|---|---|---|
| 接收端 transceiver | `degradationPreference` | `"maintain-resolution"` | 宁可掉帧，不降分辨率（糊的主因） |
| 接收端 receiver | `jitterBufferTarget` | `0` | 实时优先，不攒延迟 |
| 发送端编码器 | `target_bitrate` | 默认 **8 Mbps**，可切 4/8/20 | aiortc 默认 1 Mbps、且 setter 夹到 3 Mbps 上限，**必须写私有字段绕过** |
| 发送端分辨率 | `width` | 默认 1920（`screen` 更窄时取原宽） | 不做超采样，保持 1:1 像素 |

实测依据（本机 2048×1280 屏幕截图，PSNR 对比）：

| 方案 | PSNR | 每帧 | 码率 |
|---|---|---|---|
| 旧默认 JPEG 1280/q55 | 26.9 dB | 90 KB | 11.0 Mbps |
| 旧高清 JPEG 1920/q75 | 37.2 dB | 231 KB | 28.4 Mbps |
| **H.264 4 Mbps** | 39.7 dB | 23 KB | 4 Mbps |
| **H.264 8 Mbps** | **45.8 dB** | 38 KB | 8 Mbps |
| H.264 20 Mbps | 48.5 dB | 69 KB | 20 Mbps |

> 结论：8 Mbps 的 H.264 已接近视觉无损（4:2:0 实际上限约 50 dB），且带宽只有旧「高清档」的 1/3.5。

---

## 4. 运行时调参（复用 `stream.config`）

```json
{"p": "stream.config", "width": 1920, "fps": 30, "quality": 75, "bitrate": 8000}
```

- `bitrate` 为**新增可选字段**（kbps），只作用于 WebRTC；JPEG 通路忽略
- Agent 回 `stream.config.ack`，带 `media` 与生效的 `bitrate`：

```json
{"p": "stream.config.ack", "fps": 30, "quality": 75, "width": 1920, "media": "webrtc", "bitrate": 8000}
```

画质档位（控制页下拉，值为 `width,quality,bitrate`）：

| 档位 | value | 适用 |
|---|---|---|
| 流畅 | `1280,55,4000` | 移动网络 |
| 高清（默认） | `1920,75,8000` | 局域网/宽带 |
| 超清 | `2560,80,20000` | 同城/专线 |

---

## 5. 兜底与降级

| 场景 | 行为 |
|---|---|
| Agent 无 aiortc | `media: "jpeg"`，控制端用 canvas 渲染旧通路 |
| `startRTC()` 抛错 / 浏览器不支持 | 控制端 `stopRTC()`，回到 JPEG（若 Agent 只推 WebRTC 则黑屏，提示用户） |
| `connectionState === "failed"` | 控制端主动 `stopRTC()` 并提示；Agent 侧 `on_state` 恢复 JPEG 推流 |
| WebRTC 连上 | Agent **暂停** JPEG 推流（省 CPU/带宽），断开自动恢复 |
| WS 断开 | 两端都回收 PC；重连后重新走 hello → offer |

**不变式**：任何时刻，同一房间内要么 WebRTC 在传，要么 JPEG 在传，不允许同时推（避免双倍 CPU）。

---

## 6. 不变的部分（协议兼容红线）

| 项 | 状态 |
|---|---|
| `/ws/signaling` 路径、`?token=&device_id=` 鉴权 | 不变 |
| 房间语义、`peer.join` 通知 | 不变 |
| 输入事件 `{p:"input", t, x, y, ...}`，坐标归一化 0..1 | 不变 |
| 关机 `{p:"shutdown", delay}` / `shutdown.state` | 不变 |
| `FRM1 + 8B 时间戳 + JPEG` 帧格式 | 不变（仅 JPEG 通路使用） |
| 服务端 `server.py` | **一行不改** |

---

## 7. 验收（改协议前必须全过）

- [ ] `media: "webrtc"` 时画面来自 `<video>`（非 canvas），HUD 显示 `H.264 · xx fps · WxH · x.x Mbps`
- [ ] 分辨率等于 `stream.config.width`（不因带宽降分辨率）
- [ ] 局域网 1080p@30 端到端延迟 < 100ms（对比旧通路 150–250ms）
- [ ] 拔网线 → `connectionState` 变 failed → 自动回落 JPEG → 恢复后重协商
- [ ] 老 Agent（不发 `media`）仍可用
- [ ] `tests.py` 34 项 + `tests_regression.py` 23 项全绿