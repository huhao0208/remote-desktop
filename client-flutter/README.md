# client-flutter · UU Remote 控制端（Flutter 骨架）

Flutter 版控制端，目标是与 `srv2/control.html`、`client-desktop`、`client-mobile` 行为一致：
**登录 → 设备列表 → 远控**。画面走 WebRTC（H.264 / SRTP over UDP），`agent.hello.media == "jpeg"`
时自动用 JPEG 兜底通路。

- 协议依据：`../docs/media-protocol.md`（FROZEN v1）
- 服务端：`../srv2/server.py`（本仓库代码**一行不改**）
- 不做的事：不改 `agent/`、`srv2/`、`.github/`、`docs/` 等其它目录

---

## 1. 当前实现状态

| 能力 | 状态 |
|---|---|
| 手机号登录（`POST /api/v1/login/by_mobile`，带 `register_device`） | ✅ |
| token / 本机 device_id 持久化（`shared_preferences`） | ✅ |
| 设备列表（`POST /api/v1/device/list`），在线/本机/可控标记 | ✅ |
| 进房间（`POST /api/v1/room/join/by_device/{id}`）→ 连 `wss://.../ws/signaling` | ✅ |
| `agent.hello` 解析（含 `media` 缺省按 `jpeg` 兜底） | ✅ |
| **WebRTC 收流（H.264 / `RTCVideoView`）** | ✅ **主通路**，见第 5 节 |
| JPEG 帧渲染（`FRM1` + 8B 时间戳 + JPEG） | ✅ 兜底通路（`Image.memory`，临时方案） |
| 输入转发（move / click / scroll / text / press / keydown / keyup） | ✅ 坐标归一化 0..1 |
| `stream.config` 画质切换（流畅/高清/超清，含 bitrate） | ✅ |
| `MediaTransport` 抽象 + `JpegTransport` / `WebRtcTransport` | ✅ |
| WebRTC `rtc.offer/answer/ice/close` | ✅ 见 `lib/media/webrtc_transport.dart` |
| 关机 `shutdown` UI、文件传输、剪贴板、音频、多屏 | ❌ 未做（协议 v2 已就绪，只留挂点） |

骨架代码已在 Flutter 3.50.1 上验证：`flutter analyze --fatal-infos` → **No issues found**，
`flutter test` → 22 passed，`flutter build bundle`（Dart 全量编译）通过。

---

## 2. 目录结构

```
lib/
  main.dart                 入口：初始化 Settings → 桌面窗口 → 有无会话分流
  core/
    app_config.dart         服务端默认地址、画质档位（value 与 control.html 一致）
    settings.dart           SharedPreferences：server/token/device_id/device_uuid
    device_identity.dart    稳定设备指纹(uuid v4)、展示名、platform 标识
    api_client.dart         REST 客户端（{code,msg,data} 信封 + Bearer）
    models.dart             LoginResult / DeviceInfo / RoomConfig / AgentHello
    input_events.dart       输入事件构造 + 键位映射（对齐 MODKEYS/KEYMAP）
    theme.dart              深色主题 #0d1117 / #161b22 / #2ea043
    window_setup.dart       桌面窗口初始/最小尺寸（window_manager）
  signaling/
    signaling_client.dart   房间 WS：文本=JSON、二进制=画面帧，双向流
  media/
    media_transport.dart    MediaTransport 抽象 + FramePacket + TransportStats + 占位视图
    jpeg_transport.dart     JPEG 兜底（FRM1 解析 + Image.memory）
    webrtc_transport.dart   WebRTC 收流：协商 / RTCVideoView / getStats / failed 回调
    rtc_signaling.dart      ice_servers 转换 + rtc.offer/rtc.ice 载荷（纯函数，可单测）
    media_factory.dart      按 agent.hello.media 选通路
  pages/
    login_page.dart
    device_list_page.dart
    remote_page.dart        远控：HUD / 画质 / 鼠标键盘触控映射
test/
  protocol_test.dart        协议字段解析、信令地址组装、FRM1 帧头
  rtc_signaling_test.dart   ice_servers 转换、rtc.offer/rtc.ice 载荷
```

### 页面 → 通路 的解耦点

`remote_page.dart` 只依赖 `MediaTransport`：

```dart
abstract class MediaTransport {
  String get kind;
  String get label;
  Stream<FramePacket> get frames;
  ValueListenable<TransportStats>? get stats => null;  // 仅 WebRTC 有（getStats）
  Future<void> start({required AgentHello hello, required RoomConfig room, required SignalingClient signaling});
  Widget buildView({required BoxFit fit});
  Future<void> dispose();
}
```

`createTransport()` 按 `agent.hello.media` 选实现；`start()` 抛错或运行中
`connectionState` 变 `failed/disconnected` 时，远控页自动切回 `JpegTransport` 并 toast
——对应协议 §5 的降级表（细节见第 5.3 节）。

---

## 3. 本地运行

需要 Flutter **3.50.x**（本骨架在 3.50.1 stable 实测）。本机若没有 SDK：

```bash
# 官方 tarball（不要 brew cask，避免 sudo 交互）
curl -sSL -o /tmp/flutter.zip \
  https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_3.50.1-stable.zip
unzip -q /tmp/flutter.zip -d ~/ && export PATH="$HOME/flutter/bin:$PATH"
flutter --version
```

然后：

```bash
cd client-flutter
flutter pub get
flutter analyze          # 期望：No issues found（或仅 warning）
flutter test             # 协议单测
flutter run -d macos     # 需 Xcode；Windows/Linux 同理
flutter run -d chrome    # ❌ 不支持：代码用了 dart:io Platform / WebSocket
```

平台骨架（`macos/` `windows/` `linux/` `android/` `ios/`）由下面这条命令生成，已包含在仓库里：

```bash
flutter create --platforms=macos,windows,linux,android,ios \
  --org com.huhao --project-name uu_remote client-flutter
```

### 依赖与 SDK 版本的两个坑

1. **`material_ui`**：Flutter 3.47 起 `package:flutter/material.dart` 被废弃，官方模板改为
   `package:material_ui/material_ui.dart` + 依赖 `material_ui: ^1.1.0`。本工程按 3.50 模板写法，
   `analyze` 才能做到 No issues。若 CI 用 **< 3.47** 的 Flutter，需要把 7 个文件的 import 改回
   `package:flutter/material.dart` 并删掉该依赖（否则依赖解析失败）。
2. **`flutter_lints ^6.0.0`** 对应 3.50；旧模板的 `^5.0.0` 在 3.50 下会有一条 lint 版本提示。

平台配置里已经补了两处「模板不带、但联网必需」的权限：

- `macos/Runner/{DebugProfile,Release}.entitlements`：加 `com.apple.security.network.client`
  （沙盒应用不加就无法发起任何 HTTP/WS 连接，release 版尤其容易漏）
- `android/app/src/main/AndroidManifest.xml`：加 `android.permission.INTERNET`
  （模板只在 debug/profile 声明，release 包会静默断网）

### 登录注意

- 服务端 `platform` 字段：桌面端登记为 `pc`（服务端只把 pc/mac/linux 视为「可远控」），
  移动端自动登记为 `mobile`，避免手机把自己伪装成一台可被远控的电脑。
- 同一个 `device_uuid` 重复登录不会堆设备行（服务端按 fingerprint 去重）。
- 默认服务端 `https://47-251-105-202.sslip.io:8444` 内置在 `core/app_config.dart`，
  登录页「服务器设置」和设备列表右上角菜单都能改。

### 自签证书

自托管服务端多为自签证书，`ApiClient` 与 `SignalingClient` 都设置了
`badCertificateCallback => true`。**这是骨架期的权宜之计**，正式版应改为把 CA 打进
应用信任链或做证书固定（见 `core/api_client.dart` 注释）。

---

## 4. 协议对齐（逐字段）

| 用途 | 请求 | 关键字段 |
|---|---|---|
| 登录 | `POST /api/v1/login/by_mobile` | `mobile, register_device:1, uuid, device_name, platform` → `token, uid, nickname, mobile, device.device_id` |
| 设备列表 | `POST /api/v1/device/list`（`Authorization: Bearer <token>`） | 请求 `device_id`(本机) → `list[].device_id/device_name/platform/online/is_self/controllable/last_seen` |
| 进房间 | `POST /api/v1/room/join/by_device/{device_id}` | → `signaling_server, token(房间), room_id, ice_servers` |
| 信令 | `wss://<host>/ws/signaling?token=<房间token>&device_id=<本机device_id>` | 文本=JSON 透传，二进制=画面帧 |
| 能力 | `agent.hello` | `name, os, screen.w/h, media("webrtc"/"jpeg"), stream.fps` |
| 画质 | `stream.config` | `{width, quality, fps, bitrate}`，Agent 回 `stream.config.ack` |
| 输入 | `input` | `{p:"input", t:"move|click|scroll|press|text|keydown|keyup|key", x, y, btn, dy, k, v, combo}`，x/y ∈ [0,1] |
| 关机 | `shutdown` | `{p:"shutdown", delay}` / `{p:"shutdown", cancel:true}` |

画面帧格式（JPEG 通路）：`"FRM1"` + 8 字节大端毫秒时间戳 + JPEG；兼容无时间戳的
`"FRM1" + JPEG`（判断 `data[4..5]` 是否 `FF D8`）。

---

## 5. WebRTC 通路（H.264，已接入）

依赖 `flutter_webrtc: ^1.6.3`（底层 `dart_webrtc 1.8.2` / `webrtc_interface 1.5.1`）。
实现在 `lib/media/webrtc_transport.dart`，协议依据 `docs/media-protocol.md` §2/§3/§5。

### 5.1 怎么协商（trickle ICE，全部复用现有 `/ws/signaling`）

```
Flutter 控制端                                    Agent
  rtc.offer {sdp, ice, peer}  ─────────────────►  建 RTCPeerConnection / 挂 ScreenTrack
  ◄───────────── rtc.answer {sdp, bitrate}         createAnswer + setLocalDescription
  rtc.ice {candidate, sdpMid, sdpMLineIndex} ◄──►  rtc.ice（双向，谁先 gather 谁先发）
  ═════════ SRTP/UDP 媒体流（不经服务端）══════════
  rtc.close（可选，离开房间/降级） ────────────►
```

1. `createPeerConnection({'iceServers': toRtcIceServers(room.iceServers), 'bundlePolicy': 'max-bundle'})`
   —— 服务端 `build_ice()` 下发的是 `{stun: [...], turn: [...]}` 对象，`toRtcIceServers()`
   转成插件要的 `[{urls, username, credential}]`；`rtc.offer.ice` 里则**原样透传**该对象
   （Agent 两种形态都认，省一次请求）。
2. `addTransceiver(kind: video, init: RTCRtpTransceiverInit(direction: RecvOnly))` —— 只收不发，
   全程不申请摄像头/麦克风。
3. `createOffer` → `setLocalDescription` → 发 `rtc.offer`（带 `peer = 本机 device_id`）。
4. 收 `rtc.answer` → `setRemoteDescription(RTCSessionDescription(sdp, 'answer'))`。
   早到的远端候选先缓存，answer 落地后补投（协议 §2.3）。
5. `onTrack` → `RTCVideoRenderer.srcObject = event.streams[0]`；页面用 `RTCVideoView(renderer)`
   渲染原生纹理，`BoxFit.contain` 保持 1:1 像素，不超采样。
6. 远端候选 → `pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex))`。

### 5.2 清晰度（命门，别改）

| 位置 | 设置 | 说明 |
|---|---|---|
| transceiver | **maintain-resolution** | flutter_webrtc 没有 `transceiver.degradationPreference`，等价写法是把 `RTCDegradationPreference.MAINTAIN_RESOLUTION` 写进 sender 的 RTP 参数（`sender.setParameters`）；recvonly 无 SSRC 时平台可能拒绝，已 catch，**不影响收流** |
| 接收端渲染 | `BoxFit.contain` | 不做缩放，画面像素与编码分辨率 1:1 |
| 被控端 | `stream.config.bitrate` | 页面切档位时随 `stream.config` 下发 4000/8000/20000 kbps，真正决定清晰度的是这条（Agent 侧 8 Mbps + 同策略） |
| `jitterBufferTarget = 0` | ❌ 未实现 | 插件未暴露该参数，见「已知限制」 |

HUD 显示 `H.264 · {fps} fps · {W}×{H}`，数据取自 `pc.getStats()` 的
`inbound-rtp(kind=video)`：`framesPerSecond` / `frameWidth` / `frameHeight`
（没有 `framesPerSecond` 时按 `framesDecoded` 差分自算）。

### 5.3 失败怎么回落（协议 §5）

| 时机 | 行为 |
|---|---|
| `start()` 抛错（平台不支持 / 建 PC 失败 / 无法初始化渲染器） | 页面 catch → 装 `JpegTransport` → toast「H.264 直连不可用，已回落 JPEG」 |
| 协商期失败（`setRemoteDescription` 报错） | 传输层记下 `fallbackReason`，页面在 `start()` 返回后补查并回落 |
| 运行中 `connectionState` = `failed` / `disconnected` | `onFallback` 回调 → 关 PC → 切回 JPEG → toast（含原因） |
| 收到 `rtc.close` | 同上（对端主动收线，Agent 会恢复 JPEG 推流） |
| 回落前后 | 传输层 dispose 时补发一条 `rtc.close`，避免 Agent 白推 WebRTC |

回落是单向的：一次会话内不再自动重试 WebRTC，需要点「重新连接」（避免和 Agent 的重协商互踢）。

### 5.4 iOS 需要什么 Info.plist 权限

纯接收**不需要**摄像头/麦克风权限，`ios/Runner/Info.plist` 现在一项都不用加。需要补的只有：

| 场景 | 键 | 值 |
|---|---|---|
| 连内网被控端（iOS 14+ 局域网访问弹窗） | `NSLocalNetworkUsageDescription` | 如「需要访问局域网内的被控设备以建立直连」 |
| v2 音频（收被控端声音，**只播放不采集**） | 无需权限 | 仅 `AVAudioSession` 播放类别，`flutter_webrtc` 自己配 |
| v2 若做「本机麦克风上行」 | `NSMicrophoneUsageDescription` | 说明文案，否则启动即崩 |

macOS：沙盒必须开 `com.apple.security.network.client`（已在
`macos/Runner/{DebugProfile,Release}.entitlements` 里）；如将来做音频上行再加
`com.apple.security.device.audio-input`。

平台最低版本要求（`flutter_webrtc` 1.6.3）：iOS ≥ 13.0、macOS ≥ 10.15 —— 本工程
分别是 15.0 / 12.0，无需改动。

### 5.5 输入与坐标（不变式）

`RTCVideoView` 挂在远控页 `_stage` 那层 `Listener` 之下，与 JPEG 的 `Image.memory`
共用同一套 `localPosition → 0..1` 归一化（`BoxFit.contain` 的留白偏移也一并算掉）。
换通路不改任何协议字段：`{p:"input", t, x, y, ...}`、x/y ∈ [0,1]。

---

## 5.5 本地验证结果（Flutter 3.50.1 / macOS arm64）

```
$ flutter pub get                     → +9 dependencies（flutter_webrtc 1.6.3 / dart_webrtc 1.8.2 ...）
$ flutter analyze --fatal-infos       → No issues found!
$ flutter test                        → 00:25 +22: All tests passed!
$ flutter build bundle                → 成功（kernel_blob.bin + flutter_assets，等价于 Dart 全量编译通过）
```

**没做**：`flutter build macos/android/ios`（本机无 Xcode / Android SDK），`flutter run` 真机运行，
以及一次真实的 H.264 端到端联调（需要 Agent + 服务端在跑）。平台构建请交给 CI（见下一节）。

---

## 6. 已知限制

1. **JPEG 通路是兜底方案**：`Image.memory` 每帧解码 + 上传纹理，1080p@30 时 CPU/GPU 占用高、
   有 1 帧级抖动。WebRTC 可用时不会走这条路。
2. **WebRTC 未做真机联调**：代码路径、依赖与协议字段已对齐（`flutter analyze/test/build bundle` 全绿），
   但 SDP 协商、TURN 兜底、`connectionState` 回落需要 Agent + 服务端在跑才能验证；
   首次真机验证建议先看 HUD 的 fps 是否 > 0、分辨率是否等于档位宽度。
3. **`jitterBufferTarget = 0` 未实现**：`flutter_webrtc` 未暴露该参数（协议 §3 建议项），
   延迟目前靠 `playout-delay` 默认值 + 低抖动网络；要强制需改插件或改 SDP。
4. **`degradationPreference` 是 best-effort**：recvonly sender 无 SSRC，部分平台 `setParameters` 返回 false
   （已忽略）。清晰度实际由被控端码率/策略决定，本端只保证不缩放。
5. **没有自动重连**：WS 掉线后需点右上角「重新连接」（骨架期故意不做退避重试，避免掩盖问题）；
   WebRTC 断链后同样是「一次性回落 JPEG」，不自动重试 H.264。
6. **自签证书全放行**，仅适合自托管内网/测试环境。
7. **移动端 UI 未在真机验证**（本机无 Android SDK / Xcode）；触控已按「单指移动=光标、轻点=左键、
   长按 550ms=右键」实现，阈值未实测调优。
8. **Android 9+ 不支持 `http://` 服务端**：默认未开 `usesCleartextTraffic`，请用 `https://`；
   若内网必须走明文，需在 `AndroidManifest.xml` 加网络明文策略（不推荐）。
9. **v2 能力未实现**：音频、剪贴板同步、多屏切换、修饰键状态机只留了挂点与 TODO 注释
   （见 `webrtc_transport.dart` 末尾的表格）。
10. **Android release 是 debug key 签名**，可安装调试、不能上架（换签名见第 7 节）。

---

## 7. CI 构建（已落地在 `.github/workflows/build.yml`）

> 该 workflow 由 `ci-packager` 维护，本目录只写说明，不改 `.github/`。
> **注意路径基准**：仓库根目录就是 `remote-desktop/`，所以 job 里的
> `working-directory` 是 `client-flutter`，**不要**写成 `remote-desktop/client-flutter`。

| job | runner | 内容 | 产物 |
|---|---|---|---|
| `flutter-verify` | ubuntu-latest | `pub get` → `analyze --fatal-infos` → `test` | — |
| `flutter-build-macos` | macos-latest（自带 Xcode） | `flutter build macos --release` | `uu-remote-client-flutter-macos`（`client-flutter/build/macos/Build/Products/Release/*.app`） |
| `flutter-build-linux` | ubuntu-latest | 装 `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev` 后 `build linux --release` | `uu-remote-client-flutter-linux`（`build/linux/x64/release/bundle`） |
| `flutter-build-android` | ubuntu-latest + Java 17 | `flutter build apk --release` | `uu-remote-client-flutter-android`（`.apk`） |

所有 job 固定 `flutter-version: 3.50.1` + `cache: true`；`flutter-verify` 通过后三个平台构建才跑。

本地等价验证（本机无 Xcode / Android SDK，只能做到这层）：

```bash
cd client-flutter
flutter pub get && flutter analyze --fatal-infos && flutter test
flutter build bundle     # Dart 全量编译，但不出安装包
```

注意：
- **Flutter 版本必须 ≥ 3.47，CI 钉 3.50.1**：`material_ui` 依赖与 import 都是 3.50 模板写法。
  版本对不上会直接 `pub get` 失败（`material_ui` 解析不到 / import 未定义），不要放松 `sdk` 约束来绕过。
- **Android release 目前用 debug key 签名**（`android/app/build.gradle.kts` 里
  `signingConfig = signingConfigs.getByName("debug")`）：能装能跑，**不能上架**。要发布需配
  keystore + `key.properties` 并换成 release signingConfig。
- `build-ios` 未进 CI（需要签名证书）；如需验证编译可单独跑 `flutter build ios --no-codesign`。
- **`flutter_webrtc` 带原生依赖，macOS/Linux/Android job 会明显变慢**：
  - macOS：`flutter build macos` 会自动跑 `pod install` 拉 `WebRTC.xcframework`（数百 MB），
    `macos-latest` runner 自带 CocoaPods，**workflow 不需要加任何 pod 步骤**；只是首次构建慢。
  - Linux：插件在 CMake 配置阶段从 `github.com/webrtc-sdk/libwebrtc/releases` 下载预编译
    `libwebrtc.m150.7871.07`（zip，数百 MB）解到 `third_party/`，需要 runner 能出网；
    `libpulse` dev 头可选（没有只是禁掉系统音频环回，不影响收流）。
    建议给 CI 加缓存目录：`~/.pub-cache`（已有）以外的 `third_party` 不好缓存，就近缓存整个
    `client-flutter/build/linux` 更快。
  - Android：插件 `compileSdk 36 / minSdk 21`，与模板一致，gradle 侧无需改；
    打包体积会 +~15–20 MB（libwebrtc .so）。
  - Ubuntu 的 `flutter-verify` job（`pub get`→`analyze`→`test`）不受影响，不跑原生构建，
    仍是几十秒级。
- `window_manager` 只声明 macOS/Windows/Linux 平台，Android/iOS 上不注册，代码里已用 `Platform.is*`
  保护，`build apk` 不受影响。
- `flutter test` 现在 22 项：协议解析（`hello`/`device.list`/信令地址/输入/帧头）+ ICE 转换与
  `rtc.offer`/`rtc.ice` 载荷（`test/rtc_signaling_test.dart`）+ UI 组件；仍没有 widget/集成测试
  （需要真机或模拟器，且 WebRTC 必须有 Agent 在对面）。
