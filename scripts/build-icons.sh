#!/usr/bin/env bash
# Crop/center docs/characters/talku.jpg → Resources app icon + README banner.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 << 'PY'
from pathlib import Path
from PIL import Image

img = Image.open("docs/characters/talku.jpg").convert("RGBA")
w, h = img.size
px = img.load()
corners = [px[2, 2][:3], px[w - 3, 2][:3], px[2, h - 3][:3], px[w - 3, h - 3][:3]]
br = sum(c[0] for c in corners) // 4
bg = sum(c[1] for c in corners) // 4
bb = sum(c[2] for c in corners) // 4

def is_bg(x, y, thr=22):
    r, g, b, a = px[x, y]
    if a < 12:
        return True
    return abs(r - br) < thr and abs(g - bg) < thr and abs(b - bb) < thr

for y in range(h):
    for x in range(w):
        if is_bg(x, y):
            px[x, y] = (255, 255, 255, 0)

min_x, min_y, max_x, max_y = w, h, 0, 0
found = 0
for y in range(h):
    for x in range(w):
        if px[x, y][3] > 12:
            found += 1
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
if found < 100:
    min_x, min_y, max_x, max_y = 0, 0, w - 1, h - 1
pad = max(4, int(min(w, h) * 0.02))
cropped = img.crop((max(0, min_x - pad), max(0, min_y - pad), min(w, max_x + 1 + pad), min(h, max_y + 1 + pad)))

def square_pad(im, size, bg=(255, 255, 255, 255), scale=0.90):
    canvas = Image.new("RGBA", (size, size), bg)
    target = int(size * scale)
    ratio = min(target / im.width, target / im.height)
    nw = max(1, int(im.width * ratio))
    nh = max(1, int(im.height * ratio))
    resized = im.resize((nw, nh), Image.Resampling.LANCZOS)
    canvas.paste(resized, ((size - nw) // 2, (size - nh) // 2), resized)
    return canvas

def to_rgb(im, bg=(255, 255, 255)):
    o = Image.new("RGB", im.size, bg)
    o.paste(im, mask=im.split()[3])
    return o

out = Path("Resources")
out.mkdir(exist_ok=True)
chars = Path("docs/characters")

to_rgb(square_pad(cropped, 1024, scale=0.90)).save(out / "AppIcon-1024.png", "PNG")
to_rgb(square_pad(cropped, 1024, scale=0.92)).save(chars / "talku-appicon.jpg", "JPEG", quality=93)

bw, bh = 1920, 640
banner = Image.new("RGBA", (bw, bh), (255, 255, 255, 255))
target_h = int(bh * 0.88)
ratio = target_h / cropped.height
nw = int(cropped.width * ratio)
nh = target_h
char = cropped.resize((nw, nh), Image.Resampling.LANCZOS)
banner.paste(char, ((bw - nw) // 2, (bh - nh) // 2), char)
to_rgb(banner).save(chars / "talku-banner.jpg", "JPEG", quality=94)
print(f"cropped {cropped.size} → Resources + docs/characters")
PY

ICONSET=Resources/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
MASTER=Resources/AppIcon-1024.png
for spec in \
  "16:icon_16x16.png" \
  "32:diana.l@example.org" \
  "32:icon_32x32.png" \
  "64:ivan.p@example.net" \
  "128:icon_128x128.png" \
  "256:wendy.h@example.net" \
  "256:icon_256x256.png" \
  "512:wendy.h@example.net" \
  "512:icon_512x512.png" \
  "1024:walt.e@example.net"
do
  size=${spec%%:*}
  name=${spec##*:}
  sips -s format png -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"
echo "Wrote Resources/AppIcon.icns"
