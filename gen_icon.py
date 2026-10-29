"""Generate ThandoSign launcher icons (adaptive + legacy)."""
import os
from PIL import Image, ImageDraw

RES = r"C:\Users\tanak\OneDrive\Desktop\Thando Project\thando_sign_app\android\app\src\main\res"
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
FORE_SIZES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

NAVY_TOP = (15, 23, 42)     # #0F172A
NAVY_BOT = (30, 41, 59)     # #1E293B
TEAL = (13, 148, 136)       # #0D9488
BLUE = (37, 99, 235)        # #2563EB
WHITE = (255, 255, 255)


def vgrad(size, top, bottom):
    img = Image.new("RGBA", (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(size):
            px[x, y] = c
    return img


def draw_hand(canvas, scale=1.0):
    """Draw a stylized open hand (palm + 4 fingers + thumb) centred on canvas."""
    d = ImageDraw.Draw(canvas)
    w, h = canvas.size
    u = w / 432.0 * scale  # unit relative to 432 design size

    cx = w / 2
    # fingers (rounded bars)
    finger_w = 34 * u
    gap = 12 * u
    heights = [150 * u, 185 * u, 200 * u, 170 * u]
    tops = [200 * u, 165 * u, 150 * u, 180 * u]
    start_x = cx - (4 * finger_w + 3 * gap) / 2
    for i in range(4):
        x0 = start_x + i * (finger_w + gap)
        x1 = x0 + finger_w
        y0 = tops[i]
        y1 = y0 + heights[i]
        d.rounded_rectangle([x0, y0, x1, y1], radius=finger_w / 2, fill=WHITE)
    # palm
    d.rounded_rectangle(
        [start_x - 10 * u, 320 * u, start_x + 4 * finger_w + 3 * gap + 10 * u, 420 * u],
        radius=48 * u,
        fill=WHITE,
    )
    # thumb (left diagonal bar)
    thumb = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    td = ImageDraw.Draw(thumb)
    td.rounded_rectangle(
        [start_x - 90 * u, 300 * u, start_x - 10 * u, 380 * u],
        radius=40 * u,
        fill=WHITE,
    )
    thumb = thumb.rotate(-35, center=(start_x - 50 * u, 340 * u))
    canvas.alpha_composite(thumb)


def make_base(size):
    """Full square icon: dark bg + teal rounded plate + white hand."""
    img = vgrad(size, NAVY_TOP, NAVY_BOT)
    # teal plate
    plate = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pd = ImageDraw.Draw(plate)
    margin = size * 0.12
    pd.rounded_rectangle([margin, margin, size - margin, size - margin],
                         radius=size * 0.22, fill=TEAL)
    # subtle diagonal highlight on plate
    hl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hl)
    hd.polygon([(margin, size - margin), (size - margin, margin), (size - margin, size - margin)],
               fill=tuple(list(BLUE) + [110]))
    plate.alpha_composite(Image.composite(hl, Image.new("RGBA", (size, size)), plate.split()[3]))
    img.alpha_composite(plate)
    draw_hand(img)
    return img


def circle_mask(size):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([0, 0, size, size], fill=255)
    return m


def main():
    # Legacy + round icons
    for name, px in SIZES.items():
        base = make_base(px)
        out_dir = os.path.join(RES, f"mipmap-{name}")
        base.save(os.path.join(out_dir, "ic_launcher.png"))

        round_img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        round_img.paste(base, (0, 0), circle_mask(px))
        round_img.save(os.path.join(out_dir, "ic_launcher_round.png"))

    # Adaptive foreground (hand on transparent, safe-zone aware)
    for name, px in FORE_SIZES.items():
        fg = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        draw_hand(fg, scale=0.62)
        # recentre the drawing (hand drawn in 432-space; scale factor shifts it)
        out_dir = os.path.join(RES, f"mipmap-{name}")
        fg.save(os.path.join(out_dir, "ic_launcher_foreground.png"))

    # Adaptive icon XML
    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
"""
    for f in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, f), "w") as fh:
            fh.write(xml)

    # Background color
    colors_path = os.path.join(RES, "values", "colors.xml")
    existing = open(colors_path).read() if os.path.exists(colors_path) else ""
    if "ic_launcher_background" not in existing:
        with open(colors_path, "w") as fh:
            fh.write("""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#0D9488</color>
</resources>
""")

    print("Icons generated.")


if __name__ == "__main__":
    main()
