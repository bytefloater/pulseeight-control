#!/usr/bin/env python3
"""Builds AppIcon.ico from Logo.png.

    python3 PulseEightControl-windows/App/Assets/make-icon.py

The .ico holds the sizes Windows asks for (16 to 256 px), each stored as a PNG, which every supported version of
Windows reads. Logo.png must have a transparent background outside its rounded corners (not white). It is resized
with Pillow (`pip install pillow`) where that is installed, otherwise with macOS's `sips`; run this again whenever
Logo.png changes and commit the result.
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
    try:
        from PIL import Image
    except ImportError:
        subprocess.run(["sips", "-z", str(size), str(size), SOURCE, "--out", out], check=True, capture_output=True)
    else:
        with Image.open(SOURCE) as logo:
            # Pillow resizes RGBA with the colour weighted by alpha, so the soft corners don't pick up a fringe.
            logo.convert("RGBA").resize((size, size), Image.LANCZOS).save(out)
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
