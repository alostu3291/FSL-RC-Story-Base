// Moves a pest demo cast customer's Initial Pest Treatment on, dispatched to the running user.
// MODE book: schedules it DAYS_AHEAD days out at HOUR on the territory's clock, for the first treatment.
// MODE complete: treats every finding and completes it, which starts coverage and milestone billing,
// then dates the visit to the day the plans started (START_DAYS_AGO) so visit history reads right.
// Run through seed_rtk_demo_cast.

String accountName = '%%%ACCOUNT_NAME%%%';
String mode = '%%%MODE%%%';
Integer hour = Integer.valueOf('%%%HOUR%%%');
Integer daysAhead = Integer.valueOf('%%%DAYS_AHEAD%%%');
Integer startDaysAgo = Integer.valueOf('%%%START_DAYS_AGO%%%');

List<WorkOrder> treatments = [
    SELECT Id, Status, RLM_Order__r.QuoteId, RLM_RTK_Inspection__c,
        (SELECT Id FROM ServiceAppointments ORDER BY CreatedDate ASC LIMIT 1)
    FROM WorkOrder
    WHERE Account.Name = :accountName AND WorkType.Name = 'Initial Pest Treatment'
    ORDER BY CreatedDate DESC LIMIT 1
];
if (treatments.isEmpty() || treatments[0].ServiceAppointments.isEmpty()) {
    throw new IllegalArgumentException(accountName + ' has no Initial Pest Treatment appointment yet.');
}
WorkOrder wo = treatments[0];
if (wo.Status == 'Completed') {
    throw new IllegalArgumentException(accountName + '\'s first treatment is already completed.');
}
ServiceAppointment sa = wo.ServiceAppointments[0];
ServiceTerritory territory = [SELECT OperatingHours.TimeZone FROM ServiceTerritory WHERE Name = 'Bloomingdale IL' LIMIT 1];
TimeZone zone = territory.OperatingHours.TimeZone == null
    ? UserInfo.getTimeZone() : TimeZone.getTimeZone(territory.OperatingHours.TimeZone);

if (mode == 'book') {
    Datetime wall = Datetime.newInstanceGmt(Date.today().addDays(daysAhead), Time.newInstance(hour, 0, 0, 0));
    RLM_RTK_FieldVisit.bookTreatment(sa.Id, wall.addSeconds(-zone.getOffset(wall) / 1000), wo.RLM_Order__r.QuoteId);
} else {
    List<ServiceResource> resources = [
        SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
    ];
    if (!resources.isEmpty() && [SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id] == 0) {
        update new ServiceAppointment(Id = sa.Id, SchedStartTime = Datetime.now(), SchedEndTime = Datetime.now().addHours(1));
        insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = resources[0].Id);
    }
    RLM_RTK_FieldVisit.startVisit(sa.Id);
    for (RLM_RTK_Finding__c f : [SELECT Id, Pest__c FROM RLM_RTK_Finding__c WHERE Inspection__c = :wo.RLM_RTK_Inspection__c]) {
        RLM_RTK_Inspection.saveTreatment(wo.Id, f.Id, 'Treated',
            'Treated ' + (f.Pest__c == null ? 'the area' : f.Pest__c.toLowerCase()) + ' on the first visit.');
    }
    RLM_RTK_FieldVisit.completeVisit(wo.Id);

    Datetime wall = Datetime.newInstanceGmt(Date.today().addDays(-startDaysAgo), Time.newInstance(10, 0, 0, 0));
    Datetime startedAt = wall.addSeconds(-zone.getOffset(wall) / 1000);
    if (startedAt < Datetime.now().addHours(-1)) {
        Database.update(new ServiceAppointment(Id = sa.Id, SchedStartTime = startedAt, SchedEndTime = startedAt.addHours(1),
            ActualStartTime = startedAt, ActualEndTime = startedAt.addHours(1), ActualDuration = 60), false);
        Database.update(new WorkOrder(Id = wo.Id, StartDate = startedAt, EndDate = startedAt.addHours(1)), false);
    }
}
