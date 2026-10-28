// Idempotently start Field Service coverage for every pest customer with an active plan: a guarantee
// Entitlement per plan asset and one Maintenance Plan with the recurring visit rules, then generate
// the visits. New customers get this automatically when their Initial Pest Treatment is completed.
Set<Id> accountIds = new Set<Id>();
for (Asset a : [
    SELECT AccountId FROM Asset
    WHERE Product2.StockKeepingUnit IN ('RTK-ESSENTIAL', 'RTK-HOME-PROT', 'RTK-HOME-PROT-PLUS', 'RTK-MOSQUITO', 'RTK-TERMITE')
        AND CurrentQuantity > 0 AND AccountId != null
]) {
    accountIds.add(a.AccountId);
}
RLM_RTK_Coverage.activate(accountIds);
Set<Id> planIds = new Map<Id, MaintenancePlan>([
    SELECT Id FROM MaintenancePlan
    WHERE AccountId IN :accountIds AND MaintenancePlanTitle = :RLM_RTK_Coverage.PLAN_TITLE
]).keySet();
RLM_RTK_Coverage.generate(planIds);
System.debug('setupRtkGrow complete: ' + accountIds.size() + ' customers, ' + planIds.size() + ' plans generating visits');
