"""被控端自更新：查 GitHub Release → 下载 agent 专用包 → 校验 → 原地替换 → 自重启。

和客户端自动升级共用同一个 GitHub Release（`docs/auto-update.md`），但**不带 GUI**：
agent 是常驻后台进程，没有界面可弹窗，所以策略是「静默下载 + 空闲时替换」。

三条硬约束（都是踩过的坑，别改）：

1. **`.app` 内的 agent 不自动更新。** macOS 上客户端包里的 agent 处于
   `Contents/Resources/agent/`，替换它会破坏 ad-hoc 签名，并让「屏幕录制」TCC 授权
   （绑定 cdhash）失效，用户得重新授权一次。所以这种情况只记录日志、不落盘。
2. **远控进行中不替换。** 用户正在被控时重启 agent 会直接断链，等空闲再说。
3. **Windows 上运行中的 exe 不能覆盖。** 必须交给独立脚本：等进程退出 → robocopy → 重启。

只在 PyInstaller 打包产物里启用（`getattr(sys, "frozen", False)`）；
源码运行时 sys.executable 是 python，替换它等于毁掉用户环境。
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zipfile
from pathlib import Path
from typing import Callable, Optional

import httpx

try:
    from ._version import VERSION as AGENT_VERSION
except ImportError:
    from _version import VERSION as AGENT_VERSION

REPO = os.environ.get("UU_RELEASE_REPO", "huhao0208/remote-desktop")
API_LATEST = f"https://api.github.com/repos/{REPO}/releases/latest"

# 启动后先等一会儿（别和连服务端抢带宽/CPU），之后每 24h 一次
FIRST_DELAY = 60
CHECK_INTERVAL = 24 * 3600

STATE_DIR = Path.home() / ".uu-agent"
STATE_FILE = STATE_DIR / "update_state.json"


def log(msg: str) -> None:
    print(f"[updater] {msg}", flush=True)


# ------------------------------------------------------------------ 版本比较

def parse_version(v: str) -> tuple[int, int, int]:
    core = v.strip().lstrip("vV").split("-")[0].split("+")[0]
    parts = core.split(".")
    out = []
    for i in range(3):
        raw = parts[i] if i < len(parts) else "0"
        digits = "".join(ch for ch in raw if ch.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out)  # type: ignore[return-value]


def is_newer(remote: str, current: str) -> bool:
    return parse_version(remote) > parse_version(current)


# ---------------------------------------------------------------- 平台与资产

def asset_name() -> Optional[str]:
    sysname = platform.system()
    machine = platform.machine().lower()
    arm = machine in ("arm64", "aarch64")
    if sysname == "Darwin":
        return "uu-agent-macos-arm64.tar.gz" if arm else None
    if sysname == "Linux":
        return "uu-agent-linux-x64.tar.gz" if not arm else "uu-agent-linux-arm64.tar.gz"
    if sysname == "Windows":
        return "uu-agent-windows-x64.zip"
    return None


def install_dir() -> Path:
    """当前 agent 所在的目录（onedir 形态即 uu-agent + _internal 的父目录）。"""
    return Path(sys.executable).resolve().parent


def running_inside_app() -> bool:
    return ".app/Contents/" in str(install_dir()).replace(os.sep, "/")


# ------------------------------------------------------------------ 状态文件

def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text("utf-8"))
    except Exception:
        return {}


def save_state(state: dict) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(state), "utf-8")
    except Exception:
        pass


# ------------------------------------------------------------------ 查询/下载

def fetch_latest(timeout: float = 15.0) -> Optional[dict]:
    name = asset_name()
    if not name:
        return None
    try:
        with httpx.Client(timeout=timeout, follow_redirects=True) as c:
            r = c.get(
                API_LATEST,
                headers={
                    "Accept": "application/vnd.github+json",
                    "User-Agent": f"uu-agent/{AGENT_VERSION}",
                },
            )
            if r.status_code != 200:
                log(f"查询最新版本失败：HTTP {r.status_code}")
                return None
            rel = r.json()
    except Exception as e:
        log(f"查询最新版本异常：{e}")
        return None

    tag = (rel.get("tag_name") or "").strip()
    version = tag.lstrip("vV")
    if not version or not is_newer(version, AGENT_VERSION):
        return None

    for a in rel.get("assets") or []:
        if a.get("name") != name:
            continue
        digest = (a.get("digest") or "")
        sha = digest.split(":", 1)[1].lower() if digest.startswith("sha256:") else ""
        return {
            "version": version,
            "url": a.get("browser_download_url"),
            "size": int(a.get("size") or 0),
            "sha256": sha,
            "notes_url": rel.get("html_url") or "",
        }
    log(f"v{version} 里没有 {name}")
    return None


def download(info: dict, dest_dir: Path) -> Optional[Path]:
    url = info.get("url")
    if not url:
        return None
    dest_dir.mkdir(parents=True, exist_ok=True)
    suffix = ".tar.gz" if url.endswith(".tar.gz") else ".zip"
    out = dest_dir / f"agent-{info['version']}{suffix}"
    if out.exists():
        out.unlink()

    h = hashlib.sha256()
    try:
        with httpx.Client(timeout=None, follow_redirects=True) as c:
            with c.stream("GET", url, headers={"User-Agent": f"uu-agent/{AGENT_VERSION}"}) as r:
                if r.status_code != 200:
                    log(f"下载失败：HTTP {r.status_code}")
                    return None
                with out.open("wb") as f:
                    for chunk in r.iter_bytes(256 * 1024):
                        f.write(chunk)
                        h.update(chunk)
    except Exception as e:
        log(f"下载异常：{e}")
        if out.exists():
            out.unlink()
        return None

    if info.get("sha256") and h.hexdigest() != info["sha256"]:
        log("校验失败（sha256 不符），已丢弃")
        out.unlink()
        return None
    if info.get("size") and out.stat().st_size != info["size"]:
        log(f"下载不完整：{out.stat().st_size} != {info['size']}")
        out.unlink()
        return None
    return out


def extract(archive: Path, dest: Path) -> bool:
    if dest.exists():
        shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True, exist_ok=True)
    try:
        if archive.name.endswith(".zip"):
            with zipfile.ZipFile(archive) as z:
                z.extractall(dest)
        else:
            with tarfile.open(archive, "r:gz") as t:
                t.extractall(dest)
        return True
    except Exception as e:
        log(f"解压失败：{e}")
        return False


# ------------------------------------------------------------------ 应用替换

def _exe_name() -> str:
    return "uu-agent.exe" if platform.system() == "Windows" else "uu-agent"


def apply_windows(staging: Path) -> bool:
    exe = install_dir() / _exe_name()
    if not (staging / _exe_name()).exists():
        log("包里没有 uu-agent.exe，放弃")
        return False

    script = staging / "uu-agent-update.ps1"
    script.write_text(
        "$ErrorActionPreference = 'Continue'\n"
        f"$procId = {os.getpid()}\n"
        f"$src = '{staging}'\n"
        f"$dst = '{install_dir()}'\n"
        f"$exeName = '{_exe_name()}'\n"
        "for ($i = 0; $i -lt 120; $i++) {\n"
        "  if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { break }\n"
        "  Start-Sleep -Milliseconds 500\n"
        "}\n"
        "Start-Sleep -Milliseconds 800\n"
        "$old = Join-Path $dst ($exeName + '.old')\n"
        "if (Test-Path $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }\n"
        "try { Move-Item -LiteralPath (Join-Path $dst $exeName) -Destination $old -Force } catch {}\n"
        "robocopy $src $dst /E /IS /NFL /NDL /NJH /NJS /R:2 /W:1 | Out-Null\n"
        "Start-Process -FilePath (Join-Path $dst $exeName) -ArgumentList $args\n",
        encoding="utf-8",
    )
    try:
        subprocess.Popen(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
             "-File", str(script)],
            creationflags=getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
            close_fds=True,
        )
        log("已交给 PowerShell 脚本，退出后替换并重启")
        os._exit(0)
    except Exception as e:
        log(f"启动替换脚本失败：{e}")
        return False


def apply_posix(staging: Path) -> bool:
    """macOS / Linux：直接覆盖文件再 execv 自己。

    运行中的进程不受影响（旧 inode 仍然有效），execv 之后跑的就是新版本。
    """
    exe = install_dir() / _exe_name()
    if not (staging / _exe_name()).exists():
        log("包里没有 uu-agent，放弃")
        return False
    try:
        # 先备份可执行文件，替换后 execv 失败还能回滚
        backup = exe.with_suffix(".bak")
        shutil.copy2(exe, backup)
        for item in staging.iterdir():
            target = install_dir() / item.name
            if item.is_dir():
                if target.exists():
                    shutil.rmtree(target, ignore_errors=True)
                shutil.copytree(item, target)
            else:
                shutil.copy2(item, target)
        os.chmod(exe, 0o755)
    except Exception as e:
        log(f"替换文件失败（可能没有写权限）：{e}")
        return False

    log("替换完成，execv 重启自身")
    argv = [str(exe)] + sys.argv[1:]
    try:
        os.execv(str(exe), argv)
    except Exception as e:
        log(f"execv 失败：{e}，等外层重连逻辑重启")
    return True


# ------------------------------------------------------------------ 主循环

class AgentUpdater:
    def __init__(self, busy: Optional[Callable[[], bool]] = None) -> None:
        self._busy = busy or (lambda: False)
        self._state = load_state()

    def _maybe_update(self) -> bool:
        if not getattr(sys, "frozen", False):
            log("源码运行，跳过自更新")
            return False
        if running_inside_app():
            log("运行在 .app 内（随客户端分发），跳过自更新以免破坏签名与屏幕录制授权")
            return False
        if not os.access(install_dir(), os.W_OK):
            log(f"{install_dir()} 不可写，跳过自更新")
            return False

        info = fetch_latest()
        if not info:
            return False
        if self._state.get("skipped") == info["version"]:
            return False
        if self._busy():
            log(f"v{info['version']} 可用，但正在远控，30 分钟后再试")
            return False

        log(f"发现新版本 v{info['version']}，开始下载")
        tmp = Path(tempfile.gettempdir()) / "uu-agent-update"
        archive = download(info, tmp)
        if not archive:
            return False

        staging = tmp / "extract"
        if not extract(archive, staging):
            return False

        ok = apply_windows(staging) if platform.system() == "Windows" else apply_posix(staging)
        if ok:
            self._state["last_applied"] = info["version"]
            save_state(self._state)
        return ok

    def loop(self) -> None:
        """后台线程：启动后 FIRST_DELAY 检查一次，之后每 CHECK_INTERVAL 一次。"""
        time.sleep(FIRST_DELAY)
        while True:
            try:
                last = float(self._state.get("last_check_ms") or 0) / 1000
                if time.time() - last < CHECK_INTERVAL:
                    time.sleep(600)
                    continue
                self._state["last_check_ms"] = int(time.time() * 1000)
                save_state(self._state)
                self._maybe_update()
            except Exception as e:  # 自更新永远不能影响主链路
                log(f"检查更新异常：{e}")
            time.sleep(CHECK_INTERVAL)


def start_background(busy: Optional[Callable[[], bool]] = None) -> threading.Thread:
    """在 agent 启动时调用；daemon 线程，进程退出即结束。"""
    up = AgentUpdater(busy=busy)
    th = threading.Thread(target=up.loop, name="uu-agent-updater", daemon=True)
    th.start()
    return th
