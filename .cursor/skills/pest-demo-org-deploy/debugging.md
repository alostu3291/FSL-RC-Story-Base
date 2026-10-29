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
