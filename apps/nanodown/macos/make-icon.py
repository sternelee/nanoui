#!/usr/bin/env python3
"""Draws nanodown's app icon, an arrow coming down into a progress bar in
nanomon's warm charcoal and amber, and writes AppIcon.icns beside this file.
Needs Pillow and macOS's iconutil. Usage: python3 macos/make-icon.py"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024

def base():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Apple's icon grid: an 824-point square, corners of about 185.
    box = (100, 100, 924, 924)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, 185, fill=255)
    fill = Image.new("RGBA", (S, S))
    fd = ImageDraw.Draw(fill)
    top, bottom = (0x2a, 0x26, 0x1e), (0x16, 0x14, 0x0f)
    for y in range(S):
        t = min(1, max(0, (y - 100) / 824))
        fd.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    img.paste(fill, (0, 0), mask)
    d.rounded_rectangle(box, 185, outline=(0x3a, 0x35, 0x2b, 255), width=4)
    return img, d

def draw(d):
    amber, text, muted, faint = (0xe8, 0xa3, 0x3d, 255), (0xed, 0xea, 0xe2, 255), (0x9a, 0x93, 0x84, 255), (0x5c, 0x56, 0x4b, 255)
    # The arrow coming down: a shaft and a head, the thing the app does.
    d.rounded_rectangle((482, 220, 542, 560), 30, fill=amber)
    d.polygon([(390, 520), (634, 520), (512, 660)], fill=amber)
    # The bar it lands in: the groove, and how much of it is filled.
    d.rounded_rectangle((250, 730, 774, 790), 30, fill=faint)
    d.rounded_rectangle((250, 730, 620, 790), 30, fill=text)
    # The head of the fill, so the bar reads as moving rather than as a rule.
    d.ellipse((586, 730, 646, 790), fill=amber)
    # Two hairlines above, the page it came from.
    d.rounded_rectangle((330, 150, 694, 178), 14, fill=muted)
    d.rounded_rectangle((420, 200, 604, 228), 14, fill=faint)

def icns(img, name):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                suffix = "" if scale == 1 else "@2x"
                img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}{suffix}.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, name)], check=True)

if __name__ == "__main__":
    img, d = base()
    draw(d)
    img.save(os.path.join(tempfile.gettempdir(), "nanodown-icon.png"))
    icns(img, "AppIcon.icns")
