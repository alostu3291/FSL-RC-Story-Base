// Idempotently start Field Service coverage for every HVAC customer with an active comfort agreement:
// a priority-response Entitlement per agreement asset and one Maintenance Plan with the seasonal
// tune-up rules, then generate the visits. New customers get this automatically when their
// Initial Tune-up is completed.
Set<Id> accountIds = new Set<Id>();
for (Asset a : [
    SELECT AccountId FROM Asset
    WHERE Product2.StockKeepingUnit IN ('HVAC-BASIC', 'HVAC-PLUS', 'HVAC-PREMIER', 'HVAC-IAQ', 'HVAC-WATER-HEATER')
        AND CurrentQuantity > 0 AND AccountId != null
]) {
    accountIds.add(a.AccountId);
}
RLM_HVAC_Coverage.activate(accountIds);
Set<Id> planIds = new Map<Id, MaintenancePlan>([
    SELECT Id FROM MaintenancePlan
    WHERE AccountId IN :accountIds AND MaintenancePlanTitle = :RLM_HVAC_Coverage.PLAN_TITLE
]).keySet();
RLM_HVAC_Coverage.generate(planIds);
System.debug('setupHvacGrow complete: ' + accountIds.size() + ' customers, ' + planIds.size() + ' plans generating visits');
