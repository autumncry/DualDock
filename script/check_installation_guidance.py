#!/usr/bin/env python3
"""Fail release packaging if first-launch guidance or its DMG copy is missing."""

import argparse
from pathlib import Path
import sys


MARKER_START = "<!-- first-launch-guidance:start -->"
MARKER_END = "<!-- first-launch-guidance:end -->"
COMMON = (
    "Apple Developer ID",
    "Open Anyway",
    "SHA-256",
    "https://github.com/autumncry/DualDock/releases/latest",
    "https://github.com/autumncry/DualDock/issues",
    "https://support.apple.com/en-us/102445",
    "https://support.apple.com/en-gb/guide/mac-help/mh40617/mac",
)
CHINESE = (
    "公证", "无法验证开发者", "先尝试打开", "系统设置", "隐私与安全性",
    "仍要打开", "确认提示中选择“打开”", "再次尝试打开", "一小时",
    "来源可信", "未被篡改", "将损坏你的电脑", "恶意软件", "已损坏", "停止打开",
)
ENGLISH = (
    "notarized", "developer cannot be verified", "try opening it once",
    "System Settings", "Privacy & Security", "confirm **Open**",
    "Applications again", "one hour", "trust its source", "not tampered with",
    "will damage your computer", "malware", "is damaged", "stop opening it",
)
REQUIRED = {
    "README.md": COMMON + CHINESE,
    "README.en.md": COMMON + ENGLISH,
    "docs/installation.txt": COMMON + CHINESE,
}


def check_documents(root):
    errors = []
    for relative, phrases in REQUIRED.items():
        try:
            content = (root / relative).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            errors.append(f"{relative}: cannot read installation guidance ({error})")
            continue
        if relative.endswith(".md"):
            if content.count(MARKER_START) != 1 or content.count(MARKER_END) != 1:
                errors.append(f"{relative}: keep one complete first-launch guidance block")
                continue
            if content.index(MARKER_END) < content.index(MARKER_START):
                errors.append(f"{relative}: first-launch guidance markers are out of order")
                continue
            content = content.split(MARKER_START, 1)[1].split(MARKER_END, 1)[0]
        missing = [phrase for phrase in phrases if phrase not in content]
        if missing:
            errors.append(f"{relative}: missing first-launch guidance: {', '.join(missing)}")
    return errors


def check_volume(root, volume):
    packaged = volume / "安装说明.txt"
    try:
        if packaged.is_symlink() or not packaged.is_file():
            return [f"{packaged}: DMG must contain the installation text as a regular file"]
        if packaged.read_bytes() != (root / "docs/installation.txt").read_bytes():
            return [f"{packaged}: DMG installation text differs from docs/installation.txt"]
    except OSError as error:
        return [f"{packaged}: cannot verify DMG installation text ({error})"]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--volume", type=Path, help="Read-only mounted DMG or staging directory")
    options = parser.parse_args()
    errors = check_documents(options.root)
    if options.volume is not None:
        errors.extend(check_volume(options.root, options.volume))
    if errors:
        for error in errors:
            print(f"Installation guidance check failed: {error}", file=sys.stderr)
        return 1
    print("First-launch documentation and installation text checks passed.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
