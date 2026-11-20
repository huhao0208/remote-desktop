# client-flutter · UU Remote 控制端（Flutter 骨架）

Flutter 版控制端，目标是与 `srv2/control.html`、`client-desktop`、`client-mobile` 行为一致：
**登录 → 设备列表 → 远控**。v1 先用 JPEG 兜底通路，WebRTC(H.264) 只留接口。

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
| JPEG 帧渲染（`FRM1` + 8B 时间戳 + JPEG） | ✅ **临时方案**，P0-3 换 `Texture` |
| 输入转发（move / click / scroll / text / press / keydown / keyup） | ✅ 坐标归一化 0..1 |
| `stream.config` 画质切换（流畅/高清/超清） | ✅ |
| `MediaTransport` 抽象 + `JpegTransport` / `WebRtcTransport` | ✅ 抽象就位 |
| WebRTC `rtc.offer/answer/ice` | ❌ 见 `lib/media/webrtc_transport.dart` 的 TODO |
| 关机 `shutdown` UI、文件传输、剪贴板 | ❌ 未做（协议已就绪） |

骨架代码已在 Flutter 3.50.1 上验证：`flutter analyze` → **No issues found**，
`flutter test` → 10 passed，`flutter build bundle`（Dart 全量编译）通过。

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
    media_transport.dart    MediaTransport 抽象 + FramePacket + 占位视图
    jpeg_transport.dart     JPEG 兜底（FRM1 解析 + Image.memory）
    webrtc_transport.dart   WebRTC 占位 + 详细接入 TODO
    media_factory.dart      按 agent.hello.media 选通路
  pages/
    login_page.dart
    device_list_page.dart
    remote_page.dart        远控：HUD / 画质 / 鼠标键盘触控映射
test/
  protocol_test.dart        协议字段解析、信令地址组装、FRM1 帧头
```

### 页面 → 通路 的解耦点

`remote_page.dart` 只依赖 `MediaTransport`：

```dart
abstract class MediaTransport {
  String get kind;
  String get label;
  Stream<FramePacket> get frames;
  Future<void> start({required AgentHello hello, required RoomConfig room, required SignalingClient signaling});
  Widget buildView({required BoxFit fit});
  Future<void> dispose();
}
```

接 WebRTC 时只需实现 `WebRtcTransport` 并让 `createTransport()` 返回它，**远控页不动**。
`agent.hello.media == "webrtc"` 但 `WebRtcTransport.start()` 抛 `UnsupportedError` 时，远控页会
自动回落到 `JpegTransport` 并提示——对应协议 §5 的降级表。

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

## 5. 如何接 WebRTC（P0-3）

1. `pubspec.yaml` 加 `flutter_webrtc`。
2. 按 `lib/media/webrtc_transport.dart` 顶部 TODO 实现：
   - `createPeerConnection({'iceServers': room.iceServers})`（服务端下发的结构可直接透传）
   - `addTransceiver(video, RecvOnly)`，`degradationPreference = maintain-resolution`
   - `createOffer` → 发 `{"p":"rtc.offer","sdp":...,"ice":room.iceServers}`
   - 收 `rtc.answer` → `setRemoteDescription`；`rtc.ice` → `addCandidate`；本地 ICE → 发 `rtc.ice`
   - `onTrack` → `RTCVideoRenderer`，`buildView` 返回 `RTCVideoView`（**不要再走 Image.memory**）
   - `onConnectionState` failed → 通知页面回落 JPEG
3. macOS 需要在 `macos/Runner/DebugProfile.entitlements` 与 `Release.entitlements`
   里保留 `com.apple.security.network.client`（模板默认已开）。
4. 分辨率策略：不做超采样，`stream.config.width` 即目标宽度（协议 §3）。

---

## 5.5 本地验证结果（Flutter 3.50.1 / macOS arm64）

```
$ flutter pub get      → Changed 6 dependencies（material_ui / web_socket_channel 3.0.3 / window_manager 0.4.3 ...）
$ flutter analyze      → No issues found!
$ flutter test         → 00:00 +10: All tests passed!
$ flutter build bundle → 成功（kernel_blob.bin + flutter_assets，等价于 Dart 全量编译通过）
```

**没做**：`flutter build macos/android/ios`（本机无 Xcode / Android SDK），`flutter run` 真机运行。
平台构建请交给 CI（见下一节）。

---

## 6. 已知限制

1. **JPEG 渲染是临时方案**：`Image.memory` 每帧解码 + 上传纹理，1080p@30 时 CPU/GPU 占用高、
   有 1 帧级抖动。P0-3 换 `Texture`（WebRTC）后删除 `jpeg_transport.dart` 的渲染分支即可。
2. **WebRTC 未接入**，`media:"webrtc"` 时必定回落 JPEG（Agent 未连上 RTC 时仍在推 JPEG，所以能看见画面）。
3. **没有自动重连**：WS 掉线后需点右上角「重新连接」（骨架期故意不做退避重试，避免掩盖问题）。
4. **自签证书全放行**，仅适合自托管内网/测试环境。
5. **移动端 UI 未在真机验证**（本机无 Android SDK / Xcode）；触控已按「单指移动=光标、轻点=左键、
   长按 550ms=右键」实现，阈值未实测调优。
6. **Android 9+ 不支持 `http://` 服务端**：默认未开 `usesCleartextTraffic`，请用 `https://`；
   若内网必须走明文，需在 `AndroidManifest.xml` 加网络明文策略（不推荐）。
7. 关机按钮、文件传输、剪贴板同步未做。
8. 键盘映射覆盖常用键；输入法（IME）组词走 `text` 事件，复杂中文输入未验证。
9. 远控页的画质下拉、HUD 只在桌面端布局验证过（窄屏隐藏 HUD chips，但未做真机尺寸适配打磨）。
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
- `window_manager` 只声明 macOS/Windows/Linux 平台，Android/iOS 上不注册，代码里已用 `Platform.is*`
  保护，`build apk` 不受影响。
- `flutter test` 目前只有协议单测（10 项），没有 widget/集成测试（需要真机或模拟器）。
