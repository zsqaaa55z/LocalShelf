#!/usr/bin/env python3
"""Review a source-only distribution. No network access and no secret output.

The allowlist controls archive contents, not .gitignore. This heuristic check is
not a security audit. --normalize-icons removes only PNG metadata, not pixels.
"""
import argparse
import hashlib
import re
import struct
import sys
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON_PATHS = {
    "ios/Assets.xcassets/AppIcon.appiconset/icon.png": (1024, 1024),
    "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png": (192, 192),
}
SCREENSHOT_PATHS = {
    "docs/images/ios-home.png": (1206, 2622),
    "docs/images/android-home.png": (1220, 2712),
}


def png_chunks(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("not PNG")
    pos = 8
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        chunk = data[pos + 4:pos + 8]
        end = pos + 12 + length
        if end > len(data):
            raise ValueError("truncated PNG")
        payload = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:end])[0]
        if zlib.crc32(chunk + payload) & 0xffffffff != crc:
            raise ValueError("invalid PNG checksum")
        yield chunk, payload, data[pos:end]
        pos = end
        if chunk == b"IEND":
            if pos != len(data):
                raise ValueError("trailing PNG content")
            return
    raise ValueError("missing IEND")


def run(normalize=False, archive=None):
    manifest = ROOT / "PUBLIC_FILES.txt"
    names = [x.strip() for x in manifest.read_text().splitlines() if x.strip()]
    if len(names) != len(set(names)) or "PUBLIC_FILES.txt" not in names:
        raise ValueError("invalid allowlist")
    errors = []
    files = []
    generated = {"build", ".build", ".gradle", ".git", "__pycache__"}
    for item in ROOT.rglob("*"):
        relative = item.relative_to(ROOT)
        if any(part in generated for part in relative.parts):
            continue
        if item.is_file() or item.is_symlink():
            if relative.as_posix() not in names:
                errors.append((relative.as_posix(), "unreviewed file outside allowlist"))
    # These are generic patterns, not an embedded list of a developer's secrets.
    patterns = [
        r"/(?:Users|home)/[^\s/]+/", r"\b[A-Za-z]:\\Users\\",
        r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        r"\b(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{30,})",
        r"\bAKIA[A-Z0-9]{16}\b", r"\bsk-[A-Za-z0-9_-]{24,}\b",
        r"DEVELOPMENT_TEAM\s*=\s*[^;\s]+", r"\bsdk\.dir\s*=",
        r"\b(?:storePassword|keyPassword)\s*[=:]\s*['\"][^'\"]+",
    ]
    forbidden_suffixes = {".db", ".sqlite", ".p12", ".pfx", ".jks", ".keystore",
                          ".ipa", ".apk", ".aab", ".mobileprovision", ".log"}
    for name in names:
        relative = Path(name)
        path = ROOT / relative
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("unsafe allowlist path")
        if any((ROOT / Path(*relative.parts[:i])).is_symlink() for i in range(1, len(relative.parts) + 1)):
            errors.append((name, "symlink")); continue
        if not path.is_file():
            errors.append((name, "missing file")); continue
        if path.suffix in forbidden_suffixes or "xcuserdata" in relative.parts or ".git" in relative.parts:
            errors.append((name, "private/generated file type")); continue
        data = path.read_bytes()
        if name in ICON_PATHS or name in SCREENSHOT_PATHS:
            chunks = list(png_chunks(data))
            ihdr = chunks[0]
            dimensions = (ICON_PATHS | SCREENSHOT_PATHS)[name]
            if ihdr[0] != b"IHDR" or struct.unpack(">II", ihdr[1][:8]) != dimensions:
                errors.append((name, "wrong image dimensions"))
            # Only opaque RGB. Strip metadata without re-encoding pixel data.
            if name in ICON_PATHS and ihdr[1][9] != 2:
                errors.append((name, "icon is not opaque RGB"))
            allowed = {b"IHDR", b"IDAT", b"IEND", b"sRGB", b"gAMA", b"cHRM"}
            if normalize:
                data = data[:8] + b"".join(raw for kind, _, raw in chunks if kind in allowed)
                path.write_bytes(data)
            elif any(kind not in allowed for kind, _, _ in chunks):
                errors.append((name, "unreviewed PNG metadata"))
        else:
            try:
                value = data.decode("utf-8")
            except UnicodeDecodeError:
                errors.append((name, "unexpected binary file")); continue
            for pattern in patterns:
                if re.search(pattern, value):
                    errors.append((name, "potential personal configuration or secret"))
            if "\x00" in value:
                errors.append((name, "NUL in text"))
        files.append((name, data))
    if errors:
        for name, reason in errors:
            print(f"FAIL {name}: {reason}", file=sys.stderr)
        raise SystemExit(1)
    if archive:
        target = Path(archive).resolve()
        if target == ROOT or ROOT in target.parents:
            raise ValueError("archive must be outside the source tree")
        if target.exists():
            raise ValueError("refusing to overwrite an existing archive")
        with zipfile.ZipFile(target, "x", zipfile.ZIP_DEFLATED) as package:
            for name, data in files:
                info = zipfile.ZipInfo("LocalShelf/" + name, (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                package.writestr(info, data)
        with zipfile.ZipFile(target) as package:
            assert package.testzip() is None
            assert len(package.namelist()) == len(names)
        print("ZIP SHA256 " + hashlib.sha256(target.read_bytes()).hexdigest())
    print(f"PASS {len(files)} allowlisted source files; no detected pattern violations")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--normalize-icons", action="store_true")
    parser.add_argument("--zip", dest="archive")
    args = parser.parse_args()
    run(args.normalize_icons, args.archive)
