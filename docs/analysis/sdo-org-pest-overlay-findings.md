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
things the repo assumes are missing or named differently, and two template
setups break billing and tests. Most of the hand work is in layouts and
billing.

| Area | Result |
|------|--------|
| Quote from the field (Inspect & Quote) | Works. $79 Home Protection + $199 Initial Service = $278, Suburb zone ×1.00 |
| Order, DRO initial treatment, guarantees, maintenance plan | Works |
| Covered re-service with Rentokil SLA milestone | Works |
| Invoicing | Works after adding sequence policies and recovering the failed invoices |
| FS mobile actions | Work after patching the template's layouts |
| Apex tests | 37 pass, 47 fail because of a template flow, not pest code |

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
| Work Order | `SDO SFS Work Order Layout` | Inspect & Quote and Treatment actions, plus a "Rentokil Pest" section (`RLM_RTK_Inspection__c`, `RLM_RTK_Reported_Pest__c`, `RLM_Service_Coverage__c`, `RLM_Order__c`) |
| Service Appointment | `SDO - SFS Service Appointment Feed Based` | Inspect & Quote |
| Quote | `RC Quote Layout` | Sign & Pay |
| Account | `Account Layout`, `SDO - Account` | Inspect & Quote |

Lightning pages the **Revenue Cloud** app (`RC_Revenue_Cloud`) uses, and the
related lists added to their **Related** tab:

| Page | Added |
|------|-------|
| `RC_Account_Record_Page` | Work Orders, Service Appointments |
| `RC_Asset_Record_Page` | Maintenance Plans, Entitlements (guarantees) |

How to do it, and what not to do:

- Retrieve the assigned layout or page, patch it, and deploy it back. Don't run
  `assemble_and_deploy_ux`; it overwrites the template's profile layout
  assignments and record pages.
- LWC actions go in `platformActionList`; the Metadata API rejects them in
  `quickActionList`.
- A new layout section goes before `<miniLayout>`. Putting it after gives
  "Element layoutSections is duplicated".
- Related list names and columns on `lst:dynamicRelatedList` are covered in
  [Related list details](#related-list-details).
- These patches are org-only and not in the repo. Other apps (Field Service
  console, Service console) have their own pages and weren't changed.

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

1. Run `cci task run create_sequence_policies -o plan_dir <dir>` with a copy of
   `datasets/sfdmu/qb/en-US/qb-billing/SequencePolicies.json`, trimmed to the
   org's legal entities (here US and Canada, for both Invoice and Credit Memo).
2. Recover the errored invoices. For each one, call `POST
   commerce/invoicing/billing-schedules/collection/actions/recover` with one
   of its billing schedule ids. This cancels the invoice and sets all of its
   schedules back to ReadyForInvoicing.
3. Run `RLM_FSL_InvoiceOrder.enqueue(orderIds)` once per account.

Afterwards Michael's invoice posted at $370.70 and Priya's at $502.70.

### 6. Template flow breaks Apex tests

The org flow **SDO SFS Attach Forms On Create** fails with "Select a valid
Action Definition" whenever a test inserts a Work Order. That causes all 47
test failures. Live use is unaffected. Deactivate the flow if you need green
tests.

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
4. `deploy_post_pest_sla` (only once; it can't be redeployed while active),
   `deploy_post_pest` and `RLM_Rentokil_Pest`.
5. `deploy_post_pest_ai` and `activate_pest_prompt_templates`.
6. `apply_context_pest_location -o developer_name RC_SalesTransactionContext`,
   then the pest catalog, pricing, FSL and DRO data, the `setup_rtk_*`
   scripts, and `refresh_dt_default_pricing`.
7. `create_sequence_policies` with a trimmed JSON (see Gap 5).
8. Pest docgen (`deploy_post_pest_docgen`, `activate_docgen_templates`,
   `fix_pest_document_template_binaries`), then the pest billing agent.
9. Patch the template's layouts and Revenue Cloud record pages (see Gap 3).
10. Set the user's time zone to America/Chicago and seed visits (see
    [pest-demo-seed-visits](../../.cursor/skills/pest-demo-seed-visits/SKILL.md)).
11. Run `python scripts/ai/pest_org_inventory.py --target-org <user>`. It
    should report "Nothing missing".

## Not changed on the template org

- No `prepare_rlm_org`, QuantumBit catalog, or Billing / Revenue settings
  changes, so the Cirrus demo keeps working.
- No feature flags committed in `cumulusci.yml`.
- The template's default invoice document template was left in place.

## Open items

- **Template layout and page patches are org-only.** A fresh template org needs
  them redone by hand. A task that patches whatever layouts are assigned
  would remove this step.
- **`create_sequence_policies` assumes QuantumBit legal entities.** On orgs
  without EU or UK entities it needs a trimmed JSON. It could skip policies
  whose legal entity doesn't exist.
- **Apex tests and the SDO Work Order flow.** Tests stay red on template orgs
  until that flow is deactivated or the tests bypass it.
