// Idempotently book a free system check for a prospect, dispatched to the running user.
// Run through the seed_hvac_prospect_check task, which fills the %%%...%%% tokens.
// The comfort advisor runs Check & Quote from this appointment; no tune-up work order exists
// until the homeowner signs. Re-running reuses the open system check and moves it to the new time.

String accountName = '%%%ACCOUNT_NAME%%%';
String street = '%%%STREET%%%';
String phone = '%%%PHONE%%%';
String subject = String.isBlank('%%%SUBJECT%%%') ? 'Free System Check' : '%%%SUBJECT%%%';
String description = String.isBlank('%%%DESCRIPTION%%%')
    ? 'Homeowner says the upstairs will not cool below 78 and the furnace is about 14 years old. Check the system and quote on site.'
    : '%%%DESCRIPTION%%%';
Integer hour = Integer.valueOf('%%%HOUR%%%');
Integer daysAhead = Integer.valueOf('%%%DAYS_AHEAD%%%');

List<Account> accounts = [SELECT Id, ShippingStreet FROM Account WHERE Name = :accountName LIMIT 1];
Account account;
if (accounts.isEmpty()) {
    if (String.isBlank(street)) {
        throw new IllegalArgumentException('Pass -o street for a new prospect; each needs its own address.');
    }
    account = new Account(
        Name = accountName,
        ShippingStreet = street, ShippingCity = 'Naperville', ShippingState = 'IL',
        ShippingPostalCode = '60540', ShippingCountry = 'United States',
        BillingStreet = street, BillingCity = 'Naperville', BillingState = 'IL',
        BillingPostalCode = '60540', BillingCountry = 'United States'
    );
    Database.DMLOptions dml = new Database.DMLOptions();
    dml.DuplicateRuleHeader.AllowSave = true;
    Database.insert(account, dml);
} else {
    account = accounts[0];
    street = account.ShippingStreet;
}
if ([SELECT COUNT() FROM Asset WHERE AccountId = :account.Id AND Product2.StockKeepingUnit LIKE 'HVAC-%'] > 0) {
    throw new IllegalArgumentException(accountName + ' already has a comfort agreement. Pick a new prospect name.');
}
if ([SELECT COUNT() FROM Contact WHERE AccountId = :account.Id] == 0) {
    String first = accountName.substringBefore(' ');
    String last = accountName.contains(' ') ? accountName.substringAfter(' ') : accountName;
    insert new Contact(AccountId = account.Id, FirstName = first, LastName = last,
        Email = (first + '.' + last).toLowerCase().replaceAll('[^a-z.]', '') + '@example.com',
        Phone = String.isBlank(phone) ? null : phone);
}
Contact contact = [SELECT Id FROM Contact WHERE AccountId = :account.Id ORDER BY CreatedDate LIMIT 1];

WorkType checkType = [SELECT Id, EstimatedDuration FROM WorkType WHERE Name = 'System Check' LIMIT 1];
ServiceTerritory territory = [
    SELECT Id, OperatingHours.TimeZone FROM ServiceTerritory WHERE Name = 'Naperville IL' LIMIT 1
];
List<ServiceResource> resources = [
    SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
];
if (resources.isEmpty()) {
    throw new IllegalArgumentException('The running user is not an active service resource. Run setup_hvac_foundation first.');
}

List<WorkOrder> open = [
    SELECT Id, RLM_HVAC_Assessment__r.Status__c FROM WorkOrder
    WHERE AccountId = :account.Id AND WorkTypeId = :checkType.Id AND RLM_Order__c = null
        AND Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete')
    ORDER BY CreatedDate DESC LIMIT 1
];
// A visit whose quote was accepted is done; close it so this run books a fresh one.
if (!open.isEmpty() && open[0].RLM_HVAC_Assessment__r.Status__c == 'Accepted') {
    List<ServiceAppointment> done = [SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :open[0].Id];
    for (ServiceAppointment s : done) {
        s.Status = 'Completed';
    }
    update done;
    update new WorkOrder(Id = open[0].Id, Status = 'Completed');
    open.clear();
}
WorkOrder wo;
if (open.isEmpty()) {
    wo = new WorkOrder(
        AccountId = account.Id, ContactId = contact.Id, WorkTypeId = checkType.Id,
        ServiceTerritoryId = territory.Id, Subject = subject, Description = description,
        Street = street, City = 'Naperville', State = 'IL', PostalCode = '60540', Country = 'United States'
    );
    insert wo;
} else {
    wo = open[0];
}

List<ServiceAppointment> appointments = [
    SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :wo.Id ORDER BY CreatedDate ASC LIMIT 1
];
ServiceAppointment sa = appointments.isEmpty() ? new ServiceAppointment(ParentRecordId = wo.Id) : appointments[0];
// The hour is on the territory's clock, not the running user's.
TimeZone zone = territory.OperatingHours.TimeZone == null
    ? UserInfo.getTimeZone() : TimeZone.getTimeZone(territory.OperatingHours.TimeZone);
Datetime wall = Datetime.newInstanceGmt(Date.today().addDays(daysAhead), Time.newInstance(hour, 0, 0, 0));
Datetime start = wall.addSeconds(-zone.getOffset(wall) / 1000);
Integer minutes = checkType.EstimatedDuration == null ? 60 : (Integer) (checkType.EstimatedDuration * 60);
sa.EarliestStartTime = start.addHours(-2);
sa.DueDate = start.addDays(2);
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
