// Records a dated plan change for a pest demo cast customer through RLM_RTK_PlanChange, the same
// amendment the Change the plan panel places. ACTION change: move to SKU (or add or remove it) from
// START_DATE. ACTION resume: restore a removed add-on plan from START_DATE, which ends a seasonal pause.
// Run through seed_rtk_demo_cast.

String accountName = '%%%ACCOUNT_NAME%%%';
String action = '%%%ACTION%%%';
String sku = '%%%SKU%%%';
Date startDate = Date.valueOf('%%%START_DATE%%%');

Account account = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
if (action == 'resume') {
    RLM_RTK_PlanChange.resumePlan(account.Id, sku, startDate, accountName);
} else {
    RLM_RTK_PlanChange.scheduleChange(account.Id, sku, accountName, startDate);
}
