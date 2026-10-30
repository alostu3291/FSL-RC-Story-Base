# Pest Demo on a Demo-Template (SDO) Org: Findings

What it took to run the pest control story (quote, sign and pay, initial
treatment, invoicing, coverage, re-service, Field Service mobile) on an org
built from the Salesforce demo template instead of `prepare_rlm_org`.

- **Org:** `user@fieldrev.demo` (CCI alias `fieldrev`), Enterprise trial on
  USA1142, API v68.0, My Domain `trailsignup-855a60c3c05a57`.
- **Date:** October 2026.
- **Approach:** targeted overlay. Pest bundles and data went in as single CCI
  tasks; the template's Revenue Cloud demo (Cirrus) was left working.

Quick fixes for each error are in
[pest-demo-org-deploy/debugging.md](../../.cursor/skills/pest-demo-org-deploy/debugging.md#demo-template-sdo-orgs).
This page is the overall picture.

## Bottom line

The pest story works end to end on an SDO org, but not out of the box. Three
things the repo assumes are missing or named differently, two template setups
break billing and tests, and the managed Field Service package is stricter in
Apex tests than in the live org. All of it is now handled by repo tasks and
code; see [Deploy order that worked](#deploy-order-that-worked).

| Area | Result |
|------|--------|
| Quote from the field (Inspect & Quote) | Works. $79 Home Protection + $199 Initial Service = $278, Suburb zone ×1.00 |
| Order, DRO initial treatment, guarantees, maintenance plan | Works |
| Covered re-service with Rentokil SLA milestone | Works |
| Invoicing | Works after adding sequence policies and recovering the failed invoices |
| FS mobile actions | Work after `patch_sdo_org_for_pest` patches the template's layouts |
| Apex tests | All 79 pest tests pass. Before the fixes most Work Order tests failed (Gaps 6 and 7) |

## What the template org already has

- Revenue Cloud under `RC_*` names: `RC_SalesTransactionContext`,
  `RC_BillingContext`, 24 `RC_*` flows, the Cirrus Solar catalog, and
  `Cirrus Billing Policy` and `Cirrus Tax Policy`.
- Licences for Revenue Cloud, Billing, DRO, DocGen, OmniStudio, Field Service
  (Standard, Dispatcher, Mobile, Scheduling), Prompt Builder and Agentforce.
- FSL managed package and the Field Service Starter Kit.
- PKCE required, entitlements on, Einstein generative AI on, USD only.
- `Price_Book_Entry_Decision_Table_v2` active.
- Default legal entities for US and Canada.

It has none of this repo's `RLM_*` metadata, no QuantumBit catalog, and no
`RLM_*` context definitions. The pest inventory reported 211 gaps; 52 of the
`post_pest` "failing" items were base dependencies from `post_fsl`,
`post_docgen` and `post_billing_ui`.

## Gaps the repo hits on a template org

### 1. Context definition names

`datasets/context_plans/PestLocation` targets `RLM_SalesTransactionContext`.
The template uses `RC_SalesTransactionContext`, which is an extended context, so:

- Custom attribute and tag names need a `__c` suffix (`ServicePostalCode__c`).
- Mapping `ShippingPostalCode` from Quote and Order fails with "Many-to-one
  mapping isn't allowed" because the template already maps it.

The overlay used `ServicePostalCode__c` with no mappings. Zone pricing runs in
Apex, so it doesn't need the tag.

### 2. No QuantumBit products to copy policies from

`setupRtkRevenue.apex` copied the billing and tax policy from `QB-SVC-REPAIR`
or `QB-SRV-OG-PSH`. With no QuantumBit catalog it did nothing, so plan products
couldn't bill. **Repo fix:** the script now falls back to the org's first
active `BillingPolicy` and `TaxPolicy`. `RTK-INITIAL` keeps its milestone
billing policy and gets the tax policy.

### 3. Layout and page assignments

The template assigns its own layouts and Lightning pages, so the repo's pest
layouts (`Work Order Layout`, `RLM Quote Layout`, and so on) never show. The FS
mobile app reads page layouts, not Lightning pages.

Layouts the admin profile uses, and what was added to each:

| Object | Assigned layout | Added |
|--------|-----------------|-------|
| Work Order | `SDO SFS Work Order Layout` | Inspect & Quote and Treatment actions, plus a "Rentokil Pest" section (`RLM_RTK_Inspection__c`, `RLM_RTK_Reported_Pest__c`, `RLM_Service_Coverage__c`, `RLM_Order__c`, `RLM_Billable_Order__c`) |
| Service Appointment | `SDO - SFS Service Appointment Feed Based` | Inspect & Quote |
| Quote | `RC Quote Layout` | Sign & Pay |
| Account | `Account Layout`, `SDO - Account`, `SDO - Partner Account`, `SDO - Account Community` (one per record type) | Inspect & Quote; Work Orders and Service Appointments related lists |
| Asset | `RC Asset Layout` | Maintenance Plans and Entitlements related lists |

Lightning pages the **Revenue Cloud** app (`RC_Revenue_Cloud`) uses, and the
related lists added to their **Related** tab:

| Page | Added |
|------|-------|
| `RC_Account_Record_Page` | Work Orders, Service Appointments |
| `RC_Asset_Record_Page` | Maintenance Plans, Entitlements (guarantees) |

**Fix: `cci task run patch_sdo_org_for_pest`** (`tasks/rlm_sdo_overlay.py`).
It patches whatever the org actually uses, in place:

- **Layouts.** It reads the layouts assigned to the given profiles (default
  System Administrator; add technician profiles with `-o profiles "System
  Administrator,Field Technician"`). Into each one it copies the `*.RLM_RTK_*`
  actions from the matching `templates/layouts/pest` layout, plus any pest
  `RLM_*` fields the layout lacks, in a "Rentokil Pest" section. It also
  copies related lists, with their columns, from a repo template:
  Work Orders and Service Appointments from the pest Account layout, and
  Maintenance Plans and Entitlements from `templates/layouts/fsl/Asset-RLM
  Asset Layout`. The FS mobile app shows layout related lists, not the
  Lightning page ones, so both are needed.
- **Record pages.** It reads the Account and Asset record pages the app assigns
  (default `RC_Revenue_Cloud`, `-o app` to change) and adds the related lists
  to their Related tab.
- **Flows.** See Gap 6.
- **Dry run.** `-o deploy false -o work_dir /tmp/sdo` retrieves and patches
  without deploying, so you can diff the files.

Each step skips when the org lacks its target, and reruns report "already
patched". The first run on fieldrev found three things the manual pass had
missed: the Partner and Community account layouts, and
`RLM_Billable_Order__c`.

What not to do, and why the task works the way it does:

- Don't run `assemble_and_deploy_ux`; it overwrites the template's profile
  layout assignments and record pages.
- LWC actions go in `platformActionList`; the Metadata API rejects them in
  `quickActionList`.
- Layout sections must be contiguous. A section inserted after `<miniLayout>`
  gives "Element layoutSections is duplicated", so the task inserts after the
  last `</layoutSections>`.
- Related list names and columns on `lst:dynamicRelatedList` are covered in
  [Related list details](#related-list-details).
- Other apps (Field Service console, Service console) have their own record
  pages. Run the task again with `-o app <name> -o steps pages` to patch them.

### 4. Pest depends on parts of other bundles

`post_pest` needs, besides `post_fsl`:

- From `post_docgen`: `RLM_SignAndPay*` classes, `rlmSignAndPay` and
  `rlmFileViewer` LWCs, `Quote.RLM_Demo_*` fields, and a trimmed `RLM_DocGen`
  permission set.
- From `post_billing_ui`: `InvoiceLine.RLM_Charge_Type__c`.

Deploying the whole bundles pulls in QuantumBit templates and pages, so deploy
just those files with `sf project deploy start --source-dir`.

### 5. No invoice numbering (sequence policies)

The template ships no `SequencePolicy`. Every invoice was created with lines
and tax, then went to **Error**. The Revenue Transaction Error Log says "There's
no active or effective sequence policy for the target object."

The fix, in order:

1. Run `cci task run create_sequence_policies`. It creates the Invoice and
   Credit Memo policies from `datasets/sfdmu/qb/en-US/qb-billing/SequencePolicies.json`,
   one per legal entity. Policies whose legal entity the org doesn't have (EU
   and UK here) are skipped with a warning. Before this fix they failed the
   task, so you had to trim the JSON by hand.
2. Recover the errored invoices. For each one, call `POST
   commerce/invoicing/billing-schedules/collection/actions/recover` with one
   of its billing schedule ids. This cancels the invoice and sets all of its
   schedules back to ReadyForInvoicing.
3. Run `RLM_FSL_InvoiceOrder.enqueue(orderIds)` once per account.

Afterwards Michael's invoice posted at $370.70 and Priya's at $502.70.

### 6. Template flow breaks Work Order inserts in Apex tests

The org flow **SDO SFS Attach Forms On Create** attaches six Data Capture forms
(`DynamicDataCapture`) to every new Work Order. In an Apex test it fails with
"Select a valid Action Definition", so every test that inserts a Work Order
fails. That was the cause of all but four failures.

**Cause.** Form validation reads org data that test isolation hides. This was
proven with two throwaway tests that insert the same Work Order: the one with
`SeeAllData=true` passes and the isolated one fails. All six form flows are
active, and live Work Orders get their forms.

**Fix.** `patch_sdo_org_for_pest` (the `flows` step) gives each of the flow's
Create Records elements a fault path to the next element. The last element
gets a fault path to a no-op assignment. A form that can't be attached is
skipped instead of failing the Work Order insert, and live Work Orders still
get all six forms.

- Fault paths that rejoin the main path use `isGoTo`, so the auto-layout canvas
  still opens.
- The task activates the new flow version if the deploy didn't.
- `SeeAllData=true` on the pest tests was rejected, because it would couple
  them to org data and unique-SKU collisions.

On an org that runs tests on deploy, run `patch_sdo_org_for_pest -o steps
flows` before `deploy_post_pest`, which runs the pest tests. fieldrev skips
tests on deploy, so a validate-only deploy runs 0 tests there.

### 7. Managed Field Service package is stricter in Apex tests

With the flow fixed, 75 of the 79 pest tests passed. Four failed with "Cannot
change status from None to Dispatched / In Progress / Completed". Once that
was fixed, the booking test failed with "there's no service territory member
defined".

**Cause.** The FSL managed package enforces its default appointment lifecycle,
None → Scheduled → Dispatched → In Progress → Completed, unless it can see the
org's own status transitions. Tests can't see them, and an org that never
configured transitions gets the defaults live too. The pest code jumped
straight from None to the target status. The package also only assigns a
resource that is a member of a service territory.

**Fix (repo code).**

- `RLM_RTK_FieldVisit.stepToward` moves appointments through the lifecycle
  steps before the target, in bulk, one update per step, before the start,
  book and complete paths set their status. Statuses outside that list (custom
  SDO statuses) are left alone.
- `RLM_RTK_FieldVisitTest` steps through the lifecycle too, and gives the
  booking test's technician a territory and membership.
- Checked live inside a rolled-back transaction: fieldrev's own transitions
  accept every intermediate step.

Result: all 79 pest tests pass on fieldrev.

## Template behaviour that looks like an error but isn't

- **`AssetizationFailed`: "couldn't find order products eligible to be
  converted to assets."** The template's `RC_Assetize_Order` flow submits the
  order to DRO and creates the assets when the order activates. When the
  initial treatment completes the fulfillment plan, the platform tries again
  and logs this error. The plan asset already exists.
- **`PaymentScheduleGeneration`: payment schedule created in Draft.** The
  customer has no saved payment method yet. Expected until a payment is taken.
- **Unscheduled Service Appointments on the account.** The maintenance plan
  creates future re-service Work Orders, and their appointments have no times
  until they're scheduled.

## Environment and tooling notes

- **CCI needs a git repository.** If the workspace isn't one, CCI says "No
  git repository". Run `git init` and make a commit.
- **Some custom tasks reject `--org`.** `recalculate_permission_set_groups`
  and `apply_context_pest_location` are examples. Run `cci org default
  <alias>`, then run the task without `--org`.
- **Time zone.** The template user was on Asia/Kolkata; the pest territory and
  slots run on America/Chicago. Set the user to America/Chicago or visit
  times look wrong.
- **Field Service settings.** Work Orders and the Service Appointment
  lifecycle were off; `deploy_pre_fsl` turns them on.
- **API limits for invoicing calls:**
  - Post: one invoice per call.
  - Recover: one billing schedule per call.
  - Generate: all schedules in a call must belong to one account.
- **API version.** The org is v68.0 and the repo targets v66.0. Nothing broke
  because of it.

## Related list details

On `lst:dynamicRelatedList`, the deploy checks column names per related list,
and the names differ between lists:

| Related list | Parent | Columns that deploy |
|--------------|--------|---------------------|
| `WorkOrders` | Account | `Name` (not `WorkOrderNumber`), `Subject`, `Status`, `StartDate`, `EndDate` |
| `ServiceAppointmentAccount` | Account | `Name`, `Subject`, `Status`, `SchedStartTime`, `SchedEndTime` (not `ParentRecordId`) |
| `MaintenanceAssets` | Asset | `Name`, `MaintenancePlan`, `NextSuggestedMaintenanceDate` (not `MaintenanceType`) |
| `Entitlements` | Asset | `ENTITLEMENT.NAME`, `ENTITLEMENT.TYPE`, `ENTITLEMENT.STARTDATE`, `ENTITLEMENT.ENDDATE`, `ENTITLEMENT.STATUS` |

On classic page layouts the names differ again: Entitlements is
`RelatedEntitlementList` (on a Lightning page that name gives "Could not find
related list"), and maintenance plans is `MaintenanceAssets` with columns
`MaintenancePlan`, `WorkType`, `ContractLineItem`, `CreatedDate`.

- Use `ServiceAppointmentAccount` (matches on `AccountId`) for Account pages,
  not `ServiceAppointments`, which matches on `ParentRecordId`. Pest
  appointments have a Work Order as their parent, so `ServiceAppointments`
  shows nothing.
- If a column is rejected, copy the field names from the object's page layout
  related list (`<relatedLists><fields>`).
- `ui-api/related-list-info/{object}/{list}` lists columns but doesn't always
  match what the deploy accepts.

## Deploy order that worked

1. `cci org import <username> <alias>` and `cci org default <alias>`.
2. `deploy_pre_fsl`, `deploy_post_fsl`, then the FSL permission set licences,
   `RLM_Field_Service_PSG` and the mobile permission sets.
3. The Sign & Pay subset from `post_docgen` and
   `InvoiceLine.RLM_Charge_Type__c`.
4. `patch_sdo_org_for_pest -o steps flows`, so `deploy_post_pest`'s tests
   can insert Work Orders (see Gap 6).
5. `deploy_post_pest_sla` (only once; it can't be redeployed while active),
   `deploy_post_pest` and `RLM_Rentokil_Pest`.
6. `deploy_post_pest_ai` and `activate_pest_prompt_templates`.
7. `apply_context_pest_location -o developer_name RC_SalesTransactionContext`,
   then the pest catalog, pricing, FSL and DRO data, the `setup_rtk_*`
   scripts, and `refresh_dt_default_pricing`.
8. `create_sequence_policies` (see Gap 5).
9. Pest docgen (`deploy_post_pest_docgen`, `activate_docgen_templates`,
   `fix_pest_document_template_binaries`), then the pest billing agent.
10. `patch_sdo_org_for_pest` for the layouts and record pages (see Gap 3).
11. Set the user's time zone to America/Chicago and seed visits (see
    [pest-demo-seed-visits](../../.cursor/skills/pest-demo-seed-visits/SKILL.md)).
12. Run `python scripts/ai/pest_org_inventory.py --target-org <user>`. It
    should report "Nothing missing". Then run the pest Apex tests; all 79
    should pass.

## Not changed on the template org

- No `prepare_rlm_org`, QuantumBit catalog, or Billing / Revenue settings
  changes, so the Cirrus demo keeps working.
- No feature flags committed in `cumulusci.yml`.
- The template's default invoice document template was left in place.
- Template automation was changed in one place only: fault paths on SDO SFS
  Attach Forms On Create. Its behaviour for successful form attachment is
  unchanged.

## Resolved open items

| Item | Resolution |
|------|------------|
| Layout and page patches were org-only and manual | `patch_sdo_org_for_pest` does them on any template org |
| `create_sequence_policies` needed a trimmed JSON | It skips policies whose legal entity the org doesn't have |
| Apex tests red on template orgs | Fault paths on the template flow (Gap 6) and a lifecycle-aware `RLM_RTK_FieldVisit` (Gap 7); all 79 pest tests pass |

Still manual: recovering invoices that already failed before the sequence
policies existed (Gap 5, steps 2 and 3).
