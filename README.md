# FSL-RC Story — Pest Control (Rentokil)

Secondary demo story on the **`pest-control`** branch: **residential pest
control**. Rentokil sells Home Protection (and related plans) to Michael Reyes
in Bloomingdale, IL. The quote is created **in the field** on a tablet.

> The **base** story (high tech / data center, sale over the phone or with an
> account rep) is on `main` — see the QuantumBit deck and `demo-guide.md` there.

## Story notes

- **Industry:** residential pest control (Rentokil).
- **The sale happens in the field.** A sales rep inspects the property, captures
  findings on a tablet, and places a Revenue Cloud quote with location-aware
  pricing (service ZIP → zone multiplier). Field Service then delivers the
  Initial Service and every quarterly visit after that.
- **Not the QuantumBit path.** QuantumBit's sale is typical inside sales /
  account-rep quoting; this story is door-to-door inspect-and-quote.

## The nine scenes

| Act | # | Scene | Persona |
|-----|---|-------|---------|
| Sell | 1 | Plan the day | Sales Rep |
| | 2 | Inspect & quote on the tablet | Sales Rep |
| | 3 | Sign & pay at the door | Sales Rep + Michael |
| Hand off | 4 | The plan builds itself | Automation / Dispatcher |
| Serve | 5 | First treatment starts billing | Technician + Billing |
| | 6 | Recurring visits run themselves | Service Manager |
| | 7 | Re-service with a guarantee check | Care + Billing |
| Grow & retain | 8 | Upsell in the driveway | Technician |
| | 9 | Pause, resume & renew | Care + Subscription |

## Contents

| Path | What it is |
|------|------------|
| `deck/Rentokil Residential Pest Control Lifecycle Story.pptx` | Pest lifecycle deck |
| `deck/QuantumBit…pptx` | Base high-tech deck (also present for comparison) |
| `demo-guide-pest.md` | Click path and build notes for this story |
| `scripts/fill_pest_deck.py` | Recolors Vision → Core Demo and sets field-sale notes |
| `scripts/build_pest_deck.py` | Storyboard builder (needs Salesforce FY27 template) |
| `scripts/place_pest…` | Drivers live in rlm-base-dev (`scripts/place_pest_demo_order.py`) |

## Rebuild

```bash
pip install python-pptx
python3 scripts/fill_pest_deck.py
```

## Related build

Enable `pest: true` (and `fsl: true`) in Revenue Cloud Base Foundations
(`rlm-base-dev` branch `pest-control`), then `cci flow run prepare_pest`.
After loading prices, refresh pricing decision tables and wait for
`Price_Book_Entry_Decision_Table_v2` before placing quotes.
