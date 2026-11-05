# Brightline Commercial HVAC Demo

Brightline Home Comfort's commercial division runs one planned-maintenance contract for
**Lakeshore Property Group**: six sites (three offices, two restaurants and a small data room)
with 42 rooftop units (RTUs). The demo covers one quote with a line group per site, one order
that builds each site's coverage and maintenance plan, emergency response priority by site, EPA
refrigerant leak-rate tracking, adding a building mid-term, a capital project billed by milestone,
and one monthly invoice to headquarters that the billing agent explains by site.

It builds on the residential demo ([`hvac-demo.md`](hvac-demo.md)): same org, brand, territory
and billing setup. The storyboard deck is
[`hvac-commercial-demo-deck.pptx`](hvac-commercial-demo-deck.pptx).

## Enable

Requires the residential build (`fsl`, `hvac`), then `hvac_commercial: true` in
`cumulusci.yml` under `project → custom`:

```bash
cci flow run prepare_hvac_commercial --org <alias>
```

With `docgen: true` the flow also deploys the three commercial documents; with `agents: true` it
redeploys the billing agent with the Commercial Invoice by Site topic. A rerun is safe; it takes
about 2 minutes.

## Before each run

```bash
cci flow run reset_hvac_commercial_demo --org <alias>
```

This restores the site and unit fixture and resets the capital project, then reseeds the data
room's refrigerant history with its maintenance visit dispatched tomorrow at 9 Central. It also
books a covered No Cool call at Harvest Table Restaurant for the next hour. Orders, invoices and
the contract stay. Details and per-story tasks: the Commercial section of
`.cursor/skills/hvac-demo-seed-visits/SKILL.md`.

The contract has to be booked once (Scenes 2–3) before the reset flow can seed the Serve scenes.

## The customer

| Site | Code | Type | Units | Response |
|------|------|------|-------|----------|
| Lakeshore Property Group | LPG-HQ | Headquarters (bill to) | — | — |
| Lakeshore Office Park A | LPG-OPA | Office | 10, six of them 2007–2009 R-22 | Next business day |
| Lakeshore Office Park B | LPG-OPB | Office | 9 | Next business day |
| Riverwalk Plaza Offices | LPG-RWP | Office | 8 | Next business day |
| Ember & Oak Bistro | LPG-EOB | Restaurant | 4 | 4 hours, 24/7 |
| Harvest Table Restaurant | LPG-HTR | Restaurant | 5 | 4 hours, 24/7 |
| Lakeshore Data Room | LPG-LDR | Data Room | 6, four holding 50 lb or more | 4 hours, 24/7 |
| Westfield Commons Office | LPG-WFC | Office, bought mid-term (Scene 8) | 6 | Next business day |

Renee Castillo (Director of Facilities) signs; Accounts Payable at HQ gets the invoice.

## Catalog and pricing (HVAC-COM-*)

| SKU | Price | Billed |
|-----|-------|--------|
| `HVAC-COM-PM-S` / `-M` / `-L` / `-XL` | $38 / $55 / $85 / $130 a unit | Monthly, by tonnage band (up to 5, 6–12, 13–25, over 25 tons) |
| `HVAC-COM-RESP-4H` | $175 a site | Monthly: restaurants and the data room |
| `HVAC-COM-RESP-NBD` | $45 a site | Monthly: offices |
| `HVAC-COM-FILTER` | $9 a unit | Monthly, optional filter program |
| `HVAC-COM-RTU-REPL` | $16,800 a unit | Capital project, by milestone |
| `HVAC-COM-CRANE` | $2,600 | Capital project crane day |
| `HVAC-COM-LABOR`, `-REFRIGERANT`, `-LEAK-REPAIR`, `-BELT`, `-COMPRESSOR` | $165/h, $95/lb, $750, $85, $4,200 | One-time, on calls and repairs |

Contract terms: one year from the first of next month, renewed yearly with a 3% increase, Net 30,
billed monthly to HQ. A maintenance discount of 15% or more routes the quote to approval.

## Scenes

### Sell

**1. Site survey** (Account Manager, desktop). Lakeshore HQ with six site accounts, each with
a Field Service Location, and 42 rooftop units as Assets with unit tag, tonnage, install year,
refrigerant type and charge. Units holding 50 lb or more are leak-rate tracked. The survey is
seeded (`seed_hvac_commercial_sites`); there's no on-roof capture screen yet.

**2. Contract quote** (Account Manager). On HQ, **Contract Quote** previews the contract:
each site's units, tonnage, response tier and oldest unit, priced per unit by tonnage band, with
the filter program and a maintenance discount. Lakeshore's six sites come to **$3,715.20 a
month, $44,582.40 a year** at a 5% discount. **Create contract quote** builds one quote with a
line group per site (quote 00000068, 27 lines).

**3. Sign and order** (Account Manager + Renee). On the quote, **Book Contract** creates the
Brightline Contract Proposal (a site table and each site's services), takes the PO
(LPG-PO-2026-118) and places the order. The page shows the order activated, 27 contract assets
(one per site and service), response coverage for all six sites and six site maintenance plans.

### Hand off

**4. Site plans build themselves** (Operations, Dispatcher). Activating the order assetizes each
line, and each asset takes its site from the order line it came from. Each site gets an
entitlement on its response coverage, and a maintenance plan at the site's Location with a
quarterly rule per rooftop unit. Each quarter's visit is one work order per site with a line per
unit (the data room's visit, 00000343, has six lines).

### Serve

**5. Emergency call by site priority** (Customer Care, Technician). Harvest Table reports No Cool
during the lunch rush. The call is Covered by the site's 4-hour, 24/7 entitlement and gets
Critical priority and a 4-hour Priority Response countdown. The same call at an office gets next
business day.

**6. Refrigerant compliance** (Technician). On the data room's maintenance visit, **Refrigerant
Log** lists the units with their charge and annualized leak rate. RTU-03 (62 lb R-410A) is at
7.9% after an add 140 days ago. The technician logs 3 lb: the leak rate is 3 / 62 × 365 / 140 =
12.6%, over the 10% comfort-cooling limit. The unit turns **Repair due** with a 30-day deadline,
and a Commercial Leak Repair work order opens at the site for RTU-03. Completing the repair puts
the unit back In Compliance.

**7. One invoice for every site** (Billing). The month's invoice goes to HQ: PO, Net 30, bill to
Accounts Payable, with **Invoice by site** subtotals (DOC-000000007: $4,137.35 + $413.78 tax =
$4,551.13 across seven sites). The consolidated invoice PDF shows the same site table. In the
Agentforce panel, the Brightline Billing Agent answers "Explain the latest Lakeshore invoice by
site": each site's lines, periods and share (Harvest Table is $540.50, 11.9%). For a project
invoice it names the milestone. Test the agent in the panel; `sf agent preview` can't start
employee agents.

### Grow and retain

**8. Add a site and renew** (Account Manager). Lakeshore buys Westfield Commons Office
(`seed_hvac_commercial_new_site`, six units). **Add Site** prices it at the contract's discount
and adds it on an amendment order co-terminated with the contract and prorated from Jan 1, 2027
(order 00000165, $4,643.65). It can be shown once per contract. **Renew Contract** previews each
site at this year's price plus 3% and creates the renewal quote (00000083, $51,140.04 for seven
sites).

**9. Capital project** (Account Manager, Operations, crew). On Office Park A, **Capital Project**
recommends the six units on R-22 or past 15 years. **Create project quote** prices six
replacements at $16,800 plus a $2,600 crane day: **$103,400**. **Book Project** creates the
Brightline Project Proposal with the milestone schedule, takes PO LPG-CAP-2026-311 and bills the
**40% deposit ($41,360)**. Orchestration creates the crane lift, install and commissioning work
orders in turn. Completing the install bills the second 40% and rewrites the six units as new
R-454B units. Commissioning bills the last 20% ($20,680). `reset_hvac_capital_project` puts the
story back.

## Documents

| Document | Where | Shows |
|----------|-------|-------|
| Contract proposal | Book Contract | Sites table, monthly and annual totals, per-site services |
| Project proposal | Book Project | Scope, unit prices, milestone schedule |
| Consolidated invoice | Invoice by site card on the invoice | PO, due date, a subtotal per site |

See the Brightline documents section of [`hvac-demo.md`](hvac-demo.md) for the templates and
the binary-fix step.

## Run of show

| # | Scene | Persona | Min | Status |
|---|-------|---------|-----|--------|
| 1 | Site survey | Account Manager | 1.5 | Partly live: seeded hierarchy and units; no on-roof capture |
| 2 | Contract quote | Account Manager | 2.5 | Live |
| 3 | Sign and order | Account Manager + Renee | 2 | Live |
| 4 | Site plans build themselves | Operations | 1.5 | Live |
| 5 | Emergency call by site priority | Customer Care + Technician | 1.5 | Live (seeded call) |
| 6 | Refrigerant compliance | Technician | 2 | Live |
| 7 | One invoice for every site | Billing | 2 | Live; agent in the Agentforce panel |
| 8 | Add a site and renew | Account Manager | 2 | Live; Add Site once per contract |
| 9 | Capital project | Account Manager + Operations | 3 | Live |

About 18 minutes.

## Known gaps

- There's no on-device site survey or per-unit checklist. Units are seeded, and the per-unit work is on the work order lines.
- Contract quotes start on the first of next month. `seed_hvac_commercial_service_call` moves not-yet-started site entitlements to today so a call is Covered.
- The proposals show the quote creator's name and email. Book the demo contract as a demo user before showing PDFs to an audience.
