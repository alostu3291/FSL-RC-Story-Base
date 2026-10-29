# Rentokil Residential Pest Control Demo

Secondary FSL + Revenue Cloud story: the sale happens **in the field**. A technician
inspects Michael Reyes's home at 316 Ridgewood Dr, Bloomingdale, IL 60108, builds a
priced Quote on a tablet, and Revenue Cloud plus Field Service run the lifecycle.

The storyboard deck is [`pest-control-demo-deck.pptx`](pest-control-demo-deck.pptx). Each scene is
marked Live, Partly live or Vision, and the run-of-show slide lists the status of every scene. AI moments are marked ✧ Einstein, and the "Einstein at every step" slide summarizes them.
Older story assets (screenshots, earlier deck drafts) are on the `pest-control` branch of
[FSL-RC-Story-Base](https://github.com/alostu3291/FSL-RC-Story-Base).

## Enable

In `cumulusci.yml` (or org-specific override):

```yaml
project:
  custom:
    fsl: true
    pest: true
    einstein: true   # AI features (prompt templates); without it they fall back to the rules
    agents: true     # Rentokil Pest Billing Agent
```

Then:

```bash
cci flow run prepare_fsl --org fsl-rc          # if not already applied
cci flow run prepare_pest --org fsl-rc
cci org default fsl-rc
cci task run sync_pricing_data
cci task run refresh_dt_default_pricing        # after price book changes
# Wait until Price_Book_Entry_Decision_Table_v2 finishes (often 2–5 minutes).
# Place Sales Transaction returns "Could not find product with ID" until then.
```

## Catalog (RTK-*)

| SKU | Type | Role |
|-----|------|------|
| RTK-ESSENTIAL | Evergreen monthly | Essential plan |
| RTK-HOME-PROT | Evergreen monthly | Home Protection (demo default) |
| RTK-HOME-PROT-PLUS | Evergreen monthly | Home Protection Plus |
| RTK-TERMITE | Evergreen monthly | Termite upsell (Scene 8) |
| RTK-MOSQUITO | Evergreen monthly | Seasonal mosquito (pause Scene 9) |
| RTK-INITIAL | One-time | Initial Service (auto-added) |
| RTK-RESERVICE | One-time | Billable re-service when uncovered |
| RTK-INSPECTION | One-time | Inspection |
| RTK-WASP-NEST | One-time | Field add-on: wasp and hornet nest removal ($179) |
| RTK-RODENT-EXCL | One-time | Field add-on: rodent exclusion ($349) |
| RTK-ATTIC-SANI | One-time | Field add-on: attic sanitation ($499) |
| RTK-BEDBUG | One-time | Field add-on: bed bug treatment ($649) |

Field add-ons are the products in category `PC-RTK-FIELD` (Field Add-ons); adding a product there makes it available in Find & Add.

## Location pricing

1. Quote shipping ZIP → context tag `ServicePostalCode` ([PestLocation](../../datasets/context_plans/PestLocation/)).
2. `RLM_RTK_Service_Zone__c` maps ZIP / 3-digit prefix → zone multiplier (Bloomingdale `60108` = 1.00, rural `60140` = 1.20, dense `606*` = 0.95).
3. `RLM_RTK_FieldQuote` / `place_pest_demo_order.py` apply the multiplier when placing the Quote. QuantumBit prices are unchanged.
4. **Size and severity adjustment:** the plan tier (not add-ons or Initial Service) also gets a monthly adjustment for the home: 2,000–3,500 sq ft +$10, over 3,500 sq ft +$20, Moderate severity +$10, Heavy +$25. The rules live in `RLM_RTK_FieldQuote` (`SIZE_ADJUSTMENTS`, `SEVERITY_ADJUSTMENTS`), and the quote screen reads them and the zone prices from `pricingFor`. Quoting saves the size, the severity priced and the amount on the inspection (`Home_Size__c`, `Priced_Severity__c`, `Size_Severity_Adjustment__c`), and writes it on the plan quote line's description (for example "Includes a $20/mo size and severity adjustment (2,000–3,500 sq ft +$10, Moderate severity +$10)"), which the proposal PDF shows.

Demo proof: quote Michael at 60108, then change shipping ZIP to 60140 and show the higher net.

## Field Quote (Scene 2)

- **Guided (Account):** open **Michael Reyes** → highlights **Inspect & Quote** → walk the property → review the plan → creates a priced Quote (always adds `RTK-INITIAL`) → **Open quote** on the success panel.
  1. **Walk the property** (`rlmRtkInspectionWalk`): eight zone cards (Exterior Perimeter through Yard). Tap a zone to add a finding (pest, what you see, severity, customer note, internal note), then attach photos to it; the camera opens in the Salesforce mobile app. Zones without activity can be marked clear. Findings are `RLM_RTK_Finding__c` records under an `RLM_RTK_Inspection__c`, and photos are Files on each finding.
  2. **Recommendation rules** (`RLM_RTK_Inspection.recommend`): overall severity is the worst finding. Termites or wood-to-soil contact add Termite; mosquitoes or standing water add Mosquito. Rodents or entry points pick Home Protection, or Home Protection Plus when heavy or three or more. A heavy general-pest finding picks Home Protection; otherwise Essential. Each product carries the findings that justify it.
  3. **Review the plan** (`rlmRtkInspectQuote`): pre-filled from the recommendation with a "Because" list on the recommended plan and add-ons. Changing the plan, severity or add-ons requires a reason, which is saved on the inspection (`Override_Reason__c`) along with the new quote. Plan cards show the zone price ("from $59/mo"), the size readout and severity buttons show their adjustment, and **Price for this home** adds it up: list price, zone, home size, severity, the plan price, add-ons, the monthly total and Initial Service. After the quote, the customer's findings view adds **How your price is set** with the same adjustment.
  4. **Show the customer** (`rlmRtkInspectionFindings`): **Sign & Pay** on the Quote opens with "What we found": each finding with its customer note, photos (tap to enlarge) and the plan on the quote that addresses it. Internal notes never appear. The component can also be added to the Quote record page.
  5. **Treat on the first visit** (`rlmRtkTreatmentChecklist`): the Initial Pest Treatment work order links to the inspection (`WorkOrder.RLM_RTK_Inspection__c`, set by `RLM_RTK_Create_Initial_Work_Order`; older work orders fall back to the order's quote). The checklist sits at the top of the Work Order page and behind the **Treatment** action (`rlmRtkTreatmentAction`) on mobile. For each finding the technician sees the specialist's notes (including internal) and before photos, marks it **Treated** or **Needs follow-up**, notes what was done, and adds after photos. After photos are tagged `ContentVersion.RLM_RTK_Photo_Stage__c = After` and never appear in the customer's "What we found" view.
- **Traditional quote UI:** from that Quote (or quote `00000037`), use **Browse Catalogs** / the line editor like any other RLM quote — accept → **Create Order**.
- **Deep link (dev only):** `/flow/RLM_RTK_Inspect_and_Quote?recordId=<AccountId>`.

## Field Service mobile app

No treatment work order exists until the customer has been inspected, quoted and has signed. The visit itself is a lightweight **Pest Inspection** work order, because the app's Schedule tab only shows appointments whose parent is a work order.

- **Setup:** with `fsl: true` and `pest: true`, `prepare_pest` step 11.5 (`setup_rtk_inspection_visit`) creates **Priya Nair** (142 Lakeview Ct, Bloomingdale IL 60108), an open "Free Pest Inspection" work order and a Dispatched appointment tomorrow at 10:00 assigned to the running user. For fresh runs later, `seed_rtk_prospect_inspection` books a new prospect's inspection (`-o account_name … -o street … -o hour …`) and `seed_rtk_reservice` books a re-service for an existing customer (`-o account_name … -o pest …`; fails unless a guarantee covers the pest). Both report what they booked; see `.cursor/skills/pest-demo-seed-visits/SKILL.md`. To check what an org is missing before deploying, run `python scripts/ai/pest_org_inventory.py --target-org <username>` (`.cursor/skills/pest-demo-org-deploy/SKILL.md`). `ps_fsl` assigns `RLM_FSL_Mobile_Extensions` (Lightning SDK for Field Service Mobile), which LWC quick actions need in the app.
- **Login:** in the FS app choose **Use Custom Domain** and enter the org's My Domain prefix. Winter '27 orgs created before the app supported them (such as `fsl-rc`) can't sign in from iOS.
- **Inspect & Quote** (`rlmRtkFieldVisit`, on the appointment and the work order): Walk the property, then Review the plan, then Create quote, then show the customer the findings and the generated `RLM_RTK_PestProposal` PDF, then **Sign & Pay** (embedded `rlmSignAndPay`), then Booked. Booking creates the order with the `createOrdersFromQuote` standard action, fills the bill-to and ship-to contact from the quote or the account's first contact, activates it, and marks the inspection **Accepted**. The DRO plan then creates the Initial Pest Treatment work order and an unscheduled appointment. The last screen offers six open times for the first treatment (business days at 8, 10, 1 and 3 on the territory's clock, inside the appointment's window, skipping the technician's other appointments); picking one schedules it and dispatches it to the technician (`treatmentSlots` / `bookTreatment`). **Leave for dispatch** keeps it unscheduled for a dispatcher. Every step is resumable: reopening the action picks up at the current stage (`RLM_RTK_FieldVisit.getContext`).
- **Treatment** (`rlmRtkTreatmentAction`, on the work order) is the treatment checklist for the first visit.
- **Find & Add** (`rlmRtkFindAndAdd`, under the checklist in **Treatment**): the technician logs a new finding (saved on the visit's inspection, so it joins the checklist) and picks one-time services from the Field Add-ons category, priced at list price times the customer's service zone. Findings suggest add-ons: wasps or bees for nest removal, rodent entry points or damage for exclusion, attic droppings or rodents for attic sanitation, bed bugs for bed bug treatment. The customer approves on the device. Approved add-ons become work order line items (`RLM_RTK_Approved_By__c` / `RLM_RTK_Approved_At__c`, linked to the finding). When the work order is completed, `RLM_RTK_Bill_Field_Add_Ons` calls `RLM_RTK_FieldAddOn.billAddOns`, which places one priced order for them, activates it and posts the invoice (`RLM_RTK_Add_On_Order__c` on each line). Plan changes, such as adding Termite, use Change the plan below.
- **Change the plan** (`rlmRtkPlanChange`, under Find & Add in **Treatment**; `RLM_RTK_PlanChange`): the technician moves the customer to another tier (Essential, Home Protection, Home Protection Plus), or adds or removes the Termite or Mosquito plan, and the customer approves on the device. Findings recommend plans: rodents for Home Protection, wasps or bees for Home Protection Plus, termites or wood-to-soil contact for Termite, mosquitoes or standing water for Mosquito. The change amends the customer's assets from tomorrow. A same-day amendment fails assetization because it starts on the asset's start date. `initiateAmendment` creates the amendment order for the asset being changed: quantity −1 ends a tier or removes a plan, and 0 anchors an add on the current tier. Place Sales Transaction then adds the new plan line at the customer's zone price. A new tier also keeps the size and severity adjustment the customer pays on their current tier: a home paying $79 for Home Protection ($59 list + $20) sees Plus at $99 (+$20/mo), not its $79 list price. The panel says so: a note names the home's adjustment and its reasons (from the inspection that priced the plan; customers quoted before it was saved get the amount without reasons), each tier shows "= $79 list + $20 size and severity adjustment", and the approve area reads "Home Protection Plan $79 → Home Protection Plus $99 (+$20/mo; adjustment unchanged)". Tier changes set the `UpgradeFrom`/`UpgradeTo` or `DowngradeFrom`/`DowngradeTo` order action subtypes (by price), so assetization records them as upgrades or downgrades. The order is named `Plan change: …`, carries the customer's approval in its description, and is activated and invoiced up to its start date. Only one change can be scheduled at a time; the panel locks until it takes effect.
- **Starting visits:** **Start inspection** in Inspect & Quote and **Start treatment** in the Treatment Checklist action record the technician's arrival (`RLM_RTK_FieldVisit.startVisit`). The appointment goes In Progress with its Actual Start, and the work order goes In Progress with its Start Date. The appointment is the one the action was opened from, otherwise the technician's open one. Restarting keeps the first start time. The treatment checklist, Find & Add and plan change appear once the visit is started, under a "Started at …" line. A Covered re-service's response milestone is met at this point. When the visit has a response guarantee to meet, the Treatment action shows a **Re-service guarantee** card above **Start treatment** (`rlmRtkResponseGuarantee`). Before arrival it shows the deadline, a live countdown and a progress bar, amber in the last 4 hours and red once overdue. After the start it shows when the guarantee was met and how much time was to spare. Visits without a response guarantee don't show it.
- **Completing visits:** the app has no status picker in this org, so both actions finish with a button that completes the work order's open appointments (Actual End and Actual Duration) and then the work order (End Date) (`RLM_RTK_FieldVisit.completeVisit`): **Complete visit** on the last Inspect & Quote screen, **Complete treatment** under the checklist. Completing the treatment work order starts milestone billing.
- **Photos:** `lightning-file-upload` isn't supported in the app, so `rlmRtkPhotoCapture` resizes images to 1600 px JPEG and uploads them through `RLM_RTK_Inspection.uploadPhoto`.
- **Viewing files:** LWCs in the app don't load from the org's domain and only support `standard__webPage` navigation, so relative `/sfc/servlet.shepherd` URLs and the `filePreview` page both fail there. Photos use the absolute `ContentVersion.VersionDataUrl`, and tapping a photo or the proposal opens `rlmFileViewer`, which shows images directly and PDFs as page images. The page rendition (`SVGZ`, `page=N`) is always served gzip-encoded, which the app can't load in an img tag, so `RLM_SignAndPay.pageImage` fetches each page and the viewer decompresses it (`DecompressionStream`).
- LWC actions live in each layout's `platformActionList` (`templates/layouts/pest/`); the Metadata API rejects them in `quickActionList`. Fully quit and reopen the iOS app after deploying LWC changes.

## Recurring visits and guarantees (Scenes 6–7)

Completing the **Initial Pest Treatment** work order starts Field Service coverage (`RLM_RTK_WorkOrderTrigger` → `RLM_RTK_Coverage`, in a queueable). For each active plan asset (quantity above zero) it creates:

| Plan | Guarantee entitlement covers (`Entitlement.RLM_RTK_Covered_Pests__c`) | Visit rule (work type) |
|------|------|------|
| Essential | Ants, Spiders, Cockroaches | Quarterly (`Quarterly Pest Visit`) |
| Home Protection | Essential + Rodents | Monthly (`Monthly Pest Visit`) |
| Home Protection Plus | Home Protection + Wasps / Bees, Other | Monthly (`Monthly Pest Visit`) |
| Seasonal Mosquito | Mosquitoes | Monthly, April through October only (`Mosquito Visit`) |
| Termite | Termites | Yearly (`Termite Monitoring`) |

- **One maintenance plan per customer** ("Rentokil recurring service"), with a maintenance asset and rule per plan. It generates one work order per visit date with a line per plan due that day (`WorkOrderLineItemPerAsset`) and one appointment per work order, for the next four months. `RLM_RTK_Generate_Maintenance_Visits` runs the standard Generate Work Orders action, which Apex can't call directly. Auto-generation is off, because the platform blocks manual generation on auto-generating plans; the nightly sync below generates instead, so the schedule always reaches four months ahead.
- **Generated visits** get the work type, territory, address and contact of the customer's latest visit, and their accepted inspection, so **Treatment** shows the original findings. The recurring work types don't auto-create appointments (`ShouldAutoCreateSvcAppt = false`); the plan creates the one appointment.
- **Re-service:** create a **Pest Re-service** work order on the account and set **Reported Pest**. An active guarantee that lists the pest marks it **Covered**, links the entitlement and its asset, and it's free. Otherwise it's **Not Covered**, and completing it bills `RTK-RESERVICE` ($149) through `RLM_FSL_Bill_Uncovered_Repair`: a "Re-service Visit - WO …" order and a posted invoice. Coverage is rechecked when the pest changes and frozen once the work order is completed.
- **Re-service response guarantee:** every guarantee runs the **Rentokil Re-service Guarantee** entitlement process (`deploy_post_pest_sla`), so a Covered re-service gets a **Re-service Response** milestone due 48 hours after the request, counting Monday to Saturday on the **Rentokil Service Days** business hours (Central): a Wednesday 2 PM request is due Friday 2 PM, and a Saturday 2 PM request is due Tuesday 2 PM. It's met when the technician arrives, meaning the appointment is checked in, started or completed (`RLM_RTK_ServiceAppointmentTrigger`). The work order shows **Milestone Status**, the **Milestones** countdown tracker in the record page sidebar under Service Appointments (pest patch on `RLM_Work_Order_Record_Page`), and a **Milestones** related list with the target, time remaining and whether it was missed. Not Covered re-services have no milestone.
- **Existing customers:** `prepare_pest` step 11 (`setup_rtk_grow`) backfills coverage for every customer with an active plan and generates their visits. It's safe to re-run.
- **Coverage follows the plan.** Upgrades, downgrades, pauses, renewals and cancellations all land in the assets' state periods, so `RLM_RTK_Coverage.sync` rebuilds coverage from them:
  - **Guarantees:** one entitlement per active stretch of a plan asset. An upgrade ends the old tier's guarantee the day before the change and starts the new tier's; a pause ends the guarantee at the pause and adds "… guarantee from <date>" for the resume; a renewal or cancellation moves the end date. Re-service checks use the guarantee active that day.
  - **Upcoming visits:** a visit line for a day the plan isn't active moves to the tier that replaced it, so an upgrade keeps the customer's visit days; otherwise it's removed, along with the visit and its appointment when no lines are left. Visits take the work type of their leading plan.
  - **Visit rules:** an ended plan's rule is removed, a paused plan's rule skips to the first visit after it resumes, and a new plan gets a rule (continuing after any visits it took over). The maintenance plan's work type follows the plan that leads the remaining visits.
- **When it syncs:** `RLM_RTK_AssetTrigger` syncs a customer a minute after any plan asset changes, which is when assetization finishes (from **Change the plan** or the standard Amend, Renew and Cancel actions). The **RLM RTK Nightly Coverage Sync** scheduled flow syncs every customer at 3 AM org time, which also covers changes that take effect that day, and generates visits as the four-month window moves forward.

## Rentokil documents

With `docgen: true`, `prepare_pest` steps 12–14 deploy `unpackaged/post_pest_docgen`:

| Template | Used for | Data |
|----------|----------|------|
| `RLM_RTK_PestProposal` | Quote **Create Proposal** (pick it in the template list) | `RLMRTKProposalExtract` / `RLMRTKProposalTransform`: inspection findings ("What We Found at Your Home", via the `RLM_RTK_Finding__c.Quote_Id__c` formula; one "No active activity recorded" row when the quote has no inspection), service plans (lines with a billing frequency), one-time services, service address, specialist, and the `RLM_RTK_Monthly_Total__c` / `RLM_RTK_One_Time_Total__c` Quote roll-ups |
| `RLM_RTK_Invoice` | Invoice documents | Same platform invoice mappings as `RLM_InvoiceTemplate`; only branding differs |

The proposal also has a **Why We Recommend This Plan** box (`WhyThisPlan`, from `Quote.RLM_RTK_Plan_Explanation__c`; see Einstein AI below).

Invoices keep using the org default (`BillingSettings.defaultInvoiceDocTemplate`) until it points at `RLM_RTK_Invoice`.

The proposal docx is generated by `scripts/docgen/build_rtk_pest_proposal.py` and its data mappings by `scripts/docgen/build_rtk_proposal_odts.py`; edit the scripts and rebuild rather than hand-editing the `.dt` or `.rpt-meta.xml` files. Inspection photos are not in the PDF (image tokens fail in this org); customers see them at Sign & Pay. Redeploying a template creates a new draft version, so run `activate_docgen_templates` afterwards.

## Einstein AI

Every AI feature suggests and the technician or customer decides. Prices always come from the rules and the customer's zone, never from the model. Each feature has a rules fallback, so with `einstein: false`, or when a call fails, the demo still works and the card is labelled **From the records** instead of **Einstein**.

`RLM_RTK_AI` (in `post_pest`) holds the features and the fallbacks. It finds `RLM_RTK_EinsteinGenerator` (in `unpackaged/post_pest_ai`, `prepare_pest` steps 1.6–1.7) by name at runtime, because `ConnectApi.EinsteinLLM` doesn't compile in orgs without Einstein. The generator calls the six `RLM_RTK_*` prompt templates (GPT-4o mini). A metadata deploy leaves new template versions inactive, so `activate_pest_prompt_templates` runs after every deploy. Each AI call runs before any DML, because a callout can't follow DML in the same transaction.

| # | Feature | Where | Template | Saved on |
|---|---------|-------|----------|----------|
| 1 | Pre-visit brief: why they called, plans, last visit, open balance, pending plan changes, what to look for | Top of Inspect & Quote and Treatment (`rlmRtkVisitBrief`) | `RLM_RTK_Visit_Brief` | `WorkOrder.RLM_RTK_AI_Brief__c` / `_At__c` (Refresh regenerates) |
| 2 | Photo suggestions: pest, evidence and severity from a finding photo; **Review & apply** pre-fills the finding editor | Walk the property, after a photo upload | `RLM_RTK_Photo_Finding` (image input as `SOBJECT://ContentDocument`) | Nothing until the technician saves |
| 3 | Notes into findings: dictate with the keyboard mic (the Field Service app doesn't support in-page speech recognition), then **Fill from notes** | Finding editor | `RLM_RTK_Notes_Finding`; keyword fallback | Nothing until saved |
| 4 | Why this plan: two plain sentences tying the plan to the findings | Review the plan, "What we found" at Sign & Pay, proposal PDF | `RLM_RTK_Plan_Explanation` | `RLM_RTK_Inspection__c.Plan_Explanation__c` (reused until the recommendation changes) and the Quote |
| 5 | **Ask Einstein** in Find & Add and Change the plan: up to three extra picks with a reason, only from offered products, and only when the reason names a pest that product treats | `rlmRtkFindAndAdd`, `rlmRtkPlanChange` | `RLM_RTK_Product_Suggestions` | Nothing; the customer still approves |
| 6 | Visit summary: what was treated, what was approved, plan changes, next visit; emailed to the contact on completion | Done screen of both actions (`rlmRtkVisitSummary`) | `RLM_RTK_Visit_Summary` | `WorkOrder.RLM_RTK_Visit_Summary__c` / `RLM_RTK_Summary_Sent_At__c` (sent once) |

**Billing agent (Scenes 8–9).** With `agents: true`, `prepare_pest` steps 15–18 deploy `unpackaged/post_pest_agent`: the **Rentokil Pest Billing Agent** (Agentforce employee agent) with a Pest Bill Questions topic, and the `RLM_RTK_Pest_Billing_Agent` permission set. Its one action, `RLM_RTK_BillExplainer` (invocable Apex), finds the bill by amount ($366 matches $366.30; a total of open bills also matches), number or customer, and lists each line: plan charges and periods, the initial service milestone, visit add-ons with their work order, plan-change credits and proration, and tax. The agent only rephrases those facts. Ask it "Why is Sam Patel's bill $366?" or "Why did Dana get a $20 bill after changing plans?". The CLI's `sf agent preview` can't start employee agents, so test them in the Agentforce panel. The repo's `post_agents` billing agents need the `billing_agents` managed package and aren't used here.

## Nine scenes

| # | Scene | What to show |
|---|-------|----------------|
| 1 | Plan the day | Bloomingdale territory, tech schedule; **Einstein visit brief** on the appointment |
| 2 | Inspect & quote | Tablet flow + location zone on waterfall; **photo suggestions** and **dictated notes** fill findings |
| 3 | Sign & pay | **Why this plan** on screen and in the PDF; **Create Proposal** → preview → **Sign & Pay** (mock card + signature tied to the PDF), or Quote highlight **Sign & Pay** after a proposal exists → Create Order |
| 4 | Plan builds itself | Activate Order → assets per plan, DRO fulfillment plan creates the Initial Pest Treatment WO + Service Appointment; `RTK-INITIAL` billing schedule waits on the "Initial Treatment Complete" milestone, monthly plans are Ready for Invoicing |
| 5 | First treatment | Complete WO → fulfillment step completed, milestone accomplished, order invoiced (`RLM_FSL_Complete_Fulfillment_Step`); **Ask Einstein** in Find & Add; **visit summary** emailed |
| 6 | Recurring visits | Account → Maintenance Plans → "Rentokil recurring service": a rule per plan and the generated visits (Michael's Home Protection is monthly; mosquito resumes in April); routing = package vision |
| 7 | Re-service | Pest Re-service WO with **Reported Pest**: Ants → Covered by the Home Protection guarantee, free, with a 48-hour **Re-service Response** milestone met when the technician starts the visit; Bed Bugs → Not Covered, completion bills `RTK-RESERVICE` via `RLM_FSL_BillRepair` |
| 8 | Upsell & upgrade | Find & Add finding → **Change the plan** (Termite add or tier upgrade) on an amendment order, invoiced; a minute later the new plan's guarantee and visits replace the old tier's (same visit days); **Ask Einstein**; billing agent explains the prorated bill |
| 9 | Pause / renew | Mosquito qty amendment Nov/Apr splits the mosquito guarantee around the pause; renew plan asset extends its guarantee; billing agent answers "why is my bill $366?" |

## Driver

```bash
python scripts/place_pest_demo_order.py --target-org fsl-rc --activate --complete-initial
```

## Teardown

```bash
cci task run delete_pest_data --org fsl-rc
```

Does not delete transactional quotes/orders; use Account Utilities for those.
