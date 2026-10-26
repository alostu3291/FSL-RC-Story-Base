// Idempotently book a free pest inspection for prospect Priya Nair, dispatched to the running
// user tomorrow at 10:00. The technician runs Inspect & Quote from this appointment in the Field
// Service mobile app; no treatment work order exists until the customer signs.
// Re-running reuses the open inspection work order and moves it back to tomorrow.

String accountName = 'Priya Nair';
List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
Account account;
if (accounts.isEmpty()) {
    account = new Account(
        Name = accountName,
        ShippingStreet = '142 Lakeview Ct', ShippingCity = 'Bloomingdale', ShippingState = 'IL',
        ShippingPostalCode = '60108', ShippingCountry = 'United States',
        BillingStreet = '142 Lakeview Ct', BillingCity = 'Bloomingdale', BillingState = 'IL',
        BillingPostalCode = '60108', BillingCountry = 'United States'
    );
    insert account;
} else {
    account = accounts[0];
}
List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :account.Id LIMIT 1];
Contact contact;
if (contacts.isEmpty()) {
    contact = new Contact(AccountId = account.Id, FirstName = 'Priya', LastName = 'Nair',
        Email = 'priya.nair@example.com', Phone = '(630) 555-0142');
    insert contact;
} else {
    contact = contacts[0];
}

WorkType inspectionType = [SELECT Id, EstimatedDuration FROM WorkType WHERE Name = 'Pest Inspection' LIMIT 1];
ServiceTerritory territory = [SELECT Id FROM ServiceTerritory WHERE Name = 'Bloomingdale IL' LIMIT 1];
ServiceResource resource = [
    SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
];

List<WorkOrder> open = [
    SELECT Id FROM WorkOrder
    WHERE AccountId = :account.Id AND WorkTypeId = :inspectionType.Id AND RLM_Order__c = null
        AND Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete')
    ORDER BY CreatedDate DESC LIMIT 1
];
WorkOrder wo;
if (open.isEmpty()) {
    wo = new WorkOrder(
        AccountId = account.Id,
        ContactId = contact.Id,
        WorkTypeId = inspectionType.Id,
        ServiceTerritoryId = territory.Id,
        Subject = 'Free Pest Inspection',
        Description = 'Prospect called about mice in the garage and ants in the kitchen. Inspect and quote on site.',
        Street = '142 Lakeview Ct', City = 'Bloomingdale', State = 'IL', PostalCode = '60108',
        Country = 'United States'
    );
    insert wo;
} else {
    wo = open[0];
}

List<ServiceAppointment> appointments = [
    SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :wo.Id ORDER BY CreatedDate ASC LIMIT 1
];
ServiceAppointment sa = appointments.isEmpty() ? new ServiceAppointment(ParentRecordId = wo.Id) : appointments[0];
Datetime start = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(10, 0, 0, 0));
Integer minutes = inspectionType.EstimatedDuration == null ? 60 : (Integer) (inspectionType.EstimatedDuration * 60);
sa.EarliestStartTime = start.addHours(-2);
sa.DueDate = start.addDays(2);
sa.SchedStartTime = start;
sa.SchedEndTime = start.addMinutes(minutes);
sa.ArrivalWindowStartTime = start;
sa.ArrivalWindowEndTime = start.addHours(1);
sa.ServiceTerritoryId = territory.Id;
sa.Subject = 'Free Pest Inspection';
sa.Status = 'Dispatched';
upsert sa;

if ([SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id AND ServiceResourceId = :resource.Id] == 0) {
    insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = resource.Id);
}

System.debug('setupRtkInspectionVisit complete: work order ' + wo.Id + ', appointment ' + sa.Id + ' at ' + start.format());
