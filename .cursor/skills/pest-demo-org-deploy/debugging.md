# Pest Demo Deploy: Known Failures

Find the error text, apply the fix, redeploy only what failed.

## Deploy errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Must have at least one default business hours` | `BusinessHours.settings-meta.xml` lists only Rentokil Service Days | Keep the Default (24/7) entry in the settings file; it is in the repo version |
| Entitlement process can't be updated / is in use | Active processes with entitlements can't be redeployed | Use `deploy_post_pest_sla` (skips when present). To change it, create a new version in Setup |
| `IsVersionDefault` invalid on `SlaProcess` | Versioning is off in these orgs | Don't query or set it |
| Layout related list not found | Milestones related list name | Use `RelatedEntityMilestoneList` |
| `Can't edit an active bot version` | Agent version is active | Leave it, or deactivate in Agentforce Builder, deploy, reactivate |
| Field not accessible after deploy | New field without FLS | Add `fieldPermissions` to `RLM_Rentokil_Pest` and redeploy the permission set |
| DocumentTemplate deployed but blank or inactive | Templates always deploy inactive; batch deploy drops binaries | `activate_docgen_templates`, then `fix_pest_document_template_binaries` |
| Duplicate `StockKeepingUnit` when a test inserts an `RTK-` product | SKUs are unique org-wide, even in tests | Test data uses suffixed SKUs (see `RLM_RTK_PlanChange.skuSuffix`) |
| Deploy says Succeeded but behaviour unchanged | Org skips tests and may cache LWCs | Run the tests, hard-refresh the app, recheck with the inventory |

## Runtime and data issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Re-service not Covered | No active guarantee covers the reported pest | Check `Entitlement.RLM_RTK_Covered_Pests__c` for the account; coverage syncs a minute after plan assets change, or run `RLM_RTK_Coverage.syncAll();` |
| No response milestone on a Covered re-service | Guarantee has no `SlaProcessId` | `RLM_RTK_Coverage.syncAll();` backfills it |
| Milestone due date a few seconds off | Target is truncated to the minute | Expected |
| Plan prices look wrong after a price change | Pricing decision tables not refreshed | `refresh_dt_default_pricing`, wait, recheck |
| Plan change shows "$79 → $79" | Old build without the size and severity carry-over | Deploy current `RLM_RTK_PlanChange` and `rlmRtkPlanChange` |
| Map lookup misses in Apex (`10` vs `10.00`) | Decimal map keys compare by scale | Key maps by `Integer` or `String` |
| Can't delete a demo account | Activated orders and posted invoices can't be deleted | Strip it and rename to `zz Archived - …` |
| Visits book at the wrong hour | Times are on the territory's clock (America/Chicago) | Expected; seeding tasks convert |

## Checking a fix without leaving data

```apex
Savepoint sp = Database.setSavepoint();
// call the changed method, System.debug the result
Database.rollback(sp);
```

Place Sales Transaction runs inside the savepoint and rolls back cleanly. Confirm afterwards
that no Quote or Opportunity was left for the test account.

## Demo-template (SDO) orgs

SDO / Trailhead signup orgs (for example `user@fieldrev.demo`) already have Revenue Cloud
and Field Service under `RC_*` names and Cirrus policies. They have never run
`prepare_rlm_org`. Overlay pest with single CCI tasks; do not run the full base build.

| Gap | Cause | Fix |
|-----|-------|-----|
| No `RLM_SalesTransactionContext` | Org uses `RC_SalesTransactionContext` | `apply_context_pest_location -o developer_name RC_SalesTransactionContext`. Extended contexts require attribute/tag names with `__c` (e.g. `ServicePostalCode__c`). Mapping `ShippingPostalCode` may already exist; Apex zone pricing does not need the tag |
| RTK products have no Billing/Tax policy | `setupRtkRevenue` looked up QuantumBit SKUs only | Script falls back to the first active `BillingPolicy` / `TaxPolicy` (Cirrus). Keep `RTK-INITIAL` on its milestone policy |
| Pest actions missing in the FS app | Admin profile uses SDO layouts, not repo `Work Order Layout` / `RLM Quote Layout` | Retrieve the assigned layouts, add pest `platformActionList` entries (and WO fields), redeploy. Do not run `assemble_and_deploy_ux` (it would overwrite template layout assignments) |
| `post_pest` dry-run fails on `RLM_Demo_*`, `RLM_SignAndPay`, `RLM_Charge_Type__c`, `RLM_Order__c` | Those live in `post_docgen`, `post_billing_ui`, and `post_fsl` | Deploy `post_fsl` first; deploy a Sign & Pay subset from `post_docgen` (Apex, LWCs, `Quote.RLM_Demo_*`, trimmed `RLM_DocGen`) and `InvoiceLine.RLM_Charge_Type__c` from `post_billing_ui` |
| Apex tests fail creating Work Orders | Org flow **SDO SFS Attach Forms On Create** errors with `Select a valid Action Definition` | Org automation, not pest code. Live quote / order / visits still work. Deactivate or fix that flow if you need green tests |
| Invoice Status = Error after initial treatment; Revenue Transaction Error Log says "no active or effective sequence policy" | The template has no `SequencePolicy` for Invoice / CreditMemo, so posting can't number the invoice | `cci task run create_sequence_policies -o plan_dir <dir>` with a copy of `qb-billing/SequencePolicies.json` trimmed to the org's legal entities. Then recover one schedule per errored invoice (`POST commerce/invoicing/billing-schedules/collection/actions/recover`, one id per call — it cancels the invoice and frees all its schedules) and run `RLM_FSL_InvoiceOrder.enqueue` once per account |
| `OrderToAsset` / `AssetizationFailed` "couldn't find order products eligible to be converted to assets" after the initial treatment | `RC_Assetize_Order` already assetized the order at activation; DRO tries again when the plan completes | Harmless — check the plan asset exists |
| CCI `BaseTask` rejects `--org` | Some custom tasks declare `access_token` or malformed option defaults | `cci org default <alias>` then run the task without `--org` |
| CCI says "No git repository" | Workspace was unpacked from a zip | `git init` and make a commit |
| Context API: "Many-to-one mapping isn't allowed" | Template already maps `ShippingPostalCode` from Quote / Order | Use the `__c` tag with no mappings |
| Layout deploy: "Element layoutSections is duplicated" | New section inserted after `<miniLayout>` | Put new `layoutSections` before `<miniLayout>` |
| Revenue Cloud app pages lack WO / SA / Maintenance Plan / Entitlement lists | Template pages `RC_Account_Record_Page` and `RC_Asset_Record_Page` don't include them | Add `lst:dynamicRelatedList` items to `relatedTabContent`. Column names per list are in [the findings report](../../../docs/analysis/sdo-org-pest-overlay-findings.md#related-list-details) |
| Account Service Appointments list is empty | `ServiceAppointments` matches `ParentRecordId`; pest SAs have a Work Order parent | Use `ServiceAppointmentAccount` (matches `AccountId`) |
| `dynamicRelatedList` deploy: "Could not find column [X] in related list" | Each list has its own column names (`Name` for WO number, `ENTITLEMENT.*` for Entitlements) | Copy the field names from the object's page layout related list |
| Invoice API: "can't post more than 1 invoice per attempt", "Provide only one billing schedule id", "All billing schedules must be related to the same account" | Per-call limits on post, recover and generate | Call per invoice / schedule; enqueue `RLM_FSL_InvoiceOrder` once per account |
| Errored invoice can't be posted ("isn't in Draft status") | Error invoices aren't retried | Recover a schedule (cancels the invoice), then generate again |
| `PaymentScheduleGeneration` log: payment schedule in Draft | Customer has no saved payment method | Expected until a payment is taken |

Deploy order that worked on fieldrev: `deploy_pre_fsl` → `deploy_post_fsl` + FSL PSG/PS
→ Sign & Pay subset + charge-type field → `deploy_post_pest_sla` → `deploy_post_pest` →
pest AI → context / catalog / pricing / FSL / DRO / `setup_rtk_*` → `create_sequence_policies` →
pest docgen → pest agent → patch SDO layouts and RC record pages → seed visits.

Full write-up, including what the template already has and open items:
[docs/analysis/sdo-org-pest-overlay-findings.md](../../../docs/analysis/sdo-org-pest-overlay-findings.md).
