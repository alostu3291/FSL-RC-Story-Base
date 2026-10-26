# Rentokil Residential Pest Control Demo

Secondary FSL + Revenue Cloud story: the sale happens **in the field**. A technician
inspects Michael Reyes's home at 316 Ridgewood Dr, Bloomingdale, IL 60108, builds a
priced Quote on a tablet, and Revenue Cloud plus Field Service run the lifecycle.

Story assets (deck, screenshots) live on the `pest-control` branch of
[FSL-RC-Story-Base](https://github.com/alostu3291/FSL-RC-Story-Base).

## Enable

In `cumulusci.yml` (or org-specific override):

```yaml
project:
  custom:
    fsl: true
    pest: true
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
3. `RLM_RTK_FieldQuote` / `place_pest_demo_order.py` apply the multiplier (and severity / sqft uplift) when placing the Quote. QuantumBit prices are unchanged.

Demo proof: quote Michael at 60108, then change shipping ZIP to 60140 and show the higher net.

## Field Quote (Scene 2)

- **Guided (Account):** open **Michael Reyes** → highlights **Inspect & Quote** → walk the property → review the plan → creates a priced Quote (always adds `RTK-INITIAL`) → **Open quote** on the success panel.
  1. **Walk the property** (`rlmRtkInspectionWalk`): eight zone cards (Exterior Perimeter through Yard). Tap a zone to add a finding (pest, what you see, severity, customer note, internal note), then attach photos to it; the camera opens in the Salesforce mobile app. Zones without activity can be marked clear. Findings are `RLM_RTK_Finding__c` records under an `RLM_RTK_Inspection__c`, and photos are Files on each finding.
  2. **Recommendation rules** (`RLM_RTK_Inspection.recommend`): overall severity is the worst finding. Termites or wood-to-soil contact add Termite; mosquitoes or standing water add Mosquito. Rodents or entry points pick Home Protection, or Home Protection Plus when heavy or three or more. A heavy general-pest finding picks Home Protection; otherwise Essential. Each product carries the findings that justify it.
  3. **Review the plan** (`rlmRtkInspectQuote`): pre-filled from the recommendation with a "Because" list on the recommended plan and add-ons. Changing the plan, severity or add-ons requires a reason, which is saved on the inspection (`Override_Reason__c`) along with the new quote.
  4. **Show the customer** (`rlmRtkInspectionFindings`): **Sign & Pay** on the Quote opens with "What we found": each finding with its customer note, photos (tap to enlarge) and the plan on the quote that addresses it. Internal notes never appear. The component can also be added to the Quote record page.
  5. **Treat on the first visit** (`rlmRtkTreatmentChecklist`): the Initial Pest Treatment work order links to the inspection (`WorkOrder.RLM_RTK_Inspection__c`, set by `RLM_RTK_Create_Initial_Work_Order`; older work orders fall back to the order's quote). The checklist sits at the top of the Work Order page and behind the **Treatment** action (`rlmRtkTreatmentAction`) on mobile. For each finding the technician sees the specialist's notes (including internal) and before photos, marks it **Treated** or **Needs follow-up**, notes what was done, and adds after photos. After photos are tagged `ContentVersion.RLM_RTK_Photo_Stage__c = After` and never appear in the customer's "What we found" view.
- **Traditional quote UI:** from that Quote (or quote `00000037`), use **Browse Catalogs** / the line editor like any other RLM quote — accept → **Create Order**.
- **Deep link (dev only):** `/flow/RLM_RTK_Inspect_and_Quote?recordId=<AccountId>`.

## Field Service mobile app

No treatment work order exists until the customer has been inspected, quoted and has signed. The visit itself is a lightweight **Pest Inspection** work order, because the app's Schedule tab only shows appointments whose parent is a work order.

- **Setup:** with `fsl: true` and `pest: true`, `prepare_pest` step 11.5 (`setup_rtk_inspection_visit`) creates **Priya Nair** (142 Lakeview Ct, Bloomingdale IL 60108), an open "Free Pest Inspection" work order and a Dispatched appointment tomorrow at 10:00 assigned to the running user. `ps_fsl` assigns `RLM_FSL_Mobile_Extensions` (Lightning SDK for Field Service Mobile), which LWC quick actions need in the app.
- **Login:** in the FS app choose **Use Custom Domain** and enter the org's My Domain prefix. Winter '27 orgs created before the app supported them (such as `fsl-rc`) can't sign in from iOS.
- **Inspect & Quote** (`rlmRtkFieldVisit`, on the appointment and the work order): Walk the property, then Review the plan, then Create quote, then show the customer the findings and the generated `RLM_RTK_PestProposal` PDF, then **Sign & Pay** (embedded `rlmSignAndPay`), then Booked. Booking creates the order with the `createOrdersFromQuote` standard action, fills the bill-to and ship-to contact from the quote or the account's first contact, activates it, and marks the inspection **Accepted**. The DRO plan then creates the Initial Pest Treatment work order and an unscheduled appointment. The last screen offers six open times for the first treatment (business days at 8, 10, 1 and 3 on the territory's clock, inside the appointment's window, skipping the technician's other appointments); picking one schedules it and dispatches it to the technician (`treatmentSlots` / `bookTreatment`). **Leave for dispatch** keeps it unscheduled for a dispatcher. Every step is resumable: reopening the action picks up at the current stage (`RLM_RTK_FieldVisit.getContext`).
- **Treatment** (`rlmRtkTreatmentAction`, on the work order) is the treatment checklist for the first visit.
- **Find & Add** (`rlmRtkFindAndAdd`, under the checklist in **Treatment**): the technician logs a new finding (saved on the visit's inspection, so it joins the checklist) and picks one-time services from the Field Add-ons category, priced at list price times the customer's service zone. Findings suggest add-ons: wasps or bees for nest removal, rodent entry points or damage for exclusion, attic droppings or rodents for attic sanitation, bed bugs for bed bug treatment. The customer approves on the device. Approved add-ons become work order line items (`RLM_RTK_Approved_By__c` / `RLM_RTK_Approved_At__c`, linked to the finding). When the work order is completed, `RLM_RTK_Bill_Field_Add_Ons` calls `RLM_RTK_FieldAddOn.billAddOns`, which places one priced order for them, activates it and posts the invoice (`RLM_RTK_Add_On_Order__c` on each line). Plan changes, such as adding Termite, still go through Flag Expansion for now.
- **Completing visits:** the app has no status picker in this org, so both actions finish with a button that completes the work order's open appointments and then the work order (`RLM_RTK_FieldVisit.completeVisit`): **Complete visit** on the last Inspect & Quote screen, **Complete treatment** under the checklist. Completing the treatment work order starts milestone billing.
- **Photos:** `lightning-file-upload` isn't supported in the app, so `rlmRtkPhotoCapture` resizes images to 1600 px JPEG and uploads them through `RLM_RTK_Inspection.uploadPhoto`.
- LWC actions live in each layout's `platformActionList` (`templates/layouts/pest/`); the Metadata API rejects them in `quickActionList`. Fully quit and reopen the iOS app after deploying LWC changes.

## Rentokil documents

With `docgen: true`, `prepare_pest` steps 12–14 deploy `unpackaged/post_pest_docgen`:

| Template | Used for | Data |
|----------|----------|------|
| `RLM_RTK_PestProposal` | Quote **Create Proposal** (pick it in the template list) | `RLMRTKProposalExtract` / `RLMRTKProposalTransform`: inspection findings ("What We Found at Your Home", via the `RLM_RTK_Finding__c.Quote_Id__c` formula; one "No active activity recorded" row when the quote has no inspection), service plans (lines with a billing frequency), one-time services, service address, specialist, and the `RLM_RTK_Monthly_Total__c` / `RLM_RTK_One_Time_Total__c` Quote roll-ups |
| `RLM_RTK_Invoice` | Invoice documents | Same platform invoice mappings as `RLM_InvoiceTemplate`; only branding differs |

Invoices keep using the org default (`BillingSettings.defaultInvoiceDocTemplate`) until it points at `RLM_RTK_Invoice`.

The proposal docx is generated by `scripts/docgen/build_rtk_pest_proposal.py` and its data mappings by `scripts/docgen/build_rtk_proposal_odts.py`; edit the scripts and rebuild rather than hand-editing the `.dt` or `.rpt-meta.xml` files. Inspection photos are not in the PDF (image tokens fail in this org); customers see them at Sign & Pay. Redeploying a template creates a new draft version, so run `activate_docgen_templates` afterwards.

## Nine scenes

| # | Scene | What to show |
|---|-------|----------------|
| 1 | Plan the day | Bloomingdale territory, tech schedule |
| 2 | Inspect & quote | Tablet flow + location zone on waterfall |
| 3 | Sign & pay | **Create Proposal** → preview → **Sign & Pay** (mock card + signature tied to the PDF), or Quote highlight **Sign & Pay** after a proposal exists → Create Order |
| 4 | Plan builds itself | Activate Order → assets per plan, DRO fulfillment plan creates the Initial Pest Treatment WO + Service Appointment; `RTK-INITIAL` billing schedule waits on the "Initial Treatment Complete" milestone, monthly plans are Ready for Invoicing |
| 5 | First treatment | Complete WO → fulfillment step completed, milestone accomplished, order invoiced (`RLM_FSL_Complete_Fulfillment_Step`) |
| 6 | Recurring visits | Maintenance Plan quarterly WOs (routing = package vision) |
| 7 | Re-service | Coverage check; free under plan, else `RTK-RESERVICE` via `RLM_FSL_BillRepair` |
| 8 | Upsell | Flag Expansion → Termite co-term amendment |
| 9 | Pause / renew | Mosquito qty amendment Nov/Apr; renew plan asset |

## Driver

```bash
python scripts/place_pest_demo_order.py --target-org fsl-rc --activate --complete-initial
```

## Teardown

```bash
cci task run delete_pest_data --org fsl-rc
```

Does not delete transactional quotes/orders; use Account Utilities for those.
