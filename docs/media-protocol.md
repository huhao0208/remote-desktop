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
---

# 协议 v2 扩展（2026-11-20 追加，FROZEN）

> 目标：补齐「体验最佳」缺的能力。所有新消息**仍然走现有 WS**，服务端依旧零改动。
> 与 v1 完全向后兼容：老 Agent 不发/不收这些消息，页面按能力降级。

## 1. 音频（Agent → 控制端）

- Agent 在**同一条 `RTCPeerConnection`** 上增加一个 audio track（Opus，48 kHz，单声道，`echoCancellation:false`）
- `agent.hello` 增加字段：

```json
{"p":"agent.hello", "media":"webrtc", "audio": true, "screens": 2}
```

| 字段 | 含义 |
|---|---|
| `audio` | `true` = 本会话会有音频轨（控制端 `<audio autoplay>` 播放） |
| `screens` | 显示器数量（见 §3） |

- 控制端：`pc.ontrack` 里判断 `event.track.kind === 'audio'` → 挂到隐藏 `<audio>` 元素，不参与画面布局
- 静音开关：控制端本地 `audio.muted = !enabled`（**不**通知 Agent，省一次往返）
- Agent 侧采集：macOS 用 `sounddevice`/`pyaudio` 抓默认输出（loopback 需 BlackHole 之类虚拟设备，首版只支持「麦克风/系统默认输入」，系统内录作为 TODO 标注）

## 2. 剪贴板双向同步

```json
{"p":"clip", "dir":"up",   "text":"..."}   // 控制端 → Agent：写入被控端剪贴板
{"p":"clip", "dir":"down", "text":"..."}   // Agent → 控制端：被控端剪贴板变化
{"p":"clip.sync", "enable": true}          // 控制端开/关同步
```

- Agent 侧：读取用 `pbpaste`（macOS）/`Get-Clipboard`（Windows）/`xclip -o`（Linux）；写入用 `pbcopy`/`Set-Clipboard`/`xclip -i`
- 轮询间隔 800 ms，**内容 md5 去重**，只推变化；超过 256 KB 的文本不传（避免大段代码卡链路）
- 控制端开启同步前必须先有用户手势（浏览器 clipboard 权限要求）
- 两端都要做**回环抑制**：写入动作打标记，5 秒内同一内容不再回推

## 3. 多显示器

```json
{"p":"screens", "current":0, "list":[
  {"id":0,"w":2048,"h":1280,"x":0,"y":0,"name":"内建","primary":true},
  {"id":1,"w":1920,"h":1080,"x":2048,"y":0,"name":"外接","primary":false}
]}
{"p":"screen.select", "id":1}
{"p":"screen.selected", "id":1}          // Agent 确认，下一帧生效（强制关键帧）
```

- `agent.hello` 之后立即推一次 `screens`
- 切换后 Agent 必须**重建视频轨**（分辨率变了），控制端无感（WebRTC 自动重协商）
- 控制端 UI：工具栏显示当前屏，多屏时点开选择

## 4. 修饰键状态机（修正 v1 语义）

v1 的 `keydown/keyup` 只发单键，被控端按一下就抬起，导致 Shift 多选、Ctrl+滚轮失效。v2 明确：

```json
{"p":"input","t":"keydown","k":"shift"}          // 按下并**保持**
{"p":"input","t":"keyup",  "k":"shift"}          // 释放
{"p":"input","t":"key","combo":["ctrl","c"]}     // 原子组合键（按下→释放全序列）
{"p":"input","t":"scroll","dy":-3,"mods":["ctrl"]}   // 带修饰键的滚轮
```

- Agent 维护 `pressed_mods: set`，所有 `move/click/scroll` 事件都带上当前修饰状态
- 控制端失焦（`blur`/`visibilitychange`）必须发送**全部 keyup**，避免远端卡住 Shift

## 5. 画质与连接信息（UI 用，复用现有消息）

```json
{"p":"stream.config","width":1920,"fps":30,"bitrate":8000,"audio":true}
{"p":"stats","ts":1795177000000,"fps":17,"mbps":0.4,"rtt":3,"jb":22,"dropped":0,
 "enc":"h264","w":1920,"h":1200,"audio":true}
```

- `stats` 由控制端本地采集即可（`pc.getStats()`），**不需要 Agent 参与**；此条仅为将来「被控端也上报」预留，v2 不实现
- 控制端「连接信息面板」展示：编码、分辨率、fps、码率、RTT、抖动缓冲、丢帧、ICE 类型（host/srflx/relay）

## 6. 观看模式 / 隐私屏

```json
{"p":"view.only","enable":true}       // 控制端只渲染，不发 input（本地拦截，不通知 Agent）
{"p":"privacy","enable":true}         // Agent 用纯色遮罩覆盖被控屏（本地窗口 + 暂停推流）
```

## 7. 验收补充（v2）

- [ ] 有音频时 CPU 增幅 < 15%，延迟 < 200 ms
- [ ] 剪贴板：控制端复制 → 被控端 5 s 内可粘贴；反向同理；不出现回环抖动
- [ ] 多屏：切换后画面分辨率跟着变，不需要重连
- [ ] Shift 长按 + 点击可多选；失焦后远端不卡修饰键
- [ ] 连接信息面板数值与 HUD 一致
