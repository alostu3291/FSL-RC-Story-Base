// Books a pest demo cast customer's signed quote, the way Sign & Pay does: creates the order and
// activates it, which starts fulfillment (the Initial Pest Treatment work order and appointment).
// Run through seed_rtk_demo_cast. Re-running activates an order left in Draft.

String accountName = '%%%ACCOUNT_NAME%%%';
List<RLM_RTK_Inspection__c> inspections = [
    SELECT Quote__c FROM RLM_RTK_Inspection__c
    WHERE Account__r.Name = :accountName AND Quote__c != null
    ORDER BY CreatedDate DESC LIMIT 1
];
if (inspections.isEmpty()) {
    throw new IllegalArgumentException(accountName + ' has no quote from an inspection.');
}
RLM_RTK_FieldVisit.placeOrder(inspections[0].Quote__c);
