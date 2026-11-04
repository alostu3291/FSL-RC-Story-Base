"""Build the Brightline invoice DocGen template from the Verdant pest invoice.

Swaps the company name, the Verdant palette for the Brightline one, and the logo, keeping
every token and table the standard invoice data mappings fill.

Usage:
    python scripts/docgen/build_hvac_invoice.py \
        unpackaged/post_pest_docgen/documentTemplates/RLM_RTK_Invoice_1.dt \
        scripts/docgen/assets/brightline_logo_color.png \
        unpackaged/post_hvac_docgen/documentTemplates/RLM_HVAC_Invoice_1.dt
"""
import re
import sys
import zipfile

from PIL import Image

SOURCE, LOGO, OUT = sys.argv[1:4]

TEXT = {"Verdant Pest Care": "Brightline Home Comfort"}
# Verdant forest, leaf and tint, to Brightline navy, glacier and mist.
COLORS = {"1F4D3A": "1B3A5C", "3FA34D": "3BA7D9", "D7E2DB": "D5DFE8", "EEF3E8": "EEF3F7"}
EMU_PER_INCH = 914400


def rebrand(xml, logo_ratio):
    for old, new in TEXT.items():
        xml = xml.replace(old, new)
    for old, new in COLORS.items():
        xml = re.sub(f'"{old}"', f'"{new}"', xml, flags=re.IGNORECASE)

    def fit(match):
        cx = int(match.group(2))
        return f'{match.group(1)}cx="{cx}" cy="{round(cx / logo_ratio)}"'

    return re.sub(r'(<(?:wp:extent|a:ext) )cx="(\d+)" cy="(\d+)"', fit, xml)


with Image.open(LOGO) as logo:
    ratio = logo.width / logo.height

with zipfile.ZipFile(SOURCE) as src, zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as dst:
    images = [n for n in src.namelist() if n.startswith("word/media/") and not n.endswith("/")]
    if len(images) != 1:
        sys.exit(f"expected one logo image in {SOURCE}, found {images}")
    for name in src.namelist():
        data = src.read(name)
        if name in images:
            with open(LOGO, "rb") as fh:
                data = fh.read()
        elif name.startswith("word/") and name.endswith(".xml"):
            data = rebrand(data.decode("utf-8"), ratio).encode("utf-8")
        dst.writestr(src.getinfo(name), data)
print("saved", OUT)
