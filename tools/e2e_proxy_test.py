"""端到端验证（自包含）：经 mitmproxy + 临时自建 CA，走官方域名完成 REST 与 WebSocket 信令。

不依赖任何未入库产物：运行时自动生成 CA / 服务端叶子证书 / mitmproxy confdir，
自动拉起 uvicorn(8443, TLS) 与 mitmdump(8080)，测完全部清理进程。

覆盖：
1) REST 登录 / 设备注册 / 建房（全部走 https://api.nrd.nie.163.com:443，经 8080 代理）
2) 双端 WebSocket 连接房间信令，A 发帧 → B 收到（证明信令透传链路成立）

依赖：pip install fastapi uvicorn websockets mitmproxy cryptography
运行：python tools/e2e_proxy_test.py
"""
from __future__ import annotations

import asyncio
import datetime
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

import websockets
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parent.parent
BASE = "https://api.nrd.nie.163.com"
PROXY = "http://127.0.0.1:8080"
DOMAIN = "api.nrd.nie.163.com"


def _cert(cn: str, key, issuer_name=None, issuer_key=None, san: str | None = None, ca: bool = False):
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    now = datetime.datetime.now(datetime.timezone.utc)
    b = (x509.CertificateBuilder()
         .subject_name(name)
         .issuer_name(issuer_name or name)
         .public_key(key.public_key())
         .serial_number(x509.random_serial_number())
         .not_valid_before(now - datetime.timedelta(days=1))
         .not_valid_after(now + datetime.timedelta(days=30))
         .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    if ca:
        b = b.add_extension(x509.KeyUsage(
            digital_signature=True, key_cert_sign=True, crl_sign=True,
            content_commitment=False, key_encipherment=False, data_encipherment=False,
            key_agreement=False, encipher_only=False, decipher_only=False), critical=True)
        b = b.add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
    else:
        issuer_pub = (issuer_key or key).public_key()
        b = b.add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_pub), critical=False)
    if san:
        b = b.add_extension(x509.SubjectAlternativeName([x509.DNSName(san)]), critical=False)
    return b.sign(issuer_key or key, hashes.SHA256())


def _key_pem(key) -> bytes:
    return key.private_bytes(serialization.Encoding.PEM,
                             serialization.PrivateFormat.TraditionalOpenSSL,
                             serialization.NoEncryption())


def gen_certs(work: Path) -> tuple[Path, Path, Path, Path]:
    """生成两套 CA：服务端证书链 + mitmproxy 签发 CA。
    返回 (trust.pem 客户端合并信任链, fullchain.pem, privkey.pem, confdir)。"""
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_crt = _cert("uu-e2e-ca", ca_key, ca=True)
    sv_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    sv_crt = _cert(DOMAIN, sv_key, ca_crt.subject, ca_key, san=DOMAIN)
    chain_p, key_p = work / "fullchain.pem", work / "privkey.pem"
    chain_p.write_bytes(sv_crt.public_bytes(serialization.Encoding.PEM))
    key_p.write_bytes(_key_pem(sv_key))

    # mitmproxy confdir：预置我们生成的 CA（cert+key 合并），避免首启随机生成
    confdir = work / "confdir"
    confdir.mkdir()
    mitm_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    mitm_crt = _cert("uu-e2e-mitm-ca", mitm_key, ca=True)
    (confdir / "mitmproxy-ca.pem").write_bytes(
        mitm_crt.public_bytes(serialization.Encoding.PEM) + _key_pem(mitm_key))
    mitm_ca_cert = mitm_crt.public_bytes(serialization.Encoding.PEM)
    (confdir / "mitmproxy-ca-cert.pem").write_bytes(mitm_ca_cert)

    # 客户端信任链 = 服务端 CA + mitm CA（REST 经代理时叶子由 mitm CA 签发）
    trust = work / "trust.pem"
    trust.write_bytes(ca_crt.public_bytes(serialization.Encoding.PEM) + mitm_ca_cert)
    return trust, chain_p, key_p, confdir


def wait_port(port: int, timeout: float = 25.0) -> None:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            socket.create_connection(("127.0.0.1", port), 1).close()
            return
        except OSError:
            time.sleep(0.3)
    raise RuntimeError("port %d not up in %.0fs" % (port, timeout))


def api(path: str, ca: Path, body: dict | None = None, token: str | None = None) -> dict:
    ctx = ssl.create_default_context(cafile=str(ca))
    handler = urllib.request.ProxyHandler({"https": PROXY, "http": PROXY})
    opener = urllib.request.build_opener(handler, urllib.request.HTTPSHandler(context=ctx))
    data = json.dumps(body or {}).encode()
    req = urllib.request.Request(
        BASE + path, data=data, method="POST",
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})},
    )
    with opener.open(req, timeout=20) as r:
        return json.loads(r.read().decode())


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="uu-e2e-"))
    procs: list[subprocess.Popen] = []
    try:
        trust, chain, key, confdir = gen_certs(work)
        env = {**os.environ,
               "UU_PUBLIC_BASE": BASE, "UU_WS_BASE": "wss://" + DOMAIN,
               "UU_DATA_DIR": str(work / "data")}
        py = sys.executable
        procs.append(subprocess.Popen(
            [py, "-m", "uvicorn", "server:app", "--host", "127.0.0.1", "--port", "8443",
             "--ssl-certfile", str(chain), "--ssl-keyfile", str(key), "--log-level", "warning"],
            cwd=str(ROOT / "srv2"), env=env,
            stdout=open(work / "server.log", "w"), stderr=subprocess.STDOUT))
        mitmdump = str(Path(py).parent / "mitmdump")
        procs.append(subprocess.Popen(
            [mitmdump, "-p", "8080", "--set", f"confdir={confdir}", "--set", "ssl_insecure=true",
             "-s", str(ROOT / "proxy" / "addon_uuyc.py"), "--flow-detail", "0"],
            stdout=open(work / "proxy.log", "w"), stderr=subprocess.STDOUT))
        wait_port(8443)
        wait_port(8080)
        time.sleep(1.0)  # mitmproxy addon 加载余量

        ctx = ssl.create_default_context(cafile=str(trust))

        async def run() -> None:
            login = api("/api/v1/login/by_mobile", trust, {"mobile": "13700000001"})
            assert login["code"] == 0, login
            tok = login["data"]["token"]
            print("login ok      uid =", login["data"]["uid"])

            init = api("/api/v1/device/android/init", trust, {"device_name": "host-A", "os": "android"}, tok)
            assert init["code"] == 0, init
            dev_a = init["data"]["device_id"]
            print("device-A ok   id  =", dev_a)
            init_b = api("/api/v1/device/android/init", trust, {"device_name": "peer-B", "os": "android"}, tok)
            dev_b = init_b["data"]["device_id"]
            print("device-B ok   id  =", dev_b)

            room = api("/api/v1/room/create", trust, {"device_id": dev_a, "mode": "control"}, tok)
            assert room["code"] == 0, room
            cfg = room["data"]
            rtok = cfg["token"]
            print("room ok       signaling =", cfg["signaling_server"])
            assert cfg["signaling_server"].startswith("wss://" + DOMAIN), cfg

            # --- WebSocket 信令：服务端为二进制透明中继，不注入任何帧 ---
            url = f"wss://{DOMAIN}/ws/signaling?token={rtok}"
            async with websockets.connect(url + f"&device_id={dev_a}", ssl=ctx, proxy=PROXY,
                                          subprotocols=["uu.v1"]) as wa, \
                       websockets.connect(url + f"&device_id={dev_b}", ssl=ctx, proxy=PROXY) as wb:
                print("ws connected  A subprotocol =", wa.subprotocol)
                assert wa.subprotocol == "uu.v1", wa.subprotocol

                # B 进房时服务端向 A 发 peer.join 通知，先消费掉
                notice = json.loads(await asyncio.wait_for(wa.recv(), 10))
                assert notice.get("p") == "peer.join", notice

                probe = {"kind": "offer", "p": "transport.probe", "data": "aGVsbG8="}
                await wa.send(json.dumps(probe))
                got = json.loads(await asyncio.wait_for(wb.recv(), 10))
                print("ws relay A→B  =", got)
                assert got.get("p") == "transport.probe", got

                blob = bytes(range(48))
                await wb.send(blob)
                back = await asyncio.wait_for(wa.recv(), 10)
                assert back == blob, len(back)
                print("ws relay B→A  = binary", len(blob), "bytes OK")

        asyncio.run(run())
        print("\nALL PASS")
        return 0
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                p.kill()
        print("[e2e] logs:", work)


if __name__ == "__main__":
    sys.exit(main())