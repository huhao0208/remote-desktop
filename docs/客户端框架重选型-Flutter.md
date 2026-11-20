# 客户端框架重选型（推翻前一版结论）

> 触发：项目 owner 否决 Electron + Capacitor 方案，判定「太臃肿、性能差」
> 前一版文档的结论作废，本文档为新结论
> 数据来源：2026 年多来源交叉验证（见文末）

> ⚠️ **2026-11-20 补充（先读）**：本文 §5「解码/渲染路径」与 §6「迁移阶段」写的是**当时**的计划（桌面 `media_kit`、移动端自写原生解码插件）。
> 后续 **ADR-8**（见 `HANDOFF.md`）决定媒体传输改 **WebRTC**，因此：
> - 解码/渲染统一走 **`flutter_webrtc` 的 `RTCVideoRenderer` → `Texture`**（桌面/移动同一套）
> - **不需要**自写 Android `MediaCodec` / iOS `VTDecompressionSession` 插件（省 2–3 周）
> - `media_kit` 方案未采用
>
> 本文的**选型结论（换 Flutter）与硬指标对比仍然有效**，只有上述实现路径被替代。媒体契约见 `media-protocol.md`。

---

## 0. 为什么推翻前一版

前一版的核心论据是「端到端延迟的 95% 来自传输与编解码，UI 框架只占 2–5ms，所以换框架收益低」。

**这个论证本身没错，但它回答错了问题。**

owner 关心的是**产品形态**，不只是延迟：
- 装完 300MB+ 的客户端，对一个远控工具来说不可接受
- 常驻 300–400MB 内存，笔记本用户会直接卸载
- 冷启动 1–3s，点开要等，体验差

这些都是**框架的固有属性**，不是优化能解决的。所以：**框架要换。**

---

## 1. 硬指标对比（2026 实测数据）

多个独立来源数据高度一致，取区间：

| 框架 | 安装包 | 空闲内存 | 冷启动 | 五端覆盖 | 渲染引擎 |
|---|---|---|---|---|---|
| **Electron** | 120 MB（dmg）/ **274 MB**（`.app` 解压） | 90–450 MB | 1–3 s | 桌面 3 端 | 完整 Chromium |
| **Flutter** | 18–60 MB | 45–90 MB（复杂 170MB） | 0.5–1 s | **5 端全官方** | 自绘 Skia/Impeller |
| **Tauri 2** | 3–30 MB | 25–60 MB | 0.3–0.8 s | 5 端（移动较新） | 系统 WebView |
| **Qt 6** | 20–80 MB | 35–100 MB | 0.2–0.8 s | 5 端 | 原生 Raster |
| 原生五套 | 最小 | 最小 | 最快 | 5 端 | 系统原生 |

**绝对差距**：
- Electron 解压后（274 MB）≈ Flutter 的 **5–15 倍**、Tauri 的 **9–90 倍**
- Electron 常驻内存 ≈ Flutter 的 **3–4 倍**
- Electron 冷启动 ≈ Flutter 的 **2–3 倍**

---

## 2. 四个候选的真实代价

### A. Flutter（推荐）

**优势**
1. **五端一套代码**：Win / macOS / Linux / Android / iOS 全部官方支持，同一套 Dart UI
2. **体积与内存可接受**：桌面 18–60MB（Hello 25–30MB），移动 Android ~20MB
3. **自绘引擎**：Impeller（iOS/Android）/ Skia，渲染路径自己掌控，不受宿主 WebView 版本影响
4. **视频零拷贝有成熟路径**：`Texture` widget + 原生解码
   ```
   码流 → 原生解码（MediaCodec / VTDecompressionSession）
        → GPU 纹理 → 仅把 textureId 传给 Flutter
        → Texture(textureId: id) 直接合成上屏
   ```
   像素数据**全程留在原生/GPU 侧**，不经过 Dart 层，无逐帧拷贝。
   `flutter_webrtc` 就是这么做的，是生产级方案。
5. **120fps 渲染能力**：Impeller 对高刷友好（远控要 60/90/144fps）

**代价**
1. **UI 要从 HTML 重写为 Dart**（登录/设备列表/工具栏/画面页，估计 3–5 天）
2. **要写原生解码插件**（Android Kotlin + iOS Swift），2–3 周
3. Dart 学习成本（前端背景上手快，语法接近 TS）
4. 桌面生态不如 Electron 成熟（窗口管理、自动更新要自己多写些代码）

### B. Tauri 2（最轻，但有陷阱）

**优势**：3–30MB、25–60MB 内存、0.3s 冷启动，**最轻**
**代价**：
1. **Linux 用 WebKitGTK** —— WebCodecs 支持不全、GPU 路径弱，五端性能不一致
2. **视频渲染不能走 WebView canvas** —— 仍然要原生 overlay（`NSView`/`HWND`/`Surface`），等于「Tauri 外壳 + 原生视频窗口」，架构比 Flutter 更复杂
3. Rust 学习成本

**结论**：省下的体积，会被「原生 overlay + 五端 WebView 差异」的复杂度吃掉。**不推荐**，除非你只做 Windows+macOS 且愿意自己写 overlay。

### C. Qt 6（性能天花板，但开发慢）

**优势**：35–100MB 内存、0.2–0.8s 启动、原生渲染路径最短、`QVideoSink` 直通
**代价**：
1. LGPL/商业授权（动态链接可规避，但要谨慎）
2. C++/QML 开发效率低于 Dart/TS
3. 移动端体验落后（iOS 尤其）
4. 五端 UI 一致性和响应式布局要手写很多

**结论**：适合有 C++ 团队且追求极致，个人项目不推荐。

### D. 原生五套

性能天花板，但要维护 5 套代码（Swift / Kotlin / C# 或 C++ / Objective-C++…）。个人项目**不可行**。

---

## 3. 推荐方案：Flutter + 原生解码 Texture

### 3.1 架构

```
┌──────────────────────────────────────────────┐
│ Flutter UI（Dart，五端一套）                   │
│  登录 / 设备列表 / 远控页 / 工具栏 / 设置       │
├──────────────────────────────────────────────┤
│ 信令层（Dart，dart:io WebSocket）              │
│  input / stream.* / shutdown / ping            │
├──────────────────────────────────────────────┤
│ 渲染桥（Texture widget）                       │
│  桌面：Flutter Engine 内置 → 用 textureId 引用  │
│  移动：原生插件（Kotlin / Swift）产出纹理        │
├──────────────────────────────────────────────┤
│ 原生解码（插件，仅移动端需要写）                 │
│  Android: MediaCodec → SurfaceTexture          │
│  iOS:     VTDecompressionSession → CVMetalTex  │
└──────────────────────────────────────────────┘
```

### 3.2 为什么桌面端可以更快落地

Flutter 桌面端可以直接用 **FFI + ffmpeg** 或已有的 `media_kit`：
- `media_kit` 基于 libmpv，支持硬解、低延迟模式（`untimed` + 关闭缓冲）
- 或自己用 `dart:ffi` 调 `ffmpeg` 的 `avcodec`，输出到 `Texture`

**建议**：桌面先用 `media_kit` 打通（1–2 天），移动端再写原生插件。

### 3.3 五端验收目标

| 指标 | 桌面 | 移动 |
|---|---|---|
| 安装包 | < 60MB | < 25MB |
| 空闲内存 | < 100MB | < 120MB |
| 冷启动 | < 1s | < 1.5s |
| 1080p@60 延迟 | < 30ms | < 50ms |
| 解码 CPU | < 25% | < 30% |

---

## 4. 迁移路径

### 阶段 1（3–5 天）：UI 重写 + 信令打通
```
1. flutter create --platforms=windows,macos,linux,android,ios
2. 把 www/index.html 的页面结构翻译成 Flutter widget
   - 登录页 → TextField + Button
   - 设备列表 → ListView.builder
   - 远控页 → Stack(Texture, 工具栏 overlay)
3. 信令用 dart:io 的 WebSocket 重写（协议不变，JS 对象 → Dart Map）
4. 先用「JPEG 解码 → Image.memory」跑通链路（性能差但能验证）
   验收：五端能登录、能看画面、能发输入
```

### 阶段 2（1 周）：桌面低延迟渲染
```
1. 接入 media_kit 或自行 FFI + ffmpeg
2. 开硬解（VideoToolbox / D3D11VA / VAAPI）
3. 低延迟模式：关闭解码缓冲、不做时间戳同步、丢帧优先
4. 验收：1080p60 < 30ms，CPU < 25%
```

### 阶段 3（2–3 周）：移动端原生解码插件
```
1. Android: MediaCodec.configure(format, surface) → SurfaceTexture → TextureRegistry
2. iOS: VTDecompressionSession → CVMetalTextureCache → FlutterTexture
3. 通过 MethodChannel 把 textureId 回传 Dart
4. 验收：1080p30 < 50ms，iOS 15+ 可用
```

### 阶段 4：UI 对齐官方设计
参考 `docs/reverse/UU远程-远程功能与UI设计还原.md` 的工具栏结构与设计 token。

---

## 5. 对现有代码的处置

| 现有资产 | 处置 |
|---|---|
| `srv2/server.py` + `control.html` | **完全保留**（服务端与框架无关） |
| `agent/agent.py` | **只改媒体出口**（ADR-8：加 aiortc / `ScreenTrack`，JPEG 保留兜底），输入/房间/关机逻辑保留 |
| `client-desktop/`（Electron） | **保留一版作为参照**，迁移完成后归档 |
| `client-desktop/web/index.html` | ⚠️ 是 `scripts/sync-web.js` 生成的产物（已 gitignore），只作 UI 结构参考，翻译成 Dart |
| `client-mobile/`（Capacitor） | 迁移完成后删除 |
| WS 协议 / 房间契约 / 输入事件格式 | **完全复用**，Dart 侧照搬 |

> 好消息：**服务端一行不用改**。换的只是控制端 UI 层；被控端只因 ADR-8 换媒体传输而改媒体出口。

---

## 6. 如果还是嫌 Flutter 大

Flutter 桌面 18–60MB 已经比 Electron 小一个数量级。如果仍不满意：

| 目标 | 方案 | 代价 |
|---|---|---|
| < 10MB | Tauri（仅 Win+macOS）+ 原生视频 overlay | Linux 放弃或单独做；复杂度上升 |
| < 5MB | Rust + Slint/egui | 移动端要原生化，UI 开发效率极低 |
| 极致 | 原生五套 | 维护成本 ×5 |

**我的建议**：先按 Flutter 做，18–60MB 对远控工具是合理区间（对比：向日葵 macOS 客户端约 80MB，ToDesk 约 60MB，Parsec 约 40MB）。如果做完还觉得大，再考虑收窄到 Tauri。

---

## 7. 决策记录

| 项 | 结论 |
|---|---|
| 框架 | **Flutter**（五端一套） |
| 视频渲染 | `Texture` widget + 原生解码直通（移动）/ media_kit（桌面先行） |
| 信令 | Dart `dart:io` WebSocket，协议照搬现有 |
| 服务端 | 不改 |
| 被控端 Agent | 不改 |
| 前版 Electron 结论 | **作废** |

**复核条件**：若 Flutter 桌面端在 1080p60 下 CPU 超过 40%，说明 media_kit 路径不合适，改为自行 FFI 调 ffmpeg 输出到 Texture。

---

## 附：数据来源

| 指标 | 来源 |
|---|---|
| Electron/Flutter/Tauri 包体与内存对比 | kanopylabs.com (2026) |
| 桌面端框架内存/包体/启动排序 | psvmc.cn 桌面端选型 2026-04 |
| Flutter vs Electron 生产案例数据 | chenguangliang.com 2026 |
| 框架抽象层开销审计 | tsight.io 架构选型审计 |
| Flutter Texture 零拷贝视频路径 | Flutter 官方文档 + flutter_webrtc 实现 + 多篇工程实践 |

*数据为 2026 年公开基准，实际值随应用复杂度浮动，迁移前建议做一次 POC 验证。*