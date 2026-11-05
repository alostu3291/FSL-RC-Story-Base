// Resets refrigerant compliance at a commercial site and seeds a year of history, so the technician's
// next refrigerant add on the site's first leak-rate tracked unit crosses the 10% limit and opens a
// leak repair. Run through the seed_hvac_refrigerant_leak task, which fills the %%%...%%% tokens.
//
// Reset: open leak repair work orders at the site are canceled, the site's refrigerant logs are deleted
// and its tracked units go back to In Compliance.
// History: the first tracked unit (the "watch" unit) had adds about 400 and 140 days ago, leaving it
// near the limit; the other tracked units had one small add each. Today's add on the watch unit is
// annualized over 140 days, so adding about 4% of its charge trips the limit.
// Visit: the site's next quarterly maintenance work order is dispatched to the running user, so the
// technician opens it on the device and logs the add from Refrigerant Log.

String accountName = '%%%ACCOUNT_NAME%%%';
Integer hour = Integer.valueOf('%%%HOUR%%%');
Integer daysAhead = Integer.valueOf('%%%DAYS_AHEAD%%%');
final Integer WATCH_FIRST_DAYS = 400;
final Integer WATCH_LAST_DAYS = 140;
final Integer OTHER_DAYS = 240;

List<Account> sites = [SELECT Id, Name FROM Account WHERE Name = :accountName AND ParentId != null LIMIT 1];
if (sites.isEmpty()) {
    throw new IllegalArgumentException('No commercial site account named ' + accountName + '. Run seed_hvac_commercial_sites first.');
}
Account site = sites[0];
List<Asset> tracked = [
    SELECT Id, RLM_HVAC_Unit_Tag__c, RLM_HVAC_Refrigerant_Charge__c FROM Asset
    WHERE AccountId = :site.Id AND RLM_HVAC_Leak_Rate_Tracked__c = true AND Status != 'Obsolete'
    ORDER BY RLM_HVAC_Unit_Tag__c
];
if (tracked.isEmpty()) {
    throw new IllegalArgumentException(site.Name + ' has no units holding 50 lb or more; pick a site with leak-rate tracked units.');
}
List<Asset> units = [SELECT Id FROM Asset WHERE AccountId = :site.Id AND RLM_HVAC_Tonnage__c != null];
Set<Id> unitIds = new Map<Id, Asset>(units).keySet();

// Reset
Set<Id> repairIds = new Set<Id>();
for (WorkOrderLineItem line : [
    SELECT WorkOrderId FROM WorkOrderLineItem
    WHERE AssetId IN :unitIds AND WorkOrder.WorkType.Name = :RLM_HVAC_RefrigerantCompliance.REPAIR_WORK_TYPE
        AND WorkOrder.Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete')
]) {
    repairIds.add(line.WorkOrderId);
}
List<ServiceAppointment> repairVisits = [
    SELECT Id FROM ServiceAppointment WHERE ParentRecordId IN :repairIds AND Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
];
for (ServiceAppointment sa : repairVisits) {
    sa.Status = 'Canceled';
}
update repairVisits;
List<WorkOrder> repairs = new List<WorkOrder>();
for (Id woId : repairIds) {
    repairs.add(new WorkOrder(Id = woId, Status = 'Canceled'));
}
update repairs;
delete [SELECT Id FROM RLM_HVAC_Refrigerant_Log__c WHERE RLM_HVAC_Asset__c IN :unitIds];
Set<Id> trackedIds = new Map<Id, Asset>(tracked).keySet();
List<Asset> cleared = new List<Asset>();
for (Asset a : units) {
    cleared.add(new Asset(Id = a.Id, RLM_HVAC_Leak_Rate__c = null, RLM_HVAC_Last_Refrigerant_Add__c = null,
        RLM_HVAC_Repair_Due_Date__c = null,
        RLM_HVAC_Compliance_Status__c = trackedIds.contains(a.Id) ? RLM_HVAC_RefrigerantCompliance.IN_COMPLIANCE : null));
}
update cleared;

// History, oldest first: each insert's leak rate is measured from the adds already saved.
Date today = Date.today();
Asset watch = tracked[0];
Decimal charge = watch.RLM_HVAC_Refrigerant_Charge__c;
List<RLM_HVAC_Refrigerant_Log__c> first = new List<RLM_HVAC_Refrigerant_Log__c>{
    new RLM_HVAC_Refrigerant_Log__c(RLM_HVAC_Asset__c = watch.Id, RLM_HVAC_Logged_On__c = today.addDays(-WATCH_FIRST_DAYS),
        RLM_HVAC_Pounds_Added__c = (charge * 0.045).setScale(0, System.RoundingMode.HALF_UP),
        RLM_HVAC_Notes__c = 'Low on charge at the quarterly visit; tightened a Schrader core and topped off.')
};
for (Integer i = 1; i < tracked.size(); i++) {
    first.add(new RLM_HVAC_Refrigerant_Log__c(RLM_HVAC_Asset__c = tracked[i].Id, RLM_HVAC_Logged_On__c = today.addDays(-OTHER_DAYS),
        RLM_HVAC_Pounds_Added__c = (tracked[i].RLM_HVAC_Refrigerant_Charge__c * 0.035).setScale(0, System.RoundingMode.HALF_UP),
        RLM_HVAC_Notes__c = 'Topped off after a coil cleaning; no leak found.'));
}
insert first;
insert new RLM_HVAC_Refrigerant_Log__c(RLM_HVAC_Asset__c = watch.Id, RLM_HVAC_Logged_On__c = today.addDays(-WATCH_LAST_DAYS),
    RLM_HVAC_Pounds_Added__c = (charge * 0.06 * 2).setScale(0, System.RoundingMode.HALF_UP) / 2,
    RLM_HVAC_Notes__c = 'Charge low again; leak search found nothing at the coil. Watch this unit.');

// The visit: the site's next open quarterly maintenance work order, dispatched to the running user.
ServiceTerritory territory = [SELECT Id, OperatingHours.TimeZone FROM ServiceTerritory WHERE Name = :RLM_HVAC_CommercialCoverage.TERRITORY LIMIT 1];
List<ServiceResource> resources = [
    SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
];
if (resources.isEmpty()) {
    throw new IllegalArgumentException('The running user is not an active service resource. Run setup_hvac_foundation first.');
}
List<WorkOrder> visits = [
    SELECT Id, WorkType.EstimatedDuration FROM WorkOrder
    WHERE AccountId = :site.Id AND WorkType.Name = :RLM_HVAC_CommercialCoverage.MAINTENANCE_WORK_TYPE
        AND Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete')
    ORDER BY SuggestedMaintenanceDate NULLS LAST, CreatedDate LIMIT 1
];
if (visits.isEmpty()) {
    throw new IllegalArgumentException(site.Name + ' has no open quarterly maintenance visit. Book the contract first.');
}
WorkOrder visit = visits[0];
List<ServiceAppointment> appointments = [SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :visit.Id ORDER BY CreatedDate LIMIT 1];
ServiceAppointment sa = appointments.isEmpty() ? new ServiceAppointment(ParentRecordId = visit.Id) : appointments[0];
// The hour is on the territory's clock, not the running user's.
TimeZone zone = territory.OperatingHours.TimeZone == null
    ? UserInfo.getTimeZone() : TimeZone.getTimeZone(territory.OperatingHours.TimeZone);
Datetime wall = Datetime.newInstanceGmt(today.addDays(daysAhead), Time.newInstance(hour, 0, 0, 0));
Datetime start = wall.addSeconds(-zone.getOffset(wall) / 1000);
Integer minutes = visit.WorkType.EstimatedDuration == null ? 240 : (Integer) (visit.WorkType.EstimatedDuration * 60);
sa.EarliestStartTime = start.addHours(-2);
sa.DueDate = start.addDays(1);
sa.SchedStartTime = start;
sa.SchedEndTime = start.addMinutes(minutes);
sa.ArrivalWindowStartTime = start;
sa.ArrivalWindowEndTime = start.addHours(1);
sa.ServiceTerritoryId = territory.Id;
sa.Status = 'Dispatched';
upsert sa;
if ([SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id AND ServiceResourceId = :resources[0].Id] == 0) {
    insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = resources[0].Id);
}
// Touch the visit last so the task reports it.
update new WorkOrder(Id = visit.Id, StartDate = start, EndDate = start.addMinutes(minutes));

Decimal trips = (RLM_HVAC_RefrigerantCompliance.LEAK_LIMIT / 100 * charge * WATCH_LAST_DAYS / 365).setScale(1, System.RoundingMode.UP);
System.debug('Watch unit ' + watch.RLM_HVAC_Unit_Tag__c + ' (' + charge + ' lb): adding more than ' + trips + ' lb trips the limit.');
