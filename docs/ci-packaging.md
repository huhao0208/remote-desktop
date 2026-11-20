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

## 7. 遗留风险

- **Windows / Linux 只验证了轮子存在与参数正确，没在真机跑过**。首次 CI 跑绿后建议顺手
  检查日志里 Agent 是否打印 `[rtc] answer 已发`（说明 aiortc 真的起来了）。
- **aiortc 私有字段**（`_H264Encoder__target_bitrate`）在 `webrtc_media.py` 里被直接赋值，
  升级 aiortc 需复核；这属于运行时代码，与打包无关，但升级时要一起看。
- `-onefile` 冷启动 5 s 左右（解压 50 MB）；如需秒开改 `--onedir`，会牵动客户端 `extraResources` 结构。