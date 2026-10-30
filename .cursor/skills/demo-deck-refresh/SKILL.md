---
name: demo-deck-refresh
description: Revises a demo deck (.pptx) in docs/guides to match what the org does now - edits slide text and speaker notes without losing formatting, replaces stale screenshots with fresh captures from the org, and renders the slides to check layout. Use when asked to update, scrub, revise or refresh the pest control demo deck or another storyboard deck, or to replace its screenshots.
---

# Demo Deck Refresh

The decks (for example `docs/guides/pest-control-demo-deck.pptx`) have no build script.
Edit them in place with python-pptx, keep the demo guide as the source of truth, and check
the result visually.

## Quick Rules

1. Read the guide first (`docs/guides/pest-control-demo.md`); the deck should say what the
   guide says. Fix the guide too when they disagree.
2. Dump every slide's text, notes and pictures before editing.
3. Edit runs, not paragraphs: replacing a paragraph's text flattens colored segments.
4. Assert the old text before replacing it, so a mismatch fails instead of editing the wrong
   shape.
5. Replace screenshots with records from real demo runs, and say in the notes whose record it
   is when it isn't the story's customer.
6. Render through Keynote and look at every changed slide before committing.

## DO NOT

- **DO NOT** print or save the login links used for screenshots; they carry a session.
- **DO NOT** screenshot pages showing credentials or real customer data.
- **DO NOT** leave a replaced image's relationship on the slide; the old image stays in the
  file and the deck grows.

## Workflow

**1. Set up and dump**

```bash
python3 -m venv /tmp/pptxenv && /tmp/pptxenv/bin/pip install python-pptx pillow
```

Dump each slide's shapes as `[shape_id] text`, pictures with position and size, and notes.
Extract pictures (`shape.image.blob`) to see which ones are stale.

**2. Decide what changed**

List each scene's claims (bullets, flow steps, notes, status table) against the guide.
Typical drift: prices, step names, features added since, setup task names, dates.

**3. Capture new screenshots**

Find records from today's runs (quotes, orders, work orders), then:

```bash
python3 scripts/ai/capture_org_screenshots.py --target-org <username> --out-dir /tmp/shots \
  quote=/lightning/r/Quote/<Id>/view wo=/lightning/r/WorkOrder/<Id>/view
```

Defaults give 1600x1100 images, the size of the deck's desktop slots. Look at each image; if a
side panel is still loading, capture it again. Phone screenshots can't be captured this way;
list the stale ones for the user to retake on the device.

**4. Edit with helpers like these**

```python
from pptx.oxml.ns import qn

def set_par(p, text):              # keep the first run's formatting
    p.runs[0].text = text
    for r in p.runs[1:]:
        r._r.getparent().remove(r._r)

def edit(slide, shape_id, old, new):
    sh = next(s for s in slide.shapes if s.shape_id == shape_id)
    hits = [p for p in sh.text_frame.paragraphs if p.text == old]
    assert len(hits) == 1, (shape_id, old)
    set_par(hits[0], new)

# Add a bullet: deepcopy the neighbor's <a:p>, addnext(), then set_par on the copy.
# Table cells with a colored second run: change only cell.text_frame.paragraphs[0].runs[0].

def swap_image(slide, pic, path):
    _, rid = slide.part.get_or_add_image_part(path)
    blip = pic._element.blipFill.find(qn("a:blip"))
    old = blip.get(qn("r:embed"))
    blip.set(qn("r:embed"), rid)
    if f'"{old}"' not in slide.part.blob.decode("utf-8", "ignore"):
        slide.part.drop_rel(old)
```

Notes: `slide.notes_slide.notes_text_frame.paragraphs`, matched by the start of the paragraph.
Write the script against the committed deck (`git checkout` it before rerunning) so asserts
keep matching.

**5. Render and check**

```bash
open -a Keynote && sleep 5 && osascript -e 'tell application "Keynote"
set d to open POSIX file "/abs/path/deck.pptx"
export d to POSIX file "/tmp/deckrender" as slide images with properties {image format:PNG, skipped slides:false}
close d saving no
end tell'
```

Check text overflow, table row heights, colors in edited cells and the new pictures. Compare
the file size with the original.

**6. Commit** the deck with the guide fixes, and report which slides changed, which
screenshots were replaced (with record numbers) and which still need device shots.
