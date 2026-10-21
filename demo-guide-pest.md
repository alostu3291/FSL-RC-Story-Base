# Rentokil Residential Pest Control Demo Guide

Secondary story on the `pest-control` branch. The sale happens **in the field**:
a Rentokil sales rep inspects Michael Reyes's home at 316 Ridgewood Dr,
Bloomingdale, IL 60108 and builds a priced Revenue Cloud quote on a tablet.

Build orchestration lives in the Revenue Cloud Base Foundations repo
(`rlm-base-dev`) on branch `pest-control` — see
`docs/guides/pest-control-demo.md`.

## Deck

`deck/Rentokil Residential Pest Control Lifecycle Story.pptx` — nine scenes
across Sell → Hand off → Serve → Grow & retain. Source builder:
`scripts/build_pest_deck.py`. Fill / recolor:

```bash
python3 scripts/fill_pest_deck.py
```

## Nine scenes

| # | Scene | What to show |
|---|-------|----------------|
| 1 | Plan the day | Bloomingdale route / visit plan |
| 2 | Inspect & quote | Inspect & Quote flow + location zone (60108 vs 60140) |
| 3 | Sign & pay | Accept quote → order → activate |
| 4 | Plan builds itself | DRO Initial Treatment WO; billing waits on milestone |
| 5 | First treatment | Complete WO → subscription billing starts |
| 6 | Recurring visits | Maintenance Plan quarterly WOs |
| 7 | Re-service | Coverage check; free vs `RTK-RESERVICE` |
| 8 | Upsell | Flag Expansion → Termite co-term |
| 9 | Pause / renew | Mosquito pause/resume; renew plan |

## Org driver

```bash
# In rlm-base-dev (pest-control branch), after prepare_pest + DT refresh:
python scripts/place_pest_demo_order.py --target-org fsl-rc --activate --complete-initial
python scripts/capture_pest_screenshots.py
```

## Story notes

- **Industry:** residential pest control (Rentokil).
- **The sale happens in the field** with the tech/rep on a tablet — opposite of
  the QuantumBit base story where the sale is over the phone or with an account
  rep.
- **Location-aware pricing** uses `RLM_RTK_Service_Zone__c` multipliers applied
  when placing the quote (`RLM_RTK_FieldQuote` / `place_pest_demo_order.py`).
