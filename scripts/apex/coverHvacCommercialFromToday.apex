// Demo prelude for seed_hvac_commercial_service_call: a contract quote starts on the first of next
// month, so a contract booked for the demo doesn't cover a call today. This moves the property group's
// site response entitlements that haven't started yet to start today, so a call at any site is Covered
// with its site priority. The contract, its assets and billing keep their dates.
// Variable names are prefixed so they don't clash with the service call script that runs after it.

List<Account> coverSites = [SELECT Id, ParentId FROM Account WHERE Name = '%%%ACCOUNT_NAME%%%' AND ParentId != null LIMIT 1];
if (!coverSites.isEmpty()) {
    List<Entitlement> coverPending = [
        SELECT Id FROM Entitlement
        WHERE Account.ParentId = :coverSites[0].ParentId AND RLM_HVAC_Covered_Systems__c != null
            AND StartDate > TODAY AND (EndDate = null OR EndDate >= TODAY)
    ];
    for (Entitlement coverE : coverPending) {
        coverE.StartDate = Date.today();
    }
    update coverPending;
}
