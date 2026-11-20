#!/usr/bin/env python3
"""把根目录 `VERSION` 注入三端，保持版本号单一真源。

为什么要有这个脚本：客户端（Flutter）、被控端（Python agent）、服务端（Python）三处
各自需要一份版本号，手改必然漂移——v0.1.3 发布时 `pubspec.yaml` 还停在 `0.1.0+1`，
`FastAPI(version=...)` 是个写死的 `1.0.0`，导致「用户到底跑哪个版本」无法判断，
而自动升级的整个前提就是能判断版本。

用法
----
    python3 scripts/gen_version.py                 # 生成/覆盖四处文件
    python3 scripts/gen_version.py --build 37      # 同时把 pubspec 的 build 号设为 37（CI 用 run_number）
    python3 scripts/gen_version.py --check         # 只校验，不一致则退出 1（CI 门禁用）

生成目标
--------
    client-flutter/lib/core/version.g.dart   客户端编译期常量
    agent/_version.py                        被控端
    srv2/_version.py                         服务端
    client-flutter/pubspec.yaml              只改 `version:` 一行
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"

DART_OUT = ROOT / "client-flutter" / "lib" / "core" / "version.g.dart"
AGENT_OUT = ROOT / "agent" / "_version.py"
SERVER_OUT = ROOT / "srv2" / "_version.py"
PUBSPEC = ROOT / "client-flutter" / "pubspec.yaml"

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")


def read_version() -> str:
    if not VERSION_FILE.exists():
        raise SystemExit(f"缺少 {VERSION_FILE}")
    v = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not SEMVER_RE.match(v):
        raise SystemExit(f"VERSION 内容不是 x.y.z 形式：{v!r}")
    return v


def dart_source(version: str) -> str:
    return (
        "// 由 scripts/gen_version.py 生成，不要手改；改版本请改根目录 VERSION。\n"
        "// ignore_for_file: constant_identifier_names\n"
        "\n"
        f"const String kAppVersion = '{version}';\n"
    )


def py_source(version: str) -> str:
    return (
        '"""由 scripts/gen_version.py 生成，不要手改；改版本请改根目录 VERSION。"""\n'
        "\n"
        f'VERSION = "{version}"\n'
    )


def pubspec_with_version(text: str, version: str, build: int | None) -> str:
    m = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?\s*$", text, re.MULTILINE)
    if not m:
        raise SystemExit("pubspec.yaml 里找不到 `version: x.y.z+n` 行")
    cur_build = int(m.group(2)) if m.group(2) else 1
    new_build = build if build is not None else cur_build
    return text[: m.start()] + f"version: {version}+{new_build}" + text[m.end():]


def main() -> int:
    ap = argparse.ArgumentParser(description="注入版本号")
    ap.add_argument("--check", action="store_true", help="只校验，不写文件")
    ap.add_argument("--build", type=int, default=None, help="pubspec 的 build 号（默认保持不变）")
    args = ap.parse_args()

    version = read_version()
    pubspec_text = PUBSPEC.read_text(encoding="utf-8")
    new_pubspec = pubspec_with_version(pubspec_text, version, args.build)

    targets = [
        (DART_OUT, dart_source(version)),
        (AGENT_OUT, py_source(version)),
        (SERVER_OUT, py_source(version)),
        (PUBSPEC, new_pubspec),
    ]

    if args.check:
        bad: list[str] = []
        for path, want in targets:
            if not path.exists():
                bad.append(f"{path.relative_to(ROOT)} 不存在")
            elif path.read_text(encoding="utf-8") != want:
                if path == PUBSPEC:
                    # build 号允许本地/CI 各自不同，只比 x.y.z
                    m = re.search(r"^version:\s*([0-9.]+)", path.read_text(encoding="utf-8"), re.MULTILINE)
                    got = m.group(1) if m else "?"
                    if got != version:
                        bad.append(f"pubspec.yaml 版本 {got} != VERSION {version}")
                else:
                    bad.append(f"{path.relative_to(ROOT)} 内容与 VERSION 不一致")
        if bad:
            print("版本不一致：", file=sys.stderr)
            for b in bad:
                print(f"  - {b}", file=sys.stderr)
            print("修复：python3 scripts/gen_version.py", file=sys.stderr)
            return 1
        print(f"版本一致：{version}")
        return 0

    for path, content in targets:
        path.parent.mkdir(parents=True, exist_ok=True)
        old = path.read_text(encoding="utf-8") if path.exists() else ""
        if old == content:
            print(f"未变  {path.relative_to(ROOT)}")
            continue
        path.write_text(content, encoding="utf-8")
        print(f"写入  {path.relative_to(ROOT)}")
    print(f"版本：{version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
