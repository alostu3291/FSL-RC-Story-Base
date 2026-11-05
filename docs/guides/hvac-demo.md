# Brightline Home Comfort Residential HVAC Demo

A Field Service + Revenue Cloud story where the sale happens **in the home**. A comfort advisor
checks Priya Raman's heating and cooling at 1240 Aurora Ave, Naperville, IL 60540, sells a
comfort agreement and a repair on a tablet, and Revenue Cloud plus Field Service run the
lifecycle: tune-ups twice a year, priority response on a no-cool call, and a good / better /
best replacement when a system is at the end of its life.

The storyboard deck is [`hvac-demo-deck.pptx`](hvac-demo-deck.pptx). Each scene is marked Live,
Partly live or Vision, and the run-of-show slide lists the status of every scene. AI moments are
marked ✧ Einstein. The build plan, including the commercial extension, is
[`docs/analysis/hvac-demo-build-plan.md`](../analysis/hvac-demo-build-plan.md).

The HVAC demo is built on the pest demo's framework ([`pest-control-demo.md`](pest-control-demo.md))
with its own `RLM_HVAC_*` metadata, so both can run in one org.

## Enable

In `cumulusci.yml` (or an org-specific override):

```yaml
project:
  custom:
    fsl: true
    hvac: true
    einstein: true   # AI features (prompt templates); without it they fall back to the rules
    agents: true     # Brightline Billing Agent
```

Then:

```bash
cci flow run prepare_fsl --org hvac            # if not already applied
cci flow run prepare_hvac --org hvac
cci task run refresh_dt_default_pricing --org hvac   # after price book changes
```

Wait until the pricing decision table finishes refreshing (often 2–5 minutes) before quoting.

Manual steps after the flow:
- **Theme:** Setup → **Themes and Branding** → menu on **Brightline Home Comfort** → **Activate**.
- **Mobile login:** turn on PKCE (Setup → OAuth and OpenID Connect Settings), or the iOS app
  can't sign in. See [`fsl-mobile-setup.md`](fsl-mobile-setup.md).

## Seed demo data

Three tasks seed the three stories; see `.cursor/skills/hvac-demo-seed-visits/SKILL.md` for the
full workflow, checks and report template.

| Story | Task |
|-------|------|
| New customer (Scenes 1–5) | `seed_hvac_prospect_check -o account_name … -o street …` books a free System Check |
| Replacement (Scene 8) | The same task for another prospect; the advisor records old or failing equipment |
| Existing customer (Scenes 7–8) | `seed_hvac_agreement_customer` runs a full sale so the customer has a live agreement, then `seed_hvac_service_call -o account_name … -o issue "No Cool"` books the covered call |

`prepare_hvac` step 11.5 books Priya Raman's System Check. A prospect who signed is used up;
pick a new name and street for the next run.

## Catalog (HVAC-*)

| SKU | Type | Price | Role |
|-----|------|-------|------|
| HVAC-BASIC | Evergreen monthly, per system | $19 | Comfort Basic: spring and fall tune-ups, 24-hour priority response, 10% off repairs |
| HVAC-PLUS | Evergreen monthly, per system | $29 | Comfort Plus: 8-hour response, 15% off repairs |
| HVAC-PREMIER | Evergreen monthly, per system | $45 | Comfort Premier: 4-hour response, covered parts and labor |
| HVAC-IAQ | Evergreen monthly | $15 | Indoor Air Quality: UV lamp care and filter changes, one visit each quarter |
| HVAC-WATER-HEATER | Evergreen monthly | $8 | Water Heater Care: yearly flush and anode check |
| HVAC-SYSTEM-CHECK | One-time | $0 | Free System Check |
| HVAC-TUNEUP | One-time, per system | $129 | Initial Tune-up, added to every agreement; bills when the visit is done |
| HVAC-DIAGNOSTIC | One-time | $89 | Billed for a no-cool or no-heat call that no agreement covers |
| HVAC-CAPACITOR, -CONTACTOR, -COIL-CLEAN, -DRAIN-CLEAR, -REFRIGERANT, -BLOWER-MOTOR | One-time repairs | $185, $165, $249, $129, $395, $650 | Quoted from findings and added in Find & Add |
| HVAC-REPL-GOOD, -BETTER, -BEST | One-time | $8,900, $11,500, $14,800 | Good / Better / Best Heat Pump System (14.3, 16 and 18 SEER2), installed |
| HVAC-DRO-FSL, HVAC-DRO-INSTALL | Fulfillment | — | Create the Initial Tune-up and Replacement Install work orders |

## Pricing

1. **Service zone:** the quote's shipping ZIP picks an `RLM_HVAC_Service_Zone__c` by ZIP or
   3-digit prefix: Naperville `60540` and the suburbs 1.00, south suburbs `604` 1.10, rural
   Kendall County `60545` 1.20, dense Chicago `606` 0.95. Every price is multiplied by it.
2. **Equipment age:** the oldest main system's age adds a monthly amount to the agreement per
   system: 0–5 years +$0, 6–10 +$3, 11–15 +$6, over 15 +$10 (`RLM_HVAC_FieldQuote.AGE_ADJUSTMENTS`).
   Add-ons, tune-ups and repairs have no age adjustment.
3. **Systems:** the agreement, its age adjustment and the Initial Tune-up are per system
   (quantity = systems in the home).
4. **Repairs at signup** get the new agreement's discount, capped at 15% (Premier's covered
   repairs start once the agreement is active).

Priya, two systems from 2015 (11 years old): Comfort Plus 2 × ($29 + $6) = $70/mo, Indoor Air
Quality $15/mo, so $85/mo; once: two Initial Tune-ups $258 plus a capacitor at 15% off $157.25,
so $415.25.

## Check & Quote (Scenes 2–3)

**Check & Quote** (`rlmHvacFieldVisit`) runs from the System Check appointment or work order in
the Field Service app, or from the Account. Steps: Check, Agreement, Sign, Booked. Every step is
resumable: reopening the action picks up where it stopped.

1. **Start the system check** records the arrival (appointment and work order In Progress) and
   creates the assessment (`RLM_HVAC_Assessment__c`).
2. **Check** (`rlmHvacSystemWalk`): pick the system type (AC + furnace, heat pump) and the
   number of systems, then one card per piece of equipment: Outdoor Unit, Furnace, Air Handler,
   Heat Pump, Boiler, Thermostat, Ductwork, Water Heater, Indoor Air. A finding has a component,
   condition, urgency (Monitor, Repair Soon, Safety), the data plate (make, model, serial,
   install year), a reading, a customer note, an internal note and photos (`RLM_HVAC_Finding__c`).
   Equipment with nothing wrong can be marked good.
3. **Recommendation** (`RLM_HVAC_Assessment.recommend`): each finding maps to a repair. The
   worst urgency sets the overall urgency; a cracked heat exchanger or CO reading is always
   Safety. Premier is recommended for a replacement, a Safety finding or two or more repairs;
   Plus for one repair, equipment over 10 years old or more than one system; otherwise Basic.
   Filter or allergy findings add Indoor Air Quality; water heater findings add Water Heater
   Care. **Replacement is recommended** when the oldest system is 12 or more years old, a main
   system has failed at over 10 years, or the heat exchanger is cracked.
4. **Agreement** (`rlmHvacAssessQuote`): pre-filled from the recommendation with a "Because"
   list on each product. Changing it needs a reason, saved on the assessment. **Price for this
   home** adds it up: list, zone, age, systems, add-ons, repairs and the monthly and one-time totals.
5. **Sign** (`rlmHvacFindings` + `rlmSignAndPay`): what was found, with photos and the customer
   notes (never the internal notes), **How your price is set**, the **Why this agreement**
   explanation, and the Brightline proposal PDF; then signature and card on file (a mock).
6. **Booked:** creates and activates the order, marks the assessment Accepted, and offers six
   open times for the Initial Tune-up (Monday to Saturday at 8, 10, 1 and 3 Central, skipping the
   technician's other appointments). **Complete visit** closes the System Check.

**Replacement Options** (`rlmHvacReplacementOptions`, Work Order action) shows Good / Better /
Best Heat Pump System cards at the home's zone price, with the oldest equipment's age and the
reason, and the suggested tier when replacement is recommended. Picking one creates a
replacement quote whose explanation names the equipment's age, the Safety and Repair Soon
findings and the chosen system. Its proposal uses `RLM_HVAC_Replacement_Proposal`. Signing
creates the order; fulfillment creates a **Replacement Install** work order with the new system
as its asset, and the system bills (milestone "Replacement Install Complete") when that work
order is completed.

## Field Service mobile app

App login, settings and licensing: [`fsl-mobile-setup.md`](fsl-mobile-setup.md). Building
actions: `.cursor/skills/fsl-mobile-lwc/SKILL.md`. LWC actions live in each layout's
`platformActionList`; fully quit and reopen the iOS app after deploying LWC changes.

- **Service Checklist** (`rlmHvacServiceAction`, Work Order action) is the technician's screen
  for every visit after the sale: the visit brief, the priority response card on a covered call,
  **Start visit**, then the checklist, Find & Add and Change the plan, then **Complete**.
- **Checklist** (`rlmHvacServiceChecklist`): tune-up steps for the system type and the season
  (cooling steps in spring, heating in fall) with readings such as thermostat, capacitor
  µF, refrigerant pressure, CO and temperature split (`WorkOrder.RLM_HVAC_Service_Steps__c`),
  then the assessment's findings to work: mark each Done or Needs follow-up, note what was done,
  add a reading after the repair and after photos.
- **Find & Add** (`rlmHvacFindAndAdd`): log a new finding and pick repairs from the Field
  Add-ons category at the zone price less the member discount (Basic 10%, Plus 15%, Premier
  100%). The customer approves on the device. Completing the work order bills approved repairs
  on their own order and invoice (`RLM_HVAC_Bill_Field_Add_Ons`); a Premier repair bills $0.
- **Change the plan** (`rlmHvacPlanChange`): move between Basic, Plus and Premier, or add or
  remove Indoor Air Quality and Water Heater Care. The number of systems carries over. The
  amendment starts tomorrow and is invoiced up to its start date; coverage and visits follow a
  minute after assetization.
- **Photos** use `rlmHvacPhotoCapture` (resized JPEG through Apex); the app doesn't support
  `lightning-file-upload`. Files open in `rlmFileViewer`.

## Coverage and seasonal visits (Scenes 5–7)

Completing the **Initial Tune-up** work order finishes the fulfillment step, accomplishes the
"Initial Tune-up Complete" milestone and posts the first invoice (tune-up, first month and
repairs). It also starts coverage (`RLM_HVAC_WorkOrderTrigger` → `RLM_HVAC_Coverage`):

| Agreement | Entitlement covers (`RLM_HVAC_Covered_Systems__c`) | Visits (work type) | Covered call priority and response |
|-----------|------|------|------|
| Comfort Basic | Cooling, Heating | April and October (`Spring AC Tune-up`, `Fall Furnace Tune-up`) | Medium, 24 hours |
| Comfort Plus | Cooling, Heating | April and October | High, 8 hours |
| Comfort Premier | Cooling, Heating | April and October | Critical, 4 hours |
| Indoor Air Quality | Indoor Air Quality | Every 3 months (`Indoor Air Quality Visit`) | Medium, 24 hours |
| Water Heater Care | Water Heater | Yearly (`Water Heater Flush`) | Medium, 24 hours |

- **One maintenance plan per customer** ("Brightline comfort agreement") with a rule per
  product; it generates the next visit, with one line per product due that day, and each visit
  takes the work type of its leading line. `RLM_HVAC_Generate_Maintenance_Visits` runs the
  standard Generate Work Orders action; the **RLM HVAC Nightly Coverage Sync** flow keeps the
  schedule moving forward.
- **No-Cool / No-Heat Call:** set **Reported Issue** (No Cool, No Heat, Noise, Water Leak,
  Thermostat, Air Quality, Water Heater). An active entitlement covering that system marks it
  **Covered**: no diagnostic fee, Priority from the agreement tier, and the **Brightline Comfort
  Response** entitlement process starts a **Priority Response** milestone (4, 8 or 24 service
  hours, 7 AM–9 PM). It's met when the technician arrives (checked in, started or completed;
  `RLM_HVAC_ServiceAppointmentTrigger`). The Service Checklist shows the deadline and a live
  countdown before arrival, and the time to spare after. **Not Covered** calls have no
  milestone, and completing them bills the $89 diagnostic fee (`RLM_FSL_Bill_Uncovered_Repair`).
- **Coverage follows the agreement:** `RLM_HVAC_AssetTrigger` resyncs a customer a minute after
  any agreement asset changes (Change the plan, Amend, Renew, Cancel). An upgrade ends the old
  tier's entitlement the day before and starts the new tier's; upcoming visits keep their days.
- **Existing customers:** `prepare_hvac` step 11 (`setup_hvac_grow`) backfills coverage for every
  customer with an active agreement. It's safe to re-run.

## Brightline documents

With `docgen: true`, `prepare_hvac` steps 12–14 deploy `unpackaged/post_hvac_docgen`, activate
the templates and re-upload their binaries:

| Template | Used for | Data |
|----------|----------|------|
| `RLM_HVAC_Proposal` | Agreement quotes (Check & Quote) | `RLMHVACProposalExtract` / `Transform`: what we found (equipment, condition, urgency), your systems, the agreement per system, repairs, why we recommend it, monthly and one-time totals |
| `RLM_HVAC_Replacement_Proposal` | Replacement quotes (Replacement Options) | `RLMHVACReplacementProposalExtract` / `Transform`: findings, why we recommend replacing it, your new system, install-day next steps and warranty |
| `RLM_HVAC_Invoice` | Invoice documents | Platform invoice mappings with Brightline branding |

With `hvac_commercial: true` as well, `prepare_hvac_commercial` steps 7–9 deploy
`unpackaged/post_hvac_commercial_docgen`. The Book Contract and Book Project actions and the
Invoice by Site card get a button that creates the PDF and attaches it to the record
(`RLM_HVAC_CommercialDocuments`):

| Template | Used for | Data |
|----------|----------|------|
| `RLM_HVAC_Contract_Proposal` | Multi-site contract quotes | `RLMHVACContractProposalExtract` / `Transform`: a row per site (units, tons, response, price per year), the term, monthly invoice and contract total, then each site's services and the units they cover |
| `RLM_HVAC_Project_Proposal` | Capital project quotes | `RLMHVACProjectProposalExtract` / `Transform`: scope, unit replacements and crane lift, and the 40/40/20 milestone schedule (Quote `RLM_HVAC_Deposit_Amount__c`, `Install_Amount__c`, `Commissioning_Amount__c`) |
| `RLM_HVAC_Commercial_Invoice` | Contract and project invoices | `RLMHVACCommercialInvoiceExtract` / `Transform`: the PO number, due date and a subtotal per site from `RLM_HVAC_Invoice_Site__c`, which `RLM_HVAC_ContractInvoice.stampSites` rebuilds when the invoice posts and again before each PDF |

Rebuild them with `scripts/docgen/build_hvac_commercial_docs.py` and
`build_hvac_commercial_odts.py`; the second script also writes the `.dt-meta.xml` token lists.
After a redeploy, DocGen can keep rendering the previous template version for a minute or two.

Build the proposals with `scripts/docgen/build_hvac_proposal.py` (add `replacement` for the
replacement proposal) and `build_hvac_proposal_odts.py`, and the invoice with
`build_hvac_invoice.py`; don't hand-edit the `.dt` or `.rpt-meta.xml` files. Redeploying a
template creates a new draft version, so run `activate_docgen_templates` and
`fix_hvac_document_template_binaries` afterwards.

## Brand: Brightline Home Comfort

A fictional brand; customer-facing text says Brightline, API names keep `RLM_HVAC_*` / `HVAC-*`.

| Color | Hex | Used for |
|-------|-----|----------|
| Navy | `#1B3A5C` | Primary: Lightning brand color, DocGen header bands and totals |
| Ember | `#F26B3A` | Accent: tagline, highlights |
| Glacier | `#3BA7D9` | Secondary accent |
| Mist | `#EEF3F7` | Backgrounds |
| Ink | `#1E2A35` | Text |

- **Logos:** `scripts/brand/build_brightline_assets.py` writes the kit to `scripts/brand/brightline/`,
  the DocGen logos and the Lightning header image.
- **Lightning theme:** `prepare_hvac` step 19 (`deploy_post_hvac_brand`) deploys `RLM_Brightline`;
  activate it by hand (see Enable).
- **Field Service mobile colors** live on `FieldServiceMobileSettings` and are left at the org's
  defaults (the `field-service-mobile-branding-configure` skill changes them).

## Einstein AI

Every AI feature suggests and a person decides. Prices always come from the rules and the
customer's zone. With `einstein: false`, or when a call fails, each card is built from the
records and labelled **From the records**.

`RLM_HVAC_AI` holds the features and fallbacks; it finds `RLM_HVAC_EinsteinGenerator`
(`unpackaged/post_hvac_ai`, steps 1.6–1.7) at runtime and calls six prompt templates.
`activate_hvac_prompt_templates` runs after every deploy.

| Feature | Where | Template |
|---------|-------|----------|
| Visit brief: why they called, systems and ages, agreements, last visit, open balance, what to look for | Top of Check & Quote and Service Checklist (`rlmHvacVisitBrief`) | `RLM_HVAC_Visit_Brief` |
| Photo finding: reads make, model, serial and install year off a data plate, or the component, condition and urgency from a photo | Check, after a photo upload | `RLM_HVAC_Photo_Finding` |
| Notes into findings: dictate with the keyboard mic, then fill the finding | Finding editor | `RLM_HVAC_Notes_Finding` |
| Why this agreement | Agreement step, Sign, the proposal PDF | `RLM_HVAC_Plan_Explanation` |
| **Ask Einstein**: up to three extra repairs or agreement changes, each with a reason, only from offered products | Find & Add, Change the plan | `RLM_HVAC_Product_Suggestions` |
| Visit summary: what was fixed, what's still open, the next visit; emailed once on completion | Done screen of both actions (`rlmHvacVisitSummary`) | `RLM_HVAC_Visit_Summary` |

**Billing agent (Scene 9).** With `agents: true`, steps 15–18 deploy the **Brightline Billing
Agent** (Agentforce employee agent) with an HVAC Bill Questions topic. Its action,
`RLM_HVAC_BillExplainer`, finds the bill by amount, number or customer and lists each line:
agreement charges and periods, the tune-up milestone, visit repairs with their work order,
agreement-change credits and proration, and tax. Ask "Why is Dana Whitfield's bill $369.88?"
(first month of Comfort Plus $35 and IAQ $15, the tune-up $129 and a capacitor $157.25, plus
10% tax). Test it in the Agentforce panel.

**Commercial invoices by site.** With `hvac_commercial: true` as well, `prepare_hvac_commercial`
steps 10–12 deactivate the agent, deploy `unpackaged/post_hvac_commercial_agent` and activate it
again. That bundle is a full copy of the planner with a second topic, Commercial Invoice by Site,
so keep the HVAC Bill Questions topic in step with `unpackaged/post_hvac_agent`. Its action,
`RLM_HVAC_SiteInvoiceExplainer`, finds the property group's invoice by record, number, amount or
site. It lists each site's services, charges and tax, the PO and due date, and for a capital
project invoice the milestone and its share of each line. Ask "Explain the latest Lakeshore
Property Group invoice by site" ($4,551.13 across seven sites under PO LPG-PO-2026-118), "What is
Harvest Table Restaurant paying for on it?" ($540.50, 11.9% of the invoice) or "What milestone
is DOC-000000009 billing?" (the 40% installation milestone).

## Nine scenes

| # | Scene | What to show |
|---|-------|--------------|
| 1 | Plan the day | Naperville schedule in the app; the System Check is first; **Einstein visit brief** |
| 2 | Check & quote | Equipment cards, findings with urgency, data plate from a photo, recommended agreement, Price for this home |
| 3 | Sign & pay | Why this agreement, proposal PDF, Sign & Pay, order activated, first tune-up booked |
| 4 | The agreement builds itself | Order → fulfillment plan → Initial Tune-up work order; assets per agreement; tune-up billing waits on its milestone |
| 5 | First tune-up | Service Checklist: season's steps with readings, findings fixed with photos, Find & Add; Complete posts the invoice, starts coverage and emails the summary |
| 6 | Seasonal tune-ups | Maintenance plan with spring and fall tune-ups and quarterly IAQ visits; routing is package vision |
| 7 | No-cool call | Covered: High priority, 8-hour milestone and countdown, met on arrival, member price in Find & Add; Not Covered: $89 diagnostic billed |
| 8 | Replace or upgrade | Replacement Options Good / Better / Best, replacement proposal, Replacement Install work order billed at completion; or Change the plan to Premier |
| 9 | Bill questions & renewal | Billing agent explains a bill line by line; adding a system mid-term and renewal with uplift are vision |
