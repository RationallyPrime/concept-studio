"""ConceptStudio's app icon artwork: the flower on its dark indigo plate, for Icon Composer.

    uv run --with pillow python scripts/make-app-icon.py app/Packaging/icon-art.png

writes app/Packaging/ConceptStudio.icon/Assets/artwork.png, the icon's one layer: a full-bleed
1024 square that macOS masks to its rounded square. The flower is screen-blended onto the plate,
so its black background disappears and its glow stays. build-app.sh compiles the .icon with
actool into the app's Assets.car; regenerate the fallback .icns for older macOS with the same
actool call (it writes ConceptStudio.icns beside Assets.car) and copy it to app/Packaging/.
"""

import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

S = 1024
FLOWER = 0.80  # share of the canvas the flower spans, clear of the rounded corners

art_path = Path(sys.argv[1])
out = Path(__file__).resolve().parents[1] / "app/Packaging/ConceptStudio.icon/Assets/artwork.png"

# Plate: near-black indigo with a soft glow under the flower.
plate = Image.new("RGB", (S, S), (9, 8, 22))
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse((S * 0.14, S * 0.14, S * 0.86, S * 0.86), fill=140)
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.12))
plate = Image.composite(Image.new("RGB", (S, S), (46, 30, 110)), plate, glow)

art = ImageEnhance.Contrast(Image.open(art_path).convert("RGB")).enhance(1.06)
side = int(S * FLOWER)
layer = Image.new("RGB", (S, S), (0, 0, 0))
layer.paste(art.resize((side, side), Image.LANCZOS), ((S - side) // 2, (S - side) // 2))
out.parent.mkdir(parents=True, exist_ok=True)
ImageChops.screen(plate, layer).save(out)
print(out)
