# UU 远程 · 远程功能实现方案 + UI 设计规范

> 来源：`/Applications/UURemote.app`（`com.netease.uuremote` v4.48.1 / macOS）静态逆向
> 用途：互操作性开发 / 功能学习——为自建 `uu-remote-server` 落地
> 证据等级标注：**【证】**=二进制/资源直接证据　**【推】**=基于证据的合理推断，未运行时验证

---

# PART A · 远程功能实现方案

## A1. 端到端链路（官方 7 阶段）

```
① 协商    控制端 ──API──> 服务端 ──> 被控端     (room/create → join → 能力交换)
② 打洞    ICE(STUN) 直连  ──失败──> TURN 中继 / QUIC 通道
③ 采集    ScreenCaptureKit (macOS) / DXGI (Win) / XShm (Linux)
④ 编码    VideoToolbox H.264/H.265（硬编，零拷贝 IOSurface）
⑤ 传输    WebRTC(SRTP/DTLS) 主通道 + QUIC 备用通道（双栈并行）
⑥ 解码    VideoToolbox / MediaCodec（硬解）
⑦ 渲染    Metal / MetalKit（GPU 纹理直上，无 CPU 回拷）
     输入    控制端事件采样 ──信令──> 被控端注入（CGEvent / SendInput）
```

**【证】** 依据：`libstreamer.dylib` 依赖 ScreenCaptureKit / VideoToolbox / CoreVideo / IOSurface / Metal / AudioUnit；字符串含 `WebRTC`、`RTP/SAVP`、`DTLS/SCTP`、`TCP/DTLS`、`quic`、`quicv2`、`QuicTran`、`ice_*`、`turn`；导出符号 `ExchangeControlledInterface` / `ExchangeControllerInterface` / `MetalView`。

**对你的实现建议**：你的 agent 目前是 `mss 截屏 → JPEG → WS`。要提升到可用级，按优先级：

| 阶段 | 现状 | 建议 | 收益 |
|---|---|---|---|
| 采集 | mss 轮询 | 保持 mss（跨平台简单），但改**变化检测 + 局部矩形**，只传脏区 | 带宽降 60-80% |
| 编码 | JPEG | 换 **H.264（libx264 / openh264）**，关键帧 2s，B 帧关闭 | 码率降 70%，延迟降 |
| 传输 | WS 单通道 | WS 传控制信令，**UDP 直传媒体**（QUIC 或裸 UDP + 序号），全失败回落 WS | 延迟从 100ms+ 降到 30ms |
| 解码/渲染 | MJPEG `<img>` | WebCodecs（`VideoDecoder`）→ canvas / WebGL | CPU 降，帧率稳 |

> 关键：**媒体面绝不能走 TCP**。你现在的 WS 是 TCP，丢包会引发队头阻塞，这是远程桌面体验的头号杀手。

## A2. 媒体参数矩阵（官方画质体系）【证】

**画质 6 档**（`Control.Menu.Quality.*`）：

| 档位 | key | 典型分辨率 | 用途 |
|---|---|---|---|
| 省流 | `speed` | 480P | 弱网/移动流量 |
| 高清 | `normal` | 1080P | 默认 |
| 超清 | `highDefinition` | 2K | 办公 |
| 蓝光 | `blue` | 4K | 设计/视频 |
| 原画 | `original` | 源分辨率 | 无损 |
| 自动 | `auto` | 动态 | 默认推荐 |

**帧率**：`30` / `60` / `90` / `144`（`FrameLimit.low/middle/high/noLimit`），默认 60，标注「推荐」。

**分辨率**：`跟随当前显示屏` / `跟随被控端` / 480P / 1080P / 2K / 4K / 其他。

**色彩**：`常规色彩` / `真彩`（True Color，需硬解+带宽），与 **HDR 互斥**——两者同时开会弹「关闭 HDR 并开启真彩」/「关闭真彩并开启 HDR」二选一对话框。【证】

**码率**：支持自定义码率（`CustomBitrateSetting`），技术上限标称 500Mbps。【证】
> 注：官方对此设了商业付费分级（属商业逻辑，与本文技术还原无关）。自研产品无需此限制，按上行带宽与编码器能力设实际上限即可。

**媒体降级策略**（`streamer-config.json` 实际内容）【证】：
```json
{
  "disable_h265_codec": [{
    "enable": true,
    "roles": ["controller"],
    "platforms": ["windows"],
    "graphic_cards": ["GTX\\s*7", "GT\\s*7", "GTX\\s*9", "GT\\s*9"]
  }],
  "set_max_decoder_cap": [{
    "enable": true,
    "platforms": ["android"],
    "brands": ["Lenovo"],
    "models": ["TB371FC"]
  }]
}
```
→ **按显卡型号/机型做能力降级**：老 N 卡（GTX 7xx/9xx）禁 H.265 编码；特定 Android 平板限解码上限。**这是产品级细节，建议你在 agent 启动时做一次能力自检并上报服务端。**

## A3. 输入管线

### A3.1 事件协议【证：字符串层 `mouse_move`/`mouseDown`/`mouseUp`/`Scroll`/`keyDown`/`keyUp`/`keyCode`/`touchEvent`/`inputEvent`】

建议事件格式（对齐官方语义，字段名自定）：

```json
{"t":"m","a":"mv","x":0.512,"y":0.334,"ts":1234567890}
{"t":"m","a":"dn","b":0,"x":0.512,"y":0.334}
{"t":"m","a":"up","b":0,"x":0.512,"y":0.334}
{"t":"m","a":"wh","dx":0,"dy":-3}
{"t":"k","a":"dn","code":65,"mods":["cmd","shift"],"ts":...}
{"t":"k","a":"up","code":65,"mods":[]}
{"t":"t","a":"dn","id":0,"x":0.3,"y":0.6}
```

**要点**：
1. 坐标用**归一化浮点**（0-1），而非像素——被控端分辨率变化/多屏切换时不用改协议
2. 事件带 `ts`，便于被控端做**抖动缓冲**（20-40ms 窗口平滑）
3. `mods` 用数组，避免位掩码跨平台歧义

### A3.2 三种鼠标模式【证：`Control.Menu.Mouse.*`】

| 模式 | 文案 | 实现差异 | 适用 |
|---|---|---|---|
| 使用主控端鼠标 | `ControlMouse` | 控制端渲染光标，被控端**隐藏系统光标**，只注入移动事件 | 跟手性好，但部分游戏/软件不兼容 |
| 使用被控端鼠标 | `ControlledMouse` | 不渲染本地光标，依赖被控端系统光标（受网络延迟影响） | **默认**，兼容性最好 |
| 智能鼠标 | `AutoMouse` | 自适应：办公用主控端、游戏/特殊软件切被控端 | 默认演进方向 |

**关键细节**【证】：被控端鼠标模式下开启隐私屏保时「**被控端无法完全隐藏鼠标**」——因为系统光标是真实绘制的，遮不住。这是产品已知缺陷，文案里明确提示了。

**游戏鼠标模式**【证】：独立开关 `GameMode`，带**速度调节**（`gameModeMouseSpeed`），快捷键 `Ctrl+Option+Enter`。原理推测是绕过系统指针加速，直接注入原始位移。

**指针加速**【证：`com.netease.uuremote.pointer.acceleration`】——有独立算法模块。

### A3.3 按键映射（Mac 控制端 → Windows 被控端）【证：`Setting.Keyboard.WindowsMapping.*`】

| 源（Mac） | 目标（Windows） |
|---|---|
| Command（⌘） | Win 或 Ctrl（可配） |
| Control（⌃） | Ctrl |
| Option（⌥） | Alt |
| Delete | Backspace |
| Fn + Delete | Delete |

### A3.4 系统快捷键策略【证：`Setting.Keyboard.Response.*`】

三种模式：
1. **优先在控制端响应**（`controllerFirst`）——默认
2. **优先在被控端响应**（`remoteFirst`）——开启时 `Command+Tab` 等传给被控端
3. **例外按键**——通过「配置快捷键」单独指定

这是远程桌面的经典难题（Cmd+Tab 到底切谁的窗口），官方用「三档策略 + 例外列表」解决，**建议直接照抄这个设计**。

### A3.5 权限依赖【证：`Setting.Keyboard.Permission.*`】

| 权限 | 用途 | 缺失后果 |
|---|---|---|
| 辅助功能（Accessibility） | 识别/发送系统快捷键 | 快捷键功能不可用 |
| 输入监控（Input Monitoring） | 捕获系统级按键 | 无法捕获快捷键 |

> macOS 上这两个权限**必须重启客户端才生效**（文案明确写了）。

## A4. 连接协商与降级

**协商失败提示体系**【证：`Control.NegotiateInfo.*` 21 条】——按「谁受限」× 「哪个能力」× 「怎么降」三维组合：

```
被控端不支持 HDR        → 当前被控端不支持 HDR
主控端不支持 HDR        → 当前主控端不支持 HDR
性能受限                → 设备性能受限，最高支持 %@ 画质
性能受限 + 可降级       → 设备性能受限，可降低画质到 %@ 后重试
性能受限 + 双能力冲突   → 可尝试关闭 HDR 和真彩后重试
```

**连接后自动降级提示**【证：`Control.NegotiateInfo.Connect.notice1-7`】：
- 已关闭真彩与 HDR 并降低到 %@ 画质
- 已自动降低到 %@ 画质

**性能归因提示 9 条**【证：`Control.Connection.notice1-9`】——这是产品亮点，建议照抄：

| # | 归因 | 建议动作 |
|---|---|---|
| 1 | 网络延迟高 | 降低画质或帧率 |
| 2 | 网络延迟高 | 切换更好的网络 |
| 3 | 设备性能受限 | 降低画质或帧率 |
| 4 | 被控端显卡驱动版本过低 | 升级驱动 |
| 5 | **控制端**资源占用高 | 关闭其他应用 |
| 6 | **被控端**资源占用高 | 关闭其他应用 |
| 7 | 网络延迟高 | 降低帧率 |
| 8 | 设备性能受限 | 降低帧率 |
| 9 | 设备性能受限 | 降低画质 |

> 注意 5/6 区分了「控制端」和「被控端」——这个归因粒度是体验关键。

## A5. 防窥模式（官方叫「防窥模式」，4 档）【证：`Control.Privacy.*`】

| 档位 | 文案 | 实现原理（推测） | 防护等级 |
|---|---|---|---|
| `unusable` | 不启用 —— 被控端屏幕未防护，旁人可见 | 无操作 | 无 |
| `blankScreen` | **黑屏防护** —— 显示黑屏画面遮挡内容 | 全屏置顶黑窗覆盖 | 中 |
| `closeScreen` | **关闭显示屏** —— 屏幕已熄屏，仅使用虚拟屏幕 | 物理熄屏 + 虚拟显示器接管 | **高** |
| `screensaver` | **隐私屏保** —— 屏幕已防护，遮挡屏幕内容 | 全屏置顶图片（自定义/预设） | 中 |

**隐私屏保规格**【证】：
- 图片 ≥ 1920×1080，≤ 2MB，JPG/PNG
- 上传服务端做敏感内容检测（`Alert.sensitiveImage`）
- 支持「预设」和「自定义」两栏，记忆「上次使用」
- 上传成功 → 询问「是否使用作为隐私屏保？」→ 立即使用 / 下次再说

**配套能力**【证】：
- **自动锁屏**（`autoLock`）：结束远程时自动锁被控端
- **被控静音**（`remoteMute`）：远程期间被控端静音，但控制端仍能听到声音
- **安全状态**（`statusTitle`）：已防护 / 需关注
- **解除快捷键**（`Setting.Shortcut.PrivacyScreen.*`）：被控端本地按快捷键解除防窥

> `closeScreen` 需要**虚拟显示器**支持——这就是它和 `virtualScreen` / `superScreen` 共用一套底层能力的原因。

## A6. 文件传输 / 剪贴板 / 拖拽

### A6.1 文件传输【证：`FileTrans.*`、`file_trans_v1~v4`（4 代协议）、`clipboard_file_transport`】

**双向能力**：
- 控制端 → 被控端：拖拽 / 复制粘贴 / 文件面板
- **被控端 → 控制端**：`FileTrans.DragDrop` 文案「把文件拖到这儿，即可发送给主控端」——被控端也能反向拖给主控端

**核心设计点**：
1. **权限探测**：`fileTransferControlledPermissionProbeRequestNotification` → 传输前先问被控端是否允许
2. **接收目录可配**：`file_transfer_default_receive_directory` / `custom_receive_directory`
3. **断点续传**：`Filetransfer.Resume` 需被控端版本支持（版本门槛拦截）
4. **冲突处理**：`FileTrans.Conflict`、`FileTrans.Permission`、`FileTrans.transFail`
5. **批量汇总**：通知文案「接收完成 %@ 个文件，失败 %@ 个」
6. **磁盘空间检查**：`error.noSpace` —— 无法完成粘贴，磁盘空间不足

### A6.2 剪贴板【证：`remote_clipboard_v1` → `v5`，5 代协议】

| 代 | 起始版本 | 推测能力 |
|---|---|---|
| v1 | 1.0.12 | 纯文本单向 |
| v2 | 1.3.12 | 双向文本 |
| v3 | 3.9.0 | + 富文本/HTML |
| v4 | 4.19.0 | + 图片 |
| v5 | 4.20.0 | + 文件（拖拽/复制粘贴传文件） |

**同步方向控制**：【证 `follow_local` / `follow_remote`】——跟随本地 / 跟随远程，避免双端互相覆盖。

### A6.3 拖拽 UI【证：`FileTrans.DragDrop`】

被控端拖文件到控制端窗口时的浮层：
- `ready.title`：拖拽到此处直接发送给主控端
- `overlay.title`：网易UU远程
- 确认框：`发送到 %@` / `存放路径：%@` / `**%@ 等 %d 项**` / [发送]
- 未知目标时：`主控端` / `由主控端设置`
- 可在 `[设置]-[常规]` 关闭

## A7. 远程终端（Terminal）

**【证】** 模块 `Terminal`（6）、文案 `Terminal.State`(22)/`Unlock`(20)/`Rename`(14)/`Error`(10)/`Connect`(9)/`Password`/`List`/`Stage`/`Kill`/`Close`，Helper 里有 `tmux`。

**能力**：
- 多会话列表（`TerminalListWindow`）
- 会话重命名（≤40 字符，重名检测）
- tmux 后端（会话持久化，断线可恢复）

**最关键的发现：终端与「自动解锁」深度耦合**【证 `Terminal.State` / `Terminal.Unlock`】

```
检测到被控端已锁屏
  ├─ 已开自动解锁 → 正在通过「自动解锁被控端」验证身份（此过程不会解锁被控端）
  ├─ 未开自动解锁 → 请输入被控端账户密码验证身份
  └─ 验证成功     → 正在启动被控命令行...
```

**注意文案细节**：「此过程**不会解锁**被控端」——即终端只是**借用凭据启动 shell**，不会把桌面解锁（安全设计）。

**错误处理链**：
- 密码错误次数限制（`第%d次/共%d次`）
- 超时（`验证超时，请检查被控端状态`）
- 被控 Mac 未登录（`mac402`，需先手动登录）
- Windows 未登录（`winNotLoggedIn`）

## A8. 超级屏 / 虚拟屏 / 多屏【证：`Screen.Super`(18)、`Screen.Virtual`(8)、`Control.Virtual`(7)、`multi_screen`】

| 能力 | 行为 | 依赖 |
|---|---|---|
| **超级屏** | 关闭被控端物理屏，所有内容适配到虚拟屏（高分辨率/高帧率） | 虚拟显示器驱动 |
| **虚拟屏** | 增加一块虚拟显示器，可命名/删除/多块 | 同上 |
| **多显示屏管理** | 切换 / 下一屏 / 屏幕布局 | 系统 API |

**触发逻辑**（重要产品设计）【证】：
- 分辨率不匹配 → 自动创建虚拟屏，弹提示「已自动使用虚拟屏」（可勾选不再提醒）
- 帧率超出被控端能力 → 建议改用超级屏
- 虚拟屏数量上限 → 拦截提示
- 最后一块虚拟屏不可删除

## A9. 端口映射【证：`PortMapping.*`、`port_mapping` 4.21.0】

内网穿透能力，把被控端端口映射到控制端 `127.0.0.1`：

| 字段 | 说明 |
|---|---|
| 名称 | 规则名 |
| 目标地址 / 目标端口 | 被控端服务 |
| 本地端口 | 控制端监听端口 |
| 映射状态 | 成功 / 失败 / 连接失败 / 设备离线 |
| 失败原因 | 本地端口已被占用 等 |

行为：连接后自动启动已启用规则的本地监听。

## A10. 落地优先级（给你的 Electron + Python agent）

### P0 — 体验及格线（1-2 周）

| # | 项 | 做法 |
|---|---|---|
| 1 | **媒体走 UDP** | WS 只传信令；媒体用 UDP + 序号 + NACK；全失败回 WS |
| 2 | **H.264 编码** | agent 侧 openh264/x264，关键帧 2s；前端 WebCodecs 解码 |
| 3 | **脏区检测** | mss 帧差，只传变化矩形；静止时降到 1fps 心跳 |
| 4 | **归一化坐标** | 输入事件改 0-1 浮点，多屏/分辨率无关 |
| 5 | **三档鼠标模式** | 主控端/被控端/智能，先做前两个 |
| 6 | **画质 3 档** | 省流/高清/原画（先不做超分/HDR） |

### P1 — 差异化（2-4 周）

| # | 项 | 做法 |
|---|---|---|
| 7 | 防窥模式（黑屏 + 屏保） | tkinter/Electron 全屏置顶窗；屏保图片走服务端上传 |
| 8 | 文件拖拽双向 | 被控端 → 控制端方向（官方有，你没做） |
| 9 | 剪贴板双向 + 方向控制 | 轮询 + hash 去重；跟随本地/远程 |
| 10 | 远程终端 | pty + tmux + xterm.js |
| 11 | 性能归因提示 | 采集 RTT/丢包/CPU，映射到官方 9 条文案 |
| 12 | 快捷键策略三档 | 优先控制端/优先被控端/例外列表 |

### P2 — 高成本（暂缓）

超级屏/虚拟屏（需系统虚拟显示器 API）、HDR、真彩、超分、端口映射、云电脑。

---

# PART B · UI 设计规范

## B1. 窗口与信息架构

**【证】** 窗口类：`ControlDeviceWindowController`、`ControlDeviceSmallWindow*`（小窗）、`TerminalListWindow`、`AppSettingWindow`、`ClientSecurityLockWindow`、`CloudDiskMountWindow`、`AboutAppWindow`

| 窗口 | 用途 | 特征 |
|---|---|---|
| 主窗口 | 设备列表 + 功能入口 | 侧边栏导航（`BG_Sidebar`） |
| **远控窗口** | 远程画面 | 可全屏/窗口化/小窗三种形态 |
| **小窗模式** | 悬浮小窗 | 置顶 + 不透明度可调 + 单设备 |
| 终端窗口 | 多会话终端 | 独立窗口，支持多开 |
| 设置窗口 | 配置 | 分类侧栏 |
| 锁定页 | 客户端锁 | 密码/验证码解锁 |

## B2. 控制端工具栏（核心 UI）

**【证】** 按钮图标 `icon_control_menu_*` 32 个 + 文案 `Control.Menu` 141 条。还原出的完整结构：

### B2.1 顶部工具栏（悬浮，可自动隐藏）

```
┌──────────────────────────────────────────────────────────────────────┐
│ [画质▾] [显示屏▾] [外设▾] [鼠标▾] [键盘] │ [麦克风] [声音▾] [文件] │      │
│                                          │ [安全▾] [工具▾] [更多▾] │ [全屏] [退出] │
└──────────────────────────────────────────────────────────────────────┘
```

**按钮 → 图标 → 文案对照表**：

| 按钮 | 图标 | 类型 | 展开内容 |
|---|---|---|---|
| 画质 | `icon_control_menu_quality` | 下拉 | 6 档 + 分辨率 + 帧率 + 真彩 + HDR + 自定义码率 |
| 显示屏 | `icon_control_menu_display` | 下拉 | 多显示屏管理 / 切换下一屏 / 虚拟屏 / 超级屏 |
| 外设 | `icon_control_menu_device` | 下拉 | 鼠标 / 键盘 / 手柄 |
| 鼠标 | `icon_control_menu_mouse` | 下拉 | 三模式 + 游戏鼠标模式 + 速度 |
| 麦克风 | `icon_control_menu_microphone` / `_device_microphone_on/off` | 开关 | 状态切换 + 音量指示 |
| 声音 | `icon_control_menu_sound` / `_close` / `_disable` | 下拉 | 播放被控端声音 / 被控静音 / 音量 |
| 文件传输 | `icon_control_menu_file_transfer` | 打开面板 | 双向文件列表 |
| 安全 | `icon_control_menu_safe` | 下拉 | 防窥模式 4 档 / 自动锁屏 / 被控静音 / 安全状态 |
| 工具 | `icon_control_menu_tool` | 下拉 | 快捷键配置 / Windows 设置 / 魔兽提醒 / 定时关机 |
| 更多 | `icon_control_menu_more` | 下拉 | 观看模式 / 小窗模式 / 网络状态 / 常驻网络 / 退出 |
| 全屏 | `icon_control_menu_fullscreen` | 开关 | 全屏 ↔ 窗口 |
| 退出 | `icon_control_menu_quit_control` | 动作 | 二次确认 |
| 窗口 | `icon_control_menu_window` | 下拉 | 自适应 / 不透明度 / 实际大小 1:1 |
| 不透明度 | `icon_control_menu_opacity` | 滑块 | 窗口透明度 |
| 快捷键配置 | `icon_control_menu_shortcut_config` | 打开 | 快捷键设置 |
| 后台挂断 | `icon_control_menu_background_hangup` | 动作 | 后台保持连接 |
| 定时关机 | `icon_control_menu_schedule_shutdown` | 打开 | 倒计时关机 |

### B2.2 画质下拉面板（详细设计）【证】

```
画质
├─ 自动 / 省流(480P) / 高清(1080P) / 超清(2K) / 蓝光(4K) / 原画
├─ ─────────
├─ 分辨率       跟随当前显示屏 / 跟随被控端 / 480P / 1080P / 2K / 4K / 其他分辨率
├─ 帧率上限     30 / 60(推荐) / 90 / 144
├─ ─────────
├─ 真彩         [开关]   （与 HDR 互斥，冲突时弹二选一）
├─ HDR          [开关]
├─ ─────────
└─ 启用自定义码率 [开关] → 显示码率滑块（自研产品：直接开放，附带宽预估提示）
```

**交互要点**：
- 档位切换即时生效，无需确认
- 能力不支持时置灰 + tooltip 说明原因（「当前被控端不支持 HDR」）
- 真彩/HDR 互斥 → 弹「关闭 HDR 并开启真彩」/「关闭真彩并开启 HDR」
- 降级时 toast：「设备性能受限，已自动降低到 %@ 画质」

### B2.3 安全下拉（防窥模式）【证】

```
安全状态：已防护 / 需关注
├─ 防窥模式
│   ├─ ○ 不启用      被控端屏幕未防护，旁人可见
│   ├─ ○ 黑屏防护    在被控端显示屏上显示黑屏画面，遮挡屏幕内容
│   ├─ ○ 关闭显示屏  被控端屏幕已熄屏，彻底防护隐私
│   └─ ○ 隐私屏保    被控端屏幕已防护，遮挡屏幕内容  [设置隐私屏保 →]
├─ ─────────
├─ 自动锁屏      [开关]  结束远程自动锁屏
└─ 被控静音      [开关]  已静音 / 已外放
```

**隐私屏保设置面板**：
- Tab：预设 / 自定义
- 预览区（`PrivacyScreenPreviewWindow`）
- 上传：≥1920×1080、≤2M、JPG/PNG
- 状态标记：「正在使用」「上次使用」
- 按钮：确定并启用 / 修改

## B3. 远控信息面板（RemoteInfo）【证 28 个字段】

```
┌─ 远程连接信息 ─────────────────── [复制全部信息] ─┐
│ 连接时间: 00:32:15                               │
│ ─────────────────────────────────                │
│ 网络延时   当前 18ms / 平均 22ms / 最高 87ms      │
│ 丢包率     0.3%                                  │
│ 带宽占用   12.4 Mbps                             │
│ ─────────────────────────────────                │
│ 帧率       60 fps                                │
│ 帧延时     16.7 ms                               │
│ 画质       超清 (2K)                             │
│ 采集方式   ScreenCaptureKit                      │
│ 编码模式   H.265                                 │
│ 编解码器   硬编 / 硬解                            │
│ ─────────────────────────────────                │
│ 加密通道   ✓                                     │
│ 连接方式   局域网直连 / 安全中转连接              │
│ ─────────────────────────────────                │
│ 控制端     192.168.1.10  macOS 14.5  4.48.1      │
│ 被控端     192.168.1.20  Windows 11  4.48.1      │
└──────────────────────────────────────────────────┘
```

**字段清单**（可直接建表）：`connectionTime` / `latency.current|average|highest` / `packageLost` / `bandWidth` / `frame` / `frameLatency` / `qualityFrame` / `capture` / `codec` / `encoderDecoder`(hardwareEncoder/softwareEncoder/hardwareDecoder/softwareDecoder) / `EncryptionChannel` / `SecurityLan|SecurityServiceTransit` / `clientIp` / `clientSystem` / `clientVersion` / `terminalIP` / `terminalSystem` / `controlTerminalVersion`

> 「复制全部信息」是排障利器，建议照抄。

## B4. 观看模式工具栏【证：`Control.ViewMode.*`】

控制端有三态：**操控** / **观看（+批注）**。

```
观看模式工具栏（底部/顶部浮条）
[✋ 拖拽浏览] [✏️ 批注] [🔍 放大 ⌘=] [🔍 缩小 ⌘-] [🪟 窗口模式] [✕ 隐藏工具栏]
```
- 「隐藏工具栏」带快捷键提示
- 批注开关：`viewModeToggleAnnotation`
- 工具栏显示/隐藏：`viewModeToggleToolbar`

## B5. 小窗模式【证：`Control.SmallWindow`、`ControlDeviceSmallWindow*`】

| 能力 | 说明 |
|---|---|
| 置顶 | `topMost` |
| 不透明度 | `opacity` 滑块 |
| 切换屏幕 | 小窗内切屏 |
| 效果预览 | `Preview.title` 小窗效果预览 |
| 限制 | **仅支持单设备**，切换设备会关掉原小窗 |
| 退出 | `exit` 退出小窗模式 |

组件结构：`ControlDeviceSmallWindowOverlayHostView` + `PreviewContentView` + `OpacityTipView` + `ButtonTipView` + `DialogView` + `ErrorView`

## B6. 设置页结构【证：`Setting.Menu` 16 条】

```
设置
├─ 常用设置           General
├─ 设备管理           deviceManage
├─ 安全锁定           securityLock      （客户端锁）
├─ 远程协助           remoteHelp
├─ 快捷键             Shortcut
├─ 键盘               Keyboard（按键映射/快捷键）
├─ 代理设置           Proxy
├─ 文件传输           FileTransfer（接收目录）
├─ 防止休眠           PreventSleep
├─ 关于               about
├─ 检查更新           checkUpdate
├─ 帮助与反馈         feedback
├─ 常见问题           FAQ
├─ 在线客服           Online.Customer.service
├─ 上传日志           uploadLog
└─ 退出登录           User.logout
```

### B6.1 快捷键页（22 个可配置功能）【证 `Setting.Keyboard.Function.*`】

| 功能 | key |
|---|---|
| 老板键（隐藏/显示所有客户端窗口） | `bossKey` |
| 发送 Ctrl+Alt+Delete | `ctrlAltDelete` |
| 打开文件传输 | `fileTransfer` |
| 显示/隐藏悬浮球 | `floatingBall` |
| 远控窗口全屏/窗口化 | `fullScreen` |
| 锁定鼠标在远控窗口中 | `lockMouse` |
| 静音/取消静音 | `muteController` |
| 显示/隐藏网络状态 | `networkStatus` |
| 切换上一个/下一个屏幕 | `previousScreen` / `nextScreen` |
| 被控时解除防窥模式 | `privacyMode` |
| 开启/关闭隐私屏保 | `privacyScreenSaver` |
| 立即退出远控 | `quitRemote` |
| 使用被控端鼠标/解锁鼠标 | `remoteMouseMode` |
| 进入/退出小窗模式 | `smallWindowMode` |
| 切换远控窗口 | `switchRemoteWindow` |
| 观看模式 / 切换观看操控 | `viewMode` / `viewModeToggle` |
| 观看模式开关批注 | `viewModeToggleAnnotation` |
| 观看模式显示/隐藏工具栏 | `viewModeToggleToolbar` |

**另有两组独立快捷键**：
1. **仅控制端响应的快捷键**（`ControllerOnly`）——不发送到被控端
2. **被控时解除防窥模式**（`Setting.Shortcut.PrivacyScreen`）——在被控端本地按

**录制交互**：「按下键盘按键可设置快捷键，按下 ⌫ 可删除」，冲突提示「快捷键冲突」，非法键「该按键不可设置」。

### B6.2 代理设置【证 28 条】
- 模式：不使用 / 系统代理 / 手动
- 手动：协议（HTTP / SOCKS5）、地址、端口、用户名（选填）、密码（选填）
- [检测] 按钮 → 「检测到此代理服务可用」/「此代理服务不可用,请检查设置」
- 状态：检测中 / 已启用

### B6.3 客户端锁（SecurityLock）【证 22 条】
- 安全密码：8-16 位
- 三种自动锁定策略：
  1. 关闭主界面时自动锁定
  2. 远程协助本设备期间自动锁定（结束后自动解锁）
  3. 启动时自动锁定
- 解锁方式：密码 / 短信验证码（`forgotPassword` → `getCode` → 60s 倒计时重发）

## B7. 主页 / 设备卡片

**【证】** `Home.Device`(42)、`icon_device_*`(84)、`Home.SecondScreen`(35)

**设备卡片状态**：
| 状态 | 文案 |
|---|---|
| 在线可连 | 进入桌面 / 启动应用 |
| 被本机控制 | 正在被【本机】%@ 控制中 |
| 被他人控制 | 正在被 %@ 远程控制中 |
| 副屏连接中 | 副屏连接中 |
| 离线 | 「远程开机」按钮 / 离线灰态 |

**设备操作菜单**【证 `Home.Device.Menu.*`、`NowDevice.More`】：
刷新 / 重命名 / 重启电脑 / 关机 / 终端 / 断开远控 / 删除设备

**接管逻辑**（重要）【证】：
```
当前设备正在被控中
  ├─ 远控        → 「接管设备后可进行远控」  [接管设备]
  ├─ 文件传输    → 「接管设备后可传输文件」
  └─ 副屏中      → 「继续远控将会断开副屏连接」 [继续发起远控]
```

**快速启动应用**（`Device.App`）：添加/管理远程应用，支持搜索、置顶、启动、关闭。
- 隐私声明：「使用此功能需要连接并访问被控端以获取应用。**网易UU远程不会上传应用信息**」

**无线副屏**（`Home.SecondScreen` 35 条）——把移动设备扩展为**可触控副屏**：
- 设置项：方向（横向/纵向）、布局方向、帧率、断开
- 状态：可连接 / 连接中 / 远控中 / 已作为副屏
- 错误矩阵：设备离线、版本过低、被控中、已被占用、驱动异常、超时

## B8. 设计 Token（从 Assets.car 提取）【证 719 个资源】

### B8.1 颜色

**中性色（黑色透明度梯度）**：
```
Black_2  Black_3  Black_4  Black_5  Black_6  Black_8
Black_10 Black_15 Black_20 Black_30 Black_35 Black_45
Black_60 Black_85 Black_90
```

**白色**：`White` `White_50` `White_70` `White_80`
**灰阶**：`Gray2_60` `Gray3_80`

**品牌色阶**（8 组）：
```
Brand_Brand1 (+_60 _70 _80 _90)
Brand_Brand2 (+_30 _80 _90)
Brand_Brand3
Brand_Brand4
Brand_Brand5_50
Brand_Brand6
Brand_Brand7_5  Brand_Brand7_10
Brand_Brand8
B000  B200  B600
```

**语义色**（可直接用作 CSS 变量名）：
```
--color-bg-0 / --color-bg-4                      背景层级
--color-primary-normal / -hover / -active        主色三态
--color-custom-button1-normal/-hover/-active/-disabled   按钮四态
--color-connect-state-high / -mid / -low         连接质量三档
--color-control-device-toolbar-connect-state-signal      信号强度
--color-control-device-net-detail-high / -mid    网络详情
--color-view-mode-toolbar-selected / -pressed    观看模式工具栏
--color-floating-ball-menu-*                     悬浮球
--color-home-device-wallpaper-mask               设备卡壁纸遮罩
--color-paste-file-bg / -detail_error            粘贴文件
--color-textfield-focus-border-color             输入框聚焦
--color-login-bg / --color-login-link-title-*    登录页
--color-device-manage-popup-bg                   弹窗
```

**背景语义**：`BG_Sidebar` `BG_Hover` `BG_Disabled` `BG_Reset` `BG_Brand4` `BG_DeviceToolHome` `BG_DeviceToolNormal`

### B8.2 图标规范

所有图标遵循 **`{状态}_{尺寸}_{态}`** 命名：
```
icon_arrow_down_18_N   （18pt，Normal）
icon_arrow_down_18_H   （18pt，Hover）
icon_arrow_down_18_P   （18pt，Pressed）
icon_eyes_close_24_N/H/P
```
→ 尺寸档：`16` / `18` / `20` / `24` / `40`；态：`N`(normal) / `H`(hover) / `P`(pressed)

**这套命名规范建议直接复用**——图标资源按 `name_size_state` 组织，代码里按 `name_size` 取当前态，极简。

### B8.3 字体
`Barlow-SemiBold.ttf`（`ATSApplicationFontsPath`）—— 数字/英文用 Barlow SemiBold，中文走系统字体。

> ⚠️ **视觉还原缺口**：颜色 token 的**具体色值**（如 `Brand_Brand1` 到底是多少 HEX）未提取——Assets.car 只存名字不存语义对照。需要**运行时截图取色**或解析 .car 内部的颜色对象才能拿到。圆角、字号、间距同样缺失。

## B9. 交互细节清单（可直接抄）

| # | 细节 | 来源 |
|---|---|---|
| 1 | 工具栏自动隐藏，鼠标移到顶部/边缘唤出 | `Control.Menu.show` |
| 2 | 网络状态可「常驻显示」或按需显示 | `netInfo` / `network` |
| 3 | 退出远控二次确认：「确定要退出与 %@ 的远程连接吗？」 | `Control.SmallWindow.ExitRemote` |
| 4 | 多屏时提示「当前远程窗口仅有 1 个屏幕，无需切换」 | `switchNextScreen.singleScreenToast` |
| 5 | 快捷键提示内嵌在 tooltip：「批注（⌘⇧A）」 | `Control.ViewMode.Toolbar.Tooltip.penWithShortcut` |
| 6 | 被控端版本过低时**拦截而非报错**，给「立即更新 / 稍后再说」 | `Control.Trigger.Upgrade.Alert.*` |
| 7 | 升级中提示「被控端将在 %@ 秒后重启软件完成更新」 | `Upgrade.Top.Toast.title` |
| 8 | 麦克风失败有 **13 种**分类错误（驱动/权限/冲突/BSOD风险） | `Control.Menu.microphone.error.*` |
| 9 | 后台运行权限缺失时报「错误码 1001，请前往设置-通用-登录项」 | `Common.Error.Connection.Error.*` |
| 10 | 未登录时点击任何功能 → 弹登录引导，文案说明「登录后能做什么」 | `NoLogin.Alert` 25 条 |
| 11 | 本机被控中无法登录 → 「断开连接并登录」 | `NoLogin.Alert.OnControlled` |
| 12 | 拖拽文件浮层显示目标与路径，多文件显示「%@ 等 %d 项」 | `FileTrans.DragDrop.confirm.*` |

## B10. UI 落地建议（Electron）

你现在是 Electron + web/。建议：

```
web/
├─ styles/
│   ├─ tokens.css        ← 移植 B8.1 的颜色变量（值需截图取色）
│   └─ icons.css         ← icon-font 或 SVG sprite，按 name_size_state
├─ components/
│   ├─ ControlToolbar/   ← 顶部悬浮工具栏（B2）
│   ├─ QualityPanel/     ← 画质下拉（B2.2）
│   ├─ PrivacyPanel/     ← 防窥模式（B2.3）
│   ├─ RemoteInfoPanel/  ← 连接信息（B3）
│   ├─ ViewModeBar/      ← 观看模式工具条（B4）
│   ├─ SmallWindow/      ← 小窗（B5）
│   └─ DeviceCard/       ← 设备卡片（B7）
└─ views/
    ├─ Home/             ← 设备列表
    ├─ Remote/           ← 远控画面 + 工具栏
    └─ Settings/         ← 设置（B6）
```

**关键实现点**：
1. 远控画面用 `<canvas>` + WebCodecs，不要用 `<video>`（延迟高）
2. 工具栏用 CSS `backdrop-filter: blur()` + 半透明背景（`Black_60`~`Black_85`）
3. 工具栏 `position: absolute` + 鼠标进入热区（顶部 40px）唤出，2s 无操作淡出
4. 小窗模式用 `BrowserWindow` 的 `setAlwaysOnTop` + `setOpacity`
5. 快捷键用 `globalShortcut`（主进程）+ `before-input-event`（渲染进程）

---

# 附录：证据索引

| 类别 | 位置 |
|---|---|
| 中文文案 1809 条 | `uu-reverse/zh-strings.json` |
| 资源名 719 个 | `uu-reverse/assets-names.txt` |
| 字符串层导出 | `uu-reverse/strings/{UURemote,Daemon,Service,streamer,uuyc,Server}.txt` |
| 媒体配置 | `UURemote.app/Contents/Resources/streamer-config.json` |
| Launchd 配置 | `.../Resources/com.netease.uuremote.{daemon,agent}.plist` |

**未验证项**（需运行时或反编译确认）：
1. 颜色 token 具体色值、圆角、字号、间距
2. `ACTION_TYPE_*` 帧格式（推测 Protobuf，有 `SwiftProtobuf` 依赖）
3. 信令消息体结构（`message_type` 内存字段，未落到字符串层）
4. UI 实际布局尺寸（需截图或 `decode-interface-builder` 解析 nib）
5. 编码参数细节（GOP、QP、码控策略）

> 本文档为**逻辑与行为重建**，非源码还原。用于互操作性开发与学习研究。