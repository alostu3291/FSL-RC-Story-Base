#!/usr/bin/env python3
"""Build the Verdant Pest Care brand kit for the pest demo.

Writes SVG sources to scripts/brand/verdant/, renders PNGs with headless Chrome,
and copies the PNGs the demo uses:
    scripts/docgen/assets/verdant_logo_white.png   DocGen header (on the Forest band)
    scripts/docgen/assets/verdant_logo_color.png   DocGen on light backgrounds
    unpackaged/post_pest_brand/contentassets/      Lightning theme logo (600x120 PNG)

Usage:
    python scripts/brand/build_verdant_assets.py

The wordmark uses Avenir Next (macOS); the PNGs are the deliverables, the SVGs
render with a fallback sans font where Avenir Next isn't installed.
"""
import io
import os
import shutil
import subprocess
import tempfile

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
KIT = os.path.join(ROOT, "scripts", "brand", "verdant")
DOCGEN_ASSETS = os.path.join(ROOT, "scripts", "docgen", "assets")
THEME_ASSETS = os.path.join(ROOT, "unpackaged", "post_pest_brand", "contentassets")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

FOREST, LEAF, SAGE, CREAM, SUN = "#1F4D3A", "#3FA34D", "#A8C69F", "#F6F4EC", "#F2B33D"
FONT = "'Avenir Next', 'Helvetica Neue', Arial, sans-serif"
THEME_LOGO = "RLM_verdant_logo"
THEME_SIZE = (600, 120)


def mark(rev=False):
    shield = CREAM if rev else FOREST
    rib = FOREST if rev else CREAM
    return f'''<path d="M50 5 L88 18 V47 C88 71 71 88 50 96 C29 88 12 71 12 47 V18 Z" fill="{shield}"/>
<path d="M50 24 C70 32 74 56 50 79 C30 62 30 38 50 24 Z" fill="{LEAF}"/>
<path d="M50 30 C47 46 47 62 50 76" stroke="{rib}" stroke-width="3" fill="none" stroke-linecap="round"/>
<path d="M49 48 L60 40 M49 60 L61 53 M49 54 L39 46" stroke="{rib}" stroke-width="2.4" fill="none" stroke-linecap="round"/>
<circle cx="73" cy="27" r="6" fill="{SUN}"/>'''


def mark_svg(rev=False):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">{mark(rev)}</svg>\n'


def logo_svg(rev=False):
    word = "#FFFFFF" if rev else FOREST
    tag = "#FFFFFF" if rev else LEAF
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 520 120">
<g transform="translate(6 10)">{mark(rev)}</g>
<text x="122" y="70" font-family="{FONT}" font-weight="600" font-size="54" letter-spacing="0.5" fill="{word}">Verdant</text>
<text x="125" y="100" font-family="{FONT}" font-weight="600" font-size="15" letter-spacing="4.2" fill="{tag}">PEST CARE</text>
</svg>
'''


def render(svg_text, width, height, out_png):
    """Rasterize an SVG at width x height with a transparent background."""
    with tempfile.TemporaryDirectory() as tmp:
        html = os.path.join(tmp, "r.html")
        with open(html, "w") as f:
            f.write("<html><body style='margin:0;background:transparent'>"
                    f"<div style='width:{width}px;height:{height}px'>"
                    + svg_text.replace("<svg ", f"<svg width='{width}' height='{height}' ", 1)
                    + "</div></body></html>")
        shot = os.path.join(tmp, "shot.png")
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        f"--user-data-dir={tmp}/prof", "--default-background-color=00000000",
                        f"--window-size={width},{height}", f"--screenshot={shot}",
                        "file://" + html], check=True, capture_output=True)
        img = Image.open(shot).convert("RGBA").crop((0, 0, width, height))
        img.save(out_png, optimize=True)


def theme_logo(color_png, out_png):
    """Letterbox the color logo onto a white 600x120 canvas for the Lightning header."""
    src = Image.open(color_png).convert("RGBA")
    scale = min(THEME_SIZE[0] / src.width, THEME_SIZE[1] / src.height)
    src = src.resize((int(src.width * scale), int(src.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGBA", THEME_SIZE, (255, 255, 255, 255))
    canvas.paste(src, ((THEME_SIZE[0] - src.width) // 2, (THEME_SIZE[1] - src.height) // 2), src)
    buf = io.BytesIO()
    canvas.save(buf, format="PNG", optimize=True)
    with open(out_png, "wb") as f:
        f.write(buf.getvalue())


def main():
    os.makedirs(KIT, exist_ok=True)
    svgs = {
        "mark": mark_svg(), "mark_reversed": mark_svg(True),
        "logo": logo_svg(), "logo_reversed": logo_svg(True),
    }
    for name, text in svgs.items():
        with open(os.path.join(KIT, f"verdant_{name}.svg"), "w") as f:
            f.write(text)
        w, h = (512, 512) if name.startswith("mark") else (1560, 360)
        render(text, w, h, os.path.join(KIT, f"verdant_{name}.png"))
        print(f"verdant_{name}: svg + {w}x{h} png")

    shutil.copy(os.path.join(KIT, "verdant_logo_reversed.png"),
                os.path.join(DOCGEN_ASSETS, "verdant_logo_white.png"))
    shutil.copy(os.path.join(KIT, "verdant_logo.png"),
                os.path.join(DOCGEN_ASSETS, "verdant_logo_color.png"))
    os.makedirs(THEME_ASSETS, exist_ok=True)
    theme_logo(os.path.join(KIT, "verdant_logo.png"), os.path.join(THEME_ASSETS, f"{THEME_LOGO}.asset"))
    print("docgen assets and theme logo written")


if __name__ == "__main__":
    main()
