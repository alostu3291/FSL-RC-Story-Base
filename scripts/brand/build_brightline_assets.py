#!/usr/bin/env python3
"""Build the Brightline Home Comfort brand kit for the HVAC demo.

Writes SVG sources and PNGs to scripts/brand/brightline/, and copies the PNGs the demo uses:
    scripts/docgen/assets/brightline_logo_white.png   DocGen header (on the Navy band)
    scripts/docgen/assets/brightline_logo_color.png   DocGen on light backgrounds
    unpackaged/post_hvac_brand/contentassets/          Lightning theme logo (600x120 PNG)

Usage:
    python scripts/brand/build_brightline_assets.py
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(__file__))
from build_verdant_assets import FONT, ROOT, render, theme_logo  # noqa: E402

KIT = os.path.join(ROOT, "scripts", "brand", "brightline")
DOCGEN_ASSETS = os.path.join(ROOT, "scripts", "docgen", "assets")
THEME_ASSETS = os.path.join(ROOT, "unpackaged", "post_hvac_brand", "contentassets")
THEME_LOGO = "RLM_brightline_logo"

NAVY, EMBER, GLACIER, MIST, INK = "#1B3A5C", "#F26B3A", "#3BA7D9", "#EEF3F7", "#1E2A35"


def mark(rev=False):
    tile = "#FFFFFF" if rev else NAVY
    roof = NAVY if rev else "#FFFFFF"
    return f'''<rect x="6" y="6" width="88" height="88" rx="22" fill="{tile}"/>
<path d="M24 54 L50 30 L76 54" stroke="{roof}" stroke-width="8" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M26 69 H47" stroke="{EMBER}" stroke-width="8" stroke-linecap="round"/>
<path d="M53 69 H74" stroke="{GLACIER}" stroke-width="8" stroke-linecap="round"/>'''


def mark_svg(rev=False):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">{mark(rev)}</svg>\n'


def logo_svg(rev=False):
    word = "#FFFFFF" if rev else NAVY
    tag = "#FFFFFF" if rev else EMBER
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 120">
<g transform="translate(6 10)">{mark(rev)}</g>
<text x="122" y="70" font-family="{FONT}" font-weight="600" font-size="54" letter-spacing="0.2" fill="{word}">Brightline</text>
<text x="125" y="100" font-family="{FONT}" font-weight="600" font-size="15" letter-spacing="4.2" fill="{tag}">HOME COMFORT</text>
</svg>
'''


def main():
    os.makedirs(KIT, exist_ok=True)
    svgs = {
        "mark": mark_svg(), "mark_reversed": mark_svg(True),
        "logo": logo_svg(), "logo_reversed": logo_svg(True),
    }
    for name, text in svgs.items():
        with open(os.path.join(KIT, f"brightline_{name}.svg"), "w") as f:
            f.write(text)
        w, h = (512, 512) if name.startswith("mark") else (1800, 360)
        render(text, w, h, os.path.join(KIT, f"brightline_{name}.png"))
        print(f"brightline_{name}: svg + {w}x{h} png")

    shutil.copy(os.path.join(KIT, "brightline_logo_reversed.png"),
                os.path.join(DOCGEN_ASSETS, "brightline_logo_white.png"))
    shutil.copy(os.path.join(KIT, "brightline_logo.png"),
                os.path.join(DOCGEN_ASSETS, "brightline_logo_color.png"))
    os.makedirs(THEME_ASSETS, exist_ok=True)
    theme_logo(os.path.join(KIT, "brightline_logo.png"), os.path.join(THEME_ASSETS, f"{THEME_LOGO}.asset"))
    print("docgen assets and theme logo written")


if __name__ == "__main__":
    main()
