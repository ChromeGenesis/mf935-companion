"""MF935 Companion app icon generator.

Draws the brand mark — an amber wifi-tethering glyph (center dot +
two wave arcs) over the app's dark glass look — at 4096px supersample
and exports every target format:

  Android (adaptive, API 26+): drawable-nodpi/ic_launcher_background.png,
      mipmap-*/ic_launcher_foreground.png, mipmap-*/ic_launcher_monochrome.png
      (Android 13 themed icons), mipmap-anydpi-v26/*.xml
  Android (legacy, API < 26): mipmap-*/ic_launcher.png + ic_launcher_round.png
  Windows: windows/runner/resources/app_icon.ico (+ assets/tray_icon.ico)
  Masters: art/icon_master.png (1024, rounded), art/icon_512.png (Play Store)

Re-run after any brand tweak: python art/gen_icons.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'

# Design tokens (mirror lib/core/theme.dart).
AMBER_HI = (251, 191, 36)    # #FBBF24 accentText
AMBER = (245, 158, 11)       # #F59E0B accent
BG_TOP = (18, 18, 26)        # #12121A
BG_BOTTOM = (5, 5, 7)        # #050507
WHITE = (248, 250, 252)      # #F8FAFC textPrimary

S = 4096  # supersample canvas; everything is a fraction of this


def radial_glow(size: int, color, peak_alpha: int) -> Image.Image:
    """Center-bright radial fade tinted with [color], circular falloff."""
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    steps = 96
    half = size / 2
    for i in range(steps, 0, -1):
        r = half * i / steps
        a = int(peak_alpha * (1 - i / steps) ** 1.8)
        d.ellipse((half - r, half - r, half + r, half + r), fill=a)
    layer = Image.new('RGBA', (size, size), color + (0,))
    layer.putalpha(mask)
    return layer


def draw_glyph(canvas: Image.Image, color_dot, color_arc, with_glow: bool):
    """The tethering mark: dot + two arcs with round caps, y-centered."""
    d = ImageDraw.Draw(canvas)
    cx = cy = S / 2

    # Soft amber aura behind the dot so the mark feels lit, not painted.
    if with_glow:
        glow = radial_glow(int(S * 0.62), AMBER, 70)
        canvas.alpha_composite(
            glow, (int(cx - glow.width / 2), int(cy - glow.height / 2))
        )

    # Center dot with a top-left highlight (radial, amber_hi -> amber).
    dot_r = S * 0.082
    dot_size = (int(dot_r * 2), int(dot_r * 2))
    grad = ImageOps.invert(Image.radial_gradient('L')).resize(dot_size)
    dot = Image.composite(
        Image.new('RGBA', dot_size, AMBER_HI + (255,)),
        Image.new('RGBA', dot_size, AMBER + (255,)),
        grad,
    ).convert('RGBA')
    mask = Image.new('L', dot_size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, dot_size[0] - 1, dot_size[1] - 1), 255)
    canvas.paste(dot, (int(cx - dot_r), int(cy - dot_r)), mask)

    # Two wave arcs (top + bottom), squared-ends fixed by cap circles.
    arcs = [
        (S * 0.235, S * 0.036, 195, 345),
        (S * 0.375, S * 0.036, 15, 165),
    ]
    import math

    for radius, stroke, a0, a1 in arcs:
        bbox = (cx - radius, cy - radius, cx + radius, cy + radius)
        d.arc(bbox, start=a0, end=a1, fill=color_arc + (255,), width=int(stroke))
        for angle in (a0, a1):
            arad = math.radians(angle)
            ex = cx + radius * math.cos(arad)
            ey = cy + radius * math.sin(arad)
            r = stroke / 2
            d.ellipse((ex - r, ey - r, ex + r, ey + r), fill=color_arc + (255,))


def background_fullbleed() -> Image.Image:
    """Adaptive-icon background: edge-to-edge vertical gradient + glow."""
    grad = Image.linear_gradient('L').resize((S, S))
    img = Image.composite(
        Image.new('RGBA', (S, S), BG_BOTTOM + (255,)),
        Image.new('RGBA', (S, S), BG_TOP + (255,)),
        grad,
    ).convert('RGBA')
    # Ambient amber orb, upper-left like the app's AmbientBackground.
    orb = radial_glow(int(S * 0.9), AMBER, 34)
    img.alpha_composite(orb, (int(-S * 0.22), int(-S * 0.30)))
    return img


def legacy_icon(round_mask: bool) -> Image.Image:
    """Pre-26 launcher icon: baked rounded square + ring + glyph."""
    img = background_fullbleed()
    draw_glyph(img, AMBER, AMBER, with_glow=True)
    # Hairline inner ring, the glass-card border cue.
    inset = S * 0.045
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(
        (inset, inset, S - inset, S - inset),
        radius=S * 0.135,
        outline=AMBER + (44,),
        width=int(S * 0.006),
    )
    # Corner mask (rounded square or circle).
    mask = Image.new('L', (S, S), 0)
    md = ImageDraw.Draw(mask)
    if round_mask:
        md.ellipse((0, 0, S, S), 255)
    else:
        md.rounded_rectangle((0, 0, S, S), radius=S * 0.15, fill=255)
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def foreground() -> Image.Image:
    """Adaptive foreground: transparent, glyph inside the 66% safe zone."""
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    # Scale the glyph down into the safe zone by drawing onto a larger
    # virtual canvas: draw at S then shrink onto the foreground.
    tmp = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    draw_glyph(tmp, AMBER, AMBER, with_glow=False)
    scale = 0.80
    tmp = tmp.resize((int(S * scale), int(S * scale)), Image.LANCZOS)
    off = (S - tmp.width) // 2
    img.alpha_composite(tmp, (off, off))
    return img


def monochrome() -> Image.Image:
    """Android 13+ themed-icon layer: pure white glyph, no glow."""
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    draw_glyph(img, WHITE, WHITE, with_glow=False)
    return img


def save_png(img: Image.Image, path: Path, size: int | None = None):
    path.parent.mkdir(parents=True, exist_ok=True)
    out = img
    if size is not None and size != img.width:
        out = img.resize((size, size), Image.LANCZOS)
    out.save(path)
    print(f'  {path.relative_to(ROOT)}  {out.width}x{out.height}')


def save_ico(img: Image.Image, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(
        path,
        format='ICO',
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
               (128, 128), (256, 256)],
    )
    print(f'  {path.relative_to(ROOT)}  ico (16-256)')


def main():
    print('Rendering master…')
    legacy = legacy_icon(round_mask=False)
    round_icon = legacy_icon(round_mask=True)
    fg = foreground()
    mono = monochrome()
    bg = background_fullbleed()

    print('Android legacy + adaptive layers:')
    densities = {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
    }
    fg_sizes = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324,
                'xxxhdpi': 432}
    for dpi, px in densities.items():
        save_png(legacy, RES / f'mipmap-{dpi}' / 'ic_launcher.png', px)
        save_png(round_icon, RES / f'mipmap-{dpi}' / 'ic_launcher_round.png', px)
        save_png(fg, RES / f'mipmap-{dpi}' / 'ic_launcher_foreground.png',
                 fg_sizes[dpi])
        save_png(mono, RES / f'mipmap-{dpi}' / 'ic_launcher_monochrome.png',
                 fg_sizes[dpi])
    save_png(bg, RES / 'drawable-nodpi' / 'ic_launcher_background.png', 1024)

    anydpi = RES / 'mipmap-anydpi-v26'
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
"""
    (anydpi / 'ic_launcher.xml').write_text(adaptive)
    (anydpi / 'ic_launcher_round.xml').write_text(adaptive)
    print(f'  {anydpi.relative_to(ROOT)}/ic_launcher{{,_round}}.xml')

    print('Desktop:')
    save_ico(legacy, ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico')
    save_ico(legacy, ROOT / 'assets' / 'tray_icon.ico')

    print('Masters:')
    save_png(legacy, ROOT / 'art' / 'icon_master.png', 1024)
    save_png(legacy, ROOT / 'art' / 'icon_512.png', 512)
    print('Done.')


if __name__ == '__main__':
    main()
