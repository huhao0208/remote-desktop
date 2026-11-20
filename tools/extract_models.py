"""从 jadx 反编译产物中提取 kotlinx.serialization 描述符（API 数据模型字段表）。

用法: python3 extract_models.py <jadx_sources_dir> <out.json>
"""
import json
import re
import sys
from pathlib import Path

RE_NEW = re.compile(r'new U\("([\w.$]+)",\s*\w+,\s*(\d+)\)')
RE_FIELD = re.compile(r'\.l\("([^"]+)",\s*(true|false)\)')


def extract(src: Path):
    models = {}
    for f in src.rglob("*.java"):
        try:
            text = f.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if "new U(" not in text:
            continue
        # 逐个 descriptor 块解析：以 new U( 开头，到下一个 new U( 或文件尾
        matches = list(RE_NEW.finditer(text))
        for i, m in enumerate(matches):
            name, count = m.group(1), int(m.group(2))
            end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
            block = text[m.end():end]
            fields = []
            for fm in RE_FIELD.finditer(block):
                fields.append({"name": fm.group(1), "optional": fm.group(2) == "true"})
            models.setdefault(name, {
                "field_count": count,
                "fields": fields,
                "source": str(f.relative_to(src)),
            })
    return models


def main():
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    models = extract(src)
    out.write_text(json.dumps(models, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"models={len(models)} -> {out}")
    for n, v in list(models.items())[:15]:
        names = [f["name"] for f in v["fields"]]
        print(f"  {n}: {names}")


if __name__ == "__main__":
    main()