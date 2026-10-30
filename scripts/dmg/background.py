#!/usr/bin/env python3
"""Draws the installer window background for the Glasstunnel DMG.

Writes background.png (660x400) and background@2x.png (1320x800) to the
directory given as the only argument. scripts/dmg/build-dmg.sh combines them
into the TIFF that Finder shows at either pixel density.

The layout must match scripts/dmg/settings.py: the app icon is centred at
(180, 172) and the Applications folder at (480, 172), both 112 points.
Three lines, like the ones entering the tunnel in the Glasstunnel mark, run
from the app to the folder and end in an arrowhead.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 660, 400
APP_X, FOLDER_X, ICON_Y = 180, 480, 172

PAPER_TOP = (247, 246, 244)
PAPER_BOTTOM = (236, 234, 230)
INK = (32, 29, 29)
MUTED = (107, 103, 99)
BLUE = (0, 122, 255)

FONT = "/System/Library/Fonts/SFNS.ttf"


def font(points, scale, weight):
    face = ImageFont.truetype(FONT, points * scale)
    # SF's axes are width, optical size, grade, weight.
    try:
        face.set_variation_by_axes([100, max(17, min(96, points)), 400, weight])
    except (OSError, ValueError):
        pass
    return face


def draw(scale):
    w, h = WIDTH * scale, HEIGHT * scale
    image = Image.new("RGB", (w, h))

    # Paper, a touch darker toward the bottom.
    gradient = ImageDraw.Draw(image)
    for y in range(h):
        t = y / (h - 1)
        gradient.line(
            [(0, y), (w, y)],
            fill=tuple(round(a + (b - a) * t) for a, b in zip(PAPER_TOP, PAPER_BOTTOM)),
        )

    # The three lines are drawn on their own layer so they can fade in from
    # the app icon toward the folder.
    lines = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    pen = ImageDraw.Draw(lines)
    stroke = round(3.5 * scale)
    start, end = (APP_X + 74) * scale, (FOLDER_X - 78) * scale
    # (vertical offset, start inset, end inset, opacity); the outer lines stop
    # short of the arrowhead's arms.
    for offset, inset, stop, alpha in ((-14, 22, 26, 0.45), (0, 0, 0, 1.0), (14, 34, 26, 0.45)):
        y = (ICON_Y + offset) * scale
        x0 = start + inset * scale
        x1 = end - stop * scale
        steps = 48
        for i in range(steps):
            a = x0 + (x1 - x0) * i / steps
            b = x0 + (x1 - x0) * (i + 1) / steps
            fade = 0.25 + 0.75 * (i / steps)
            pen.line([(a, y), (b, y)], fill=BLUE + (round(255 * alpha * fade),), width=stroke)
        cap = stroke / 2
        pen.ellipse([x0 - cap, y - cap, x0 + cap, y + cap], fill=BLUE + (round(255 * alpha * 0.25),))

    # Arrowhead on the middle line.
    tip = end + 10 * scale
    y = ICON_Y * scale
    arm = 12 * scale
    pen.line([(tip - arm, y - arm), (tip, y), (tip - arm, y + arm)], fill=BLUE + (255,), width=stroke, joint="curve")
    for x, yy in ((tip - arm, y - arm), (tip, y), (tip - arm, y + arm)):
        pen.ellipse([x - stroke / 2, yy - stroke / 2, x + stroke / 2, yy + stroke / 2], fill=BLUE + (255,))
    image.paste(lines, (0, 0), lines)

    text = ImageDraw.Draw(image)
    title = font(19, scale, 600)
    sub = font(13, scale, 400)
    text.text((w / 2, 296 * scale), "Drag Glasstunnel into Applications", font=title, fill=INK, anchor="mm")
    text.text(
        (w / 2, 324 * scale),
        "Then open it and sign in on your phone at app.glasstunnel.io",
        font=sub,
        fill=MUTED,
        anchor="mm",
    )
    return image


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    draw(1).save(out / "background.png", dpi=(72, 72))
    draw(2).save(out / "background@2x.png", dpi=(144, 144))


if __name__ == "__main__":
    main()
