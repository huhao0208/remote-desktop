# UU 远程（com.netease.uuremote v4.48.1 / macOS）功能逆向分析报告

> 分析方式：REA 工具链静态分析（Mach-O 依赖、字符串层、plist、资源、XPC/Launchd 配置）
> 目标：`/Applications/UURemote.app`（网易 UU 远程 macOS 客户端）
> 用途：互操作性开发 / 功能学习——为自建 `uu-remote-server` 补齐功能面
> 结论性质：**逻辑与行为重建，非源码还原**；标注「推测」的条目未经运行时验证

---

## 一、功能解释

### 1.1 进程与权限架构（这是理解一切功能的前提）

| 组件 | 路径 | 角色 | 证据 |
|---|---|---|---|
| `UURemote` | `Contents/MacOS/UURemote` | 主 UI 进程（SwiftUI + AppKit，56MB universal） | Info.plist / otool |
| `UURemoteDaemon` | `Contents/MacOS/UURemoteDaemon` | **root 守护进程**（LaunchDaemon，`-daemon`） | `com.netease.uuremote.daemon.plist` |
| `UURemoteService` | `Contents/MacOS/UURemoteService` | 会话代理（LaunchAgent，`-agent`） | `com.netease.uuremote.agent.plist` |
| `UURemoteHelper.xpc` | `Contents/XPCServices/` | 权限隔离辅助（输入注入/捕获的提权出口） | XPC 目录 |
| `libstreamer.dylib` | `Contents/Frameworks/` | 媒体栈（捕获→编码→传输→渲染） | 25MB dylib |
| `UURemoteServer` | `Contents/Helpers/` | 本地服务组件 | Helpers 目录 |
| `uuyc-cli` | `Contents/Helpers/` | 云电脑 CLI（`cloudpc`/`connect`/`assist` 子命令） | 字符串层 |
| `tmux` | `Contents/Helpers/` | 远程终端复用（多会话终端功能） | Helpers 目录 |

**关键设计 1：登录窗口级远控**
`agent.plist` 的 `LimitLoadToSessionType = [LoginWindow, Aqua]`，意味着被控端在**用户未登录时的登录界面**就已运行。这是"远程开机后直接看到锁屏/登录界面并输入密码"的实现基础。（证据：`agent.plist`）

**关键设计 2：双 Mach Service 通道**
- `com.uuremote.agent.controlled`（被控端）
- `com.uuremote.agent.controller`（控制端）
- `com.uuremote.daemon`（守护）
- `com.uuremote.arbitrator`（**仲裁者**，推测用于多控制端/权限仲裁）
- `com.uuremote.service.consoleuser`（**控制台用户会话**，用于跨会话切换）
- `com.uuremote.subprocessmanager`（子进程管理）
- `com.uuremote.heartbeat`（心跳）
- `com.uuremote.filemonitor.auto`（文件监控，文件传输用）

**关键设计 3：root 权限**
daemon 的 `Umask = 0` + `KeepAlive` + `RunAtLoad`，说明它需要高权限执行：输入注入、屏幕捕获、锁屏/重启/关机、WOL 发送。

---

### 1.2 媒体栈：WebRTC + QUIC 双栈（不是纯 WebRTC）

**采集**（libstreamer 依赖）：`ScreenCaptureKit`（macOS 12.3+ 系统级捕获）、`AVFoundation`（摄像头/麦克风）、`CoreAudio`/`AudioUnit`（音频）

**编码**（字符串层证据）：`H264`、`H265`、`VP8`、`VP9`、`lpcm`
→ H.265 为主力（带宽优先），VP8/VP9 兼容 Web 端（手机浏览器免装 App 的场景）

**传输**（字符串层证据）：
| 证据 | 含义 |
|---|---|
| `WebRTC`、`RTP/SAVP`、`DTLS/SCTP`、`TCP/DTLS` | 标准 WebRTC 通道，SRTP 加密，DTLS over TCP 做 UDP 被封时的兜底 |
| `quic`、`quicv2`、`QuicTran` | **QUIC 通道（v2 已上线）**，低延迟/弱网抗性 |
| `ice_f`、`iceServe`、`start_ice`、`turn` | ICE 打洞 + TURN 中继 |

**渲染**：`Metal` / `MetalKit` / `IOSurface`（零拷贝 GPU 纹理路径），`MetalView` 导出类

**结论**：媒体面 = 自研 RTC（WebRTC 协议族 + QUIC 双通道），硬件编解码走 VideoToolbox，渲染走 Metal。**没有 FFmpeg / libwebrtc 外部依赖**（全部静态链接进 dylib）。

---

### 1.3 功能域地图（按模块，29 个）

源码构建路径泄露了模块结构（`nrd-mac-client/Module/`），按出现频次排序：

| 模块 | 频次 | 功能域 |
|---|---|---|
| `ControlDevice` | 82 | **控制端核心**：画质、输入、隐私屏、标注、游戏模式 |
| `CloudPc` | 58 | 云电脑（创建/磁盘/网络测速/UI 开关） |
| `AppSetting` | 50 | 应用设置 |
| `Login` | 40 | 登录（手机/邮箱/扫码） |
| `NowDevice` | 38 | 本机设备（WOL、状态、被控开关） |
| `DeviceAssist` | 34 | 设备协助（访客协助/远程协助） |
| `FileTransfer` | 32 | 文件传输（4 代协议） |
| `SpiltHome` | 28 | 分栏主页 |
| `FloatingBall` | 22 | 悬浮球（控制端工具栏） |
| `UIStyleSheet` | 14 | 样式表 |
| `SwitchDevice` | 12 | 切换设备 |
| `DeviceList` | 10 | 设备列表 |
| `CloudDisk` | 10 | 云磁盘 |
| `ClientSecurityLock` | 10 | **客户端安全锁**（本机被控密码锁） |
| `AppPermission` | 10 | 应用权限 |
| `PortMapping` | 8 | **端口映射**（内网穿透） |
| `ControlledDetail` | 8 | 被控端详情 |
| `Terminal` | 6 | **远程终端**（tmux 多会话） |
| `DeviceInfo` / `RenameDevice` / `AddApp` / `ManageApp` | 6/4/6/4 | 设备信息、改名、添加/管理远程应用 |
| `PasteFile` | 4 | 粘贴文件（剪贴板文件传输） |
| `VersionUpdate` / `HomeUpdateConfirm` | 4/4 | 版本更新 |
| `DownloadMobile` | 4 | 下载移动端 |
| `DeviceGuide` | 4 | 设备引导 |
| `AboutApp` / `Feedback` / `MessageCenter` / `MemberPermission` | 2 各 | 关于、反馈、消息中心、会员权限 |

**未被独立建模块但存在于功能开关的功能**：隐私屏、远程开机、多屏、游戏手柄、超分、HDR、标注、端口映射、虚拟屏。

---

### 1.4 功能灰度开关全表（62 项，含起始版本）

这是官方自己的"能力清单"，比模块名更精确：

| 功能键 | 起始版本 | 功能含义 |
|---|---|---|
| `remote_clipboard_v1`→`v5` | 1.0.12 → 4.43.0 | 剪贴板同步，**5 代协议演进** |
| `file_trans_v1`→`v4` | 2.5.0 → 4.36.0 | 文件传输，**4 代协议演进** |
| `screen_privacy` / `_enhanced` / `privacy_wallpaper` | 1.2.5 / 4.4.0 / 4.23.0 | 隐私屏（黑屏）/ 增强隐私 / 隐私壁纸 |
| `screen_virtual` | 1.2.1 | 虚拟屏（无头 Mac 扩展显示） |
| `multi_screen` | 4.0.0 | 多屏切换 |
| `screen_super` / `manual_super_screen` / `fps_super_screen` | 4.2.3 / 4.27.0 | 超分辨率 / 手动超分 / 超分高刷 |
| `screen_hdr` | 4.2.2 | HDR 显示 |
| `screen_chroma` | 2.4.0 | 色度采样（4:2:0 / 4:4:4） |
| `screen_orientation` | 4.16.0 | 屏幕方向 |
| `screen_zoomscale` | 3.4.0 | 缩放比例 |
| `fps_90` / `fps_144` | 1.0.0 / 2.2.0 | 90 / 144 帧率 |
| `quality_normal` | 1.0.0 | 画质档位 |
| `custom_bitrate` | 3.4.1 | 自定义码率 |
| `delay_reason` | 3.1.3 | **延迟原因诊断**（网络/编码/渲染归因） |
| `follow_local` / `follow_remote` | 2.3.1 / 3.0.0 | 分辨率跟随本地 / 跟随远程 |
| `device_mouse` / `device_keyboard` / `device_gamepad` | 1.5.22 | 输入设备（鼠标/键盘/手柄） |
| `virtual_mouse` / `smart_mouse` / `simulate_mouse` | 1.1.0 / 3.2.1 / 3.1.37 | 虚拟鼠标 / 智能鼠标 / 模拟鼠标 |
| `pad_touch` | 1.1.0 | 平板触控模式 |
| `device_microphone` | 4.16.800 | 远程麦克风（双向语音） |
| `remote_mute` / `voice_setting` | 1.1.0 | 远程静音 / 语音设置 |
| `device_lock` / `device_reboot` / `device_shutdown` | 1.0.0 | **远程锁屏 / 重启 / 关机** |
| `device_task_manager` | 1.0.0 | **远程任务管理器** |
| `auto_unlock` | 1.5.2 | **自动解锁**（远程输入密码解锁） |
| `disconnect_lock` | 1.1.4 | 断连锁屏 |
| `watch_unlock` | 4.3.0 | **手表解锁**（Apple Watch 解锁被控 Mac） |
| `remote_app_list` | 4.18.0 | 远程应用列表 |
| `annotation_v1` / `v2` | 4.35.0 / 4.40.0 | **屏幕标注**（控制端在画面上画圈/写字） |
| `port_mapping` | 4.21.0 | **端口映射**（内网穿透） |
| `mumu_control` | 3.13.1 | **MuMu 模拟器控制**（网易自家模拟器联动） |
| `wow_detection` | 4.14.0 | 游戏检测（推测：游戏场景自动优化） |
| `desktop_display` / `windows_display` | 1.0.0 | 桌面显示 / 窗口显示（单窗口远控） |
| `full_screen` / `manual_transfer` / `operation_guide` | 1.0.0 / 4.9.0 / 2.0.0 | 全屏 / 手动传输 / 操作引导 |
| `virtual_plan` | 1.0.0 | 虚拟方案（推测：多套显示方案预设） |
| `controlled_update` | 2.5.0 | 被控端远程升级 |
| `remote_connection_cli` / `_v2` | 4.23.0 / 4.39.0 | **CLI 远程连接**（给自动化/Agent 用） |

---

### 1.5 远程指令集（被控端 RPC 动作，29 个）

`ACTION_TYPE_*` 枚举，这是控制端→被控端的**指令协议**：

| 类别 | 动作 |
|---|---|
| 捕获控制 | `CAPTURE_DESKTOP`、`CAPTURE_WINDOW`、`CAPTURE_MUMU`、`QUIT_CAPTURE`、`RESTART_CAPTURE`、`STOP_CAPTURE` |
| 电源管理 | `SHUTDOWN_SYSTEM`、`REBOOT_SYSTEM`、`LOCK_SYSTEM`、`AUTO_UNLOCK_SYSTEM`、`SET_AUTO_LOCK` |
| 音频 | `MICROPHONE_OPENED/CLOSED`、`SPEAKER_OPENED/CLOSED`、`MUTE_SYSTEM`、`MUTE_PERMANENT`、`MUTE_TEMPORARY`、`MUTE_RESTORE` |
| 桌面交互 | `SHOW_DESKTOP`、`SHOW_TASKMGR`、`SHOW_WINDOWS`、`KEY_TOGGLE` |
| 系统信息 | `ACQUIRE_SYSTEM_INFO`、`STOP_ACQUIRE_UPDATE` |
| 心跳/应用 | `ECHO_REQUEST`、`ECHO_RESPONSE`、`NEED_RESTART_USERAPP` |

---

### 1.6 服务端 API 面（63 个端点）

#### A. 你已实现（srv2 覆盖）

`login/by_mobile`、`login/by_qrcode`、`user/info`、`user/logout`、`device/{pc,android,android_tv}/init`、`device/list`、`device/rename`、`device/delete`、`room/create`、`room/join/refetch`、`room/clear`、`room/list`、`transport/rpc/*`、`ws/signaling`

#### B. 未实现（按价值排序）

**P0 — 核心体验缺口**

| 端点 | 功能 |
|---|---|
| `/api/v1/device/macos/init` | **macOS 设备注册**（你只做了 pc/android/android_tv） |
| `/api/v1/device/wake_on_lan/info` + `/wake_on_lan/req` | **远程开机**（WOL 魔术包） |
| `/api/v1/room/join/share/by_code` | 分享码加入房间 |
| `/api/v2/room/join/share/by_confirmation` | **确认式加入**（被控端点确认） |
| `/api/v2/room/share/control_mode` | **控制模式切换**（仅查看/完全控制） |
| `/api/v2/room/share/cancel_remote_assist` | 取消远程协助 |
| `/api/v1/tool/configures_with_version` | **配置下发**（功能灰度/开关按版本下发） |
| `/api/v1/tool/keymapping/list` | 按键映射表（游戏/快捷键） |

**P1 — 设备与账号**

| 端点 | 功能 |
|---|---|
| `/api/v1/device/groups/of/my` | 设备分组 |
| `/api/v1/device/preferences` | 设备偏好 |
| `/api/v1/device/share/info` · `/share/saved/favorites` | 设备分享信息 / 收藏 |
| `/api/v1/device/mac_controllable` | macOS 可被控判定 |
| `/api/v1/device/update/prepare` | 被控端升级准备 |
| `/api/v1/login/by_email` | 邮箱登录 |
| `/api/v1/qrcode/gen/login` · `/qrcode/login/status` | 扫码登录轮询（拆成两接口） |
| `/api/v1/user/ticket/for/wvlogin` | WebView 登录票据 |
| `/api/v1/user/verify/realname` | 实名认证 |
| `/api/v1/security/client_lock/{send_code,reset}` | **客户端锁**（本机被控密码） |
| `/api/v1/security/{mobile,email}/.../code` | 验证码 |

**P2 — 访客协助（全新能力域）**

| 端点 | 功能 |
|---|---|
| `/api/v1/guest/create` | 创建访客身份 |
| `/api/v1/guest/room/create` | 访客房间 |
| `/api/v1/guest/share/info` · `/share/cancel` | 访客分享查询/取消 |
| `/api/v1/guest/room/share/upload/sign` | 分享素材上传签名 |

**P3 — 云电脑 / 云盘（全新能力域）**

`cloud_pc/{create,disks,features,ui_switch,network/speed}`、`cloud_disk/consumption`、`device/cloud_pc/list`

**P4 — 运营与运维**

`member/{entitlements,trial}`、`campaign/{interactions,strategies}`、`message/summary`、`event/report/batch`、`release/fetch/*`（5 个）、`tool/fp/token`、`tool/feedback_3rd/configure`、`room/notify/user_device/upload_log`

#### C. 信令服务器发现机制

字符串层：`signaling_server`、`signaling_list`、`sni_required_signaling_list`、`signalingServer`、`signalingList`、`sniRequiredSignalingList`

→ 客户端从服务端拉取**信令服务器列表**，其中部分标记为「要求 SNI」（必须用域名而非 IP 访问）。这解释了为什么你的 mitmproxy 改写需要覆盖多个域名。

---

### 1.7 输入与文件协议

**输入事件**（字符串层）：`mouse_move`、`mouseDown`、`mouseUp`、`MouseEvent`、`Scroll`、`keyDown`、`keyUp`、`KeyEvent`、`keyCode`、`touchEvent`、`inputEvent`
→ 输入是结构化事件对象（非原始 HID），控制端采样后序列化传输，被控端注入。

**指针策略**：`com.netease.uuremote.pointer.acceleration`、`mouse_cursor`、`smart_mouse`、`virtual_mouse`、`gameModeMouseSpeed`
→ 有独立的指针加速/智能鼠标算法（游戏场景降低延迟，办公场景做加速曲线）。

**文件传输**（Daemon/Service 字符串）：
- `file_transfer_default_receive_directory` / `file_transfer_custom_receive_directory`（接收目录可配）
- `clipboardDragDrop` / `clipboardFileTransport` / `clipboardReceiveCopy`（**拖拽/复制粘贴传文件**）
- `fileTransferControlledPermissionProbeRequestNotification`（**被控端权限探测**：先问对方是否允许）
- `fileTransferControlledPermissionDeniedNotification`（拒绝通知）
- `com.netease.uuremote.file-transfer.local-directory-io` / `local-directory-timeout`

**剪贴板**：5 代协议（v1→v5），支持文本 + 文件 + 富内容（推测 v5 支持图片/格式保留）。

---

## 二、证据清单

| 证据 | 位置/值 |
|---|---|
| 应用标识 | `com.netease.uuremote`，v4.48.1（Build 633） |
| 二进制 | `Contents/MacOS/{UURemote,UURemoteDaemon,UURemoteService}`（universal x86_64+arm64） |
| 媒体库 | `Contents/Frameworks/libstreamer.dylib`（25MB），导出 `ExchangeControlledInterface` / `ExchangeControllerInterface` / `MetalView` |
| 媒体依赖 | ScreenCaptureKit、VideoToolbox、CoreMedia、CoreVideo、IOSurface、Metal、MetalKit、AudioToolbox、AudioUnit、CoreAudio、AVFoundation |
| 编码证据 | `H264` / `H265` / `VP8` / `VP9` / `lpcm` / `RTP/SAVP` / `DTLS/SCTP` / `TCP/DTLS` / `quic` / `quicv2` / `QuicTran` |
| 守护配置 | `Contents/Resources/com.netease.uuremote.daemon.plist`（LaunchDaemon, KeepAlive, Umask 0） |
| 代理配置 | `Contents/Resources/com.netease.uuremote.agent.plist`（LimitLoadToSessionType: LoginWindow + Aqua） |
| XPC/Mach | `com.uuremote.{agent.controlled,agent.controller,daemon,arbitrator,service.consoleuser,subprocessmanager,heartbeat,filemonitor.auto}` |
| API 域名 | `api.nrd.nie.163.com`、`api-dcdn.nrd.nie.163.com` |
| 源码路径泄露 | `/Users/game-netease/Desktop/Runner/Builds/nrd-Mac/KGGzibPf8/0/nrd/nrd-mac/nrd-mac-clinet/nrd-mac-client/Module/...` |
| 功能开关 | 62 项 `{"feature":...,"original_version":...}` 字符串表 |
| 指令枚举 | 29 个 `ACTION_TYPE_*` |
| URL Scheme | `uuremote://` |
| 权限声明 | 麦克风（远程通话）、下载文件夹（远程文件拖拽） |
| 手柄 | `GCSupportedGameControllers: ExtendedGamepad` |
| 本地证据留存 | `/Users/hoha/WorkBuddy/2026-11-20-18-18-50/uu-reverse/strings/*.txt` |

---

## 三、局限与未知

1. **无函数级反编译**：本机未配置 Ghidra/Hopper/IDA，`rea inspect` 返回 `provider_unavailable`。上述结论来自 Mach-O 元数据、依赖图、字符串层、plist、XPC 配置——**属于"结构级证据"，不是"算法级证据"**。具体加密算法、信令帧格式、QUIC 握手参数均未验证。
2. **universal Mach-O 限制**：Ghidra/Kuna provider 不接受 fat binary，若要深入函数级分析，需先 `lipo -thin arm64` 抽薄片再导入。
3. **符号被 strip**：主二进制仅 3978 个符号（Swift 类符号仅 2 个），类名/函数名大量丢失；`Module/` 路径与功能开关是仅存的命名线索。
4. **`ACTION_TYPE_*` 的确切帧格式未知**：只知道动作枚举名，不知道序列化方式（Protobuf? JSON? 自定义二进制?）。有 `SwiftProtobuf` 依赖，推测是 Protobuf。
5. **房间配置 14 字段**：你的 srv2 声称已对齐 RoomConfig 14 字段，本轮未从二进制中提取到字段名清单（可能在已加密的配置下发或运行时才出现）。
6. **云电脑后端**：`cloud_pc/*` 只是客户端调用点，服务端实现完全不可见。
7. **未做运行时验证**：所有结论未经实际抓包/动态验证，与真实报文可能有差异。

---

## 四、重建建议（针对你的 `uu-remote-server` 技术栈）

### 4.1 立即可补（P0，1-2 天）

| 项 | 落点 | 做法 |
|---|---|---|
| macOS 设备注册 | `srv2/server.py` 加 `/api/v1/device/macos/init` | 复用现有 pc 分支，device_type 加 `macos` |
| 远程开机 WOL | 新端点 `/api/v1/device/wake_on_lan/{info,req}` | info 返回目标 MAC + 广播地址；req 由**同网段任一在线 Agent** 发魔术包（UDP 9/7，6×0xFF + 16×MAC） |
| 分享码加入 | `/api/v1/room/join/share/by_code` | 房间生成 6-8 位短码，落 sqlite，校验后复用 join 逻辑 |
| 确认式加入 | `/api/v2/room/join/share/by_confirmation` | 走你已有的 RPC 通道（request→被控端 poll→respond），复用 30s 超时 |
| 控制模式 | `/api/v2/room/share/control_mode` | 房间级字段 `control_mode: view_only|full`，信令层对被控端下发权限位 |
| 配置下发 | `/api/v1/tool/configures_with_version` | 返回 `{version, features:[{name, enabled}]}`，客户端侧按 version 过滤（对齐官方 62 项 feature 表） |

### 4.2 功能面对齐（P1，按你的优先级）

**输入协议**：你的 agent 目前用 pyautogui 直接注入。建议改为**结构化事件**：
```json
{"t":"mouse","a":"move|down|up|wheel","x":..,"y":..,"b":0,"d":..,"ts":..}
{"t":"key","a":"down|up","code":..,"mods":..,"ts":..}
```
好处：可做事件回放、可做指针加速算法（对齐 `smart_mouse`/`gameModeMouseSpeed`）、可跨平台复用。

**剪贴板**：官方 5 代演进说明这块坑多。最小可用版建议：
- 文本：轮询 `pbpaste`/`pb.Paste()` 变化（200ms），hash 去重，仅传增量
- 文件：走独立通道（见下），剪贴板只传路径清单
- 方向控制：按官方 `follow_local`/`follow_remote` 思路做「跟随本地/跟随远程/双向」

**文件传输**：官方有 `default/custom receive directory` + 权限探测。建议：
1. 传输前先发 `file_transfer_permission_probe`（对端弹确认）
2. 分块（4MB）+ 断点续传（记录 offset 到 sqlite）
3. 接收端目录可配，默认 `~/Downloads/UUReceive/`
4. 拖拽入口：Electron 侧 `webContents.on('will-navigate')` + `dragged files` 拦截

**远程电源管理**：官方 4 个动作（lock/reboot/shutdown/taskmgr）+ auto_unlock。你已有「远程关机+倒计时撤销」，建议补：
- 锁屏：macOS `pmset displaysleepnow` 或 `CGSession -suspend`；Windows `rundll32 user32.dll,LockWorkStation`
- 任务管理器：Windows `taskmgr`；macOS `Activity Monitor` / `top`
- 自动解锁：**高风险**，需要 root + 安全输入通道，建议不做（官方用 `auto_unlock` + `watch_unlock` 双保险）

**隐私屏**：官方三档（`screen_privacy` / `_enhanced` / `privacy_wallpaper`）。实现思路：
- 被控端物理屏幕切到「隐私壁纸」（覆盖窗口/虚拟显示器），但捕获流仍输出真实画面
- macOS 可用 `CGDisplayCapture` + 覆盖窗口；Windows 用 `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` 反向思路
- 你的 agent 是 Python，可用 `tkinter` 全屏置顶黑窗 + `pyautogui` 屏蔽本地输入

**多屏/虚拟屏**：官方 `multi_screen` + `screen_virtual`。你 agent 用 mss，天然支持多显示器枚举（`mss.monitors`）。虚拟屏需要系统级驱动（macOS 需 `CGVirtualDisplay` 私有 API），**建议先做多屏切换，虚拟屏延后**。

**终端**：官方用 tmux + `TerminalStreamerModel`。你的服务端已有 WS，可复用：
- Agent 侧 `pty` 开 shell，绑定 tmux session
- 信令复用现有 WS，新增 `terminal.*` 消息类型
- 渲染在手机端用 xterm.js

**标注**：`annotation_v1/v2`。前端在视频层叠 canvas，坐标归一化后通过信令发对端渲染。**纯前端功能，成本低，建议早做**。

### 4.3 不建议做

| 项 | 原因 |
|---|---|
| `auto_unlock` / `watch_unlock` | 需要安全输入通道 + root，风险高，且涉及绕过系统锁屏 |
| 云电脑 `cloud_pc/*` | 需要真实云主机 + 计费体系，与你的自建定位不符 |
| `mumu_control` | 网易生态专属 |
| 会员/运营 `member/*`、`campaign/*` | 商业逻辑，无互操作价值 |

### 4.4 架构层建议（最重要）

官方是 **三进程 + XPC 仲裁** 架构：
```
UI (UURemote)  ←XPC→  Agent (UURemoteService, LoginWindow级)  ←XPC→  Daemon (root)
                              ↓                                        ↓
                        libstreamer (捕获/编码)                  输入注入/电源管理
```

你的现状是 **单进程 Agent（Python）+ Electron UI**。若要逼近官方体验，最小改造：
1. **权限拆分**：把「输入注入 + 电源管理」拆成独立高权限进程（macOS 用 `launchd` + `SMJobBless`，或用现成的 `osascript with administrator privileges`）
2. **登录窗口级运行**：macOS 装 LaunchAgent 到 `/Library/LaunchAgents/`，`LimitLoadToSessionType = LoginWindow`
3. **保活**：`KeepAlive=true` + `ThrottleInterval=5`（官方就是 5 秒）

这三条能让"远程开机 → 看到登录界面 → 输入密码进入桌面"整条链路成立，是目前你缺的最大体验差距。

---

## 附：功能点总览（一页纸）

```
登录      手机 / 邮箱 / 扫码 / 实名 / 验证码 / 客户端锁
设备      注册(win/mac/android/tv) / 列表 / 分组 / 改名 / 删除 / 偏好 / 分享 / WOL开机
会话      建房 / 分享码加入 / 确认加入 / 控制模式 / 取消协助 / 访客协助
媒体      ScreenCaptureKit捕获 → VideoToolbox(H.264/H.265) → WebRTC+QUIC → Metal渲染
          画质: 普通/高清/超分  |  帧率: 60/90/144  |  HDR / 色度 / 缩放 / 方向
输入      鼠标(加速/智能/虚拟/模拟) / 键盘 / 手柄 / 触控 / 按键映射
音频      麦克风双向 / 扬声器 / 静音(临时/永久/系统) / 语音设置
文件      拖拽 / 复制粘贴 / 4代传输协议 / 接收目录可配 / 权限探测
剪贴板    5代协议 / 双向同步 / 文本+文件
屏幕      隐私屏(3档) / 隐私壁纸 / 多屏 / 虚拟屏 / 窗口级远控
电源      锁屏 / 重启 / 关机 / 任务管理器 / 自动解锁 / 手表解锁 / 断连锁屏
终端      tmux 多会话 / CLI 远程连接
扩展      端口映射 / 标注(v1,v2) / MuMu联动 / 游戏模式 / 延迟归因
云        云电脑(创建/磁盘/测速) / 云盘
```

---

*报告生成：REA 静态分析 | 证据留存 `/Users/hoha/WorkBuddy/2026-11-20-18-18-50/uu-reverse/strings/`*
*声明：结论为逻辑与行为重建，非源码还原；仅供互操作性开发与学习研究*