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

## 7. Flutter 控制端（client-flutter，4 个构建 job）

`flutter-verify` 是门禁，四个 `flutter-build-*` 都 `needs: flutter-verify`，只有 analyze/test
通过才会跑；三个桌面 job 还额外 `needs: binary`（要从服务端/Agent 包里取 `uu-agent` 塞进
客户端，见下「随包被控端」）。`release` job 的 `needs` 已包含这四个 job，tag 发布时产物一并上传。

| job | runner | 关键依赖 | 产物（artifact 名 / 大小） |
|---|---|---|---|
| `flutter-verify` | ubuntu-latest | `subosito/flutter-action@v2`，钉 `stable / 3.50.1`（Dart 3.14，pubspec 要求 sdk ≥3.13） | 无（只跑 `flutter pub get` / `analyze --fatal-infos` / `test`） |
| `flutter-build-macos` | macos-latest (arm64) | runner 自带 Xcode + CocoaPods；`macos/Runner/Release.entitlements` 已开 `com.apple.security.network.client`（沙箱内联网必需） | `uu-remote-client-flutter-macos` / `uu-remote-client-flutter-macos.zip`：塞入 agent → **ad-hoc 签名**（先签 agent 再 `--deep` 签 App）→ `ditto` 归档，脚本断言 zip 内有 `Contents/Resources/agent/uu-agent` |
| `flutter-build-linux` | ubuntu-latest | `apt-get install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`（Flutter Linux 桌面必需，缺 GTK 会直接 cmake 失败） | `uu-remote-client-flutter-linux` / `uu-remote-client-flutter-linux.tar.gz`（tar 保住可执行位），agent 放 `bundle/data/flutter_assets/agent/uu-agent`，tar 内断言其存在 |
| `flutter-build-windows` | windows-latest | 镜像自带 VS 2022「使用 C++ 的桌面开发」，无需额外装 MSVC；`shell: pwsh` | `uu-remote-client-flutter-windows` / `uu-remote-client-flutter-windows.zip`（`Compress-Archive` 打 `runner/Release/*`），agent 放 `agent\uu-agent.exe`，脚本断言根目录 `uu_remote.exe` 与 agent 都在 |
| `flutter-build-android` | ubuntu-latest | `actions/setup-java@v4` temurin **JDK 17** + runner 自带 Android SDK（无需 setup-android） | `uu-remote-client-flutter-android` / `uu-remote-client-flutter-android.apk`，v0.1.1 实测 51 MB（纯控制端，不带 agent） |

**随包被控端（uu-agent）**：客户端登录后会拉起随包分发的被控端进程
（`client-flutter/lib/core/agent_host.dart`），找不到就提示「被控端未随包分发」。CI 的做法是
`flutter build *` 之后从同平台的 `uu-remote-<platform>` 包里取出 `client/uu-agent[.exe]`，复制到
以下位置（顺序必须在打包/签名之前）：

| 平台 | 目标路径 |
|---|---|
| macOS | `uu_remote.app/Contents/Resources/agent/uu-agent`（0755，且必须先签名再签整个 App） |
| Windows | `agent\uu-agent.exe`（与 `uu_remote.exe` 同级的子目录，代码也兼容同级直接放） |
| Linux | `bundle/data/flutter_assets/agent/uu-agent`（0755） |

不要试图在 `flutter build bundle` 阶段塞：那一步只编 Dart，产物会被后续原生构建覆盖。
三个桌面 job 因此 `needs: [flutter-verify, binary]`（`binary` 才产出 agent 二进制）。

已知限制：

1. **`lib/` 曾被 `.gitignore` 整条忽略**（裸 `lib/` 规则会匹配任意层级的 `lib/`），
   导致 `client-flutter/lib/**` 从未入库、CI 报 `Target of URI doesn't exist: package:uu_remote/...`。
   现已改为根锚定的 `/lib/`，**新增 Flutter 目录时注意别再写裸路径规则**。
2. Android 产物用 **debug key 签名**（`flutter build apk --release` 未配 `key.properties`），
   可安装可运行，**不能上架**；正式发布需补 keystore 与 `signingConfigs`。
3. macOS 产物是 **ad-hoc 签名**（不是 Developer ID，也没公证）：不签会因
   `app-sandbox=true` 在沙箱初始化时 SIGTRAP 崩溃，所以 CI 必须签；用户首次打开仍需
   `xattr -dr com.apple.quarantine` 或右键「打开」，且只能自用、不能分发给别人的 Mac
   （详 §9.4 第 1 条）；要对外分发需 Developer ID 证书 + `notarytool`。
4. Linux 产物依赖 runner 的 glibc（ubuntu-latest，2.39+），老发行版需自行降级构建环境。
5. **macOS runner 偶发排队 15 分钟后被 GitHub 直接 cancel**——这不是代码失败。判断依据：
   打开该 job，`started_at` 有值但 `runner_name` 为空、`steps` 列表为空，说明从头到尾
   没分配到机器（真失败一定会有具体的失败 step）。处理：`gh run rerun <run-id> --failed`
   重跑即可，通常第二次就能拿到 runner。**不要因此把 macOS 构建改成只在 tag 触发**——
   这台开发机没有 Xcode，CI 是产出 macOS 客户端的唯一途径。

## 8. 遗留风险

- **Windows / Linux 只验证了轮子存在与参数正确，没在真机跑过**。首次 CI 跑绿后建议顺手
  检查日志里 Agent 是否打印 `[rtc] answer 已发`（说明 aiortc 真的起来了）。
- **aiortc 私有字段**（`_H264Encoder__target_bitrate`）在 `webrtc_media.py` 里被直接赋值，
  升级 aiortc 需复核；这属于运行时代码，与打包无关，但升级时要一起看。
- `-onefile` 冷启动 5 s 左右（解压 50 MB）；如需秒开改 `--onedir`，会牵动客户端 `extraResources` 结构。

## 9. Release 资产清单

**发布范围（v0.1.2 起）**：客户端只有 Flutter 一套，加上服务端/被控端包，共 **9 个资产**
（4 个 Flutter 客户端 + 5 个服务端/Agent 包）。Electron 桌面端与 Capacitor 安卓/iOS 产物
已停止发布，见 §9.3（v0.1.1 里还能下到，只作历史保留）。

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
| `uu-remote-windows-x64.zip` | 85 MB | Windows 做服务端或被控端（`uu-server.exe` / `uu-agent.exe`） |
| `uu-remote-macos-arm64.tar.gz` | 66 MB | Apple Silicon Mac（M 系列）；CI 只产出 arm64，Intel Mac 需自行 `pyinstaller`（见 §2） |
| `uu-remote-linux-x64.tar.gz` | 139 MB | Linux VPS / NAS 免 Docker 部署（也含被控端） |
| `uu-remote-android-termux.tar.gz` | 53 KB | 安卓手机 Termux 里直接跑源码（无预编译二进制，需 `pip install`） |
| `uu-remote-universal.tar.gz` | 96 KB | 任意平台源码包（Python 3.10+），排查问题/改代码用 |

服务端二进制**不含证书**：自己把 TLS 证书放到 `server/certs/fullchain.pem`、
`privkey.pem`，否则 `uu-server` 起不来（或走 Docker Compose 挂载）。

### 9.2 控制端（Flutter，唯一发布的客户端）

官方浅色风界面，桌面/移动同一套代码、装上即用（内置默认服务器地址）。
**三个桌面包都自带被控端 `uu-agent`**（PyInstaller 单文件，macOS 49 MB / Windows 68 MB），
所以「允许其他设备控制本机」开箱可用；代价是包体比 v0.1.1 大很多——
v0.1.1 的 macOS 包是 18 MB zip / 53 MB 解包，带上 agent 后变成约 82 MB zip / 121 MB 解包。
安卓包是纯控制端，不含 agent。

| 资产 | 体积 | 给谁用 |
|---|---|---|
| `uu-remote-client-flutter-macos.zip` | 约 82 MB（解包 121 MB） | Apple Silicon macOS；解压得 `uu_remote.app`，**已做 ad-hoc 签名**（首次仍要过 Gatekeeper，见 §9.4 第 1 条） |
| `uu-remote-client-flutter-windows.zip` | 约 89 MB（解包 118 MB） | Windows 10/11 x64；解压后双击 `uu_remote.exe`，被控端在同目录 `agent\uu-agent.exe`（未签名，SmartScreen 需「仍要运行」） |
| `uu-remote-client-flutter-linux.tar.gz` | 约 121 MB | Linux 桌面；解压得 `bundle/`，跑 `bundle/uu_remote`，被控端在 `bundle/data/flutter_assets/agent/uu-agent` |
| `uu-remote-client-flutter-android.apk` | 约 88 MB | 安卓手机（debug key 签名，可装不可上架；纯控制端，不带 agent） |

被控端首次运行需要在系统里授权：macOS 给「屏幕录制 + 辅助功能」，Windows/Linux 视系统而定。

**iOS 没有发布产物**：CI 不产出 ipa（`flutter build ios --no-codesign` 出来的未签名 `.app`
对用户装不上，没意义）。需要 iOS 客户端请自行用 Xcode 打开 `client-flutter/ios` 构建，
并用 Apple 开发者账号签名 —— 这与 Capacitor 时代「只给 Xcode 工程」的处境一致，不是能力倒退。

媒体通路见 §9.4 第 5 条。

### 9.3 已废弃，不再发布（Electron / Capacitor）

`desktop-client`、`android-apk`、`ios-project` 三个 CI job 已加 `if: false` 留档，
不再进 `release.needs`，因此 **v0.1.2 起的 Release 里不会再有下面这些包**。
需要老版本请到 `v0.1.1` 下载（仍可安装使用，但不再修复）。

| 旧资产 | 体积 | 原来给谁用 | 被谁取代 |
|---|---|---|---|
| `uu-remote-client-win-x64.exe` | 148 MB | Windows 安装包（Electron） | Flutter Windows zip |
| `uu-remote-client-mac-arm64.dmg` / `.zip` | 147 / 143 MB | Apple Silicon Mac（Electron） | Flutter macOS zip |
| `uu-remote-client-mac-x64.dmg` / `.zip` | 151 / 148 MB | Intel Mac（Electron） | 无 Flutter x64 包 → 暂留 v0.1.1 |
| `uu-remote-client-linux-x86_64.AppImage` | 204 MB | Linux 桌面（Electron） | Flutter Linux tar.gz |
| `uu-remote-client-android.apk` | 3.8 MB | 安卓（Capacitor 壳） | Flutter 安卓 apk |
| `uu-remote-client-ios-project.zip` | 217 KB | iPhone（Capacitor Xcode 工程） | 无（iOS 走 H5 / 自行构建 Flutter iOS） |

Electron 版的差别：它内置被控端 Agent，Flutter 客户端不带（被控端请用 §9.1 包里的 `uu-agent`）；
媒体通路两者都走 WebRTC，见 §9.4 第 5 条。
v0.1.0 的 macOS/Linux Flutter 包是坏的（macOS 变成 23 KB 的 `uu_remote`、Linux 整个丢失），
根因见 §10。

### 9.4 已知限制（下载前先看）

1. **macOS 产物是 ad-hoc 签名，不是 Developer ID**：CI 里先签 `Contents/Resources/agent/uu-agent`
   再用 `codesign --force --deep --sign -` 签整个 `.app`。不签名时 `Release.entitlements` 的
   `app-sandbox=true` 会让沙箱初始化直接 SIGTRAP 崩溃，所以这一步是必需的。
   用户须知：
   - 首次运行仍会被 Gatekeeper 拦（从未公证），执行
     `xattr -dr com.apple.quarantine /Applications/uu_remote.app`，或右键 →「打开」放行。
   - ad-hoc 签名**不能分发给他人的 Mac**（对方 Gatekeeper 会拦，且系统不认为是同一开发者）；
     正式对外分发需 Developer ID 证书 + `notarytool` 公证。自用可跑。
2. **Windows 产物未签名**：`uu_remote.exe` 首次运行会被 SmartScreen 拦，点「更多信息 →
   仍要运行」；正式分发需代码签名证书（EV/OV）。Windows 包是免安装的目录形态，
   整个 zip 解压后直接跑，**没有安装程序**。
3. **安卓 APK 是 debug key 签名**（Flutter 版 51 MB）：
   能装能跑，**不能上架应用商店**；上架需补 `key.properties` + `signingConfigs`。
4. **iOS 没有发布产物，CI 也不产 ipa**：`flutter build ios --no-codesign` 得到的是未签名
   `.app`，装不到设备上，因此不做这个 job。需要 iOS 客户端请自行用 Xcode 打开
   `client-flutter/ios` 构建并签名（需 Apple 开发者账号；免费账号 7 天过期）。
   临时可用 iPhone Safari 开 H5 控制页。这与 Capacitor 时代只发 Xcode 工程等价，不是能力倒退。
5. **Flutter 版已接入 WebRTC**：H.264 + 优先保分辨率（flutter_webrtc 插件，commit `c639657`），
   macOS / Linux / Android / Windows 构建均通过；**真机联调数据在 v0.1.2 发布后补充**。
   若 WebRTC 建连失败会自动回落 JPEG，界面上会提示。
6. **Linux Flutter 包绑定 runner 的 glibc**（ubuntu-latest，2.39+），老发行版跑不起来。
7. 服务端二进制需自备 TLS 证书（见 §9.1 末尾）。
8. **已知问题：随包 uu-agent 让桌面包体变大**。`uu-agent` 用 PyInstaller `--onefile`，
   单文件 50–102 MB，导致桌面包从 18–21 MB 涨到 **82–121 MB**；且 onefile 每次启动都要
   解压到临时目录，**冷启 4–6 s**。对照：Electron 时代 dmg 144 MB / 解包 274 MB，
   现在 82 MB zip / 121 MB 解包，仍小 2.2 倍，换来「装上即可被控、免装 Python」。
   **下一版计划（v0.1.3，两项体积优化一起做，现在不动 CI）**：
   a) agent 改 `--onedir`（dylib 共享、zip 压缩率更高，预计 45–55 MB），
      同时冷启从 4–6 s 降到 <1 s（不用解压）；
   b) Android apk 做 ABI 拆分：`flutter build apk --release --split-per-abi`
      （或单发 `--target-platform android-arm64`），把当前 **88 MB** 的全 ABI 包压到
      约 **45 MB**。现状是 flutter_webrtc 把各 ABI 的 `libwebrtc.so` 全打进去了；
      拆分后需在 §9.2 的资产表里写清「arm64-v8a / armeabi-v7a 分别下载哪个」，
      并提醒用户按手机架构选包（选错会装不上）；
   c) 若仍嫌大，再评估「首次运行按需下载 agent」。

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