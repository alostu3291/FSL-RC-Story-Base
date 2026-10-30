// Idempotently book a free pest inspection for a prospect, dispatched to the running user.
// Run through the seed_rtk_prospect_inspection task, which fills the %%%...%%% tokens.
// The technician runs Inspect & Quote from this appointment; no treatment work order exists
// until the customer signs. Re-running reuses the open inspection and moves it to the new time.

String accountName = '%%%ACCOUNT_NAME%%%';
String street = '%%%STREET%%%';
String phone = '%%%PHONE%%%';
String subject = String.isBlank('%%%SUBJECT%%%') ? 'Free Pest Inspection' : '%%%SUBJECT%%%';
String description = String.isBlank('%%%DESCRIPTION%%%')
    ? 'Prospect called about ants in the kitchen, droppings in the attic and mud tubes on the garage wall. Inspect and quote on site.'
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
        ShippingStreet = street, ShippingCity = 'Bloomingdale', ShippingState = 'IL',
        ShippingPostalCode = '60108', ShippingCountry = 'United States',
        BillingStreet = street, BillingCity = 'Bloomingdale', BillingState = 'IL',
        BillingPostalCode = '60108', BillingCountry = 'United States'
    );
    Database.DMLOptions dml = new Database.DMLOptions();
    dml.DuplicateRuleHeader.AllowSave = true;
    Database.insert(account, dml);
} else {
    account = accounts[0];
    street = account.ShippingStreet;
}
if ([SELECT COUNT() FROM Asset WHERE AccountId = :account.Id] > 0) {
    throw new IllegalArgumentException(accountName + ' already has plans. Pick a new prospect name.');
}
if ([SELECT COUNT() FROM Contact WHERE AccountId = :account.Id] == 0) {
    String first = accountName.substringBefore(' ');
    String last = accountName.contains(' ') ? accountName.substringAfter(' ') : accountName;
    insert new Contact(AccountId = account.Id, FirstName = first, LastName = last,
        Email = (first + '.' + last).toLowerCase().replaceAll('[^a-z.]', '') + '@example.com',
        Phone = String.isBlank(phone) ? null : phone);
}
Contact contact = [SELECT Id FROM Contact WHERE AccountId = :account.Id ORDER BY CreatedDate LIMIT 1];

WorkType inspectionType = [SELECT Id, EstimatedDuration FROM WorkType WHERE Name = 'Pest Inspection' LIMIT 1];
ServiceTerritory territory = [
    SELECT Id, OperatingHours.TimeZone FROM ServiceTerritory WHERE Name = 'Bloomingdale IL' LIMIT 1
];
List<ServiceResource> resources = [
    SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
];
if (resources.isEmpty()) {
    throw new IllegalArgumentException('The running user is not an active service resource. Run setup_rtk_foundation first.');
}

List<WorkOrder> open = [
    SELECT Id, RLM_RTK_Inspection__r.Status__c FROM WorkOrder
    WHERE AccountId = :account.Id AND WorkTypeId = :inspectionType.Id AND RLM_Order__c = null
        AND Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete')
    ORDER BY CreatedDate DESC LIMIT 1
];
// A visit whose quote was accepted is done; close it so this run books a fresh one.
if (!open.isEmpty() && open[0].RLM_RTK_Inspection__r.Status__c == 'Accepted') {
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
        AccountId = account.Id, ContactId = contact.Id, WorkTypeId = inspectionType.Id,
        ServiceTerritoryId = territory.Id, Subject = subject, Description = description,
        Street = street, City = 'Bloomingdale', State = 'IL', PostalCode = '60108', Country = 'United States'
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
Integer minutes = inspectionType.EstimatedDuration == null ? 60 : (Integer) (inspectionType.EstimatedDuration * 60);
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
