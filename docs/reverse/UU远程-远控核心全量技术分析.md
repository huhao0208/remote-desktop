# UU 远程 · 远控核心功能全量技术分析

> 目标：`/Applications/UURemote.app`（`com.netease.uuremote` v4.48.1 / macOS，原生 Swift universal）
> 范围：**仅远控（远程桌面）能力**，已剔除云电脑/云盘/会员运营等无关域
> 用途：互操作性开发 / 功能学习
> 标注：**【证】**=二进制/资源直接证据　**【推】**=基于证据推断，未运行时验证

---

## 0. 远控能力全景（一页纸）

```
┌─ 连接 ────────────────────────────────────────────────────────┐
│ 房间模型(createRoom/loginRoom) · 信令服务器列表+SNI · ICE打洞  │
│ TURN中继 · QUIC辅助通道 · 7阶段状态机 · 自动重连(指数退避)      │
├─ 媒体 ────────────────────────────────────────────────────────┤
│ 捕获: ScreenCaptureKit/窗口/区域采集                           │
│ 编码: H.264/H.265/VP8/VP9 × VT/NVENC/AMF/QSV/MediaCodec/软编  │
│ 色度: I420(主)/NV12 · 码控: CBR/CQ/QP + Target/Min/Max Bitrate│
│ 传输: WebRTC(SRTP+DTLS, REMB+transport-cc) + QUIC(ngtcp2, BBR)│
│ 音频: Opus + AEC/AGC/NS · 16kHz/stereo · 多音频轨道            │
│ 渲染: Metal(主) · 多视频轨道(videoTrackIndex)                  │
├─ 输入 ────────────────────────────────────────────────────────┤
│ 鼠标5键 · 三模式(主控/被控/智能) · 触摸(tap/swipe/pinch)       │
│ 键盘+修饰键 · Mac→Win映射 · 系统快捷键三档策略 · 虚拟鼠标      │
├─ 显示 ────────────────────────────────────────────────────────┤
│ 多屏 · 虚拟屏(IDD/CGVirtualDisplay) · 超级屏 · 窗口级远控      │
│ DPI缩放 · 旋转 · 分辨率协商 · 帧率30/60/90/144                 │
├─ 安全 ────────────────────────────────────────────────────────┤
│ 防窥4档(不启用/黑屏/熄屏/隐私屏保) · 自动锁屏 · 双重验证        │
│ 客户端锁 · 自动解锁 · SecureDesktop(UAC) · 权限矩阵            │
├─ 协作 ────────────────────────────────────────────────────────┤
│ 批注(v1/v2) · 观看模式 · 文件传输·剪贴板·拖拽 · 远程终端(tmux) │
│ 端口映射 · 快捷启动应用 · 无线副屏 · 设备接管                  │
└──────────────────────────────────────────────────────────────┘
```

---

# A. 引擎层：libstreamer SDK

## A1. `StreamerManager` 完整接口【证：ObjC 方法签名】

```objc
// ── 生命周期 ──
- (void)initialize:(NSString*)path configPath:(NSString*)configPath;
- (id)init;
- (void)dealloc;
- (void)deleteSelf;

// ── 房间 ──
- (void)createRoomWithToken:(id)token
                 serverList:(NSArray*)serverList
       sniRequiredServerList:(NSArray*)sniRequiredServerList
              streamerConfig:(id)config
              connectTimeout:(NSTimeInterval)timeout
              reconnectDelay:(NSTimeInterval)delay
                 reportToken:(id)reportToken
                   reportUrl:(NSString*)reportUrl
        reportServerAddress:(NSString*)addr
                    delegate:(id)delegate;

- (void)loginRoomWithToken:...(同上参数...);   // 加入已有房间
- (void)destroyRoomForHandle:(int64_t)handle;
- (void)exitRoomForHandle:(int64_t)handle;
- (void)connectForHandle:(int64_t)handle appData:(id)data controlId:(id)controlId;
- (void)disconnectForHandle:(int64_t)handle;
- (void)removeDelegateForHandle:(int64_t)handle;

// ── 数据发送（6 条通道）──
- (void)sendControlData:(void*)buf size:(size_t)size toHandle:(int64_t)handle;      // 控制面裸数据
- (void)sendProtoBufControlData:(void*)buf size:(size_t)size toHandle:(int64_t)h;   // 控制面 Protobuf ★主通道
- (void)sendPbTextData:(void*)buf size:(size_t)size toHandle:(int64_t)handle;       // Protobuf 文本
- (void)sendTextData:(void*)buf size:(size_t)size toHandle:(int64_t)handle;         // 纯文本
- (void)sendBinaryRawData:(void*)buf size:(size_t)size toHandle:(int64_t)handle;    // 原始二进制
- (void)sendFileData:(void*)buf size:(size_t)size toHandle:(int64_t)handle;         // 文件专用

// ── 媒体轨道 ──
- (void)startVideoRenderInView:(id)view renderMode:(int)mode
                     forHandle:(int64_t)h videoTrackIndex:(int)idx;    // ★多视频轨道
- (void)stopVideoRenderForHandle:(int64_t)h videoTrackIndex:(int)idx;
- (void)startAudioCaptureForHandle:(int64_t)h audioIndex:(int)idx;     // ★多音频输入
- (void)stopAudioCaptureForHandle:(int64_t)h audioIndex:(int)idx;
- (void)startAudioRenderForHandle:(int64_t)h audioTrackIndex:(int)idx volume:(float)v;
- (void)stopAudioRenderForHandle:(int64_t)h audioTrackIndex:(int)idx;

// ── 网络与诊断 ──
- (void)switchIceNetworkForHandle:(int64_t)h isEnable:(BOOL)enable;
- (id)getConnectionStatsForHandle:(int64_t)handle;
- (int)getDecodeCapability;
```

**设计解读**：
1. **句柄模型**：一个 `StreamerManager` 管多路连接，`handle` 是句柄 → 支持多窗口/多设备/多屏
2. **房间双入口**：`createRoom`（主控建房）/ `loginRoom`（加入）—— 与你 srv2 的 `room/create` + `room/join` 语义一致
3. **信令服务器双列表**：`serverList` + `sniRequiredServerList`（要求 SNI 的单独列表）
4. **重连参数内建**：`connectTimeout` + `reconnectDelay` —— SDK 层自己做重连
5. **上报通道内建**：`reportToken` / `reportUrl` / `reportServerAddress`
6. **Protobuf 是控制面主通道**（`sendProtoBufControlData`），文件走独立通道（`sendFileData`）

## A2. 事件模型（delegate 回调）【证】

### 数据接收（12）
```
streamerDidReceiveControlData          控制数据（裸）
streamerDidReceiveControlDataByPb      控制数据（Protobuf）★
streamerDidReceiveSignalData           信令数据
streamerDidReceiveSignalPreData        信令预数据（连接前）
streamerDidReceiveBinaryData           二进制
streamerDidReceiveTextData             文本
streamerDidReceiveFileData             文件块
streamerDidReceiveDualNegotiateCapability  双向能力协商 ★
streamerDidReciveMediaTrackType        媒体轨道类型（原代码拼写错误 Recive）
streamerDidReceiveEventReport          事件上报
streamerDidUpdateScreenInfos           屏幕信息更新 ★
streamerFrameChange / streamerFrameSizeChange  帧/尺寸变化
```

### 连接状态（8）
```
streamerConnectionControllerRoomState      控制端-房间状态
streamerConnectionControllerPeerState      控制端-Peer状态
streamerConnectionControllerStateCode      控制端-状态码
streamerConnectionControlledRoomState      被控端-房间状态
streamerConnectionControlledPeerState      被控端-Peer状态
streamerConnectionControlledStateCode      被控端-状态码
streamerConnectError / streamerConnectSuccessTime
```

### 网络与 ICE（4）
```
streamerOnIceSelectedCandidatePairChangedInfo   ICE 选对变化 ★
streamerOnNatInfo                               NAT 类型
streamerRetryDeltaMs                            重连增量
streamerUpdateConnectInfo                       连接信息更新
```

### 其他
```
streamerPush / streamerNotification / streamerLog / streamerLogPath
streamerVersion / streamerConfig / streamerConfigPath
streamerOffsetLeft / streamerOffsetTop
streamerError
```

**关键洞察**：状态建模是 **「Controller/Controlled × Room/Peer/StateCode」六元组**——控制端和被控端各自有独立的房间状态、Peer 状态、状态码。这意味着**双端状态机是分开维护的**，排障时能精确定位是哪一端的问题。

---

# B. 协议层：193 个 Protobuf 消息

**【证】** 命名空间 `gv_pb`（Swift）/ `GvPb_`（C 符号）。以下按域全量分类。

## B1. 连接与会话（8）
`ConnectOptions` `RequestHeader` `ResponseHeader` `Message` `Error` `TaskId`
`ClientUiReadyState` `CheckEnvReq/Resp` `FeatureFlag` `PermissionState` `RpcRequest/RpcResponse`

## B2. 捕获与显示（16）
`CaptureChange` `CaptureConfig` `CaptureConfigResponse` `CaptureParams`
`CaptureSettingRequest/Response/Sync` `CaptureMode`
`Screen` `ScreenSources` `ScreenResolution` `Resolution` `ResolutionSettingRequest`
`ChooseResolutionType` `BuiltinScreenType` `FpsSettingRequest` `VideoQualitySettingReqeust`

## B3. 编解码协商（6）
`CodecNegotiation` `CodecType` `EncoderCap` `DecoderCap` `ChromaFormat` `DpiScale` `DpH`

## B4. 输入（8）
`InputEvent` `TouchEvent` `TouchEventPoint` `ActionKeyToggle`
`CursorShape` `CursorSettingReqeust`（原拼写错误）
`VirtualMouseSwitchRequest/Response` `SimpleAction`

## B5. 剪贴板（15，完整协议栈）★
```
变更通知   ClipboardChange
请求响应   ClipboardRequest / ClipboardResponse
文本       ClipboardTextChangeRequest / ClipboardTextChangeResponse
格式协商   ClipboardFormat · ClipboardFormatDataAsk · ClipboardFormatDataConfirm
           ClipboardFormatListRequest · ClipboardFormatListResponse
数据块     ClipboardDataBlock · ClipboardDataBlockConfirm
文件描述符 ClipboardFileDescriptor · ClipboardFileDescriptorListRequest/Response
           ClipboardFileDescriptorSegment · ClipboardFileDescriptorSegmentConfirm
文件内容   ClipboardFileContentsRequest / ClipboardFileContentsResponse
取消       ClipboardFileCancelRequest / ClipboardFileCancelResponse
错误       ClipboardError
```

**这是「格式协商 + 分块传输 + 确认」的完整可靠传输设计**，不是简单的文本广播。可以直接照搬。

## B6. 文件传输（24）★
```
握手    FileTransferAsk · FileTransferConfirm
块传输  FileTransferBlock · FileTransferBlockConfirm
完成    FileTransferComplete · FileTransferResult
发送端  FileTransferSendRequest / FileTransferSendResponse
接收端  FileTransferReceiveRequest / FileTransferReceiveResponse
FTP     FileTransferFtpRequest / FileTransferFtpResponse     ← 独立 FTP 模式
目录    DirectoryData · DirectorySizeRead · FileDirectory · FileList · ReadDir
文件    FileInfo · FileEntry · FileExist/Response/Result
操作    FileRename · FileRemoveFile · FileRemoveDir · FileDirCreate · FileOperationResult
清理    ClearSendTemp
其他    RemoteAssistFileTransferState · RemoteDownloadPath
```

**注意 `FileTransferFtpRequest/Response`**——说明除了自有协议，还支持 **FTP 传输模式**（大文件/断点续传场景）。

## B7. 拖拽（4）
`DragDropAutoSave` `DragDropAutoSaveComplete/Response` `DragDropOleDrop`（Windows OLE 拖拽）

## B8. 批注（9）★
```
开关    DrawToggleRequest / DrawToggleResponse
绘制    DrawRequest / DrawResponse
笔画    DrawStrokeRequest / DrawStrokeResponse · DrawPoint
清除    DrawClearRequest / DrawClearResponse
```

## B9. 虚拟显示 / 超级屏（10）
```
创建虚拟屏  CreateVirtualDisplayRequest/Response
删除虚拟屏  RemoveVirtualDisplayRequest/Response
配置        VirtualDisplayInitResolution · VirtualDisplayMode
超级屏      EnterSuperScreenRequest/Response · QuitSuperScreenRequest/Response
异常        EnterSuperScreenFpsNotSupport
翻转屏幕    SendFlipScreenRequest/Response
```

## B10. 隐私屏（4）
`PrivateScreenSettingRequest/Response` `PrivateScreenState`
`UpdateScreenSaverRequest/Response` `SecureDesktopState` ★

> `SecureDesktopState` = **Windows UAC 安全桌面状态**。远控必须能感知它，否则用户看不到 UAC 弹窗就卡死。

## B11. 音频（2）
`VirtualAudioDriverPolicyRequest/Response` ★（「网易虚拟音频」驱动策略协商）

## B12. 终端（2）
`TerminalSessionChanged` `RenameSessionReq/RenameSessionResp`

## B13. 应用与快速启动（6）
`LaunchApp` `ShowApp` `QuickLaunchAppItem`
`QuickLaunchScanRequest/Response` `QuickLaunchAppIconRequest/Response`

## B14. 系统状态与性能（12）
`QuerySystemState` `SystemStateChange` `SystemMetrics` `Performance`
`ReportQosStats` `ReportError` `GeneralMetric` `SettingMetric`
`SettingRangePerformance` `SettingRangeResolution` `MinMax`
`ActiveWindowChange` `WinRect`

## B15. 端口映射（1）
`PortMappingFrame`（帧封装）

## B16. 插件系统（9）★
`PluginEnableNotificationRequest/Response` `PluginNotificationRequest/Response`
`QueryPluginSettingRequest/Response` `UpdatePluginSettingRequest/Response`
`StartDownloadAndInstallPluginRequest/Response`
`PluginType` `PluginState` `PluginSwitch` `PluginStateQuery`

**插件特征**：`plugin_detect_exe_show`（检测 exe 是否存在）、`plugin_package_size`（包大小）、`plugin_notification_show/click`、`plugin_switch_open/close`
→ 推测是**按需下发的功能插件**（虚拟显示器驱动 / 虚拟音频驱动 / 特定硬件编码支持），客户端检测到需要才下载安装。

## B17. MuMu 模拟器联动（8）
`MumuControl` `MumuInfo` `MumuOperate` `MumuPlayerList` `MumuSetting` `MumuSettingRange` `MumuNotifyProcess` `MumuNotifySimple`
→ 网易自家模拟器的深度联动（`ACTION_TYPE_CAPTURE_MUMU`），非通用能力，**可跳过**。

## B18. 枚举与通用结构
```
状态    STATE_ALLOW · STATE_REJECT · STATE_CHANGE · STATE_ERROR · STATE_UNKOWN(原文拼写)
错误    ERROR_NONE · ERROR_CONTENT · ERROR_MESSAGE_EMPTY · ERROR_MESSAGE_TOO_LARGE
        ERROR_SHUTTING_DOWN · ERROR_TRANSPORT
鼠标键  MOUSE_PRIMARY · MOUSE_SECONDARY · MOUSE_TERTIARY · MOUSE_BACK · MOUSE_FORWARD
通用    KeyValue · OneKeyMultiValue · LanguageKeyValue/Value · MinMax · Resolution · Screen
```

---

# C. 媒体层

## C1. 采集【证】
- macOS：**ScreenCaptureKit**（系统级，非轮询）
- 采集模式：`CaptureMode` 枚举（桌面 / 窗口 / 区域 / MuMu）
- 采集参数：`CaptureParams` `CaptureConfig` `CaptureSettingSync`
- 运行时变更：`CaptureChange`（分辨率/屏切换/DPI 变化）
- 权限：`checkScreenRecordingPermission` / `refreshScreenRecordingPermission` / 缓存机制

## C2. 编码（全平台硬编矩阵）【证】

| 平台 | 硬编 | 软编兜底 |
|---|---|---|
| macOS | VideoToolbox | OpenH264 |
| Windows | NVENC / AMF / QSV | OpenH264 |
| Android | MediaCodec | — |
| 通用 | — | OpenH264 |

**编码格式**：H.264、H.265、VP8、VP9
**色度**：I420（46 次引用，主力）、NV12
**捕获像素格式**：ARGB / BGRA / RGBA（渲染侧）

**码率控制参数**【证】：
```
码控模式  CBR / CQ / QP
码率      TargetBitrate · MinBitrate · MaxBitrate · max_bitrate
关键帧    KeyframeInterval
GOP       GoP
```

**能力协商**：`EncoderCap` / `DecoderCap` / `CodecNegotiation` / `getDecodeCapability`

**降级策略**（`streamer-config.json` 实录）【证】：
```json
{"disable_h265_codec":[{"enable":true,"roles":["controller"],"platforms":["windows"],
  "graphic_cards":["GTX\\s*7","GT\\s*7","GTX\\s*9","GT\\s*9"]}],
 "set_max_decoder_cap":[{"enable":true,"platforms":["android"],"brands":["Lenovo"],"models":["TB371FC"]}]}
```

## C3. 传输（双栈）【证】

### 通道 1：WebRTC
- 加密：`SRTP`（`RTP/SAVP`）、`DTLS/SCTP`
- 传输：UDP 主，`TCP/DTLS` 兜底（UDP 被封时）
- 拥塞控制：`REMB` + `transport_cc`（transport-wide CC）
- 候选：`ice_f` / `iceServe` / `start_ice` / `turn`

### 通道 2：QUIC
- 实现：**ngtcp2 + OpenSSL**（390 次 ngtcp2 引用）
- 拥塞控制：**BBR**（20 次）+ cubic 备选
- 证据：`initial_source_connection_id` / `original_destination_connection_id` / `retry_source_connection_id` / `max_idle_timeout` / `initial_max_data` / `active_connection_id_limit` / `transport_parameters`
- 流状态：`STATE_WRITE_INIT` / `STATE_WRITE_UNRELIABLE`（Datagram）/ `STREAM_DATA_BLOCKED` / `STREAM_LIMIT_ERROR`
- TLS：`CLIENT_HANDSHAKE_TRAFFIC_SECRET` / `CLIENT_TRAFFIC_SECRET_0` / `KEY_PHASE`（TLS 1.3）

### 通道选择
`switchIceNetworkForHandle:isEnable:` — 运行时可切 ICE 网络
`streamerOnIceSelectedCandidatePairChangedInfo` — 选对变化可观测
`streamerOnNatInfo` — NAT 类型上报
`bandWidthEstimation` — 带宽估计模块

**推论**：双栈是**并行探测 + 择优**——WebRTC 拿通用性，QUIC 拿低延迟/弱网；连接后根据 RTT/丢包动态选路（`optimizedConnectionPath` 状态）。

## C4. 音频链【证】

```
采集 → AEC(回声消除) → AGC(自动增益) → NS(噪声抑制) → Opus 编码 → 传输
                                                    → 对端 Opus 解码 → 渲染
```

- 编码：**Opus**（184 次引用）
- 采样率：16kHz（语音优化）/ 其他（`sampleRate` 可配）
- 声道：`stereo` 支持
- 处理链：`AEC` / `EchoCancel`（156+44）、`AGC`（32）、`NS_`（87+55）
- 多轨道：`audioIndex`（采集）/ `audioTrackIndex`（渲染）→ 支持多路音频（麦克风 + 系统声）
- 被控端驱动：**「网易虚拟音频」**（Windows），通过 `VirtualAudioDriverPolicyRequest/Response` 协商

**关键设计**：被控端装虚拟音频驱动，把系统声音路由到虚拟设备，控制端才能"听到被控端的声音但被控端自己静音"（`Control.Volume.mute` 文案：「开启后会将被控端设置为静音，控制端仍能播放被控端声音」）。

## C5. 渲染【证】
- Metal（169 次）为主，`MetalView` 导出类
- `IOSurface` 零拷贝（解码输出直接上 GPU）
- `RenderMode` 枚举（多种渲染路径）
- 多视频轨道：`videoTrackIndex` → 多屏同时渲染

---

# D. 输入层

## D1. 事件模型【证】
```
InputEvent       通用输入事件
TouchEvent       触摸事件
TouchEventPoint  触摸点
ActionKeyToggle  按键开关（组合键）
CursorShape      光标形状（被控端光标同步到控制端）
CursorSettingReqeust  光标设置
VirtualMouseSwitchRequest/Response  虚拟鼠标切换
SimpleAction     简单动作
```

**鼠标 5 键**：`MOUSE_PRIMARY` / `MOUSE_SECONDARY` / `MOUSE_TERTIARY` / `MOUSE_BACK` / `MOUSE_FORWARD`
**修饰键**：`modifier` 字段（16 次引用）
**坐标**：`x`（1013 次）/ `y`（546 次）—— 输入 + 绘制共用
**按键**：`key_code` / `scan_code`

**触摸手势**【证】：`tap` / `swipe` / `pinch`（移动端三种手势映射到桌面操作）

## D2. 鼠标三模式【证】
| 模式 | 机制 | 默认 |
|---|---|---|
| 使用主控端鼠标 | 控制端渲染光标，被控端隐藏系统光标 | 跟手，兼容差 |
| 使用被控端鼠标 | 依赖被控端系统光标 | ★默认 |
| 智能鼠标 | 按软件自适应切换 | 演进方向 |

配套：`virtual_mouse`（虚拟鼠标）、`smart_mouse`（智能鼠标）、`simulate_mouse`（模拟鼠标）、`gameModeMouseSpeed`（游戏鼠标速度）、`pointer.acceleration`（指针加速）

**已知缺陷**（官方文案自述）：被控端鼠标模式 + 隐私屏保 → 被控端无法完全隐藏鼠标。

## D3. 键盘与映射

**Mac 控制端 → Windows 被控端**【证】：
| 源 | 目标 |
|---|---|
| Command(⌘) | Win 或 Ctrl（可配） |
| Control(⌃) | Ctrl |
| Option(⌥) | Alt |
| Delete | Backspace |
| Fn+Delete | Delete |

**系统快捷键三档策略**【证】：
1. 优先在控制端响应（默认）
2. 优先在被控端响应（Cmd+Tab 等传给被控端）
3. 例外列表（单独指定哪些键始终本地/远端）

**依赖权限**：辅助功能（Accessibility）+ 输入监控（Input Monitoring），改权限后需重启客户端。

## D4. 22 个可配置功能快捷键【证】
老板键 · 发送 Ctrl+Alt+Delete · 打开文件传输 · 显示/隐藏悬浮球 · 全屏切换 · 锁定鼠标 · 静音切换 · 网络状态 · 上/下一屏 · 解除防窥 · 隐私屏保开关 · 退出远控 · 被控端鼠标切换 · 小窗模式 · 切换远控窗口 · 观看模式 · 观看/操控切换 · 批注开关 · 工具栏开关

---

# E. 显示层

## E1. 多屏与虚拟屏【证】

| 能力 | 实现 | 证据 |
|---|---|---|
| 多屏枚举 | `screenInfos`：`screen_index` / `is_primary` / `rotation` / `display_mode` | 【证】 |
| 虚拟屏（Windows） | **IDD**（Indirect Display Driver，170 次引用） | 【证】 |
| 虚拟屏（macOS） | `CGVirtualDisplay` / `VirtualDisplay`（66 次） | 【证】 |
| DisplayLink 兼容 | `DisplayLink`（16 次） | 【证】 |
| 超级屏 | 关物理屏 + 高规格虚拟屏 | 【证】 |
| 屏幕翻转 | `SendFlipScreenRequest/Response` | 【证】 |
| DPI | `DpiScale` / `DpH` | 【证】 |

**虚拟屏约束**（官方文案）：
- 数量有上限（`maxTips1` / `maxTips2`）
- 最后一块虚拟屏不可删除
- 分辨率不匹配时自动创建并提示（可「不再提醒」）
- macOS 低版本不支持强制虚拟屏

## E2. 分辨率与帧率
- 分辨率：自动 / 跟随被控端 / 跟随当前显示屏 / 480P / 1080P / 2K / 4K / 自定义
- 帧率：30 / 60（推荐）/ 90 / 144
- 缩放：实际大小 1:1 / 自适应 / 自定义
- 方向：横/纵（`screen_orientation`）

## E3. 画质增强
| 能力 | 说明 | 约束 |
|---|---|---|
| 真彩（True Color） | 全色域 | 与 HDR **互斥**；需硬解 |
| HDR | 高动态范围 | 与真彩互斥；需硬解 |
| 超分（`screen_super`） | 低带宽传超分画质 | 4.2.3+ |
| 色度（`screen_chroma`） | 4:2:0 / 4:4:4 可选 | 带宽换质量 |

## E4. 窗口级远控
- `windows_display` / `desktop_display`：窗口级 vs 桌面级
- `ActiveWindowChange` / `WinRect`：活动窗口追踪
- 场景：只远控某个应用窗口（如只控游戏窗口）

---

# F. 安全层

## F1. 防窥模式 4 档【证】

| 档位 | 行为 | 技术实现（推） | 防护级 |
|---|---|---|---|
| 不启用 | 无操作 | — | 无 |
| 黑屏防护 | 显示黑屏遮挡 | 全屏置顶黑窗 | 中 |
| **关闭显示屏** | 物理熄屏 + 虚拟屏接管 | `SetDisplayConfig` / `CGDisplayCapture` + 虚拟屏 | **高** |
| 隐私屏保 | 全屏置顶图片 | 覆盖窗口 + 图片（≥1920×1080 ≤2M） | 中 |

**配套**：
- 自动锁屏（结束远程时锁被控端）
- 被控静音（远程期间被控端静音，控制端仍可听）
- 安全状态指示（已防护 / 需关注）
- 被控端本地快捷键解除防窥

## F2. 解锁体系（三层）

### 层 1：自动解锁（`auto_unlock`）
- 录入被控端开机密码，**本地加密存储，不上传**
- 解锁时校验身份 → 输入密码 → 解锁
- 失败原因分类：`NoLoggedInUser`（未登录用户）/ `NoPermission`（缺辅助功能）/ `Timeout`（超时）/ `Failed`

### 层 2：双重验证（`Unlock.Menu.Double.Authentication`）
解锁被控端时可要求：
- macOS 登录密码
- 触控 ID（Touch ID）
- **Apple Watch 确认**（`watch_unlock`）

### 层 3：客户端锁（`ClientSecurityLock`）
保护**控制端**自身设置：
- 安全密码 8-16 位
- 三种自动锁定：关闭主界面 / 远程协助期间 / 启动时
- 解锁：密码 或 短信验证码

## F3. SecureDesktop（Windows UAC）【证】
`SecureDesktopState` 消息 + `SecureDesktop` 字符串（6 次）
→ 能处理 UAC 提权弹窗的安全桌面切换，这是远控软件的高级能力（很多开源方案在这里卡死）。

## F4. 权限矩阵（macOS）【证】

| 权限 | 用途 | 缺失影响 |
|---|---|---|
| 屏幕录制（Screen Recording） | 捕获画面 | **无法被控**（`允许本设备被控`强制关闭） |
| 辅助功能（Accessibility） | 键鼠注入、快捷键识别 | 无法操作被控端 |
| 输入监控（Input Monitoring） | 捕获系统按键 | 快捷键录入/发送失败 |
| 麦克风 | 语音 | 无声音 |
| 文件与文件夹 / 完全磁盘访问 | 文件传输 | 每次传输都要手动授权 |

**关键文案**：`ScreenCapture.notice`「由于未开启录屏与系统录音权限，【允许本设备被控】将保持关闭状态」——**权限与开关强绑定**，这是很好的设计（避免用户以为开了实际没生效）。

## F5. 远程协助（他人设备）
- 设备 ID + 验证码
- 「允许他人远程协助」开关（被控端）
- 收藏设备（设备 ID + 备注 + 可选验证码）
- 确认式加入（被控端弹窗确认）

---

# G. 会话生命周期

## G1. 连接状态机【证：`ConnectState.*` 文案】

```
init                    初始化连接
  ↓
buildServer             建立服务器连接
  ↓
syncInfo                同步连接信息
  ↓
settingRemoteConversation  设置远程会话
  ↓
optimizedConnectionPath    优化连接路径（ICE 探路）
  ↓
transmittingScreen         正在传输画面
  ↓
connectSuccess             连接成功

异常分支：
reconnecting            正在尝试重连（指数退避）
restoreConnect          正在恢复连接（断线保活）
```

## G2. 双端状态六元组【证】
```
Controller × {RoomState, PeerState, StateCode}
Controlled × {RoomState, PeerState, StateCode}
```
状态值：`STATE_ALLOW` / `STATE_REJECT` / `STATE_CHANGE` / `STATE_ERROR` / `STATE_UNKOWN`

## G3. 错误分类【证】
```
ERROR_NONE                 正常
ERROR_CONTENT              内容错误
ERROR_MESSAGE_EMPTY        空消息
ERROR_MESSAGE_TOO_LARGE    消息过大
ERROR_SHUTTING_DOWN        正在关闭
ERROR_TRANSPORT            传输层错误
```

**用户侧错误文案分类**：
- 连接超时 / 无法连接服务器 / 网络配置错误（码 1001：后台运行权限）
- 连接意外断开 → 「被控/主控设备无网络或意外断线 / 已关机重启」+ [重新连接]
- 权限拒绝（`Connect.PermissionReject`）
- **RDP 冲突**：`Control.Error.rdp`「被控端系统会话发生变化，画面会有短暂卡顿」★
- 设备 ID 错误（协助场景）

## G4. 断线与重连
- `reconnectDelay` / `streamerRetryDeltaMs`（指数退避）
- `disconnect_lock`：断连锁屏（安全）
- `restoreConnect`：会话恢复
- 被控端显示「连接时长 %@」

---

# H. 可观测性

## H1. 性能指标字段【证】
```
cpu_usage · capture_time · decode_time · render_time
jitter · packet_loss · frame_latency
```

## H2. 连接信息面板（28 字段）【证】
延时三段（当前/平均/最高）· 丢包率 · 带宽占用 · 帧率 · 帧延时 · 画质 · 采集方式 · 编码模式 · 硬编/软编/硬解/软解 · 加密通道 · 局域网直连/安全中转 · 双端 IP/系统/版本 · 连接时间 · [复制全部信息]

## H3. 性能归因 9 条【证】
| 归因 | 建议 |
|---|---|
| 网络延迟高 | 降画质/降帧率/换网络 |
| 设备性能受限 | 降画质/降帧率 |
| **被控端**显卡驱动过低 | 升级驱动 |
| **控制端**资源占用高 | 关闭其他应用 |
| **被控端**资源占用高 | 关闭其他应用 |

## H4. QoS 上报
`ReportQosStats` / `Performance` / `GeneralMetric` / `SystemMetrics` / `streamerDidReceiveEventReport`

---

# I. 与你现有实现的差距与落地路径

## I1. 现状对照

| 维度 | 官方 | 你的 `uu-remote-server` | 差距 |
|---|---|---|---|
| 引擎 | libstreamer（C++ 自研，双栈） | Python asyncio + WS | 架构级 |
| 传输 | WebRTC + QUIC 双栈，BBR | TCP(WS) | ★★★ 致命 |
| 编码 | H.264/H.265 硬编 | JPEG | ★★★ 大 |
| 通信 | Protobuf（193 消息） | JSON over WS | ★★ 中 |
| 多轨 | 多视频/音频轨道 | 单流 | ★★ 中 |
| 输入 | 5键/3模式/手势/映射 | pyautogui 单模式 | ★★ 中 |
| 显示 | 虚拟屏/超级屏/DPI | 单屏 | ★★ 中 |
| 安全 | 防窥4档/双重验证/UAC | 无 | ★★ 中 |

## I2. 分阶段落地

### 阶段 1：媒体链路重构（最高优先）
```
1. 编码：JPEG → H.264（openh264 / x264），关键帧 2s，I420 输入
2. 传输：WS 只走信令；媒体走 UDP（自研包格式：seq + ts + frag + payload）
        失败回落 WS 分片
3. 解码：前端 WebCodecs VideoDecoder → canvas
4. 脏区：帧差检测，只传变化矩形（静止时 1fps 心跳）
5. 码控：目标码率 + 丢包反馈（简化版 REMB）
```
**收益**：带宽 ↓70%，延迟 ↓60%，CPU ↓50%

### 阶段 2：输入与协议
```
1. 输入事件改 Protobuf/MessagePack（对齐官方 InputEvent 语义）
2. 坐标归一化（0-1）
3. 三档鼠标模式（先做两档）
4. 键盘修饰键 + Mac→Win 映射
5. 系统快捷键三档策略
```

### 阶段 3：安全与显示
```
1. 防窥：黑屏 + 隐私屏保（tkinter/Electron 全屏窗）
2. 自动锁屏
3. 多屏枚举与切换
4. 虚拟屏（macOS CGVirtualDisplay / Windows IDD 驱动，成本高）
```

### 阶段 4：协作能力
```
1. 剪贴板：格式协商 + 分块 + 确认（照搬官方 15 消息设计）
2. 文件传输：块传输 + 断点续传 + 目录操作
3. 批注：DrawStroke 协议（纯前端 canvas + 坐标同步）
4. 终端：pty + tmux
5. 端口映射
```

### 阶段 5：可观测
```
1. 连接信息面板（28 字段）
2. 性能归因（RTT/丢包/CPU → 9 条文案）
3. QoS 上报
```

## I3. 建议直接照搬的设计

| # | 设计 | 理由 |
|---|---|---|
| 1 | **双端状态六元组** | 排障精确定位到端 |
| 2 | **剪贴板 15 消息协议** | 格式协商 + 分块 + 确认，工业级 |
| 3 | **系统快捷键三档策略** | 解决 Cmd+Tab 归属难题 |
| 4 | **防窥 4 档** | 覆盖不同安全场景 |
| 5 | **性能归因区分控制端/被控端** | 用户能自助排障 |
| 6 | **权限与开关强绑定** | 避免"以为开了实际没生效" |
| 7 | **连接信息复制全文** | 客服排障效率 |
| 8 | **按显卡/机型降级** | 真实世界的兼容性 |
| 9 | **连接状态 7 阶段文案** | 长连接有进度感 |

## I4. 不建议做
- MuMu 联动（网易生态专属）
- 云电脑/云盘（用户明确排除）
- 会员/运营（商业逻辑）
- 超分/HDR/真彩（成本极高，收益边际）
- 插件系统（架构复杂，先做内置）

---

# 附录：证据索引

| 文件 | 内容 |
|---|---|
| `uu-reverse/pb-messages.txt` | 193 个 Protobuf 消息名 |
| `uu-reverse/zh-strings.json` | 1809 条界面文案 |
| `uu-reverse/assets-names.txt` | 719 个资源名（颜色 token + 图标） |
| `uu-reverse/strings/{UURemote,Daemon,Service,streamer,uuyc,Server}.txt` | 字符串层导出（约 9MB） |
| `UURemote.app/Contents/Resources/streamer-config.json` | 媒体降级策略 |

**未验证项**：
1. Protobuf 消息的**字段编号与类型**（只拿到消息名，未拿到 .proto）
2. 帧格式的**封装头**（magic/version/length/checksum）
3. QUIC 的**应用层 ALPN 与自定义帧**
4. ICE 的**候选交换格式与信令封装**
5. 虚拟屏驱动的**安装与签名机制**
6. 颜色 token 具体色值

> 本文档为逻辑与行为重建，非源码还原；仅供互操作性开发与学习研究。