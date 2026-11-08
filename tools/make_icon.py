#!/usr/bin/env python3
"""Genera el icono de la app (1024x1024) en el asset catalog.

Escudo de curvas suaves con la mitad izquierda sólida (el mismo motivo que el
botón de escudos de la barra), sobre un degradado ámbar. Se dibuja a 4x y se
reduce para que los bordes salgan suavizados.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "Shield/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
SS = 4
S = 1024 * SS


def cubic(p0, p1, p2, p3, n=80):
    pts = []
    for i in range(n + 1):
        t = i / n
        a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
                    a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return pts


def half(sign):
    """Contorno de media silueta (sign=+1 derecha, -1 izquierda), de arriba a la punta."""
    m = lambda x, y: ((512 + sign * (x - 512)) * SS, y * SS)
    pts = cubic(m(512, 176), m(596, 232), m(690, 258), m(764, 258))
    pts += cubic(m(764, 258), m(770, 380), m(768, 470), m(752, 548))[1:]
    pts += cubic(m(752, 548), m(724, 700), m(626, 800), m(512, 868))[1:]
    return pts


right = half(1)
left = half(-1)
shield = right + list(reversed(left))[1:]

# Fondo: degradado diagonal ámbar → naranja intenso
top, bottom = (255, 150, 62), (222, 62, 22)
small = Image.new("RGB", (64, 64))
for y in range(64):
    for x in range(64):
        t = (x * 0.35 + y * 0.65) / 63
        small.putpixel((x, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
bg = small.resize((S, S), Image.BILINEAR)

# Sombra suave bajo el escudo
shadow = Image.new("L", (S, S), 0)
ImageDraw.Draw(shadow).polygon([(x, y + 22 * SS) for x, y in shield], fill=90)
shadow = shadow.filter(ImageFilter.GaussianBlur(28 * SS))
bg.paste((120, 30, 0), (0, 0), shadow)

# Escudo: mitad derecha en tono claro, mitad izquierda blanca
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw = ImageDraw.Draw(layer)
draw.polygon(shield, fill=(255, 216, 192, 255))
draw.polygon(list(reversed(left)) + [(512 * SS, 176 * SS)], fill=(255, 255, 255, 255))
bg = Image.alpha_composite(bg.convert("RGBA"), layer).convert("RGB")

bg.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("Icono:", OUT)
