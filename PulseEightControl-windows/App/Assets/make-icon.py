#!/usr/bin/env python3
"""Builds AppIcon.ico from Logo.png.

    python3 PulseEightControl-windows/App/Assets/make-icon.py

The .ico holds the sizes Windows asks for (16 to 256 px), each stored as a PNG, which every supported version of
Windows reads. Needs macOS (it resizes with `sips`) and nothing else; run it again whenever Logo.png changes and
commit the result. Only the Python standard library is used.
"""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "Logo.png")
TARGET = os.path.join(HERE, "AppIcon.ico")
SIZES = [16, 24, 32, 48, 64, 128, 256]


def resized(size: int, folder: str) -> bytes:
    out = os.path.join(folder, f"{size}.png")
    subprocess.run(["sips", "-z", str(size), str(size), SOURCE, "--out", out], check=True, capture_output=True)
    with open(out, "rb") as handle:
        return handle.read()


def main() -> int:
    if not os.path.exists(SOURCE):
        print(f"{SOURCE} not found", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as folder:
        images = [(size, resized(size, folder)) for size in SIZES]

    header = struct.pack("<HHH", 0, 1, len(images))
    entries = b""
    data = b""
    offset = len(header) + 16 * len(images)
    for size, png in images:
        # Width and height are one byte each, with 0 meaning 256.
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    with open(TARGET, "wb") as handle:
        handle.write(header + entries + data)
    print(f"wrote {TARGET} ({len(images)} sizes, {len(header + entries + data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
