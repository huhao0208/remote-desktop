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
| `max_fps` | `15..144` | 被控端粗测的采集上限，**仅供画质面板提示**「超出采集能力」，不做硬拦截（探测有误差，误禁比误开更烦人）。老控制端忽略 |
| `version` / `ip` / `capture` | 字符串 | 连接信息面板用（被控端版本 / 局域网 IP / 采集后端）。缺省则面板显示「—」 |
| `power` | `["lock","shutdown","reboot","taskmgr"]` | 被控端支持的电源动作白名单。控制端据此置灰菜单项。**缺省按「只有 shutdown」处理**——老 Agent 一定有它 |
| `privacy_engine` | `"overlay"` \| `"unsupported"` | 防窥实现引擎。`unsupported` = 该平台做不了真防窥（见 §6），面板整组置灰并给出原因 |
| `privacy` | `"off"` \| `"blank"` \| `"screenoff"` \| `"wallpaper"` | 当前防窥档位（重连后恢复用） |
| `auto_lock` | `true` \| `false` | 结束远程自动锁屏开关（持久化在被控端，下次开机仍生效） |

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
{"p": "stream.config", "width": 1920, "fps": 60, "quality": 75, "bitrate": 8000}
```

- `bitrate` 为**新增可选字段**（kbps），只作用于 WebRTC；JPEG 通路忽略
- `width: 0` = **原画不缩放**（按被控端屏原生分辨率编码）；正数钳到 `640..3840`
- `fps` 钳到 `1..144`（官方 `FrameLimit` 最高档）；JPEG 通路实际到不了，由采集循环自然限速
- Agent 回 `stream.config.ack`，带 `media` 与生效值：

```json
{"p": "stream.config.ack", "fps": 60, "quality": 75, "width": 1920, "media": "webrtc", "bitrate": 8000}
```

> **`bitrate` 只在 WebRTC 通路出现**。JPEG 通路 ack 不带该字段（协议允许缺省），
> 控制端据此不显示「0kbps」这种误导值。

画质 6 档（对齐官方 `Control.Menu.Quality.*`，`value` 存 **key**）：

| 档位 | key | width | quality | bitrate |
|---|---|---|---|---|
| 自动 | `auto` | 0（跟随被控端） | 72 | 0（按宽度/帧率推算） |
| 省流 480P | `speed` | 854 | 55 | 3000 |
| 高清 1080P | `normal` | 1920 | 75 | 8000 |
| 超清 2K | `hd` | 2560 | 80 | 20000 |
| 蓝光 4K | `blue` | 3840 | 85 | 40000 |
| 原画 | `original` | 0（不缩放） | 90 | 60000 |

> 老版本持久化的 `width,quality,bitrate` 三元组仍能读：`QualityPreset.fromValue`
> 先按 key 查，再按参数精确匹配，最后按宽度就近归档，升级不会跳档。

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
- **Agent 侧默认关闭**（`ClipboardSync.enabled = False`）：控制端必须在 `agent.hello` 之后显式发
  `{"p":"clip.sync","enable":true}`，否则永远收不到 `dir:"down"`。开启时 Agent 把当前剪贴板记作
  基线，不会「一开就推一次旧内容」
- 控制端（Flutter）按 1 秒轮询本机剪贴板做上行；去重、超长护栏（200k 字符）、回声抑制在
  `client-flutter/lib/core/clipboard_sync.dart`，下行写入是**静默**的（只有超长才提示一次）
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

> **实现状态（2026-11-21）**：Agent 侧 `list_screens()` + `screen.select` 已上线；
> 控制端已消费 `screens` / `screen.selected`，顶栏有屏选择器。单屏时点击按官方文案
> 提示「当前远程窗口仅有 1 个屏幕，无需切换」，不发无效请求。
> 实测：`screen.select{id:0}` → `screen.selected{id:0}`；`id:5` → `agent.error 无效屏幕 5`。

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

> **实现状态（2026-11-21）**：面板已上线（`lib/widgets/remote_info_panel.dart`），
> 数据源是 `pc.getStats()` 的 `inbound-rtp` + `candidate-pair` + `codec` join 结果
> （`parseStatsSnapshot`）。被控端 IP / 版本来自 `agent.hello` 新增的 `ip` / `version` /
> `capture` 三个可选字段，老 Agent 不填则面板显示「—」。
> 取不到的字段一律显示「—」**而不是 0**，避免「拿不到」被误读成「测得 0」。

## 6. 观看模式 / 防窥

```json
{"p":"view.only","enable":true}       // 控制端只渲染，不发 input；同时通知 Agent 放掉按住的修饰键
{"p":"view.only","enable":false}      // 回到操控态
```

两件事分开做，缺一不可：

1. **本地拦截**（必须）：控制端进观看态后不再产生任何 `input` 消息——`hover`/点击/按键全不发，
   这是「观看模式」的核心承诺，光靠被控端忽略是不够的（省带宽也省被控端 CPU）。
2. **通知 Agent**（兜底）：`enable:true` 时 Agent 调 `release_all()` 清掉按住的修饰键。
   控制端切态那一刻会自己补发 `keyup`，但失焦、系统快捷键抢占等情况下这次 `keyup` 可能丢，
   远端就会卡住 Shift/Alt。Agent 侧这一下是第二道保险。

防窥四档（键名对齐官方 `Control.Privacy.*`）：

```json
→ {"p":"privacy","mode":"blank"}
→ {"p":"privacy","mode":"wallpaper","image":"<base64 PNG/JPG>"}   // 可选：顺带设置壁纸
→ {"p":"privacy","mode":"off"}
← {"p":"privacy.state","ok":true,"mode":"blank","label":"黑屏防护",
   "engine":"overlay","alive":true,"image":false,"since":1763700000000}
← {"p":"privacy.state","ok":false,"err":"当前被控端不支持防窥：…",
   "mode":"off","engine":"unsupported"}
```

| 档位 | 官方行为 | 要求 |
|---|---|---|
| `off` | 不启用 | — |
| `blank` | 黑屏防护（全屏置顶黑窗） | 遮罩窗**必须不进录屏** |
| `screenoff` | 关闭显示屏 | 在 `blank` 基础上再熄屏 |
| `wallpaper` | 隐私屏保（全屏置顶图片） | 图片 ≤ 2MB，建议 ≥ 1920×1080 |

**引擎判定（`privacy_engine`）**——这条是实测结论，不是设计偏好：

| 平台 | 遮罩窗 | 熄屏 | 结论 |
|---|---|---|---|
| Windows | 可用（`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` 让窗口不进录屏） | 可用 | `overlay` |
| macOS | 可用（`NSWindow.sharingType=NSWindowSharingNone`，ctypes 零依赖；实测遮罩占比 91.7%→0.2%） | **采集直接失效** | `overlay`（`screenoff` 档拒绝） |
| Linux | 会被自己的采集录进去（X11 无排除 API） | 依赖 DPMS，Wayland 无 | `unsupported` |

macOS 实测（2026-11-21，2048×1280）：`pmset displaysleepnow` 之后
`mss` 的 `monitors` 变成 `0×0`，`screencapture` 报
`could not create image from display` —— 熄屏等于断流。

> 所以 `unsupported` 不是「懒得做」：真做了要么控制端全黑，要么直接没画面。
> 下一步候选见 `docs/远控复刻基线.md` §P2（`CGWindowListCreateImage`
> 的 `OnScreenBelowWindow` 或 `NSWindowSharingNone`）。

**断线收尾**：会话结束（WS 断开）时 Agent 必须撤销遮罩、恢复音量、
取消未执行的关机倒计时——否则用户面对一块黑屏或一个静音会以为机器坏了。

## 7. 电源与安全配置

```json
→ {"p":"power","action":"lock"}                                  // 立即执行
→ {"p":"power","action":"taskmgr"}
→ {"p":"power","action":"shutdown","delay":30}                   // 倒计时，可撤销
→ {"p":"power","action":"reboot","delay":30}
→ {"p":"power","action":"shutdown","cancel":true}                // 撤销

← {"p":"power.state","action":"shutdown","state":"pending","remain":30}
← {"p":"power.state","action":"shutdown","state":"executing"}
← {"p":"power.state","action":"shutdown","state":"done"}          // lock/taskmgr
← {"p":"power.state","action":"shutdown","state":"cancelled"}
← {"p":"power.state","action":"shutdown","state":"failed","err":"…"}
```

- `lock` / `taskmgr` **不设倒计时**：做成倒计时反而碍事
- `shutdown` / `reboot` 默认 30 秒缓冲，**断链自动撤销**（断线时执行关机最容易变成「人不在机器前」）
- 兼容：`{p:"shutdown"}` 旧指令等价于 `action:"shutdown"`；
  `action=shutdown` 时 Agent 会**额外补发**旧的 `{p:"shutdown.state"}`
  （`srv2/control.html` 仍在用），新客户端以 `power.state` 为准

```json
→ {"p":"security.config","auto_lock":true}
→ {"p":"security.config","mute":true}
← {"p":"security.state","auto_lock":true,"mute":true,"mute_ok":true}
← {"p":"security.state","auto_lock":false,"mute":false,"mute_ok":false,"err":"…"}
```

- `auto_lock`：**结束远程**时锁被控端。只在本会话真有人连过时才触发，
  否则每次网络抖动重连都会把人踢回登录界面
- `mute`：只静音**扬声器输出**，不碰采集设备——所以「被控静音」之后控制端仍听得到。
  若哪天改用 loopback 采集，这条语义要跟着改，否则控制端会一起被静音
- Windows 的静音走 CoreAudio COM，**放在子进程里跑**（vtable 写错就是访问违例），
  写完回读校验，读不回就报失败而不是谎报成功

## 8. 验收补充（v2）

- [ ] 有音频时 CPU 增幅 < 15%，延迟 < 200 ms
- [ ] 剪贴板：控制端复制 → 被控端 5 s 内可粘贴；反向同理；不出现回环抖动
- [x] 多屏：切换后画面分辨率跟着变，不需要重连（协议往返已验，双屏真机待验）
- [ ] Shift 长按 + 点击可多选；失焦后远端不卡修饰键
- [x] 连接信息面板数值与 HUD 一致（同一 `parseStatsSnapshot` 数据源）
- [x] `scroll` 带 `mods`：Ctrl+滚轮在远端触发缩放（Agent 侧 `_hold(mods)` 已支持）
- [x] 电源：`shutdown` 倒计时 3→2→撤销 全链路实测通过；旧 `shutdown.state` 同时下发
- [x] 静音：macOS `osascript` 置位/复位均回读 `mute_ok:true`，测完已恢复外放
- [ ] 防窥：Windows 遮罩窗「不进录屏」待真机验证（macOS/Linux 明确 `unsupported`）
- [ ] 自动锁屏：需真机断开验证（本次仅验证开关落盘与回执）

---

# 协议 v3 扩展（2026-11-21 追加）：文件传输 / 鼠标模式 / 键盘映射 / 控制端麦克风

> 这三块是 B 阶段的功能本体。契约先行：控制端（`client-flutter/`）与
> 被控端（`agent/`）各自实现，谁都不许私自加字段。

## 1. 文件传输：为什么走信令 WS

控制端有两条媒体通路——WebRTC（`rtc.*`）和 JPEG 兜底（二进制帧）。文件传输要在
**两者都可用**，否则「低配环境传不了文件」。而信令 WS 在服务端是**透明中继**
（`srv2/server.py::signaling`，文本按 JSON 广播、二进制原样转发），与媒体通路正交。

所以 v3 统一走信令 WS 的**文本帧 + base64**：

- 单块原始 32KB（base64 后约 43.7KB）。块再大就会把同一条 WS 上的 `input`
  堵在队头——输入延迟是体感生命线，传输慢一点可以忍，点一下慢半秒不行
- 不用二进制帧：JPEG 通路的二进制帧是 agent→client 的图片，再塞一路
  方向语义不同、需要额外帧头区分的二进制流，解析成本大于省下的 33% 带宽
- 服务端零改动：中继本来就透明

## 2. 消息全集

控制端 → Agent：

```json
{"p":"file.offer","id":"f-1763700000-4821","name":"a.zip","size":10485760,"offset":0}
{"p":"file.chunk","id":"…","off":32768,"data":"<base64 ≤32KB>"}
{"p":"file.done","id":"…","sha256":"<hex 可省略>"}
{"p":"file.cancel","id":"…","reason":"user"}
{"p":"file.get","id":"…","path":"/Users/x/a.zip","offset":0}
{"p":"file.list","dir":""}
```

Agent → 控制端：

```json
{"p":"file.accept","id":"…","name":"a.zip","size":10485760,"path":"/Users/x/Downloads/a.zip","offset":0,"mode":"new"}
{"p":"file.reject","id":"…","reason":"denied|no_space|too_large|bad_name|unsupported"}
{"p":"file.chunk","id":"…","off":0,"data":"<base64>"}
{"p":"file.progress","id":"…","received":1048576}
{"p":"file.complete","id":"…","path":"…","bytes":10485760,"sha256":"…"}
{"p":"file.error","id":"…","reason":"offset|io|sha256|not_found","msg":"…"}
{"p":"file.list.result","dir":"…","entries":[{"name":"a.zip","size":10,"is_dir":false,"mtime":1763700000}]}
```

规则（缺一条就会出现「传了一半的坏文件」）：

1. **id 由发起方生成**，`f-<毫秒>-<4位随机>`。**发起方决定数据方向**，接收方只按 id 回，
   绝不靠 `dir` 字段猜方向——下载方向 agent 发 `file.chunk`，上传方向控制端发，
   帧格式相同，只有 id 的发起方能区分。
2. **块必须按 `off` 升序到达**。接收方发现 `off != 已写字节数` → `file.error`
   reason=`offset`，发起方从 0 重传。v1 不做乱序重排与块级重传（复杂度不值）。
3. **续传**：重连后 `file.offer` 带 `offset`。Agent 若 `size(目标) == offset` →
   `mode:"append"` 从 offset 续写；否则 `mode:"new"` 从 0 开始（并截断旧文件）。
4. **冲突改名**：目标已存在 → 默认 `a (1).zip`、`a (2).zip`…，`mode:"rename"`，
   回包 `path` 是**真实落盘路径**，控制端要按它显示。覆盖需显式 `overwrite:true`
   （首版不开放 UI）。
5. **落盘安全（Agent 强制，不是可选项）**：文件传输是最容易被拿来写任意文件的入口。
   只取 basename、拒绝 `..`、拒绝绝对路径、滤掉 Windows 保留字符 `<>:"|?*` 与结尾点/空格、
   长度 ≤200 字符；最终路径必须落在接收目录内（`realpath` 前缀校验），
   越界一律 `file.reject` reason=`bad_name`。
6. **容量**：单文件上限默认 4GiB；接收目录剩余空间 < 1.2×size → `file.reject` `no_space`。
7. **进度节流**：`file.progress` 每 ≥1MiB 或 ≥500ms 才发一次，否则一条 10GB 传输
   能刷出 30 万条消息，把信令挤爆。
8. `file.list` / `file.get` 的浏览范围 = **接收目录 + 用户主目录**两个白名单根
   （`realpath` 后拼分隔符比较前缀，挡住 `/tmp/a` 匹配 `/tmp/ab` 这类经典漏法）。
   系统目录（`/etc`、`/System`、`/var`、`/usr`）与其它用户一律拒绝，回 `file.error reason:"denied"`。
   > 为什么允许主目录：下载方向的本意就是「把被控端的文件拿过来」，只允许接收目录
   > 等于只能下载自己刚上传的文件，功能等于没有。而 agent 本来就已经接受全量
   > 键鼠注入与关机指令，信任模型上「读主目录内的文件」不是新增的信任边界。

## 3. 鼠标模式 + 光标可见性

```json
→ {"p":"cursor","visible":false}
← {"p":"cursor.state","visible":false,"ok":true,"engine":"win-show-cursor|mac-cgdisplay|unsupported"}
→ {"p":"input","t":"moverel","dx":0.0021,"dy":-0.0004}
```

| 模式 | 官方名 | 行为 |
|---|---|---|
| `remote` | `ControlledMouse` | 绝对坐标 `input.move`，被控端系统光标可见。**默认**，兼容性最好 |
| `control` | `ControlMouse` | 相对位移 `input.moverel`，被控端光标隐藏，控制端用本机光标指示位置 |
| `auto` | `AutoMouse` | RTT 平滑 >60ms 或正在拖拽 → 临时切 `control`；条件消失后 2 秒回 `remote` |

- `moverel` 的 `dx/dy` 是**归一化相对位移**（0.001 = 屏幕宽度的 0.1%），
  Agent 侧换算成像素后走「warp」语义（macOS `CGWarpMouseCursorPosition`、
  Windows `SetCursorPos`），**不吃系统指针加速**。这正是游戏场景要的。
- 游戏模式 = `control` 下再乘一个 `speed`（0.5–3.0），不做平滑、不做加速曲线。
- 切到 `remote` 必须**立刻**发 `cursor:visible:true`——否则被控端光标一直是隐藏的，
  用户会以为鼠标坏了。
- `engine:"unsupported"`（Linux X11 无统一 API）时控制端要隐藏「隐藏远端光标」这个选项，
  而不是给一个点了没反应的开关。

## 4. 键盘映射（外设组）

只在**跨平台**时生效，同平台直通；映射在**控制端**做（Agent 只认 pyautogui 键名，
两边都维护映射表必然对不上）：

| 控制端 | 被控端 | 映射 | 备注 |
|---|---|---|---|
| macOS | Windows | `cmd` → `win`（默认）/ `ctrl`（可配） | 官方 `Setting.Keyboard.WindowsMapping.*` |
| macOS | Windows | `option` → `alt`；`delete` → `backspace` | `fn+delete` → `delete` |
| Windows | macOS | `win` → `cmd`；`alt` → `option` | |
| Linux | 任意 | 直通 | |

## 5. 验收

- [ ] 双向各传一个 ≥100MB 文件，sha256 一致；中途断网重连后能续传
- [ ] 文件名带 `../`、绝对路径、`CON`、超长名 → 被拒且不落盘
- [ ] 同名文件第二次传 → 落成 `a (1).zip`，原文件不被覆盖
- [ ] 磁盘不足 → `file.reject no_space`，不留半截文件
- [ ] 鼠标三模式切换后远端光标可见性跟着变，切回 `remote` 光标必回来
- [ ] Mac 控制端按 ⌘ 在 Windows 被控端表现为 Win 键（可配成 Ctrl）

## 6. 控制端麦克风（Agent 侧放音）

方向与 v2 §1 相反：**控制端采集 → 被控端播放**。官方叫「语音通话」，我们只做单向，
理由见下。

### 6.1 为什么是单向而不是双向通话

v2 §1 已经有一条 Agent → 控制端的音频轨（被控端麦克风/系统输入）。如果再补一条反方向，
同一个 `RTCPeerConnection` 上就有两条音频 m-line，语义变成「双向通话」——那时候必须处理
回声消除（AEC）、双讲（double-talk）、以及「两端都在放音时谁压谁」，这些是实时音频工程，
不是远控该背的复杂度。

所以这里只做**控制端 → 被控端的单向推送**定位为「对被控端喊话」。控制端这边
`getUserMedia` 必须显式开 `echoCancellation: true` + `noiseSuppression: true`：
控制端自己的扬声器正在放被控端的声音，不开 AEC 会形成回授啸叫。

### 6.2 消息

```json
// 控制端 → Agent：开/关喊话
{"p":"mic", "enable": true}
// Agent → 控制端：能力与状态回执
{"p":"mic.state", "ok": true, "on": true, "engine": "aiortc", "err": null}
```

| 字段 | 含义 |
|---|---|
| `ok` | 本次切换是否被接受。`false` 时 `err` 给原因码 |
| `on` | 切换**之后**的实际状态（不是请求值）。控制端以它为准 |
| `engine` | `aiortc` = 走 WebRTC 音频轨；`unsupported` = 本平台无放音能力 |
| `err` | `no_audio` / `no_track` / `unsupported` / `busy`（**预留，当前 Agent 不会返回**：多控制端抢麦克风的产品规则还没定，先留词表避免以后改协议） |

### 6.3 `agent.hello` 新增字段

```json
{"p":"agent.hello", "mic": true}
```

`mic` = 本会话**能否**接收控制端麦克风（即 Agent 有可用的音频输出设备且支持播放）。
缺省视为 `false`：老 Agent 不会发这个字段，控制端据此把「麦克风」按钮置灰并说明原因，
而不是给一个点了没反应的开关。

### 6.4 协商方式：**不重协商**

这是本节最关键的一条。控制端在 `createOffer` 阶段就加一条 **`sendrecv` 的 audio m-line**，
但**不挂本地轨**（`addTransceiver(audio, sendrecv)` 后不 `addTrack`）。

- 为什么不用 `recvonly`：`recvonly` 的 m-line 之后要变成 `sendonly` 必须重新协商
  （re-offer），而 Agent 的 `handle_offer` 对同 peer 的策略是**先关旧会话再重建**
  （见 `agent/webrtc_media.py handle_offer`）——那会把画面也一起重建，用户看到黑屏闪一下。
- 为什么不在开麦时才 re-offer：同上。用 `sendrecv` 预留双向能力，开麦只是
  `pc.getSenders()` 里给那条 audio sender `replaceTrack(localMic)`，**零协商、零中断**。
- 代价：m-line 一直在，即使从没开过麦。空 `sendrecv` 不产生 RTP 包，带宽代价为 0。

Agent 侧对应地：`handle_offer` 里如果 SDP 有 `m=audio`，先 `pc.on("track")` 注册接收，
收到的 `RemoteAudioTrack` 交给 `pyaudio`/`sounddevice` 播放。**不 `addTrack`**——
Agent 自己的麦克风轨仍然只在 `audio_ok` 且 SDP 有 m=audio 时挂（v2 §1 的行为不变）。

### 6.5 强制规则

1. 开麦前必须先 `getUserMedia({audio: {echoCancellation: true, noiseSuppression: true}})`，
   **拿不到就立刻回 `mic.state{ok:false,err:"no_track"}` 并让按钮弹回 OFF**，
   绝不允许「按钮亮着但没声音」。
2. 关麦时必须 `track.stop()` 释放采集设备——否则系统状态栏的麦克风指示灯会一直亮，
   用户会以为被偷听。
3. 页面退出 / 断链 / 切到 JPEG 通路时**必须**自动关麦（同规则 2）。
4. `mic.state` 是唯一真相源：控制端点了开关后进入「pending」态，收到回执才定态；
   3 秒没回执视为失败并弹回。
5. 被控端**必须在本地有可见提示**（正在被喊话），不做静默放音。这一条是产品红线，
   与防窥功能同级的隐私要求。
6. JPEG 通路不支持麦克风（没有 RTP 通路），`p:"mic"` 发过去 Agent 应回
   `ok:false, err:"unsupported"`。

### 6.6 验收

- [ ] 控制端开麦 → 被控端扬声器出声，延迟 < 300ms
- [ ] 开麦/关麦切换**不触发**任何 `rtc.offer`（抓包确认零重协商）
- [ ] 关麦后系统麦克风指示灯熄灭，`track.stop()` 已调用
- [ ] 拒绝麦克风权限 → 按钮弹回 OFF 并提示，不进入「亮着但没声音」的假状态
- [ ] 断链后重新连接，麦克风是 OFF（不记忆上次状态）
- [ ] 老 Agent（hello 无 `mic`）→ 按钮置灰，提示「被控端不支持语音」
