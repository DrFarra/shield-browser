#!/usr/bin/env python3
"""Icono de Glint (1024x1024): un destello de cuatro puntas menta sobre casi negro.
Se dibuja a 4x y se reduce para suavizar los bordes."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "Glint/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
SS = 4
S = 1024 * SS


def cubic(p0, p1, p2, p3, n=90):
    pts = []
    for i in range(n + 1):
        t = i / n
        a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
                    a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return pts


def sparkle(cx, cy, r, pinch):
    """Estrella de cuatro puntas con lados cóncavos; pinch = cuánto se acercan los lados al centro."""
    tips = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    pts = []
    for i in range(4):
        a, b = tips[i], tips[(i + 1) % 4]
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        c = (cx + (mx - cx) * pinch, cy + (my - cy) * pinch)
        pts += cubic(a, c, c, b)[:-1]
    return [(x * SS, y * SS) for x, y in pts]


bg = Image.new("RGB", (S, S), (12, 14, 13))
# Halo muy suave detrás del destello
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse([(300 * SS, 300 * SS), (724 * SS, 724 * SS)], fill=70)
glow = glow.filter(ImageFilter.GaussianBlur(120 * SS))
bg.paste((70, 190, 150), (0, 0), glow)

draw = ImageDraw.Draw(bg)
draw.polygon(sparkle(492, 532, 300, 0.12), fill=(102, 230, 184))
draw.polygon(sparkle(748, 268, 92, 0.12), fill=(232, 255, 245))

bg.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("icono:", OUT)
