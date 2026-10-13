#!/usr/bin/env python3
"""Renders Upright's app icon into Upright/Assets.xcassets/AppIcon.appiconset.

Requires Pillow (`pip install pillow`). Run from the repository root:

    python3 scripts/make_icon.py
"""
import json
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SCALE = 2
SIZE = 1024 * SCALE
OUT = os.path.join(os.path.dirname(__file__), "..", "Upright", "Assets.xcassets", "AppIcon.appiconset")


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def vertical_gradient(size, top, bottom):
    gradient = Image.new("RGBA", (1, size[1]))
    for y in range(size[1]):
        gradient.putpixel((0, y), lerp(top, bottom, y / (size[1] - 1)))
    return gradient.resize(size)


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def render():
    s = SCALE
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # macOS icon grid: an 824 pt squircle centered in 1024 pt, with a soft drop shadow.
    box = (100 * s, 92 * s, 924 * s, 916 * s)
    radius = 186 * s
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 14 * s, box[2], box[3] + 14 * s), radius=radius, fill=(0, 0, 0, 90))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * s)))

    tile_mask = rounded_mask((SIZE, SIZE), box, radius)
    tile = vertical_gradient((SIZE, SIZE), (64, 156, 255, 255), (88, 64, 230, 255))
    sheen_height = (box[3] - box[1]) * 3 // 5
    sheen = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sheen.paste(vertical_gradient((SIZE, sheen_height), (255, 255, 255, 56), (255, 255, 255, 0)), (0, box[1]))
    tile.alpha_composite(sheen)
    canvas.paste(tile, (0, 0), tile_mask)

    # An upright mouse, tilted slightly like the MX Vertical.
    mouse = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(mouse)
    body = (352 * s, 238 * s, 672 * s, 792 * s)
    d.rounded_rectangle(body, radius=160 * s, fill=(255, 255, 255, 255))
    # Button split and scroll wheel.
    d.line((512 * s, 250 * s, 512 * s, 430 * s), fill=(196, 206, 238, 255), width=10 * s)
    d.line((360 * s, 438 * s, 664 * s, 438 * s), fill=(196, 206, 238, 255), width=10 * s)
    d.rounded_rectangle((490 * s, 300 * s, 534 * s, 392 * s), radius=22 * s, fill=(86, 112, 240, 255))
    # Thumb buttons on the side.
    d.rounded_rectangle((330 * s, 500 * s, 368 * s, 570 * s), radius=18 * s, fill=(222, 228, 248, 255))
    d.rounded_rectangle((330 * s, 588 * s, 368 * s, 658 * s), radius=18 * s, fill=(222, 228, 248, 255))
    mouse = mouse.rotate(-14, resample=Image.BICUBIC, center=(512 * s, 520 * s))

    mouse_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mouse_shadow.putalpha(ImageChops.multiply(mouse.getchannel("A"), Image.new("L", (SIZE, SIZE), 80)))
    mouse_shadow = mouse_shadow.transform((SIZE, SIZE), Image.AFFINE, (1, 0, 0, 0, 1, -18 * s)).filter(ImageFilter.GaussianBlur(20 * s))
    clipped = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    clipped.paste(mouse_shadow, (0, 0), ImageChops.multiply(mouse_shadow.getchannel("A"), tile_mask))
    canvas.alpha_composite(clipped)
    canvas.alpha_composite(mouse)

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    master = render()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(OUT, name), optimize=True)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    with open(os.path.join(OUT, "Contents.json"), "w") as fh:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, fh, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
