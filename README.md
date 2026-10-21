# FSL-RC Story (Base)

The base Revenue Cloud + Field Service demo story: **high tech, data center**.
QuantumBit sells PowerSwerve rack servers to Infinitech for its San Francisco
data center, installs and services them with Field Service, and bills through
Revenue Cloud.

## Story notes

- **Industry:** high tech. The asset is a PowerSwerve R750 rack server going
  into a customer data center, with Installation and Assembly and Gold Hardware
  Maintenance sold alongside it.
- **The sale happens the typical way.** A seller (inside sales over the phone,
  or an account rep working with the customer) builds the quote in Revenue
  Cloud and converts it to an order. The deal is not sold in the field by a
  technician; Field Service only enters once the order is activated and the
  install is orchestrated.
- **Field Service is delivery and service, not sales.** Technicians install,
  maintain and repair. In Scene 8 the technician *flags* an expansion from the
  Work Order, which creates an opportunity, but the account's seller still runs
  the follow-up quote.

## The nine scenes

| Act | # | Scene | Persona |
|-----|---|-------|---------|
| 1 · Sell, deliver, bill | 1 | Configure & quote | Seller (phone / account rep) |
| | 2 | Activate the order | Fulfillment Manager |
| | 3 | Automatic dispatch | Dispatcher |
| | 4 | Technician on site | Technician |
| | 5 | Billing starts at install | Billing Specialist |
| 2 · Service, protect, grow | 6 | Maintenance runs itself | Service Manager |
| | 7 | Break/fix with coverage check | Dispatcher & Billing |
| | 8 | Upsell from the field | Technician flags → Seller quotes |
| | 9 | One install base | Account Team |

Scene 7 compares Infinitech (covered by Gold) with Apex Dynamics, a second
customer whose R750 has no Gold maintenance.

## Contents

| Path | What it is |
|------|------------|
| `deck/QuantumBit Revenue Cloud + Field Service Demo Story.pptx` | Presentation with screenshots on every scene slide and a screenshot appendix |
| `deck/source/…Storyboard.pptx` | Unfilled storyboard that `fill_deck.py` builds from |
| `deck/preview-demo-map.png` | Demo map preview image |
| `screenshots/` | 33 screenshots from the fsl-rc org run (`sN-NN-*.png`), plus `story-records.json` with the record Ids used |
| `demo-guide.md` | Build steps, automation and click path (copy of `docs/guides/fsl-rev-cloud-demo.md` in the Revenue Cloud Base Foundations repo) |
| `scripts/fill_deck.py` | Places the screenshots into the deck and aligns its text with the built demo |
| `scripts/capture_screenshots.py` | Runs the story against an org and captures each scene |
| `scripts/build_deck.py`, `scripts/deck_helpers.py` | Original storyboard builder (needs the Salesforce FY27 template, not included) |

## Rebuild

```bash
pip install python-pptx pillow selenium

# Refresh the deck from the current screenshots
python3 scripts/fill_deck.py

# Re-run the story and recapture screenshots (scenes are optional, e.g. 1,2,3)
RLM_REPO=/path/to/rlm-base-dev FSL_ORG=<sf alias> python3 scripts/capture_screenshots.py [scenes]
```

`capture_screenshots.py` needs an org built with `fsl: true` from the Revenue
Cloud Base Foundations repo (`prepare_fsl` + `setup_fsl_revenue`) and a
logged-in `sf` CLI alias.
