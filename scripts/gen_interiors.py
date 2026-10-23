#!/usr/bin/env python3
"""Paints the building interior backdrops (assets/interiors/<name>.png).

Placeholder art: flat shapes, gradients and glows, standard library only. Run from the
repository root: python3 scripts/gen_interiors.py
"""
import math
import os
import random
import struct
import zlib

W, H = 960, 540


class Canvas:
    def __init__(self):
        self.px = [[0.0, 0.0, 0.0] for _ in range(W * H)]

    def blend(self, x, y, c, a):
        if 0 <= x < W and 0 <= y < H and a > 0:
            p = self.px[y * W + x]
            a = min(a, 1.0)
            p[0] += (c[0] - p[0]) * a
            p[1] += (c[1] - p[1]) * a
            p[2] += (c[2] - p[2]) * a

    def vgrad(self, x0, y0, x1, y1, top, bot):
        for y in range(max(0, y0), min(H, y1)):
            t = (y - y0) / max(1, y1 - y0 - 1)
            c = [top[i] + (bot[i] - top[i]) * t for i in range(3)]
            for x in range(max(0, x0), min(W, x1)):
                self.px[y * W + x] = list(c)

    def rect(self, x0, y0, x1, y1, c, a=1.0):
        for y in range(max(0, int(y0)), min(H, int(y1))):
            for x in range(max(0, int(x0)), min(W, int(x1))):
                self.blend(x, y, c, a)

    def poly(self, pts, c, a=1.0):
        ys = [p[1] for p in pts]
        for y in range(max(0, int(min(ys))), min(H, int(max(ys)) + 1)):
            xs = []
            for i in range(len(pts)):
                (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
                if (y0 <= y < y1) or (y1 <= y < y0):
                    xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                for x in range(max(0, int(xs[k])), min(W, int(xs[k + 1]) + 1)):
                    self.blend(x, y, c, a)

    def ellipse(self, cx, cy, rx, ry, c, a=1.0):
        for y in range(max(0, int(cy - ry)), min(H, int(cy + ry) + 1)):
            for x in range(max(0, int(cx - rx)), min(W, int(cx + rx) + 1)):
                d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
                if d <= 1:
                    self.blend(x, y, c, a * min(1.0, (1 - d) * 6))

    def glow(self, cx, cy, r, c, a):
        for y in range(max(0, int(cy - r)), min(H, int(cy + r) + 1)):
            for x in range(max(0, int(cx - r)), min(W, int(cx + r) + 1)):
                d = math.hypot(x - cx, y - cy) / r
                if d < 1:
                    self.blend(x, y, c, a * (1 - d) ** 2)

    def line(self, x0, y0, x1, y1, w, c, a=1.0):
        n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
        for i in range(n):
            t = i / max(1, n - 1)
            self.ellipse(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, w, w, c, a)

    def vignette(self, k=0.55):
        for y in range(H):
            for x in range(W):
                d = math.hypot((x - W / 2) / (W / 2), (y - H / 2) / (H / 2))
                f = 1 - k * max(0.0, d - 0.45) ** 1.5
                p = self.px[y * W + x]
                p[0] *= f
                p[1] *= f
                p[2] *= f

    def save(self, path):
        raw = bytearray()
        for y in range(H):
            raw.append(0)
            for x in range(W):
                p = self.px[y * W + x]
                raw.extend(max(0, min(255, int(v * 255))) for v in p)

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
        with open(path, "wb") as f:
            f.write(png)


def rgb(h):
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def planks(c, y0, base, rng):
    """A wooden floor from y0 down, boards converging to the back."""
    c.vgrad(0, y0, W, H, [v * 0.6 for v in base], base)
    for k in range(-12, 13):
        c.line(W / 2 + k * 18, y0, W / 2 + k * 95, H, 1, [v * 0.55 for v in base], 0.6)
    for y in range(y0 + 12, H, 26):
        c.rect(0, y, W, y + 1, [v * 0.7 for v in base], 0.35)


def beams(c, col, n=3):
    for i in range(n):
        y = 30 + i * 46
        c.rect(0, y, W, y + 18, col)
        c.rect(0, y + 18, W, y + 22, [v * 0.5 for v in col])


def smithy(rng):
    c = Canvas()
    c.vgrad(0, 0, W, 360, rgb("2a1a14"), rgb("4a2e22"))
    for y in range(120, 360, 22):  # brick courses
        off = 0 if (y // 22) % 2 else 30
        for x in range(-60 + off, W, 60):
            c.rect(x + 2, y + 2, x + 58, y + 20, rgb("5a3526"), 0.5 + rng.random() * 0.3)
    beams(c, rgb("2b1a10"), 2)
    planks(c, 360, rgb("3a2a20"), rng)
    # Forge: stone hearth with coals and a hood.
    c.poly([(90, 150), (330, 150), (290, 250), (130, 250)], rgb("3a302c"))
    c.rect(100, 250, 320, 380, rgb("4c403a"))
    c.rect(120, 290, 300, 330, rgb("1a0c06"))
    for _ in range(140):
        c.ellipse(rng.uniform(125, 295), rng.uniform(300, 328), 5, 3, rgb("ff8a2a"), 0.8)
    c.glow(210, 310, 260, rgb("ff7a20"), 0.55)
    c.glow(210, 310, 90, rgb("ffd070"), 0.6)
    # Anvil.
    c.poly([(400, 380), (520, 380), (500, 400), (420, 400)], rgb("2c2c30"))
    c.rect(440, 400, 480, 450, rgb("2c2c30"))
    c.rect(415, 450, 505, 465, rgb("26262a"))
    # Tools on the wall.
    for i, x in enumerate(range(380, 620, 40)):
        c.line(x, 140, x, 230 + (i % 3) * 20, 2, rgb("6a6a70"))
        c.rect(x - 8, 128, x + 8, 140, rgb("3a2a1c"))
    c.vignette()
    return c


def temple(rng):
    c = Canvas()
    c.vgrad(0, 0, W, 380, rgb("3a1010"), rgb("6a2418"))
    beams(c, rgb("5a1a10"), 2)
    c.vgrad(0, 380, W, H, rgb("4a3a30"), rgb("6a5848"))
    for y in range(392, H, 30):
        c.rect(0, y, W, y + 2, rgb("3a2c24"), 0.6)
    # Altar and statue.
    c.rect(300, 300, 660, 400, rgb("7a2a18"))
    c.rect(290, 290, 670, 304, rgb("c89a40"))
    c.poly([(400, 290), (560, 290), (530, 170), (430, 170)], rgb("6a7068"))
    c.ellipse(480, 145, 42, 48, rgb("7a8078"))
    c.glow(480, 160, 220, rgb("ffd890"), 0.35)
    for x in (340, 420, 540, 620):  # offerings and candles
        c.ellipse(x, 285, 18, 9, rgb("e8a040"))
        c.rect(x - 3, 250, x + 3, 280, rgb("f0e0c0"))
        c.glow(x, 246, 30, rgb("ffe0a0"), 0.8)
    # Pillars and lanterns.
    for x in (80, 220, 740, 880):
        c.rect(x - 22, 90, x + 22, 420, rgb("a02418"))
        c.rect(x - 22, 90, x - 12, 420, rgb("c0402c"), 0.6)
        c.rect(x - 28, 410, x + 28, 430, rgb("3a2a20"))
    for x in (150, 810):
        c.line(x, 90, x, 130, 1, rgb("2a1a10"))
        c.ellipse(x, 160, 26, 32, rgb("e04020"))
        c.glow(x, 160, 90, rgb("ff8040"), 0.5)
    for _ in range(40):  # incense haze
        c.glow(rng.uniform(300, 660), rng.uniform(40, 260), rng.uniform(40, 90), rgb("d8c8b8"), 0.06)
    c.vignette()
    return c


def home(rng):
    c = Canvas()
    c.vgrad(0, 0, W, 370, rgb("6a5034"), rgb("8a6a48"))
    beams(c, rgb("3a2814"), 2)
    planks(c, 370, rgb("6a5038"), rng)
    # Bamboo window with daylight.
    c.rect(560, 130, 780, 290, rgb("d8f0ff"))
    c.glow(670, 210, 260, rgb("fff4d0"), 0.3)
    for x in range(560, 790, 24):
        c.rect(x, 130, x + 6, 290, rgb("8a7038"))
    c.rect(550, 120, 790, 132, rgb("4a3418"))
    c.rect(550, 288, 790, 300, rgb("4a3418"))
    for k in range(6):  # light shaft on the floor
        c.poly([(560, 290), (780, 290), (900 - k * 6, H), (520 + k * 6, H)], rgb("fff0c0"), 0.03)
    # Hearth.
    c.ellipse(220, 420, 120, 34, rgb("3a3028"))
    c.ellipse(220, 414, 90, 22, rgb("1a100a"))
    for _ in range(50):
        c.ellipse(rng.uniform(150, 290), rng.uniform(404, 422), 5, 3, rgb("ff8030"), 0.8)
    c.glow(220, 410, 200, rgb("ff9040"), 0.4)
    c.line(220, 300, 220, 390, 2, rgb("2a2018"))
    c.ellipse(220, 380, 40, 18, rgb("2a2622"))
    # Rolled mats and the buffalo toy.
    for i in range(3):
        c.ellipse(80 + i * 10, 300 - i * 34, 60, 17, rgb("c8a868"))
    c.ellipse(470, 470, 30, 16, rgb("5a4a3a"))
    c.ellipse(500, 460, 12, 10, rgb("5a4a3a"))
    c.vignette()
    return c


def hall(rng):
    c = Canvas()
    c.vgrad(0, 0, W, 330, rgb("2a1c14"), rgb("4a3020"))
    planks(c, 330, rgb("5a3a24"), rng)
    # Back wall with a carved panel.
    c.rect(330, 150, 630, 320, rgb("3a2416"))
    c.rect(350, 170, 610, 300, rgb("5a2a18"))
    c.glow(480, 235, 140, rgb("e0a050"), 0.25)
    # Dragon beam: a gold wave across the top.
    for i in range(W):
        y = 70 + 16 * math.sin(i / 38.0) + 6 * math.sin(i / 11.0)
        c.ellipse(i, y, 3, 6, rgb("d8a840"))
    c.rect(0, 40, W, 50, rgb("2a1a0e"))
    c.rect(0, 100, W, 110, rgb("2a1a0e"))
    # Rows of pillars receding to the back.
    for side in (-1, 1):
        for k in range(5):
            s = 1 - k * 0.17
            x = W / 2 + side * (110 + 360 * s)
            w = 26 * s
            c.rect(x - w, 110, x + w, 330 + 210 * s * 0.6, rgb("8a2014"))
            c.rect(x - w, 110, x - w * 0.4, 330 + 210 * s * 0.6, rgb("b03a24"), 0.5)
    # Long council tables.
    for k, y in enumerate((380, 450)):
        c.poly([(260 - k * 60, y), (700 + k * 60, y), (720 + k * 70, y + 26), (240 - k * 70, y + 26)], rgb("6a4224"))
    c.vignette()
    return c


def market(rng):
    c = Canvas()
    c.vgrad(0, 0, W, 320, rgb("c8dce8"), rgb("e8e0c8"))
    # The roof's underside and posts.
    c.poly([(0, 0), (W, 0), (W, 70), (0, 120)], rgb("5a3a20"))
    for x in range(0, W, 48):
        c.line(x, 0, x + 30, 110 - x * 0.05, 2, rgb("3a2410"))
    c.vgrad(0, 320, W, H, rgb("9a8460"), rgb("7a6448"))
    # Shuttered stalls with striped awnings.
    stripes = [rgb("c04030"), rgb("e8d8b0")]
    for i, x in enumerate((40, 300, 620)):
        w = 260
        c.rect(x, 200, x + w, 360, rgb("6a4a2a"))
        for k in range(0, w, 12):
            c.rect(x + k, 210, x + k + 10, 350, rgb("8a6438"), 0.8)
        for k in range(10):
            c.poly([(x - 10 + k * 28, 150), (x + 18 + k * 28, 150), (x + 22 + k * 28, 205), (x - 6 + k * 28, 205)],
                   stripes[(k + i) % 2])
        c.rect(x - 10, 360, x + w + 10, 380, rgb("4a3018"))
    # Stacked, covered baskets.
    for _ in range(14):
        bx, by = rng.uniform(60, 900), rng.uniform(400, 500)
        r = rng.uniform(24, 40)
        c.ellipse(bx, by, r, r * 0.7, rgb("a8844a"))
        c.ellipse(bx, by - r * 0.5, r * 0.95, r * 0.25, rgb("d8c8a0"))
    c.glow(480, 140, 500, rgb("fff8e0"), 0.15)
    c.vignette(0.4)
    return c


def main():
    out = os.path.join("assets", "interiors")
    os.makedirs(out, exist_ok=True)
    for name, fn in (("smithy", smithy), ("temple", temple), ("home", home), ("hall", hall), ("market", market)):
        fn(random.Random(name)).save(os.path.join(out, name + ".png"))
        print("wrote", os.path.join(out, name + ".png"))


if __name__ == "__main__":
    main()
