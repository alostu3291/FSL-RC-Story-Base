#!/usr/bin/env python3
"""Fill the Rentokil pest-control deck: Core Demo styling + scene screenshots.

Rebuilds from the pre-fill backup when present so it can be re-run safely.

Usage:
    python3 scripts/fill_pest_deck.py
    /tmp/pest-shots/bin/python scripts/fill_pest_deck.py
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from PIL import Image, ImageChops
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE_TYPE
from pptx.util import Pt

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DECK = ROOT / "deck" / "Rentokil Residential Pest Control Lifecycle Story.pptx"
SHOTS = ROOT / "screenshots" / "pest"

BLUE = RGBColor(0x06, 0x6A, 0xFE)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
BORDER = RGBColor(201, 201, 201)
ORANGE_FILL = "F38304"
ORANGE_LIGHT = "FFEBD6"

# 0-based slide index -> (screenshot stem, top_px crop or None, frame_id, label_id)
HERO = {
    5: ("s1-00-map", None, 14, 15),  # Plan the day
    6: ("s2-01-quote", None, 14, 15),  # Inspect & quote
    7: ("s3-01-order", None, 14, 15),  # Sign & pay
    9: ("s4-02-order", None, 15, 16),  # Plan builds itself (order + fulfillment)
    11: ("s5-01-work-order", None, 15, 16),  # First treatment starts billing
    12: ("s6-01-maintenance-plan", None, 15, 16),  # Recurring visits
    13: ("s7-01-asset", None, 15, 16),  # Re-service / guarantee
    15: ("s8-01-expansion-opportunity", None, 14, 15),  # Upsell
    16: ("s9-01-asset", 0, 14, 15),  # Pause / renew (tall shot band)
}


def by_id(slide, shape_id):
    return next(s for s in slide.shapes if s.shape_id == shape_id)


def remove(shape):
    shape._element.getparent().remove(shape._element)


def content_height(path: Path) -> int:
    img = Image.open(path).convert("RGB")
    w, h = img.size
    bg = img.getpixel((w // 2, h - 1))
    diff = ImageChops.difference(img, Image.new("RGB", img.size, bg)).convert("L").point(
        lambda v: 255 if v > 12 else 0
    )
    box = diff.getbbox()
    return min(h, box[3] + 20) if box else h


def add_picture(slide, name: str, left, top, width, height, top_px=None):
    path = SHOTS / f"{name}.png"
    if not path.exists():
        print(f"  missing shot: {path.name}")
        return None
    w, h = Image.open(path).size
    if top_px is None:
        start, band = 0, content_height(path)
    else:
        start, band = top_px, min(h - top_px, int(w * height / width))
    scale = min(width / w, height / band)
    pic_w, pic_h = int(w * scale), int(band * scale)
    pic = slide.shapes.add_picture(
        str(path), int(left + (width - pic_w) / 2), int(top), pic_w, pic_h
    )
    pic.crop_top = start / h
    pic.crop_bottom = (h - start - band) / h
    pic.line.color.rgb = BORDER
    pic.line.width = Pt(0.75)
    print(f"  placed {name} on slide")
    return pic


def recolor_shape(shape):
    if shape.shape_type == MSO_SHAPE_TYPE.GROUP:
        for s in shape.shapes:
            recolor_shape(s)
        return
    if not shape.has_text_frame:
        return
    for para in shape.text_frame.paragraphs:
        for run in para.runs:
            try:
                color = run.font.color.rgb
            except Exception:
                color = None
            if color and str(color).upper() in (ORANGE_FILL, ORANGE_LIGHT):
                run.font.color.rgb = BLUE


def recolor_fill(shape):
    try:
        fill = shape.fill
        if fill.type is not None and fill.fore_color and fill.fore_color.rgb:
            if str(fill.fore_color.rgb).upper() in (ORANGE_FILL, ORANGE_LIGHT):
                fill.solid()
                fill.fore_color.rgb = BLUE
    except Exception:
        pass
    if shape.shape_type == MSO_SHAPE_TYPE.GROUP:
        for s in shape.shapes:
            recolor_fill(s)


def replace_vision_text(shape):
    if not shape.has_text_frame:
        if shape.shape_type == MSO_SHAPE_TYPE.GROUP:
            for s in shape.shapes:
                replace_vision_text(s)
        return
    for para in shape.text_frame.paragraphs:
        for run in para.runs:
            if run.text and "VISION" in run.text.upper():
                run.text = run.text.replace("VISION", "CORE DEMO").replace("Vision", "Core demo")
            if run.text and "vision scene" in run.text.lower():
                run.text = run.text.replace("Vision scene. ", "").replace("vision scene. ", "")


def set_notes(slide, text: str):
    notes_slide = slide.notes_slide
    notes_slide.notes_text_frame.text = text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--deck", default=str(DEFAULT_DECK))
    parser.add_argument("--backup", action="store_true", default=True)
    args = parser.parse_args()
    deck_path = Path(args.deck)
    if not deck_path.exists():
        raise SystemExit(f"Deck not found: {deck_path}")

    backup = deck_path.with_name(deck_path.stem + " (pre-fill backup).pptx")
    if args.backup and not backup.exists():
        shutil.copy2(deck_path, backup)
        print(f"Backup: {backup}")

    # Prefer clean storyboard so re-runs don't stack pictures
    src = backup if backup.exists() else deck_path
    prs = Presentation(str(src))

    for i, slide in enumerate(prs.slides):
        for shape in slide.shapes:
            recolor_shape(shape)
            recolor_fill(shape)
            replace_vision_text(shape)

    placed = 0
    for slide_idx, (name, top_px, frame_id, label_id) in HERO.items():
        if slide_idx >= len(prs.slides):
            continue
        slide = prs.slides[slide_idx]
        try:
            frame = by_id(slide, frame_id)
            label = by_id(slide, label_id)
        except StopIteration:
            print(f"  slide {slide_idx}: missing frame/label shapes")
            continue
        pic = add_picture(slide, name, frame.left, frame.top, frame.width, frame.height, top_px)
        if pic is not None:
            remove(frame)
            remove(label)
            placed += 1

    if len(prs.slides) > 0:
        set_notes(
            prs.slides[0],
            "Rentokil residential pest control. The sale happens in the field: "
            "the rep inspects and quotes on a tablet at Michael's door "
            "(316 Ridgewood Dr, Bloomingdale, IL 60108), then Revenue Cloud and "
            "Field Service run the lifecycle. Secondary story to the QuantumBit "
            "high-tech / data center base story.",
        )
    if len(prs.slides) > 6:
        set_notes(
            prs.slides[6],
            "Scene 2 — Inspect & Quote. Use Inspect & Quote on the Account "
            "(flow RLM_RTK_Inspect_and_Quote) or Browse Catalogs on the Quote. "
            "Location pricing: Bloomingdale 60108 = suburb x1.00. Change ZIP to "
            "60140 to show the rural x1.20 multiplier on the waterfall.",
        )

    prs.save(str(deck_path))
    shots = list(SHOTS.glob("s*.png")) if SHOTS.exists() else []
    print(f"Wrote {deck_path} ({len(prs.slides)} slides, {placed} heroes, {len(shots)} shots available)")


if __name__ == "__main__":
    main()
