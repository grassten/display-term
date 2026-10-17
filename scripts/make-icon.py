#!/usr/bin/env python3
"""Draws the app icon: a Studio Display-shaped terminal showing a green `>_` prompt.

Writes Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024x1024, no alpha).
Needs Pillow (`pip3 install pillow`). Re-run after changing anything below.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
FONT = ROOT / "Sources/Resources/Fonts/JetBrainsMonoNerdFontMono-Bold.ttf"

S = 4          # supersample factor
N = 1024 * S   # canvas size


def px(v):
    return int(v * S)


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        grad.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return grad.resize((w, h))


# Background: graphite, lighter at the top (iOS masks the corners itself).
img = vertical_gradient((N, N), (58, 58, 64), (18, 18, 22))
draw = ImageDraw.Draw(img)

# Display geometry (Studio Display proportions: 16:9 panel, thin even bezel, slim stand).
body = (px(132), px(214), px(892), px(676))     # aluminium frame
bezel = px(22)
screen = (body[0] + bezel, body[1] + bezel, body[2] - bezel, body[3] - bezel)
neck = (px(452), body[3] - px(4), px(572), px(800))
foot = (px(352), px(792), px(672), px(826))

# Soft shadow under the whole display.
shadow = Image.new("L", (N, N), 0)
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle((body[0], body[1] + px(18), body[2], body[3] + px(18)), radius=px(40), fill=150)
sd.rounded_rectangle((foot[0], foot[1] + px(10), foot[2], foot[3] + px(14)), radius=px(16), fill=120)
shadow = shadow.filter(ImageFilter.GaussianBlur(px(22)))
img.paste((0, 0, 0), mask=shadow)
draw = ImageDraw.Draw(img)

# Stand: neck then foot, silver.
draw.rectangle(neck, fill=(150, 152, 158))
draw.rounded_rectangle(foot, radius=px(16), fill=(196, 198, 204))
draw.rectangle((foot[0] + px(16), foot[1], foot[2] - px(16), foot[1] + px(4)), fill=(225, 226, 230))

# Frame: silver with a light top edge.
frame = vertical_gradient((body[2] - body[0], body[3] - body[1]), (214, 216, 222), (160, 162, 168))
mask = Image.new("L", frame.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, *frame.size), radius=px(36), fill=255)
img.paste(frame, body[:2], mask)

# Screen: near-black with a faint top glow.
scr = vertical_gradient((screen[2] - screen[0], screen[3] - screen[1]), (30, 32, 36), (12, 12, 14))
mask = Image.new("L", scr.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, *scr.size), radius=px(16), fill=255)
img.paste(scr, screen[:2], mask)
draw = ImageDraw.Draw(img)

# Prompt: `>_` in terminal green, with a glow, the `_` drawn as a block-ish cursor bar.
green = (52, 199, 89)
font = ImageFont.truetype(str(FONT), px(300))
glow = Image.new("L", (N, N), 0)
gd = ImageDraw.Draw(glow)

chevron = ">"
left, top, right, bottom = font.getbbox(chevron)
bar_h = px(40)
group_h = bottom - top
sx = screen[0] + px(84) - left
sy = (screen[1] + screen[3]) // 2 - group_h // 2 - top
gd.text((sx, sy), chevron, font=font, fill=255)
cx = sx + right + px(26)
cursor = (cx, sy + bottom - bar_h, cx + px(170), sy + bottom)
gd.rectangle(cursor, fill=255)

halo = glow.filter(ImageFilter.GaussianBlur(px(18))).point(lambda v: int(v * 0.55))
img.paste(green, mask=halo)
img.paste(green, mask=glow)

img = img.resize((1024, 1024), Image.LANCZOS)
OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT)
print(OUT)
