#!/usr/bin/env python3
"""Build a Tahoe-safe ATerminal icon: squircle-masked icns from a generated master."""

from pathlib import Path

from PIL import Image, ImageChops, ImageFilter

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def superellipse_mask(s: int, n: float = 5.0) -> Image.Image:
    """Apple-like squircle. n=5 is close to the macOS continuous-corner icon."""
    m = Image.new("L", (s, s), 0)
    px = m.load()
    c = (s - 1) / 2.0
    r = c
    for y in range(s):
        for x in range(s):
            u = abs(x - c) / r
            v = abs(y - c) / r
            if u**n + v**n <= 1.0:
                px[x, y] = 255
    # Slight blur then re-threshold for AA at large sizes.
    if s >= 64:
        m = m.filter(ImageFilter.GaussianBlur(radius=s / 512))
        m = m.point(lambda p: min(255, int(p * 1.15)))
    return m


def load_master(src: Path) -> Image.Image:
    im = Image.open(src).convert("RGBA")
    px = im.load()
    w, h = im.size
    # Knock out the off-white studio background in the corners.
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if r > 232 and g > 232 and b > 232:
                px[x, y] = (0, 0, 0, 0)
    alpha = im.split()[-1]
    bbox = alpha.getbbox()
    if not bbox:
        raise SystemExit("master has no opaque content")
    im = im.crop(bbox)
    # Scale the squircle face to fill 1024.
    im = im.resize((1024, 1024), Image.Resampling.LANCZOS)
    mask = superellipse_mask(1024)
    out = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    out.paste(im, (0, 0))
    out.putalpha(ImageChops.multiply(out.split()[-1], mask))
    return out


def main() -> None:
    root = Path(__file__).resolve().parent
    master = load_master(root / "icon-master.jpg")
    preview = root / "AppIcon-1024.png"
    master.save(preview)

    iconset = root / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for p in iconset.glob("*.png"):
        p.unlink()

    mapping = {
        16: ["icon_16x16.png"],
        32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: ["icon_32x32@2x.png"],
        128: ["icon_128x128.png"],
        256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"],
        1024: ["icon_512x512@2x.png"],
    }
    for s, names in mapping.items():
        im = master.resize((s, s), Image.Resampling.LANCZOS)
        # Re-apply mask at this size so 16/32px corners stay clean.
        im.putalpha(ImageChops.multiply(im.split()[-1], superellipse_mask(s)))
        for name in names:
            im.save(iconset / name)
    print(f"wrote {preview} and {iconset}")


if __name__ == "__main__":
    main()
