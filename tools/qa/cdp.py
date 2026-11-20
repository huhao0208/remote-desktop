"""Chrome DevTools 代理 + 客户端（qa 套件专用）。

对外暴露一个 HTTP 代理（默认 127.0.0.1:3456），端点：
  GET  /targets                      → {"targets":[{targetId,url,title}]}
  GET  /new?url=                     → {"targetId": "..."}
  POST /navigate?target=<id>&url=    → {"ok": true}
  POST /eval?target=<id>   body=JS   → {"value": ...} / {"error": "..."}
  GET  /screenshot?target=<id>       → image/png
  POST /close?target=<id>            → {"ok": true}

约定（历史踩坑，勿改）：
- `/eval` 的 body 只接受**单行** JS，且不能返回 Promise（返回 Promise 会 unserializable）。
  异步逻辑一律「先落全局变量，再轮询读取」。
- 代理内部复用 Chrome 的 /json/* HTTP 接口 + Runtime.evaluate。

Chrome 由本模块按需拉起（headless=new，独立 user-data-dir，保证 H.264 解码可用）。
若 3456 已有代理在跑则直接复用，不重复拉起。
"""
from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional

PROXY_PORT = int(os.environ.get("QA_CDP_PORT", "3456"))
CDP_PORT = int(os.environ.get("QA_CHROME_CDP_PORT", "9222"))
CHROME_BIN = os.environ.get(
    "QA_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
)
PROFILE_DIR = Path(os.environ.get("QA_CHROME_PROFILE", "/tmp/qa-chrome-profile"))

_CHROME_FLAGS = [
    "--headless=new",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding",
    "--disable-backgrounding-occluded-windows",
    "--autoplay-policy=no-user-gesture-required",
    "--window-size=1600,1000",
    "--hide-scrollbars",
]


# ------------------------------------------------------------------ 基础工具

def _port_open(port: int, host: str = "127.0.0.1", timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _http(url: str, method: str = "GET", timeout: float = 15) -> bytes:
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def _http_json(url: str, method: str = "GET", timeout: float = 15) -> Any:
    return json.loads(_http(url, method=method, timeout=timeout).decode())


# ------------------------------------------------------------ CDP 命令通道

def _ws_eval(ws_url: str, expression: str, timeout: float = 40) -> Dict[str, Any]:
    """发一条 Runtime.evaluate，返回 {"value": ...} 或 {"error": ...}。"""
    from websockets.sync.client import connect

    with connect(ws_url, open_timeout=10, max_size=None) as ws:
        ws.send(json.dumps({
            "id": 1,
            "method": "Runtime.evaluate",
            "params": {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": False,
                "userGesture": True,
            },
        }))
        deadline = time.time() + timeout
        while True:
            left = max(0.1, deadline - time.time())
            try:
                raw = json.loads(ws.recv(timeout=left))
            except TimeoutError:
                return {"error": "eval timeout"}
            if raw.get("id") != 1:
                continue
            if "error" in raw:
                return {"error": str(raw["error"].get("message") or raw["error"])}
            res = raw.get("result") or {}
            if "exceptionDetails" in res:
                det = res["exceptionDetails"]
                text = det.get("text") or ""
                exc = (det.get("exception") or {}).get("description") or ""
                return {"error": (text + " " + exc).strip() or "exception"}
            return {"value": (res.get("result") or {}).get("value")}


def _ws_cmd(ws_url: str, method: str, params: Optional[dict] = None,
            timeout: float = 20) -> Dict[str, Any]:
    from websockets.sync.client import connect

    with connect(ws_url, open_timeout=10, max_size=None) as ws:
        ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        deadline = time.time() + timeout
        while True:
            left = max(0.1, deadline - time.time())
            try:
                raw = json.loads(ws.recv(timeout=left))
            except TimeoutError:
                raise RuntimeError(f"{method} timeout")
            if raw.get("id") == 1:
                if "error" in raw:
                    raise RuntimeError(f"{method}: {raw['error']}")
                return raw.get("result") or {}


# ------------------------------------------------------------------ HTTP 代理

class _ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:  # 静音
        pass

    # -- helpers
    def _json(self, obj: Any, code: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _bin(self, data: bytes, ctype: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _query(self) -> Dict[str, str]:
        q = urllib.parse.urlparse(self.path).query
        return {k: v[0] for k, v in urllib.parse.parse_qs(q).items()}

    def _target_ws(self, target: str) -> str:
        info = _http_json(f"http://127.0.0.1:{CDP_PORT}/json/list")
        for t in info:
            if t.get("id") == target and t.get("type") == "page":
                return t["webSocketDebuggerUrl"]
        raise RuntimeError(f"target not found: {target}")

    def _body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    # -- routes
    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        try:
            if path == "/health":
                return self._json({"ok": True, "port": PROXY_PORT})
            if path == "/targets":
                items = _http_json(f"http://127.0.0.1:{CDP_PORT}/json/list")
                pages = [{"targetId": t["id"], "url": t.get("url"), "title": t.get("title")}
                         for t in items if t.get("type") == "page"]
                return self._json({"targets": pages})
            if path == "/new":
                url = self._query().get("url", "about:blank")
                quoted = urllib.parse.quote(url, safe=":/?&=#%")
                info = _http_json(f"http://127.0.0.1:{CDP_PORT}/json/new?{quoted}", method="PUT")
                return self._json({"targetId": info["id"], "url": info.get("url")})
            if path == "/screenshot":
                tid = self._query().get("target", "")
                res = _ws_cmd(self._target_ws(tid), "Page.captureScreenshot", {"format": "png"})
                return self._bin(base64.b64decode(res["data"]), "image/png")
            if path == "/eval":
                tid = self._query().get("target", "")
                js = self._query().get("js", "")
                return self._json(_ws_eval(self._target_ws(tid), js))
            self._json({"error": f"unknown path {path}"}, 404)
        except Exception as e:  # 代理自身绝不 500 崩掉调用方
            self._json({"error": f"{type(e).__name__}: {e}"}, 200 if path == "/eval" else 500)

    def do_POST(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        try:
            q = self._query()
            if path == "/eval":
                js = " ".join(self._body().decode("utf-8", "replace").split())
                return self._json(_ws_eval(self._target_ws(q.get("target", "")), js))
            if path == "/navigate":
                res = _ws_cmd(self._target_ws(q.get("target", "")), "Page.navigate",
                              {"url": q.get("url", "")})
                return self._json({"ok": True, "frameId": res.get("frameId")})
            if path == "/close":
                _http(f"http://127.0.0.1:{CDP_PORT}/json/close/{q.get('target', '')}")
                return self._json({"ok": True})
            self._json({"error": f"unknown path {path}"}, 404)
        except Exception as e:
            self._json({"error": f"{type(e).__name__}: {e}"}, 500)


class Client:
    """代理的 Python 客户端（测试用例只依赖这个类）。"""

    def __init__(self, base: str = f"http://127.0.0.1:{PROXY_PORT}") -> None:
        self.base = base.rstrip("/")

    # -- 页面/标签
    def targets(self) -> List[dict]:
        raw = json.loads(_http(f"{self.base}/targets").decode())
        items = raw.get("targets", raw) if isinstance(raw, dict) else raw
        return [t for t in items if isinstance(t, dict)]

    def new(self, url: str) -> str:
        out = _http(f"{self.base}/new?url=" + urllib.parse.quote(url, safe="")).decode()
        data = json.loads(out)
        if isinstance(data, dict) and data.get("targetId"):
            return data["targetId"]
        if isinstance(data, dict) and data.get("error"):
            raise RuntimeError(f"新建标签失败: {data['error']}")
        # 个别代理直接回目标对象
        if isinstance(data, dict) and data.get("id"):
            return data["id"]
        if isinstance(data, list) and data:
            return data[0].get("targetId") or data[0]["id"]
        raise RuntimeError(f"/new 响应无法解析: {out[:200]}")

    def navigate(self, target: str, url: str) -> None:
        req = urllib.request.Request(
            f"{self.base}/navigate?target={target}&url=" + urllib.parse.quote(url, safe=""),
            data=b"", method="POST")
        with urllib.request.urlopen(req, timeout=20):
            pass

    def close(self, target: str) -> None:
        for method in ("POST", "GET"):
            try:
                req = urllib.request.Request(f"{self.base}/close?target={target}",
                                             data=b"" if method == "POST" else None,
                                             method=method)
                with urllib.request.urlopen(req, timeout=10):
                    return
            except Exception:
                continue

    # -- 执行 JS
    def eval(self, target: str, js: str) -> Any:
        js = " ".join(js.split())
        last = None
        for attempt in range(3):
            req = urllib.request.Request(f"{self.base}/eval?target={target}", data=js.encode())
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    out = json.loads(r.read().decode())
                if "error" in out:
                    raise RuntimeError(f"{out['error']} :: {js[:140]}")
                return out.get("value")
            except urllib.error.HTTPError as e:
                # 标签正在导航/重载时代理会返回 400/500：短暂重试即可
                detail = e.read().decode(errors="replace")[:200]
                last = RuntimeError(f"HTTP {e.code} :: {detail} :: {js[:120]}")
                if e.code not in (400, 404, 500) or attempt == 2:
                    raise last from None
                time.sleep(0.6)
            except urllib.error.URLError as e:
                last = RuntimeError(f"proxy unreachable: {e}")
                if attempt == 2:
                    raise last from None
                time.sleep(0.6)
        raise last  # pragma: no cover

    def eval_json(self, target: str, js: str) -> Any:
        v = self.eval(target, js)
        if v is None:
            raise RuntimeError(f"eval returned None (unserializable?) :: {js[:140]}")
        return json.loads(v) if isinstance(v, str) else v

    def screenshot(self, target: str) -> bytes:
        with urllib.request.urlopen(f"{self.base}/screenshot?target={target}", timeout=30) as r:
            return r.read()

    def wait_for(self, target: str, js: str, timeout: float, interval: float = 0.3) -> bool:
        end = time.time() + timeout
        while time.time() < end:
            try:
                if self.eval(target, js) in (True, "true"):
                    return True
            except Exception:
                pass
            time.sleep(interval)
        return False


def _launch_chrome() -> subprocess.Popen:
    if not Path(CHROME_BIN).exists():
        raise RuntimeError(f"Chrome 不存在: {CHROME_BIN}（可用 QA_CHROME 覆盖）")
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [CHROME_BIN, * _CHROME_FLAGS,
           f"--remote-debugging-port={CDP_PORT}",
           f"--user-data-dir={PROFILE_DIR}",
           "about:blank"]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            _http_json(f"http://127.0.0.1:{CDP_PORT}/json/version", timeout=1)
            return proc
        except Exception:
            if proc.poll() is not None:
                raise RuntimeError(f"Chrome 启动失败 exit={proc.returncode}")
            time.sleep(0.3)
    raise RuntimeError("Chrome 调试端口未就绪")


class Browser:
    """生命周期管理：复用外部代理，否则拉起 Chrome + 内置代理。"""

    def __init__(self) -> None:
        self.client: Optional[Client] = None
        self._chrome: Optional[subprocess.Popen] = None
        self._httpd: Optional[ThreadingHTTPServer] = None
        self.owned = False

    def start(self) -> Client:
        if self.client:
            return self.client
        if _port_open(PROXY_PORT):
            # 外部代理（已由工具链/人工拉起）：只复用，不接管其 Chrome 生命周期
            c = Client()
            try:
                c.targets()
            except Exception as e:
                raise RuntimeError(f"{PROXY_PORT} 上有服务但不是 CDP 代理: {e}")
            self.client = c
            return c
        self._chrome = _launch_chrome()
        ThreadingHTTPServer.allow_reuse_address = True
        self._httpd = ThreadingHTTPServer(("127.0.0.1", PROXY_PORT), _ProxyHandler)
        threading.Thread(target=self._httpd.serve_forever, daemon=True).start()
        self.client = Client()
        self.owned = True
        return self.client

    def stop(self) -> None:
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
        if self._chrome:
            self._chrome.terminate()
            try:
                self._chrome.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self._chrome.kill()

    def __enter__(self) -> Client:
        return self.start()

    def __exit__(self, *exc: Any) -> None:
        self.stop()


def codec_support(client: Client, target: str) -> Dict[str, Any]:
    """确认 Chrome 具备 H.264 接收能力（headless shell 不带专有编解码器）。"""
    js = ("JSON.stringify({h264:document.createElement('video').canPlayType('video/mp4; "
          "codecs=\"avc1.42E01E\"'),webrtc:typeof RTCPeerConnection!=='undefined'})")
    return json.loads(client.eval(target, js) or "{}")