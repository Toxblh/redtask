"""RedTask app icon: stack of two task cards, front card carries a check.
Renders light / dark / tinted 1024x1024 RGB (no alpha) PNGs into argv[1]."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096          # supersampled canvas
OUT = 1024
out_dir = sys.argv[1]


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def gradient(top, bottom):
    g = Image.new("RGB", (1, 256))
    for y in range(256):
        g.putpixel((0, y), lerp(top, bottom, y / 255))
    return g.resize((S, S), Image.BICUBIC)


def card(fill, angle, dx=0, dy=0, check=None):
    """A rounded card rotated by angle, optional check stroke in colour `check`."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    w, h = 0.50 * S, 0.56 * S
    x0, y0 = (S - w) / 2, (S - h) / 2
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=0.10 * S, fill=fill)
    if check:
        pts = [(0.385 * S, 0.515 * S), (0.465 * S, 0.595 * S), (0.625 * S, 0.420 * S)]
        sw = int(0.062 * S)
        d.line(pts, fill=check, width=sw, joint="curve")
        for p in (pts[0], pts[-1]):
            r = sw / 2
            d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=check)
    layer = layer.rotate(angle, resample=Image.BICUBIC, center=(S / 2, S / 2))
    if dx or dy:
        layer = layer.transform(layer.size, Image.AFFINE, (1, 0, -dx * S, 0, 1, -dy * S), resample=Image.BICUBIC)
    return layer


def shadow(layer, alpha=70):
    a = layer.getchannel("A").point(lambda v: v * alpha // 255)
    sh = Image.new("RGBA", layer.size, (60, 0, 10, 0))
    sh.putalpha(a)
    sh = sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, -0.012 * S))
    return sh.filter(ImageFilter.GaussianBlur(0.02 * S))


def render(bg, back, front, check, name):
    img = bg.convert("RGBA")
    b = card(back, -10, dx=0.035, dy=-0.035)
    f = card(front, 6, dx=-0.015, dy=0.025, check=check)
    img.alpha_composite(b)
    img.alpha_composite(shadow(f))
    img.alpha_composite(f)
    img.convert("RGB").resize((OUT, OUT), Image.LANCZOS).save(f"{out_dir}/{name}", optimize=True)


RED = (226, 40, 46)
render(gradient((240, 84, 72), (176, 18, 40)), (255, 255, 255, 105), (255, 255, 255, 255), RED, "icon-1024.png")
render(gradient((44, 30, 34), (18, 12, 14)), (226, 40, 46, 120), (238, 64, 62, 255), (255, 255, 255, 255), "icon-1024-dark.png")
# tinted: grayscale on black, system applies the tint
render(gradient((0, 0, 0), (0, 0, 0)), (255, 255, 255, 90), (255, 255, 255, 255), (0, 0, 0, 255), "icon-1024-tinted.png")
