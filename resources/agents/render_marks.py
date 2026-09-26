#!/usr/bin/env python3
"""Rasterize the original agent marks. Not the vendor logos."""

from pathlib import Path

from PIL import Image, ImageDraw

DIR = Path(__file__).resolve().parent
SIZE = 64
BG = (28, 25, 22, 255)
INK = (196, 165, 116, 255)


def canvas():
    im = Image.new("RGBA", (SIZE, SIZE), BG)
    # squircle-ish mask via rounded paste
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=14, fill=255)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(im, mask=mask)
    return out


def save(name, draw_fn):
    im = canvas()
    draw_fn(ImageDraw.Draw(im))
    im.save(DIR / f"{name}.png")


def claude(d):
    d.arc((16, 14, 48, 50), 50, 310, fill=INK, width=6)


def grok(d):
    d.line((18, 44, 32, 16), fill=INK, width=6)
    d.line((32, 16, 46, 44), fill=INK, width=6)


def chatgpt(d):
    d.ellipse((18, 18, 46, 46), outline=INK, width=6)
    d.ellipse((28, 28, 36, 36), fill=INK)


def gemini(d):
    d.polygon([(32, 14), (46, 32), (32, 50), (18, 32)], outline=INK)
    d.line((32, 14, 46, 32), fill=INK, width=6)
    d.line((46, 32, 32, 50), fill=INK, width=6)
    d.line((32, 50, 18, 32), fill=INK, width=6)
    d.line((18, 32, 32, 14), fill=INK, width=6)


if __name__ == "__main__":
    save("claude", claude)
    save("grok", grok)
    save("chatgpt", chatgpt)
    save("gemini", gemini)
