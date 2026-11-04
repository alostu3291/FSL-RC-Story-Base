# HVAC Demo Build Plan

A Revenue Cloud + Field Service story for heating and cooling companies, built on the pest
control demo's framework (`prepare_pest`, Verdant Pest Care). Residential first; commercial
second, as an extension of the residential build.

Branch: `hvac`. Status: residential build in progress.

## Decisions

| Decision | Plan | Why |
|----------|------|-----|
| Replace pest or run alongside | Alongside: new `RLM_HVAC_*` metadata, `hvac` feature flag, `prepare_hvac` flow | The pest demo is working and recorded; both can live in one org |
| Clone or generalize the pest code | Clone for residential; extract a shared field-services layer when commercial starts | Cloning is fastest; a third vertical (commercial) is when shared code pays for itself |
| Brand | **Brightline Home Comfort** (chosen Nov 4); commercial is Brightline Commercial | |
| Residential scope | **Includes the good / better / best replacement quote** (chosen Nov 4) | The strongest HVAC moment |
| Commercial scope | **All nine commercial scenes** (chosen Nov 4) | |
| Org | **A fresh QuantumBit base org** dedicated to HVAC (chosen Nov 4) | Clean start; no pest data to work around |
| Territory | Naperville IL | Separate schedule from the pest demo's Bloomingdale territory |

Naming: metadata `RLM_HVAC_*`, LWCs `rlmHvac*`, SKUs `HVAC-*`, bundles `unpackaged/post_hvac*`,
data plans `datasets/sfdmu/hvac/en-US/hvac-{pcm,pricing,fsl,dro-fsl}`, flags `hvac` and
`hvac_commercial`.

## What carries over unchanged

These already run the pest story and don't know about pests:

- **Quoting and signing:** Place Sales Transaction quotes, `RLM_SignAndPay` (proposal PDF,
  signature, mock card, Create Order), DocGen activation and the binary-fix task.
- **Fulfillment:** order activation creates assets; a DRO fulfillment plan creates the first
  work order (`RLM_FSL_Create_Install_Work_Order` pattern) and completing it finishes the step
  and releases milestone billing (`RLM_FSL_Complete_Fulfillment_Step`).
- **Billing:** billing schedules, milestone billing on the first visit, invoices, uncovered
  work billed on completion (`RLM_FSL_BillRepair`, `RLM_FSL_Bill_Uncovered_Repair`).
- **Recurring service:** maintenance plans, visit generation through a flow, the nightly
  coverage sync, guarantees as entitlements with a response milestone.
- **Plan changes:** amendment orders, next-day effective date, guarantee and visit swap.
- **Field Service mobile:** quick action wiring, `RLM_FSL_Mobile_Extensions`, mobile settings.
- **AI and agent:** `RLM_RTK_EinsteinGenerator` pattern, six prompt templates, the billing agent
  that explains a bill from posted invoices.
- **Tooling:** seed tasks (prospect visit, covered re-service), `pest_org_inventory.py`,
  `capture_org_screenshots.py`, the brand and DocGen builder scripts, the deck-refresh skill.

## Lessons carried forward

From the pest build; each cost time once.

- **Mobile LWCs:** no `lightning-file-upload` (file input + canvas resize + Apex upload, about
  4 MB of base64); absolute `VersionDataUrl` for images; no speech recognition; PDFs shown as
  Apex-served page images. See `.cursor/skills/fsl-mobile-lwc/SKILL.md`.
- **Login on new orgs:** turn on PKCE (Setup → OAuth and OpenID Connect Settings) or the iOS app
  can't sign in; use `sf org login web`, because password logins over the API are blocked.
- **Name SLA records right the first time:** an entitlement process in use can't be renamed or
  redeployed. Put the brand in its name from day one.
- **Active agents reject deploys:** deactivate, deploy, reactivate.
- **Generate Work Orders in a flow:** leave `storeOutputAutomatically` off, or up-to-date plans
  fault every night.
- **Redeployed DocGen templates and prompt templates come back inactive:** always run the
  activate tasks after deploy.
- **SFDMU v5:** Upsert on a direct external ID (SKU, Code); the five v5 bugs in `AGENTS.md` apply.
- **Theme activation is manual** (Setup → Themes and Branding).
- **Seed tasks must be idempotent** and refuse reused prospects; duplicate rules match on street.

---

## Part 1: Residential

### Story

A homeowner calls because the upstairs is hot. A comfort advisor checks the system, finds an
aging AC and a dirty coil, and sells a maintenance agreement plus a repair on the spot.
Months later the AC stops cooling on a hot day; the agreement makes it a priority visit with a
countdown, and the technician recommends a replacement.

| # | Scene | What's shown | Pest scene it reuses |
|---|-------|--------------|----------------------|
| 1 | Plan the day | Naperville territory, advisor's schedule, Einstein brief: equipment ages, last service, local heat advisory | 1 |
| 2 | System check & quote | Walk the equipment (condenser, furnace or air handler, thermostat, ductwork, filters, water heater). Photo of the data plate fills make, model, serial and age; findings get an urgency (Monitor, Repair soon, Safety) | 2 |
| 3 | Sign & pay | "Why this agreement" on screen and in the proposal; signs Comfort Plus + coil cleaning | 3 |
| 4 | Agreement builds itself | Order activates; assets per agreement; DRO creates the first tune-up work order; the repair bills when it's done | 4 |
| 5 | First visit | Tune-up checklist with readings (temperature split, refrigerant pressures, amp draw), before and after photos, visit summary email | 5 |
| 6 | Seasonal visits | Spring AC tune-up and fall furnace tune-up generated from the agreement | 6 |
| 7 | No-cool call | Covered: diagnostic fee waived, repair discount, priority response countdown (Basic 24h, Plus 8h, Premier 4h). Not covered: diagnostic fee billed | 7 |
| 8 | Replace or upgrade | Technician finds a 16-year-old unit: good / better / best replacement quote from the field; or upgrade the agreement to Premier | 8 |
| 9 | Add a system | Customer adds a second system mid-term: quantity amendment, prorated, billing agent explains the bill | 9 |

### Catalog (`HVAC-*`)

| Type | Products | Pricing |
|------|----------|---------|
| Agreements (monthly, evergreen) | Comfort Basic, Comfort Plus, Comfort Premier | $19 / $29 / $45 a month per system; quantity = number of systems |
| Add-ons (monthly) | Indoor Air Quality (UV lamp + 4 filter changes), Water Heater Care (annual flush) | $15 / $8 |
| One-time | System Check (free), Initial Tune-up, Diagnostic Fee | $0 / $129 / $89 |
| Repairs | Capacitor, contactor, coil cleaning, condensate drain clear, refrigerant per lb, blower motor | $165–$650 |
| Replacement (optional scope) | Good / Better / Best heat pump systems (14 / 16 / 18 SEER2) | $8,900 / $11,500 / $14,800 |
| Fulfillment | `HVAC-DRO-FSL` | Creates the Initial Tune-up work order |

Pricing attributes replace pest's home size and severity:
- **Equipment age band** (0–5, 6–10, 11–15, 15+ years) adjusts the agreement (+$0 / +$3 / +$6 / +$10).
- **System type** (AC + furnace, heat pump, boiler) picks the checklist and the tune-up work type.
- ZIP-based zone pricing (`RLM_RTK_ZonePricing` pattern) carries over as is.

Agreement benefits drive the coverage rules:

| Benefit | Basic | Plus | Premier |
|---------|-------|------|---------|
| Tune-ups a year | 2 | 2 | 2 |
| Response time on a covered call | 24h | 8h | 4h |
| Diagnostic fee | $89 | Waived | Waived |
| Repair discount | 10% | 15% | Covered parts and labor |

### Data model

| Pest | HVAC | Notes |
|------|------|-------|
| `RLM_RTK_Inspection__c` | `RLM_HVAC_Assessment__c` | Adds systems count, oldest equipment age, recommended agreement, replacement flag |
| `RLM_RTK_Finding__c` (Zone, Pest, Evidence, Severity) | `RLM_HVAC_Finding__c` (Equipment, Component, Condition, Urgency, Reading) | Equipment is a lookup to an `Asset` |
| — | Customer equipment as `Asset` records | Make, model, serial, install year, tonnage, refrigerant type. The furnace and condenser become real Field Service assets |
| `Entitlement.RLM_RTK_Covered_Pests__c` | `Entitlement.RLM_HVAC_Covered_Systems__c` | Cooling, Heating, IAQ, Water Heater |
| `WorkOrder.RLM_RTK_Reported_Pest__c` | `WorkOrder.RLM_HVAC_Reported_Issue__c` | No cool, no heat, noise, leak, thermostat |
| `RLM_RTK_Service_Zone__c` | `RLM_HVAC_Service_Zone__c` | Same ZIP-prefix pricing; its own object so the HVAC org needs no pest metadata |

### Rules to rewrite (Apex)

Three places hold all the domain rules; the rest of the code is plumbing.

- **Findings to recommendation** (`RLM_RTK_Inspection` pattern): equipment 12+ years old means
  a replacement flag; a dirty coil or low refrigerant means a tune-up plus a repair; a Safety
  finding (cracked heat exchanger, CO reading) blocks "Monitor" and flags the visit; two or more
  systems raise the agreement quantity.
- **Coverage table** (`RLM_RTK_Coverage.Cadence` pattern): each agreement has two maintenance
  rules (spring `FREQ=YEARLY;BYMONTH=4` AC tune-up, fall `BYMONTH=10` furnace tune-up), its
  covered systems and its response hours.
- **Plan change** (`RLM_RTK_PlanChange` pattern): tiers Basic → Plus → Premier, add-ons IAQ and
  Water Heater Care; a finding such as "Allergies noted" recommends IAQ.

### Field Service setup

- **Work types:** System Check (60 min), Spring AC Tune-up (90), Fall Furnace Tune-up (90),
  No-Cool / No-Heat Call (120), Repair (120), Replacement Install (8 hours, crew of 2).
- **Skills:** EPA 608 certified, gas furnace, heat pump.
- **Territory:** Naperville, operating hours 7 AM–9 PM, seven days.
- **SLA:** entitlement process "<Brand> Comfort Response"; one milestone, "Priority Response",
  whose target comes from the agreement's response hours; business hours 7 AM–9 PM daily.

### LWC plan

Clone each pest component to `rlmHvac*`. Most changes are text; two are real work, plus one
new component.

| Component | From pest | Change | Effort |
|-----------|-----------|--------|--------|
| `rlmHvacSystemWalk` | `rlmRtkInspectionWalk` | Equipment list instead of rooms; component + condition pickers; data-plate fields; a photo of the data plate fills them through Einstein | Half a day |
| `rlmHvacAssessQuote` | `rlmRtkInspectQuote` | Systems count and age band instead of size and severity; recommendation shows a replacement option | Half a day |
| `rlmHvacServiceChecklist` + action | `rlmRtkTreatmentChecklist` / `Action` | Checklist items from findings plus numeric readings (temperature split, pressures, amps) with in-range checks | 2–3 hours |
| `rlmHvacReplacementOptions` | New | Good / better / best cards with price, efficiency, monthly financing estimate; picks one and starts a quote | Half a day (optional scope) |
| `rlmHvacFieldVisit` | `rlmRtkFieldVisit` | Step names and copy; same check → quote → sign flow | 1 hour |
| `rlmHvacPlanChange` | `rlmRtkPlanChange` | Copy; tiers and add-ons come from data | 1 hour |
| `rlmHvacResponseGuarantee` | `rlmRtkResponseGuarantee` | Copy ("Priority response within 8 hours") | 30 min |
| `rlmHvacFindAndAdd`, `PhotoCapture`, `Findings`, `VisitBrief`, `VisitSummary`, `QuoteReady` | Same names | Copy only | 1–2 hours total |

Every new component also needs: a quick action on Work Order or Service Appointment, the
layout's `platformActionList`, and an entry in `RLM_FSL_Mobile_Extensions`.

### AI, documents, agent, brand

- **Prompts:** rewrite the six templates. The photo prompt reads a data plate (make, model,
  serial, year) or describes a component's condition; the brief adds equipment ages and the
  last tune-up's readings.
- **Proposal:** "What we found in your system" (equipment table with ages), "Your comfort
  agreement", "Recommended repairs", optional "Replacement options". Built with the
  `build_rtk_pest_proposal.py` pattern; invoice relogoed.
- **Agent:** "<Brand> Billing Agent", same bill-explainer action with HVAC wording.
- **Brand:** logo kit, Lightning theme and mobile colors with `build_verdant_assets.py` adapted.

### Build sequence (residential)

| Step | Work | Estimate |
|------|------|----------|
| R1 | Brand, catalog, pricing and Field Service data plans; feature flag and `prepare_hvac` flow skeleton | 0.5 day |
| R2 | Objects, Apex clones with HVAC rules, tests | 1 day |
| R3 | LWCs, quick actions, layouts, mobile permission set | 1 day |
| R4 | Prompts, proposal and invoice, agent, SLA bundle | 0.5 day |
| R5 | Seed tasks (new prospect, covered no-cool call), end-to-end run in an org, fixes | 0.5 day |
| R6 | Demo guide, deck (desktop screenshots by me; phone screenshots retaken on the device) | 0.5 day |

About **4 days**; **3.5 days** without the replacement quote.

---

## Part 2: Commercial

What changes when the customer is a property manager with many buildings instead of a
homeowner. Built on top of residential; same brand with a commercial division.

### Story

*Lakeshore Property Group* manages 6 sites (offices, two restaurants, a small data room) with
42 rooftop units (RTUs). They want one planned-maintenance contract, one invoice, and fast
response where it matters.

| # | Scene | What's shown |
|---|-------|--------------|
| 1 | Site survey | Account hierarchy (Lakeshore HQ → 6 site accounts) and Field Service Locations; an equipment inventory of 42 RTUs with tonnage, age and refrigerant charge, captured on the device |
| 2 | Contract quote | One quote, one line group per site; planned maintenance priced per unit by tonnage band; quarterly visits; 3-year term with a 3% annual increase; discount over 10% goes to approval |
| 3 | Sign and order | Contract signed by the facility director; one order creates assets per unit, per site |
| 4 | Planned maintenance | One maintenance plan per site, one maintenance asset per RTU; each quarterly visit is a work order per site with a line item per unit (filters, belts, coil check); the crew is scheduled by site |
| 5 | Emergency call | Priority by site: 4 hours for restaurants and the data room, next business day for offices; 24/7 business hours; labor covered, parts billed |
| 6 | Refrigerant compliance | Units holding 50 lb or more log refrigerant added; leak rate is calculated, and a unit over the limit gets a repair work order and a compliance flag |
| 7 | Add a site | Lakeshore buys a building mid-term: add its units on an amendment, co-terminated with the contract, prorated |
| 8 | Capital project | Replacing 6 RTUs: project quote with milestone billing (40% deposit, 40% at install, 20% at commissioning); DRO creates crane, install and commissioning work orders |
| 9 | Consolidated billing and renewal | One monthly invoice to HQ with site subtotals and the PO number, net 30; renewal applies the increase; the billing agent explains the invoice by site |

### What's different from residential

| Area | Residential | Commercial |
|------|-------------|------------|
| Customer | Person account, one address | Parent account + site accounts; Field Service Locations |
| Equipment | 1–2 systems | Dozens of RTUs as Assets, each a maintenance asset |
| Pricing | Per system plus age band | Per unit by tonnage band (≤5, 6–12, 13–25, 25+ tons) and site type; volume tiers |
| Quote | One page, signed at the door | Line groups per site, approvals, 3-year term with annual increase |
| Visits | Spring and fall | Quarterly per site, one work order per site with a line item per unit |
| SLA | One response time per agreement | Per-site priority, 24/7 hours, several entitlements per contract |
| Billing | Card on file, monthly | Billing account at HQ, PO number, net 30, consolidated invoice with site subtotals |
| Upsell | Replace one system | Capital project with milestone billing and multi-step install |
| Compliance | — | EPA refrigerant leak-rate tracking |

### Platform pieces to confirm before building

Each is a known unknown; check in an org first, in this order.

1. **Quote line groups** through Place Sales Transaction, and whether DocGen can show subtotals by group.
2. **Annual price increases** on a multi-year term (ramp or price-escalation support in this release).
3. **Approvals** on discount thresholds (Advanced Approvals) in the demo org's licenses.
4. **Generate Work Orders per location** with one line item per maintenance asset.
5. **Consolidated invoicing** across child accounts to one billing account, and the PO number on the invoice.
6. **Co-terminated amendments** that add assets mid-term with proration.

### New pieces for commercial

- **Objects:** `RLM_HVAC_Refrigerant_Log__c` (unit, date, pounds added, technician, leak rate);
  site priority and site type on the site account or Location.
- **Data:** a commercial catalog (`HVAC-COM-*`): PM per unit by tonnage band, emergency labor
  coverage, filter program, parts markup; a site and RTU fixture for Lakeshore.
- **Apex:** site-level coverage sync (priority by site, entitlements per site), leak-rate
  calculation, a consolidated invoice summary for the agent.
- **LWCs:**
  - `rlmHvacSiteSurvey`: unit-by-unit capture on a roof.
  - `rlmHvacUnitChecklist`: the per-unit line items within a site visit.
  - `rlmHvacRefrigerantLog`.
  - The quote screen becomes a desktop flow; commercial quotes aren't signed on a tablet at the door.
- **Documents:** a contract proposal with a site table, a capital project proposal with the
  milestone schedule, and a consolidated invoice.
- **Optional:** an Experience Cloud page for the facility manager to request service and see
  invoices (the repo's PRM site pattern).

### Shared layer (do this at the start of commercial)

With pest, residential and commercial running the same machinery, move the plumbing into one
place and keep each vertical's rules as configuration:

- Custom metadata for the coverage table (product → visit type, recurrence, covered issues,
  response hours) and for finding-to-recommendation rules.
- One coverage sync, one plan-change engine and one field-visit controller that read that
  configuration.
- Vertical-specific LWCs stay thin, calling the shared controllers.

This turns a fourth vertical (plumbing, electrical, lawn care) into mostly data work.

### Build sequence (commercial)

| Step | Work | Estimate |
|------|------|----------|
| C0 | Confirm the six platform pieces above in an org | 0.5 day |
| C1 | Shared layer extracted from pest and residential, tests green for both | 1.5 days |
| C2 | Account hierarchy, Locations, RTU assets, commercial catalog and pricing | 1 day |
| C3 | Contract quote (line groups, term increase, approvals) and order to assets | 1 day |
| C4 | Site maintenance plans, per-unit line items, site-priority SLA | 1 day |
| C5 | Consolidated billing, PO, amendment to add a site | 1 day |
| C6 | Capital project with milestone billing and multi-step DRO install | 1 day |
| C7 | Refrigerant compliance, documents, agent, seeds, end-to-end run, deck | 1.5 days |

About **8 days** after residential, or about **6 days** without the shared layer, the capital project or compliance.

---

## Open decisions

1. Brand name (three proposals above, or yours).
2. Replacement quote in residential scope: yes adds about half a day and the strongest HVAC moment.
3. Commercial: which scenes matter most for the audience (consolidated billing and site SLAs, or
   capital projects)? That sets the order of C3–C7.
4. Target org for the first build: the demo org beside pest, or a fresh org.
