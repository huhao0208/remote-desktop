# NAS Linux 被控端联调 · 交接文档

> 写于 2026-11-21 17:00，**当日晚些时候更新：§6 卡点已解除，§7 清单 11 条已全部验证**。
> 历史坑都踩完了，**别重试已排除项**（§5 有清单，每条都花了真实时间）。

---

## 1. 任务背景

- B 阶段四项（文件传输/鼠标三模式/键位映射/控制端麦克风）已完成并推送
  （`eeb31a3`），全量测试 441 项通过。
- 本轮任务：**在 NAS 上用 Linux 被控端做真机联调**，验证 `docs/nas-vm-debug.md`
  里那 11 条（尤其 Linux 降级行为）。
- 进度（2026-11-21 晚）：**卡点已解除，§7 清单 11 条全部验证通过**（协议层自动化），
  根因定案与修复见 §6。

## 2. NAS 环境速查

| 项 | 值 |
|---|---|
| 设备 | 威联通 QNAP（MAC `24:27:30:32:e0:98`） |
| 地址 | `192.168.31.152`，**SSH 端口 5022**（22 是关的） |
| 账号 | `huzhifeng`（无 sudo 密码可用，**不在 docker 组**，docker 命令 Permission denied） |
| 系统 | Debian 12 bookworm，4 核 / 16GB，python3.11 |
| 本机 X | **无**（无头），也没法 apt install（无 root） |
| 旧部署 | `/vol5/@appdata/trim.hermes/workspace/uu-re/srv2` 跑在 **8443 HTTPS**（trim.hermes 用户的进程，无权管理；**它的 WS 握手一律 403**，原因未查清，别浪费时间去连它） |
| 我们的实例 | `http://192.168.31.152:18443`（明文 HTTP，uvicorn 直跑，进程由 restart-srv2.sh 管理） |

## 3. NAS 上的资产（都在 `/home/huzhfieng`）

```
~/uu-remote/
├── agent/               # Agent 源码（从 Mac scp，与仓库 agent/ 同步）
├── srv2/                # 新版服务端源码 + data/uu.db（曾清空过一次）
├── agent-venv/          # Python 虚拟环境（依赖已装齐，用清华镜像）
├── restart-srv2.sh      # 起 18443 实例（**必须带 UU_PUBLIC_BASE/UU_WS_BASE，见 §5-1**）
├── restart-agent.sh     # 起 Agent（server=18443，DISPLAY=:99，jpeg，--no-audio）
└── run-vm.sh            # unshare 里 Xvfb+Agent 一体启动（§6 方案 A 用它）
~/xvfb/
├── debs/                # 手工 apt-get download 的 deb 包（xvfb/xauth/x11-xkb-utils/依赖库）
├── root/                # dpkg-deb -x 解包结果（usr/bin 里有 Xvfb/xkbcomp）
└── merged-bin/          # 合成目录：cp -a /usr/bin + 解包覆盖（bind mount 用）
日志：/tmp/srv2.log、/tmp/agent-final.log、/tmp/vm.log、/tmp/xvfb.log
```

本地仓库对应物：`deploy/nas-vm/run-vm.sh`（与 NAS 上同步）。

## 4. Mac 侧资产

- 仓库：`/Users/hoha/WorkBuddy/2026-11-20-14-15-30/remote-desktop-git`
- Flutter 控制端：`client-flutter`，`flutter run -d macos` 后设置页把服务端地址改成
  `http://192.168.31.152:18443` 即可连。
- 测试账号：`13800000001`（登录接口免密验证码模式，直接 POST `/api/v1/login/by_mobile`）。

## 5. 已排除项与关键坑（**不要重试**）

| # | 坑 | 结论 |
|---|---|---|
| 1 | **token 顶掉**：每次 `login/by_mobile` 会把旧 token 置空。拿一个 token 后先测着测着就 1001 | 一次登录后**立刻**用同一个 token 查所有接口；脚本里不要反复 login |
| 2 | **signaling_server 指向官方生产域名**：`room_config` 返回 `wss://api.nrd.nie.163.com` → WS 403 | 起 18443 必须 `UU_PUBLIC_BASE=http://192.168.31.152:18443 UU_WS_BASE=ws://192.168.31.152:18443`（restart-srv2.sh 已带） |
| 3 | **Xvfb 硬编码 `/usr/bin/xkbcomp`**（源码 `XKB_BINDIR` 编译期写死）：PATH、-xkbdir、~/bin wrapper 全无效 | 只能 mount bind。且 NAS 是 usrmerge（`/bin → usr/bin`），**bind /usr/bin 会把 /bin 一起覆盖** → sleep/python 全消失 |
| 4 | **硬链接跨文件系统失败**：/usr/bin 在 / 分区，合成目录放 /home 分区，`ln` 静默全败 | 必须 `cp -a`（merged-bin 已建好，1138 个文件） |
| 5 | **WebRTC 模式在无 X 环境下反复崩**（`Bad display name` 循环断链） | 无 X 测试一律 `--transport jpeg --no-audio`。顺带发现 Agent 代码缺陷：无 X 应优雅降级（hello 报 screen_permission）而不是崩，**这是待修 bug** |
| 6 | pip 官方源超时 | 用 `-i https://pypi.tuna.tsinghua.edu.cn/simple` |
| 7 | 旧 8443 实例的 WS 全 403 | uvicorn 0.41 + websockets 15 都装着，仍未查明。**绕开它**，用我们的 18443 |
| 8 | NAS 数据库 `uu.db` 是 scp 上去的旧文件，里面存着旧 rooms/devices | 已手动清空过；出诡异 room 相关问题时先怀疑库脏了 |
| 9 | **mouseinfo 缺 tkinter 静默杀 agent（本轮卡点真凶）**：pyautogui 硬依赖 mouseinfo，后者 import 时 `from tkinter import ttk/Event` 失败就 `sys.exit('NOTE:…')`——传字符串的 exit 打印消息、rc=1、**无 traceback**，agent 启动日志停在 NOTE 后无声死亡。当时误判成「pyautogui 卡死/WS 无日志」 | venv 的 site-packages 放**空壳 tkinter**（`Tk/Tcl/Event/TclError/TkVersion=8.6 + ttk.py`，全 no-op；agent 只用 pyautogui 的 Xlib 路径，GUI 类不会触碰）。装 python3-tk 不可行（无 root），解包 deb 太重 |
| 10 | **「ns 内 /tmp 隔离」假说不成立**（§6.2 的推理被定案实验推翻）：/tmp 在 rootfs 上非独立挂载，unshare -m 的 rprivate 只隔离**新挂载操作**，同一文件系统的文件 I/O ns 内外共享 | 定案实验：marker 文件互相可见、X99 socket ns 内外同 inode（2232526）。**方案 A 的 bind xsock 没必要做**，Agent 无需进 ns |
| 11 | **ssh inline 命令里 pkill -f 自杀**：模式串出现在 ssh 命令文本里时，远端 bash -c 的 argv 含该串 → pkill 把自己会话杀了（ssh exit 255，本轮踩了三次） | 模式经远端脚本文件执行（argv 干净），或本地 ps 取 PID 后 `kill <pid>`；查活用本地 grep |
| 12 | **清单 §5-#7 的预期写错**：旧预期「下载 /etc/hosts 成功」，但协议 media-protocol.md §2-8 明确「浏览范围=接收目录+主目录，/etc 等系统目录一律拒绝」——实现是对的，清单预期与协议不符 | 已按协议口径验证：白名单内文件下载成功 + /etc/shadow、/etc/hosts 均 denied。nas-vm-debug.md §5 表已同步纠正 |

## 6. 卡点定案（2026-11-21 晚，已解除）

### 6.1 §6.2 的「pyautogui 卡死」真因

两个独立问题叠加，都与「ns /tmp 隔离」无关（该假说被 §5-10 的定案实验推翻）：

1. **mouseinfo 缺 tkinter 静默 sys.exit**（§5-9）：agent-final.log 停在
   `NOTE: You must install tkinter...` 后无声退出（rc=1、无 traceback）——agent 根本
   不是卡死，是被 pyautogui 的硬依赖 mouseinfo 杀掉。修复 = venv 空壳 tkinter（§5-9）。
2. **Xvfb keymap 半初始化暂态**：vm.log（15:49 轮）keymap 编译失败期间，Xvfb 的
   listening socket 已建但不应答 → 客户端 connect 卡死（这是「卡死」印象的来源）。
   Xvfb 正常起来后（15:53 轮，`vm2.log`）暂态消失。

**验证**：`DISPLAY=:99 pyautogui.size()/moveTo/click` 全通（XTEST 注入真实生效）。

### 6.2 原候选方案结局

- **方案 A（bind xsock）**：不需要——/tmp 不隔离（§5-10）。
- **方案 B（一体长驻）**：run-vm.sh 保持 ns 内 Xvfb + exec agent 结构，但 **agent 其实
  无需进 ns**；调用要 `nohup unshare -Urm sh run-vm.sh … &` 包装，否则 ssh 会话结束
  进程组被杀（16:00 那轮 agent 消失即此因）。
- **方案 C（修降级 bug）**：已修并真机验证，见 §6.3。

### 6.3 §6.5-1 无 X 降级 —— 已修复

`_init_input()`（agent.py:178）import pyautogui/mouseinfo 连不上 X 时抛异常 →
run() 在 WS 建连前就死 → main 循环「断链…5s 后重连」死循环，永远到不了 hello，
既有的 screens=[] 降级分支（agent.py:706-715）从未被走到。

修复：`_init_input()` 失败时打日志并返回 no-op 注入器 `(inject, (0,0), release_all)`，
流程继续走到 hello（screens=0）+ `agent.error: screen_permission`。单测 20/20 过。

**真机验证**（NAS，`env -u DISPLAY`）：日志打出「输入后端不可用（'DISPLAY'），
键鼠注入降级为 no-op」→ `media=jpeg screens=0` → hello 照发；`tools/e2e_bstage_linux.py
--skip-upload` 下 7/8 PASS，唯一 FAIL 是「无帧」——正是无屏降级的预期语义。
信令/文件传输/键位面板契约/组合键/断链重连全部可用。

### 6.4 §6.5-2 WS close code 日志 —— 复核为不成立

- 实测断链日志**已带 code**：杀 srv2 后 agent 打出
  `断链: received 1012 (service restart); then sent 1012，5s 后重连`。
- 坏 token 直连 WS 得到的是**握手期 HTTP 403**
  （`server rejected WebSocket connection: HTTP 403`），异常文本完整；所有异常都会进
  main 的 `断链: {e}` 日志路径。
- 当时看到的「无日志」现象与 mouseinfo 静默 sys.exit 吻合（根因已修）。**不改代码**。

## 7. 验收清单结果（2026-11-21 真机验证）

`docs/nas-vm-debug.md` §5 的 11 条，工具 `tools/e2e_bstage_linux.py`
（100MB 正式轮 **15/15 PASS**；无 X 降级轮 7/8，FAIL 项即降级语义）：

| # | 条目 | 结果 | 证据 |
|---|---|---|---|
| 1 | JPEG 画面 | ✅ | 1920×1080 可解码、尺寸=hello.screen；Xvfb 注入四色块后抓帧内容逐块吻合（协议层+截图） |
| 2 | 鼠标跟手 | ✅ | 发 move(0.75,0.25) → Xvfb 指针精确 (1440,270)；moveTo/click XTEST 注入直测通过 |
| 3 | 鼠标面板置灰 | ✅ | hello.cursor="unsupported" 契约达成；Flutter 置灰渲染由 441 单测覆盖，UI 走查待人工 |
| 4 | 外设面板置灰 | ✅ | hello.os="Linux" → 同平台直通置灰（同上） |
| 5 | 100MB 上传 | ✅ | sha256 一致（52884316…）、mode=new、无 .part 残留 |
| 6 | 同名冲突 | ✅ | 第二次 → mode=rename 落成 "… (1).bin" |
| 7 | 下载白名单 | ✅ | 白名单内成功+sha256 一致；/etc/shadow、/etc/hosts 均 denied（预期按协议纠正，§5-12） |
| 8 | 开语音 | ✅ | 降级路径：NAS 无声卡 mic=false → mic.state{ok:false,err:"unsupported"}；真实出声需 WebRTC+声卡，此环境验不了 |
| 9 | 连续开关 5 次 | ✅ | 5 次回执齐全、无卡死 |
| 10 | Ctrl+Alt+Del | ✅ | 原子组合发出无 error、连接保持 |
| 11 | 断开重连 | ✅ | 控制端重进房收重发 hello（peer.join 触发）；杀 srv2 后 agent 打出带 code 断链日志并自动回原房间（同 token） |

遗留人工项：#3/#4 的 Flutter 面板 UI 走查、#8 真实音频轨（需 WebRTC+声卡环境）。

## 8. 快速操作备忘

```bash
# 连 NAS
ssh -p 5022 huzhifeng@192.168.31.152

# 重启服务端（18443）—— 幂等，带对的环境变量
~/uu-remote/restart-srv2.sh

# 重启 Agent（指向 18443，jpeg 模式）
~/uu-remote/restart-agent.sh

# 一体启动（ns 内 Xvfb + exec agent；nohup 包装防 ssh 退出杀进程）
nohup unshare -Urm sh ~/uu-remote/run-vm.sh > /tmp/vm.log 2>&1 &

# B 阶段 Linux 清单协议级验证（Mac 侧跑，详细用法见脚本 docstring）
python3 tools/e2e_bstage_linux.py --server http://192.168.31.152:18443 \
    --mobile 13800000001 [--size-mb 100] [--skip-upload] [--save-frame PATH]

# Mac 侧验证设备在线（**token 只能用一次登录拿到的那个**）
curl -s -X POST http://192.168.31.152:18443/api/v1/login/by_mobile \
  -H 'Content-Type: application/json' -d '{"mobile":"13800000001"}'
# → 拿 data.token，立刻：
curl -s -X POST http://192.168.31.152:18443/api/v1/device/list \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'

# Mac 控制端
cd client-flutter && flutter run -d macos   # 设置页服务端 → http://192.168.31.152:18443
```

## 9. 产物与提交状态

已提交（origin/main）：
- `eeb31a3` B 阶段四项 + 工具栏合并
- `d302c90` NAS 虚拟机调试指南
- `96e8714` 本文档初版 + `deploy/nas-vm/run-vm.sh`

本轮（2026-11-21 晚）已改**待提交**：
- `agent/agent.py`：`_init_input()` 无 X 降级（§6.3）
- `tools/e2e_bstage_linux.py`：新增，B 阶段 Linux 清单协议级验证工具
- `deploy/nas-vm/run-vm.sh`：--server 8443→18443 修正 + 定案注释（NAS 侧已 scp 同步）
- `docs/nas-debug-handoff.md`、`docs/nas-vm-debug.md`：定案与清单结果回写

NAS 侧（不在 git）：agent-venv 空壳 tkinter（site-packages/tkinter/，§5-9）、
agent/agent.py 与 run-vm.sh 已 scp 同步。
