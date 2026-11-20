# CI 打包说明（含 WebRTC：aiortc + av + numpy）

本文件只讲「怎么把带 WebRTC 媒体通道的 `uu-agent` 打成单文件二进制」，供接手人照抄。
涉及文件：`.github/workflows/build.yml`（`binary` / `desktop-client` 两个 job）。

## 1. Agent 新增的依赖

`agent/webrtc_media.py` 引入：

| 包 | 本地实测版本 | 作用 | 是否带原生二进制 |
|---|---|---|---|
| `aiortc` | 1.16.0 | PeerConnection / SDP / RTP 收发 | 否（纯 Python） |
| `av` (PyAV) | 19.0.2 | 屏幕帧 → H.264（libx264） | **是**：`av/_core.abi3.so` + `av/.dylibs/lib*.dylib` |
| `numpy` | 2.5.5 | aiortc/av 的图像缓冲区 | 是（.so/.pyd） |
| `pylibsrtp` | 1.0.0 | SRTP 加密（aiortc 自动带） | **是**：`pylibsrtp/_binding.abi3.so` |
| `Pillow` / `mss` | 原有 | 抓屏、resize | Pillow 自带大量 dylib |

`agent.py` 里是 **函数内延迟 import**（`run()` 里 `from webrtc_media import WebRTCMedia`），
PyInstaller 的静态分析看不到，而且 `webrtc_media` 与被分析脚本同目录、不是安装包，
**所以必须显式 `--hidden-import webrtc_media`**，否则打出来的二进制一律退回 JPEG 推流
（不会报错，只会打一行 `[agent] WebRTC 不可用`，很容易误判为「CI 正常」）。

## 2. 最终可用参数（已验证）

```
pyinstaller --onefile --name uu-agent \
  --collect-submodules mss \
  --collect-submodules aiortc \
  --collect-all av \
  --hidden-import webrtc_media \
  --hidden-import pyautogui --hidden-import PIL \
  --distpath <dist> --workpath <tmp> --specpath <tmp> \
  agent/agent.py
```

要点：

- `--collect-submodules aiortc`：aiortc 的编解码器/传输类是运行时按需取的，静态分析漏项多。
- `--collect-all av`：把 `av/.dylibs/libavcodec|libavutil|libx264|libopus...` 全带上。
  实测 PyInstaller 自带的 hook-av 也能收（不加这个参数 libx264 仍可用），
  但显式加上代价几乎为零（体积差 < 1 MB），跨平台更稳，保留。
- `--hidden-import webrtc_media`：见上一节，**不能省**。
- 不需要 `--hidden-import pylibsrtp/aioice/cryptography`：它们由 aiortc 的静态 import 带进来，
  已实测在产物内可正常 `Policy(key=...)` / `Session(...)`。
- `--specpath` 放到临时目录不影响 `--hidden-import webrtc_media` 解析：
  实测 `--specpath /tmp/... agent/agent.py` 也能找到 `agent/webrtc_media.py`。

## 3. 本地验证结果（macOS 14 / Apple Silicon / Python 3.13.12 / PyInstaller 6.22.3）

| 项目 | 结果 |
|---|---|
| 产物大小 | **50 MB**（`uu-agent`，arm64，onefile） |
| `./uu-agent --help` | 正常输出全部参数，无 ImportError |
| 冷启动耗时 | 首次 8.2 s（macOS 对未签名 50 MB 二进制做校验），之后 5.0–6.5 s |
| 归档内容 | 64 个 `aiortc.*` 模块 + `webrtc_media` 在 PYZ 内；`av/.dylibs/libx264.165.dylib` 等 20 个 ffmpeg 库；`pylibsrtp/_binding.abi3.so` 均在包内 |
| 运行时冒烟 | 单独用相同参数打了探针二进制：`import av/aiortc/webrtc_media/numpy` OK、`av.CodecContext.create("libx264","w")` OK、`pylibsrtp.Policy(key=30B)` OK、`Session(policy=...)` OK |

冷启动 5 s 主要是 onefile 每次运行都要把 50 MB 解压到临时目录。Agent 是开机常驻进程，
一次性代价可接受；若以后不能接受，再考虑 `--onedir` 分发（会改变产物形态，需同步改
`desktop-client/package.json` 的 `extraResources`）。

## 4. CI 改动点

1. `binary` job 的 `Install deps`：追加 `aiortc av numpy`
   （`pylibsrtp / aioice / pyee / cryptography / google-crc32c` 作为 aiortc 依赖自动装）。
2. `binary` job 的 agent 打包命令：加上 `--collect-submodules aiortc --collect-all av --hidden-import webrtc_media`。
   服务端 `uu-server` 的打包命令**未改动**（不需要 WebRTC）。
3. `desktop-client` job 的 "Build embedded agent"：`pip install` 同样追加 `aiortc av numpy`，PyInstaller 参数同上。
   产物仍落 `client-desktop/bin`，由 electron-builder 的 `extraResources` 打进安装包。
4. `source-packs` job 的 Termux 包：补 `cp agent/webrtc_media.py pack-termux/`
   —— 原来只拷 `agent.py`，Termux 包里 `webrtc_media` 缺失 → 只能用 JPEG。
5. 产物命名、`upload-artifact` 路径、各平台 `sep`/`ext` 变量一律未改。

## 5. 各平台可行性（已查 PyPI 轮子，非猜测）

用 `pip download --only-binary=:all: --python-version 312 --platform <plat>` 实测：

| 平台 | av | pylibsrtp | numpy | google-crc32c | 结论 |
|---|---|---|---|---|---|
| `win_amd64` | 19.0.2 ✓ | 1.0.0 ✓ | 2.5.5 ✓ | 1.9.0 ✓ | 可打包 |
| `manylinux_2_28_x86_64` | 19.0.2 ✓ | 1.0.0 ✓ | 2.5.5 ✓ | ✓ | 可打包（ubuntu-latest glibc 2.39） |
| `macosx_11_0_arm64` | 19.0.2 ✓（本机实打实跑） | ✓ | ✓ | ✓ | 可打包 |

Python 3.12 下 `numpy 2.5` 要求 ≥3.11、`av 19` 要求 ≥3.9、`aiortc 1.16` 要求 ≥3.9，均满足。

## 6. 踩过的坑

1. **`webrtc_media` 静默丢失**：延迟 import + 同目录模块，不加 `--hidden-import` 不报错，
   只是运行时退回 JPEG。判断方法：`grep -c aiortc <workpath>/PYZ-00.toc`，
   或看 Agent 启动日志有没有 `[agent] WebRTC 不可用`。
2. **av 的 dylib**：`av` 的 ffmpeg 全在 `av/.dylibs/`，只拷 `.so` 会 `ImportError: libavcodec`。
   用 `--collect-all av`（或确认 hook-av 生效）。
3. **`--help` 不能证明打进去了**：`--help` 在 argparse 阶段就退出，根本不会 import aiortc。
   验证要单独打一个探针脚本 import 真模块 + 创建 libx264 编码器。
4. **构建告警里的 `cython` / `collections.abc` missing 是噪声**：cython 只在编译期用，不影响运行。
5. **体积跳变**：50 MB 里 av(dylib) + numpy + Pillow 占大头；不要试图 `--exclude-module numpy`
   来瘦身，aiortc/av 都依赖它。
6. **Termux / 源码包不装 aiortc 时**，`agent.py` 会自动退回 JPEG（try/except），属预期降级；
   需要 WebRTC 就在 Termux 里 `pip install aiortc av numpy`（Termux 有 aarch64 轮子，编译慢）。

## 7. Flutter 控制端（client-flutter，3 个构建 job）

`flutter-verify` 是门禁，三个 `flutter-build-*` 都 `needs: flutter-verify`，只有 analyze/test
通过才会跑；`release` job 的 `needs` 也已包含这三个 job，tag 发布时产物一并上传。

| job | runner | 关键依赖 | 产物（artifact 名 / 大小） |
|---|---|---|---|
| `flutter-verify` | ubuntu-latest | `subosito/flutter-action@v2`，钉 `stable / 3.50.1`（Dart 3.14，pubspec 要求 sdk ≥3.13） | 无（只跑 `flutter pub get` / `analyze --fatal-infos` / `test`） |
| `flutter-build-macos` | macos-latest (arm64) | runner 自带 Xcode + CocoaPods；工程无第三方原生插件，`macos/Runner/Release.entitlements` 已开 `com.apple.security.network.client`（沙箱内联网必需） | `uu-remote-client-flutter-macos` / `uu-remote-client-flutter-macos.zip`（`ditto` 归档 .app），v0.1.1 实测 18 MB（解包 53 MB） |
| `flutter-build-linux` | ubuntu-latest | `apt-get install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`（Flutter Linux 桌面必需，缺 GTK 会直接 cmake 失败） | `uu-remote-client-flutter-linux` / `uu-remote-client-flutter-linux.tar.gz`（tar 保住可执行位），v0.1.1 实测 10 MB |
| `flutter-build-android` | ubuntu-latest | `actions/setup-java@v4` temurin **JDK 17** + runner 自带 Android SDK（无需 setup-android） | `uu-remote-client-flutter-android` / `uu-remote-client-flutter-android.apk`，v0.1.1 实测 51 MB |

已知限制：

1. **`lib/` 曾被 `.gitignore` 整条忽略**（裸 `lib/` 规则会匹配任意层级的 `lib/`），
   导致 `client-flutter/lib/**` 从未入库、CI 报 `Target of URI doesn't exist: package:uu_remote/...`。
   现已改为根锚定的 `/lib/`，**新增 Flutter 目录时注意别再写裸路径规则**。
2. Android 产物用 **debug key 签名**（`flutter build apk --release` 未配 `key.properties`），
   可安装可运行，**不能上架**；正式发布需补 keystore 与 `signingConfigs`。
3. macOS 产物未签名/未公证，用户首次打开需右键「打开」或在系统设置里放行；
   覆盖分发需 Developer ID 证书 + `notarytool`。
4. Linux 产物依赖 runner 的 glibc（ubuntu-latest，2.39+），老发行版需自行降级构建环境。

## 8. 遗留风险

- **Windows / Linux 只验证了轮子存在与参数正确，没在真机跑过**。首次 CI 跑绿后建议顺手
  检查日志里 Agent 是否打印 `[rtc] answer 已发`（说明 aiortc 真的起来了）。
- **aiortc 私有字段**（`_H264Encoder__target_bitrate`）在 `webrtc_media.py` 里被直接赋值，
  升级 aiortc 需复核；这属于运行时代码，与打包无关，但升级时要一起看。
- `-onefile` 冷启动 5 s 左右（解压 50 MB）；如需秒开改 `--onedir`，会牵动客户端 `extraResources` 结构。

## 9. Release 资产清单

**发布范围（v0.1.2 起）**：客户端只有 Flutter 一套，加上服务端/被控端包，共 **8 个资产**。
Electron 桌面端与 Capacitor 安卓/iOS 产物已停止发布，见 §9.3（v0.1.1 里还能下到，只作历史保留）。

体积取自 v0.1.1 Release 实测值，四舍五入到 MB；v0.1.2 重新打包后以 Release 页数字为准。
`v0.1.0` 已标记为 **pre-release**，它的 `uu_remote` 是个 23 KB 的假文件、Linux 桌面包还缺失，
只作历史保留，**不要下载**。

> 仓库当前是 **private**，直接 `curl` 资产链接会 404（返回 `Not Found`），
> 必须用 `gh release download v0.1.1 -R huhao0208/remote-desktop` 或浏览器登录后点。
> 要对外分享需先公开仓库（由仓库主决定）。

### 9.1 服务端 + 被控端（同一份包内含 `uu-server` 与 `uu-agent`）

装服务端的那台机器（VPS/局域网主机）和被控的电脑各取所需，包里 `server/`、`client/`
两个目录，`START.md` 写了启动命令。

| 资产 | 体积 | 给谁用 |
|---|---|---|
| `uu-remote-windows-x64.zip` | 84 MB | Windows 做服务端或被控端（`uu-server.exe` / `uu-agent.exe`） |
| `uu-remote-macos-arm64.tar.gz` | 66 MB | Apple Silicon Mac（M 系列）；CI 只产出 arm64，Intel Mac 需自行 `pyinstaller`（见 §2） |
| `uu-remote-linux-x64.tar.gz` | 138 MB | Linux VPS / NAS 免 Docker 部署（也含被控端） |
| `uu-remote-android-termux.tar.gz` | 40 KB | 安卓手机 Termux 里直接跑源码（无预编译二进制，需 `pip install`） |
| `uu-remote-universal.tar.gz` | 55 KB | 任意平台源码包（Python 3.10+），排查问题/改代码用 |

服务端二进制**不含证书**：自己把 TLS 证书放到 `server/certs/fullchain.pem`、
`privkey.pem`，否则 `uu-server` 起不来（或走 Docker Compose 挂载）。

### 9.2 控制端（Flutter，唯一发布的客户端）

官方浅色风界面，桌面/移动同一套代码、装上即用（内置默认服务器地址）。
体积取自 v0.1.1：macOS 包是 **53 MB 解包 / 18 MB zip**，冷启约 0.7 s。

| 资产 | 体积 | 给谁用 |
|---|---|---|
| `uu-remote-client-flutter-macos.zip` | 18 MB（解包 53 MB） | Apple Silicon macOS；解压得 `uu_remote.app`（未签名，右键「打开」） |
| `uu-remote-client-flutter-linux.tar.gz` | 10 MB | Linux 桌面；解压得 `bundle/` 目录，跑 `bundle/uu_remote` |
| `uu-remote-client-flutter-android.apk` | 51 MB | 安卓手机（debug key 签名，可装不可上架） |

**Windows 与 iOS 没有 Flutter 桌面/移动包**：Windows 用户请用 H5 控制页
（`https://<host>:8443/control`）或 v0.1.1 里的 Electron 版；iOS 用户用 Safari 开 H5 控制页。
媒体通路见 §9.4 第 5 条。

### 9.3 已废弃，不再发布（Electron / Capacitor）

`desktop-client`、`android-apk`、`ios-project` 三个 CI job 已加 `if: false` 留档，
不再进 `release.needs`，因此 **v0.1.2 起的 Release 里不会再有下面这些包**。
需要老版本请到 `v0.1.1` 下载（仍可安装使用，但不再修复）。

| 旧资产 | 体积 | 原来给谁用 | 被谁取代 |
|---|---|---|---|
| `uu-remote-client-win-x64.exe` | 148 MB | Windows 安装包（Electron） | 无 Flutter 版 → 用 H5 控制页 |
| `uu-remote-client-mac-arm64.dmg` / `.zip` | 147 / 143 MB | Apple Silicon Mac（Electron） | Flutter macOS zip |
| `uu-remote-client-mac-x64.dmg` / `.zip` | 151 / 148 MB | Intel Mac（Electron） | 无 Flutter x64 包 → 暂留 v0.1.1 |
| `uu-remote-client-linux-x86_64.AppImage` | 204 MB | Linux 桌面（Electron） | Flutter Linux tar.gz |
| `uu-remote-client-android.apk` | 3.8 MB | 安卓（Capacitor 壳） | Flutter 安卓 apk |
| `uu-remote-client-ios-project.zip` | 217 KB | iPhone（Capacitor Xcode 工程） | 无（iOS 走 H5 / 自行构建 Flutter iOS） |

Electron 版的差别：它内置被控端 Agent、开箱即有 H.264；Flutter 版当前媒体通路见 §9.4。
v0.1.0 的 macOS/Linux Flutter 包是坏的（macOS 变成 23 KB 的 `uu_remote`、Linux 整个丢失），
根因见 §10。

### 9.4 已知限制（下载前先看）

1. **全部 macOS 产物未签名 / 未公证**：首次打开会被 Gatekeeper 拦。右键 →「打开」，
   或 `xattr -dr com.apple.quarantine /Applications/uu_remote.app`。正式分发需
   Developer ID 证书 + `notarytool`。
2. **Windows 没有发布包**：Electron 版已废弃，Flutter 也没出 Windows 构建；
   Windows 控制端请用浏览器开 `https://<host>:8443/control`（H5 控制页）。
3. **安卓 APK 是 debug key 签名**（Flutter 版 51 MB）：
   能装能跑，**不能上架应用商店**；上架需补 `key.properties` + `signingConfigs`。
4. **iOS 没有发布产物**：Capacitor 工程已废弃，Flutter iOS 需要 Mac + Xcode 自行构建并
   签名（免费 Apple ID 7 天过期）；临时用 iPhone Safari 开 H5 控制页。
5. **Flutter 版 WebRTC 状态以实际为准**：H.264 通路正在接入（`flutter-webrtc` 负责），
   接入前一律回落 JPEG（界面会提示「H.264 通路尚未接入」）。v0.1.2 Release notes 会写明
   该版本的实测状态，不要只看文档描述。
6. **Linux Flutter 包绑定 runner 的 glibc**（ubuntu-latest，2.39+），老发行版跑不起来。
7. 服务端二进制需自备 TLS 证书（见 §9.1 末尾）。

## 10. v0.1.0 打包事故复盘（目录被当文件上传）

**现象**：v0.1.0 Release 里有一个 23 KB 的 `uu_remote`，下载后解不出 App；
同时 `uu-remote-client-flutter-linux` 整个不见了。

**根因**：`flutter-build-macos` 的 `upload-artifact` 路径是
`.../Release/*.app`（目录），`flutter-build-linux` 是 `.../release/bundle`（目录）。
`release` job 用 `download-artifact` 的 `merge-multiple: true` 把所有 artifact
展平到同一目录，目录条目无法作为「一个文件」存在 →
macOS 那个退化成单个残留条目被 `action-gh-release` 当文件发出，Linux 那个被拆散。

**修法**：两个 job 都先在本地归档再上传单个文件
（macOS `ditto -c -k --sequesterRsrc --keepParent` → `.zip`；
Linux `tar -czf` → `.tar.gz`，tar 保住可执行位）。

**教训**：凡是要进 Release 的产物，`upload-artifact` 的 `path` 必须是
**文件或通配到文件**，绝不能让目录参与 `merge-multiple` 的合并。