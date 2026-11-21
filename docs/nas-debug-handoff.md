# NAS Linux 被控端联调 · 交接文档

> 写于 2026-11-21 17:00。接手人从 §6「当前卡点」开始看，前面的坑都踩完了，
> **别重试已排除项**（§5 有清单，每条都花了真实时间）。

---

## 1. 任务背景

- B 阶段四项（文件传输/鼠标三模式/键位映射/控制端麦克风）已完成并推送
  （`eeb31a3`），全量测试 441 项通过。
- 本轮任务：**在 NAS 上用 Linux 被控端做真机联调**，验证 `docs/nas-vm-debug.md`
  里那 11 条（尤其 Linux 降级行为）。
- 进度：**Agent 已在 NAS 上跑通注册/建房，卡在 X 显示与进程持久化**，详见 §6。

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

## 6. 当前卡点（接手人从这里开始）

### 6.1 已经打通的部分

`unshare -Urm sh ~/uu-remote/run-vm.sh` 一体启动**成功过一轮**（`/tmp/vm2.log` 有证据）：
Agent 起来、注册成设备 `NAS-VM`、建了房间、无断链日志。Xvfb + 合成 bind + umount 恢复
这条链路是通的。

### 6.2 卡点：`pyautogui.size()` 卡死 → Agent 永远走不到 WS 建连

**证据链**（当前状态）：
- Agent 进程活着，但 `ss -tn` 对 18443 **零连接**，日志停在 init 阶段、无任何断链输出；
- 手工 `DISPLAY=:99 python -c "import pyautogui; pyautogui.size()"` **卡死**（10s timeout 杀掉）；
- Xlib 直连 `display.Display(":99")` 却**成功**（`screens: 1`）；
- Xvfb 进程活着，`/tmp/.X11-unix/X99` socket 文件存在（时间戳 15:53，是**旧一轮**留下的）。

**根因（高置信推理，未验证完）**：`unshare -Urm` 的 namespace 里 **/tmp 是独立的**。
ns 内 Xvfb 建的 X99 socket 在 **ns 内的 /tmp**；ns 外跑的 Agent 连的是 ns 外残留的旧
socket 文件——后面没人监听 → pyautogui 首次调用卡死。Xlib 能「连上」是因为 Xlib 对
本地 socket 连接失败时回落 TCP 抽象？不对——Xlib 显示成功说明它连到了某个东西；
更可能的解释是 Xlib 建连成功但后续也异常。**不管哪种，先做 §6.3 的实验定案**。

### 6.3 定案实验（10 分钟内能做完）

```bash
# 1) 进 ns，看 ns 内 /tmp/.X11-unix 与 ns 外是否同一个
unshare -Urm sh -c 'ls -la /tmp/.X11-unix/; sleep 60' &
# 另开 ssh：ls -la /tmp/.X11-unix/（对比 inode）
# 2) 若确认隔离 → 用 bind 把 X socket 目录挂到 ns 外可见的路径
```

### 6.4 候选方案（按推荐顺序）

**方案 A（首选，改一行）**：在 `run-vm.sh` 里，ns 内把共享目录 bind 到 /tmp/.X11-unix：

```sh
mkdir -p /home/huzhfieng/xvfb/xsock
mount --bind /home/huzhfieng/xvfb/xsock /tmp/.X11-unix
# 之后再起 Xvfb → socket 落在共享路径，ns 外的 Agent 直连
```

ns 外 `DISPLAY=:99` + restart-agent.sh 即可。**不用改 Agent 代码。**

**方案 B**：整个 Xvfb+Agent 都留在同一个 unshare 长驻会话里（现在 run-vm.sh 就是这么
写的）。上一轮成功过的链路，唯一问题是 ssh 会话结束后进程被杀。QNAP 实测 **nohup 的
后台进程能活**（srv2 活过多个会话），所以 setsid+nohup 包一层 unshare 大概率也行，
但当时时序混乱没验证干净。接手后优先验证 A，A 不通再回来测 B。

**方案 C（兜底，改 Agent 代码）**：修 §5-5 的降级 bug——无 X 时 `_init_input()`
失败不崩，hello 报 `screen_permission`、画面无但**信令/文件传输/协议链路可用**。
这个 bug 本来就该修（真机上「没接显示器的主机」也会撞到），修完至少能把
nas-vm-debug.md 清单里的 4/5/6/7/10/11 六条先验掉（文件传输、键位面板、白名单、
CAD 降级、断链重连）。

### 6.5 顺带要修的 Agent 代码缺陷（真实 bug，和 NAS 无关）

1. **无 X 不降级**：`Bad display name ""` 循环断链（`--transport both` 时）。应：
   采集/输入初始化失败 → `screens=[]` + hello 照发 + `agent.error: screen_permission`。
2. **WS 断链日志缺口**：WS 被服务端 close(4002) 时 Agent 无任何日志（排查时被坑）。
   建议在 websockets 异常处把 close code 打出来。

## 7. 验收清单（通过后回写 `docs/远控复刻基线.md` 与 `docs/nas-vm-debug.md`）

`docs/nas-vm-debug.md` §5 的 11 条。当前进度：**0/11 完成**（Agent 注册链路已通，
但屏幕采集未验证）。

## 8. 快速操作备忘

```bash
# 连 NAS
ssh -p 5022 huzhifeng@192.168.31.152

# 重启服务端（18443）—— 幂等，带对的环境变量
~/uu-remote/restart-srv2.sh

# 重启 Agent（指向 18443，jpeg 模式）
~/uu-remote/restart-agent.sh

# 一体启动（ns 内 Xvfb+Agent）
unshare -Urm sh ~/uu-remote/run-vm.sh

# Mac 侧验证设备在线（**token 只能用一次登录拿到的那个**）
curl -s -X POST http://192.168.31.152:18443/api/v1/login/by_mobile \
  -H 'Content-Type: application/json' -d '{"mobile":"13800000001"}'
# → 拿 data.token，立刻：
curl -s -X POST http://192.168.31.152:18443/api/v1/device/list \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'

# Mac 控制端
cd client-flutter && flutter run -d macos   # 设置页服务端 → http://192.168.31.152:18443
```

## 9. 已提交的产物

- `eeb31a3` B 阶段四项 + 工具栏合并（已推 origin/main）
- `d302c90` NAS 虚拟机调试指南
- 本文档 + `deploy/nas-vm/run-vm.sh` 待提交
