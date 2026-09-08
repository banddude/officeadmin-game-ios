#!/usr/bin/env python3
"""Generate the OfficeAdmin Game app icon (1024x1024, opaque, no alpha).

Soft sage/cream palette matching the game's warm stylized look: sage gradient
sky, rolling hill, cream lightning bolt with a soft shadow. Supersampled 4x
and downscaled for smooth edges. Output is RGB (altool rejects alpha).

Usage: python3 tools/make_app_icon.py [Assets.xcassets/AppIcon.appiconset]
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersample factor
SIZE = 1024

# Palette (soft sage / cream, echoes the world map's warm greens)
SAGE_TOP = (183, 205, 169)      # light warm sage
SAGE_BOTTOM = (143, 174, 136)   # deeper sage
HILL = (126, 156, 119)          # rolling hill silhouette
BOLT = (247, 241, 223)          # cream
SHADOW = (95, 122, 88)          # soft bolt shadow

# Classic zigzag bolt, roughly centered on the 1024 canvas
BOLT_POINTS = [
    (592, 148), (332, 586), (478, 586),
    (414, 876), (692, 428), (536, 428),
]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "Assets.xcassets/AppIcon.appiconset"
    import json, os
    os.makedirs(out_dir, exist_ok=True)
    n = SIZE * S

    # Vertical sage gradient
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        c = lerp(SAGE_TOP, SAGE_BOTTOM, y / (n - 1))
        for x in range(n):
            px[x, y] = c

    draw = ImageDraw.Draw(img)
    big = [tuple(v * S for v in p) for p in BOLT_POINTS]

    # Rolling hills along the bottom (drawn before the bolt so it sits "in" the land)
    draw.ellipse((-260 * S, 800 * S, 480 * S, 1240 * S), fill=HILL)
    draw.ellipse((420 * S, 830 * S, 1300 * S, 1290 * S), fill=lerp(HILL, SAGE_BOTTOM, 0.35))

    # Soft shadow under the bolt
    shadow = Image.new("RGB", (n, n), (0, 0, 0))
    ImageDraw.Draw(shadow).polygon(
        [(x + 14 * S, y + 20 * S) for x, y in big], fill=SHADOW)
    shadow = shadow.filter(ImageFilter.GaussianBlur(16 * S))
    img = Image.composite(Image.blend(img, shadow, 0.55), img,
                          shadow.convert("L").point(lambda v: min(255, v * 2)))

    # Cream bolt
    ImageDraw.Draw(img).polygon(big, fill=BOLT)

    img = img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    img.save(f"{out_dir}/AppIcon.png", optimize=True)

    with open(f"{out_dir}/Contents.json", "w") as f:
        json.dump({
            "images": [{
                "filename": "AppIcon.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }],
            "info": {"author": "xcode", "version": 1},
        }, f, indent=2)
        f.write("\n")
    print(f"wrote {out_dir}/AppIcon.png ({img.mode} {img.size}) + Contents.json")


if __name__ == "__main__":
    main()
