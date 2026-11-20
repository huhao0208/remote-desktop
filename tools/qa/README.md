# QA 自动化验收套件（WebRTC 媒体面 + v2 能力）

只依赖 `tools/**`，**不改产品代码**。服务端 / Agent 都以外部进程方式拉起，测完回收。

```
tools/qa/
├── cdp.py             # Chrome DevTools 代理客户端（3456）+ 自建代理/Chrome 兜底
├── env.py             # 服务端/Agent 编排、登录建房、agent.hello 探测、抓屏前置闸门
├── model.py           # Result / Check / PASS-FAIL-SKIP 汇总
├── test_media.py      # 首帧 / 帧率 / 分辨率 / RTT / 丢帧率
├── test_degrade.py    # JPEG 兜底通路（--transport jpeg）
├── test_input.py      # move/click/scroll 连发不报错
├── test_clipboard.py  # v2 剪贴板（未实现则 SKIP）
├── test_multiscreen.py# v2 screens 契约（1 屏则 SKIP）
├── run_all.py         # 入口：串行跑用例 + 人读摘要 + JSON 报告
└── .artifacts/        # 每次运行的日志/截图/report.json（已 gitignore）
```

---

## 1. 环境准备

| 依赖 | 说明 |
|---|---|
| 服务端 | `cd srv2 && ../.venv/bin/python server.py`（默认 8443）。`--auto-env` 会自动拉起，端口已占用则复用 |
| Agent | `cd agent && ../.venv/bin/python agent.py --server http://127.0.0.1:8443 --mobile <手机号> --name QA-PC --transport webrtc` |
| Chrome 代理 | `http://127.0.0.1:3456`，端点 `/targets` `/new?url=` `/navigate` `/eval?target=` `/screenshot?target=` `/close`。**优先复用已有代理**；没有时代码会用本机 Chrome headless 自建（本机 Chrome 157 上不稳定，仅兜底，见「已知不稳定项」） |
| 屏幕录制权限 | **必须**授予运行 Agent 的 python 屏幕录制权限，否则抓屏 30s/帧，媒体用例会以「环境不满足」SKIP。注意 TCC 按**可执行文件**授权：默认是 `.workbuddy/binaries/python/versions/<ver>/bin/python3.13`；换了 Agent 解释器用 `--agent-python` 指定 |

**账号隔离**：默认 `13900000001`。若同账号下已有别人在跑的 Agent（名字不是 `QA-PC`），用例可能点到它；
建议用独立手机号（如 `13900000003`）跑，`--auto-env` 会自己起一个 `QA-PC` 并在结束时回收。

> ⚠️ `/eval` 只接受**单行** JS 且不能返回 Promise。异步逻辑一律「先落全局变量（`window.__qa`），再轮询读取」。
> 标签正在导航时代理会回 400/500，客户端已自动重试 3 次。

---

## 2. 怎么跑

```bash
cd <repo>

# 全量（WebRTC），自动起服务端+Agent
.venv/bin/python tools/qa/run_all.py --transport webrtc

# 兜底通路
.venv/bin/python tools/qa/run_all.py --transport jpeg --mobile 13900000003

# 复用已在跑的服务端/Agent
.venv/bin/python tools/qa/run_all.py --no-auto-env

# 只跑部分用例
.venv/bin/python tools/qa/run_all.py --only media,input

# 机器可读（stdout 纯 JSON）
.venv/bin/python tools/qa/run_all.py --json

# 写文件
.venv/bin/python tools/qa/run_all.py --json /tmp/qa.json
```

- 退出码：`0` = 无 FAIL（SKIP 不算失败）；`1` = 有 FAIL / 环境起不来
- 人读摘要含每个用例的检查项、失败明细、实测数字表
- 每次运行产物：`tools/qa/.artifacts/run-<ts>/`（`server.log`、`agent.log`、`media.png`、`degrade.png`、`report.json`）

旧入口保留：`tools/e2e_webrtc_test.py` 是 `test_media` 的薄封装，退出码 `0/1/2`（PASS/FAIL/SKIP）。

---

## 3. 用例与判定阈值

### test_media（WebRTC）

| 检查 | 阈值 | 口径 |
|---|---|---|
| 媒体来自 WebRTC | `<video>` 可见 + HUD 含 `H.264` | 排除「rtcOn 为真但无帧」 |
| 首帧 | **< 1000 ms** | 点击设备 → `inbound-rtp.framesReceived > 0`（含建房/WS/offer-answer/ICE/解码） |
| 平均帧率 | **≥ 10 fps** | 去掉起播前 1/3 的稳定段，取 `framesPerSecond` 均值 |
| 分辨率 | **= stream.config.width**（默认 1920，±2） | `inbound-rtp.frameWidth`；页面画质档位被固定为 `1920,75,8000` |
| RTT | **< 100 ms** | 选中 candidate-pair 的 `currentRoundTripTime` |
| 丢帧率 | **< 5%** | 增量 `framesDropped / (framesReceived + framesDropped)` |

> 页面自带的 `rtcFirstFrame` 在 `pc.ontrack` 就置位（远端轨建立，不代表已解出画面），
> 因此套件不用它判定首帧，只作为诊断字段 `rtc_ontrack_ms`。

### test_degrade（JPEG 兜底）

`media == "jpeg"` 才执行（否则 SKIP）。判定：canvas 可见且 `<video>` 隐藏、平均 fps ≥ 5、
最近一帧年龄 < 2000ms、页面截图平均亮度 > 2（排除「HUD 在动但画面全黑」）。

### test_input

裸 WS 进同一房间，连发 8×move、3×click（右下角空白桌面）、4×scroll、Shift 按下/抬起，
随后 ping。判定：无 `agent.error`、收到 `pong`、Agent 日志无 traceback/断链、设备仍在线。
测试结束会把鼠标移回原位。

### test_clipboard（v2）

`clip.sync` + `clip{dir:up}` 下发唯一标记，5s 内 `pbpaste` 包含该标记即 PASS（契约不要求回执）。
无回执且剪贴板未变 → SKIP（Agent 未实现）；有回执但未变 / 回 `agent.error` → FAIL。
仅 macOS；测试前保存、结束后恢复原剪贴板内容。

### test_multiscreen（v2）

等 `screens` 消息：未收到 → SKIP；结构不合契约（缺 `id/w/h/x/y/name/primary`、`current` 越界等）→ FAIL；
只有 1 屏 → 结构校验通过后 SKIP；≥2 屏 → 额外校验 `screen.select → screen.selected` 往返。

---

## 4. 已知不稳定项

| 现象 | 原因 | 处理 |
|---|---|---|
| 首帧首次 1000–1200ms | Chrome 首次初始化 H.264 解码器 | 用例自动重载控制页再测一次，记录 `cold_start_ms`，以预热值判定 |
| 媒体/兜底用例 SKIP，原因含「抓屏单帧 30s」 | macOS 屏幕录制权限被拒/变更后未重启 Agent | 重新授权 + 重启 Agent；这是环境闸门，不是产品 FAIL |
| 页面 `0 fps` 但 PC `connected` | Agent 抓屏卡住 / 帧未产生 | 看 `agent.log` 是否有 `answer 已发`，再测 `ScreenTrack.recv()` 耗时 |
| 点到别人的设备 | 同账号下有多个在线可控 PC | 用独立手机号，或保证只有 `QA-PC` 在线 |
| 用例中途 RTC 回落 JPEG | Agent 被重启 / 网络抖动 | 报告里 `abort=rtc_failed_回落到JPEG`，重跑 |
| `--json` 输出混入日志 | 只在 `--json -` 时抑制人读输出 | 需要人读时把 JSON 写到文件 |
| 自建 Chrome 时 `/eval` 报 `Connection refused` | 本机 Chrome 157 headless 的 DevTools HTTP 偶发不可达 | 起好 3456 代理再跑（推荐），或手工指定 `QA_CDP_PORT` 指向可用代理 |

---

## 5. 报告字段（JSON）

```json
{
  "generated_at": "...", "elapsed_s": 42.1,
  "env": {"server": "...", "mobile": "...", "monitors": 1, "artifacts": "..."},
  "transport": "webrtc", "notes": ["已启动服务端/Agent（transport=webrtc）"],
  "summary": {"pass": 3, "fail": 0, "skip": 2, "total": 5, "exit_code": 0},
  "results": [
    {"name": "test_media", "status": "PASS", "metrics": {...},
     "checks": [{"name": "首帧 < 1000 ms", "ok": true, "value": 198, "limit": 1000}]}
  ],
  "agent_log_tail": ["..."]
}
```

`metrics` 里媒体用例的关键键：`first_frame_ms` `cold_start_ms` `avg_fps` `avg_mbps`
`width` `height` `rtt_ms` `jitter_buffer_ms` `drop_rate` `frames_received` `frames_dropped`
`capture_s` `screenshot`。