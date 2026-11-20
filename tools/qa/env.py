"""测试环境编排：起服务端 / 起 Agent / 登录建房间 / 探测 agent.hello。

服务端与 Agent 都是**外部进程**，本模块只 spawn 与等待，不改产品代码。
若端口上已有进程（例如手工起的服务端），则直接复用，不重复启动。
"""
from __future__ import annotations

import json
import os
import platform
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import cdp

REPO = Path(__file__).resolve().parents[2]
VENV_PY = REPO / ".venv" / "bin" / "python"
PY = str(VENV_PY if VENV_PY.exists() else Path(sys.executable))
DEFAULT_SERVER = "http://127.0.0.1:8443"
DEFAULT_MOBILE = "13900000001"
DEVICE_NAME = "QA-PC"


def _http_json(url: str, body: Optional[dict] = None, token: Optional[str] = None,
               timeout: float = 15) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def _port_open(host: str, port: int) -> bool:
    import socket
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def log_tail(path: Optional[Path], lines: int = 25) -> str:
    if not path or not path.exists():
        return ""
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])
    except Exception:
        return ""


class Env:
    def __init__(self, server: str = DEFAULT_SERVER, mobile: str = DEFAULT_MOBILE,
                 artifacts: Optional[Path] = None, agent_python: Optional[str] = None,
                 agent_pythonpath: Optional[str] = None) -> None:
        self.server = server.rstrip("/")
        self.mobile = mobile
        # Agent 解释器可单独指定：屏幕录制授权是按可执行文件给的，
        # 只有已授权的 python 才能抓到屏（见 README 环境准备）
        self.agent_py = agent_python or PY
        self.agent_pythonpath = agent_pythonpath
        self.artifacts = artifacts or (Path(__file__).parent / ".artifacts")
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.run_dir = self.artifacts / time.strftime("run-%Y%m%d-%H%M%S")
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.server_log = self.run_dir / "server.log"
        self.agent_log = self.run_dir / "agent.log"
        self._server_proc: Optional[subprocess.Popen] = None
        self._agent_proc: Optional[subprocess.Popen] = None
        self._token: Optional[str] = None
        self._browser: Optional[cdp.Browser] = None
        self._owned_tabs: set = set()
        self.server_owned = False
        self.agent_owned = False

    # ------------------------------------------------------------ 生命周期
    @property
    def port(self) -> int:
        return int(self.server.rsplit(":", 1)[-1].split("/")[0])

    def start_server(self) -> None:
        if _port_open("127.0.0.1", self.port):
            return
        f = open(self.server_log, "wb")
        env = dict(os.environ)
        env.setdefault("UU_PORT", str(self.port))
        self._server_proc = subprocess.Popen(
            [PY, "server.py"], cwd=str(REPO / "srv2"),
            stdout=f, stderr=subprocess.STDOUT, env=env)
        self.server_owned = True
        deadline = time.time() + 30
        while time.time() < deadline:
            if _port_open("127.0.0.1", self.port):
                return
            if self._server_proc.poll() is not None:
                raise RuntimeError(f"服务端启动失败：\n{log_tail(self.server_log)}")
            time.sleep(0.3)
        raise RuntimeError(f"服务端 30s 未监听 {self.port}：\n{log_tail(self.server_log)}")

    def stop_server(self) -> None:
        if self._server_proc and self._server_proc.poll() is None:
            self._server_proc.terminate()
            try:
                self._server_proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self._server_proc.kill()
        self._server_proc = None

    def start_agent(self, transport: str = "webrtc") -> None:
        self.stop_agent()
        if self.agent_log.exists():
            self.agent_log.unlink()
        f = open(self.agent_log, "wb")
        aenv = dict(os.environ, PYTHONUNBUFFERED="1")  # 日志实时落盘，失败时能拿到最后几行
        if self.agent_pythonpath:
            aenv["PYTHONPATH"] = self.agent_pythonpath
        self._agent_proc = subprocess.Popen(
            [self.agent_py, "agent.py", "--server", self.server, "--mobile", self.mobile,
             "--name", DEVICE_NAME, "--transport", transport],
            cwd=str(REPO / "agent"), stdout=f, stderr=subprocess.STDOUT, env=aenv)
        self.agent_owned = True
        # 等设备在线 + hello 可读（hello 里有 media 真值，含降级情况）
        deadline = time.time() + 40
        last_err = ""
        while time.time() < deadline:
            if self._agent_proc.poll() is not None:
                raise RuntimeError(f"Agent 退出 code={self._agent_proc.returncode}：\n"
                                   f"{log_tail(self.agent_log)}")
            try:
                hello = self.hello(timeout=3).get("hello")
                if hello:
                    return
            except Exception as e:  # 设备尚未注册完成
                last_err = str(e)
            time.sleep(0.5)
        raise RuntimeError(f"Agent 40s 内未发 hello（{last_err}）：\n{log_tail(self.agent_log)}")

    def stop_agent(self) -> None:
        if self._agent_proc and self._agent_proc.poll() is None:
            try:
                os.kill(self._agent_proc.pid, signal.SIGINT)
            except Exception:
                self._agent_proc.terminate()
            try:
                self._agent_proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self._agent_proc.kill()
        self._agent_proc = None

    def close(self) -> None:
        self.stop_agent()
        if self.server_owned:
            self.stop_server()
        if self._browser:
            self._browser.stop()
            self._browser = None

    # ------------------------------------------------------------ HTTP API
    def api(self, path: str, body: Optional[dict] = None,
            token: Optional[str] = None) -> dict:
        return _http_json(self.server + path, body, token)

    def login(self) -> str:
        if self._token:
            return self._token
        r = self.api("/api/v1/login/by_mobile", {"mobile": self.mobile})
        if r.get("code") != 0:
            raise RuntimeError(f"登录失败: {r}")
        self._token = r["data"]["token"]
        return self._token

    def devices(self) -> List[dict]:
        r = self.api("/api/v1/device/list", {}, self.login())
        return (r.get("data") or {}).get("list") or []

    def pick_device(self, name: str = DEVICE_NAME, allow_other: bool = False) -> dict:
        """选本套件的 Agent。默认只认 DEVICE_NAME，避免同账号下点到同事在跑的 Agent。"""
        all_devs = self.devices()
        cands = [d for d in all_devs if d.get("online") and d.get("controllable", True)
                 and d.get("platform") == "pc"]
        for d in cands:
            if name.lower() in (d.get("device_name") or "").lower():
                return d
        if allow_other and cands:
            return cands[0]
        raise RuntimeError(
            f"没有在线设备 {name}（当前可控：{[d.get('device_name') for d in cands]}）")

    def room(self, device_id: str) -> dict:
        r = self.api(f"/api/v1/room/join/by_device/{device_id}", {}, self.login())
        if r.get("code") != 0:
            raise RuntimeError(f"join room 失败: {r}")
        return r["data"]

    def hello(self, timeout: float = 6.0, screens_wait: float = 1.5) -> Dict[str, Any]:
        """进一次房间，读 agent.hello（顺带收集 screens 等首帧消息）。"""
        from websockets.sync.client import connect

        dev = self.pick_device()
        cfg = self.room(dev["device_id"])
        ws_base = self.server.replace("https://", "wss://").replace("http://", "ws://")
        url = f"{ws_base}/ws/signaling?token={cfg['token']}&device_id=qa-probe"
        out: Dict[str, Any] = {"hello": None, "screens": None, "messages": []}
        with connect(url, open_timeout=10, max_size=8 * 1024 * 1024) as ws:
            deadline = time.time() + timeout
            while time.time() < deadline:
                try:
                    raw = ws.recv(timeout=max(0.1, deadline - time.time()))
                except TimeoutError:
                    break
                if isinstance(raw, bytes):
                    continue
                try:
                    m = json.loads(raw)
                except Exception:
                    continue
                out["messages"].append(m)
                if m.get("p") == "agent.hello" and out["hello"] is None:
                    out["hello"] = m
                elif m.get("p") == "screens" and out["screens"] is None:
                    out["screens"] = m
        # 再看一眼是否随后补发 screens（hello 之后立即推，可能晚于 hello 一帧）
        if out["hello"] and out["screens"] is None and screens_wait > 0:
            out["screens"] = self._sniff_screens(dev, screens_wait)
        return out

    def _sniff_screens(self, dev: dict, wait: float) -> Optional[dict]:
        from websockets.sync.client import connect

        cfg = self.room(dev["device_id"])
        ws_base = self.server.replace("https://", "wss://").replace("http://", "ws://")
        url = f"{ws_base}/ws/signaling?token={cfg['token']}&device_id=qa-probe2"
        found = None
        try:
            with connect(url, open_timeout=10, max_size=8 * 1024 * 1024) as ws:
                end = time.time() + wait
                while time.time() < end:
                    try:
                        raw = ws.recv(timeout=max(0.1, end - time.time()))
                    except TimeoutError:
                        break
                    if isinstance(raw, bytes):
                        continue
                    m = json.loads(raw)
                    if m.get("p") == "screens":
                        found = m
                        break
        except Exception:
            pass
        return found

    # ------------------------------------------------------------ 浏览器
    def browser(self) -> cdp.Client:
        if not self._browser:
            self._browser = cdp.Browser()
        return self._browser.start()

    def open_control(self) -> str:
        """打开（或复用）控制页并完成登录，返回 targetId。"""
        c = self.browser()
        want = self.server + "/control"
        tid = None
        for t in c.targets():
            if (t.get("url") or "").rstrip("/").endswith("/control") and \
                    (t.get("url") or "").startswith(self.server):
                tid = t.get("targetId") or t.get("id")
                break
        if tid:
            c.navigate(tid, want)
        else:
            tid = c.new(want)
            self._owned_tabs.add(tid)
        if not c.wait_for(tid, "typeof doLogin === 'function'", 25):
            raise RuntimeError("控制页脚本未就绪")
        c.eval(tid, f"localStorage.setItem('rd_mobile','{self.mobile}');'ok'")
        c.eval(tid, "localStorage.removeItem('rd_token');'ok'")
        # 画质档位固定为「高清 1920 · 8M」，让分辨率断言有确定目标
        c.eval(tid, "localStorage.setItem('rd_quality','1920,75,8000');'ok'")
        c.navigate(tid, self.server + "/control")
        if not c.wait_for(tid, "typeof doLogin === 'function'", 25):
            raise RuntimeError("控制页重载后脚本未就绪")
        c.eval(tid, "window.__login='pending';"
                    f"doLogin('{self.mobile}').then(r=>window.__login=r?'ok':'fail')"
                    ".catch(e=>window.__login='err:'+e.message);'started'")
        if not c.wait_for(tid, "window.__login && window.__login!=='pending'", 25):
            raise RuntimeError(f"控制页登录超时: {c.eval(tid, 'window.__login')}")
        state = c.eval(tid, "window.__login")
        if state != "ok":
            raise RuntimeError(f"控制页登录失败: {state}")
        return tid

    def enter_device(self, tid: str, name: str = DEVICE_NAME) -> None:
        """在设备列表里点开指定名字的 Agent（避免点到历史设备）。"""
        c = self.browser()
        js = ("(()=>{const rows=[...document.querySelectorAll('.dev.clickable')];"
              f"const el=rows.find(e=>e.textContent.includes('{name}'));"
              "if(!el)return 'none';el.click();return 'clicked'})()")
        if not c.wait_for(tid, "document.querySelectorAll('.dev.clickable').length>0", 20):
            raise RuntimeError("设备列表中没有可点击设备（Agent 是否在线？）")
        if c.eval(tid, js) == "none":
            raise RuntimeError(f"设备列表无 {name}")
        if not c.wait_for(tid, "document.getElementById('stage').style.display==='block'", 15):
            raise RuntimeError("点击设备后未进入桌面（WS 未连上）")

    def close_tab(self, tid: str) -> None:
        """只关闭本套件自己开的标签，复用用户已有的标签保持不动。"""
        if tid in self._owned_tabs:
            self.browser().close(tid)
            self._owned_tabs.discard(tid)

    # ------------------------------------------------------------ 环境前置检查
    def capture_seconds(self) -> float:
        """本机单次抓屏耗时（秒）。macOS 屏幕录制权限异常时会阻塞 ~30s/帧，
        此时任何媒体用例都无帧可推，必须先区分「环境未就绪」与「产品回归」。"""
        if getattr(self, "_cap_s", None) is None:
            try:
                import mss
                t0 = time.time()
                with mss.mss() as s:
                    s.grab(s.monitors[1])
                self._cap_s = round(time.time() - t0, 2)
            except Exception:
                self._cap_s = -1.0
        return self._cap_s

    def capture_block_reason(self, limit: float = 3.0) -> Optional[str]:
        sec = self.capture_seconds()
        if 0 <= sec <= limit:
            return None
        hint = ("运行 Agent 的 python 缺少「屏幕录制」TCC 授权（或已被拒），"
                "授权后需重启 Agent 再跑")
        if sec < 0:
            return f"环境不满足：本机 mss 抓屏探测抛异常；{hint}"
        return (f"环境不满足：本机 mss 进程内抓屏单帧 {sec}s（阈值 {limit}s），"
                f"而系统 screencapture / PIL.ImageGrab 仅 ~0.4s —— {hint}")

    # ------------------------------------------------------------ 环境快照
    def snapshot(self) -> Dict[str, Any]:
        return {
            "server": self.server,
            "mobile": self.mobile,
            "python": PY,
            "agent_python": self.agent_py,
            "platform": platform.platform(),
            "monitors": self._monitor_count(),
            "chrome": cdp.CHROME_BIN,
            "artifacts": str(self.run_dir),
        }

    @staticmethod
    def _monitor_count() -> int:
        try:
            import mss
            with mss.mss() as s:
                return max(0, len(s.monitors) - 1)
        except Exception:
            return -1