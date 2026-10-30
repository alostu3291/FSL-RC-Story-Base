// Idempotently book a pest re-service for an existing customer, dispatched to the running user.
// Run through the seed_rtk_reservice task, which fills the %%%...%%% tokens.
// RLM_RTK_Coverage marks it Covered when an active guarantee covers the reported pest, and a
// Covered re-service gets the 48-hour Re-service Response milestone. Re-running reuses the
// open re-service and moves it to the new time.

String accountName = '%%%ACCOUNT_NAME%%%';
String pest = '%%%PEST%%%';
Boolean requireCoverage = '%%%REQUIRE_COVERAGE%%%'.toLowerCase() != 'false';
String subject = String.isBlank('%%%SUBJECT%%%') ? 'Re-service: ' + pest.toLowerCase() + ' are back' : '%%%SUBJECT%%%';
String description = String.isBlank('%%%DESCRIPTION%%%')
    ? 'Customer reports ' + pest.toLowerCase() + ' again since the last treatment.'
    : '%%%DESCRIPTION%%%';
Integer hour = Integer.valueOf('%%%HOUR%%%');
Integer daysAhead = Integer.valueOf('%%%DAYS_AHEAD%%%');
if (String.isBlank(pest)) {
    throw new IllegalArgumentException('Pass -o pest, for example Ants, Rodents or Termites.');
}

List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
if (accounts.isEmpty()) {
    throw new IllegalArgumentException('No account named ' + accountName + '.');
}
Account account = accounts[0];

List<String> covering = new List<String>();
List<String> offered = new List<String>();
for (Entitlement e : [
    SELECT Name, RLM_RTK_Covered_Pests__c FROM Entitlement
    WHERE AccountId = :account.Id AND RLM_RTK_Covered_Pests__c != null
        AND StartDate <= TODAY AND (EndDate = null OR EndDate >= TODAY)
]) {
    offered.add(e.Name + ' (' + e.RLM_RTK_Covered_Pests__c.replace(';', ', ') + ')');
    if (e.RLM_RTK_Covered_Pests__c.split(';').contains(pest)) {
        covering.add(e.Name);
    }
}
if (requireCoverage && covering.isEmpty()) {
    throw new IllegalArgumentException(accountName + ' has no active guarantee covering ' + pest + '. Guarantees: '
        + (offered.isEmpty() ? 'none' : String.join(offered, '; '))
        + '. Pick a covered pest, or pass -o require_coverage false for a Not Covered visit.');
}

WorkType rs = [SELECT Id, EstimatedDuration FROM WorkType WHERE Name = 'Pest Re-service' LIMIT 1];
ServiceTerritory territory = [SELECT Id, OperatingHours.TimeZone FROM ServiceTerritory WHERE Name = 'Bloomingdale IL' LIMIT 1];
List<ServiceResource> resources = [
    SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
];
if (resources.isEmpty()) {
    throw new IllegalArgumentException('The running user is not an active service resource. Run setup_rtk_foundation first.');
}

List<WorkOrder> open = [
    SELECT Id FROM WorkOrder WHERE AccountId = :account.Id AND WorkTypeId = :rs.Id
        AND Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete') LIMIT 1
];
WorkOrder wo;
if (open.isEmpty()) {
    wo = new WorkOrder(AccountId = account.Id, WorkTypeId = rs.Id, RLM_RTK_Reported_Pest__c = pest,
        Subject = subject, Description = description);
    insert wo;
} else {
    wo = open[0];
}
List<ServiceAppointment> appointments = [SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :wo.Id ORDER BY CreatedDate ASC LIMIT 1];
ServiceAppointment sa = appointments.isEmpty() ? new ServiceAppointment(ParentRecordId = wo.Id) : appointments[0];
// The hour is on the territory's clock, not the running user's.
TimeZone zone = territory.OperatingHours.TimeZone == null
    ? UserInfo.getTimeZone() : TimeZone.getTimeZone(territory.OperatingHours.TimeZone);
Datetime wall = Datetime.newInstanceGmt(Date.today().addDays(daysAhead), Time.newInstance(hour, 0, 0, 0));
Datetime start = wall.addSeconds(-zone.getOffset(wall) / 1000);
Integer minutes = rs.EstimatedDuration == null ? 60 : (Integer) (rs.EstimatedDuration * 60);
sa.EarliestStartTime = start.addHours(-2);
sa.DueDate = start.addDays(2);
sa.SchedStartTime = start;
sa.SchedEndTime = start.addMinutes(minutes);
sa.ArrivalWindowStartTime = start;
sa.ArrivalWindowEndTime = start.addHours(1);
sa.ServiceTerritoryId = territory.Id;
sa.Subject = 'Pest Re-service';
sa.Status = 'Dispatched';
upsert sa;
if ([SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id AND ServiceResourceId = :resources[0].Id] == 0) {
    insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = resources[0].Id);
}
