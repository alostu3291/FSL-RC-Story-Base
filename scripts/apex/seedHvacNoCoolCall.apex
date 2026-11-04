// Idempotently book a No-Cool / No-Heat Call for an existing customer, dispatched to the running user.
// Run through the seed_hvac_service_call task, which fills the %%%...%%% tokens.
// RLM_HVAC_Coverage marks it Covered when an active comfort agreement covers the reported issue,
// sets the work order Priority from the agreement tier, and a Covered call gets the Priority
// Response milestone (4, 8 or 24 service hours). Re-running reuses the open call and moves it
// to the new time.

String accountName = '%%%ACCOUNT_NAME%%%';
String issue = '%%%ISSUE%%%';
Boolean requireCoverage = '%%%REQUIRE_COVERAGE%%%'.toLowerCase() != 'false';
String subject = String.isBlank('%%%SUBJECT%%%') ? issue + ' call' : '%%%SUBJECT%%%';
String description = String.isBlank('%%%DESCRIPTION%%%')
    ? (issue == 'No Heat'
        ? 'Homeowner reports the furnace runs but blows cold air; house is down to 61.'
        : 'Homeowner reports the AC runs but the house will not cool below 80; outdoor fan is not spinning.')
    : '%%%DESCRIPTION%%%';
Integer hour = Integer.valueOf('%%%HOUR%%%');
Integer daysAhead = Integer.valueOf('%%%DAYS_AHEAD%%%');
if (String.isBlank(issue)) {
    throw new IllegalArgumentException('Pass -o issue, for example No Cool, No Heat or Water Heater.');
}

List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
if (accounts.isEmpty()) {
    throw new IllegalArgumentException('No account named ' + accountName + '.');
}
Account account = accounts[0];

Set<String> systems = RLM_HVAC_Coverage.systemsForIssue(issue);
List<String> covering = new List<String>();
List<String> offered = new List<String>();
for (Entitlement e : [
    SELECT Name, RLM_HVAC_Covered_Systems__c FROM Entitlement
    WHERE AccountId = :account.Id AND RLM_HVAC_Covered_Systems__c != null
        AND StartDate <= TODAY AND (EndDate = null OR EndDate >= TODAY)
]) {
    offered.add(e.Name + ' (' + e.RLM_HVAC_Covered_Systems__c.replace(';', ', ') + ')');
    for (String s : e.RLM_HVAC_Covered_Systems__c.split(';')) {
        if (systems.contains(s)) {
            covering.add(e.Name);
            break;
        }
    }
}
if (requireCoverage && covering.isEmpty()) {
    throw new IllegalArgumentException(accountName + ' has no active agreement covering ' + issue + '. Agreements: '
        + (offered.isEmpty() ? 'none' : String.join(offered, '; '))
        + '. Pick a covered issue, or pass -o require_coverage false for a Not Covered call.');
}

WorkType callType = [SELECT Id, EstimatedDuration FROM WorkType WHERE Name = :RLM_HVAC_Coverage.SERVICE_CALL LIMIT 1];
ServiceTerritory territory = [SELECT Id, OperatingHours.TimeZone FROM ServiceTerritory WHERE Name = 'Naperville IL' LIMIT 1];
List<ServiceResource> resources = [
    SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
];
if (resources.isEmpty()) {
    throw new IllegalArgumentException('The running user is not an active service resource. Run setup_hvac_foundation first.');
}

List<WorkOrder> open = [
    SELECT Id FROM WorkOrder WHERE AccountId = :account.Id AND WorkTypeId = :callType.Id
        AND Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete') LIMIT 1
];
WorkOrder wo;
if (open.isEmpty()) {
    wo = new WorkOrder(AccountId = account.Id, WorkTypeId = callType.Id, RLM_HVAC_Reported_Issue__c = issue,
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
Integer minutes = callType.EstimatedDuration == null ? 120 : (Integer) (callType.EstimatedDuration * 60);
sa.EarliestStartTime = start.addHours(-2);
sa.DueDate = start.addDays(1);
sa.SchedStartTime = start;
sa.SchedEndTime = start.addMinutes(minutes);
sa.ArrivalWindowStartTime = start;
sa.ArrivalWindowEndTime = start.addHours(1);
sa.ServiceTerritoryId = territory.Id;
sa.Subject = subject;
sa.Status = 'Dispatched';
upsert sa;
if ([SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id AND ServiceResourceId = :resources[0].Id] == 0) {
    insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = resources[0].Id);
}
