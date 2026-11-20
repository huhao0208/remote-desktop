"""mitmproxy 上行改写：把客户端硬编码的网易网关域名整体转到本地自建服务端。

工作方式
--------
客户端（电脑/手机）WiFi 里把 HTTP 代理指向 NAS:8080，并信任 ca.crt；
mitmproxy 用该 CA 为 api.nrd.nie.163.com 现场签发叶子证书完成 TLS 终结，
随后把连接目标改写到 127.0.0.1:8443（自建服务端），并**保留原始 Host 头**，
使服务端看到的仍是官方域名（便于日志与后续逻辑对齐真实环境）。

启动：
    mitmdump -p 8080 --set confdir=proxy/confdir --set ssl_insecure=true \
             -s proxy/addon_uuyc.py
"""
from __future__ import annotations

from mitmproxy import http

UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 8443
# 客户端硬编码的全部网关域名后缀
TARGET_SUFFIXES = ("nrd.nie.163.com",)


def request(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host
    if not any(host.endswith(sfx) for sfx in TARGET_SUFFIXES):
        return
    orig = host
    flow.request.scheme = "https"
    flow.request.host = UPSTREAM_HOST
    flow.request.port = UPSTREAM_PORT
    # 关键：改写目标后把 Host 头还原成官方域名
    flow.request.headers["Host"] = orig