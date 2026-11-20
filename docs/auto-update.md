# 自动升级

v0.2.0 起，客户端、被控端（`uu-agent`）、服务端都能自己发现并安装新版本。
本文写清**契约、三端行为、平台硬限制和回滚办法**，改这套逻辑前先读一遍。

## 1. 版本号单一真源

```
VERSION                ← 唯一真源，内容就一行 `0.2.0`
scripts/gen_version.py ← 注入三端
  ├─ client-flutter/lib/core/version.g.dart   const kAppVersion
  ├─ agent/_version.py                       VERSION
  ├─ srv2/_version.py                        VERSION
  └─ client-flutter/pubspec.yaml             只改 version: 那一行
```

```bash
python3 scripts/gen_version.py            # 写文件
python3 scripts/gen_version.py --check    # CI 门禁：生成物漂移就失败
```

为什么要这么麻烦：v0.1.3 发布时 `pubspec.yaml` 还停在 `0.1.0+1`，服务端
`FastAPI(version=...)` 是写死的 `1.0.0`，agent 根本没有版本概念——**没法判断用户跑的是哪个版本，
自动升级就无从谈起**。现在三处都由脚本生成，CI 的 `flutter-verify` 会校验一致性。

版本会在这些地方暴露出来：

| 位置 | 形式 |
|---|---|
| 客户端「我的」页 | `检查更新` 右侧的 `v0.2.0 · 已是最新` |
| 被控端 | `uu-agent --version` → `uu-agent 0.2.0`；启动日志第一行也打 |
| 服务端 | `GET /healthz` → `{"ok":true,...,"version":"0.2.0"}` |

## 2. 更新源：直连 GitHub Release

```
GET https://api.github.com/repos/huhao0208/remote-desktop/releases/latest
```

- 仓库是 **public**，匿名可读；限额 **60 次/小时/IP**，命中 `ETag` 的 304 **不计数**。
- 客户端 24h 才真正请求一次（`Updater.checkInterval`），手动点「检查更新」会 `force` 绕过节流。
- 拿到的 `assets[].digest` 就是 `sha256:...`，直接用作完整性校验。
- **403/429 一律当成「检查失败」**，绝不显示「已是最新」——不能让限流伪装成安全。
- 国内网络访问 api.github.com 可能不稳，失败时 UI 明确说「检查失败」并给出 Release 链接。

被控端和服务端用同一个 `releases/latest`，只是各自挑不同的资产。
`UU_RELEASE_REPO` 环境变量（agent/服务端）/ `--dart-define=UU_RELEASE_REPO=owner/repo`（客户端）
可以把整套指到你自己的 fork。

## 3. 资产契约

客户端与 agent 靠**文件名**选包，改 CI 产物名必须同步改
`client-flutter/lib/core/updater.dart` 的 `clientAssetName()` 与 `agent/updater.py` 的 `asset_name()`。

| 资产 | 谁用 | 形态 |
|---|---|---|
| `uu-remote-client-flutter-macos.zip` | macOS arm64 客户端 | zip 内含 `uu_remote.app` |
| `uu-remote-client-flutter-windows.zip` | Windows x64 客户端 | zip 根是 `runner/Release/*`（`uu_remote.exe` 在根） |
| `uu-remote-client-flutter-linux.tar.gz` | Linux x64 客户端 | tar 根是 `bundle/` 内容（`uu_remote` 在根） |
| `uu-remote-client-flutter-android-arm64-v8a.apk` | Android arm64 | APK |
| `uu-remote-client-flutter-android-armeabi-v7a.apk` | Android armv7 | APK |
| `uu-agent-macos-arm64.tar.gz` | **被控端自更新** | tar 根是 onedir 内容（`uu-agent` + `_internal/`） |
| `uu-agent-windows-x64.zip` | 同上 | zip 根是 `uu-agent.exe` + `_internal/` |
| `uu-agent-linux-x64.tar.gz` | 同上 | 同上 |
| `SHA256SUMS` | 兜底校验 | `sha256sum` 格式，一行为一个资产 |

**为什么单独出 agent-only 包**：服务端包（`uu-remote-*.tar.gz`）含服务端 + agent，100+ MB；
agent 只想升级自己那 47 MB。`--onedir` 产物直接打平到归档根，解压即覆盖安装目录。

平台没有对应资产时（Intel Mac、Linux arm64、Android x86_64），客户端显示
「当前平台没有官方安装包」并给出 Release 链接，不会瞎装一个架构不对的包。

## 4. 各端行为

### 4.1 客户端（Flutter，win/mac/linux/android）

| 阶段 | 行为 |
|---|---|
| 启动 | 延迟 3s 静默检查，24h 节流；**只查不下载** |
| 提示 | 「我的」页多一行 `检查更新`，有新版本时红色圆点 + `v0.2.1 可升级`；底部「我的」Tab 挂红点 |
| 用户点升级 | 下载到 `~/.uu-remote/updates/<version>/`（Win: `%LOCALAPPDATA%`，Android: cache），边下边算 sha256 |
| 校验 | `asset.digest` 缺失时回退 `SHA256SUMS`；两者都没有 → **拒绝安装**，只给下载链接 |
| 安装 | 见下表（每平台一套替换器） |
| 跳过 | 「跳过此版本」记进 `Settings.updateSkipVersion`，之后只提示不弹窗 |

替换器（`lib/core/update_installer.dart`）：

| 平台 | 做法 | 关键点 |
|---|---|---|
| macOS | `ditto -x -k` 解压 → 校验 `CFBundleShortVersionString` 与目标版本一致 → `codesign --verify --deep --strict` → 旧 `.app` 改名 `.app.bak` → 新版就位 → `open -n` | 旧包留在 `.app.bak`，失败自动回滚；自己下载的文件不带 quarantine，不需要 `xattr` 清理（仍兜了一遍） |
| Windows | 写 `uu-update-*.ps1` 并 detached 启动：`Wait-Process` 等主进程退出 → 运行中的 exe 改名 `.old` → `robocopy /E /IS` → `Start-Process` 拉起 → 自删脚本 | 运行中的 exe **不能覆盖但能改名**，这是 Windows 上的标准绕法 |
| Linux | tar 解到 staging → `/bin/sh` helper 等 PID 退出 → `cp -a` 覆盖 bundle → 重新 `exec` | 需要 bundle 目录写权限（用户级安装没问题） |
| Android | APK 落到 cache 目录 → `FileProvider.getUriForFile` → `Intent.ACTION_VIEW` 交给系统安装器 | **必须同签名**，见 §5.2；用户还要允许「安装未知应用」 |

升级前会先 `AgentHost.stop()` 停掉随包 agent：不然旧 agent 留在被换走的 `.app` 里继续跑，
新实例又拉起一个，同一 device 两条连接。

### 4.2 被控端（`agent/updater.py`）

- 启动 60s 后检查一次，之后每 24h；状态落在 `~/.uu-agent/update_state.json`。
- 只在 **PyInstaller 打包产物** 里生效（`sys.frozen`）；源码运行直接跳过——否则
  `sys.executable` 是 python，替换它等于毁掉用户环境。
- **运行在 `.app/Contents/` 里时跳过自更新**：替换会破坏 ad-hoc 签名，并让「屏幕录制」
  TCC 授权（绑定 cdhash）失效。这种情况只打日志。
- **正在使用时不动手**：`agent.py` 的 `mark_activity()` 记录最近一次收发，
  两分钟内有流量就算 busy，推迟到下一轮。
- POSIX：覆盖文件后 `os.execv` 重启自身（旧 inode 对运行中的进程仍有效）。
- Windows：交给 `uu-agent-update.ps1`，等进程退出 → exe 改名 → `robocopy` → 重启。
- `--no-update` 可整体关闭。

### 4.3 服务端

```bash
cd deploy/nas
./upgrade.sh            # 只检查（默认，安全）
./upgrade.sh --yes      # 真的升：git checkout 最新 tag → docker compose up -d --build
./upgrade.sh --rollback # 回滚到上次升级前记录的 tag
```

因为 `deploy/nas/docker-compose.yml` 用的是 `build: ../../srv2`（本项目不发布预构建镜像），
**升级 = 换源码 + 重建**，不是 `docker compose pull`。脚本会拒绝在脏工作区上升级。

想全自动：`0 4 * * * cd /path/to/repo/deploy/nas && ./upgrade.sh --yes >> upgrade.log 2>&1`。
或者把镜像推到自己的 registry，改用 `image:` + watchtower（compose 里有注释模板）。

## 5. 两个绕不过去的平台限制

### 5.1 macOS：ad-hoc 签名 → TCC 授权会重置

客户端和 agent 都是 ad-hoc 签名（没有 Developer ID）。macOS 的「屏幕录制 / 辅助功能」
授权绑定 **cdhash**，每次替换包 cdhash 都变 → 系统认为这是"另一个程序"，**授权需要重新给一次**。

这是签名身份不稳定的必然结果，代码层面无解。缓解手段：

1. 客户端升级后如果 agent 报「没有屏幕录制权限」，引导用户去
   `系统设置 → 隐私与安全性 → 屏幕录制` 重新勾选（`agent` 已有 `CGPreflightScreenCaptureAccess` 检测）。
2. agent 不随客户端一起升级（它有自己的 24h 节奏，且 `.app` 内不自动更新），把重授权次数降到最低。
3. 真要彻底解决：买 Apple Developer ID（$99/年）用固定证书签名，cdhash 之外的 designated
   requirement 保持稳定，TCC 才认「同一个应用」。

### 5.2 Android：签名不一致就装不上

覆盖安装要求新旧 APK **签名一致**。以前 CI 固定用 debug key：

- debug keystore 由构建机生成，换台 runner 签名就变 → 用户点升级只会得到「应用未安装」。
- 所以 v0.2.0 起 `android/app/build.gradle.kts` 支持读 `android/key.properties` +
  固定 keystore；**没配就回退 debug 签名**（行为与以前一致，不阻断构建），CI 会打 warning。

启用方法（一次性）：生成 keystore 后把四个值存进仓库 Secrets。

```bash
keytool -genkeypair -v -keystore uu-release.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias uu -storepass <store_pw> -keypass <key_pw> \
  -dname "CN=UU Remote, OU=Dev, O=UU, L=Shenzhen, S=Guangdong, C=CN"
base64 -i uu-release.jks | pbcopy   # → ANDROID_KEYSTORE_B64
```

| Secret | 值 |
|---|---|
| `ANDROID_KEYSTORE_B64` | keystore 的 base64 |
| `ANDROID_KEY_ALIAS` | `uu` |
| `ANDROID_KEY_PASSWORD` | key 密码 |
| `ANDROID_STORE_PASSWORD` | store 密码 |

**注意**：一旦发过正式签名的包，就再也不能用 debug 签名的包覆盖升级（反之亦然）。
切换签名的那一版，必须让用户**卸载重装**一次。

## 6. 发布流程（每版照做）

```bash
# 1. 改版本（唯一真源）
echo "0.2.1" > VERSION
python3 scripts/gen_version.py
git add -A && git commit -m "chore(release): v0.2.1"

# 2. 本地门禁
cd client-flutter && flutter analyze --fatal-infos && flutter test && cd ..
python3 scripts/gen_version.py --check

# 3. 打 tag 触发 CI（会自动注入 build 号、生成 SHA256SUMS、出 14 个资产）
git tag -a v0.2.1 -m "v0.2.1"
git push origin main --tags

# 4. 出包后核对
gh release view v0.2.1 --json assets -q '.assets[].name'
```

CI 侧动作（`.github/workflows/build.yml`）：

- 各构建 job 先跑 `scripts/gen_version.py --build ${{ github.run_number }}`；
- `binary` job 多出 `uu-agent-<platform>.{zip,tar.gz}` 三个自更新专用包；
- `release` job 生成并上传 `SHA256SUMS`；
- `flutter-verify` 里跑 `--check`，版本漂移直接失败。

## 7. 回滚

| 组件 | 回滚办法 |
|---|---|
| 客户端 macOS | 退出后把 `uu_remote.app.bak` 改名回 `uu_remote.app` |
| 客户端 Windows | 把同目录 `uu_remote.exe.old` 改名回 `uu_remote.exe` |
| 客户端 Linux | 重下旧版 tar 覆盖 bundle（脚本不保留备份） |
| 客户端 Android | 装回旧 APK（同签名才能覆盖；跨签名需卸载） |
| 被控端 | POSIX 留下 `uu-agent.bak`；Windows 是 `uu-agent.exe.old` |
| 服务端 | `./upgrade.sh --rollback` |

## 8. 未验证项（诚实记录）

v0.2.0 的自动升级在本机只验证到「查得到、解析对、校验对」这一层：

- ✅ 真实 GitHub 响应解析（v0.1.3 的 10 个资产全部匹配上，sha256 与 API digest 一致）
- ✅ 版本比较 / 平台资产选择 / 13 个单测（`test/updater_test.dart`）
- ✅ 服务端 `upgrade.sh` 的 `--check` 实跑（正确识别「已是最新」）
- ❌ **端到端替换没跑过**：需要一个"假装有新版本"的 Release 才能触发下载，
  且 macOS 替换 `.app`、Windows `robocopy` 延迟替换、Android 安装器都需要真机点一次
- ❌ Android release 签名未启用（没有 keystore），所以应用内升级目前**注定失败**，
  这一版安卓用户请手动下载覆盖（若签名未变可装，变了得卸载）
- ❌ macOS 升级后「屏幕录制」重授权流程没实测

下一版（v0.2.1）计划：先发一个 patch 版本专门用来验证端到端链路，把上面三个 ❌ 补上。
