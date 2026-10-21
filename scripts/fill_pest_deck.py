#!/usr/bin/env python3
"""Fill the Rentokil pest-control deck: mark scenes as Core Demo, strip Vision
styling, and optionally place screenshots from screenshots/pest/.

Usage:
    python3 scripts/fill_pest_deck.py
    python3 scripts/fill_pest_deck.py --deck "deck/Rentokil Residential Pest Control Lifecycle Story.pptx"
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE_TYPE
from pptx.util import Inches, Pt

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DECK = ROOT / "deck" / "Rentokil Residential Pest Control Lifecycle Story.pptx"
SHOTS = ROOT / "screenshots" / "pest"

BLUE = RGBColor(0x06, 0x6A, 0xFE)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
ORANGE_FILL = "F38304"
ORANGE_LIGHT = "FFEBD6"

# Scene slide index guesses from build_pest_deck layout (title + map + scenes).
# Adjusted after open if needed.
HERO = {
    # slide_index (0-based): (screenshot stem prefix, top_px crop)
}


def recolor_shape(shape):
    """Recolor orange vision accents to blue."""
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

    if args.backup:
        backup = deck_path.with_name(deck_path.stem + " (pre-fill backup).pptx")
        if not backup.exists():
            shutil.copy2(deck_path, backup)
            print(f"Backup: {backup}")

    prs = Presentation(str(deck_path))
    for i, slide in enumerate(prs.slides):
        for shape in slide.shapes:
            recolor_shape(shape)
            recolor_fill(shape)
            replace_vision_text(shape)

    # Title slide notes: field sale story
    if len(prs.slides) > 0:
        set_notes(
            prs.slides[0],
            "Rentokil residential pest control. The sale happens in the field: "
            "the rep inspects and quotes on a tablet at Michael's door "
            "(316 Ridgewood Dr, Bloomingdale, IL 60108), then Revenue Cloud and "
            "Field Service run the lifecycle. Secondary story to the QuantumBit "
            "high-tech / data center base story.",
        )

    # Scene 2 notes emphasize location pricing
    if len(prs.slides) > 5:
        set_notes(
            prs.slides[5],
            "Scene 2 — Inspect & Quote. Use Inspect & Quote on the Account "
            "(flow RLM_RTK_Inspect_and_Quote) or Browse Catalogs on the Quote. "
            "Location pricing: Bloomingdale 60108 = suburb x1.00. Change ZIP to "
            "60140 to show the rural x1.20 multiplier on the waterfall.",
        )

    out = deck_path
    prs.save(str(out))
    print(f"Wrote {out} ({len(prs.slides)} slides)")
    if SHOTS.exists():
        shots = list(SHOTS.glob("s*.png"))
        print(f"Screenshots available: {len(shots)} in {SHOTS} (place manually or extend HERO map)")


if __name__ == "__main__":
    main()
